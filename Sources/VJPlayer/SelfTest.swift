import AVFoundation
import AppKit
import Metal
import QuartzCore
import simd

/// `VJPlayer --selftest clip1.mov clip2.mov` で起動すると、画面を出さずに再生エンジンを検証して終了する。
/// 保存データには触れない。音量は 0。
enum SelfTest {
    static func run(paths: [String]) {
        guard paths.count >= 2 else {
            print("usage: VJPlayer --selftest a.mov b.mov"); exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)   // ログと順番が混ざらないように 1 行ずつ出す
        // テストの音はスピーカーに出さない（マスター音量を上げて確かめる項目があるため）
        AudioOutput.shared.silenceForTests()
        AudioOutput.shared.engine.mainMixerNode.outputVolume = 0
        let a = ClipSlot(url: URL(fileURLWithPath: paths[0]), endAction: .hold)
        let b = ClipSlot(url: URL(fileURLWithPath: paths[1]), endAction: .hold)
        var failures = 0

        func check(_ ok: Bool, _ msg: String) {
            print((ok ? "PASS " : "FAIL ") + msg)
            if !ok { failures += 1 }
        }
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        /// トリガーしてから最初のフレームが取れるまで(ms)
        func firstFrameLatency(_ slot: ClipSlot, trigger: () -> Void) -> Double {
            let t0 = CACurrentMediaTime()
            trigger()
            while CACurrentMediaTime() - t0 < 2 {
                if slot.frameForDisplay(at: CACurrentMediaTime()) != nil {
                    return (CACurrentMediaTime() - t0) * 1000
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.0005))
            }
            return .infinity
        }

        /// 音声の位置 − 映像の時計の位置(ms)。正なら音声が先行。
        func avOffsetMs(_ slot: ClipSlot) -> Double? {
            guard let r = slot.audio?.renderedPosition() else { return nil }
            return (r.pos - slot.clock.position(at: r.hostSeconds)) * 1000
        }

        let t0 = CACurrentMediaTime()
        while !(a.isReady && b.isReady) && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
        check(a.isReady && b.isReady,
              String(format: "クリップ読み込み %.2fs (音声=%@, 長さ=%.2fs)", CACurrentMediaTime() - t0,
                     a.hasAudio ? "あり" : "なし", a.duration))
        wait(0.5)

        // 1. 待機中クリップのポン出し
        let l1 = firstFrameLatency(a) { a.playFromStart() }
        check(l1 < 5, String(format: "トリガー → 先頭フレーム表示まで %.2f ms（動き出しは %.0f ms 後、音声と同時）",
                             l1, ClipSlot.startMargin * 1000))

        // 2. 音声と映像のずれ
        wait(1.0)
        var offs: [Double] = []
        for _ in 0..<10 { if let o = avOffsetMs(a) { offs.append(o) }; wait(0.05) }
        let base = offs.isEmpty ? .nan : offs.reduce(0, +) / Double(offs.count)
        check(!offs.isEmpty && abs(base) < 40, String(format: "音声と映像のずれ（通常速度）%.1f ms", base))

        // 3. 速度 1.03x が音声にも反映されるか
        a.speed = 1.03
        wait(0.3)
        if let r0 = a.audio?.renderedPosition() {
            wait(1.5)
            if let r1 = a.audio?.renderedPosition() {
                let ratio = (r1.pos - r0.pos) / (r1.hostSeconds - r0.hostSeconds)
                check(abs(ratio - 1.03) < 0.005, String(format: "速度 1.03x の実測（音声）%.4fx", ratio))
            }
        }
        a.speed = 1.0
        // 1.03x で約 1.8 秒 → 通常再生より約 +0.054 秒先行しているはず
        let off = a.offsetFromNormal(at: CACurrentMediaTime()) ?? .nan
        check(off > 0.045 && off < 0.065, String(format: "通常再生との差 %+.3f 秒（期待値 約 +0.054）", off))
        wait(0.5)
        let off2 = a.offsetFromNormal(at: CACurrentMediaTime()) ?? .nan
        check(abs(off2 - off) < 0.002, String(format: "1.0x に戻した後は差が増えない (%+.3f → %+.3f)", off, off2))
        check(a.clock.rate == 1.0 && a.audio?.rate == 1.0, "右クリック相当（1.0x に戻す）")

        // 4. マウスドラッグ中の速度変更でカクつかないか
        wait(0.3)
        let steady = measureSmoothness(a, seconds: 1.0) { _ in }
        var dragSpeed = 1.0
        var lastDrag = 0.0
        let drag = measureSmoothness(a, seconds: 2.0) { t in
            guard t - lastDrag >= 0.008 else { return }   // マウスイベント相当（約 8ms ごと）
            lastDrag = t
            dragSpeed += (sin(t * 3) > 0 ? 0.002 : -0.002)
            a.speed = dragSpeed
        }
        a.speed = 1.0
        print("   通常:       \(steady)")
        print("   ドラッグ中: \(drag)")
        // 間隔は他のアプリの負荷でも数 ms 揺れるので、半コマ（約 16ms）までの差は許す
        check(drag.maxGapMs <= steady.maxGapMs + 16 && drag.backwardJumps == 0 && drag.maxLagMs < 40,
              "ドラッグ中もフレームが途切れない")

        // 5. ドラッグ後も音声と映像がずれていないか
        wait(0.5)
        offs = []
        for _ in 0..<10 { if let o = avOffsetMs(a) { offs.append(o) }; wait(0.05) }
        let after = offs.isEmpty ? .nan : offs.reduce(0, +) / Double(offs.count)
        check(abs(after - base) < 10, String(format: "ドラッグ後の音声と映像のずれ %.1f ms（通常時との差 %.1f ms）", after, after - base))

        // 6. 再生中に別クリップへ切り替え
        let l2 = firstFrameLatency(b) {
            a.stopAndRearm()
            b.playFromStart()
        }
        check(l2 < 5, String(format: "別クリップへ切り替え → 先頭フレームまで %.2f ms", l2))

        // 7. 同じクリップを連打（待機ストリームが用意される前でも再生できるか）
        wait(0.05)
        let l3 = firstFrameLatency(b) { b.playFromStart() }
        check(l3 < 30, String(format: "同じクリップを連打 → 先頭フレームまで %.2f ms", l3))
        wait(0.5)
        let l4 = firstFrameLatency(b) { b.playFromStart() }
        check(l4 < 5, String(format: "同じクリップを再トリガー → 先頭フレームまで %.2f ms", l4))

        // 7b. スクラブ（進行バーをドラッグ）→ その位置の映像が出て、離すとそこから再生
        b.stopAndRearm()
        a.playFromStart()
        wait(0.3)
        for t in stride(from: 3.0, through: 10.0, by: 0.5) {   // ドラッグ相当
            a.scrub(to: t)
            _ = a.frameForDisplay(at: CACurrentMediaTime())
            wait(0.01)
        }
        wait(0.05)
        var shown = -1.0
        for _ in 0..<20 {
            if a.frameForDisplay(at: CACurrentMediaTime()) != nil { shown = a.lastShownPTS; break }
            wait(0.005)
        }
        check(!a.isPlaying && a.isScrubbing && abs(shown - 10.0) < 0.05,
              String(format: "スクラブ中はその位置の映像が出る（10.000 秒 → 表示 %.3f 秒）", shown))
        a.endScrub()
        wait(0.6)
        let posAfter = a.position(at: CACurrentMediaTime())
        check(a.isPlaying && posAfter > 10.4 && posAfter < 10.7,
              String(format: "離すとその位置から再生（0.6 秒後に %.2f 秒）", posAfter))
        offs = []
        for _ in 0..<10 { if let o = avOffsetMs(a) { offs.append(o) }; wait(0.05) }
        let scrubOff = offs.isEmpty ? .nan : offs.reduce(0, +) / Double(offs.count)
        check(abs(scrubOff - base) < 10, String(format: "スクラブ後の音声と映像のずれ %.1f ms", scrubOff))

        // 8. ループなしのクリップは最後で止まる
        a.playFromStart()
        b.stopAndRearm()
        let endWait = a.duration + 0.5
        let te = CACurrentMediaTime()
        while CACurrentMediaTime() - te < endWait {
            _ = a.frameForDisplay(at: CACurrentMediaTime())
            wait(0.016)
        }
        check(!a.isPlaying && abs(a.currentTime - a.duration) < 0.01, "ループなしのクリップは最後のフレームで止まる")

        // 8b. イン点・アウト点
        func pump(_ s: Double) {
            let t = CACurrentMediaTime()
            while CACurrentMediaTime() - t < s { _ = a.frameForDisplay(at: CACurrentMediaTime()); wait(0.008) }
        }
        a.setInOut(in: 2.0, out: .some(3.0))
        a.endAction = .loop
        wait(0.3)   // 待機ストリームの作り直しを待つ
        let lIn = firstFrameLatency(a) { a.playFromStart() }
        let firstPTS = a.lastShownPTS
        check(lIn < 5 && abs(firstPTS - 2.0) < 0.05,
              String(format: "イン点から再生（先頭フレーム %.3f 秒、%.2f ms）", firstPTS, lIn))
        pump(0.5)
        offs = []
        for _ in 0..<10 { if let o = avOffsetMs(a) { offs.append(o) }; wait(0.03) }
        let inOff = offs.isEmpty ? .nan : offs.reduce(0, +) / Double(offs.count)
        check(abs(inOff - base) < 10, String(format: "イン点から再生しても音声と映像はずれない（%.1f ms）", inOff))
        pump(0.9)
        let looped = a.position(at: CACurrentMediaTime())
        check(a.isPlaying && looped >= 2.0 && looped < 2.7,
              String(format: "アウト点まで来たらイン点へループ（1.4 秒後に %.2f 秒）", looped))
        // 往復：アウト点で逆向きになり、イン点でまた順向きに
        a.endAction = .pingpong
        wait(0.4)   // 逆再生の準備
        a.playFromStart()
        pump(1.25)
        let rp1 = a.position(at: CACurrentMediaTime())
        var revPTS: [Double] = []
        let tr = CACurrentMediaTime()
        while CACurrentMediaTime() - tr < 0.4 {
            if a.frameForDisplay(at: CACurrentMediaTime()) != nil { revPTS.append(a.lastShownPTS) }
            wait(0.008)
        }
        let rp2 = a.position(at: CACurrentMediaTime())
        let descending = revPTS.count >= 8 && zip(revPTS, revPTS.dropFirst()).allSatisfy { $0 > $1 }
        check(a.isReversing && rp1 > 2.6 && rp1 < 3.0 && rp2 < rp1 && descending,
              String(format: "往復：アウト点で逆再生になる（%.2f → %.2f 秒、表示コマ %d 枚とも逆順）", rp1, rp2, revPTS.count))
        offs = []
        for _ in 0..<8 { if let o = avOffsetMs(a) { offs.append(o) }; wait(0.02) }
        let revOff = offs.isEmpty ? .nan : offs.reduce(0, +) / Double(offs.count)
        check(a.hasAudio == false || abs(revOff + base) < 15 || abs(revOff - base) < 15,
              String(format: "逆再生中も音声は映像に付いてくる（ずれ %.1f ms）", revOff))
        pump(0.75)
        let rp3 = a.position(at: CACurrentMediaTime())
        check(!a.isReversing && a.isPlaying && rp3 >= 2.0 && rp3 < 2.75,
              String(format: "往復：イン点でまた順再生に戻る（%.2f 秒）", rp3))

        // 逆再生の滑らかさ（2 倍速、長めの区間）
        a.setInOut(in: 2.0, out: .some(8.0))
        a.speed = 2.0
        wait(0.4)
        a.playFromStart()
        pump(3.1)
        var gap = 0.0, lastNew = CACurrentMediaTime(), newCount = 0, backward = 0, lastP = Double.infinity
        let tg = CACurrentMediaTime()
        while CACurrentMediaTime() - tg < 2.0 && a.isReversing {
            if a.frameForDisplay(at: CACurrentMediaTime()) != nil {
                let now = CACurrentMediaTime()
                gap = max(gap, now - lastNew); lastNew = now; newCount += 1
                if a.lastShownPTS > lastP { backward += 1 }
                lastP = a.lastShownPTS
            }
            wait(1.0 / 120.0)
        }
        check(newCount > 30 && gap < 0.07 && backward == 0,
              String(format: "2 倍速の逆再生も滑らか（新しいコマ %d 枚、最大間隔 %.0f ms、向きの乱れ %d）", newCount, gap * 1000, backward))
        a.speed = 1.0
        a.setInOut(in: 2.0, out: .some(3.0))
        wait(0.3)

        a.endAction = .hold
        a.playFromStart()
        pump(1.3)
        check(!a.isPlaying && abs(a.currentTime - 3.0) < 0.01 && a.lastShownPTS > 2.8 && a.lastShownPTS < 3.0,
              String(format: "「最後で停止」はアウト点のコマで止まる（表示 %.3f 秒）", a.lastShownPTS))
        a.setInOut(in: 5, out: .some(4))
        check(a.inPoint < a.outTime && a.outTime - a.inPoint >= ClipSlot.minRange - 0.0001,
              String(format: "イン点はアウト点を越えない（イン %.2f / アウト %.2f）", a.inPoint, a.outTime))
        a.resetInOut()
        check(a.inPoint == 0 && a.outPoint == nil, "再生範囲のリセット")
        wait(0.3)

        // 9. レイヤーの合成（GPU で合成した色を読み戻して計算と比べる）
        testBlending(check)
        testTransform(check)

        // 10. レイヤー（段）ごとに同時再生できるか
        a.stopAndRearm()
        testLayers(paths: paths, check: check, wait: wait)

        // 11. メインスレッドが忙しくても出力の映像が止まらないか
        testRenderThread(paths: paths, check: check, wait: wait)

        // 12. 出力せずにクリップをプレビュー（クリップ選択）、レイヤー・コンポジションのプレビュー
        testPreviews(paths: paths, check: check, wait: wait)

        // 13. レイヤー・列の増減
        testGrid(paths: paths, check: check, wait: wait)

        // 14. パラメーターのアニメーションと BPM
        testAnimation(paths: paths, check: check, wait: wait)

        // 15. エフェクト
        testEffects(check)
        testClipPosterizeTime(paths: paths, check: check, wait: wait)
        testGeneratorSlots(check: check)
        testScenes(check: check, wait: wait)
        testSceneEdit(check: check, wait: wait)
        testSceneClipIDs(check: check)
        testDecks(check: check, wait: wait)
        testPads(check: check)
        testMultiSelect(check: check)
        testMoveLayer(check: check)
        testEffectClips(check: check)
        testCues(check: check, wait: wait)
        do {
            // レイアウト：保存して読み戻せる（古い保存データの無い項目は既定値）
            var l = LayoutState()
            l.topHeight = 640; l.monitorWidth = 360; l.detached = [.live, .pads]; l.floating = [.live]
            l.frames["live"] = NSStringFromRect(NSRect(x: 10, y: 20, width: 300, height: 400))
            let back = (try? JSONEncoder().encode(l)).flatMap { try? JSONDecoder().decode(LayoutState.self, from: $0) }
            check(back == l, "レイアウト：境目・別ウィンドウ・常に手前・場所を保存して戻せる")
            let auto = try? JSONDecoder().decode(LayoutState.self, from: Data("{}".utf8))
            check(auto?.topHeight == nil && auto?.detached.isEmpty == true, "レイアウト：何も無ければおまかせ・全部メインのウィンドウ")
        }
        do {
            // 自由レイアウト：区画の木の操作
            let std = DockNode.standard
            check(Set(std.panels) == Set(DockPanel.allCases) && std.panels.count == DockPanel.allCases.count,
                  "自由レイアウト：最初の並べ方に全部のパネルが 1 回ずつある")
            for (name, tpl) in [("ポン出し", DockNode.cuePlayback), ("クラブ VJ", DockNode.clubVJ)] {
                check(Set(tpl.panels) == Set(DockPanel.allCases) && tpl.panels.count == DockPanel.allCases.count,
                      "おすすめのレイアウト（\(name)）：全部のパネルが 1 回ずつある")
            }
            for (name, tpl) in [("ポン出し", DockNode.cuePlayback), ("クラブ VJ", DockNode.clubVJ)] {
                if case .split(_, .vertical, _, _, .tabs(_, let bottom, _)) = tpl {
                    check(bottom == [.pads], "おすすめのレイアウト（\(name)）：FX パッドが下いっぱい")
                } else {
                    check(false, "おすすめのレイアウト（\(name)）：FX パッドが下いっぱい")
                }
            }
            check(DockNode.cuePlayback.tabsID(containing: .live) != DockNode.cuePlayback.tabsID(containing: .cues),
                  "おすすめのレイアウト（ポン出し）：ライブとキューが別々に見える")
            func tabsID(of p: DockPanel, in n: DockNode) -> UUID? {
                switch n {
                case .tabs(let id, let ps, _): return ps.contains(p) ? id : nil
                case .split(_, _, _, let a, let b): return tabsID(of: p, in: a) ?? tabsID(of: p, in: b)
                }
            }
            // モニターをパラメーターの左へ → 元の区画（モニターだけ）は閉じる
            let paramsID = tabsID(of: .params, in: std)!
            let m1 = std.moving(.monitor, to: paramsID, zone: .left)
            check(m1.panels.count == DockPanel.allCases.count && tabsID(of: .monitor, in: m1) != tabsID(of: .params, in: m1),
                  "自由レイアウト：端に置くと区画が分かれる（パネルは減りも増えもしない）")
            if case .split(_, _, _, let a, _)? = { () -> DockNode? in
                func parent(_ n: DockNode) -> DockNode? {
                    if case .split(_, _, _, let x, let y) = n {
                        if case .tabs(_, let ps, _) = y, ps == [.params] { if case .tabs(_, let qs, _) = x, qs == [.monitor] { return n } }
                        return parent(x) ?? parent(y)
                    }
                    return nil
                }
                return parent(m1)
            }() {
                check(a.panels == [.monitor], "自由レイアウト：左に置くと左側に来る")
            } else {
                check(false, "自由レイアウト：左に置くと左側に来る")
            }
            // シーンをグリッドの区画の真ん中へ → タブになる
            let gridID = tabsID(of: .grid, in: m1)!
            let m2 = m1.moving(.scenes, to: gridID, zone: .center)
            check(m2.find(gridID).map { $0.panels == [.grid, .scenes] } == true, "自由レイアウト：真ん中に置くとタブになる")
            // 自分だけの区画の真ん中に落としても何も変わらない
            let padsID = tabsID(of: .pads, in: m2)!
            check(m2.moving(.pads, to: padsID, zone: .center) == m2, "自由レイアウト：自分の区画に戻しても変わらない")
            // 別ウィンドウにしたものは表示から消え、空の区画は閉じる
            let pr = m2.pruned([.pads, .monitor])
            check(pr.map { !$0.panels.contains(.pads) && !$0.panels.contains(.monitor) && $0.panels.count == DockPanel.allCases.count - 2 } == true,
                  "自由レイアウト：別ウィンドウのパネルは除いて表示する")
            // 保存して戻す・壊れたもの（重なり・抜け）は直す
            let back = (try? JSONEncoder().encode(m2)).flatMap { try? JSONDecoder().decode(DockNode.self, from: $0) }
            check(back == m2, "自由レイアウト：保存して戻せる")
            let broken = DockNode.split(id: UUID(), axis: .horizontal, ratio: 0.5,
                                        first: .tabs(id: UUID(), panels: [.grid, .grid], selected: 1),
                                        second: .tabs(id: UUID(), panels: [.grid], selected: 0)).normalized()
            check(Set(broken.panels) == Set(DockPanel.allCases) && broken.panels.count == DockPanel.allCases.count,
                  "自由レイアウト：重なり・抜けのある並べ方は直してから使う")
            // 画面の端：グリッドを左端いっぱい、FX パッドを下いっぱい
            let e1 = m2.movingToEdge(.grid, .left).movingToEdge(.pads, .bottom)
            if case .split(_, .vertical, _, let rest, .tabs(_, let bottom, _)) = e1,
               case .split(_, .horizontal, _, .tabs(_, let left, _), _) = rest {
                check(bottom == [.pads] && left == [.grid] && e1.panels.count == DockPanel.allCases.count,
                      "自由レイアウト：画面の端に置くと、その辺いっぱいになる")
            } else {
                check(false, "自由レイアウト：画面の端に置くと、その辺いっぱいになる")
            }
            // 境目に差し込む：左右に分かれた所（グリッド｜右側）の間に、プレビューを縦いっぱいで差し込む
            let base = DockNode.split(id: UUID(), axis: .horizontal, ratio: 0.6,
                                      first: .tabs(id: UUID(), panels: [.grid], selected: 0),
                                      second: .split(id: UUID(), axis: .vertical, ratio: 0.5,
                                                     first: .tabs(id: UUID(), panels: [.monitor], selected: 0),
                                                     second: .tabs(id: UUID(), panels: [.preview, .live], selected: 0)))
            guard case .split(let rootID, _, _, _, _) = base else { return }
            let ins = base.movingToBorder(.preview, rootID)
            if case .split(_, .horizontal, _, .tabs(_, let l, _), .split(_, .horizontal, _, .tabs(_, let mid, _), let right)) = ins {
                check(l == [.grid] && mid == [.preview] && !right.panels.contains(.preview) && right.panels.contains(.live),
                      "自由レイアウト：境目に落とすと、そこに縦いっぱいの列が増える")
            } else {
                check(false, "自由レイアウト：境目に落とすと、そこに縦いっぱいの列が増える")
            }
        }
        testStillImages(check: check, wait: wait)
        testSources(dir: URL(fileURLWithPath: paths[0]).deletingLastPathComponent(), check: check, wait: wait)

        // 16. ミュート（クリップ・レイヤー・コンポジション）
        testMute(paths: paths, check: check, wait: wait)

        // 17. プロジェクトファイル
        testProject(paths: paths, check: check, wait: wait)

        let out = AudioOutput.shared.engine.outputNode
        let feeding = AudioOutput.shared.engine.inputConnectionPoint(for: out, inputBus: 0)?.node as? AVAudioMixerNode
        check(AudioOutput.shared.silenced && feeding !== AudioOutput.shared.engine.mainMixerNode && feeding?.outputVolume == 0,
              "テスト中の音はスピーカーに出ていない（出力の手前に音量 0 のミキサー）")
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func testBlending(_ check: (Bool, String) -> Void) {
        let ctx = MetalContext.shared
        func q(_ v: SIMD3<Float>) -> SIMD3<Float> { (v * Float(255)).rounded(.toNearestOrEven) / Float(255) }
        func solid(_ c: SIMD3<Float>) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
            td.usage = [.shaderRead]
            let t = ctx.device.makeTexture(descriptor: td)!
            let b = (c * Float(255)).rounded(.toNearestOrEven)
            let px = [UInt8](repeating: 0, count: 64).enumerated().map { i, _ -> UInt8 in
                switch i % 4 { case 0: UInt8(b.z); case 1: UInt8(b.y); case 2: UInt8(b.x); default: 255 }
            }
            t.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: px, bytesPerRow: 16)
            return t
        }
        let d = q(SIMD3(0.2, 0.4, 0.8)), s = q(SIMD3(0.6, 0.5, 0.1))
        let op: Float = 0.5
        let one = SIMD3<Float>(repeating: 1)
        let bottom = solid(d), top = solid(s)
        for mode in BlendMode.allCases where !mode.isSpecial {
            let comp = Compositor()
            comp.storageMode = .shared
            let cb = ctx.queue.makeCommandBuffer()!
            guard let t = comp.composite([
                LayerDraw(texture: bottom, opacity: 1, blend: .normal, holder: nil),
                LayerDraw(texture: top, opacity: op, blend: mode, holder: nil),
            ], width: 4, height: 4, cb: cb) else { check(false, "合成 \(mode.label)"); continue }
            cb.commit()
            cb.waitUntilCompleted()
            var out = [UInt8](repeating: 0, count: 64)
            t.getBytes(&out, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
            let got = SIMD3<Float>(Float(out[2]), Float(out[1]), Float(out[0])) / 255
            let exp: SIMD3<Float>
            switch mode {
            case .normal: exp = d * (1 - op) + s * op
            case .add: exp = simd_min(d + s * op, one)
            case .screen: exp = d + s * op * (one - d)
            case .multiply: exp = d * ((1 - op) + s * op)
            case .maskLuma, .maskInvert:
                let l = min(max(simd_dot(s, SIMD3(0.2126, 0.7152, 0.0722)), 0), 1)
                exp = d * (1 - op + op * (mode == .maskLuma ? l : 1 - l))
            case .overdrive: continue
            }
            let err = simd_reduce_max(simd_abs(got - exp))
            check(err < 3.0 / 255, String(format: "合成モード「%@」不透明度50%%: 誤差 %.1f/255", mode.label, err * 255))
        }
    }

    /// クリップのトランスフォーム（位置・スケール・角度・不透明度）を GPU で合成して確かめる
    static func testTransform(_ check: (Bool, String) -> Void) {
        let ctx = MetalContext.shared
        let n = 8
        // 左半分が赤、右半分が青の 8x8
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: n, height: n, mipmapped: false)
        td.usage = [.shaderRead]
        let src = ctx.device.makeTexture(descriptor: td)!
        var px = [UInt8]()
        for _ in 0..<n { for x in 0..<n { px += x < n / 2 ? [0, 0, 255, 255] : [255, 0, 0, 255] } }
        src.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: px, bytesPerRow: n * 4)

        enum C: String { case red = "赤", blue = "青", black = "黒", other = "?" }
        func render(_ t: ClipTransform, layer lt: ClipTransform = ClipTransform(),
                    comp ct: ClipTransform = ClipTransform()) -> (Int, Int) -> (C, Int) {
            let comp = Compositor()
            comp.storageMode = .shared
            let cb = ctx.queue.makeCommandBuffer()!
            let out = comp.composite([LayerDraw(texture: src, opacity: 1, blend: .normal, transform: t,
                                                layerTransform: lt, compTransform: ct, holder: nil)],
                                     width: n, height: n, cb: cb)!
            cb.commit()
            cb.waitUntilCompleted()
            var b = [UInt8](repeating: 0, count: n * n * 4)
            out.getBytes(&b, bytesPerRow: n * 4, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)
            return { x, y in
                let i = (y * n + x) * 4
                let (bl, r) = (Int(b[i]), Int(b[i + 2]))
                let c: C = r > 100 && bl < 30 ? .red : (bl > 100 && r < 30 ? .blue : (r < 10 && bl < 10 ? .black : .other))
                return (c, max(r, bl))
            }
        }
        func expect(_ name: String, _ t: ClipTransform, layer lt: ClipTransform = ClipTransform(),
                    comp ct: ClipTransform = ClipTransform(), _ cases: [(Int, Int, C)]) {
            let px = render(t, layer: lt, comp: ct)
            let got = cases.map { px($0.0, $0.1).0 }
            let ok = zip(got, cases).allSatisfy { $0 == $1.2 }
            check(ok, "トランスフォーム \(name): " + zip(cases, got).map { "(\($0.0.0),\($0.0.1))=\($0.1.rawValue)" }.joined(separator: " "))
        }
        expect("なし", ClipTransform(), [(1, 4, .red), (6, 4, .blue)])
        expect("角度 180°", ClipTransform(rotation: .pi), [(1, 4, .blue), (6, 4, .red)])
        expect("角度 +90°（時計回り → 左が上に）", ClipTransform(rotation: .pi / 2), [(4, 1, .red), (4, 6, .blue)])
        expect("スケール 50%", ClipTransform(scale: 0.5), [(0, 0, .black), (7, 4, .black), (3, 4, .red), (4, 4, .blue)])
        expect("位置 X +50%（右へ）", ClipTransform(x: 0.5), [(1, 4, .black), (6, 4, .red)])
        expect("位置 Y +50%（上へ）", ClipTransform(y: 0.5), [(4, 6, .black), (6, 1, .blue)])
        expect("レイヤー 位置 X +50%", ClipTransform(), layer: ClipTransform(x: 0.5), [(1, 4, .black), (6, 4, .red)])
        expect("コンポジション 角度 180°", ClipTransform(), comp: ClipTransform(rotation: .pi), [(1, 4, .blue), (6, 4, .red)])
        // クリップを右へ 50%（出力の 4/8〜12/8）→ レイヤーで 50% に縮小（出力の中心基準）→ 4/8〜8/8 に入る
        expect("クリップ X +50% × レイヤー スケール 50%", ClipTransform(x: 0.5), layer: ClipTransform(scale: 0.5),
               [(3, 4, .black), (5, 4, .red), (6, 4, .blue)])
        let half = render(ClipTransform(opacity: 0.5))(1, 4)
        check(half.0 == .red && abs(half.1 - 128) <= 2, "クリップの不透明度 50%: 赤 \(half.1)/255")
    }

    static func testLayers(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        let urlA = URL(fileURLWithPath: paths[0]), urlB = URL(fileURLWithPath: paths[1])
        let c = e.columns
        e.load(urls: [urlA, urlA], startingAt: 0)   // L1 の 1 列目・2 列目
        e.load(urls: [urlB], startingAt: c)          // L2 の 1 列目
        let t0 = CACurrentMediaTime()
        while ![0, 1, c].allSatisfy({ e.slots[$0]?.isReady == true }) && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
        wait(0.3)

        e.trigger(0)
        e.trigger(c)
        check(e.activeByLayer[0] == 0 && e.activeByLayer[1] == c && e.slots[0]!.isPlaying && e.slots[c]!.isPlaying,
              "L1 と L2 で同時に再生できる")
        check(e.selectedLayer == 1, "最後にトリガーしたレイヤーが選択される")

        // 60Hz の描画ループで、両方のレイヤーのフレームが更新され続けるか
        var updates = [0, 0]
        var last: [ObjectIdentifier?] = [nil, nil]
        let tl = CACurrentMediaTime()
        while CACurrentMediaTime() - tl < 1.0 {
            e.updateFrame()
            for r in 0..<2 {
                let id = e.frame(layer: r).map { ObjectIdentifier($0) }
                if id != last[r] { updates[r] += 1; last[r] = id }
            }
            _ = e.layerDraws()
            wait(1.0 / 60.0)
        }
        check(updates.allSatisfy { $0 >= 25 }, "2 レイヤー同時再生で両方 30fps 近く更新される (L1=\(updates[0]) L2=\(updates[1]) /1秒)")
        check(e.layerDraws().count == 2, "合成対象が 2 レイヤー")

        // 同じ段の別クリップをトリガー → その段だけ切り替わる
        e.trigger(1)
        check(e.activeByLayer[0] == 1 && !e.slots[0]!.isPlaying && e.slots[1]!.isPlaying && e.slots[c]!.isPlaying,
              "同じ段の別クリップに切り替えても、他のレイヤーは止まらない")

        // レイヤーの音量
        e.layers[1].volume = 0.5
        wait(0.05)
        check(e.slots[c]?.audio?.node.volume == 0.5, "レイヤーの音量がクリップの音声に反映される")
        e.slots[c]?.clipVolume = 0.5
        wait(0.05)
        check(e.slots[c]?.audio?.node.volume == 0.25, "クリップの音量はレイヤーの音量と掛け合わされる (50% × 50%)")
        e.slots[c]?.clipVolume = 1
        e.slots[c]?.scale = 0.5
        check(e.layerDraws().first { $0.transform.scale == 0.5 } != nil, "クリップのスケールが描画に反映される")
        e.slots[c]?.scale = 1

        // コンポジション速度：全クリップに掛かる（クリップ速度との掛け算、音声も）
        let s1 = e.slots[1]!, s2 = e.slots[c]!
        s1.speed = 1.1
        e.masterSpeed = 1.03
        wait(0.05)
        check(abs(s1.clock.rate - 1.133) < 1e-9 && abs(s2.clock.rate - 1.03) < 1e-9
              && abs((s1.audio?.rate ?? 0) - 1.133) < 1e-4 && abs((s2.audio?.rate ?? 0) - 1.03) < 1e-4,
              String(format: "コンポジション速度 1.03x × クリップ速度 → 映像・音声とも %.3fx / %.3fx", s1.clock.rate, s2.clock.rate))
        e.masterSpeed = 1.0
        s1.speed = 1.0
        wait(0.05)
        check(s1.clock.rate == 1.0 && s2.clock.rate == 1.0, "コンポジション速度を 1.0x に戻すと全クリップ 1.0x")

        // レイヤー・コンポジションのトランスフォームが描画に渡る
        e.layers[1].transform.scale = 0.5
        e.compTransform.rotation = 90
        e.updateFrame()
        let d = e.layerDraws().first { $0.layerTransform.scale == 0.5 }
        check(d != nil && abs((d?.compTransform.rotation ?? 0) - .pi / 2) < 1e-5, "レイヤー・コンポジションのトランスフォームが描画に渡る")
        e.layers[1].transform.reset()
        e.compTransform.reset()

        // 不透明度 0 のレイヤーは合成しない
        e.layers[0].opacity = 0
        e.updateFrame()
        check(e.layerDraws().count == 1, "不透明度 0 のレイヤーは合成しない")
        e.layers[0].opacity = 1

        e.stopLayer(1)
        check(e.activeByLayer[1] == nil && e.frame(layer: 1) == nil && !e.slots[c]!.isPlaying && e.slots[1]!.isPlaying,
              "レイヤー単位で停止できる")
        // 再生中のクリップを別のレイヤーへ移動（L1 の 2 列目 → L2 の 3 列目）
        let moved = e.slots[1]
        e.moveSlot(1, to: c + 2)
        check(e.slots[1] == nil && e.slots[c + 2] === moved && moved?.isPlaying == true
              && e.activeByLayer[0] == nil && e.activeByLayer[1] == c + 2 && e.selectedLayer == 1,
              "再生中のクリップを別レイヤーへ移動しても止まらず、移動先のレイヤーで再生される")
        wait(0.05)
        check(moved?.audio?.node.volume == 0.5, "移動先レイヤーの音量になる")
        var gotFrame = false
        for _ in 0..<10 { e.updateFrame(); if e.frame(layer: 1) != nil { gotFrame = true; break }; wait(1.0 / 60.0) }
        check(gotFrame && e.frame(layer: 0) == nil, "移動先のレイヤーに映像が出て、元のレイヤーは空になる")

        // 移動先のレイヤーで別のクリップが再生中 → そちらが止まる
        e.trigger(0)                  // L1 で slot0 再生
        let a0 = e.slots[0]
        e.moveSlot(0, to: c + 3)      // L2 へ（L2 では moved が再生中）
        check(e.activeByLayer[1] == c + 3 && a0?.isPlaying == true && moved?.isPlaying == false,
              "移動先のレイヤーで再生中だったクリップは止まる（1レイヤー1クリップ）")

        // 入れ替え
        e.moveSlot(c + 3, to: c + 2)
        check(e.slots[c + 2] === a0 && e.slots[c + 3] === moved && e.activeByLayer[1] == c + 2,
              "クリップ同士を入れ替えられる")

        e.stopAll()
        check(e.activeByLayer.allSatisfy { $0 == nil } && e.layerDraws().isEmpty, "全レイヤー停止")
    }

    static func testRenderThread(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
        e.load(urls: [URL(fileURLWithPath: paths[1])], startingAt: e.columns)
        let t0 = CACurrentMediaTime()
        while !(e.slots[0]?.isReady == true && e.slots[e.columns]?.isReady == true) && CACurrentMediaTime() - t0 < 10 { wait(0.05) }

        let loop = RenderLoop(engine: e)
        let layer = CAMetalLayer()
        layer.device = MetalContext.shared.device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 1280, height: 720)
        loop.add(layer)
        e.trigger(0)
        e.trigger(e.columns)
        wait(0.5)

        loop.resetStats()
        wait(1.0)
        let idle = loop.currentStats()

        // メインスレッドを 1 秒間ふさぎながら、速度・不透明度を 5ms ごとに変え続ける（重い画面操作の再現）
        loop.resetStats()
        let tb = CACurrentMediaTime()
        var i = 0
        while CACurrentMediaTime() - tb < 1.0 {
            i += 1
            e.slots[0]!.speed = 1.0 + Double(i % 20) * 0.002
            e.layers[1].opacity = Double(i % 10) / 10
            usleep(5_000)
        }
        let busy = loop.currentStats()
        e.slots[0]!.speed = 1.0
        loop.stop()
        e.stopAll()

        func fmt(_ s: RenderLoop.Stats) -> String {
            String(format: "vsync=%d 新フレーム=%d 最大間隔=%.1fms vsync最大間隔=%.1fms", s.ticks, s.newFrames, s.maxNewFrameGapMs, s.maxTickGapMs)
        }
        print("   通常時:           \(fmt(idle))")
        print("   メインが忙しい時: \(fmt(busy))")
        check(busy.newFrames >= 27 && busy.maxNewFrameGapMs < 50,
              "メインスレッドが 1 秒ふさがっていても、出力の映像は 30fps で更新され続ける")
    }

    /// エフェクトを GPU で処理して、読み戻した色を確かめる
    static func testEffects(_ check: (Bool, String) -> Void) {
        // 画面下の状態表示：GPU の使用率・メモリ・CPU の刻みが読める
        let g = SystemMonitor.gpuUtilization(), m = SystemMonitor.memoryMB(), h = SystemMonitor.hostTicks()
        check(g != nil && (0...100).contains(g!) && m > 1 && (h?.total ?? 0) > 0,
              String(format: "状態表示：GPU %.0f%%・メモリ %.0f MB が読める", g ?? -1, m))
        let ctx = MetalContext.shared
        let W = 8
        func tex(_ f: (Int, Int) -> SIMD3<Float>) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: W, mipmapped: false)
            td.usage = [.shaderRead]
            let t = ctx.device.makeTexture(descriptor: td)!
            var px = [UInt8](repeating: 255, count: W * W * 4)
            for y in 0..<W { for x in 0..<W {
                let c = (f(x, y) * 255).rounded(.toNearestOrEven)
                let i = (y * W + x) * 4
                px[i] = UInt8(c.z); px[i + 1] = UInt8(c.y); px[i + 2] = UInt8(c.x)
            } }
            t.replace(region: MTLRegionMake2D(0, 0, W, W), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
            return t
        }
        /// 合成して読み戻す（x, y の色）
        func run(_ groups: [LayerGroup], _ comp: EffectStack = EffectStack(), compositor: Compositor? = nil,
                 now: Double = 0) -> (Int, Int) -> SIMD3<Float> {
            let c = compositor ?? { let c = Compositor(); c.storageMode = .shared; return c }()
            let cb = ctx.queue.makeCommandBuffer()!
            let t = c.composite(groups, effects: comp, width: W, height: W, cb: cb, now: now)!
            cb.commit(); cb.waitUntilCompleted()
            var out = [UInt8](repeating: 0, count: W * W * 4)
            t.getBytes(&out, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, W), mipmapLevel: 0)
            return { x, y in
                let i = (y * W + x) * 4
                return SIMD3(Float(out[i + 2]), Float(out[i + 1]), Float(out[i])) / 255
            }
        }
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ e: Float = 3.0 / 255) -> Bool { simd_reduce_max(simd_abs(a - b)) < e }
        func fx(_ k: EffectKind, _ v: [Double]) -> Effect { var e = Effect(kind: k); e.values = v; return e }
        /// カラーライズ（カラーモード）。色を色相（度）で
        func colorize(hue: Double, weighted: Bool = true, amount: Double = 1) -> Effect {
            var e = Effect(kind: .colorize); e.values = [0, weighted ? 1 : 0, amount]
            e.color = RGB.hsb(hue / 360, 1, 1); return e
        }
        func clip(_ t: MTLTexture, _ effects: [Effect] = []) -> LayerDraw {
            LayerDraw(texture: t, opacity: 1, blend: .normal, holder: nil, effects: EffectStack(effects: effects), effectKey: 0)
        }
        func group(_ d: LayerDraw, _ effects: [Effect] = [], opacity: Float = 1) -> LayerGroup {
            LayerGroup(draws: [d], opacity: opacity, blend: .normal, effects: EffectStack(effects: effects), key: 0)
        }
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        let halves = tex { x, _ in x < W / 2 ? red : blue }
        let grey = SIMD3<Float>(repeating: 0.5)

        // ミラー（クリップ）：左を右へ → 右半分も赤
        var r = run([group(clip(halves, [fx(.mirror, [1, 0])]))])
        check(near(r(1, 3), red) && near(r(6, 3), red), "ミラー（左を右へ）：右半分にも左の絵が映る")
        r = run([group(clip(halves, [fx(.mirror, [2, 0])]))])
        check(near(r(1, 3), blue) && near(r(6, 3), blue), "ミラー（右を左へ）")
        // カラーライズ：灰色 50% → 色相 0°・彩度 100% で赤
        r = run([group(clip(tex { _, _ in grey }, [colorize(hue: 0)]))])
        check(near(r(3, 3), red, 4.0 / 255), String(format: "カラーライズ（明るさを保つ）：灰色 → 赤（%.2f, %.2f, %.2f）", r(3, 3).x, r(3, 3).y, r(3, 3).z))
        r = run([group(clip(tex { _, _ in grey }, [colorize(hue: 0, amount: 0.5)]))])
        check(near(r(3, 3), SIMD3(0.75, 0.25, 0.25), 4.0 / 255), "カラーライズ：かかり具合 50%")
        // 明るさを保たない：黒は黒、灰色はその色の半分、白はその色そのもの
        let lumRamp = tex { x, _ in x < 3 ? .zero : (x < 6 ? grey : SIMD3(repeating: 1)) }
        r = run([group(clip(lumRamp, [colorize(hue: 240, weighted: false)]))])
        check(near(r(0, 0), .zero) && near(r(4, 0), SIMD3(0, 0, 0.5), 4.0 / 255) && near(r(7, 0), blue),
              "カラーライズ（明るさを保たない）：黒→黒、灰→色の半分、白→その色")
        // パレット：暗い所は左の色、明るい所は右の色、中間はあいだの色
        var pal = Effect(kind: .colorize); pal.values = [1, 1, 1]
        pal.palette = [.black, RGB(r: 1, g: 0, b: 0), RGB(r: 1, g: 1, b: 0)]
        r = run([group(clip(lumRamp, [pal]))])
        check(near(r(0, 0), .zero) && near(r(4, 0), red, 4.0 / 255) && near(r(7, 0), SIMD3(1, 1, 0)),
              "カラーライズ（パレット）：明るさでパレットの色に置き換わる（黒→赤→黄）")
        // 色相をずらす：赤を 120° ずらすと緑
        var hs = colorize(hue: 0); hs.values = [0, 1, 1, 120]
        r = run([group(clip(tex { _, _ in grey }, [hs]))])
        check(near(r(3, 3), SIMD3(0, 1, 0), 4.0 / 255), "カラーライズ：色相を 120° ずらすと赤 → 緑")

        // エフェクトの値のアニメーション：描画する時刻で値が変わる（色相を 4 秒で 0→360°）
        var ha = colorize(hue: 0)
        var anim = ha.anim(3); anim.mode = .time; anim.seconds = 4; anim.start = 100
        ha.setAnim(3, anim)
        ha.anims["3"]?.start = 100
        let st = EffectStack(effects: [ha])
        let c1 = run([group(clip(tex { _, _ in grey }, [ha]))], compositor: nil, now: 100.0)(3, 3)
        let atNow = { (t: Double) -> SIMD3<Float> in
            let comp = Compositor(); comp.storageMode = .shared
            let cb = ctx.queue.makeCommandBuffer()!
            var d = clip(tex { _, _ in grey }); d.effects = st
            let out = comp.composite([group(d)], effects: EffectStack(), width: W, height: W, cb: cb, now: t)!
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: W * W * 4)
            out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, W), mipmapLevel: 0)
            return SIMD3(Float(px[2]), Float(px[1]), Float(px[0])) / 255
        }
        let h0 = atNow(100.0), h1 = atNow(101.333), h2 = atNow(102.667)
        check(near(h0, red, 4.0 / 255) && near(h1, SIMD3(0, 1, 0), 6.0 / 255) && near(h2, blue, 6.0 / 255) && !c1.x.isNaN,
              "エフェクトの値を秒で動かす：色相が 赤 → 緑 → 青 と回る")
        var bt = Effect(kind: .posterizeTime)
        var ba = bt.anim(0); ba.mode = .beat; ba.beats = 4; ba.lo = 2; ba.hi = 10
        bt.setAnim(0, ba)
        let bst = EffectStack(effects: [bt], beat: BeatClock(bpm: 120, anchorHost: 0, anchorBeat: 0))
        check(abs((bst.posterizeFPS(at: 0) ?? 0) - 2) < 0.01 && abs((bst.posterizeFPS(at: 1) ?? 0) - 6) < 0.01,
              "エフェクトの値を BPM で動かす（ポスタライズ時間 2→10fps を 4 拍で）")
        let enc = try? JSONEncoder().encode(ha)
        let back = enc.flatMap { try? JSONDecoder().decode(Effect.self, from: $0) }
        check(back?.anim(3).mode == .time && back?.anim(3).seconds == 4, "エフェクトのアニメーション設定も保存される")

        // 以前の保存データ（色相・彩度・かかり具合）も読める
        let old = #"{"kind":"colorize","enabled":true,"values":[120,1,0.8]}"#
        let dec = try? JSONDecoder().decode(Effect.self, from: Data(old.utf8))
        check(dec?.values == [0, 1, 0.8, 0] && abs((dec?.color.g ?? 0) - 1) < 0.001 && (dec?.color.r ?? 1) < 0.001,
              "以前のカラーライズの設定（色相 120° など）を読み込める")
        // レベル：入力 25%〜75% → 0.375 は 0.25 に。ガンマ 2 で 0.5 → 0.707
        r = run([group(clip(tex { _, _ in SIMD3(repeating: 0.375) }, [fx(.levels, [0.25, 0.75, 1, 0, 1])]))])
        check(near(r(3, 3), SIMD3(repeating: 0.25), 4.0 / 255), String(format: "レベル：入力の黒・白（0.375 → %.3f）", r(3, 3).x))
        r = run([group(clip(tex { _, _ in grey }, [fx(.levels, [0, 1, 2, 0, 1])]))])
        check(near(r(3, 3), SIMD3(repeating: 0.7071), 4.0 / 255), String(format: "レベル：ガンマ 2（0.5 → %.3f）", r(3, 3).x))
        r = run([group(clip(tex { _, _ in grey }, [fx(.levels, [0, 1, 1, 0.2, 0.6])]))])
        check(near(r(3, 3), SIMD3(repeating: 0.4), 4.0 / 255), "レベル：出力の黒・白（0.5 → 0.4）")
        // ポスタライズ：2 段 → 0.4 は 0、0.6 は 1
        let ramp = tex { x, _ in SIMD3(repeating: Float(x) / Float(W - 1)) }
        r = run([group(clip(ramp, [fx(.posterize, [2, 0, 1])]))])
        check(near(r(2, 0), .zero) && near(r(5, 0), SIMD3(repeating: 1)), "ポスタライズ：2 段（暗い方は黒、明るい方は白）")
        // 並べ替え：ドラッグしたエフェクトを、落とした所のエフェクトの位置へ。一覧からなら、その位置に入れる
        final class TestHolder: EffectHolder { var effects: [Effect] = [] }
        let th = TestHolder()
        [EffectKind.mirror, .colorize, .levels].forEach { th.addEffect($0) }
        th.moveEffect(th.effects[0].id, to: 2)
        let o1 = th.effects.map(\.kind)
        th.moveEffect(th.effects[2].id, to: 0)
        let o2 = th.effects.map(\.kind)
        th.insertEffect(.strobe, at: 1)
        check(o1 == [.colorize, .levels, .mirror] && o2 == [.mirror, .colorize, .levels]
              && th.effects.map(\.kind) == [.mirror, .strobe, .colorize, .levels], "エフェクトの並べ替え（ドラッグ）と、位置を決めた追加")
        // エコー：前の絵が「残る長さ」（1 秒）で 1/100 まで薄まる。0.1 秒後は 0.01^0.1 = 0.63 倍
        let echo = Effect(kind: .echo)
        let black = tex { _, _ in .zero }
        let ec = Compositor(); ec.storageMode = .shared
        _ = run([group(clip(tex { _, _ in red }))], EffectStack(effects: [echo]), compositor: ec, now: 100)
        let e1 = run([group(clip(black))], EffectStack(effects: [echo]), compositor: ec, now: 100.1)(3, 3)
        let e2 = run([group(clip(black))], EffectStack(effects: [echo]), compositor: ec, now: 100.2)(3, 3)
        check(abs(e1.x - 0.631) < 0.02 && abs(e2.x - 0.398) < 0.02 && e1.z < 0.01,
              String(format: "エコー：消えた絵が残像になって時間で薄まる（%.3f → %.3f）", e1.x, e2.x))
        let e3 = run([group(clip(black))], EffectStack(effects: [echo]), compositor: ec, now: 101.5)(3, 3)
        check(e3.x < 0.01, "エコー：しばらく描かなかったら残像は残さない")
        // コマの間隔が違っても（プレビュー 30fps と出力 60fps）、同じ時刻には同じ濃さ
        let ec2 = Compositor(); ec2.storageMode = .shared
        _ = run([group(clip(tex { _, _ in red }))], EffectStack(effects: [echo]), compositor: ec2, now: 200)
        _ = run([group(clip(black))], EffectStack(effects: [echo]), compositor: ec2, now: 200.05)
        let e4 = run([group(clip(black))], EffectStack(effects: [echo]), compositor: ec2, now: 200.1)(3, 3)
        check(abs(e4.x - e1.x) < 0.02, "エコー：コマ数が違っても同じ速さで薄まる")
        // 混ぜる：今の絵（青）に前の絵（赤）が 63% 混ざる
        let mixE = fx(.echo, [2, 1, 0, 0, 1])
        let ec3 = Compositor(); ec3.storageMode = .shared
        _ = run([group(clip(tex { _, _ in red }))], EffectStack(effects: [mixE]), compositor: ec3, now: 300)
        let e5 = run([group(clip(tex { _, _ in blue }))], EffectStack(effects: [mixE]), compositor: ec3, now: 300.1)(3, 3)
        check(abs(e5.x - 0.631) < 0.03 && abs(e5.z - 0.369) < 0.03, "エコー（混ぜる）：今の絵と前の絵が混ざる")
        // クリップにかけたエコーは、そのクリップの絵の中で残る
        let ec4 = Compositor(); ec4.storageMode = .shared
        _ = run([group(clip(tex { _, _ in red }, [echo]))], compositor: ec4, now: 400)
        let e6 = run([group(clip(black, [echo]))], compositor: ec4, now: 400.1)(3, 3)
        check(abs(e6.x - 0.631) < 0.02, "エコー：クリップにかけても効く")
        // マスク（形）：真ん中の四角だけ残る。外は透明（黒地の上で黒）
        let redT = tex { _, _ in red }
        func shape(_ v: [Double]) -> Effect { fx(.shapeMask, v) }
        r = run([group(clip(redT, [shape([0, 0, 0, 0, 0.6, 0.6, 0, 0.02])]))])
        check(near(r(3, 3), red) && near(r(0, 0), .zero), "マスク（形・四角）：中だけ残って外は消える")
        r = run([group(clip(redT, [shape([0, 1, 0, 0, 0.6, 0.6, 0, 0.02])]))])
        check(near(r(3, 3), .zero) && near(r(0, 0), red), "マスク（形）：反転すると中が消える")
        let rr = run([group(clip(redT, [shape([0, 0, 0, 0, 0.8, 0.8, 0, 0.02])]))])(1, 1)
        let re = run([group(clip(redT, [shape([1, 0, 0, 0, 0.8, 0.8, 0, 0.02])]))])(1, 1)
        check(rr.x > 0.9 && re.x < 0.3, String(format: "マスク（形・丸）：四角では見える角が、丸では消える（%.2f → %.2f）", rr.x, re.x))
        r = run([group(clip(redT, [shape([0, 0, 0.25, 0, 0.3, 1, 0, 0])]))])
        check(near(r(5, 3), red) && near(r(1, 3), .zero), "マスク（形）：位置 X で右へ動く")
        r = run([group(clip(redT), [shape([0, 0, 0, 0, 0.5, 2, 0, 0])])])
        check(near(r(3, 3), red) && near(r(0, 3), .zero), "マスク（形）：レイヤーにかけても効く")
        // マスク（自由な形）：左半分の四角
        var poly = Effect(kind: .polyMask)
        poly.points = [MaskPoint(x: 0, y: 0), MaskPoint(x: 0.5, y: 0), MaskPoint(x: 0.5, y: 1), MaskPoint(x: 0, y: 1)]
        r = run([group(clip(redT, [poly]))])
        check(near(r(1, 3), red) && near(r(6, 3), .zero), "マスク（自由な形）：点で囲んだ所だけ残る")
        var polyInv = poly; polyInv.values[1] = 1
        r = run([group(clip(redT, [polyInv]))])
        check(near(r(1, 3), .zero) && near(r(6, 3), red), "マスク（自由な形）：反転すると囲んだ所が消える")
        var tri = Effect(kind: .polyMask)
        tri.points = [MaskPoint(x: 0, y: 0), MaskPoint(x: 1, y: 0), MaskPoint(x: 0, y: 1)]
        r = run([group(clip(redT, [tri]))])
        check(near(r(1, 1), red) && near(r(6, 6), .zero), "マスク（自由な形）：三角形")
        let saved = try? JSONDecoder().decode(Effect.self, from: JSONEncoder().encode(tri))
        check(saved?.points == tri.points, "マスク（自由な形）：点を保存して読み込める")
        let sqPts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        check(PolyMaskOverlay<Engine>.contains(sqPts, CGPoint(x: 5, y: 5)) && !PolyMaskOverlay<Engine>.contains(sqPts, CGPoint(x: 15, y: 5))
              && PolyMaskOverlay<Engine>.nearestEdge(sqPts, CGPoint(x: 11, y: 5)) == 1,
              "マスクの編集：中かどうか・クリックした所に近い辺（そこに点を足す）")
        // ジェネレーター：入力の絵は使わず、自分で描く
        let anyT = tex { _, _ in blue }
        var solid = Effect(kind: .solid); solid.color = RGB(r: 1, g: 0, b: 0)
        r = run([group(clip(anyT, [solid]))])
        check(near(r(3, 3), red) && near(r(0, 7), red), "ジェネレーター（単色）：全体がその色になる")
        var grad = Effect(kind: .gradient); grad.palette = [.black, .white]; grad.values = [0, 0, 1, 0]
        r = run([group(clip(anyT, [grad]))])
        check(r(0, 3).x < 0.2 && r(7, 3).x > 0.8 && r(3, 3).x > r(1, 3).x,
              String(format: "ジェネレーター（グラデーション）：左が暗く右が明るい（%.2f → %.2f）", r(0, 3).x, r(7, 3).x))
        var gradMove = grad; gradMove.values[3] = 0.5
        let gm0 = run([group(clip(anyT, [gradMove]))], now: 0)(4, 3), gm1 = run([group(clip(anyT, [gradMove]))], now: 0.5)(4, 3)
        check(abs(gm0.x - gm1.x) > 0.1, "ジェネレーター：速さを付けると時間で流れる")
        var stripes = Effect(kind: .stripes); stripes.values = [2, 0.5, 0, 0, 0]
        r = run([group(clip(anyT, [stripes]))])
        let lit = (0..<8).filter { r(3, $0).x > 0.5 }.count
        check(lit >= 3 && lit <= 5, "ジェネレーター（ストライプ）：しまの所だけ色、あいだは透明（\(lit)/8 行）")
        var checker = Effect(kind: .grid); checker.values = [0, 2, 0.15, 0]
        r = run([group(clip(anyT, [checker]))])
        check(abs(r(1, 1).x - r(5, 1).x) > 0.9 && abs(r(1, 1).x - r(1, 5).x) > 0.9, "ジェネレーター（チェッカー）：互い違い")
        r = run([group(clip(anyT, [Effect(kind: .noise)]))])
        var lo: Float = 1, hi: Float = 0
        for y in 0..<8 { for x in 0..<8 { lo = min(lo, r(x, y).x); hi = max(hi, r(x, y).x) } }
        check(hi - lo > 0.1, String(format: "ジェネレーター（ノイズ）：場所ごとに明るさが違う（%.2f〜%.2f）", lo, hi))
        r = run([group(clip(anyT, [Effect(kind: .shapes)]))])
        check(r(3, 3).x > 0.9 && near(r(0, 0), .zero), "ジェネレーター（図形）：真ん中に円、まわりは透明")
        // 横長の絵でも、数が 1 なら左右の端に隣の図形が出ない
        do {
            let wide = { () -> MTLTexture in
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 8, mipmapped: false)
                td.usage = [.shaderRead]
                return ctx.device.makeTexture(descriptor: td)!
            }()
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            let cb = ctx.queue.makeCommandBuffer()!
            let out = fxp.apply(EffectStack(effects: [Effect(kind: .shapes)]), to: wide, key: "w", cb: cb)
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 32 * 8 * 4)
            out.getBytes(&px, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 8), mipmapLevel: 0)
            let rowStart: Int = 4 * 32 * 4
            let edge: UInt8 = px[rowStart + 3]
            let mid: UInt8 = px[rowStart + 16 * 4 + 3]
            check(edge == 0 && mid > 200, "ジェネレーター（図形）：数 1 なら 1 つだけ（端に出ない）")
        }
        check(EffectKind.generators.allSatisfy { GeneratorThumbnail.image(Effect(kind: $0)) != nil }, "ジェネレーター：サムネイルを描ける")
        // ストロボ：BPM 120・間隔 1/2 拍（0.25 秒）・光る長さ 50% → 0〜0.125 秒は光る、0.125〜0.25 秒は元の絵
        let stb = Effect(kind: .strobe)
        let clock = BeatClock()
        check(stb.color == RGB.white && stb.strobeLevel(at: 0.05, beat: clock, origin: 0) == 1
              && stb.strobeLevel(at: 0.15, beat: clock, origin: 0) == 0
              && stb.strobeLevel(at: 0.30, beat: clock, origin: 0) == 1, "ストロボ（BPM）：拍に合わせて光る・戻るを繰り返す")
        var fast = clock; fast.bpm = 240
        check(stb.strobeLevel(at: 0.10, beat: fast, origin: 0) == 0, "ストロボ（BPM）：テンポを上げると間隔も短くなる")
        let sec = fx(.strobe, [0, 1, 3, 4, 0.5, 1, 0])
        check(sec.strobeLevel(at: 0.1, beat: clock, origin: 0) == 1 && sec.strobeLevel(at: 0.2, beat: clock, origin: 0) == 0
              && sec.strobeLevel(at: 10.1, beat: clock, origin: 10) == 1, "ストロボ（秒）：1 秒に 4 回")
        let sdec = fx(.strobe, [0, 0, 3, 8, 0.5, 0.8, 1])
        check(abs(sdec.strobeLevel(at: 0.0625, beat: clock, origin: 0) - 0.4) < 1e-6, "ストロボ：強さと残光（光ったあと弱まる）")
        r = run([group(clip(tex { _, _ in red }))], EffectStack(effects: [stb]), now: 0.05)
        let r2 = run([group(clip(tex { _, _ in red }))], EffectStack(effects: [stb]), now: 0.15)
        check(near(r(3, 3), SIMD3(repeating: 1)) && near(r2(3, 3), red), "ストロボ（色で光る）：光る間は白、間は元の絵")
        r = run([group(clip(tex { _, _ in red }, [fx(.strobe, [1, 0, 3, 8, 0.5, 1, 0])]))], now: 0.05)
        check(near(r(3, 3), .zero), "ストロボ（消える）：光る間は消える")
        r = run([group(clip(tex { _, _ in red }), [fx(.strobe, [2, 0, 3, 8, 0.5, 1, 0])])], now: 0.05)
        check(near(r(3, 3), SIMD3(0, 1, 1)), "ストロボ（反転）：レイヤーにかけても効く（赤 → シアン）")
        // 反転：赤 → シアン。半分なら灰色。明るさだけ・色だけ
        r = run([group(clip(tex { _, _ in red }, [fx(.invert, [0, 1])]))])
        check(near(r(3, 3), SIMD3(0, 1, 1)), "反転：色と明るさ（赤 → シアン）")
        r = run([group(clip(tex { _, _ in red }, [fx(.invert, [0, 0.5])]))])
        check(near(r(3, 3), SIMD3(repeating: 0.5)), "反転：かかり具合 50% なら元の絵との間")
        let lumOnly = run([group(clip(tex { _, _ in red }, [fx(.invert, [1, 1])]))])(3, 3)
        let colOnly = run([group(clip(tex { _, _ in red }, [fx(.invert, [2, 1])]))])(3, 3)
        check(lumOnly.x > 0.95 && abs(lumOnly.y - 0.575) < 0.05 && colOnly.x < 0.05 && abs(colOnly.y - 0.425) < 0.05,
              String(format: "反転：明るさだけ（暗い赤 → 明るい赤 %.2f,%.2f）・色だけ（赤 → 同じ明るさのシアン %.2f,%.2f）",
                     lumOnly.x, lumOnly.y, colOnly.x, colOnly.y))
        r = run([group(clip(tex { _, _ in red }), [fx(.invert, [0, 1])])], EffectStack(effects: [fx(.invert, [0, 1])]))
        check(near(r(3, 3), red), "反転：レイヤーとコンポジションで 2 回かけると元に戻る")
        // ディザ：灰色 50% を 2 段 → 白と黒が混ざって、平均はほぼ 50%
        r = run([group(clip(tex { _, _ in grey }, [fx(.posterize, [2, 1, 1])]))])
        var sum: Float = 0, whites = 0
        for y in 0..<W { for x in 0..<W { sum += r(x, y).x; if r(x, y).x > 0.5 { whites += 1 } } }
        check(whites > 16 && whites < 48 && abs(sum / Float(W * W) - 0.5) < 0.15,
              "ポスタライズ：ディザで白黒が混ざる（白 \(whites)/\(W * W) 点）")
        // ドット：大きさは 1080p での px。高さ 216 の絵なら 1/5 になる（20px → 4px ごとに同じ色）
        do {
            let S = 216
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: S, height: S, mipmapped: false)
            td.usage = [.shaderRead]
            let src = ctx.device.makeTexture(descriptor: td)!
            var px = [UInt8](repeating: 255, count: S * S * 4)
            for y in 0..<S { for x in 0..<S { let v = UInt8(x * 255 / (S - 1)); let i = (y * S + x) * 4; px[i] = v; px[i + 1] = v; px[i + 2] = v } }
            src.replace(region: MTLRegionMake2D(0, 0, S, S), mipmapLevel: 0, withBytes: px, bytesPerRow: S * 4)
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            let cb = ctx.queue.makeCommandBuffer()!
            let out = fxp.apply(EffectStack(effects: [fx(.posterize, [32, 0, 20])]), to: src, key: "t", cb: cb)
            cb.commit(); cb.waitUntilCompleted()
            var o = [UInt8](repeating: 0, count: S * S * 4)
            out.getBytes(&o, bytesPerRow: S * 4, from: MTLRegionMake2D(0, 0, S, S), mipmapLevel: 0)
            func at(_ x: Int, _ y: Int) -> UInt8 { o[(y * S + x) * 4] }
            check(at(40, 0) == at(43, 3) && at(40, 0) != at(44, 0),
                  "ポスタライズ：ドットは 1080p での大きさ（高さ 216 の絵で 20px → 4px ごと）")
        }
        // オフにしたエフェクトはかからない
        var off = fx(.mirror, [1, 0]); off.enabled = false
        r = run([group(clip(halves, [off]))])
        check(near(r(6, 3), blue), "オフにしたエフェクトはかからない")
        // 順番：カラーライズ → ポスタライズ と、ポスタライズ → カラーライズ で結果が違う
        let a1 = run([group(clip(tex { _, _ in SIMD3(repeating: 0.3) }, [colorize(hue: 120), fx(.posterize, [2, 0, 1])]))])(1, 1)
        let a2 = run([group(clip(tex { _, _ in SIMD3(repeating: 0.3) }, [fx(.posterize, [2, 0, 1]), colorize(hue: 120)]))])(1, 1)
        check(!near(a1, a2), "エフェクトは上から順にかかる（順番を変えると結果が変わる）")

        // レイヤーのエフェクト：レイヤーの絵全体にかかる。レイヤーの不透明度 50% もそのあとで
        r = run([group(clip(halves), [fx(.mirror, [1, 0])], opacity: 0.5)])
        check(near(r(6, 3), SIMD3(0.5, 0, 0), 4.0 / 255) && near(r(1, 3), SIMD3(0.5, 0, 0), 4.0 / 255),
              "レイヤーのエフェクト：レイヤー全体にかかり、不透明度 50% も効く")
        // 小さく置いたクリップ＋レイヤーのミラー：透明な部分は透明のまま
        var small = clip(tex { _, _ in red })
        small.transform = ClipTransform(x: -0.25, y: 0, scale: 0.5, rotation: 0, opacity: 1)
        r = run([group(small, [fx(.mirror, [1, 0])])])
        check(near(r(1, 3), red) && near(r(6, 3), red) && near(r(3, 0), .zero),
              "レイヤーのミラー：左に置いたクリップが右にも映り、周りは透明（下が見える）")
        // 調整レイヤー：下に重ねた絵全体にかかる。上のレイヤーにはかからない
        func adjust(_ effects: [Effect], opacity: Float = 1, key: Int = 5) -> LayerGroup {
            LayerGroup(draws: [], opacity: opacity, blend: .normal, effects: EffectStack(effects: effects), key: key,
                       isAdjustment: true)
        }
        r = run([group(clip(halves)), adjust([fx(.mirror, [1, 0])])])
        check(near(r(1, 3), red) && near(r(6, 3), red), "調整レイヤー：下のレイヤー全体にミラーがかかる")
        var topSmall = clip(tex { _, _ in SIMD3(0, 1, 0) })
        topSmall.transform = ClipTransform(x: 0.25, y: 0, scale: 0.5, rotation: 0, opacity: 1)
        var tg = group(topSmall); tg.key = 1
        r = run([group(clip(halves)), adjust([fx(.mirror, [1, 0])]), tg])
        check(near(r(1, 3), red) && near(r(6, 3), SIMD3(0, 1, 0)) && near(r(5, 0), red),
              "調整レイヤーより上のレイヤーには、エフェクトがかからない")
        r = run([group(clip(tex { _, _ in grey })), adjust([colorize(hue: 240, weighted: false)], opacity: 0.5)])
        check(near(r(3, 3), SIMD3(0.25, 0.25, 0.5), 4.0 / 255),
              String(format: "調整レイヤーの不透明度 50%%：かかり具合が半分（%.2f, %.2f, %.2f）", r(3, 3).x, r(3, 3).y, r(3, 3).z))
        let ca = Compositor(); ca.storageMode = .shared
        let pa = [fx(.posterizeTime, [2])]
        let a1c = run([group(clip(tex { _, _ in red })), adjust(pa)], compositor: ca, now: 30.1)(3, 3)
        let a2c = run([group(clip(tex { _, _ in blue })), adjust(pa)], compositor: ca, now: 30.3)(3, 3)
        let a3c = run([group(clip(tex { _, _ in blue })), adjust(pa)], compositor: ca, now: 30.6)(3, 3)
        check(near(a1c, red) && near(a2c, red) && near(a3c, blue), "調整レイヤーのポスタライズ時間：下のレイヤー全体のコマを間引く")

        // オーバードライブ加算：100% を超えた分を、にじみ・色相ずれに変える
        func od(_ halo: Double, _ hue: Double, _ soft: Double, _ d: LayerDraw, opacity: Float = 1) -> LayerGroup {
            var e = Effect(kind: .overdrive); e.values = [halo, 28, hue, 0, 14, soft]
            var g = LayerGroup(draws: [d], opacity: opacity, blend: .overdrive, key: 3)
            g.blendFX = EffectStack(effects: [e])
            return g
        }
        let g6 = SIMD3<Float>(repeating: 0.6)
        r = run([group(clip(tex { _, _ in g6 })), od(0, 0, 0, clip(tex { _, _ in g6 }))])
        check(near(r(3, 3), SIMD3(repeating: 1)), "オーバードライブ加算（にじみ・色相ずれ・抑えなし）：ふつうの加算と同じく 100% で止まる")
        r = run([group(clip(tex { _, _ in g6 })), od(0, 0, 0, clip(tex { _, _ in SIMD3(repeating: 0.2) }))])
        check(near(r(3, 3), SIMD3(repeating: 0.8), 4.0 / 255), "100% を超えない所は、ふつうの加算と同じ")
        r = run([group(clip(tex { _, _ in g6 })), od(0, 0, 0, clip(tex { _, _ in g6 }), opacity: 0.5)])
        check(near(r(3, 3), SIMD3(repeating: 0.9), 4.0 / 255), "レイヤーの不透明度も効く（0.6 + 0.6×50% = 0.9）")
        let r8 = SIMD3<Float>(0.8, 0.1, 0.1)
        r = run([group(clip(tex { _, _ in r8 })), od(0, 120, 0, clip(tex { _, _ in r8 }))])
        let hc = r(3, 3)
        check(hc.y > 0.3 || hc.z > 0.3, String(format: "色相ずれ：あふれた分だけ色が回る（赤 → %.2f, %.2f, %.2f）", hc.x, hc.y, hc.z))
        r = run([group(clip(tex { _, _ in g6 })), od(0, 0, 1, clip(tex { _, _ in g6 }))])
        check(r(3, 3).x < 0.99 && r(3, 3).x > 0.85, String(format: "白飛びの抑え：1.2 が白に張り付かず %.2f に", r(3, 3).x))
        var sq = clip(tex { _, _ in SIMD3(repeating: 1) })
        sq.transform = ClipTransform(x: 0, y: 0, scale: 0.25, rotation: 0, opacity: 1)
        let g4 = SIMD3<Float>(repeating: 0.4)
        let noHalo = run([group(clip(tex { _, _ in g4 })), od(0, 0, 0, sq)])(0, 0)
        let halo = run([group(clip(tex { _, _ in g4 })), od(2, 0, 0, sq)])(0, 0)
        check(near(noHalo, g4, 4.0 / 255) && halo.x > noHalo.x + 0.03,
              String(format: "にじみ：あふれた所のまわりまで明るくなる（端 %.2f → %.2f）", noHalo.x, halo.x))

        // 波紋：あふれた所のまわりの絵が揺れる（大きめの絵で確かめる）
        do {
            let N = 320
            func big(_ f: (Int, Int) -> SIMD3<Float>) -> MTLTexture {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: N, height: N, mipmapped: false)
                td.usage = [.shaderRead]
                let t = ctx.device.makeTexture(descriptor: td)!
                var px = [UInt8](repeating: 255, count: N * N * 4)
                for y in 0..<N { for x in 0..<N {
                    let c = (f(x, y) * 255).rounded(.toNearestOrEven); let i = (y * N + x) * 4
                    px[i] = UInt8(c.z); px[i + 1] = UInt8(c.y); px[i + 2] = UInt8(c.x)
                } }
                t.replace(region: MTLRegionMake2D(0, 0, N, N), mipmapLevel: 0, withBytes: px, bytesPerRow: N * 4)
                return t
            }
            // 下は縦じま（揺れると模様がずれて分かる）、上は真ん中の白い四角
            let stripes = big { x, _ in SIMD3(repeating: (x / 6) % 2 == 0 ? 0.25 : 0.55) }
            let white = big { _, _ in SIMD3(repeating: 1) }
            func render(_ ripple: Double, at t: Double) -> [UInt8] {
                var sq = LayerDraw(texture: white, opacity: 1, blend: .normal, holder: nil)
                sq.transform = ClipTransform(x: 0, y: 0, scale: 0.2, rotation: 0, opacity: 1)
                var e = Effect(kind: .overdrive); e.values = [0, 60, 0, ripple, 24, 0, 1.5, 120]
                var g = LayerGroup(draws: [sq], opacity: 1, blend: .overdrive, key: 3)
                g.blendFX = EffectStack(effects: [e])
                let c = Compositor(); c.storageMode = .shared
                let cb = ctx.queue.makeCommandBuffer()!
                let out = c.composite([LayerGroup(draws: [LayerDraw(texture: stripes, opacity: 1, blend: .normal, holder: nil)],
                                                  opacity: 1, blend: .normal, key: 0), g],
                                      effects: EffectStack(), width: N, height: N, cb: cb, now: t)!
                cb.commit(); cb.waitUntilCompleted()
                var px = [UInt8](repeating: 0, count: N * N * 4)
                out.getBytes(&px, bytesPerRow: N * 4, from: MTLRegionMake2D(0, 0, N, N), mipmapLevel: 0)
                return px
            }
            func diff(_ a: [UInt8], _ b: [UInt8]) -> Int {
                var n = 0
                for i in stride(from: 0, to: a.count, by: 4) where abs(Int(a[i]) - Int(b[i])) > 12 { n += 1 }
                return n
            }
            let calm = render(0, at: 10), rip = render(1, at: 10), later = render(1, at: 10.25)
            let changed = diff(calm, rip), moving = diff(rip, later)
            check(changed > N * N / 50 && moving > N * N / 100,
                  "波紋：あふれた所のまわりが揺れ（\(changed) 点）、時間とともに動く（\(moving) 点）")
        }

        // 大きさが違っても同じ見え方（プレビューと本番の出力）：小さく描いたものと、大きく描いて縮めたものを比べる
        do {
            func scene(_ Hh: Int) -> [Float] {
                let Ww = Hh * 16 / 9
                func t(_ f: (Float, Float) -> SIMD3<Float>) -> MTLTexture {
                    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Ww, height: Hh, mipmapped: false)
                    td.usage = [.shaderRead]
                    let tx = ctx.device.makeTexture(descriptor: td)!
                    var px = [UInt8](repeating: 255, count: Ww * Hh * 4)
                    for y in 0..<Hh { for x in 0..<Ww {
                        let c = (f(Float(x) / Float(Ww), Float(y) / Float(Hh)) * Float(255)).rounded(.toNearestOrEven); let i = (y * Ww + x) * 4
                        px[i] = UInt8(c.z); px[i + 1] = UInt8(c.y); px[i + 2] = UInt8(c.x)
                    } }
                    tx.replace(region: MTLRegionMake2D(0, 0, Ww, Hh), mipmapLevel: 0, withBytes: px, bytesPerRow: Ww * 4)
                    return tx
                }
                let below = t { x, y in SIMD3(repeating: 0.35 + 0.2 * sin(x * 20) * sin(y * 12)) }
                let top = t { x, y in
                    let dx = (x - 0.3) * 16 / 9, dy = y - 0.5
                    return dx * dx + dy * dy < 0.012 ? SIMD3(repeating: 1) : .zero
                }
                var e = Effect(kind: .overdrive); e.values = [1, 40, 60, 0.8, 24, 0.4, 1.5, 300]
                var g = LayerGroup(draws: [LayerDraw(texture: top, opacity: 1, blend: .overdrive, holder: nil)],
                                   opacity: 1, blend: .overdrive, key: 3)
                g.blendFX = EffectStack(effects: [e])
                let c = Compositor(); c.storageMode = .shared
                let cb = ctx.queue.makeCommandBuffer()!
                let out = c.composite([LayerGroup(draws: [LayerDraw(texture: below, opacity: 1, blend: .normal, holder: nil)],
                                                  opacity: 1, blend: .normal, key: 0), g],
                                      effects: EffectStack(), width: Ww, height: Hh, cb: cb, now: 10)!
                cb.commit(); cb.waitUntilCompleted()
                var px = [UInt8](repeating: 0, count: Ww * Hh * 4)
                out.getBytes(&px, bytesPerRow: Ww * 4, from: MTLRegionMake2D(0, 0, Ww, Hh), mipmapLevel: 0)
                // 48 x 27 のマスごとの平均にする
                var cells = [Float](repeating: 0, count: 48 * 27)
                for y in 0..<Hh { for x in 0..<Ww {
                    cells[(y * 27 / Hh) * 48 + x * 48 / Ww] += Float(px[(y * Ww + x) * 4 + 1]) / 255
                } }
                let n = Float(Ww * Hh) / Float(48 * 27)
                return cells.map { $0 / n }
            }
            let small = scene(270), large = scene(1080)
            let mad = zip(small, large).map { abs($0 - $1) }.reduce(0, +) / Float(small.count)
            check(mad < 0.03, String(format: "オーバードライブ加算：プレビュー（270p）と出力（1080p）で同じ見え方（平均の差 %.3f）", mad))
        }

        // コンポジションのエフェクト
        r = run([group(clip(tex { _, _ in grey }))], EffectStack(effects: [colorize(hue: 240)]))
        check(near(r(3, 3), blue, 4.0 / 255), "コンポジションのエフェクト：全体にかかる")

        // エフェクト一覧からの追加先
        let en = Engine(persistent: false)
        check(EffectKind.allCases.allSatisfy { EffectKind.fromDragString($0.dragString) == $0 }
              && EffectKind.fromDragString("/Users/x/a.mov") == nil, "ドラッグで運ぶ文字列からエフェクトに戻せる（ファイルは無視）")
        en.inspectorTab = .composition
        en.addEffectToCurrentTab(.mirror)
        en.selectedLayer = 2; en.inspectorTab = .layer
        en.addEffectToCurrentTab(.levels)
        en.inspectorTab = .clip
        let noClip = en.addEffectToCurrentTab(.posterize)
        check(en.effects.map(\.kind) == [.mirror] && en.layers[2].effects.map(\.kind) == [.levels] && !noClip,
              "ダブルクリックで今のタブ（コンポジション・レイヤー）に付く。クリップ未選択なら付かない")

        // 調整レイヤーを足す（エンジン）
        let ea = Engine(persistent: false)
        ea.insertAdjustmentLayer()
        check(ea.layerCount == 5 && ea.layers[0].isAdjustment && !ea.layers[0].audible && ea.selectedLayer == 0
              && ea.inspectorTab == .layer && ea.layerGroups().isEmpty,
              "調整レイヤーを一番上に足せる（エフェクトが無いうちは何もしない）")
        ea.layers[0].addEffect(.levels)
        let gs = ea.layerGroups()
        check(gs.count == 1 && gs[0].isAdjustment && gs[0].effects.effects.first?.kind == .levels,
              "調整レイヤーにエフェクトを付けると、描画に乗る")

        // ポスタライズ時間（コンポジション）：2 fps → 同じコマ（0.5 秒）の間は前の絵のまま
        let c = Compositor(); c.storageMode = .shared
        let pt = EffectStack(effects: [fx(.posterizeTime, [2])])
        let f1 = run([group(clip(tex { _, _ in red }))], pt, compositor: c, now: 10.1)(3, 3)
        let f2 = run([group(clip(tex { _, _ in blue }))], pt, compositor: c, now: 10.3)(3, 3)
        let f3 = run([group(clip(tex { _, _ in blue }))], pt, compositor: c, now: 10.6)(3, 3)
        check(near(f1, red) && near(f2, red) && near(f3, blue), "ポスタライズ時間（コンポジション）：2fps なら 0.5 秒ごとにしか変わらない")
        // ポスタライズ時間（レイヤー）
        let c2 = Compositor(); c2.storageMode = .shared
        let g1 = run([group(clip(tex { _, _ in red }), [fx(.posterizeTime, [4])])], compositor: c2, now: 5.01)(3, 3)
        let g2 = run([group(clip(tex { _, _ in blue }), [fx(.posterizeTime, [4])])], compositor: c2, now: 5.2)(3, 3)
        let g3 = run([group(clip(tex { _, _ in blue }), [fx(.posterizeTime, [4])])], compositor: c2, now: 5.26)(3, 3)
        check(near(g1, red) && near(g2, red) && near(g3, blue), "ポスタライズ時間（レイヤー）：4fps なら 0.25 秒ごと")
    }

    /// シーン：今の状態を保存して、切り替える（すぐ／フェード）
    /// 静止画：PNG・PDF・AI（PDF 互換）・SVG・PSD を読み、クリップとして出力に出せる
    static func testStillImages(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halovj-still-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 赤い 64×32 の絵（右半分は透明）
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let red = ctx.makeImage()!
        func write(_ name: String, _ type: String) -> URL? {
            let u = dir.appendingPathComponent(name)
            guard let d = CGImageDestinationCreateWithURL(u as CFURL, type as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(d, red, nil)
            return CGImageDestinationFinalize(d) ? u : nil
        }
        let png = write("a.png", "public.png")!
        let psd = write("a.psd", "com.adobe.photoshop-image")
        // PDF（AI も中身は PDF）
        let pdf = dir.appendingPathComponent("a.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        if let pc = CGContext(pdf as CFURL, mediaBox: &box, nil) {
            pc.beginPDFPage(nil)
            pc.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            pc.fill(box)
            pc.endPDFPage()
            pc.closePDF()
        }
        let ai = dir.appendingPathComponent("a.ai")
        try? FileManager.default.copyItem(at: pdf, to: ai)
        let svg = dir.appendingPathComponent("a.svg")
        try? "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\"><rect width=\"200\" height=\"100\" fill=\"#00ff00\"/></svg>"
            .write(to: svg, atomically: true, encoding: .utf8)

        let ip = StillImage.load(png), idoc = StillImage.load(pdf), iai = StillImage.load(ai), isvg = StillImage.load(svg)
        check(ip?.width == 64 && ip?.height == 32, "静止画：PNG を読める")
        check((idoc?.width ?? 0) >= 200 && idoc.map { abs(Double($0.width) / Double($0.height) - 2) < 0.02 } == true,
              "静止画：PDF を（くっきりするよう大きめに）読める")
        check(iai != nil, "静止画：AI（PDF 互換で保存したもの）を読める")
        check(isvg.map { abs(Double($0.width) / Double($0.height) - 2) < 0.02 } == true, "静止画：SVG を読める")
        if let psd { check(StillImage.load(psd)?.width == 64, "静止画：PSD（重ねた結果）を読める") }
        check(StillImage.isImage(ai) && StillImage.isImage(svg) && StillImage.isImage(png) && !StillImage.isImage(URL(fileURLWithPath: "/a.mov")),
              "静止画：拡張子で見分ける")
        // テクスチャ：左上（赤）と右上（透明）
        if let ip, let tex = StillImage.texture(ip) {
            var px = [UInt8](repeating: 0, count: 64 * 32 * 4)
            tex.getBytes(&px, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0)
            let l = Array(px[(16 * 64 + 8) * 4 ..< (16 * 64 + 8) * 4 + 4]), r = Array(px[(16 * 64 + 56) * 4 ..< (16 * 64 + 56) * 4 + 4])
            check(l == [0, 0, 255, 255] && r == [0, 0, 0, 0], "静止画：色と透明のまま描画用にできる（BGRA・乗算済み）")
        } else {
            check(false, "静止画：描画用にできる")
        }

        // クリップとして置いて出す
        let e = Engine(persistent: false)
        e.load(urls: [png], startingAt: 0)
        for _ in 0..<40 where e.slots[0]?.isReady != true { wait(0.05) }
        let slot = e.slots[0]
        check(slot?.isImage == true && slot?.isStill == true && slot?.isReady == true && slot?.thumbnail != nil,
              "静止画：クリップの枠に入れると、すぐ使える（サムネイル付き）")
        e.selectClip(0)
        check(e.previewDraws().first?.texture === slot?.stillTexture, "静止画：出力していなくてもプレビューに出る")
        e.trigger(0)
        _ = e.updateFrame()
        check(e.frame(layer: 0)?.texture === slot?.stillTexture && e.slots[0]?.isPlaying == true,
              "静止画：トリガーするとレイヤーに出る")
        let st = e.makeState(relativeTo: nil)
        let e2 = Engine(persistent: false)
        e2.apply(st, baseDir: nil)
        for _ in 0..<40 where e2.slots[0]?.isReady != true { wait(0.05) }
        check(e2.slots[0]?.isImage == true && e2.slots[0]?.stillTexture != nil, "静止画：保存して読み込める")
        let bad = dir.appendingPathComponent("bad.ai")
        try? "not a pdf".write(to: bad, atomically: true, encoding: .utf8)
        let b = ClipSlot(url: bad)
        for _ in 0..<20 where b.errorMessage == nil { wait(0.05) }
        check(b.errorMessage?.contains("PDF 互換") == true && !b.isReady, "静止画：読めない AI は、その理由を出す")

        // GIF アニメ：赤・緑・青を 0.2 秒ずつ
        let gif = dir.appendingPathComponent("anim.gif")
        if let d = CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 3, nil) {
            CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for (r, g, bl) in [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)] {
                let c = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.setFillColor(red: r, green: g, blue: bl, alpha: 1)
                c.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
                CGImageDestinationAddImage(d, c.makeImage()!,
                                           [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
            }
            CGImageDestinationFinalize(d)
        }
        let anim = StillImage.loadAnimation(gif)
        check(anim?.frames.count == 3 && anim.map { abs($0.duration - 0.6) < 0.01 } == true,
              "GIF アニメ：全コマと表示時間を読める")
        check(StillImage.loadAnimation(png) == nil, "GIF アニメ：1 コマの画像は動く画像として扱わない")
        let gs = ClipSlot(url: gif)
        for _ in 0..<40 where gs.isReady != true { wait(0.05) }
        // 真ん中の色（BGRA）
        func color(_ t: MTLTexture?) -> [UInt8] {
            guard let t else { return [] }
            var px = [UInt8](repeating: 0, count: 4)
            t.getBytes(&px, bytesPerRow: t.width * 4, from: MTLRegionMake2D(t.width / 2, t.height / 2, 1, 1), mipmapLevel: 0)
            return px
        }
        let rd: [UInt8] = [0, 0, 255, 255], gr: [UInt8] = [0, 255, 0, 255], bu: [UInt8] = [255, 0, 0, 255]
        check(gs.isAnimatedImage && abs(gs.animationDuration - 0.6) < 0.01, "GIF アニメ：クリップは動く画像になる")
        // 出力していないとき：読み込んだ時刻から動く。t は読み込みからの秒数
        let e3 = Engine(persistent: false)
        e3.load(urls: [gif], startingAt: 0)
        for _ in 0..<40 where e3.slots[0]?.isReady != true { wait(0.05) }
        guard let gslot = e3.slots[0] else { check(false, "GIF アニメ：クリップに入る"); return }
        e3.trigger(0)
        let o = gslot.animOrigin
        check(color(gslot.imageTexture(at: o + 0.1)) == rd && color(gslot.imageTexture(at: o + 0.3)) == gr
              && color(gslot.imageTexture(at: o + 0.5)) == bu && color(gslot.imageTexture(at: o + 0.7)) == rd,
              "GIF アニメ：再生すると、コマの表示時間どおりに進んでくり返す")
        // 速度 2 倍で頭から：0.15 秒後は 0.3 秒の所（緑）、0.25 秒後は 0.5 秒の所（青）
        gslot.speed = 2
        e3.trigger(0)
        let o2 = gslot.animOrigin
        check(color(gslot.imageTexture(at: o2 + 0.05)) == rd && color(gslot.imageTexture(at: o2 + 0.15)) == gr
              && color(gslot.imageTexture(at: o2 + 0.25)) == bu, "GIF アニメ：速度 2 倍なら 2 倍で進む")
        _ = e3.updateFrame()
        check(e3.frame(layer: 0) != nil, "GIF アニメ：レイヤーに出る")
    }

    /// ソース：フォルダの動画を読んで、サムネイルと長さを作る
    static func testSources(dir: URL, check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let (dirs, movies) = SourceBrowser.list(dir)
        check(movies.count >= 2 && movies.allSatisfy(SourceBrowser.isMovie) && !dirs.contains(where: SourceBrowser.isMovie),
              "ソース：フォルダの動画を一覧できる（\(movies.count) 本）")
        check(!SourceBrowser.isMovie(URL(fileURLWithPath: "/tmp/a.txt")) && SourceBrowser.isMovie(URL(fileURLWithPath: "/tmp/a.MP4")),
              "ソース：動画だけを並べる（拡張子の大文字小文字は問わない）")
        var got: SourceThumbs.Thumb?
        if let u = movies.first { SourceThumbs.shared.load(u) { got = $0 } }
        for _ in 0..<40 where got == nil { wait(0.1) }
        check((got?.frames.count ?? 0) == SourceThumbs.frameCount && (got?.duration ?? 0) > 1,
              "ソース：なぞって見る用のコマと長さを作れる")
    }

    /// 調整レイヤーの枠：エフェクトのクリップを置いて、押すとそのエフェクトが下の絵全体にかかる
    static func testEffectClips(check: (Bool, String) -> Void) {
        let e = Engine(persistent: false)
        e.insertAdjustmentLayer(at: 0)
        let c = e.columns
        e.layers[0].effects = [Effect(kind: .levels)]     // レイヤー自体のエフェクト（いつもかかる）
        check(e.createEffectClip(at: 0, with: .mirror) && e.createEffectClip(at: 1, with: .invert)
              && e.slots[0]?.isEffectClip == true && e.slots[0]?.name == "ミラー" && e.inspectedIndex == 1,
              "エフェクトのクリップ：調整レイヤーの空き枠に作れる（エフェクト名が名前になり、作ると選ばれる）")
        check(!e.createEffectClip(at: 0), "エフェクトのクリップ：埋まっている枠には作らない")
        e.slots[1]?.addEffect(.colorize)
        func adjFX() -> [EffectKind]? { e.layerGroups().first { $0.isAdjustment }?.effects.effects.map(\.kind) }
        check(adjFX() == [.levels], "エフェクトのクリップ：出していなければ、レイヤー自体のエフェクトだけ")
        e.trigger(0)
        check(adjFX() == [.levels, .mirror], "エフェクトのクリップ：押すと、そのエフェクトが下の絵全体にかかる")
        e.trigger(1)
        check(adjFX() == [.levels, .invert, .colorize] && e.activeByLayer[0] == 1, "エフェクトのクリップ：同じ段の別の枠で切り替わる")
        e.stopLayer(0)
        check(adjFX() == [.levels], "エフェクトのクリップ：空き枠（停止）で外れる")
        e.layers[0].effects = []
        check(adjFX() == nil, "エフェクトのクリップ：何もかけないときは何もしない")
        e.trigger(0)
        check(adjFX() == [.mirror], "エフェクトのクリップ：レイヤーにエフェクトが無くても、クリップのエフェクトだけかかる")
        // 名前・保存・複製
        e.slots[1]?.title = "ネガ"
        let e2 = Engine(persistent: false)
        e2.apply(e.makeState(relativeTo: nil), baseDir: nil)
        check(e2.slots[1]?.isEffectClip == true && e2.slots[1]?.name == "ネガ"
              && e2.slots[1]?.effects.map(\.kind) == [.invert, .colorize] && e2.layers[0].isAdjustment,
              "エフェクトのクリップ：名前とエフェクトを保存して読み込める")
        check(e.duplicateSlot(1, to: 2) && e.slots[2]?.isEffectClip == true && e.slots[2]?.name == "ネガ"
              && e.slots[2] !== e.slots[1], "エフェクトのクリップ：複製できる")
        _ = c
    }

    /// キュー：並べたものを GO で順に出す
    static func testCues(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.placeGenerator(.solid, at: 0)
        e.placeGenerator(.noise, at: c + 2)
        e.trigger(0)
        let sa = e.addScene()
        e.stopAll()
        e.addCue(.scene(sa.id))
        e.addClipCue(c + 2)
        e.addCue(.stopAll)
        e.updateCue(e.cues[0].id) { $0.fade = 0; $0.note = "司会のあと" }
        e.updateCue(e.cues[1].id) { $0.fade = 0 }
        check(e.cues.count == 3 && e.currentCue == nil && e.nextCue == 0, "キュー：並べた直後は、次が 1 番")
        check(e.goCue() && e.currentCue == 0 && e.activeByLayer[0] == 0 && e.nextCue == 1,
              "キュー：GO で 1 番（シーン）が出る")
        check(!e.goCue() && e.currentCue == 0, "キュー：GO の連打は少しの間受け付けない")
        e.lastGoHost = 0
        check(e.goCue() && e.currentCue == 1 && e.activeByLayer[1] == c + 2 && e.activeByLayer[0] == nil,
              "キュー：次の GO で 2 番（クリップ）が出る。クリップのキューはそのクリップだけ（ほかのレイヤーは止まる）")
        e.lastGoHost = 0
        check(e.goCue() && e.activeByLayer.allSatisfy { $0 == nil } && e.nextCue == nil, "キュー：3 番（全停止）で暗転。次は無い")
        e.lastGoHost = 0
        check(!e.goCue(), "キュー：最後まで行ったら GO しても何もしない")
        check(e.backCue() && e.currentCue == 1 && e.activeByLayer[1] == c + 2, "キュー：戻ると 1 つ前を出し直す")
        e.fireCue(0)
        check(e.currentCue == 0, "キュー：一覧から直接飛べる")
        // 「ほかのレイヤーはそのまま」
        e.trigger(0)
        e.updateCue(e.cues[1].id) { $0.keepOthers = true }
        e.fireCue(1)
        check(e.activeByLayer[0] == 0 && e.activeByLayer[1] == c + 2 && !e.cues[1].onlyThisClip,
              "キュー：「ほかのレイヤーはそのまま」なら、そのレイヤーだけ差し替える")
        e.updateCue(e.cues[1].id) { $0.keepOthers = nil }
        // 「終わったら」の上書き：キューで出したときだけ効き、クリップの設定は変えない
        if let clip = e.slots[c + 2] {
            clip.endAction = .loop
            e.updateCue(e.cues[1].id) { $0.endAction = .hold }
            e.fireCue(1)
            check(clip.currentEndAction == .hold && clip.endAction == .loop,
                  "キュー：「終わったら」をキューで上書きできる（クリップの設定はそのまま）")
            e.trigger(c + 2)
            check(clip.currentEndAction == .loop && clip.endActionOverride == nil,
                  "キュー：グリッドから普通に出し直すと、クリップ本来の「終わったら」に戻る")
            e.updateCue(e.cues[1].id) { $0.endAction = nil }
            e.fireCue(1)
            check(clip.currentEndAction == .loop, "キュー：上書きしていなければクリップの設定のまま")
            e.trigger(0)
        }
        // フェード付き：ほかのレイヤーは薄くなってから止まり、不透明度は元に戻る
        e.layers[0].opacity = 0.8
        e.updateCue(e.cues[1].id) { $0.fade = 0.3 }
        e.fireCue(1)
        wait(0.15)
        let midOp = e.layers[0].opacity
        let stillOn = e.activeByLayer[0] == 0
        wait(0.3)
        check(midOp < 0.75 && midOp > 0.05 && stillOn && e.activeByLayer[0] == nil && abs(e.layers[0].opacity - 0.8) < 1e-9,
              String(format: "キュー（クリップだけ・フェード）：ほかのレイヤーは薄くなって（%.2f）から止まり、不透明度は元に戻る", midOp))
        // 空のレイヤーにクリップを出す（ほかのキューから飛んだとき）：だんだん出てくる
        e.stopAll()
        e.layers[1].opacity = 0.9
        e.fireCue(1)
        wait(0.15)
        let inMid = e.layers[1].opacity
        wait(0.3)
        check(e.activeByLayer[1] == c + 2 && inMid > 0.05 && inMid < 0.85 && abs(e.layers[1].opacity - 0.9) < 1e-9,
              String(format: "キュー（クリップ・フェード）：レイヤーが空でも、だんだん出てくる（途中 %.2f → 0.90）", inMid))
        e.layers[1].opacity = 1
        e.trigger(0)
        // 消している途中に手で出し直したら、消すのをやめる
        e.trigger(0)
        e.fireCue(1)
        wait(0.1)
        e.trigger(0)
        wait(0.35)
        check(e.activeByLayer[0] == 0 && abs(e.layers[0].opacity - 0.8) < 1e-9, "キュー：消している途中に出し直したレイヤーは消さない")
        e.updateCue(e.cues[1].id) { $0.fade = 0 }
        e.layers[0].opacity = 1
        e.fireCue(0)
        // 並べ替え（つまみのドラッグ・上へ／下へ）：id のキューを index 番目の前へ
        do {
            let ids = e.cues.map(\.id)
            e.moveCue(ids[2], before: 0)
            check(e.cues.map(\.id) == [ids[2], ids[0], ids[1]], "キュー：最後の暗転を一番上へドラッグで動かせる")
            e.moveCue(ids[2], before: 3)
            check(e.cues.map(\.id) == ids, "キュー：一番下へ（最後の後ろ）も動かせる")
            e.moveCue(ids[0], before: 1)
            check(e.cues.map(\.id) == ids, "キュー：自分の直後へ落としても変わらない")
            e.insertCue(.scene(sa.id), at: 1)
            check(e.cues.count == 4 && e.cues[1].kind == .scene(sa.id), "キュー：シーンを一覧の途中へ落とすと、そこに入る")
            e.removeCue(e.cues[1].id)
            check(e.cueFadeText(e.cues[0]).contains("カット") && e.cueFadeText(Cue(kind: .scene(sa.id))).contains("シーンの設定"),
                  "キュー：フェードを決めていなければ、元の設定（シーン・レイヤー）の実際の時間を出す")
        }
        // 暗転にフェード：だんだん薄くなってから止まる
        do {
            e.trigger(0)
            let i = e.cues.firstIndex { $0.kind == .stopAll }!
            e.updateCue(e.cues[i].id) { $0.fade = 0.3 }
            e.fireCue(i)
            wait(0.15)
            let mid = e.layers[0].opacity, on = e.activeByLayer[0] != nil
            wait(0.3)
            check(on && mid < 0.9 && e.activeByLayer.allSatisfy { $0 == nil } && abs(e.layers[0].opacity - 1) < 1e-9,
                  "キュー（暗転・フェード 0.3 秒）：だんだん暗くなってから止まる")
            e.updateCue(e.cues[i].id) { $0.fade = nil }
            e.fireCue(0)
        }
        // 並べ替え・削除で「今」が付いてくる
        e.moveCue(from: IndexSet(integer: 0), to: 3)
        check(e.currentCue == 2 && e.cueTitle(e.cues[2]).contains("シーン"), "キュー：並べ替えても「今」の印は同じキューに付く")
        e.removeCue(e.cues[0].id)
        check(e.currentCue == 1 && e.cues.count == 2, "キュー：前のキューを消すと、番号がずれても「今」はそのまま")
        // レイヤーを足すとクリップのキューも付いていく
        e.cues = []
        e.addClipCue(c + 2)
        e.insertLayer(at: 0)
        if case .clip(_, let l, let col) = e.cues[0].kind {
            check(l == 2 && col == 2 && !e.cueTitle(e.cues[0]).contains("見つからない"), "キュー：レイヤーを足しても、クリップのキューは同じクリップを指す")
        }
        // クリップを動かしても、キューは同じクリップを指す（目印で探す）
        do {
            let clip = e.slots[e.cueClipIndex(e.cues[0])!]!
            let from = e.slots.firstIndex { $0 === clip }!
            let to = e.slotIndex(deck: 0, layer: 3, column: 5)
            e.moveSlot(from, to: to)
            check(e.cueClipIndex(e.cues[0]) == to && e.cueTitle(e.cues[0]) == clip.name,
                  "キュー：クリップをグリッドで動かしても、同じクリップを指す")
            let d2 = e.addDeck()
            e.showDeck(0)
            e.multiSelection = [to]
            _ = e.moveSelection(toDeck: d2)
            let moved = e.slotIndex(deck: d2, layer: 3, column: 5)
            check(e.cueClipIndex(e.cues[0]) == moved, "キュー：別のデッキへ移しても、同じクリップを指す")
            e.fireCue(0)
            check(e.activeByLayer[3] == moved, "キュー：動かした先のクリップが出る")
            e.clear(moved)
            check(e.cueClipIndex(e.cues[0]) == nil && e.cueTitle(e.cues[0]).contains("見つからない"),
                  "キュー：クリップを消すと「見つからない」（同じ場所の別のクリップは出さない）")
            e.cues.removeFirst()
            e.placeGenerator(.grid, at: c + 2)
            e.addClipCue(c + 2)
        }
        // 前に作ったキュー（目印が無い）は、読み込むと場所で探して目印を覚える
        do {
            var old = e.makeState(relativeTo: nil)
            old.cues = old.cues?.map { var x = $0; x.clipID = nil; return x }
            let o = Engine(persistent: false)
            o.apply(old, baseDir: nil)
            check(o.cues.first?.clipID != nil && o.cues.first?.clipID == o.slots[o.cueClipIndex(o.cues[0]) ?? 0]?.id,
                  "キュー：前に作ったクリップのキューも、読み込むと目印を覚える")
        }
        // 保存
        e.addCue(.scene(sa.id))
        let st = e.makeState(relativeTo: nil)
        let e2 = Engine(persistent: false)
        e2.apply(st, baseDir: nil)
        check(e2.cues == e.cues && e2.currentCue == nil, "キュー：保存して読み込める（「今」は最初から）")
    }

    /// レイヤーの移動：クリップ・再生中・設定ごと動き、シーンも付いてくる
    static func testMoveLayer(check: (Bool, String) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.placeGenerator(.solid, at: 0)            // L1
        e.placeGenerator(.noise, at: c + 1)        // L2
        e.placeGenerator(.stripes, at: 2 * c)      // L3
        e.trigger(0); e.trigger(c + 1)
        e.layers[0].opacity = 0.3
        e.layers[0].blend = .add
        let l0 = e.layers[0]
        let sc = e.addScene()
        l0.title = "背景"
        e.moveLayer(0, to: 2)
        check(e.layers[2].title == "背景" && e.layers[2].displayName == "L3 背景" && e.layers[0].displayName == "L1",
              "レイヤーの名前：番号は場所で変わり、付けた名前はレイヤーに付いていく")
        check(e.layers[2] === l0 && l0.index == 2 && abs(e.layers[2].opacity - 0.3) < 1e-9
              && e.slots[2 * c]?.generator?.kind == .solid && e.slots[c + 1 - c]?.generator?.kind == .noise
              && e.slots[c]?.generator?.kind == .stripes,
              "レイヤーの移動：クリップと設定ごと動き、ほかの段は詰まる")
        check(e.activeByLayer[2] == 2 * c && e.activeByLayer[0] == 1 && e.slots[2 * c]?.isPlaying == true,
              "レイヤーの移動：再生中のクリップは止まらずに付いていく")
        let s2 = e.scenes.first { $0.id == sc.id }
        check(s2?.playing[2] == 0 && s2?.playing[0] == 1 && s2?.playing[1] == nil
              && abs((s2?.layers[2].opacity ?? 0) - 0.3) < 1e-9 && s2?.layers[2].blend == BlendMode.add.rawValue,
              "レイヤーの移動：シーンの中身も同じように並べ替わる")
        e.updateScene(sc.id) { $0.fade = 0 }
        e.stopAll()
        e.recallScene(sc.id)
        check(e.activeByLayer[2] == 2 * c && e.activeByLayer[0] == 1 && abs(e.layers[2].opacity - 0.3) < 1e-9,
              "レイヤーの移動：動かしたあとにシーンを呼んでも、正しいレイヤーに出る")
        check(e.layers[2].title == "背景", "レイヤーの名前：シーンを呼んでも変わらない")
        let named = Engine(persistent: false)
        named.apply(e.makeState(relativeTo: nil), baseDir: nil)
        check(named.layers[2].title == "背景" && named.layers[0].title.isEmpty, "レイヤーの名前：保存して読み込める")
        // 足す・消すでもシーンが付いてくる
        e.insertLayer(at: 0)
        let s3 = e.scenes.first { $0.id == sc.id }
        check(s3?.playing.count == e.layers.count && s3?.playing[0] == nil && s3?.playing[3] == 0 && s3?.playing[1] == 1,
              "レイヤーを足すと、シーンの中身もずれる")
        e.removeLayer(0)
        let s4 = e.scenes.first { $0.id == sc.id }
        check(s4?.playing.count == e.layers.count && s4?.playing[2] == 0 && s4?.playing[0] == 1,
              "レイヤーを消すと、シーンの中身も詰まる")
    }

    /// グリッドの複数選択：⇧クリックで選んで、まとめて削除・移動
    static func testMultiSelect(check: (Bool, String) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.placeGenerator(.solid, at: 0)
        e.placeGenerator(.noise, at: 1)
        e.placeGenerator(.stripes, at: c)
        e.placeGenerator(.grid, at: 3)
        e.toggleMultiSelect(0); e.toggleMultiSelect(1); e.toggleMultiSelect(c); e.toggleMultiSelect(5)
        check(e.multiSelection == [0, 1, c], "選択：⇧クリックで足せる（空きの枠は選ばれない）")
        e.toggleMultiSelect(1)
        check(e.multiSelection == [0, c], "選択：もう一度で外れる")
        e.toggleMultiSelect(1)
        e.trigger(0)
        // 右へ 1 列ずらす → 3 列目は空いているので OK（4 列目のグリッドとはぶつからない）
        check(e.moveSelection(anchor: 0, to: 1), "選択：まとめて動かせる")
        check(e.slots[1]?.generator?.kind == .solid && e.slots[2]?.generator?.kind == .noise
              && e.slots[c + 1]?.generator?.kind == .stripes && e.slots[0] == nil && e.slots[c] == nil
              && e.activeByLayer[0] == 1 && e.multiSelection == [1, 2, c + 1],
              "選択：並びはそのままずれて、再生中のクリップは続き、選択も付いてくる")
        // もう 1 列右へは、4 列目（3）に選んでいないクリップがあるので動かない
        check(!e.moveSelection(anchor: 1, to: 2) && e.slots[1]?.generator?.kind == .solid,
              "選択：行き先に別のクリップがあれば動かさない")
        let bottom = e.slotIndex(deck: 0, layer: e.layers.count - 1, column: 1)
        check(!e.moveSelection(anchor: 1, to: bottom), "選択：グリッドからはみ出すなら動かさない")
        // 別のデッキへ
        let d2 = e.addDeck()
        e.showDeck(0)
        e.toggleMultiSelect(1); e.toggleMultiSelect(2); e.toggleMultiSelect(c + 1)
        let okMove = e.moveSelection(toDeck: d2)
        check(okMove && e.slots[e.slotIndex(deck: d2, layer: 0, column: 1)]?.generator?.kind == .solid
              && e.slots[e.slotIndex(deck: d2, layer: 1, column: 1)]?.generator?.kind == .stripes
              && e.slots[1] == nil && e.activeByLayer[0] == e.slotIndex(deck: d2, layer: 0, column: 1),
              "選択：別のデッキの同じ場所へ動かせる（再生中なら続く）")
        // 削除
        e.multiSelection = []
        for i in [e.slotIndex(deck: d2, layer: 0, column: 1), e.slotIndex(deck: d2, layer: 0, column: 2)] { e.toggleMultiSelect(i) }
        e.deleteSelection()
        check(e.slots[e.slotIndex(deck: d2, layer: 0, column: 1)] == nil && e.slots[e.slotIndex(deck: d2, layer: 0, column: 2)] == nil
              && e.activeByLayer[0] == nil && e.multiSelection.isEmpty
              && e.slots[e.slotIndex(deck: d2, layer: 1, column: 1)] != nil,
              "選択：まとめて削除（再生中なら止まる。選んでいないものは残る）")
        // デッキを切り替える・列を足すと選択は外れる
        e.toggleMultiSelect(3)
        e.showDeck(d2)
        check(e.multiSelection.isEmpty, "選択：表示するデッキを変えると外れる")
        e.showDeck(0)
        e.toggleMultiSelect(3)
        e.insertColumn(at: 0)
        check(e.multiSelection.isEmpty, "選択：グリッドの形を変えると外れる")

        // パッドの並び替え
        let a = e.pads[0].id, b = e.pads[2].id
        e.movePad(a, to: 2)
        check(e.pads[2].id == a && e.pads[1].id == b, "パッド：並び替えられる")
        e.movePad(a, to: 99)
        check(e.pads.last?.id == a, "パッド：端より先は端へ")
    }

    /// FX パッド：押している間だけ出力の最後にかかる。シーンとは無関係
    static func testPads(check: (Bool, String) -> Void) {
        let e = Engine(persistent: false)
        check(e.pads.count == Engine.defaultPadCount && e.padEffects().isEmpty, "パッド：最初は空のパッドが並ぶ")
        let p = e.pads[1]
        e.padDown(e.pads[0].id)
        check(e.padEffects().isEmpty, "パッド：空のパッドは押しても何もかからない")
        e.padUp(e.pads[0].id)
        p.addEffect(.strobe)
        p.addEffect(.mirror)
        check(e.padEffects().isEmpty, "パッド：押していなければかからない")
        let t0 = CACurrentMediaTime()
        e.padDown(p.id)
        let st = e.padEffects()
        check(st.count == 1 && st[0].effects.map(\.kind) == [.strobe, .mirror] && st[0].origin >= t0
              && e.effects.isEmpty, "パッド：押している間だけ、そのエフェクトが（押した時刻から）かかる。コンポジションには入らない")
        // シーンを呼んでも押している間は効いたまま
        e.placeGenerator(.solid, at: 0)
        e.trigger(0)
        let sc = e.addScene()
        e.updateScene(sc.id) { $0.fade = 0 }
        e.recallScene(sc.id)
        check(e.padEffects().count == 1, "パッド：シーンを切り替えても効いたまま")
        e.padUp(p.id)
        check(e.padEffects().isEmpty && e.heldPads.isEmpty, "パッド：離すと消える")
        p.name = "フラッシュ"
        e.addPad()
        let e2 = Engine(persistent: false)
        e2.apply(e.makeState(relativeTo: nil), baseDir: nil)
        check(e2.pads.count == Engine.defaultPadCount + 1 && e2.pads[1].name == "フラッシュ"
              && e2.pads[1].effects.map(\.kind) == [.strobe, .mirror] && e2.heldPads.isEmpty,
              "パッド：保存して読み込むと、並び・名前・エフェクトが戻る")

        // キーボード：1〜9・0 が並び順に付いていて、押している間だけ効く
        let k = Engine(persistent: false)
        check(k.pads.map { $0.key ?? "-" } == ["1", "2", "3", "4", "5", "6", "7", "8"], "パッド：最初はキー 1〜8 が付いている")
        k.pads[1].addEffect(.mirror)
        k.pads[2].addEffect(.strobe)
        let downed = k.padKeyDown(19)   // 2
        _ = k.padKeyDown(20)            // 3
        check(downed && k.padEffects().count == 2, "パッド：キーで同時に複数押せる")
        _ = k.padKeyUp(19)
        check(k.padEffects().count == 1 && k.padEffects()[0].effects.first?.kind == .strobe, "パッド：キーを離すとそのパッドだけ消える")
        k.releaseAllPads()
        check(k.padEffects().isEmpty, "パッド：アプリから離れたら全部離す")
        check(!k.padKeyDown(14), "パッド：割り当てのないキーは何もしない")
        k.setPadKey(k.pads[0].id, "2")
        check(k.pads[0].key == "2" && k.pads[1].key == nil, "パッド：キーを付け替えると、前のパッドからは外れる")
        k.setPadKey(k.pads[3].id, "q")
        let k2 = Engine(persistent: false)
        k2.apply(k.makeState(relativeTo: nil), baseDir: nil)
        check(k2.pads.map { $0.key ?? "-" } == ["2", "-", "3", "q", "5", "6", "7", "8"],
              "パッド：キーの割り当て（なしも）が保存される")

        // 効き始め・離したとき：だんだん効く・だんだん消える
        let f = Engine(persistent: false)
        let fp = f.pads[0]
        fp.addEffect(.invert)
        fp.attack = 1
        fp.release = 0.5
        f.padDown(fp.id)
        guard let pr = f.padEffects().first else { check(false, "パッド（効き始め）：押すと効く"); return }
        check(abs(pr.amount(at: pr.down + 0.25) - 0.25) < 1e-6 && abs(pr.amount(at: pr.down + 0.5) - 0.5) < 1e-6
              && pr.amount(at: pr.down + 2) == 1, "パッド（効き始め 1 秒）：0.25 秒で 25%、0.5 秒で 50%、1 秒で全開")
        f.padUp(fp.id)
        let rel = f.padEffects().first
        let rs = f.releasingPads[fp.id]
        check(rel != nil && rs != nil && f.heldPads.isEmpty, "パッド（離したとき 0.5 秒）：離しても、消え切るまでは効いている")
        if let rel, let rs {
            check(abs(rel.amount(at: rs.start + 0.25) - rs.from * 0.5) < 1e-6 && rel.amount(at: rs.start + 0.6) == 0,
                  "パッド（離したとき）：離したときの効き具合から 0.5 秒で 0 になる")
        }
        f.padDown(fp.id)
        let again = f.padEffects().first
        check(again?.release == nil && f.releasingPads.isEmpty && again.map { abs($0.amount(at: CACurrentMediaTime()) - (rs?.from ?? 0)) < 0.05 } == true,
              "パッド：消えている途中に押し直すと、今の効き具合から続けて上がる")
        f.padUp(fp.id)
        let st2 = f.makeState(relativeTo: nil)
        let f2 = Engine(persistent: false)
        f2.apply(st2, baseDir: nil)
        check(f2.pads[0].attack == 1 && f2.pads[0].release == 0.5 && f2.pads[1].attack == 0, "パッド：効き始め・離したときの秒数が保存される")
        // 混ぜる：赤と青を半分ずつ → 紫
        do {
            let ctx = MetalContext.shared
            func solid(_ b: UInt8, _ g: UInt8, _ r: UInt8) -> MTLTexture {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
                td.usage = [.shaderRead]
                td.storageMode = .shared
                let t = ctx.device.makeTexture(descriptor: td)!
                let px = [UInt8]((0..<16).flatMap { _ in [b, g, r, 255] })
                t.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: px, bytesPerRow: 16)
                return t
            }
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            let cb = ctx.queue.makeCommandBuffer()!
            let out = fxp.mix(solid(0, 0, 255), solid(255, 0, 0), k: 0.5, key: "m", cb: cb)
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 4)
            out.getBytes(&px, bytesPerRow: 16, from: MTLRegionMake2D(1, 1, 1, 1), mipmapLevel: 0)
            check(abs(Int(px[0]) - 128) <= 2 && abs(Int(px[2]) - 128) <= 2, "パッド：かける前と後を効き具合で混ぜる（赤＋青 50% → 紫）")
        }
    }

    /// デッキ：グリッドを何枚も持ち、シーンはデッキを覚える
    static func testDecks(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.placeGenerator(.solid, at: 0)
        e.placeGenerator(.noise, at: c + 1)
        e.trigger(0)
        let sa = e.addScene()
        // 空のデッキを足す → 表示が切り替わり、デッキ 1 のクリップは再生を続ける
        let d2 = e.addDeck()
        check(d2 == 1 && e.currentDeck == 1 && e.slots.count == 2 * e.gridSize && e.activeByLayer[0] == 0
              && e.slots[0] != nil && !e.deckHasClips(1),
              "デッキ：空のデッキを足すと表示が変わり、前のデッキのクリップは再生を続ける")
        let i2 = e.slotIndex(deck: 1, layer: 0, column: 2)
        e.placeGenerator(.stripes, at: i2)
        check(e.layerOf(i2) == 0 && e.deckOf(i2) == 1 && e.columnOf(i2) == 2, "デッキ：番号から段・列・デッキがわかる")
        e.trigger(i2)
        check(e.activeByLayer[0] == i2 && e.slots[0]?.isPlaying != true, "デッキ：別のデッキのクリップに切り替えられる（同じレイヤーの前のクリップは止まる）")
        let sb = e.addScene()
        check(sb.deck == e.decks[1].id && sb.playing[0] == 2 && sb.layerDecks == nil, "デッキ：シーンは保存したときのデッキを覚える")

        // シーン A（デッキ 1）を呼ぶとデッキ 1 の表示になり、そのクリップに戻る
        e.updateScene(sa.id) { $0.fade = 0 }
        e.recallScene(sa.id)
        check(e.currentDeck == 0 && e.activeByLayer[0] == 0, "デッキ：シーンを呼ぶと、そのデッキのグリッドとクリップになる")
        e.updateScene(sb.id) { $0.fade = 0 }
        e.recallScene(sb.id)
        check(e.currentDeck == 1 && e.activeByLayer[0] == i2, "デッキ：別のデッキのシーンへも切り替えられる")

        // 列を足してもデッキごとの位置はそのまま
        e.insertColumn(at: 0)
        let i2b = e.slotIndex(deck: 1, layer: 0, column: 3)
        check(e.slots[i2b]?.generator?.kind == .stripes && e.activeByLayer[0] == i2b
              && e.slots[e.slotIndex(deck: 0, layer: 1, column: 2)]?.generator?.kind == .noise,
              "デッキ：列を足しても各デッキのクリップの位置がずれない")
        e.removeColumn(0)

        // 複製・保存と読み込み
        let d3 = e.addDeck(duplicating: 0)
        check(d3 == 2 && e.slots[e.slotIndex(deck: 2, layer: 1, column: 1)]?.generator?.kind == .noise
              && e.slots[e.slotIndex(deck: 2, layer: 1, column: 1)] !== e.slots[e.slotIndex(deck: 0, layer: 1, column: 1)],
              "デッキ：複製すると同じ並びの別のクリップができる")
        e.renameDeck(1, to: "B")
        let st = e.makeState(relativeTo: nil)
        let e2 = Engine(persistent: false)
        e2.apply(st, baseDir: nil)
        check(e2.decks.map(\.name) == e.decks.map(\.name) && e2.decks.map(\.id) == e.decks.map(\.id)
              && e2.slots[e2.slotIndex(deck: 1, layer: 0, column: 2)]?.generator?.kind == .stripes
              && e2.slots[e2.slotIndex(deck: 2, layer: 1, column: 1)]?.generator?.kind == .noise
              && e2.currentDeck == e.currentDeck,
              "デッキ：保存して読み込むと、デッキの名前・中身・表示中のデッキが戻る")
        // 古い保存データ（デッキ無し）は 1 枚のデッキとして読む
        var old = st
        old.decks = nil
        old.slots = Array(st.slots.prefix(e.gridSize))
        let e3 = Engine(persistent: false)
        e3.apply(old, baseDir: nil)
        check(e3.decks.count == 1 && e3.slots[c + 1]?.generator?.kind == .noise, "デッキ：デッキの無い古いデータも読める")

        // 消す：再生中なら止まり、使っていたシーンは 1 枚目のデッキへ
        e.removeDeck(1)
        check(e.decks.count == 2 && e.activeByLayer[0] == nil && e.scenes.first { $0.id == sb.id }?.deck == nil
              && e.slots.count == 2 * e.gridSize && e.slots[e.slotIndex(deck: 1, layer: 1, column: 1)]?.generator?.kind == .noise,
              "デッキ：消すと中のクリップは止まって外れ、後ろのデッキが詰まる")
    }

    /// シーン：クリップを動かしても、同じクリップを流す（目印で探す）
    static func testSceneClipIDs(check: (Bool, String) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.placeGenerator(.solid, at: 0)
        e.placeGenerator(.noise, at: c + 1)
        e.placeGenerator(.stripes, at: 2)
        e.trigger(0); e.trigger(c + 1)
        let sc = e.addScene()
        check(sc.playingIDs?[0] == e.slots[0]?.id && sc.playingIDs?[1] == e.slots[c + 1]?.id,
              "シーン：流しているクリップの目印を覚える")
        let solid = e.slots[0]!
        e.stopAll()
        // 同じ段の中で動かす（元の場所には別のクリップを置く）
        e.moveSlot(0, to: 3)
        e.moveSlot(2, to: 0)
        e.updateScene(sc.id) { $0.fade = 0 }
        e.recallScene(sc.id)
        check(e.activeByLayer[0] == 3 && e.slots[3] === solid, "シーン：クリップを動かしても、同じクリップが出る（元の場所の別のクリップではなく）")
        // 別のデッキへ移す
        let d2 = e.addDeck()
        e.showDeck(0)
        e.stopAll()
        e.multiSelection = [3]
        _ = e.moveSelection(toDeck: d2)
        e.recallScene(sc.id)
        check(e.activeByLayer[0] == e.slotIndex(deck: d2, layer: 0, column: 3), "シーン：別のデッキへ移しても、同じクリップが出る")
        // シーンの編集でも、動かした先に表示され、選び直すと目印が変わる
        e.editScene(sc.id)
        check(e.viewPlaying(0) == e.slotIndex(deck: d2, layer: 0, column: 3), "シーンの編集：動かしたクリップは、動かした先に表示される")
        e.pressSlot(0)
        check(e.scenes.first { $0.id == sc.id }?.playingIDs?[0] == e.slots[0]?.id, "シーンの編集：クリップを選ぶと、その目印を覚える")
        e.closeSceneEditor()
        // 前のシーン（目印が無い）は読み込むと、場所で探して目印を覚える
        var old = e.makeState(relativeTo: nil)
        old.scenes = old.scenes?.map { var x = $0; x.playingIDs = nil; return x }
        let o = Engine(persistent: false)
        o.apply(old, baseDir: nil)
        check(o.scenes.first?.playingIDs?[0] == o.slots[0]?.id && o.scenes.first?.playingIDs?[0] != nil,
              "シーン：前に作ったシーンも、読み込むと目印を覚える")
    }

    /// シーンの編集：グリッド・レイヤー欄・下のパネルがそのシーンになり、出力はそのまま
    static func testSceneEdit(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.placeGenerator(.solid, at: 0)
        e.placeGenerator(.noise, at: 1)
        e.placeGenerator(.stripes, at: c)
        e.trigger(0)
        e.layers[0].opacity = 0.5
        let a = e.addScene()
        // 出力は別の状態（L1 ノイズ・L2 ストライプ）
        e.trigger(1)
        e.trigger(c)
        e.layers[0].opacity = 1
        e.editScene(a.id)
        guard let d = e.sceneDraft else { check(false, "シーンの編集：編集を始められる"); return }
        check(e.editingSceneID == a.id && e.viewPlaying(0) == 0 && e.viewPlaying(1) == nil
              && abs(e.viewLayer(0).opacity - 0.5) < 1e-9 && e.viewLayer(0) !== e.layers[0],
              "シーンの編集：グリッドとレイヤー欄がシーンの中身（流すクリップ・不透明度）になる")

        // グリッドのクリップを押す → シーンに入るだけで、出力は変わらない
        e.pressSlot(1)
        e.pressSlot(c)
        e.viewLayer(0).opacity = 0.3
        e.viewLayer(1).effects = [Effect(kind: .mirror)]
        e.selectedLayer = 1
        e.inspectorTab = .layer
        _ = e.addEffectToCurrentTab(.colorize)
        e.inspectorTab = .composition
        _ = e.addEffectToCurrentTab(.posterize)
        let sc = e.scenes.first { $0.id == a.id }
        check(sc?.playing[0] == 1 && sc?.playing[1] == 0 && abs((sc?.layers[0].opacity ?? 0) - 0.3) < 1e-9
              && sc?.layers[1].effects?.map(\.kind) == [.mirror, .colorize] && sc?.compEffects.map(\.kind) == [.posterize],
              "シーンの編集：クリップを押す・値を変える・エフェクトを付けると、すぐシーンに入る")
        check(abs(e.layers[0].opacity - 1) < 1e-9 && e.layers[1].effects.isEmpty && e.activeByLayer[0] == 1
              && e.activeByLayer[1] == c && e.effects.isEmpty && e.slots[0]?.isPlaying != true,
              "シーンの編集：出力（レイヤー・再生中のクリップ・コンポジション）はそのまま")
        e.viewStop(1)
        check(e.scenes.first { $0.id == a.id }?.playing[1] == nil && e.activeByLayer[1] == c,
              "シーンの編集：停止ボタンはシーンのそのレイヤーを「なし」にするだけ")
        e.pressSlot(c)

        // プレビュー：L1 は出力中と同じノイズ → 出力のフレーム、L2 は出力中のストライプ
        e.pressSlot(0)
        _ = e.updateFrame()
        wait(0.1)
        _ = e.updateFrame()
        let g1 = e.scenePreviewGroups()
        check(g1 != nil && g1?.groups.count == 2 && abs(Double(g1?.groups.first { $0.key == 0 }?.opacity ?? 0) - 0.3) < 1e-6
              && g1?.effects.effects.map(\.kind) == [.posterize],
              "シーンの編集：プレビューにはシーンの中身（出力していないクリップも）が映る")
        e.selectedLayer = 0
        check(e.layerPreviewGroups().count == 1, "シーンの編集：レイヤーのプレビューはシーンのそのレイヤー")

        // デッキ：編集中のタブ切り替えはシーンのデッキになり、出力の表示デッキは変わらない
        let d2 = e.addDeck()
        let i2 = e.slotIndex(deck: d2, layer: 2, column: 0)
        e.placeGenerator(.grid, at: i2)
        e.pressSlot(i2)
        let sc2 = e.scenes.first { $0.id == a.id }
        check(e.currentDeck == 0 && e.shownDeck == d2 && sc2?.deck == e.decks[d2].id && sc2?.playing[2] == 0
              && sc2?.layerDecks?[0] == e.decks[0].id && e.activeByLayer[2] == nil,
              "シーンの編集：デッキを切り替えてクリップを選ぶと、シーンのデッキとクリップになる（出力は別）")
        e.closeSceneEditor()
        e.updateScene(a.id) { $0.fade = 0 }
        e.recallScene(a.id)
        check(e.currentDeck == d2 && e.activeByLayer[0] == 0 && e.activeByLayer[1] == c && e.activeByLayer[2] == i2,
              "シーンの編集：編集したシーンを呼ぶと、その通りに出る")

        // 上書き → 編集中の中身も読み直す。削除 → 編集を終える
        e.editScene(a.id)
        e.layers[0].opacity = 0.8
        e.overwriteScene(a.id)
        check(e.sceneDraft.map { abs($0.layers[0].opacity - 0.8) < 1e-9 } == true,
              "シーンの編集：今の状態で上書きすると編集中の中身も変わる")
        e.deleteScene(a.id)
        check(e.sceneDraft == nil && e.scenePreviewGroups() == nil && e.viewLayer(0) === e.layers[0],
              "シーンの編集：シーンを消すと編集も終わり、画面は出力の状態に戻る")

        // 空のシーン：何も流さず、すぐ編集。出力はそのまま
        let live = e.activeByLayer
        let em = e.addEmptyScene()
        check(e.editingSceneID == em.id && em.playing.allSatisfy { $0 == nil } && em.compEffects.isEmpty
              && em.layers.count == e.layers.count && em.deck == e.decks[e.shownDeck].id && e.activeByLayer == live
              && e.activeSceneID != em.id && e.scenes.last?.id == em.id,
              "シーン：空のシーンを足すと、何も流さないシーンの編集が始まる（出力はそのまま）")
        e.pressSlot(1)
        check(e.scenes.last?.playing[0] == 1 && e.activeByLayer == live, "シーン：空のシーンにグリッドでクリップを入れられる")
        _ = d
    }

    static func testScenes(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.placeGenerator(.solid, at: 0)
        e.placeGenerator(.noise, at: 1)
        e.placeGenerator(.stripes, at: c)
        // シーン A：レイヤー 1 は単色・不透明度 50%、レイヤー 2 は止める、コンポジションにミラー
        e.trigger(0)
        e.layers[0].opacity = 0.5
        e.layers[0].blend = .add
        e.effects = [Effect(kind: .mirror)]
        var lv = Effect(kind: .levels); lv.values = [0, 1, 1, 0, 1]
        e.layers[0].effects = [lv]
        let a = e.addScene()
        // シーン B：レイヤー 1 はノイズ・100%、レイヤー 2 はストライプ、エフェクトなし
        e.trigger(1)
        e.trigger(c)
        e.layers[0].opacity = 1
        e.layers[0].blend = .normal
        e.effects = []
        var lv2 = lv; lv2.values = [0.4, 1, 1, 0, 1]
        e.layers[0].effects = [lv2]
        let b = e.addScene()
        check(e.scenes.count == 2 && a.playing.first == 0 && a.playing.count > 1 && a.playing[1] == nil && b.playing[1] == 0
              && e.activeSceneID == b.id, "シーン：再生中のクリップと設定を保存できる")

        e.updateScene(a.id) { $0.fade = 0 }
        e.recallScene(a.id)
        check(e.activeByLayer[0] == 0 && e.activeByLayer[1] == nil && abs(e.layers[0].opacity - 0.5) < 1e-9
              && e.layers[0].blend == .add && e.effects.map(\.kind) == [.mirror] && e.activeSceneID == a.id,
              "シーン（すぐ）：クリップ・止めるレイヤー・不透明度・重ね方・エフェクトがそのシーンになる")
        e.updateScene(b.id) { $0.fade = 0 }
        e.recallScene(b.id)
        let origin = e.slots[1]?.animOrigin ?? -1
        wait(0.05)
        e.recallScene(b.id)
        check(e.activeByLayer[0] == 1 && e.activeByLayer[1] == c && e.slots[1]?.animOrigin == origin,
              "シーン：同じクリップは頭から出し直さずに続ける")

        // フェード 0.4 秒：途中は値が間、終わればシーンの値。止めるレイヤーはフェードしてから止まる
        e.updateScene(a.id) { $0.fade = 0.4 }
        e.recallScene(a.id)
        wait(0.2)
        let mid = e.layers[0].opacity
        let midLevel = e.layers[0].effects.first?.value(0) ?? -1
        let stillPlaying = e.activeByLayer[1] == c
        let midL2 = e.layers[1].opacity
        wait(0.4)
        check(mid > 0.55 && mid < 0.95 && midLevel > 0.05 && midLevel < 0.35 && stillPlaying && midL2 < 0.95,
              String(format: "シーン（フェード）：途中は不透明度 %.2f・エフェクトの値 %.2f と間の値、消えるレイヤーは薄くなりつつ再生中", mid, midLevel))
        check(abs(e.layers[0].opacity - 0.5) < 1e-9 && e.activeByLayer[1] == nil && abs(e.layers[1].opacity - 1) < 1e-9
              && e.sceneProgress == nil && e.layers[0].blend == .add,
              "シーン（フェード）：終わるとシーンの値になり、消えたレイヤーは止まって不透明度は元に戻る")

        // エフェクトの混ぜ方：同じ並びなら値を混ぜ、違えば半分で入れ替える
        let mixed = Engine.mixEffects([lv], [lv2], k: 0.5, p: 0.5)
        let swapA = Engine.mixEffects([lv], [Effect(kind: .mirror)], k: 0.3, p: 0.3)
        let swapB = Engine.mixEffects([lv], [Effect(kind: .mirror)], k: 0.7, p: 0.7)
        check(abs((mixed.first?.value(0) ?? 0) - 0.2) < 1e-9 && swapA.first?.kind == .levels && swapB.first?.kind == .mirror,
              "シーン：同じエフェクトは値をなめらかに、違うエフェクトは途中で入れ替え")

        let st = e.makeState(relativeTo: nil)
        let e2 = Engine(persistent: false)
        e2.apply(st, baseDir: nil)
        check(e2.scenes.map(\.name) == e.scenes.map(\.name) && e2.scenes.first?.fade == 0.4,
              "シーンを保存して読み込める")
        e2.recallScene(e2.scenes[0].id)
        wait(0.6)
        check(e2.activeByLayer[0] == 0 && abs(e2.layers[0].opacity - 0.5) < 1e-9, "読み込んだシーンに切り替えられる")
        e.deleteScene(a.id)
        check(e.scenes.map(\.id) == [b.id], "シーンを削除できる")

        // サムネイル：出力の合成を小さな PNG にする（赤い絵 → 赤い画像）
        let ctx = MetalContext.shared
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 36, mipmapped: false)
        td.usage = [.shaderRead]
        let redTex = ctx.device.makeTexture(descriptor: td)!
        let px = [UInt8](repeating: 0, count: 64 * 36 * 4).enumerated().map { $0.offset % 4 == 2 || $0.offset % 4 == 3 ? 255 : 0 } as [UInt8]
        redTex.replace(region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: px, bytesPerRow: 64 * 4)
        let old = RenderLoop.shared.lastComposite()
        RenderLoop.shared.setLastCompositeForTest(redTex)
        let png = RenderLoop.shared.snapshotPNG()
        RenderLoop.shared.setLastCompositeForTest(old)
        let rep = png.flatMap { NSBitmapImageRep(data: $0) }
        let c0 = rep?.colorAt(x: 96, y: 54)
        check(rep?.pixelsWide == 192 && (c0?.redComponent ?? 0) > 0.9 && (c0?.blueComponent ?? 1) < 0.1,
              "シーンのサムネイル：出力の今の絵を小さな画像にする")
    }

    /// ジェネレーターのクリップ：置く・再生する・複製・保存して読み込む
    static func testGeneratorSlots(check: (Bool, String) -> Void) {
        let e = Engine(persistent: false)
        let placed = e.placeGenerator(.solid, at: 0)
        e.slots[0]?.generator?.color = RGB(r: 0, g: 1, b: 0)
        check(placed && e.slots[0]?.isGenerator == true && e.slots[0]?.isReady == true && e.slots[0]?.name == "単色"
              && !e.placeGenerator(.mirror, at: 1), "ジェネレーターをクリップの枠に置ける（エフェクトは置けない）")
        e.trigger(0)
        e.updateFrame()
        let f = e.frame(layer: 0)
        check(f != nil && f?.texture.height == 1080 && f?.pixelBuffer == nil, "ジェネレーターを再生すると、描いた絵がレイヤーに出る")
        check(e.duplicateSlot(0, to: 1) && e.slots[1]?.generator?.kind == .solid && e.slots[1]?.generator?.color.g == 1,
              "ジェネレーターを複製できる（設定ごと）")
        let state = e.makeState(relativeTo: nil)
        let e2 = Engine(persistent: false)
        e2.apply(state, baseDir: nil)
        check(e2.slots[0]?.generator?.kind == .solid && e2.slots[0]?.generator?.color.g == 1 && e2.slots[0]?.isMissing == false
              && e2.missingCount == 0, "ジェネレーターを保存して読み込める（「見つからない動画」にならない）")
        e.selectedLayer = 1
        let ok = e.placeGeneratorInSelectedLayer(.noise)
        check(ok && e.slots[e.columns]?.generator?.kind == .noise && e.inspectedIndex == e.columns,
              "ダブルクリック：選択中のレイヤーの空いている所に置いて選ぶ")
    }

    /// ポスタライズ時間（クリップ）：フレームの更新が指定のフレームレートまで減る
    static func testClipPosterizeTime(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
        let t0 = CACurrentMediaTime()
        while e.slots[0]?.isReady != true && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
        var pt = Effect(kind: .posterizeTime); pt.values = [5]
        e.slots[0]!.effects = [pt]
        e.trigger(0)
        var changes = 0
        var last: ObjectIdentifier?
        let ts = CACurrentMediaTime()
        while CACurrentMediaTime() - ts < 1.0 {
            e.updateFrame()
            if let f = e.frame(layer: 0) {
                let id = ObjectIdentifier(f)
                if id != last { changes += 1; last = id }
            }
            wait(1.0 / 120.0)
        }
        check(changes >= 4 && changes <= 7, "ポスタライズ時間（クリップ）：5fps → 1 秒で \(changes) コマ")
        e.slots[0]!.effects = []
        changes = 0
        let ts2 = CACurrentMediaTime()
        while CACurrentMediaTime() - ts2 < 0.5 {
            e.updateFrame()
            if let f = e.frame(layer: 0) {
                let id = ObjectIdentifier(f)
                if id != last { changes += 1; last = id }
            }
            wait(1.0 / 120.0)
        }
        check(changes >= 10, "ポスタライズ時間を外すと元のフレームレートに戻る（0.5 秒で \(changes) コマ）")
        e.stopAll()
    }

    static func testProject(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vjtest-\(UUID().uuidString)")
        let p1 = root.appendingPathComponent("show1"), p2 = root.appendingPathComponent("show2")
        try? fm.createDirectory(at: p1.appendingPathComponent("media"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let inside = p1.appendingPathComponent("media/clipA.mov")
        try? fm.copyItem(at: URL(fileURLWithPath: paths[0]), to: inside)
        func ready(_ e: Engine, _ i: Int) {
            let t0 = CACurrentMediaTime()
            while e.slots[i]?.isReady != true && e.slots[i]?.isMissing != true && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
        }

        let e = Engine(persistent: false)
        e.insertColumn(at: 8)
        e.load(urls: [inside], startingAt: 0)
        e.load(urls: [URL(fileURLWithPath: paths[1])], startingAt: e.columns + 1)
        ready(e, 0); ready(e, e.columns + 1)
        let s0 = e.slots[0]!
        s0.scale = 0.5
        s0.setInOut(in: 1, out: .some(5))   // 読み込み時に範囲を整えても「未保存」にならないことも確かめる
        s0.addEffect(.mirror)
        var rot = s0.anim(.rotation); rot.mode = .beat; s0.setAnim(.rotation, rot)
        e.layers[1].opacity = 0.3
        e.bpm = 140
        check(e.isDirty, "変更すると「未保存」になる")
        let file1 = p1.appendingPathComponent("show.halovj")
        do { try e.saveProject(to: file1) } catch { check(false, "保存できない \(error)") }
        let text = (try? String(contentsOf: file1, encoding: .utf8)) ?? ""
        check(!e.isDirty && e.projectURL == file1 && text.contains("\"relPath\" : \"media\\/clipA.mov\""),
              "プロジェクトを保存：未保存の印が消え、フォルダの中の動画はそこからの場所でも書かれる")

        // フォルダごと別の場所へ動かしてから開く
        try? fm.moveItem(at: p1, to: p2)
        let e2 = Engine(persistent: false)
        do { try e2.openProject(p2.appendingPathComponent("show.halovj")) } catch { check(false, "開けない \(error)") }
        ready(e2, 0); ready(e2, e2.columns + 1)
        wait(0.3)
        let o0 = e2.slots[0]
        check(e2.columns == 9 && o0?.url.path == p2.appendingPathComponent("media/clipA.mov").path && o0?.isReady == true
              && o0?.scale == 0.5 && o0?.effects.first?.kind == .mirror && o0?.anim(.rotation).mode == .beat
              && abs(e2.layers[1].opacity - 0.3) < 0.001 && abs(e2.bpm - 140) < 0.001
              && e2.slots[e2.columns + 1]?.isReady == true && !e2.isDirty && o0?.inPoint == 1,
              "フォルダごと動かしても開ける（動画・設定・グリッド・BPM が戻る）")

        // 動画が無い場所で開く → 見つからないクリップとして置かれ、フォルダを選ぶと付け直せる
        let p3 = root.appendingPathComponent("elsewhere")
        try? fm.createDirectory(at: p3, withIntermediateDirectories: true)
        try? fm.copyItem(at: p2.appendingPathComponent("show.halovj"), to: p3.appendingPathComponent("show.halovj"))
        let e3 = Engine(persistent: false)
        try? e3.openProject(p3.appendingPathComponent("show.halovj"))
        ready(e3, 0)
        check(e3.slots[0]?.isMissing == true && e3.missingCount == 1 && e3.slots[0]?.scale == 0.5,
              "動画が見つからないときは「見つかりません」のクリップとして設定ごと置かれる")
        let n = e3.relinkMissing(searchingIn: p2)
        ready(e3, 0)
        check(n == 1 && e3.slots[0]?.isReady == true && e3.slots[0]?.scale == 0.5 && e3.slots[0]?.effects.count == 1
              && e3.missingCount == 0, "フォルダを選ぶと同じ名前の動画を探して付け直す（設定はそのまま）")

        // 新規
        e3.newProject()
        check(e3.layerCount == Engine.defaultLayers && e3.columns == Engine.defaultColumns
              && e3.slots.allSatisfy { $0 == nil } && e3.projectURL == nil && !e3.isDirty && e3.effects.isEmpty,
              "新規プロジェクト：空の 4 段 × 8 列から")
    }

    static func testMute(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
        e.load(urls: [URL(fileURLWithPath: paths[1])], startingAt: c)
        let t0 = CACurrentMediaTime()
        while !(e.slots[0]?.isReady == true && e.slots[c]?.isReady == true) && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
        let a = e.slots[0]!, b = e.slots[c]!
        e.trigger(0); e.trigger(c)
        for _ in 0..<10 { e.updateFrame(); wait(1.0 / 60.0) }
        check(e.layerDraws().count == 2, "ミュート前は 2 レイヤーとも出ている")

        e.layers[1].muted = true
        e.updateFrame()
        check(e.layerDraws().count == 1 && b.isPlaying && b.effectiveVolume == 0 && a.effectiveVolume > 0,
              "レイヤーのミュート：そのレイヤーの映像と音だけ消える（再生は続く）")
        e.layers[1].muted = false
        check(e.layerDraws().count == 2 && b.effectiveVolume > 0, "レイヤーのミュートを解除すると戻る")

        a.muted = true
        check(e.layerDraws().count == 1 && a.isPlaying && a.effectiveVolume == 0, "クリップのミュート：そのクリップの映像と音だけ消える")
        a.muted = false

        let mixer = AudioOutput.shared.engine.mainMixerNode
        let saved = mixer.outputVolume
        e.masterVolume = 0.7
        e.compMuted = true
        check(e.renderParams().master == 0 && e.renderParams().compMaster == 0 && mixer.outputVolume == 0
              && a.isPlaying && b.isPlaying, "コンポジションのミュート：出力の映像と音がすぐ消える（再生は続く）")
        e.compMuted = false
        check(e.renderParams().master > 0.99 && abs(mixer.outputVolume - 0.7) < 0.001, "コンポジションのミュートを解除すると戻る")
        mixer.outputVolume = saved
        // 音だけのミュート：映像は出たまま、音だけ消える
        a.audioMuted = true
        check(e.layerDraws().count == 2 && a.effectiveVolume == 0, "クリップの音だけミュート：映像は出たまま音だけ消える")
        a.audioMuted = false
        e.layers[1].audioMuted = true
        check(e.layerDraws().count == 2 && b.effectiveVolume == 0 && a.effectiveVolume > 0, "レイヤーの音だけミュート")
        e.layers[1].audioMuted = false
        check(b.effectiveVolume > 0, "レイヤーの音のミュートを解除すると戻る")
        e.masterAudioMuted = true
        check(mixer.outputVolume == 0 && e.renderParams().master > 0.99, "マスターの音だけミュート：出力の映像は出たまま")
        e.masterAudioMuted = false
        check(abs(mixer.outputVolume - 0.7) < 0.001, "マスターの音のミュートを解除すると戻る")
        mixer.outputVolume = saved

        // 複製にもミュートが付いていく
        a.muted = true
        e.duplicateSlot(0, to: 5)
        check(e.slots[5]?.muted == true, "複製したクリップにもミュートが付いていく")
        e.stopAll()
    }

    /// 開発用：オーバードライブ加算の見え方を 1 枚の PNG に（下は細かいしま模様、上は白い丸と四角）
    static func odPreview(path: String, values: [Double], time: Double) {
        let ctx = MetalContext.shared
        let W = 960, H = 540
        func tex(_ w: Int, _ h: Int, _ f: (Int, Int) -> SIMD3<Float>) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.shaderRead]
            let t = ctx.device.makeTexture(descriptor: td)!
            var px = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let c = (f(x, y) * 255).rounded(.toNearestOrEven); let i = (y * w + x) * 4
                px[i] = UInt8(c.z); px[i + 1] = UInt8(c.y); px[i + 2] = UInt8(c.x)
            } }
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
            return t
        }
        let below = tex(W, H) { x, y in
            let v: Float = ((x / 12 + y / 12) % 2 == 0) ? 0.35 : 0.55
            return SIMD3(v * 0.9, v, v * 1.1)
        }
        let top = tex(W, H) { x, y in
            let dx = Float(x - 300), dy = Float(y - 270)
            if dx * dx + dy * dy < 60 * 60 { return SIMD3(repeating: 1) }
            if x > 600 && x < 760 && y > 200 && y < 340 { return SIMD3(0.9, 0.8, 0.6) }
            return .zero
        }
        var e = Effect(kind: .overdrive)
        for (i, v) in values.enumerated() where i < e.values.count { e.values[i] = v }
        while e.values.count < values.count { e.values.append(values[e.values.count]) }
        var g = LayerGroup(draws: [LayerDraw(texture: top, opacity: 1, blend: .overdrive, holder: nil)],
                           opacity: 1, blend: .overdrive, key: 3)
        g.blendFX = EffectStack(effects: [e])
        let c = Compositor(); c.storageMode = .shared
        let cb = ctx.queue.makeCommandBuffer()!
        let out = c.composite([LayerGroup(draws: [LayerDraw(texture: below, opacity: 1, blend: .normal, holder: nil)],
                                          opacity: 1, blend: .normal, key: 0), g],
                              effects: EffectStack(), width: W, height: H, cb: cb, now: time)!
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: W * H * 4)
        out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        // BGRA → RGBA
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
        px.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, px.count) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("書き出しました: \(path)")
    }

    /// 開発用：オーバードライブ加算の GPU 時間を測る（1 コマあたり ms）
    static func odBench(width W: Int, height H: Int) {
        let ctx = MetalContext.shared
        func tex(_ f: (Int, Int) -> SIMD3<Float>) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
            td.usage = [.shaderRead]
            let t = ctx.device.makeTexture(descriptor: td)!
            var px = [UInt8](repeating: 255, count: W * H * 4)
            for y in 0..<H { for x in 0..<W {
                let c = (f(x * 960 / W, y * 540 / H) * 255).rounded(.toNearestOrEven); let i = (y * W + x) * 4
                px[i] = UInt8(c.z); px[i + 1] = UInt8(c.y); px[i + 2] = UInt8(c.x)
            } }
            t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
            return t
        }
        let below = tex { x, y in SIMD3(repeating: ((x / 12 + y / 12) % 2 == 0) ? 0.35 : 0.55) }
        let top = tex { x, y in
            let dx = Float(x - 300), dy = Float(y - 270)
            return dx * dx + dy * dy < 60 * 60 ? SIMD3(repeating: 1) : .zero
        }
        let base = LayerGroup(draws: [LayerDraw(texture: below, opacity: 1, blend: .normal, holder: nil)],
                              opacity: 1, blend: .normal, key: 0)
        func groups(_ od: Bool) -> [LayerGroup] {
            var g = LayerGroup(draws: [LayerDraw(texture: top, opacity: 1, blend: od ? .overdrive : .add, holder: nil)],
                               opacity: 1, blend: od ? .overdrive : .add, key: 3)
            if od { g.blendFX = EffectStack(effects: [Effect(kind: .overdrive)]) }
            return [base, g]
        }
        for od in [false, true] {
            let c = Compositor()
            var times: [Double] = []
            for i in 0..<80 {
                let cb = ctx.queue.makeCommandBuffer()!
                _ = c.composite(groups(od), effects: EffectStack(), width: W, height: H, cb: cb, now: 10 + Double(i) / 60)
                cb.commit(); cb.waitUntilCompleted()
                if i >= 10 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
            }
            times.sort()
            print(String(format: "%@ %dx%d: GPU 中央値 %.2f ms / 最大 %.2f ms", od ? "オーバードライブ" : "加算　　　　　", W, H,
                         times[times.count / 2], times.last!))
        }
    }

    static func testAnimation(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        func near(_ a: Double, _ b: Double, _ eps: Double = 0.01) -> Bool { abs(a - b) < eps }
        var a = ParamAnim(key: .rotation)
        a.mode = .time; a.seconds = 4; a.start = 100
        let clock = BeatClock(bpm: 120, anchorHost: 0, anchorBeat: 0)
        a.motion = .forward
        let fwd = a.value(base: 0, at: 101, beat: clock)
        a.motion = .backward
        let bwd = a.value(base: 0, at: 101, beat: clock)
        a.motion = .pingpong
        let pp1 = a.value(base: 0, at: 102, beat: clock), pp2 = a.value(base: 0, at: 106, beat: clock)
        check(near(fwd, 90) && near(bwd, 270) && near(pp1, 180) && near(pp2, 180)
              && near(a.value(base: 0, at: 104, beat: clock), 360) && near(a.value(base: 0, at: 108, beat: clock), 0),
              String(format: "秒モード：順 %.0f° / 逆 %.0f° / 往復 %.0f°・%.0f°（4秒で0→360°）", fwd, bwd, pp1, pp2))
        a.motion = .random
        let r1 = a.value(base: 0, at: 100.5, beat: clock), r2 = a.value(base: 0, at: 103.5, beat: clock)
        let r3 = a.value(base: 0, at: 104.5, beat: clock)
        check(r1 == r2 && r1 != r3 && (0...360).contains(r1) && (0...360).contains(r3),
              String(format: "ランダム：1周の間は同じ値、次の周で別の値（%.0f° → %.0f°）", r1, r3))
        var b = ParamAnim(key: .opacity)
        b.mode = .beat; b.beats = 4
        check(near(b.value(base: 1, at: 1.0, beat: clock), 0.5) && near(b.value(base: 1, at: 0.5, beat: clock), 0.25),
              "BPMモード：120BPM・4拍で1周（1秒後に半分）")
        a.mode = .off
        check(a.value(base: 33, at: 101, beat: clock) == 33, "固定なら手で決めた値のまま")

        var c = BeatClock(bpm: 120, anchorHost: 10, anchorBeat: 0)
        let before = c.beat(at: 12)
        c.setBPM(90, at: 12)
        check(near(c.beat(at: 12), before) && near(c.beat(at: 14), before + 3), "BPMを変えても拍の位置は飛ばない")

        let e = Engine(persistent: false)
        for t in [50.0, 50.5, 51.0, 51.5] { e.tapTempo(at: t) }
        let tb = e.beatClock.beat(at: 51.5)
        check(near(e.bpm, 120) && near(tb, tb.rounded(), 0.0001),
              String(format: "タップテンポ：0.5秒おきに4回 → %.1f BPM、押した瞬間が拍の頭", e.bpm))

        // 描画にアニメーションが乗る
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
        let t0 = CACurrentMediaTime()
        while e.slots[0]?.isReady != true && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
        let s = e.slots[0]!
        var rot = s.anim(.rotation); rot.mode = .time; rot.seconds = 2; rot.lo = 0; rot.hi = 360
        s.setAnim(.rotation, rot)
        var lop = e.layers[0].anim(.opacity); lop.mode = .time; lop.seconds = 2; lop.lo = 0; lop.hi = 1
        e.layers[0].setAnim(.opacity, lop)
        var mop = e.anim(.opacity); mop.mode = .beat; mop.beats = 4; mop.lo = 0; mop.hi = 1
        e.setAnim(.opacity, mop)
        e.trigger(0)
        for _ in 0..<10 { e.updateFrame(); wait(1.0 / 60.0) }
        let d1 = e.layerDraws().first, m1 = e.renderParams().master
        wait(0.5)
        e.updateFrame()
        let d2 = e.layerDraws().first, m2 = e.renderParams().master
        let dRot = Double((d2?.transform.rotation ?? 0) - (d1?.transform.rotation ?? 0)) * 180 / .pi
        let dOp = Double((d2?.opacity ?? 0) - (d1?.opacity ?? 0))
        check(d1 != nil && d2 != nil && near(dRot, 90, 8) && near(dOp, 0.25, 0.04) && abs(m2 - m1) > 0.05,
              String(format: "描画にアニメーションが乗る（0.5秒で 角度 +%.0f°、レイヤー不透明度 +%.2f、マスター %.2f→%.2f）",
                     dRot, dOp, m1, m2))
        // トリガーし直すと秒モードは頭から
        e.trigger(0)
        for _ in 0..<3 { e.updateFrame(); wait(1.0 / 60.0) }
        let d3 = e.layerDraws().first
        check(Double(d3?.transform.rotation ?? 9) * 180 / .pi < 15, "クリップをトリガーし直すと、秒モードのアニメーションは頭から")
        // 複製にもアニメーションが付いていく
        e.duplicateSlot(0, to: 3)
        check(e.slots[3]?.anim(.rotation).mode == .time && e.slots[3]?.anim(.rotation).seconds == 2,
              "複製したクリップにもアニメーションが付いていく")
        s.resetTransform()
        check(!s.anim(.rotation).isOn, "リセットでアニメーションも止まる")

        // BPM 同期：再生範囲を決めた拍数でちょうど 1 周
        e.bpm = 120
        s.setInOut(in: 2.0, out: .some(4.0))   // 2 秒
        s.syncBeats = 4                          // 120BPM の 4 拍 = 2 秒 → 1.0x
        s.syncMode = .bpm
        wait(0.3)
        e.trigger(0)
        let sr1 = s.effectiveSpeed
        e.bpm = 180                              // 4 拍 = 1.333 秒 → 1.5x
        let sr2 = s.effectiveSpeed, clockRate = s.clock.rate
        let audioRate = s.audio?.rate ?? sr2
        wait(0.05)
        check(near(sr1, 1.0, 0.001) && near(sr2, 1.5, 0.001) && near(clockRate, 1.5, 0.001),
              String(format: "BPM 同期：2秒の範囲を4拍で → 120BPM %.3fx / 180BPM %.3fx（BPM に付いていく）", sr1, sr2))
        let tStart = CACurrentMediaTime()
        while s.isPlaying && s.position(at: CACurrentMediaTime()) < 3.9 && CACurrentMediaTime() - tStart < 3 { wait(0.01) }
        _ = audioRate
        e.masterSpeed = 2.0
        check(near(s.effectiveSpeed, 1.5, 0.001), "BPM 同期のクリップにはコンポジション速度は効かない")
        e.masterSpeed = 1.0
        e.tapTempo(at: 200); e.tapTempo(at: 200.25)   // 240 BPM
        check(near(s.effectiveSpeed, 2.0, 0.01), String(format: "タップで BPM を変えても付いていく（%.3fx）", s.effectiveSpeed))
        s.syncBeats = 1                          // 240BPM の 1 拍 = 0.25 秒で 2 秒 → 8x（上限）
        s.syncBeats = 1; s.setInOut(in: 0, out: .some(8.0))
        check(s.effectiveSpeed == ClipSlot.syncRateRange.upperBound, "速すぎる組み合わせは上限で止める")
        s.syncMode = .free
        s.resetInOut()

        // ランダムジャンプ：拍の頭ごとにランダムな位置へ飛ぶ（音も一緒に）
        e.bpm = 120                                // 1 拍 = 0.5 秒
        s.endAction = .loop
        s.jumpBeats = 1
        wait(0.3)
        e.trigger(0)
        var jumps: [(t: Double, beat: Double, pts: Double)] = []
        var lastPTS = -1.0, lastT = 0.0
        let tj = CACurrentMediaTime()
        while CACurrentMediaTime() - tj < 2.3 {
            let now = CACurrentMediaTime()
            if s.frameForDisplay(at: now) != nil {
                let p = s.lastShownPTS
                // 時間の進み以上に位置が変わった = 飛んだ
                if lastPTS >= 0 && abs((p - lastPTS) - (now - lastT)) > 0.2 {
                    jumps.append((now, e.beatClock.beat(at: now), p))
                }
                lastPTS = p; lastT = now
            }
            wait(1.0 / 240.0)
        }
        // 飛んだ瞬間が拍の頭からどれだけずれたか（拍の割合 → ms）
        let offsMs = jumps.map { j -> Double in
            let f = j.beat - j.beat.rounded()
            return f * 500
        }
        let maxOff = offsMs.map { abs($0) }.max() ?? .infinity
        let distinct = Set(jumps.map { Int($0.pts * 10) }).count
        check(jumps.count >= 3 && jumps.count <= 5 && maxOff < 25 && distinct >= 3,
              String(format: "ランダムジャンプ：2.3秒で %d 回、拍の頭からのずれ 最大 %.0f ms、飛び先 %d か所",
                     jumps.count, maxOff, distinct))
        // 止めてから（今の位置のまま再生は続く）測る。わざと「音声はもう次の拍の頭へ飛ぶ予約を済ませたが、
        // 映像はまだ飛んでいない」瞬間（拍の頭の 20ms 前）に止める。ここで止めても音声は映像に合わせ直される
        let bc = e.beatClock, spb = 60 / bc.bpm
        var nextBeat = bc.anchorHost + (floor(bc.beat(at: CACurrentMediaTime())) + 1 - bc.anchorBeat) * spb
        if nextBeat - CACurrentMediaTime() < 0.1 { nextBeat += spb }
        while CACurrentMediaTime() < nextBeat - 0.02 { wait(0.001) }
        s.jumpBeats = 0
        wait(0.2)
        if s.hasAudio {
            var o: [Double] = []
            for _ in 0..<8 {
                if let r = s.audio?.renderedPosition() { o.append((r.pos - s.clock.position(at: r.hostSeconds)) * 1000) }
                wait(0.02)
            }
            let avg = o.isEmpty ? .nan : o.reduce(0, +) / Double(o.count)
            check(abs(avg) < 15, String(format: "ジャンプ後も音声と映像はずれない（%.1f ms）", avg))
        }
        s.jumpBeats = 0
        e.stopAll()
        e.stopAll()
    }

    static func testGrid(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
        e.load(urls: [URL(fileURLWithPath: paths[1])], startingAt: e.columns + 2)
        let t0 = CACurrentMediaTime()
        while !(e.slots[0]?.isReady == true && e.slots[e.columns + 2]?.isReady == true) && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
        let a = e.slots[0]!, b = e.slots[e.columns + 2]!
        e.layers[1].opacity = 0.5
        e.trigger(0)
        e.trigger(e.columns + 2)
        e.selectClip(e.columns + 2)
        for _ in 0..<10 { e.updateFrame(); wait(1.0 / 60.0) }
        let fb = e.frame(layer: 1)

        // ⌥ドラッグの複製：同じ設定の別クリップができる。元の再生は止まらない
        a.scale = 0.5
        a.endAction = .pingpong
        let dupOK = e.duplicateSlot(0, to: 7)
        let d = e.slots[7]
        check(dupOK && d != nil && d !== a && d?.url == a.url && d?.scale == 0.5 && d?.endAction == .pingpong
              && d?.isPlaying == false && a.isPlaying && e.activeByLayer[0] == 0,
              "クリップを同じレイヤーの別の場所に複製できる（設定も同じ、元は再生を続ける）")
        check(e.duplicateSlot(7, to: e.columns + 7) && e.slots[e.columns + 7]?.url == a.url && b.isPlaying,
              "別のレイヤーにも複製できる")
        check(!e.duplicateSlot(7, to: e.columns + 2) && e.slots[e.columns + 2] === b && b.isPlaying,
              "再生中のクリップの上には複製しない")
        check(e.duplicateSlot(e.columns + 2, to: 7) && e.slots[7]?.url == b.url && e.slots[7] !== d,
              "再生していないクリップの上なら置き換える")
        a.scale = 1
        a.endAction = .loop
        e.clear(7); e.clear(e.columns + 7)

        // 一番上にレイヤーを足す → 下の段がずれる。再生は止まらない
        e.insertLayer(at: 0)
        check(e.layerCount == 5 && e.slots[e.columns] === a && e.slots[2 * e.columns + 2] === b
              && e.activeByLayer == [nil, e.columns, 2 * e.columns + 2, nil, nil]
              && e.layers[2].opacity == 0.5 && e.layers.map(\.name) == ["L1", "L2", "L3", "L4", "L5"]
              && a.isPlaying && b.isPlaying && e.frame(layer: 2) === fb && e.selectedLayer == 2
              && e.inspectedIndex == 2 * e.columns + 2,
              "レイヤーを上に足すと、下の段が設定・再生中のクリップごとずれる（再生は止まらない）")
        // 列を左に足す
        e.insertColumn(at: 0)
        check(e.columns == 9 && e.slots[9 + 1] === a && e.slots[18 + 3] === b && e.activeByLayer[2] == 21
              && e.slotCount == 45 && b.isPlaying,
              "列を足すと、クリップは同じ段のまま右へずれる")
        e.removeColumn(0)
        e.removeLayer(0)
        check(e.layerCount == 4 && e.columns == 8 && e.slots[0] === a && e.slots[10] === b
              && e.activeByLayer == [0, 10, nil, nil] && a.isPlaying && b.isPlaying,
              "足した列・レイヤーを消すと元に戻る")
        // 再生中のクリップがある列を消す → そのクリップは止まって外れる
        check(e.columnHasClips(2) && !e.columnHasClips(5), "列にクリップがあるか分かる")
        e.removeColumn(2)
        for _ in 0..<5 { e.updateFrame(); wait(1.0 / 60.0) }
        check(e.columns == 7 && !b.isPlaying && e.activeByLayer[1] == nil && !e.slots.contains { $0 === b }
              && e.inspectedIndex == nil && e.frame(layer: 1) == nil && a.isPlaying,
              "再生中のクリップがある列を消すと、そのクリップは止まって外れる（他は続く）")
        e.removeLayer(0)
        check(e.layerCount == 3 && !a.isPlaying && e.activeByLayer.allSatisfy { $0 == nil } && e.layerDraws().isEmpty,
              "再生中のレイヤーを消すと、そのクリップも止まる")
        while e.layerCount > 1 { e.removeLayer(0) }
        e.removeLayer(0)
        while e.columns > 1 { e.removeColumn(0) }
        e.removeColumn(0)
        check(e.layerCount == 1 && e.columns == 1, "最後の 1 段・1 列は消せない")
        for _ in 0..<20 { e.insertLayer(at: e.layerCount) }
        check(e.layerCount == Engine.maxLayers, "レイヤーは \(Engine.maxLayers) 段まで")
    }

    static func testPreviews(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
        e.load(urls: [URL(fileURLWithPath: paths[1])], startingAt: c)
        let t0 = CACurrentMediaTime()
        while !(e.slots[0]?.isReady == true && e.slots[c]?.isReady == true) && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
        wait(0.2)

        // 選択だけ（出力しない）
        e.selectClip(0)
        var updates = 0
        var last: ObjectIdentifier?
        let tp = CACurrentMediaTime()
        while CACurrentMediaTime() - tp < 1.0 {
            e.updateFrame()
            if let d = e.previewDraws().first {
                let id = ObjectIdentifier(d.texture)
                if id != last { updates += 1; last = id }
            }
            wait(1.0 / 60.0)
        }
        let slot = e.slots[0]!
        check(updates >= 25 && !slot.isPlaying && e.layerDraws().isEmpty && e.activeByLayer[0] == nil,
              "選択したクリップは出力せずにプレビューで再生される（\(updates) フレーム/1秒、出力は黒のまま）")
        check(e.inspectorTab == .clip, "クリップを選ぶとクリップタブになる")

        // 選択中のクリップの速度・トランスフォームがプレビューに反映される
        slot.scale = 0.5
        e.updateFrame()
        check(e.previewDraws().first?.transform.scale == 0.5, "プレビューにクリップのトランスフォームが反映される")
        slot.scale = 1

        // 出力したら、プレビューは出力と同じフレームになる
        e.trigger(0)
        var same = false
        for _ in 0..<20 {
            e.updateFrame()
            if let p = e.previewDraws().first, let f = e.frame(layer: 0), p.texture === f.texture { same = true; break }
            wait(1.0 / 60.0)
        }
        check(same && e.inspectedIndex == 0, "選択中のクリップを出力すると、プレビューは出力と同じ映像になる")

        // トリガーしても選択中のクリップは変わらない（別のクリップを仕込み中でも邪魔しない）
        e.selectClip(0)
        e.trigger(c)
        check(e.inspectedIndex == 0 && e.selectedLayer == 1, "別のクリップをトリガーしても、クリップの選択は変わらない")

        // レイヤープレビューは選択中レイヤーだけ
        for _ in 0..<10 { e.updateFrame(); wait(1.0 / 60.0) }
        let lp = e.layerPreviewDraws()
        check(lp.count == 1 && lp.first?.texture === e.frame(layer: 1)?.texture, "レイヤープレビューは選択中のレイヤーだけ")

        // マスター不透明度
        e.masterOpacity = 0.5
        check(e.renderParams().master == 0.5, "マスター不透明度が描画に渡る")

        // ブラックアウト（トグル）：再生は続けたまま、出力の映像と音だけ消す
        let mixer = AudioOutput.shared.engine.mainMixerNode
        let savedVol = mixer.outputVolume
        e.masterVolume = 0.8
        e.blackoutFadeOut = 0
        e.blackoutFadeIn = 0
        e.toggleBlackout()
        let bp = e.renderParams()
        check(e.isBlackout && bp.master == 0 && bp.compMaster == 0.5 && mixer.outputVolume == 0
              && e.activeByLayer.contains { $0 != nil } && !e.layerDraws().isEmpty,
              "ブラックアウト中は出力が黒・無音で、クリップは再生し続ける")
        e.toggleBlackout()
        check(!e.isBlackout && e.renderParams().master == 0.5 && abs(mixer.outputVolume - 0.8) < 0.001,
              "ブラックアウト解除で元の不透明度・音量に戻る")

        // ブラックアウトのフェード
        e.blackoutFadeOut = 0.4
        e.blackoutFadeIn = 0.2
        e.toggleBlackout()
        wait(0.2)
        let mid = e.renderParams().master, midVol = mixer.outputVolume
        check(mid > 0.15 && mid < 0.35 && midVol > 0.2 && midVol < 0.6,
              String(format: "ブラックアウトはフェードで暗くなる（0.2秒後 映像 %.2f / 音 %.2f）", mid, midVol))
        // 途中で解除 → その位置から引き返す（解除の時間は 0.2 秒 × 残り分）
        e.toggleBlackout()
        let back = e.renderParams().master
        wait(0.25)
        check(abs(back - mid) < 0.05 && e.renderParams().master == 0.5 && abs(mixer.outputVolume - 0.8) < 0.001,
              "フェード中に解除するとその位置から引き返し、元に戻る")

        // レイヤーごとのクロスフェード
        e.blackoutFadeOut = 0; e.blackoutFadeIn = 0
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: c + 1)
        let t1 = CACurrentMediaTime()
        while e.slots[c + 1]?.isReady != true && CACurrentMediaTime() - t1 < 10 { wait(0.05) }
        wait(0.2)
        e.layers[1].fadeTime = 0.5
        e.layers[1].opacity = 1
        let oldSlot = e.slots[c]!, newSlot = e.slots[c + 1]!
        if !oldSlot.isPlaying { e.trigger(c) }
        for _ in 0..<10 { e.updateFrame(); wait(1.0 / 60.0) }
        e.trigger(c + 1)
        wait(0.25)
        e.updateFrame()
        let l1 = e.layerDraws().filter { d in d.texture !== e.frame(layer: 0)?.texture }
        check(oldSlot.isPlaying && newSlot.isPlaying && l1.count == 2
              && oldSlot.fadeGain > 0.55 && oldSlot.fadeGain < 0.85 && newSlot.fadeGain > 0.55 && newSlot.fadeGain < 0.85
              && (l1.last.map { $0.opacity > 0.3 && $0.opacity < 0.7 } ?? false),
              String(format: "切り替えフェード中は前後のクリップが両方再生され、映像・音が入れ替わる（音 前 %.2f / 後 %.2f）",
                     oldSlot.fadeGain, newSlot.fadeGain))
        wait(0.4)
        e.updateFrame()
        check(!oldSlot.isPlaying && newSlot.isPlaying && newSlot.fadeGain == 1
              && e.layerDraws().filter { d in d.texture !== e.frame(layer: 0)?.texture }.count == 1,
              "フェードが終わると前のクリップは止まる")
        // フェード 0 ならカット
        e.layers[1].fadeTime = 0
        e.trigger(c)
        check(!newSlot.isPlaying && oldSlot.isPlaying && oldSlot.fadeGain == 1, "切り替えフェード 0 ならカット")

        // 終わったら「ブラックアウト」→ そのレイヤーが消える
        let s0 = e.slots[0]!
        s0.endAction = .blackout
        s0.setInOut(in: 1.0, out: .some(1.5))
        wait(0.3)
        e.trigger(0)
        let tb = CACurrentMediaTime()
        while CACurrentMediaTime() - tb < 0.9 { e.updateFrame(); wait(1.0 / 60.0) }
        check(e.activeByLayer[0] == nil && !s0.isPlaying && e.activeByLayer[1] != nil,
              "終わったら「ブラックアウト」のクリップは、最後まで来るとそのレイヤーだけ消える")
        mixer.outputVolume = savedVol
        e.stopAll()
    }

    struct Smoothness: CustomStringConvertible {
        var frames = 0
        var maxGapMs = 0.0        // 新しいフレームが来ない最長時間
        var backwardJumps = 0     // 表示フレームが巻き戻った回数
        var maxLagMs = 0.0        // 表示フレームが時計の位置からどれだけ遅れたか
        var description: String {
            String(format: "frames=%d 最大間隔=%.1fms 巻き戻り=%d 最大遅れ=%.1fms", frames, maxGapMs, backwardJumps, maxLagMs)
        }
    }

    /// 60Hz の描画ループを模して、フレームの取れ方を測る
    static func measureSmoothness(_ slot: ClipSlot, seconds: Double, tick: (Double) -> Void) -> Smoothness {
        // 描画ループが回っている状態にしてから測る
        let w0 = CACurrentMediaTime()
        while CACurrentMediaTime() - w0 < 0.2 {
            _ = slot.frameForDisplay(at: CACurrentMediaTime())
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }
        var r = Smoothness()
        let t0 = CACurrentMediaTime()
        var nextTick = t0
        var lastFrameHost = t0
        var lastPTS = slot.lastShownPTS
        var shownPTS = 0.0
        while true {
            let now = CACurrentMediaTime()
            if now - t0 >= seconds { break }
            tick(now - t0)
            if now >= nextTick {
                nextTick += 1.0 / 60.0
                if let pb = slot.frameForDisplay(at: now) {
                    _ = pb
                    r.frames += 1
                    r.maxGapMs = max(r.maxGapMs, (now - lastFrameHost) * 1000)
                    lastFrameHost = now
                    shownPTS = slot.lastShownPTS
                    if shownPTS < lastPTS { r.backwardJumps += 1 }
                    lastPTS = shownPTS
                }
                // 30fps 素材なので、時計の位置から 1 フレーム以上遅れていたら「遅れ」
                let pos = slot.clock.position(at: now)
                let lag = (pos - lastPTS) * 1000
                if lag > 40 && ProcessInfo.processInfo.environment["VJ_DEBUG"] != nil {
                    print(String(format: "   [lag] t=%.3f pos=%.3f shown=%.3f lag=%.0fms", now - t0, pos, lastPTS, lag))
                }
                r.maxLagMs = max(r.maxLagMs, lag)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.0005))
        }
        return r
    }
}
