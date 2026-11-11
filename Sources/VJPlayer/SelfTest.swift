import AVFoundation
import AppKit
import Metal
import CoreMIDI
import Network
import Syphon
import MetalKit
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
        AudioReactive.shared.forTests = true
        AudioOutput.shared.masterMixer.outputVolume = 0
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
        testSceneClipSettings(check: check, wait: wait)
        testAutopilot(check: check)
        testAutopilotUndo(check: check, wait: wait)
        testOutputEvents(check: check, wait: wait)
        testKinds2FX(check: check)
        testMoreKinds(check: check)
        testReactionDiffusion(check: check)
        testDecks(check: check, wait: wait)
        testKinds2Gen(check: check)
        testPads(check: check)
        testMultiSelect(check: check)
        testMoveLayer(check: check)
        testEffectClips(check: check)
        testSolo(check: check)
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
            for (name, tpl) in [("Show", DockNode.cuePlayback), ("VJ", DockNode.clubVJ)] {
                check(Set(tpl.panels) == Set(DockPanel.allCases) && tpl.panels.count == DockPanel.allCases.count,
                      "おすすめのレイアウト（\(name)）：全部のパネルが 1 回ずつある")
            }
            // パネルを閉じる・開く（設定には保存しないもので試す）
            do {
                let lm = LayoutManager(persist: false)
                // いつもの並べ方：閉じられるのは右下のタブ・FX パッド・出力モニター。グリッドなどは閉じられない
                lm.close(DockPanel.cues); lm.close(DockPanel.pads); lm.close(DockPanel.grid)
                check(lm.isClosed(DockPanel.cues) && !lm.attachedTabs.contains(.cues) && !lm.isShownInMain(.pads) && !lm.isClosed(DockPanel.grid),
                      "パネル：いつもの並べ方で、タブ・FX パッドを閉じられる（グリッドは閉じられない）")
                // 別ウィンドウのものを閉じると、ウィンドウも閉じる。開くとメインに戻る
                lm.detach(.scenes)
                lm.close(DockPanel.scenes)
                let closedWin = !lm.isDetached(.scenes) && lm.isClosed(DockPanel.scenes)
                lm.open(DockPanel.scenes); lm.open(DockPanel.cues); lm.open(DockPanel.pads)
                check(closedWin && lm.isShownInMain(.scenes) && lm.attachedTabs.contains(.cues) && lm.state.closed.isEmpty,
                      "パネル：別ウィンドウのパネルを閉じるとウィンドウも閉じ、開くとメインに戻る")
                // 自由レイアウト：どれでも閉じられ、開くと元の区画の元の場所に戻る。最後の 1 つは閉じられない
                lm.setDockMode(true)
                let before = lm.state.dock
                lm.close(DockPanel.monitor); lm.close(DockPanel.params)
                let tree = lm.state.dock
                lm.open(DockPanel.monitor); lm.open(DockPanel.params)
                check(tree == before && lm.state.dock == before && lm.state.closed.isEmpty,
                      "パネル：自由レイアウトで閉じても区画の形は残り、開くと元の場所に戻る")
                for d in DockPanel.allCases { lm.close(d) }
                check(lm.state.closed.count == DockPanel.allCases.count - 1, "パネル：最後の 1 つは閉じられない")
                // 閉じたパネルを除いた並びでタブを押しても、押したパネルが選ばれる
                let t = DockNode.tabs(id: UUID(), panels: [.live, .scenes, .cues, .effects], selected: 0)
                if case .tabs(let id, _, _) = t, case .tabs(_, let ps, let sel)? = t.selecting(id, panel: .effects).find(id) {
                    check(ps[sel] == .effects, "パネル：閉じたタブがあっても、押したタブが選ばれる")
                }
            }
            // ワークスペース：切り替え・いじった形を覚える・最初の形に戻す（設定には保存しないもので試す）
            do {
                let lm = LayoutManager(persist: false)
                lm.state.monitorWidth = 333                         // まだワークスペースを選んでいない並べ方
                lm.switchWorkspace("Show")
                check(lm.state.workspace == "Show" && lm.state.dockMode && lm.state.dock.map { Set($0.panels) == Set(DockPanel.allCases) } == true
                      && lm.workspaceNames.contains("前の並べ方"),
                      "ワークスペース：切り替えられる（選ぶ前の並べ方は「前の並べ方」として残る）")
                lm.state.dock = lm.state.dock?.movingToEdge(.monitor, .left)   // ポン出しをいじる
                let edited = lm.state.dock
                lm.switchWorkspace("VJ")
                check(lm.state.workspace == "VJ", "ワークスペース：別のワークスペースへ")
                lm.switchWorkspace("Show")
                check(lm.state.dock == edited, "ワークスペース：戻ると、いじった形のまま")
                lm.resetWorkspace("Show")
                check(lm.state.dock.map { Set($0.panels) == Set(DockPanel.allCases) } == true && lm.state.dock != edited,
                      "ワークスペース：最初の形に戻せる")
                // 自分で初期状態を決める → いじる → 初期状態に戻す（自分のもの）→ アプリの最初の状態に戻す
                lm.state.dock = lm.state.dock?.movingToEdge(.pads, .top)
                let mine = lm.state.dock
                lm.setCurrentAsDefault()
                lm.state.dock = lm.state.dock?.movingToEdge(.grid, .right)
                lm.resetWorkspace("Show")
                check(lm.state.dock == mine && lm.hasUserDefault("Show"), "ワークスペース：今の形を初期状態にでき、「初期状態に戻す」でその形に戻る")
                lm.factoryReset("Show")
                check(lm.state.dock == DockNode.cuePlayback.normalized() || lm.state.dock.map { Set($0.panels) == Set(DockPanel.allCases) && $0 != mine } == true,
                      "ワークスペース：アプリの最初の状態にも戻せる")
                check(!lm.hasUserDefault("Show"), "ワークスペース：アプリの最初の状態に戻すと、自分の初期状態は消える")
                lm.savePreset("本番A")
                check(lm.workspaceNames.last == "本番A" && lm.state.workspace == "本番A", "ワークスペース：今の並べ方を新しいワークスペースにできる")
                lm.switchWorkspace("前の並べ方")
                check(lm.state.monitorWidth == 333 && !lm.state.dockMode, "ワークスペース：「前の並べ方」に戻れる")
            }
            for (name, tpl) in [("Show", DockNode.cuePlayback), ("VJ", DockNode.clubVJ)] {
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
        testFrameTrim(paths: paths, check: check, wait: wait)
        testSources(dir: URL(fileURLWithPath: paths[0]).deletingLastPathComponent(), check: check, wait: wait)

        // 16. ミュート（クリップ・レイヤー・コンポジション）
        testMute(paths: paths, check: check, wait: wait)

        // 17. プロジェクトファイル
        testProject(paths: paths, check: check, wait: wait)

        // 18. 録画
        testRecording(check: check, wait: wait)

        // 19. 音に反応させる
        testAudioReactive(check: check, wait: wait)

        // 20. ほかのアプリとのやりとり（OSC・Syphon）
        testLink(check: check, wait: wait)

        // 21. MIDI コントローラー・キーの割り当て
        testControls(check: check, wait: wait)

        // 22. 元に戻す・やり直す
        testUndo(check: check, wait: wait)

        // 23. BPM の自動検出
        testBeatDetect(check: check, wait: wait)

        // 24. カメラ・ほかのアプリの映像の置き方
        testSourceDraw(check: check)

        // 25. 出力の分割
        testOutputMap(check: check)
        testOutputMapping(check: check)
        testMapEditor(check: check)

        // 26. 切り替え方（トランジション）
        testTransitions(check: check, wait: wait)

        // 27. HAP の動画
        testHap(check: check, wait: wait)

        // 28. 音の形
        testAudioScope(check: check)

        // 29. 素材をまとめて保存
        testCollect(paths: paths, check: check)

        // 30. 照明（Art-Net / DMX）
        testArtNet(check: check, wait: wait)

        // 31. NDI（ランタイムがあるときだけ）
        testNDI(check: check, wait: wait)
        testReviewFixes(paths: paths, check: check, wait: wait)

        // 32. サイコロ（値をランダムに）・エフェクトのプリセット
        testDiceAndPresets(check: check)
        testFavorites(check: check)

        let out = AudioOutput.shared.engine.outputNode
        let feeding = AudioOutput.shared.engine.inputConnectionPoint(for: out, inputBus: 0)?.node as? AVAudioMixerNode
        check(AudioOutput.shared.silenced && feeding !== AudioOutput.shared.masterMixer && feeding?.outputVolume == 0,
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
            case .difference: exp = d * (1 - op) + simd_abs(d - s) * op
            case .overlay:
                let f = SIMD3((0..<3).map { i in d[i] < 0.5 ? 2 * d[i] * s[i] : 1 - 2 * (1 - d[i]) * (1 - s[i]) })
                exp = d * (1 - op) + f * op
            case .softLight: exp = d * (1 - op) + ((one - 2 * s) * d * d + 2 * s * d) * op
            case .colorDodge: exp = d * (1 - op) + simd_min(d / simd_max(one - s, SIMD3(repeating: 1e-3)), one) * op
            case .hueOnly, .lumOnly:
                func lum(_ c: SIMD3<Float>) -> Float { simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }
                func setLum(_ c0: SIMD3<Float>, _ l: Float) -> SIMD3<Float> {
                    var c = c0 + (l - lum(c0))
                    let L = lum(c), n = c.min(), x = c.max()
                    if n < 0 { c = L + (c - L) * L / max(L - n, 1e-5) }
                    if x > 1 { c = L + (c - L) * (1 - L) / max(x - L, 1e-5) }
                    return c
                }
                func sat(_ c: SIMD3<Float>) -> Float { c.max() - c.min() }
                func setSat(_ c: SIMD3<Float>, _ v: Float) -> SIMD3<Float> {
                    c.max() - c.min() < 1e-5 ? .zero : (c - c.min()) * v / (c.max() - c.min())
                }
                let f = mode == .hueOnly ? setLum(setSat(s, sat(d)), lum(d)) : setLum(d, lum(s))
                exp = d * (1 - op) + f * op
            case .overdrive, .refract, .light, .flowInto, .interfere, .borrowColor, .dissolve: continue
            }
            let err = simd_reduce_max(simd_abs(got - exp))
            check(err < 3.0 / 255, String(format: "合成モード「%@」不透明度50%%: 誤差 %.1f/255", mode.label, err * 255))
        }

        // 絡み合う重ね方：下 = 横のしま、上 = 真ん中の白い丸（まわりは透明）
        do {
            let W = 96, H = 54
            func tex(_ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> MTLTexture {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
                td.usage = [.shaderRead]; td.storageMode = .shared
                let t = ctx.device.makeTexture(descriptor: td)!
                var px = [UInt8](repeating: 0, count: W * H * 4)
                for y in 0..<H { for x in 0..<W {
                    let (r, g, b, a) = f(x, y); let i = (y * W + x) * 4
                    px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = a
                } }
                t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
                return t
            }
            let stripes = tex { x, _ in (x / 6) % 2 == 0 ? (200, 120, 40, 255) : (40, 90, 200, 255) }
            func disc(_ cx: Int, _ col: (UInt8, UInt8, UInt8)) -> MTLTexture {
                tex { x, y in
                    let d = hypot(Double(x - cx), Double(y - H / 2))
                    return d < 14 ? (col.0, col.1, col.2, 255) : (0, 0, 0, 0)
                }
            }
            let white = disc(W / 2, (255, 255, 255))
            func run(_ mode: BlendMode, top: MTLTexture, fx: Effect? = nil, comp: Compositor = Compositor(), now: Double = 1) -> [UInt8] {
                comp.storageMode = .shared
                let cb = ctx.queue.makeCommandBuffer()!
                var g = LayerGroup(draws: [LayerDraw(texture: top, opacity: 1, blend: mode, holder: nil)], opacity: 1, blend: mode, key: 1)
                g.blendFX = EffectStack(effects: [fx ?? Effect(kind: mode.effectKind ?? .overdrive)])
                let t = comp.composite([LayerGroup(draws: [LayerDraw(texture: stripes, opacity: 1, blend: .normal, holder: nil)],
                                                   opacity: 1, blend: .normal, key: 0), g],
                                       effects: EffectStack(), width: W, height: H, cb: cb, now: now)!
                cb.commit(); cb.waitUntilCompleted()
                var px = [UInt8](repeating: 0, count: W * H * 4)
                t.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                return px
            }
            let base = run(.normal, top: tex { _, _ in (0, 0, 0, 0) })
            func at(_ p: [UInt8], _ x: Int, _ y: Int) -> SIMD3<Int> { let i = (y * W + x) * 4; return SIMD3(Int(p[i + 2]), Int(p[i + 1]), Int(p[i])) }
            func diff(_ p: [UInt8], _ x0: Int, _ x1: Int) -> Int {
                var m = 0
                for y in 0..<H { for x in x0..<x1 { m = max(m, simd_reduce_max(simd_abs(at(p, x, y) &- at(base, x, y)))) } }
                return m
            }
            // 屈折：丸のふちで下のしまが曲がり、丸から離れた所は元のまま。丸そのもの（白）は見えない
            let rf = run(.refract, top: white)
            check(diff(rf, 30, 66) > 40 && diff(rf, 0, 10) <= 2 && at(rf, W / 2, H / 2).x < 230,
                  "重ね方「屈折」：丸のふちで下の絵が曲がり、離れた所は元のまま（丸そのものは見えない）")
            // 光で照らす：丸から離れた所は暗く、丸の所は明るい
            let li = run(.light, top: white)
            let far = simd_reduce_add(at(li, 2, 2)), near = simd_reduce_add(at(li, W / 2, H / 2)), orig = simd_reduce_add(at(base, 2, 2))
            check(far < orig / 3 && near > far * 3, "重ね方「光で照らす」：照らされない所は暗く（\(orig)→\(far)）、光の所は明るい（\(near)）")
            // 干渉：下の絵と違う縞が出る
            check(diff(run(.interfere, top: white), 0, W) > 40, "重ね方「干渉」：縞が出て絵が変わる")
            // 色を借りる：丸の所は上の色（赤）、まわりは元のまま
            let red = disc(W / 2, (255, 30, 30))
            let br = run(.borrowColor, top: red)
            let c = at(br, W / 2, H / 2)
            check(c.x > c.y + 40 && c.x > c.z + 40 && diff(br, 0, 10) <= 2, "重ね方「色を借りる」：下の形に上の色が付き、上が無い所は元のまま")
            // 溶け込む：量 0 なら元のまま、量 100% なら丸の所は上の絵（白）
            var d0 = Effect(kind: .blendDissolve); d0.values[0] = 0
            var d1 = d0; d1.values[0] = 1
            let dz = run(.dissolve, top: white, fx: d0), df = run(.dissolve, top: white, fx: d1)
            check(diff(dz, 0, W) <= 2 && simd_reduce_min(at(df, W / 2, H / 2)) > 240 && diff(df, 0, 10) <= 2,
                  "重ね方「溶け込む」：量 0 で元のまま、100% で上の絵に変わる（上が無い所は元のまま）")
            // 流し込む：動く丸が、下のしまをかき混ぜる（流れは合成ごとに続く）
            let fc = Compositor()
            var last: [UInt8] = []
            var t = 1.0
            for k in 0..<45 {
                last = run(.flowInto, top: disc(20 + k, (255, 255, 255)), comp: fc, now: t)
                t += 1.0 / 30
            }
            check(diff(last, 0, W) > 40, "重ね方「流し込む」：動く丸が、下の絵を押し流してかき混ぜる")
            // 重ね方を変えると、値もその種類のものになる。保存して読み込める
            let l = Layer(index: 0)
            l.blend = .refract
            let k1 = l.blendFX.kind
            l.blend = .dissolve
            check(k1 == .blendRefract && l.blendFX.kind == .blendDissolve && BlendMode.entangle.allSatisfy { $0.readsBelow && $0.isSpecial }
                  && BlendMode.simpleBelow.allSatisfy { $0.readsBelow && !$0.isSpecial },
                  "重ね方：特殊合成を変えると、値もその種類のものになる")
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
        // 列番号を押す：その列のクリップを全レイヤーいっぺんに。空き枠のレイヤーは止まる
        do {
            let sel = e.selectedLayer
            let col0 = (0..<2).map { e.slots[e.slotIndex(deck: e.shownDeck, layer: $0, column: 0)] != nil }
            e.pressColumn(0)
            let ok0 = (0..<2).allSatisfy { r in
                col0[r] ? e.activeByLayer[r] == e.slotIndex(deck: e.shownDeck, layer: r, column: 0) : e.activeByLayer[r] == nil
            }
            check(ok0 && e.columnIsLive(0) && e.selectedLayer == sel,
                  "列番号を押すと、その列のクリップが全レイヤーいっぺんに出る（空き枠のレイヤーは止まる。選択は変えない）")
            e.pressColumn(1)
            check(!e.columnIsLive(0) || !col0.contains(true), "別の列を押すと、前の列は出ている列ではなくなる")
            e.stopLayer(0); e.stopLayer(1)
            e.trigger(1)
        }
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
        check(dec?.values == [0, 1, 1, 0] && abs((dec?.mix ?? 0) - 0.8) < 1e-9 && abs((dec?.color.g ?? 0) - 1) < 0.001 && (dec?.color.r ?? 1) < 0.001,
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
        // グリッドのサムネイルの見せ方：透明の有無・暗さ・中身に寄せる
        do {
            func img(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> NSImage {
                var px = [UInt8](repeating: 0, count: w * h * 4)
                for y in 0..<h { for x in 0..<w {
                    let (r, g, b, a) = f(x, y); let i = (y * w + x) * 4
                    px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = a
                } }
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
                px.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, px.count) }
                let im = NSImage(size: NSSize(width: w, height: h)); im.addRepresentation(rep)
                return im
            }
            let opaque = ThumbStyle.make(img(160, 90) { x, _ in (UInt8(x), 100, 50, 255) })
            // 右上に小さな白い丸（まわりは透明）
            let small = img(320, 180) { x, y in hypot(Double(x - 250), Double(y - 40)) < 15 ? (255, 255, 255, 255) : (0, 0, 0, 0) }
            let ss = ThumbStyle.make(small)
            // 真ん中に小さな暗い四角
            let darkImg = ThumbStyle.make(img(320, 180) { x, y in abs(x - 160) < 25 && abs(y - 90) < 18 ? (25, 25, 25, 255) : (0, 0, 0, 0) })
            // 透明があっても全体に明るく描かれた絵は、寄せない・暗くない
            let wide = ThumbStyle.make(img(320, 180) { x, y in (x + y) % 9 == 0 ? (0, 0, 0, 0) : (230, 200, 90, 255) })
            var zoomLit = false
            if let z = ss.zoomed?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // 寄せた絵の真ん中は白い丸
                var p = [UInt8](repeating: 0, count: 4)
                let c = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(z, in: CGRect(x: -z.width / 2, y: -z.height / 2, width: z.width, height: z.height))
                zoomLit = p[3] > 200 && p[0] > 200 && z.width < 120
            }
            check(!opaque.hasAlpha && opaque.zoomed == nil && ss.hasAlpha && !ss.dark && zoomLit
                  && darkImg.hasAlpha && darkImg.dark && darkImg.zoomed != nil && wide.hasAlpha && !wide.dark && wide.zoomed == nil,
                  "サムネイル：透明があれば印、暗い素材は灰色の地、小さく描かれた素材は描かれた所に寄せる")
        }
        // テキスト：文字を CoreText で描いて出す
        do {
            let W = 160, H = 90
            let blankT: MTLTexture = {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
                td.usage = [.shaderRead]
                return ctx.device.makeTexture(descriptor: td)!
            }()
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            func alpha(_ e: Effect, now: Double = 1, beat: BeatClock = BeatClock()) -> [UInt8] {
                let cb = ctx.queue.makeCommandBuffer()!
                let out = fxp.apply(EffectStack(effects: [e], beat: beat, origin: 0), to: blankT, key: "t", cb: cb, now: now)
                cb.commit(); cb.waitUntilCompleted()
                var px = [UInt8](repeating: 0, count: W * H * 4)
                out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                return stride(from: 3, to: px.count, by: 4).map { px[$0] }
            }
            func lit(_ a: [UInt8], x0: Int, x1: Int, y0: Int = 0, y1: Int = 90) -> Int {
                var n = 0
                for y in y0..<y1 { for x in x0..<x1 where a[y * W + x] > 128 { n += 1 } }
                return n
            }
            var te = Effect(kind: .text); te.text = "HELLO"
            var a = lit(alpha(te), x0: 0, x1: W)
            let corner = lit(alpha(te), x0: 0, x1: 10, y0: 0, y1: 10)
            check(a > 200 && corner == 0, "テキスト：真ん中に文字が出て、まわりは透明（\(a) px）")
            var empty = te; empty.text = "  \n "
            check(lit(alpha(empty), x0: 0, x1: W) == 0, "テキスト：文字が空なら透明")
            let saved = try? JSONDecoder().decode(Effect.self, from: JSONEncoder().encode(te))
            check(saved?.text == "HELLO", "テキスト：文字を保存して読み込める")
            let old = try? JSONDecoder().decode(Effect.self, from: Data(#"{"kind":"text"}"#.utf8))
            check(old?.text == TextLook.defaultText && old?.values.count == EffectKind.text.params.count, "テキスト：値が無くても初期値で読める")
            // 横に流れる：時間で絵が変わる
            var scroll = te; scroll.values[0] = 1; scroll.values[2] = 0.5
            check(alpha(scroll, now: 0) != alpha(scroll, now: 0.3), "テキスト（横に流れる）：時間で流れる")
            // 敷き詰め：画面の上の方にも文字がある
            var tile = te; tile.values[0] = 3; tile.values[1] = 0.15
            a = lit(alpha(tile), x0: 0, x1: W, y0: 0, y1: 20)
            check(a > 30, "テキスト（敷き詰め）：画面いっぱいに並ぶ（上の端 \(a) px）")
            // 1 文字ずつ：途中では左の方だけ、全部出たら右まで
            var type = te; type.values[0] = 4; type.values[2] = 0.25   // 1 秒に 2 文字
            let f0 = TextFrame.at(type, t: 0.6, beat: BeatClock(), origin: 0), f1 = TextFrame.at(type, t: 2.6, beat: BeatClock(), origin: 0)
            check(f0.visible == 2 && f1.visible == 5, "テキスト（1 文字ずつ）：時間で文字が増える（\(f0.visible ?? -1) → \(f1.visible ?? -1)）")
            let part = alpha(type, now: 0.6)
            check(lit(part, x0: 0, x1: W / 2) > 50 && lit(part, x0: W * 3 / 4, x1: W) == 0,
                  "テキスト（1 文字ずつ）：まだの文字は出ない（並びは全部出したときと同じ所）")
            // 行の切り替え：1 拍ごとに次の行（BPM 120 → 0.5 秒ごと）
            var lines = te; lines.text = "A\nB\n\nC"; lines.values[8] = 1
            let ls = [0.1, 0.6, 1.1, 1.6].map { TextFrame.at(lines, t: $0, beat: BeatClock(), origin: 0).text }
            check(ls == ["A", "B", "C", "A"], "テキスト（行の切り替え）：拍ごとに次の行、空の行は飛ばす（\(ls)）")
            var punch = te; punch.values[0] = 5
            let p0 = TextFrame.at(punch, t: 0.01, beat: BeatClock(), origin: 0).punch
            let p1 = TextFrame.at(punch, t: 0.45, beat: BeatClock(), origin: 0).punch
            check(p0 > 1.2 && p1 < 1.01, String(format: "テキスト（拍で弾む）：拍の頭で大きく、すぐ戻る（%.2f → %.2f）", p0, p1))
            // 縁取りだけ：塗りより光る所が少ない
            var outline = te; outline.values[9] = 1; outline.values[1] = 0.5
            var filled = te; filled.values[1] = 0.5
            let ao = lit(alpha(outline), x0: 0, x1: W), af = lit(alpha(filled), x0: 0, x1: W)
            check(ao > 50 && ao < af * 3 / 4, "テキスト（縁取りだけ）：線だけになる（\(ao) / \(af) px）")
            check(TextLook.fonts.indices.allSatisfy { i -> Bool in
                var f = te; f.values[6] = Double(i)
                return lit(alpha(f), x0: 0, x1: W) > 100
            }, "テキスト：どのフォントでも描ける")
            // 間隔：広げると、敷き詰めたときに光る所が減る
            var tight = tile; tight.values[10] = 0; tight.values[11] = 0
            var loose = tile; loose.values[10] = 3; loose.values[11] = 2
            let at = lit(alpha(tight), x0: 0, x1: W), al = lit(alpha(loose), x0: 0, x1: W)
            check(al < at * 2 / 3, "テキスト（敷き詰め）：間隔を広げるとすき間が広がる（\(at) → \(al) px）")
            var sc0 = scroll; sc0.values[10] = 0
            var sc1 = scroll; sc1.values[10] = 4
            check(alpha(sc0) != alpha(sc1), "テキスト（横に流れる）：横の間隔が効く")
            var changed = te; changed.values[1] = 0.9; changed.mix = 0.3; changed.color = RGB(r: 1, g: 0, b: 0)
            changed.setAnim(1, { var x = changed.anim(1); x.mode = .beat; return x }()); changed.enabled = false
            let back = changed.reset
            check(!changed.isDefault && back.isDefault && back.values == Effect(kind: .text).values && back.anims.isEmpty
                  && back.mix == 1 && back.color == .white && back.text == "HELLO" && back.id == te.id && !back.enabled,
                  "リセット：値・動き・不透明度・色は最初に戻り、文字・オン／オフ・id はそのまま")
            // 時計
            check(ClockText.string(3725, mode: 2, format: 0, frac: 0) == "01:02:05"
                  && ClockText.string(65, mode: 2, format: 0, frac: 0) == "01:05"
                  && ClockText.string(9.3, mode: 2, format: 0, frac: 0) == "10"
                  && ClockText.string(9.3, mode: 2, format: 0, frac: 1) == "00:09.3"
                  && ClockText.string(13 * 3600 + 5 * 60 + 7.5, mode: 0, format: 0, frac: 0) == "13:05:07"
                  && ClockText.string(75.42, mode: 3, format: 0, frac: 2) == "01:15.42"
                  && ClockText.string(3725, mode: 2, format: 4, frac: 0) == "3725",
                  "時計：表示（自動は 時:分:秒／分:秒、最後の 10 秒は数字だけ、数えるときは切り上げ）")
            let cal = Calendar.current
            func today(_ h: Int, _ m: Int, _ sec: Int) -> Date {
                var c = cal.dateComponents([.year, .month, .day], from: Date()); c.hour = h; c.minute = m; c.second = sec
                return cal.date(from: c)!
            }
            let ck = Effect(kind: .clock)   // カウントダウン 0:00:00、終わったら HAPPY NEW YEAR
            let c1 = ClockText.at(ck, wall: today(23, 59, 50), elapsed: 0)
            let c2 = ClockText.at(ck, wall: today(0, 0, 30), elapsed: 0)
            let c3 = ClockText.at(ck, wall: today(10, 0, 0), elapsed: 0)
            check(c1.text == "10" && c2.text == ClockText.defaultFinish && c3.text == "14:00:00",
                  "時計（カウントダウン）：0 時まで 10 秒 → 「10」、過ぎて 30 秒 → 終わりの文字、昼 → 次の 0 時まで（\(c1.text) / \(c2.text) / \(c3.text)）")
            check(c1.punch > 1.3 && ClockText.at(ck, wall: today(23, 59, 50).addingTimeInterval(0.5), elapsed: 0).punch < 1.01,
                  "時計：最後の 10 秒は数字が変わった瞬間に弾む")
            var timer = ck; timer.values[12] = 2; timer.text = ""
            check(ClockText.at(timer, wall: Date(), elapsed: 0).text == "10:00"
                  && ClockText.at(timer, wall: Date(), elapsed: 600.5).text == "0",
                  "時計（タイマー）：10 分から数えて、0 で止まる（終わりの文字が空なら 0 のまま）")
            var sw = ck; sw.values[12] = 3
            check(ClockText.at(sw, wall: Date(), elapsed: 75).text == "01:15", "時計（ストップウォッチ）：出してからの時間")
            var big = sw; big.values[1] = 0.4
            check(lit(alpha(big), x0: 0, x1: W) > 200, "時計：数字が描ける")
            var fin = ck; fin.values[12] = 2; fin.values[18] = 0; fin.values[19] = 0; fin.values[1] = 0.35
            let fa = alpha(fin)
            check(lit(fa, x0: 0, x1: W) > 150 && lit(fa, x0: 0, x1: 2) == 0 && lit(fa, x0: W - 2, x1: W) == 0,
                  "時計：終わったときの長い文字は、画面の幅に収まるように縮める")
            check(EffectKind.clock.params.count == 21 && Effect(kind: .clock).reset.text == ClockText.defaultFinish,
                  "時計：値の数・リセットしても終わりの文字は残る")
            // 1/100 秒：毎コマ描き直しても軽いか（1080p）
            do {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
                td.usage = [.shaderRead]
                let bigT = ctx.device.makeTexture(descriptor: td)!
                var hs = sw; hs.values[14] = 2; hs.values[1] = 0.35
                let p = EffectProcessor()
                let t0 = CACurrentMediaTime()
                for k in 0..<60 {
                    let cb = ctx.queue.makeCommandBuffer()!
                    _ = p.apply(EffectStack(effects: [hs], origin: 0), to: bigT, key: "b", cb: cb, now: 1 + Double(k) / 60)
                    cb.commit(); cb.waitUntilCompleted()
                }
                let ms = (CACurrentMediaTime() - t0) / 60 * 1000
                check(ms < 8, String(format: "時計：1/100 秒を毎コマ描き直しても軽い（1 コマ %.2f ms）", ms))
            }
            // 出力の解像度・フレームレート
            do {
                func renders(_ fps: Double, hz: Double, seconds: Double = 2) -> Int {
                    var g = FrameGate(), n = 0
                    let ticks = Int(seconds * hz)
                    for k in 0..<ticks where g.shouldRender(now: 100 + Double(k) / hz, fps: fps, halfPeriod: 0.5 / hz) { n += 1 }
                    return n
                }
                let r30 = renders(30, hz: 60), r25 = renders(25, hz: 60), r0 = renders(0, hz: 60), r60 = renders(60, hz: 120)
                let r24 = renders(24, hz: 120), r120 = renders(120, hz: 60)
                check(r30 == 60 && abs(r25 - 50) <= 1 && r0 == 120 && r60 == 120 && abs(r24 - 48) <= 1 && r120 == 120,
                      "フレームレート：決めた回数だけ描く（60Hz で 30fps \(r30)/2 秒・25fps \(r25)・120Hz で 60fps \(r60)・24fps \(r24)）")
                var f = OutputFormat(); f.width = 1920; f.height = 1080
                func apply(_ m: simd_float3x3, _ x: Float, _ y: Float) -> SIMD2<Float> { let v = m * SIMD3(x, y, 1); return SIMD2(v.x, v.y) / v.z }
                let fitM = f.fitMatrix(screenAspect: 4.0 / 3)
                let top = apply(fitM, 0.5, 0.125), mid = apply(fitM, 0.5, 0.5)
                f.fit = .fill
                let left = apply(f.fitMatrix(screenAspect: 4.0 / 3), 0, 0.5)
                f.fit = .stretch
                check(abs(top.y) < 1e-4 && abs(mid.x - 0.5) < 1e-4 && abs(mid.y - 0.5) < 1e-4 && abs(left.x - 0.125) < 1e-4
                      && f.fitMatrix(screenAspect: 4.0 / 3) == matrix_identity_float3x3,
                      "解像度：縦横比が違う出力先には 収める（上下に黒帯）・いっぱい（左右が切れる）・引き伸ばす で置く")
                let en = Engine(persistent: false)
                en.screenAspect = 4.0 / 3
                let autoSize = en.compositionSize
                en.outputFormat = OutputFormat(width: 1280, height: 720, fps: 30)
                let saved = try? JSONDecoder().decode(Engine.SavedState.self, from: JSONEncoder().encode(en.makeState(relativeTo: nil)))
                let en2 = Engine(persistent: false)
                if let saved { en2.apply(saved, baseDir: nil) }
                check(autoSize == (1440, 1080) && abs(en.outputAspect - 16.0 / 9) < 1e-6 && en.compositionSize == (1280, 720)
                      && en.renderParams().format.fps == 30 && en.targetFPS() == 30
                      && en2.outputFormat == OutputFormat(width: 1280, height: 720, fps: 30),
                      "解像度・フレームレート：合成の大きさ・縦横比・描画スレッドに渡る値・保存して読み込める")
            }
            // フィロタキシス（Resolume 用の FFGL から移したもの）
            do {
                let ph = Effect(kind: .phyllotaxis)
                let a0 = alpha(ph, now: 0), a5 = alpha(ph, now: 5), a6 = alpha(ph, now: 6)
                let center = lit(a5, x0: 60, x1: 100, y0: 25, y1: 65), all = lit(a5, x0: 0, x1: W)
                check(lit(a0, x0: 0, x1: W) == 0 && center > 0 && all > 20 && a5 != a6 && ph.values.count == 9,
                      "フィロタキシス：出したときは空、時間がたつと中心から粒が広がる（\(all) px）")
            }
            // ライン：0° で縦の線、本数は高さあたり。太さは px
            do {
                var ln = Effect(kind: .lines); ln.values = [4, 60, 0, 0, 0]   // 60 px（1080p）= 高さ 90 では 5 px
                let la = alpha(ln)
                let col = (0..<W).map { x in la[45 * W + x] > 128 }
                let starts = (1..<W).filter { col[$0] && !col[$0 - 1] }.count + (col[0] ? 1 : 0)
                let vertical = (0..<H).allSatisfy { la[$0 * W + 80] == la[0 * W + 80] }
                // 横長 160×90 で高さに 4 本 → 横には 160/90×4 ≈ 7 本
                check(starts >= 6 && starts <= 8 && vertical, "ライン：0° で縦の線、本数は画面の高さに入る数（横に \(starts) 本）")
                var ln1 = ln; ln1.values[1] = 5   // 高さ 90 では 0.4 px
                check(lit(alpha(ln1), x0: 0, x1: W) == 0 && alpha(ln1).contains { $0 > 0 }, "ライン：1 px より細い線は薄くして出す")
                // 波：時間でうねりが動く。線ごとのずれがあっても線は途切れない（どの行にも同じくらい線がある）
                var wv = ln; wv.values[1] = 40; wv.values += [0.05, 2, 1, 0.5, 0, 0, 0.5]
                let w0 = alpha(wv, now: 0.1), w1 = alpha(wv, now: 0.35)
                let rows = stride(from: 5, to: H, by: 10).map { y in lit(w0, x0: 0, x1: W, y0: y, y1: y + 1) }
                check(w0 != w1 && rows.allSatisfy { $0 > 0 } && (rows.max() ?? 0) <= (rows.min() ?? 0) * 3 + 6,
                      "ライン（波）：時間でうねり、線ごとにずらしても途切れない（行ごと \(rows)）")
                // 奥への傾き：横の線を床のように倒すと、上（奥）ほど線が詰まる
                var fl = Effect(kind: .lines); fl.values[0] = 6; fl.values[1] = 40; fl.values[2] = 90; fl.values[3] = 0
                fl.values[9] = 60; fl.values[11] = 0
                let fa = alpha(fl)
                func crossings(_ y0: Int, _ y1: Int) -> Int {
                    (y0 + 1..<y1).filter { (fa[$0 * W + 80] > 100) && !(fa[($0 - 1) * W + 80] > 100) }.count
                }
                let upper = crossings(10, 45), lower = crossings(45, 90)
                check(upper > lower, "ライン（奥への傾き）：上が奥になって、奥ほど線が詰まる（上 \(upper) 本・下 \(lower) 本）")
                let oldLines = try? JSONDecoder().decode(Effect.self, from: Data(#"{"kind":"lines","values":[10,4,0,0.5,0]}"#.utf8))
                check(oldLines?.values.count == 16 && oldLines?.value(9) == 0 && oldLines?.value(12) == 0, "ライン：波・傾き・高さの無い前の保存データも読める")
                // 波の高さ（3D の地形）：線が持ち上がって形が変わる。黒く塗ると、山の下は不透明になる
                var tr = Effect(kind: .lines); tr.values[0] = 12; tr.values[1] = 30
                let flatA = alpha(tr)
                tr.values[12] = 0.25; tr.values[13] = 0
                let ta = alpha(tr)
                tr.values[15] = 1
                let tf = alpha(tr)
                let opaque = tf.filter { $0 == 255 }.count
                check(ta != flatA && lit(ta, x0: 0, x1: W) > 100 && opaque > W * H / 4 && opaque > ta.filter { $0 == 255 }.count,
                      "ライン（波の高さ）：線が山のように持ち上がり、黒く塗ると山の下が隠れる（不透明 \(opaque) px）")
                // ドット：格子に並ぶ（波なしなら同じ大きさの粒が等間隔）。ばらばら・3D で形が変わる
                var dt = Effect(kind: .dots); dt.values[0] = 4; dt.values[1] = 90; dt.values[9] = 0
                let da = alpha(dt)
                // 真ん中は粒の列のあいだ。列の真ん中（高さ 90 に 4 列 → 真ん中から 11 px 下）で数える
                let mid = (0..<W).map { da[(H / 2 + 11) * W + $0] > 128 }
                let blobs = (1..<W).filter { mid[$0] && !mid[$0 - 1] }.count + (mid[0] ? 1 : 0)
                var sc = dt; sc.values[3] = 2
                var cl = dt; cl.values[16] = 0.2; cl.values[13] = 60
                var wv2 = dt; wv2.values[9] = 0.8
                check(blobs >= 6 && blobs <= 8 && alpha(sc) != da && alpha(cl) != da && alpha(wv2) != da
                      && lit(alpha(cl), x0: 0, x1: W) > 0,
                      "ドット：格子に並び（横に \(blobs) 個）、ばらばら・波・3D の点の雲で形が変わる")
                // ふらふら：時間で粒の場所が変わる（ふらふら 0 なら止まったまま）。光のにじみで光る所が広がる
                do {
                    var still = dt; still.values[9] = 0
                    var fly = still; fly.values[18] = 1; fly.values[19] = 1
                    var glow = still; glow.values[20] = 1
                    check(alpha(still, now: 1) == alpha(still, now: 3) && alpha(fly, now: 1) != alpha(fly, now: 3)
                          && lit(alpha(glow), x0: 0, x1: W) > lit(da, x0: 0, x1: W),
                          "ドット：ふらふらで粒が別々に飛び回り、光のにじみで光が広がる")
                    check(EffectKind.dots.looks.allSatisfy { $0.values.keys.allSatisfy { EffectKind.dots.params.indices.contains($0) } },
                          "ドット：見た目のひな形はどれも、ある値だけを変える")
                }
                // 群れ：魚が描かれ、時間で動く（同じ時刻なら止まったまま）。そろえると向きがそろい、画面の外へ出ていかない
                do {
                    var sc = Effect(kind: .school); sc.values[0] = 300; sc.values[14] = 0
                    let s1 = alpha(sc, now: 1), s1b = alpha(sc, now: 1), s2 = alpha(sc, now: 1.4)
                    check(lit(s1, x0: 0, x1: W) > 0 && s1 == s1b && s1 != s2, "群れ：魚が描かれ、時間で動き、同じ時刻では止まる")
                    func polar(_ e: Effect) -> (order: Double, inside: Bool) {
                        var t = 1.0
                        _ = alpha(e, now: t)
                        for _ in 0..<80 { t += 0.1; _ = alpha(e, now: t) }
                        let ps = fxp.schoolFish("t/" + e.id.uuidString, count: 300) ?? []
                        let A = Float(W) / Float(H), D = Float(e.values[14]) * 1.2
                        var m = SIMD3<Float>.zero
                        for f in ps { m += f.v / max(simd_length(f.v), 1e-6) }
                        let inside = !ps.isEmpty && ps.allSatisfy {
                            $0.p.x > -0.1 && $0.p.x < A + 0.1 && $0.p.y > -0.1 && $0.p.y < 1.1 && abs($0.p.z) <= D / 2 + 0.06
                        }
                        return (Double(simd_length(m)) / Double(max(ps.count, 1)), inside)
                    }
                    var al = sc; al.values[5] = 1; al.values[8] = 0; al.values[10] = 0
                    var no = al; no.values[5] = 0; no.values[4] = 0; no.values[10] = 1
                    let pa = polar(al), pn = polar(no)
                    check(pa.order > 0.45 && pa.order > pn.order + 0.2 && pa.inside && pn.inside,
                          String(format: "群れ：そろえると向きがそろい（%.2f、そろえないと %.2f）、画面の中にいる", pa.order, pn.order))
                    // 3D：厚みがあると奥行きに広がって泳ぎ、カメラの向きで絵が変わる
                    var s3 = sc; s3.values[14] = 0.8; s3.values[16] = 0; s3.values[19] = 1.2
                    let p3 = polar(s3)
                    let zs = (fxp.schoolFish("t/" + s3.id.uuidString, count: 300) ?? []).map(\.p.z)
                    let zSpread = (zs.max() ?? 0) - (zs.min() ?? 0)
                    var s3b = s3; s3b.values[17] = 90
                    let i3 = alpha(s3, now: 9), i3b = alpha(s3b, now: 9)
                    check(p3.inside && zSpread > 0.2 && lit(i3, x0: 0, x1: W) > 0 && i3 != i3b,
                          String(format: "群れ（3D）：奥行きに広がって泳ぎ（%.2f）、箱から出ず、カメラの向きで見え方が変わる", zSpread))
                    check(EffectKind.school.looks.allSatisfy { $0.values.keys.allSatisfy { EffectKind.school.params.indices.contains($0) } }
                          && EffectKind.school.isGenerator && EffectKind.school.generatorCategory == .shape,
                          "群れ：見た目のひな形はどれも、ある値だけを変える・図形・粒の分類")
                }
                // トンネル：輪が描かれて奥へ進む（速さ・回転・うねり 0 なら止まる）。模様・形で絵が変わる。真ん中（奥）は暗い
                do {
                    let tn = Effect(kind: .tunnel)
                    let t1 = alpha(tn, now: 1), t2 = alpha(tn, now: 1.3)
                    var still = tn; still.values[0] = 0; still.values[5] = 0; still.values[8] = 0
                    let center = lit(t1, x0: 75, x1: 85, y0: 40, y1: 50)
                    check(lit(t1, x0: 0, x1: W) > 300 && t1.contains(0) && t1 != t2
                          && alpha(still, now: 1) == alpha(still, now: 3) && center < 60,
                          "トンネル：輪が描かれて奥へ進み（止めれば止まる）、まわりは透明、奥は暗い（真ん中 \(center)/100）")
                    var imgs: [[UInt8]] = []
                    for pat in 0..<5 {
                        for sh in 0..<4 {
                            var e = tn; e.values[2] = Double(pat); e.values[1] = Double(sh); e.values[8] = 0
                            imgs.append(alpha(e))
                        }
                    }
                    check(imgs.allSatisfy { lit($0, x0: 0, x1: W) > 50 } && Set(imgs.map { $0.hashValue }).count == imgs.count,
                          "トンネル：模様 5 つ × 形 4 つ、どれも描けて見え方が違う")
                    // うねり（曲がる）を強くしても、奥（暗い所）は 1 か所だけ（ほかの所に穴が出ない）
                    do {
                        var cv = tn; cv.values[2] = 0; cv.values[4] = 0.95; cv.values[7] = 1.5; cv.values[8] = 2
                        var blobs: [Int] = []
                        for t in [1.0, 3.0, 5.0, 7.0, 9.0] {
                            // 格子のすき間は数えないように、ぼかしてから暗い所を探す
                            let raw = alpha(cv, now: t)
                            var a = raw
                            for y in 0..<H {
                                for x in 0..<W {
                                    var sum = 0, cnt = 0
                                    for yy in max(y - 3, 0)...min(y + 3, H - 1) {
                                        for xx in max(x - 3, 0)...min(x + 3, W - 1) { sum += Int(raw[yy * W + xx]); cnt += 1 }
                                    }
                                    a[y * W + x] = UInt8(sum / cnt)
                                }
                            }
                            var seen = [Bool](repeating: false, count: W * H)
                            var n = 0
                            // 画面の端にかかる暗い所（手前の太い輪のすき間）は数えない
                            for i in 0..<(W * H) where a[i] < 30 && !seen[i] {
                                var edge = false
                                var stack = [i]; seen[i] = true
                                while let j = stack.popLast() {
                                    let x = j % W, y = j / W
                                    if x == 0 || y == 0 || x == W - 1 || y == H - 1 { edge = true }
                                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                                        let nx = x + dx, ny = y + dy
                                        guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
                                        let k = ny * W + nx
                                        if a[k] < 30 && !seen[k] { seen[k] = true; stack.append(k) }
                                    }
                                }
                                if !edge { n += 1 }
                            }
                            blobs.append(n)
                        }
                        check(blobs.allSatisfy { $0 == 1 }, "トンネル：うねりを強くしても、奥の暗い所は 1 か所だけ（\(blobs)）")
                    }
                    // 線の太さをいっぱいにすると、どの模様もすき間なく埋まる（奥の暗さ 0 なら全部不透明）。チェッカーは 50% 以下ならふつうの市松
                    do {
                        let full = (0..<5).map { pat -> UInt8 in
                            var e = tn; e.values[2] = Double(pat); e.values[4] = 1; e.values[7] = 0
                            return alpha(e).min() ?? 0
                        }
                        var ck = tn; ck.values[2] = 2; ck.values[7] = 0
                        var ck2 = ck; ck.values[4] = 0.18; ck2.values[4] = 0.5
                        var ck3 = ck; ck3.values[4] = 0.8
                        let half = lit(alpha(ck), x0: 0, x1: W), more = lit(alpha(ck3), x0: 0, x1: W)
                        check(full.allSatisfy { $0 >= 250 } && alpha(ck) == alpha(ck2) && more > half,
                              "トンネル：線の太さ 100% でどの模様も埋まり（いちばん薄い所 \(full)）、チェッカーは 50% より上でマスが埋まっていく")
                    }
                    // ねじれ：三角・四角でも模様が崩れない（細かい羽のような乱れが出ない）。絵の変わり目の数がねじれなしと同じくらい
                    do {
                        func edges(_ a: [UInt8]) -> Int {
                            var n = 0
                            for y in 0..<H { for x in 1..<W where (a[y * W + x] > 128) != (a[y * W + x - 1] > 128) { n += 1 } }
                            return n
                        }
                        var res: [String] = []
                        var ok = true
                        for sh in [1.0, 3.0] {
                            var e = tn; e.values[1] = sh; e.values[2] = 2; e.values[12] = 16; e.values[7] = 0.5
                            let flat = edges(alpha(e))
                            e.values[6] = 2
                            let tw = edges(alpha(e))
                            ok = ok && tw < flat * 3
                            res.append("\(flat)→\(tw)")
                        }
                        check(ok, "トンネル：三角・四角をねじっても模様が崩れない（変わり目 \(res.joined(separator: "、"))）")
                    }
                    var pal = tn; pal.values[13] = 1
                    var rainbow = tn; rainbow.values[13] = 2
                    check(EffectKind.tunnel.looks.allSatisfy { $0.values.keys.allSatisfy { EffectKind.tunnel.params.indices.contains($0) } }
                          && EffectKind.tunnel.isGenerator && EffectKind.tunnel.generatorCategory == .shape
                          && lit(alpha(pal), x0: 0, x1: W) > 300 && lit(alpha(rainbow), x0: 0, x1: W) > 300,
                          "トンネル：見た目のひな形はどれも、ある値だけを変える・パレット・虹色でも描ける・図形・粒の分類")
                }
                // 動き続けるジェネレーター：描けて、時間で動き、同じ時刻なら止まったまま。見た目のひな形はどれも、ある値だけを変える
                do {
                    var res: [String] = []
                    var ok = true
                    for k in [EffectKind.physarum, .particleLife, .fireflies, .attractor] {
                        let e = Effect(kind: k)
                        let a1 = alpha(e, now: 5), a1b = alpha(e, now: 5), a2 = alpha(e, now: 5.5)
                        let n = lit(a1, x0: 0, x1: W) + lit(a2, x0: 0, x1: W)
                        let good = n > 0 && a1 == a1b && a1 != a2 && a1.contains(0)
                            && k.looks.allSatisfy { $0.values.keys.allSatisfy { k.params.indices.contains($0) } }
                            && k.isGenerator && k.isStateful
                        ok = ok && good
                        res.append("\(k.label) \(good ? "○" : "×\([n > 0, a1 == a1b, a1 != a2, a1.contains(0)]) max \(a1.max() ?? 0) mean \(a1.reduce(0) { $0 + Int($1) } / a1.count)")")
                    }
                    check(ok, "動き続けるジェネレーター：描けて、時間で動き、同じ時刻では止まる（\(res.joined(separator: "・"))）")
                }
                // アトラクター：変身で係数が大きく動き続けても、点が 1 か所に集まってしまわない（光の筋のまま）
                do {
                    var e = Effect(kind: .attractor); e.values[5] = 2; e.values[6] = 1
                    var t = 1.0
                    for _ in 0..<900 { _ = alpha(e, now: t); t += 1.0 / 30 }
                    let sim: AttractorSim? = fxp.life.peek("t/" + e.id.uuidString)
                    let spread = sim?.distinctWalkers() ?? 0
                    check(spread > AttractorSim.walkers / 2,
                          "アトラクター：長く変身させても、点が集まって消えない（\(spread) / \(AttractorSim.walkers) か所に分かれている）")
                }
                // 粘菌：はじめの形を変えると、作り直して違う絵になる。えさを置くと、えさの所に集まる
                do {
                    var a = Effect(kind: .physarum); a.values[12] = 0
                    var b = a; b.values[12] = 1; b.id = UUID()
                    check(alpha(a, now: 3) != alpha(b, now: 3), "粘菌：はじめの形（ばらばら・円）で違う網になる")
                }
                // パーティクル・ライフ：たねで性格が変わる（同じ時刻でも違う絵）。好き嫌いの表は -1〜1
                do {
                    var a = Effect(kind: .particleLife); a.values[2] = 1
                    var b = a; b.values[2] = 2; b.id = UUID()
                    let m = ParticleLifeSim.matrix(seed: 5)
                    check(alpha(a, now: 3) != alpha(b, now: 3) && m.count == 64 && m.allSatisfy { abs($0) <= 1 }
                          && ParticleLifeSim.matrix(seed: 5) == m && ParticleLifeSim.matrix(seed: 6) != m,
                          "パーティクル・ライフ：たねで性格（好き嫌いの表）が決まり、違う動きになる")
                }
                // ホタル：そろう強さがあると位相がそろう（そろい具合 r が上がる）。0 ならばらばらのまま
                do {
                    func order(_ K: Double) -> Double {
                        var e = Effect(kind: .fireflies); e.values[1] = K; e.values[2] = 1; e.values[4] = 0.2
                        _ = alpha(e, now: 4)
                        guard let sim: FireflySim = fxp.life.peek("t/" + e.id.uuidString) else { return -1 }
                        let ph = sim.phases(Int(e.values[0]))
                        let c = ph.reduce(0.0) { $0 + cos(Double($1)) } / Double(ph.count)
                        let s = ph.reduce(0.0) { $0 + sin(Double($1)) } / Double(ph.count)
                        return (c * c + s * s).squareRoot()
                    }
                    let r0 = order(0), r1 = order(2.5)
                    check(r0 >= 0 && r0 < 0.3 && r1 > 0.8,
                          String(format: "ホタル：そろう強さで光るタイミングがそろう（そろい具合 %.2f → %.2f）", r0, r1))
                }
                // 時間のずらし：縦（上ほど過去）なら、赤 → 青に変えたあと、上はまだ赤・下はもう青
                do {
                    func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> MTLTexture {
                        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
                        td.usage = [.shaderRead]; td.storageMode = .shared
                        let t = ctx.device.makeTexture(descriptor: td)!
                        var px = [UInt8](repeating: 255, count: W * H * 4)
                        for i in stride(from: 0, to: px.count, by: 4) { px[i] = b; px[i + 1] = g; px[i + 2] = r }
                        t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
                        return t
                    }
                    let red = solid(255, 0, 0), blue = solid(0, 0, 255)
                    let tw = Effect(kind: .timeWarp)
                    let twp = EffectProcessor(); twp.storageMode = .shared
                    func run(_ input: MTLTexture, _ t: Double) -> [UInt8] {
                        let cb = ctx.queue.makeCommandBuffer()!
                        let out = twp.apply(EffectStack(effects: [tw]), to: input, key: "tw", cb: cb, now: t)
                        cb.commit(); cb.waitUntilCompleted()
                        var px = [UInt8](repeating: 0, count: W * H * 4)
                        out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                        return px
                    }
                    var t = 0.0
                    while t < 1.2 { _ = run(red, t); t += 1.0 / 30 }
                    var last: [UInt8] = []
                    while t < 1.6 { last = run(blue, t); t += 1.0 / 30 }
                    let top = (2 * W + 80) * 4, bottom = ((H - 2) * W + 80) * 4
                    check(last[top + 2] > 200 && last[top] < 60 && last[bottom] > 200 && last[bottom + 2] < 60,
                          "時間のずらし：上ほど過去（上はまだ赤、下はもう青）")
                }
                // 流体：動く絵から絵の具が流れて、元の絵と違う絵になる。絵の具を足さず元の絵 100% なら、元の絵のまま
                do {
                    var grid2 = Effect(kind: .grid); grid2.values = [1, 6, 0.2, 1.5]; grid2.color = RGB.hsb(0.1, 0.8, 1)
                    let fp = EffectProcessor(); fp.storageMode = .shared
                    func run(_ fl: Effect, _ t: Double, alone: Bool = false) -> [UInt8] {
                        let cb = ctx.queue.makeCommandBuffer()!
                        let out = fp.apply(EffectStack(effects: alone ? [grid2] : [grid2, fl], origin: 0), to: blankT,
                                           key: alone ? "g" : "fl" + fl.id.uuidString, cb: cb, now: t)
                        cb.commit(); cb.waitUntilCompleted()
                        var px = [UInt8](repeating: 0, count: W * H * 4)
                        out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                        return px
                    }
                    let fl = Effect(kind: .fluid)
                    var none = fl; none.values[1] = 0; none.values[7] = 1; none.values[0] = 3; none.id = UUID()
                    var a: [UInt8] = [], b: [UInt8] = []
                    var t = 1.0
                    for _ in 0..<40 { a = run(fl, t); b = run(none, t); t += 1.0 / 30 }
                    let orig = run(fl, t - 1.0 / 30, alone: true)
                    let diff = zip(a, orig).map { abs(Int($0) - Int($1)) }.reduce(0, +)
                    let same = zip(b, orig).map { abs(Int($0) - Int($1)) }.max() ?? 255
                    check(diff > W * H * 4 && same <= 2 && EffectKind.fluid.category == .shape && EffectKind.timeWarp.category == .time,
                          "流体：動きで絵の具が流れて混ざり（差 \(diff)）、足さなければ元の絵のまま（最大の差 \(same)）")
                }
                // アナログ機材：グリッチボックス・VHS・ビデオフィードバック・ラスタースキャン・CRT
                do {
                    func pic(_ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> MTLTexture {
                        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
                        td.usage = [.shaderRead]; td.storageMode = .shared
                        let t = ctx.device.makeTexture(descriptor: td)!
                        var px = [UInt8](repeating: 0, count: W * H * 4)
                        for y in 0..<H { for x in 0..<W {
                            let (r, g, b, a) = f(x, y); let i = (y * W + x) * 4
                            px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = a
                        } }
                        t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
                        return t
                    }
                    let bars = pic { x, y in
                        let c: [(UInt8, UInt8, UInt8)] = [(230, 40, 40), (40, 220, 60), (240, 230, 50), (40, 60, 230)]
                        let v = c[(x / 40) % 4]
                        let k = UInt8(clamping: 80 + y * 2)
                        return (UInt8(Int(v.0) * Int(k) / 255), UInt8(Int(v.1) * Int(k) / 255), UInt8(Int(v.2) * Int(k) / 255), 255)
                    }
                    let rp = EffectProcessor(); rp.storageMode = .shared
                    func run(_ e: Effect, _ input: MTLTexture, now: Double = 2, key: String = "r") -> [UInt8] {
                        let cb = ctx.queue.makeCommandBuffer()!
                        let out = rp.apply(EffectStack(effects: [e], origin: 0), to: input, key: key, cb: cb, now: now)
                        cb.commit(); cb.waitUntilCompleted()
                        var px = [UInt8](repeating: 0, count: W * H * 4)
                        out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                        return px
                    }
                    var src = [UInt8](repeating: 0, count: W * H * 4)
                    bars.getBytes(&src, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                    func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 255 }
                    func sumDiff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.reduce(0, +) }
                    // グリッチボックス：ツマミを全部 0（ゲイン 100%）にすると元の絵のまま。乱すと変わり、時間で動き、同じ時刻なら同じ
                    var g0 = Effect(kind: .glitchBox)
                    g0.values = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1]
                    let g = Effect(kind: .glitchBox)
                    let ga = run(g, bars), gb = run(g, bars), gc = run(g, bars, now: 2.7)
                    check(maxDiff(run(g0, bars), src) <= 3 && sumDiff(ga, src) > W * H * 4 && ga == gb && ga != gc,
                          "グリッチボックス：ツマミを 0 にすると元の絵のまま、回すと乱れて時間で動く（同じ時刻なら同じ絵）")
                    // VHS：絵が変わり、時間で動く
                    let v1 = run(Effect(kind: .vhs), bars), v2 = run(Effect(kind: .vhs), bars, now: 2.5)
                    check(sumDiff(v1, src) > W * H && v1 != v2, "VHS テープ：にじみ・ノイズで絵が変わり、時間で動く")
                    // ビデオフィードバック：入力が消えても前の絵が残り（拡大して重なる）、残る強さ 0 ならすぐ消える
                    let dot = pic { x, y in hypot(Double(x - 50), Double(y - 45)) < 10 ? (255, 255, 255, 255) : (0, 0, 0, 0) }
                    let empty = pic { _, _ in (0, 0, 0, 0) }
                    func trail(_ keep: Double) -> Int {
                        var e = Effect(kind: .videoFeedback); e.values[5] = keep
                        var t = 1.0
                        for _ in 0..<20 { _ = run(e, dot, now: t, key: "fb\(keep)"); t += 1.0 / 30 }
                        let after = run(e, empty, now: t, key: "fb\(keep)")
                        return stride(from: 3, to: after.count, by: 4).filter { after[$0] > 20 }.count
                    }
                    let kept = trail(0.6), gone = trail(0)
                    check(kept > 50 && gone < kept / 4,
                          "ビデオフィードバック：入力が消えても前の絵が残って重なり（\(kept) px）、残る強さ 0 ならすぐ消える（\(gone) px）")
                    // ラスタースキャン：線の間は透明。明るい所ほど持ち上がる（高さ 0 と比べて絵が変わる）
                    var rs = Effect(kind: .rasterScan); rs.values[0] = 20
                    var flat = rs; flat.values[1] = 0
                    let ra = run(rs, bars), rf = run(flat, bars)
                    let clear = stride(from: 3, to: ra.count, by: 4).filter { ra[$0] == 0 }.count
                    check(clear > W * H / 5 && ra != rf, "ラスタースキャン：線の間は透明で、明るい所ほど線が持ち上がる")
                    // CRT：角は黒く（ふくらみ）、真ん中は元の絵に近い明るさ。残光：消えたあとも少し残る
                    let crt = run(Effect(kind: .crt), bars, key: "crt")
                    let corner = Int(crt[0]) + Int(crt[1]) + Int(crt[2])
                    let ci = ((H / 2) * W + W / 2) * 4
                    let center = (Int(crt[ci]) + Int(crt[ci + 1]) + Int(crt[ci + 2])), orig = Int(src[ci]) + Int(src[ci + 1]) + Int(src[ci + 2])
                    check(corner < 10 && center > orig / 3, "CRT モニター：角は黒く（画面のふくらみ）、真ん中は元の絵が映る（\(orig)→\(center)）")
                    check(EffectKind.allCases.filter { $0.category == .retro }.count == 5 && !EffectKind.crt.isGenerator,
                          "アナログ機材：5 つが「アナログ機材」の分類に並ぶ")
                }
                // うねり（有機的な歪み）：格子の絵をゆがませる。強さ 0 ならそのまま、時間でゆらぐ（速さ 0 なら止まる）
                do {
                    var grid = Effect(kind: .grid); grid.values = [1, 6, 0.15, 0]
                    func warped(_ w: Effect?, now: Double = 1) -> [UInt8] {
                        let cb = ctx.queue.makeCommandBuffer()!
                        let out = fxp.apply(EffectStack(effects: [grid] + (w.map { [$0] } ?? []), origin: 0),
                                            to: blankT, key: "wp", cb: cb, now: now)
                        cb.commit(); cb.waitUntilCompleted()
                        var px = [UInt8](repeating: 0, count: W * H * 4)
                        out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                        return stride(from: 3, to: px.count, by: 4).map { px[$0] }
                    }
                    let base = warped(nil)
                    var w0 = Effect(kind: .warp); w0.values[0] = 0
                    let wp = Effect(kind: .warp)
                    var still = wp; still.values[2] = 0
                    let wa = warped(wp, now: 1), wb = warped(wp, now: 2)
                    let kinds = (0..<4).map { k -> [UInt8] in var e = wp; e.values[3] = Double(k); e.values[0] = 80; return warped(e) }
                    let litBase = lit(base, x0: 0, x1: W), litWarp = lit(wa, x0: 0, x1: W)
                    check(warped(w0) == base && wa != base && wa != wb && warped(still, now: 1) == warped(still, now: 3)
                          && abs(litWarp - litBase) < litBase / 3 && Set(kinds.map { $0.hashValue }).count == 4
                          && kinds.allSatisfy { $0 != base } && EffectKind.warp.category == .shape && !EffectKind.warp.isGenerator,
                          "うねり：強さ 0 ならそのまま、ゆがませても絵の量は同じくらい（\(litBase)→\(litWarp) px）、時間でゆらぎ、4 種類とも違う")
                    var clear = wp; clear.values[0] = 300; clear.values[7] = 2
                    var fold = clear; fold.values[7] = 1
                    var solid = Effect(kind: .solid)
                    solid.values = [1]
                    func over(_ w: Effect) -> [UInt8] { let g = grid; grid = solid; defer { grid = g }; return warped(w) }
                    check(over(clear).contains(0) && !over(fold).contains(0),
                          "うねり：画面の端を「透明」にすると外は透け、「折り返す」なら透けない")
                }
                let oldDots = try? JSONDecoder().decode(Effect.self, from: Data(#"{"kind":"dots","values":[14,16]}"#.utf8))
                check(oldDots?.values.count == EffectKind.dots.params.count && EffectKind.dots.generatorCategory == .pattern,
                      "ドット：値が足りない保存データも読める・線・模様の分類")
                // 光の流れ：光の面と暗い所があり、ゆっくり動く（0.1 秒ではほとんど変わらない）
                do {
                    var fl = Effect(kind: .flow); fl.values[7] = 0   // ざらつきなしで比べる
                    let f0 = alpha(fl, now: 4), f1 = alpha(fl, now: 4.1), f2 = alpha(fl, now: 12)
                    let bright = f0.filter { $0 > 180 }.count, dark = f0.filter { $0 < 40 }.count
                    let small = zip(f0, f1).map { abs(Int($0) - Int($1)) }.max() ?? 0
                    let big = zip(f0, f2).map { abs(Int($0) - Int($1)) }.max() ?? 0
                    check(bright > 500 && dark > 500 && small < 40 && big > 60,
                          "光の流れ：光の面と暗い所があり、ゆっくり流れる（0.1 秒で最大 \(small)・8 秒で \(big)）")
                }
                check(GeneratorCategory.allCases.flatMap(\.kinds).count == EffectKind.generators.count
                      && EffectKind.generators.allSatisfy { $0.generatorCategory != nil },
                      "ジェネレーター：どれもどこかの分類に入っている")
            }
            // エフェクトを追加するメニュー：一覧と同じエフェクトが全部ある（ジェネレーター・重ね方の値は無い）。足したものは開いておく
            do {
                let listed = AddEffectMenuItems.groups.flatMap(\.1)
                let all = EffectKind.allCases.filter { !$0.isBlend && !$0.isGenerator && $0 != .transitionMask }
                let pad = FXPad()
                let added = pad.addEffectOpened(.mirror)
                check(Set(listed) == Set(all) && listed.count == all.count && pad.effects.map(\.kind) == [.mirror]
                      && EffectUIState.shared.expanded.contains(added.id),
                      "エフェクトを追加するメニュー：エフェクトが分類ごとに全部並び、選ぶと足して開く（\(listed.count) 個）")
            }
            // エフェクトを探す：ひらがな・英語・説明でも当たり、名前に当たるものが先
            do {
                let r1 = EffectPicker.results("みらー", includeGenerators: false)
                let r2 = EffectPicker.results("mask", includeGenerators: false)
                let r3 = EffectPicker.results("マスク", includeGenerators: false)
                let r4 = EffectPicker.results("てきすと", includeGenerators: true)
                let r5 = EffectPicker.results("てきすと", includeGenerators: false)
                let r6 = EffectPicker.results("残像", includeGenerators: false)
                check(r1.first == .mirror && Set(r2.prefix(2)) == [.shapeMask, .polyMask] && Set(r3.prefix(2)) == [.shapeMask, .polyMask]
                      && r4.first == .text && r5.isEmpty && r6.first == .echo
                      && EffectPicker.results("", includeGenerators: true).count == AddEffectMenuItems.groups.flatMap(\.1).count + EffectKind.generators.count,
                      "エフェクトを探す：ひらがな・英語・説明でも当たり、名前が当たるものが先（みらー → \(r1.first?.rawValue ?? "-")）")
            }
            // 色を選ぶ窓：色相・鮮やかさ・明るさ ⇔ RGB、16 進
            do {
                let samples: [RGB] = [.hsb(0.62, 0.7, 1), .hsb(0.1, 1, 0.4), .hsb(0.9, 0.3, 0.8), .white, .black]
                let round = samples.allSatisfy { c in
                    let (h, sv, bv) = c.hsb
                    let back = RGB.hsb(h, sv, bv)
                    return abs(back.r - c.r) < 1e-9 && abs(back.g - c.g) < 1e-9 && abs(back.b - c.b) < 1e-9
                }
                check(round && RGB(hex: "#4D7EFF")?.hex == "#4D7EFF" && RGB(hex: "f80")?.hex == "#FF8800" && RGB(hex: "zz") == nil
                      && RGB.white.hsb.s == 0 && RGB.hsb(0.25, 1, 1).hsb.h == 0.25,
                      "色を選ぶ窓：色相・鮮やかさ・明るさと RGB を行き来できる、16 進（#RRGGBB・3 桁）を読める")
            }
            let slot = ClipSlot(generator: te)
            check(slot.name == "「HELLO」", "テキスト：クリップの名前は最初の行（\(slot.name)）")
        }
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
        // エフェクトの不透明度：元の絵との間
        var half = fx(.invert, [0, 1]); half.mix = 0.5
        r = run([group(clip(tex { _, _ in red }, [half]))])
        check(near(r(3, 3), SIMD3(repeating: 0.5), 4.0 / 255), "エフェクトの不透明度 50%：元の絵との間（赤 → 灰色）")
        var none = fx(.mirror, [1, 0]); none.mix = 0
        r = run([group(clip(halves, [none, fx(.invert, [0, 1])]))])
        check(near(r(1, 3), SIMD3(0, 1, 1)) && near(r(6, 3), SIMD3(1, 1, 0)), "エフェクトの不透明度 0%：かからない（次のエフェクトはかかる）")
        var mixAnim = half; mixAnim.setMixAnim({ var a = ParamAnim(range: 0...1); a.mode = .beat; return a }())
        let mixData = try? JSONEncoder().encode(half)
        check(mixData.flatMap { try? JSONDecoder().decode(Effect.self, from: $0) }?.mix == 0.5 && mixAnim.mixAnim.isOn,
              "エフェクトの不透明度は保存され、動き（BPM など）も付けられる")
        // 以前の保存（かかり具合が値にあり、不透明度が無い）は、不透明度に引き継ぐ
        let oldInvert = #"{"kind":"invert","values":[0,0.4]}"#.data(using: .utf8)!
        let migrated = try? JSONDecoder().decode(Effect.self, from: oldInvert)
        check(migrated.map { abs($0.mix - 0.4) < 1e-9 && $0.value(1) == 1 } ?? false,
              "以前の反転の「かかり具合 40%」は、エフェクトの不透明度 40% に引き継ぐ")
        check(abs((Engine.mixEffects([half], [fx(.invert, [0, 1])], k: 0.5, p: 0.5).first?.mix ?? 0) - 0.75) < 1e-9,
              "シーンのフェードで、エフェクトの不透明度もなめらかに動く")
        // クリップのトランスフォームのあとにエフェクト：180° 回したクリップのミラーは、回った絵が映る
        var turned = clip(halves, [fx(.mirror, [1, 0])])
        turned.transform = ClipTransform(rotation: .pi)
        r = run([group(turned)])
        check(near(r(1, 3), blue) && near(r(6, 3), blue), "クリップのエフェクトは、回したあとの絵にかかる（回転したチェッカーもミラーになる）")
        var shrunk = clip(tex { _, _ in red }, [fx(.mirror, [1, 0])])
        shrunk.transform = ClipTransform(x: -0.25, scale: 0.5)
        r = run([group(clip(tex { _, _ in blue })), { var g = group(shrunk); g.key = 1; return g }()])
        check(near(r(1, 3), red) && near(r(6, 3), red) && near(r(3, 0), blue),
              "左に小さく置いたクリップのミラー：右にも映り、周りは下の絵が見える")
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
        // 調整レイヤーのマスク：下の絵全体を切り抜く（外は黒）。並び順に関係なく最後に切り抜く
        let leftHalf = fx(.shapeMask, [0, 0, -0.25, 0, 0.5, 2, 0, 0])
        for (name, list) in [("マスクが下", [fx(.invert, [0, 1]), leftHalf]), ("マスクが上", [leftHalf, fx(.invert, [0, 1])]),
                             ("マスクだけ", [leftHalf])] {
            r = run([group(clip(tex { _, _ in red })), adjust(list)])
            let inside = list.count == 1 ? red : SIMD3<Float>(0, 1, 1)
            check(near(r(1, 3), inside) && near(r(6, 3), .zero),
                  "調整レイヤーのマスク（\(name)）：下の絵全体を切り抜き、外は黒")
        }
        r = run([group(clip(tex { _, _ in red })), adjust([leftHalf], opacity: 0.5)])
        check(near(r(1, 3), red) && near(r(6, 3), SIMD3(0.5, 0, 0), 4.0 / 255),
              "調整レイヤーのマスク・不透明度 50%：外は半分の暗さ")
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
    /// 再生範囲を 1 コマずつ動かす・端のコマ・コマの並び
    static func testFrameTrim(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let s = ClipSlot(url: URL(fileURLWithPath: paths[0]))
        for _ in 0..<60 where !s.isReady { wait(0.05) }
        guard s.isReady else { check(false, "コマ送り：クリップが読める"); return }
        let f = s.frameLength
        s.stepIn(1)
        check(abs(s.inPoint - f) < 1e-9, String(format: "コマ送り：イン点を 1 コマ後ろへ（%.4f 秒）", f))
        s.stepIn(10)
        check(abs(s.inPoint - 11 * f) < 1e-9, "コマ送り：イン点を 10 コマ後ろへ（コマの区切りにそろう）")
        s.stepIn(-100)
        check(s.inPoint == 0, "コマ送り：先頭より前へは行かない")
        s.stepOut(-3)
        check(abs(s.outTime - (s.duration / f).rounded() * f + 3 * f) < 1e-6 && s.outPoint != nil, "コマ送り：アウト点を 3 コマ前へ")
        s.stepOut(3)
        check(s.outPoint == nil, "コマ送り：最後まで戻すと「最後まで」になる")
        var img: CGImage?
        let done = DispatchSemaphore(value: 0)
        Task { img = await s.exactFrame(at: 1.0); done.signal() }
        for _ in 0..<60 where done.wait(timeout: .now()) == .timedOut { wait(0.05) }
        check(img != nil, "端のコマ：その時刻のコマを取り出せる")
        s.loadFilmstrip(count: 8)
        for _ in 0..<80 where s.filmstrip.isEmpty { wait(0.05) }
        check(s.filmstrip.count == 8, "コマの並び：再生範囲のバーの後ろに並べるコマを作れる")
    }

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

    /// ソロ：ソロのレイヤーだけを出す（映像と音）。確認用で保存しない
    static func testSolo(check: (Bool, String) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.placeGenerator(.solid, at: 0)
        e.placeGenerator(.noise, at: c)
        e.placeGenerator(.stripes, at: 2 * c)
        e.trigger(0); e.trigger(c); e.trigger(2 * c)
        func shown() -> Set<Int> { _ = e.updateFrame(); return Set(e.layerGroups().map(\.key)) }
        check(shown() == [0, 1, 2], "ソロ：はじめは全部出る")
        e.layers[1].solo = true
        check(shown() == [1] && !e.layers[0].audible && e.layers[1].audible && e.layers[0].soloHidden,
              "ソロ：ソロのレイヤーだけが出る（ほかは映像も音も隠れる）")
        e.layers[2].solo = true
        check(shown() == [1, 2], "ソロ：いくつでもソロにできる")
        e.insertLayer(at: 0)
        check(e.layers[0].soloHidden && shown() == [2, 3], "ソロ：レイヤーを足しても、ソロでないものは隠れたまま")
        e.clearSolo()
        check(shown() == [1, 2, 3] && e.layers.allSatisfy { !$0.soloHidden }, "ソロ：全部外すと元に戻る")
        e.layers[1].solo = true
        let e2 = Engine(persistent: false)
        e2.apply(e.makeState(relativeTo: nil), baseDir: nil)
        check(e2.layers.allSatisfy { !$0.solo }, "ソロ：保存しない（確認用）")
        e.layers[1].blend = .add
        _ = e.updateFrame()
        check(e.layerGroups().first { $0.key == 1 }?.blend == .add, "レイヤー欄から重ね方を変えると、出力に効く")
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
        // クリップの見かけの名前：ジェネレーターにも付けられ、複製・保存しても残る。空にすると元の名前
        if let g = e.slots[2 * c] {
            g.title = "オープニングの背景"
            e.duplicateSlot(2 * c, to: 2 * c + 3)
            let st = e.makeState(relativeTo: nil)
            let e3 = Engine(persistent: false)
            e3.apply(st, baseDir: nil)
            let loaded = e3.slots[2 * c]
            check(g.name == "オープニングの背景" && e.slots[2 * c + 3]?.name == "オープニングの背景"
                  && loaded?.name == "オープニングの背景" && loaded?.generator?.kind == .solid,
                  "クリップの名前：ジェネレーターにも付けられ、複製・保存しても残る")
            g.title = ""
            check(g.name == EffectKind.solid.label, "クリップの名前：空にすると元の名前（\(g.name)）")
        }
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

    /// 反応拡散：変わり続ける（育ちきっても止まらない）・音で光って乱れる
    static func testReactionDiffusion(check: (Bool, String) -> Void) {
        let ctx = MetalContext.shared
        let W = 320, H = 180
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead, .renderTarget]; td.storageMode = .shared
        let blank = ctx.device.makeTexture(descriptor: td)!
        func run(drift: Double, flow: Double = 0.5, death: Double = 0, audio: [Double]?, frames: Int, snapshots: [Int]) -> [[UInt8]] {
            AudioReactive.shared.setOverrideForTest(audio)
            defer { AudioReactive.shared.setOverrideForTest(nil) }
            var e = Effect(kind: .reactionDiffusion)
            e.values[7] = drift
            e.values[9] = flow
            e.values[10] = death
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            var shots: [[UInt8]] = []
            for f in 0..<frames {
                let cb = ctx.queue.makeCommandBuffer()!
                let out = fxp.apply(EffectStack(effects: [e]), to: blank, key: "rd", cb: cb, now: 1 + Double(f) / 30)
                cb.commit(); cb.waitUntilCompleted()
                if snapshots.contains(f) {
                    var q = [UInt8](repeating: 0, count: W * H * 4)
                    out.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                    shots.append(q)
                }
            }
            return shots
        }
        func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var d = 0; for i in stride(from: 3, to: a.count, by: 4) { d += abs(Int(a[i]) - Int(b[i])) }
            return Double(d) / Double(a.count / 4) / 255
        }
        func mean(_ a: [UInt8]) -> Double {
            var s = 0; for i in stride(from: 0, to: a.count, by: 4) { s += Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2]) }
            return Double(s) / Double(a.count / 4 * 3) / 255
        }
        // 育ちきった後（30 秒・60 秒）から 2 秒で、どれだけ変わるか（音なし）
        let still = run(drift: 0, flow: 0, audio: [0, 0, 0, 0, 0], frames: 1000, snapshots: [900, 960])
        func dStillDeath() -> Double { diff(still[0], still[1]) * 5 }
        let moving = run(drift: 0.5, flow: 0.5, death: 0.5, audio: [0, 0, 0, 0, 0], frames: 1861, snapshots: [900, 960, 1800, 1860])
        // 枯れるだけ（流れ・変わり続けるは 0）でも、育っては死んでずっと入れかわる
        let dying = run(drift: 0, flow: 0, death: 0.7, audio: [0, 0, 0, 0, 0], frames: 1861, snapshots: [1680, 1740, 1800, 1860])
        let dDie = diff(dying[0], dying[1]) + diff(dying[2], dying[3])
        check(dDie / 2 > 0.03 && dDie / 2 > dStillDeath(),
              "反応拡散：枯れるで、育っては死んで入れかわり続ける（流れ・変わり続けるが 0 でも。2 秒の変化 \(String(format: "%.3f", dDie / 2))）")
        let dStill = diff(still[0], still[1]), d30 = diff(moving[0], moving[1]), d60 = diff(moving[2], moving[3])
        // 確かめ用：VJ_RD_DUMP=フォルダ で、動いている途中のコマを PNG に書き出す
        if let dir = ProcessInfo.processInfo.environment["VJ_RD_DUMP"] {
            for (i, q0) in (moving + dying).enumerated() {
                var q = q0
                for j in stride(from: 0, to: q.count, by: 4) { let b = q[j]; q[j] = q[j + 2]; q[j + 2] = b; q[j + 3] = 255 }
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
                q.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, q.count) }
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/rd_\(i).png"))
            }
        }
        check(d30 > 0.05 && d60 > 0.05 && d30 > dStill * 5,
              "反応拡散：はじめの値で、育ちきってもずっと動き続ける（2 秒の変化 30 秒後 \(String(format: "%.3f", d30))・60 秒後 \(String(format: "%.3f", d60)) ／ 流れも変化も 0 なら \(String(format: "%.3f", dStill))）")
        // 変わり続ける（穴）：急に大きく変わらない。1 コマごとの変化の一番大きい所が小さい
        do {
            AudioReactive.shared.setOverrideForTest([0, 0, 0, 0, 0])
            defer { AudioReactive.shared.setOverrideForTest(nil) }
            var e = Effect(kind: .reactionDiffusion)
            e.values[7] = 1; e.values[9] = 0; e.values[10] = 0
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            var prev: [UInt8]?
            var worst = 0.0
            for f in 0..<1500 {
                let cb = ctx.queue.makeCommandBuffer()!
                let out = fxp.apply(EffectStack(effects: [e]), to: blank, key: "rdh", cb: cb, now: 1 + Double(f) / 30)
                cb.commit(); cb.waitUntilCompleted()
                guard f >= 600 else { continue }
                var q = [UInt8](repeating: 0, count: W * H * 4)
                out.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                if let dir = ProcessInfo.processInfo.environment["VJ_RD_DUMP"], f % 15 == 0, f < 900 {
                    var o = q
                    for j in stride(from: 0, to: o.count, by: 4) { let b = o[j]; o[j] = o[j + 2]; o[j + 2] = b; o[j + 3] = 255 }
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
                    o.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, o.count) }
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/hole_\(f).png"))
                }
                if let p = prev {
                    // 8×8 のかたまりごとの変化のうち、一番大きいもの（穴がポコっと開くと、かたまりが一度に消える）
                    for by in stride(from: 0, to: H - 8, by: 8) { for bx in stride(from: 0, to: W - 8, by: 8) {
                        var s = 0
                        for y in by..<by + 8 { for x in bx..<bx + 8 { let i = (y * W + x) * 4 + 3; s += abs(Int(q[i]) - Int(p[i])) } }
                        worst = max(worst, Double(s) / 64 / 255)
                    } }
                }
                prev = q
            }
            check(worst < 0.35, "反応拡散：変わり続けるを上げても、穴はゆっくり開く（1 コマでのかたまりの変化の一番大きい所 \(String(format: "%.2f", worst))）")
        }
        // 音：大きな音とアタックで、明るくなって乱れる
        let quiet = run(drift: 0, audio: [0, 0, 0, 0, 0], frames: 200, snapshots: [199])
        let loud = run(drift: 0, audio: [1, 1, 0.5, 0.5, 1], frames: 200, snapshots: [199])
        check(mean(loud[0]) > mean(quiet[0]) * 1.2,
              "反応拡散：音の大きさで光り、アタックと低音で乱れて育つ（明るさ \(String(format: "%.3f", mean(quiet[0]))) → \(String(format: "%.3f", mean(loud[0])))）")
    }

    /// 追加のエフェクト・ジェネレーター：どれも描けて（何かが出て）、壊れた値（NaN）が出ない。値の数・分類・説明がそろっている
    static func testMoreKinds(check: (Bool, String) -> Void) {
        // 画質：保存して読み込める。古いデータ（項目なし）は「高」。外の映像の取り込みには出さない
        do {
            var q = Effect(kind: .synthwave); q.quality = 2
            let back = (try? JSONEncoder().encode(q)).flatMap { try? JSONDecoder().decode(Effect.self, from: $0) }
            let old = try? JSONDecoder().decode(Effect.self, from: Data(#"{"kind":"synthwave"}"#.utf8))
            check(back?.quality == 2 && back?.qualityScale == 0.5 && old?.quality == 0 && old?.qualityScale == 1
                  && q.hasQuality && !Effect(kind: .camera).hasQuality && !Effect(kind: .mirror).hasQuality,
                  "ジェネレーターの画質：保存して読み込める。古いデータは「高」。カメラなどの取り込み・エフェクトには無い")
            check(Effect(kind: .synthwave).quality == 2 && Effect(kind: .text).quality == 0 && Effect(kind: .clock).quality == 0,
                  "ジェネレーターの画質：新しく置くものは「低」。文字・時計は「高」")
        }

        let ctx = MetalContext.shared
        let W = 320, H = 180
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead, .renderTarget]; td.storageMode = .shared
        let src = ctx.device.makeTexture(descriptor: td)!
        // 入力：左右で色の違う、まだらの絵
        var px = [UInt8](repeating: 255, count: W * H * 4)
        for y in 0..<H { for x in 0..<W {
            let i = (y * W + x) * 4
            let v = UInt8((x * 255 / W + y * 3) % 256)
            px[i] = v; px[i + 1] = UInt8((y * 255 / H)); px[i + 2] = x < W / 2 ? 230 : 40
        } }
        src.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
        var bad: [String] = []
        for k in EffectKind.moreEffects + EffectKind.moreGenerators {
            let e = Effect(kind: k)
            guard e.values.count == k.params.count, k.moreHelp != nil, k.moreLabel != nil,
                  k.isGenerator == EffectKind.moreGenerators.contains(k),
                  !k.isGenerator || k.generatorCategory != nil else { bad.append("\(k.rawValue)（値・説明・分類）"); continue }
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            var out = src
            for f in 0..<20 {
                let cb = ctx.queue.makeCommandBuffer()!
                out = fxp.apply(EffectStack(effects: [e]), to: src, key: "m", cb: cb, now: 3 + Double(f) / 30)
                cb.commit(); cb.waitUntilCompleted()
            }
            var q = [UInt8](repeating: 0, count: W * H * 4)
            out.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            // 何かが出ている（ジェネレーターは光っている所がある・エフェクトは真っ黒・真っ透明でない）
            var lit = 0
            for i in stride(from: 0, to: q.count, by: 4) where Int(q[i]) + Int(q[i + 1]) + Int(q[i + 2]) > 30 { lit += 1 }
            if lit < W * H / 400 { bad.append("\(k.rawValue)（\(lit) 画素）") }
        }
        check(bad.isEmpty, "追加のエフェクト 11・ジェネレーター 10：どれも描ける・値と説明と分類がそろっている" + (bad.isEmpty ? "" : "（だめ：\(bad.joined(separator: "、"))）"))
        // ロゴを粒に：文字の形の点が作れる（画像が無くても）
        let pts = LogoParticleSim.samplePoints("HALO", count: 500)
        let xs = pts.map(\.0.x)
        check(pts.count == 500 && (xs.max() ?? 0) - (xs.min() ?? 0) > 0.5, "ロゴを粒に：文字の形に点を並べられる")
    }

    /// 出力が切り替わった知らせ：クリップ・まとめて・シーン（中のクリップは数えない）・止めた・自動操縦
    static func testOutputEvents(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        e.placeGenerator(.solid, at: 0); e.placeGenerator(.noise, at: c); e.placeGenerator(.stripes, at: 1)
        e.slots[0]?.title = "赤"
        e.trigger(0); wait(0.05)
        let one = e.outputEvent
        e.trigger(1); e.trigger(c); wait(0.05)
        let two = e.outputEvent
        let sc = e.addScene()
        e.stopAll(); wait(0.05)
        let stop = e.outputEvent
        e.recallScene(sc.id, fade: 0); wait(0.05)
        let scene = e.outputEvent
        e.autopilot = AutoPilot(rules: [AutoRule(target: .layer(0), unit: .minutes, every: 10, jitter: 0, pick: .sequence, fade: 0)],
                                pauseAfterManual: 0)
        e.setAutopilot(true)
        e.autoRunner.skip(e.autopilot.rules[0].id); wait(0.05)
        let auto = e.outputEvent
        e.setAutopilot(false)
        check(one?.kind == .clip && one?.text.contains("L1") == true && two?.text == "2 つのクリップを出した"
              && stop?.text == "2 つのレイヤーを止めた" && scene?.kind == .scene && scene?.text.contains(sc.name) == true
              && auto?.auto == true && auto?.kind == .clip,
              "出力の知らせ：クリップ・まとめて・止めた・シーン（中のクリップは数えない）・自動操縦（\(one?.text ?? "-") / \(two?.text ?? "-") / \(stop?.text ?? "-") / \(scene?.text ?? "-") / \(auto?.text ?? "-")）")
    }

    /// 自動操縦：自動の切り替えは元に戻すの記録に入らない。人の操作は入る
    static func testAutopilotUndo(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        e.placeGenerator(.solid, at: 0)
        e.trigger(0)
        e.layers[0].opacity = 1
        let a = e.addScene()
        e.layers[0].opacity = 0.3
        let b = e.addScene()
        e.recallScene(a.id, fade: 0)
        e.autopilot = AutoPilot(rules: [AutoRule(target: .scenes, unit: .minutes, every: 10, jitter: 0, pick: .sequence, fade: 0)],
                                pauseAfterManual: 0)
        wait(0.8); e.commitUndoStep(); e.resetUndo()
        // 人の操作：不透明度を変える（1 歩）
        e.layers[0].opacity = 0.7
        wait(0.8)
        // 自動で切り替える（シーン b：不透明度 0.3）
        e.setAutopilot(true)
        e.autoRunner.skip(e.autopilot.rules[0].id)
        let afterAuto = e.layers[0].opacity
        wait(2.0)
        // ⌘Z：自動の切り替えは飛ばして、人の操作（0.7 にした）を 1 つ戻す → 不透明度 1
        e.undo()
        let afterUndo = e.layers[0].opacity
        e.setAutopilot(false)
        check(abs(afterAuto - 0.3) < 1e-9 && abs(afterUndo - 1) < 1e-9 && !e.undoHistory.canUndo,
              "自動操縦：自動の切り替えは元に戻すの記録に入らず、⌘Z で自分の操作が戻る（自動のあと \(afterAuto) → 戻すと \(afterUndo)）")
        _ = b
    }

    /// 自動操縦：時間・小節ごとに回す、順に／ばらばら、人が触ったら休む、保存
    static func testAutopilot(check: (Bool, String) -> Void) {
        let e = Engine(persistent: false)
        let c = e.columns
        for k in 0..<4 { e.placeGenerator(.solid, at: k) }          // L1 に 4 つ
        e.placeGenerator(.noise, at: c); e.placeGenerator(.stripes, at: c + 1)  // L2 に 2 つ
        e.trigger(0)
        let s1 = e.addScene()
        e.trigger(1)
        let s2 = e.addScene()
        e.trigger(2)
        let s3 = e.addScene()
        let run = e.autoRunner
        let t0 = CACurrentMediaTime()
        var now = t0
        run.clock = { now }
        // シーンを 10 秒ごと（ゆらぎなし）・順に
        e.autopilot = AutoPilot(rules: [AutoRule(target: .scenes, unit: .seconds, every: 10, jitter: 0, pick: .sequence, fade: 0)],
                                pauseAfterManual: 30)
        e.recallScene(s1.id, fade: 0)
        e.setAutopilot(true)
        now += 5; run.tick()
        let before = e.activeSceneID
        now += 5.1; run.tick()
        let a1 = e.activeSceneID
        now += 10.1; run.tick()
        let a2 = e.activeSceneID
        check(before == s1.id && a1 == s2.id && a2 == s3.id, "自動操縦：決めた秒数ごとに、シーンを順に回す")
        // 人がシーンを出したら休む（30 秒）。休みが明けたらまた回る
        e.recallScene(s1.id, fade: 0)
        now += 10.1; run.tick(); now += 10.1; run.tick()
        let paused = e.activeSceneID
        now += 15; run.tick(); now += 10.1; run.tick()
        check(paused == s1.id && e.activeSceneID != s1.id && run.nextInfo != nil,
              "自動操縦：人がシーンを出すとしばらく休み、明けたらまた回す")
        // ばらばら：今のものは続けて選ばない。何度回しても、同じものが続かない
        e.autopilot.rules[0].pick = .random
        var last = e.activeSceneID, repeats = 0, seen = Set<UUID>()
        for _ in 0..<30 {
            now += 10.1; run.tick()
            if e.activeSceneID == last { repeats += 1 }
            last = e.activeSceneID
            if let a = last { seen.insert(a) }
        }
        check(repeats == 0 && seen.count == 3, "自動操縦：ばらばらでも同じシーンを続けず、全部を使う")
        // 使うシーンを絞る
        e.autopilot.rules[0].sceneIDs = [s1.id, s3.id]
        var only = true
        for _ in 0..<10 { now += 10.1; run.tick(); if e.activeSceneID == s2.id { only = false } }
        check(only, "自動操縦：選んだシーンだけを使う")
        // レイヤーのクリップを小節ごと（240 BPM で 1 小節 1 秒）。小節の区切りで替わる
        e.bpm = 240
        e.autopilot = AutoPilot(rules: [AutoRule(target: .layer(1), unit: .bars, every: 2, jitter: 0, pick: .sequence, fade: 0)],
                                pauseAfterManual: 0)
        e.trigger(c)
        let bar0 = Int(floor(e.beatClockForOSC().beat(at: now) / 4))
        run.tick()
        // 次の 2 小節の区切りの少し後へ
        let target = Double((bar0 / 2 + 1) * 2) * 4
        let clockNow = e.beatClockForOSC()
        var tt = now
        while clockNow.beat(at: tt) < target + 0.2 { tt += 0.05 }
        now = tt; run.tick()
        check(e.beatClockForOSC().bpm == 240 && e.activeByLayer[1] == c + 1, "自動操縦：レイヤーのクリップを、小節の区切りで替える")
        // 自動で出したものは、人の操作と数えない（休まない）／オフにすると止まる
        e.setAutopilot(false)
        let off = e.activeByLayer[1]
        now += 30; run.tick()
        check(e.activeByLayer[1] == off && run.nextInfo == nil, "自動操縦：オフにすると止まる")
        // プロジェクトに保存される（オン・オフは保存しない）
        let o = Engine(persistent: false)
        o.apply(e.makeState(relativeTo: nil), baseDir: nil)
        check(o.autopilot.rules.first?.target == .layer(1) && o.autopilot.rules.first?.unit == .bars && !o.autoRunner.isOn,
              "自動操縦：ルールはプロジェクトに保存される（開いたときはオフ）")
        // ルールが無いときにオンにすると、おまかせのルールを作る（シーンが 2 つ以上 → シーンを回す）
        let f = Engine(persistent: false)
        f.placeGenerator(.solid, at: 0); f.trigger(0); _ = f.addScene(); _ = f.addScene()
        f.setAutopilot(true)
        check(f.autopilot.rules.first?.target == .scenes && f.autoRunner.isOn, "自動操縦：ルールが無ければ、おまかせのルールで始める")
        f.setAutopilot(false)
        // OSC からオン・オフ
        OSCCommands.run(OSCMessage(address: "/halo/auto", args: [.float(1)]), engine: f)
        let on1 = f.autoRunner.isOn
        OSCCommands.run(OSCMessage(address: "/halo/auto", args: [.float(0)]), engine: f)
        check(on1 && !f.autoRunner.isOn, "自動操縦：OSC（/halo/auto）でオン・オフできる")
        _ = s2
    }

    /// シーン：流すクリップのエフェクト・位置などを記録して、呼び出すとその値に（フェード中はなめらかに）
    static func testSceneClipSettings(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        e.placeGenerator(.solid, at: 0)
        let clip = e.slots[0]!
        e.trigger(0)
        var blur = Effect(kind: .levels); blur.values[0] = 0.8
        clip.posX = 0.3; clip.scale = 1.5; clip.rotation = 40; clip.opacity = 0.6; clip.effects = [blur]
        let a = e.addScene()
        check(a.clipSettings?[0]?.id == clip.id && a.clipSettings?[0]?.x == 0.3 && a.clipSettings?[0]?.effects.first?.kind == .levels,
              "シーン：流しているクリップのエフェクト・位置などを記録する")
        // 値を変えて別のシーン
        var blur2 = blur; blur2.values[0] = 0.2
        clip.posX = -0.3; clip.scale = 0.5; clip.rotation = 0; clip.opacity = 1; clip.effects = [blur2]
        let b = e.addScene()
        e.updateScene(a.id) { $0.fade = 0 }
        e.recallScene(a.id)
        check(clip.posX == 0.3 && clip.scale == 1.5 && clip.rotation == 40 && clip.opacity == 0.6 && clip.effects.first?.values[0] == 0.8,
              "シーン：呼び出すと、クリップがシーンの値になる")
        // フェード：途中は間の値
        e.updateScene(b.id) { $0.fade = 0.6 }
        e.recallScene(b.id)
        wait(0.3)
        let mid = clip.posX, midBlur = clip.effects.first?.values[0] ?? -1
        wait(0.6)
        check(mid < 0.3 && mid > -0.3 && midBlur < 0.8 && midBlur > 0.2 && clip.posX == -0.3 && clip.effects.first?.values[0] == 0.2,
              "シーン：フェードの間、クリップの値もなめらかに動く（途中 x \(String(format: "%.2f", mid))）")
        // 前に作ったシーン（クリップの記録が無い）は、クリップの値を変えない
        e.updateScene(a.id) { $0.clipSettings = nil }
        e.recallScene(a.id)
        check(clip.posX == -0.3, "シーン：クリップの記録が無い前のシーンは、クリップの値を変えない")
        // シーンの編集：記録し直す
        clip.posX = 0.1
        e.recordSceneClipSettings(a.id)
        check(e.scenes.first { $0.id == a.id }?.clipSettings?[0]?.x == 0.1, "シーンの編集：クリップの設定を今の値で記録し直せる")
        // 保存して読み込んでも残る
        let o = Engine(persistent: false)
        o.apply(e.makeState(relativeTo: nil), baseDir: nil)
        check(o.scenes.first { $0.id == a.id }?.clipSettings?[0]?.x == 0.1, "シーン：クリップの設定はプロジェクトに保存される")
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
        check(f != nil && f?.texture.height == 540 && f?.pixelBuffer == nil, "ジェネレーターを再生すると、描いた絵がレイヤーに出る（新しく置いたものは画質「低」なので半分の大きさ）")
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

        let mixer = AudioOutput.shared.masterMixer
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

    /// 開発用：テキストのジェネレーターのいろいろな見た目を 1 枚に並べて書き出す
    ///   VJPlayer --text-preview out.png [時刻]
    static func textPreview(path: String, time: Double) {
        let ctx = MetalContext.shared
        let cw = 640, ch = 360, cols = 3
        // （文字, 動き, フォント, 塗り, 波, グリッチ, 縁取り, 大きさ）
        let looks: [(String, Double, Double, Double, Double, Double, Double, Double)] = [
            ("HALO VJ", 0, 0, 0, 0, 0, 0, 0.22),
            ("夜明けまで踊れ", 0, 2, 1, 0, 0, 0, 0.18),
            ("NO SLEEP\nTILL DAWN", 0, 5, 0, 0, 0, 1, 0.2),
            ("BASS ", 1, 4, 1, 0, 0, 0, 0.3),
            ("TOKYO TECHNO", 3, 6, 0, 0, 0, 0, 0.12),
            ("GLITCH", 0, 4, 0, 0, 0.8, 0, 0.3),
            ("wave", 0, 9, 1, 0.8, 0, 0, 0.3),
            ("タイプライター", 4, 8, 0, 0, 0, 0, 0.14),
            ("Didot", 5, 7, 0, 0, 0, 0, 0.3),
        ]
        let rows = (looks.count + cols - 1) / cols
        let W = cw * cols, H = ch * rows
        var sheet = [UInt8](repeating: 0, count: W * H * 4)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: cw, height: ch, mipmapped: false)
        td.usage = [.shaderRead]
        let blank = ctx.device.makeTexture(descriptor: td)!
        let fxp = EffectProcessor(); fxp.storageMode = .shared
        for (n, l) in looks.enumerated() {
            var e = Effect(kind: .text)
            e.text = l.0
            e.values[0] = l.1; e.values[6] = l.2; e.values[5] = l.3; e.values[3] = l.4; e.values[4] = l.5
            e.values[9] = l.6; e.values[1] = l.7
            if l.3 > 0.5 { e.palette = PalettePreset.all[3].colors }
            let cb = ctx.queue.makeCommandBuffer()!
            let out = fxp.apply(EffectStack(effects: [e]), to: blank, key: "p\(n)", cb: cb, now: time)
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: cw * ch * 4)
            out.getBytes(&px, bytesPerRow: cw * 4, from: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0)
            let ox = (n % cols) * cw, oy = (n / cols) * ch
            for y in 0..<ch { for x in 0..<cw {
                let i = (y * cw + x) * 4, j = ((oy + y) * W + ox + x) * 4
                let a = Double(px[i + 3]) / 255
                let bg: Double = (x == 0 || y == 0) ? 90 : 22
                // BGRA（色に不透明度が掛かっている）→ 暗い下地に重ねて RGBA
                sheet[j] = UInt8(min(Double(px[i + 2]) + bg * (1 - a), 255))
                sheet[j + 1] = UInt8(min(Double(px[i + 1]) + bg * (1 - a), 255))
                sheet[j + 2] = UInt8(min(Double(px[i]) + bg * (1 - a), 255))
                sheet[j + 3] = 255
            } }
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
        sheet.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, sheet.count) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("書き出しました: \(path)")
    }

    /// 開発用：ジェネレーターを 1 枚（1280×720、暗い下地）書き出す。かかった GPU 時間も出す
    /// NDI：自分で出した NDI を探して受け取り、色が合っているか
    static func testNDI(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        guard NDIRuntime.available else { print("SKIP NDI：NDI ランタイムが見つからない"); return }
        print("NDI ランタイム：\(NDIRuntime.libraryPath)（\(NDIRuntime.version)）")
        let ctx = MetalContext.shared
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 320, height: 180, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let src = ctx.device.makeTexture(descriptor: td)!
        var px = [UInt8](repeating: 0, count: 320 * 180 * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = 30; px[i + 1] = 60; px[i + 2] = 230; px[i + 3] = 255 }
        src.replace(region: MTLRegionMake2D(0, 0, 320, 180), mipmapLevel: 0, withBytes: px, bytesPerRow: 320 * 4)
        let out = NDIOutput.shared
        out.forTests = true
        let name = "HaloTest\(Int.random(in: 1000..<9999))"
        out.name = name
        out.enabled = true
        check(out.isOn, "NDI：送り手を作れる")
        func pump() {
            if let cb = ctx.queue.makeCommandBuffer() { out.publish(src, cb: cb); cb.commit() }
            wait(0.03)
        }
        var found: String?
        let t0 = CACurrentMediaTime()
        while found == nil && CACurrentMediaTime() - t0 < 10 {
            pump()
            found = NDIFinder.shared.sources(includeSelf: true).first { $0.hasSuffix("(\(name))") }
        }
        check(found != nil && !NDIFinder.shared.sources().contains(found ?? ""), "NDI：自分の出力が見つかる（選ぶ一覧には出さない）\(found ?? "")")
        guard let found else { out.enabled = false; return }
        // 送っている最中に名前を何度も打ち直しても落ちない（打ち終わってから 1 回だけ出し直す）
        let before = out.sentFrames
        for k in 0..<12 { out.name = name + String(repeating: "x", count: k % 4); pump() }
        out.name = name
        for _ in 0..<20 { pump() }
        check(out.isOn && out.sentFrames > before, "NDI：送っている最中に名前を打ち直しても落ちず、送り続ける")
        var tex: MTLTexture?
        let t1 = CACurrentMediaTime()
        while tex == nil && CACurrentMediaTime() - t1 < 10 {
            pump()
            tex = NDIInputs.shared.frame(found)
        }
        var got = [UInt8](repeating: 0, count: 4)
        if let tex { tex.getBytes(&got, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(tex.width / 2, tex.height / 2, 1, 1), mipmapLevel: 0) }
        let near = { (a: UInt8, b: UInt8) in abs(Int(a) - Int(b)) <= 12 }
        check(tex?.width == 320 && tex?.height == 180 && near(got[0], 30) && near(got[1], 60) && near(got[2], 230),
              "NDI：送った絵を受け取れる（\(tex?.width ?? 0)×\(tex?.height ?? 0)、色 \(got)、送った \(out.sentFrames) 枚）")
        // ジェネレーター「NDI から」で枠に置ける（BGRX は不透明として読む）
        var e = Effect(kind: .ndiIn); e.text = found
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 36, mipmapped: false)
        dd.usage = [.renderTarget, .shaderRead]; dd.storageMode = .shared
        let dst = ctx.device.makeTexture(descriptor: dd)!
        if let cb = ctx.queue.makeCommandBuffer() {
            SyphonDraw.shared.renderNDI(e, into: dst, now: CACurrentMediaTime(), stack: EffectStack(), cb: cb)
            cb.commit(); cb.waitUntilCompleted()
        }
        dst.getBytes(&got, bytesPerRow: 64 * 4, from: MTLRegionMake2D(32, 18, 1, 1), mipmapLevel: 0)
        check(near(got[2], 230) && got[3] > 240, "NDI：ジェネレーター「NDI から」で枠に置ける（色 \(got)）")
        out.enabled = false
        NDIInputs.shared.stopAll()
        check(!out.isOn, "NDI：止められる")
    }

    /// 照明：Art-Net のパケット・灯体ごとのチャンネル・本当に UDP で届くか
    static func testArtNet(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let pk = ArtNetOutput.packet(universe: 0x0102, data: [1, 2, 3], sequence: 7)
        check(Array(pk.prefix(8)) == Array("Art-Net".utf8) + [0] && pk[8] == 0x00 && pk[9] == 0x50 && pk[11] == 14 && pk[12] == 7
              && pk[14] == 0x02 && pk[15] == 0x01 && pk[16] == 0 && pk[17] == 4 && Array(pk.suffix(4)) == [1, 2, 3, 0],
              "照明：Art-Net（ArtDmx）のパケットの形（ユニバース・長さは偶数）")
        // 左が赤・右が青、上の行だけ白の絵
        let W = 128, H = 72
        var px = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H { for x in 0..<W {
            let i = (y * W + x) * 4
            if y < 4 { px[i] = 255; px[i + 1] = 255; px[i + 2] = 255 } else if x < W / 2 { px[i + 2] = 255 } else { px[i] = 255 }
            px[i + 3] = 255
        } }
        var m = DMXMap(); m.gamma = 1
        var a1 = DMXFixture(); a1.kind = .rgb; a1.channel = 1; a1.start = [0.25, 0.5]
        var l1 = DMXFixture(); l1.kind = .line; l1.channel = 10; l1.pixels = 4; l1.start = [0.1, 0.5]; l1.end = [0.9, 0.5]
        var w1 = DMXFixture(); w1.kind = .rgbw; w1.channel = 30; w1.start = [0.5, 0.01]
        var d1 = DMXFixture(); d1.kind = .dimmer; d1.channel = 40; d1.start = [0.75, 0.5]
        var big = DMXFixture(); big.kind = .line; big.universe = 3; big.channel = 1; big.pixels = 200; big.start = [0, 0.5]; big.end = [1, 0.5]
        m.fixtures = [a1, l1, w1, d1, big]
        let u = m.universes(pixels: px, width: W, height: H)
        let u0 = u[0] ?? []
        check(Array(u0[0..<3]) == [255, 0, 0] && Array(u0[9..<21]) == [255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255]
              && Array(u0[29..<33]) == [0, 0, 0, 255] && u0[39] == 18 && u[3]?.count == 512 && (u[4]?[87] ?? 0) == 255 && (u[4]?[88] ?? 1) == 0,
              "照明：灯体ごとに、取る所の色を決めたチャンネルへ（RGB・LED テープ・白は W に・明るさだけ・512 を超えたら次のユニバース）")
        // 壊れた設定（取る所の数が足りない）を読んでも落ちない
        let broken = #"{"fixtures":[{"kind":3,"start":[],"end":[0.2]}],"brightness":1,"gamma":1}"#
        let bm = try? JSONDecoder().decode(DMXMap.self, from: Data(broken.utf8))
        check(bm?.fixtures.first?.start.count == 2 && bm?.fixtures.first?.end.count == 2 && bm.map { !$0.universes(pixels: px, width: W, height: H).isEmpty } == true,
              "照明：壊れた灯体の設定を読んでも落ちない（足りない値は初めの値に）")
        // 本当に送る：自分あてに送って受け取る
        let port = UInt16(40_000 + Int.random(in: 0..<500))
        let rs = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(rs, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(rs, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let out = ArtNetOutput.shared
        out.forTests = true
        out.port = port
        out.host = "127.0.0.1"
        out.setMap(m)
        out.update(pixels: px, width: W, height: H)
        out.enabled = true
        var buf = [UInt8](repeating: 0, count: 600)
        var got = 0
        let t0 = CACurrentMediaTime()
        while got <= 0 && CACurrentMediaTime() - t0 < 2 { got = recv(rs, &buf, buf.count, 0); if got <= 0 { wait(0.05) } }
        out.enabled = false
        close(rs)
        check(got >= 18 && Array(buf.prefix(8)) == Array("Art-Net".utf8) + [0], "照明：Art-Net を UDP で送れる（\(got) バイト届いた）")
    }

    /// 素材をまとめて保存：同じ素材は 1 回だけ、名前がぶつかったら番号、もう一度まとめると使い回す。開き直すとコピーを読む
    static func testCollect(paths: [String], check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("vjplayer-collect-test", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp.appendingPathComponent("other"), withIntermediateDirectories: true)
        // 別のフォルダの、同じ名前の別の動画
        let sameName = tmp.appendingPathComponent("other").appendingPathComponent(URL(fileURLWithPath: paths[0]).lastPathComponent)
        try? fm.copyItem(at: URL(fileURLWithPath: paths[1]), to: sameName)
        let e = Engine(persistent: false)
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 1)
        e.load(urls: [sameName], startingAt: 2)
        _ = e.placeGenerator(.solid, at: 3)
        let out = tmp.appendingPathComponent("out")
        let r1 = try? Engine.collect(e.collectPlan(into: out, name: "まとめ"))
        let r2 = try? Engine.collect(e.collectPlan(into: out, name: "まとめ"))
        let media = out.appendingPathComponent("まとめ/素材")
        let names = ((try? fm.contentsOfDirectory(atPath: media.path)) ?? []).sorted()
        let base = URL(fileURLWithPath: paths[0]).lastPathComponent
        let stem = URL(fileURLWithPath: paths[0]).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: paths[0]).pathExtension
        check(r1?.copied == 2 && names == [stem + " 2." + ext, base].sorted() && r2?.copied == 0 && r2?.reused == 2,
              "素材をまとめて保存：同じ素材は 1 回だけ、同じ名前の別の素材は番号を付けてコピー。もう一度まとめると使い回す（\(names)）")
        // 開き直すと、まとめたコピーを読む（元の場所に無くても、プロジェクトのフォルダからの場所で）
        var ok = false
        if let url = r1?.projectURL, let data = try? Data(contentsOf: url),
           let st = try? JSONDecoder().decode(Engine.SavedState.self, from: data) {
            let rel = st.slots.compactMap { $0 }.compactMap(\.relPath)
            let back = Engine(persistent: false)
            back.apply(st, baseDir: url.deletingLastPathComponent())
            ok = rel.filter { $0.hasPrefix("素材/") }.count == 3 && back.slots[0]?.url.path.contains("まとめ/素材/") == true
                && back.slots[3]?.generator?.kind == .solid
        }
        check(ok, "素材をまとめて保存：プロジェクトには「素材/名前」で書き、開き直すとコピーを読む（ジェネレーターもそのまま）")
        // まとめたものに、別の場所の同じ名前の素材を先に足して、もう一度同じ所にまとめる：「素材」の中の元の素材を消さない
        let inMedia = media.appendingPathComponent(base)
        let size0 = (try? fm.attributesOfItem(atPath: paths[0])[.size] as? Int) ?? -1
        let again = Engine(persistent: false)
        again.load(urls: [sameName], startingAt: 0)
        again.load(urls: [inMedia], startingAt: 1)
        let r3 = try? Engine.collect(again.collectPlan(into: out, name: "まとめ"))
        let size1 = (try? fm.attributesOfItem(atPath: inMedia.path)[.size] as? Int) ?? -2
        check(r3 != nil && size1 == size0 && r3?.missing.isEmpty == true,
              "素材をまとめて保存：もう「素材」の中にある素材は、別の場所の同じ名前の素材に上書きされない")
        try? fm.removeItem(at: tmp)
    }

    /// 音の形：スペクトラムで高さの違う音が別の帯に出る。棒・波形が描ける
    static func testAudioScope(check: (Bool, String) -> Void) {
        func peakBand(_ hz: Double) -> Int {
            let an = SpectrumAnalyzer()
            let x = (0..<4096).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / 48000)) }
            let r = an.process(x, sampleRate: 48000, autoGain: true)
            return r.spectrum.indices.max { r.spectrum[$0] < r.spectrum[$1] } ?? -1
        }
        let b100 = peakBand(100), b1k = peakBand(1000), b5k = peakBand(5000)
        check(b100 >= 0 && b100 < b1k && b1k < b5k && b1k > 40 && b1k < 90,
              "音の形：低い音・高い音が、スペクトラムの別の帯に出る（100 Hz → \(b100)・1 kHz → \(b1k)・5 kHz → \(b5k) / 128）")
        // 描く：左（低い方）だけ大きいスペクトラム・正弦波の波形
        AudioScopeSim.testScope = ((0..<128).map { $0 < 64 ? 0.8 : 0 }, (0..<512).map { Float(sin(Double($0) / 512 * 2 * .pi)) })
        let ctx = MetalContext.shared
        let W = 160, H = 90
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead]; td.storageMode = .shared
        let blank = ctx.device.makeTexture(descriptor: td)!
        let fxp = EffectProcessor(); fxp.storageMode = .shared
        func alpha(_ shape: Int) -> [UInt8] {
            var e = Effect(kind: .audioScope); e.values[0] = Double(shape)
            let cb = ctx.queue.makeCommandBuffer()!
            let o = fxp.apply(EffectStack(effects: [e]), to: blank, key: "sc\(shape)", cb: cb, now: 1)
            cb.commit(); cb.waitUntilCompleted()
            var q = [UInt8](repeating: 0, count: W * H * 4)
            o.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            return stride(from: 3, to: q.count, by: 4).map { q[$0] }
        }
        let bars = alpha(0), wave = alpha(2), circle = alpha(3), circleWave = alpha(4)
        func lit(_ a: [UInt8], _ x0: Int, _ x1: Int) -> Int { var n = 0; for y in 0..<H { for x in x0..<x1 where a[y * W + x] > 128 { n += 1 } }; return n }
        AudioScopeSim.testScope = nil
        check(lit(bars, 0, 70) > 500 && lit(bars, 90, 160) == 0 && lit(wave, 0, 160) > 100 && lit(circle, 0, 160) > 50,
              "音の形：棒（大きい帯だけ伸びる）・波形・円が描ける（まわりは透明）")
        // 円の波形：一周でつながる（真下に切れ目が無い）。真下のまわりの列に線がある
        let bottom = (0..<H).filter { y in (W / 2 - 1...W / 2 + 1).contains { circleWave[y * W + $0] > 100 } }
        check(bottom.contains { $0 > H / 2 }, "音の形：円の波形は一周でつながる（真下も途切れない）")
        // 波形の頭をそろえる：同じ音を少しずらして切り出しても、ほぼ同じ形になる（跳ねない）
        let an = SpectrumAnalyzer()
        let tone: [Float] = (0..<8000).map { (i: Int) -> Float in
            let t = Double(i) / 48000
            let v: Double = 0.5 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 660 * t)
            return Float(v)
        }
        let w1 = an.process(Array(tone[0..<4096]), sampleRate: 48000, autoGain: true).wave
        let w2 = an.process(Array(tone[137..<(137 + 4096)]), sampleRate: 48000, autoGain: true).wave
        let diff = zip(w1.prefix(512), w2.prefix(512)).map { abs($0 - $1) }.max() ?? 9
        check(diff < 0.1, "音の形：波形はオシロスコープのように頭がそろう（ずらして切っても差 \(String(format: "%.3f", diff))）")
        // 届くかたまりの間も「今」へ少しずつ進む（100 ms ごとに届いても、描くたびに動く）
        let ar = AudioReactive.shared
        let saved = ar.scopeLock.withLock { (ar.scopeRing, ar.scopeWritten, ar.scopeLastCount, ar.scopeLastTime, ar.scopeRate) }
        let t0 = CACurrentMediaTime()
        ar.scopeLock.withLock {
            for i in 0..<ar.scopeRing.count { ar.scopeRing[i] = Float(i) }
            ar.scopeWritten = ar.scopeRing.count; ar.scopeLastCount = 4800; ar.scopeLastTime = t0; ar.scopeRate = 48000
        }
        let a1 = ar.scopeSamples(count: 16, now: t0)?.samples.last ?? -1
        let a2 = ar.scopeSamples(count: 16, now: t0 + 1.0 / 60)?.samples.last ?? -1
        let a3 = ar.scopeSamples(count: 16, now: t0 + 0.2)?.samples.last ?? -1
        ar.scopeLock.withLock { (ar.scopeRing, ar.scopeWritten, ar.scopeLastCount, ar.scopeLastTime, ar.scopeRate) = saved }
        check(abs((a2 - a1) - 800) < 2 && a3 == Float(ar.scopeRing.count - 1),
              "音の形：届くかたまりの間も、描くたびに「今」へ進む（1/60 秒で \(Int(a2 - a1)) 個。届いた分の先へは行かない）")
    }

    /// HAP：Snappy・区切りの読み方と、自前で書いた HAP の動画（.mov）を読んで色が合うか
    static func testHap(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        // Snappy：文字のまま（literal）と、前の所の写し（copy）
        let sn: [UInt8] = [12, (4 - 1) << 2, 97, 98, 99, 100, 0x01 | ((8 - 4) << 2), 4]
        let un = try? Hap.snappy(sn)
        check(un.map { String(decoding: $0, as: UTF8.self) } == "abcdabcdabcd" && (try? Hap.snappy([5, 0])) == nil,
              "HAP：Snappy をほどける（写しも）。壊れたものは読まない")
        // 分けて圧縮したコマで、場所の表が大きさの表より短い（壊れたファイル）：落ちずに読まない
        do {
            func sec(_ type: UInt8, _ body: [UInt8]) -> [UInt8] { [UInt8(body.count & 0xFF), UInt8((body.count >> 8) & 0xFF), 0, type] + body }
            func l32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
            let inner = sec(0x02, [0x0A, 0x0A]) + sec(0x03, l32(4) + l32(4)) + sec(0x04, l32(0) + [1, 2])
            let frame = sec(0xCB, sec(0x01, inner) + [UInt8](repeating: 0, count: 8))
            check((try? Hap.decodeFrame(frame)) == nil, "HAP：表の壊れたコマでも落ちずに、読まないで済ませる")
        }
        // 自前の HAP の書き方（単色のブロックだけ）
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        func head(_ type: UInt8, _ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), type] }
        func rgb565(_ r: Double, _ g: Double, _ b: Double) -> Int {
            Int((r * 31).rounded()) << 11 | Int((g * 63).rounded()) << 5 | Int((b * 31).rounded())
        }
        let W = 64, H = 32, blocks = (W / 4) * (H / 4)
        func dxt1(_ r: Double, _ g: Double, _ b: Double) -> [UInt8] {
            let c = rgb565(r, g, b)
            return (0..<blocks).flatMap { _ in le16(c) + le16(c) + [0, 0, 0, 0] }
        }
        func dxt5(_ r: Double, _ g: Double, _ b: Double, alpha: Double) -> [UInt8] {
            let c = rgb565(r, g, b), a = UInt8((alpha * 255).rounded())
            return (0..<blocks).flatMap { _ in [a, a, 0, 0, 0, 0, 0, 0] + le16(c) + le16(c) + [0, 0, 0, 0] }
        }
        func snappyLiteral(_ d: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            var n = d.count
            repeat { out.append(UInt8(n & 0x7F) | (n > 0x7F ? 0x80 : 0)); n >>= 7 } while n > 0
            var i = 0
            while i < d.count { let k = min(60, d.count - i); out.append(UInt8((k - 1) << 2)); out += d[i..<i + k]; i += k }
            return out
        }
        func frameNone(_ fmt: UInt8, _ d: [UInt8]) -> [UInt8] { head(0xA0 | fmt, d.count) + d }
        func frameSnappy(_ fmt: UInt8, _ d: [UInt8]) -> [UInt8] { let z = snappyLiteral(d); return head(0xB0 | fmt, z.count) + z }
        func frameChunked(_ fmt: UInt8, _ d: [UInt8]) -> [UInt8] {
            let half = d.count / 2
            let c1 = Array(d[0..<half]), c2 = snappyLiteral(Array(d[half...]))
            let comps = head(0x02, 2) + [0x0A, 0x0B]
            let sizes = head(0x03, 8) + le32(c1.count) + le32(c2.count)
            let instr = head(0x01, comps.count + sizes.count) + comps + sizes
            let payload = instr + c1 + c2
            return head(0xC0 | fmt, payload.count) + payload
        }
        // .mov に書く（AVFoundation は HAP を読み解けないが、入れ物には入れられる）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vjplayer-hap-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func writeMov(_ name: String, codec: String, frames: [[UInt8]]) -> URL? {
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreate(allocator: nil, codecType: Hap.fourCC(codec), width: Int32(W), height: Int32(H),
                                           extensions: nil, formatDescriptionOut: &fd)
            guard let fd, let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
            guard w.canAdd(input) else { return nil }
            w.add(input)
            guard w.startWriting() else { return nil }
            w.startSession(atSourceTime: .zero)
            for (k, f) in frames.enumerated() {
                var bb: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: f.count, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: f.count, flags: 0, blockBufferOut: &bb)
                guard let bb else { return nil }
                f.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: f.count) }
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10), presentationTimeStamp: CMTime(value: CMTimeValue(k), timescale: 10),
                                                decodeTimeStamp: .invalid)
                var size = f.count
                var sb: CMSampleBuffer?
                CMSampleBufferCreate(allocator: nil, dataBuffer: bb, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                     formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                     sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
                guard let sb else { return nil }
                while !input.isReadyForMoreMediaData { wait(0.01) }
                input.append(sb)
            }
            input.markAsFinished()
            var done = false
            w.finishWriting { done = true }
            let t0 = CACurrentMediaTime()
            while !done && CACurrentMediaTime() - t0 < 5 { wait(0.02) }
            return w.status == .completed ? url : nil
        }
        /// 動画の k コマ目（0.1 秒ずつ）の真ん中の色（BGRA）
        func colors(_ url: URL, count: Int) -> [[Int]] {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first, Hap.isHap(track),
                  let fs = try? FrameStream(asset: asset, track: track, capacity: 8) else { return [] }
            fs.waitUntilPrimed(timeout: 3)
            var out: [[Int]] = []
            for k in 0..<count {
                let t0 = CACurrentMediaTime()
                var f = fs.frame(at: Double(k) / 10 + 0.01)
                while (f == nil || abs(f!.pts - Double(k) / 10) > 0.02) && CACurrentMediaTime() - t0 < 2 { wait(0.02); f = fs.frame(at: Double(k) / 10 + 0.01) }
                guard let pb = f?.buffer else { out.append([]); continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                let i = (H / 2) * bpr + (W / 2) * 4
                out.append([Int(base[i]), Int(base[i + 1]), Int(base[i + 2]), Int(base[i + 3])])
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
            fs.cancel()
            return out
        }
        func near(_ c: [Int], _ e: [Int], _ tol: Int = 12) -> Bool { c.count == 4 && zip(c, e).allSatisfy { abs($0 - $1) <= tol } }
        // Hap（DXT1）：そのまま・Snappy・分けて圧縮 の 3 コマ（赤・緑・青）
        let hap1 = writeMov("hap1.mov", codec: "Hap1", frames: [frameNone(0x0B, dxt1(1, 0, 0)), frameSnappy(0x0B, dxt1(0, 1, 0)),
                                                                 frameChunked(0x0B, dxt1(0, 0, 1))])
        let c1 = hap1.map { colors($0, count: 3) } ?? []
        check(c1.count == 3 && near(c1[0], [0, 0, 255, 255]) && near(c1[1], [0, 255, 0, 255]) && near(c1[2], [255, 0, 0, 255]),
              "HAP：Hap（DXT1）の動画を読んで、そのまま・Snappy・分けて圧縮のコマがどれも正しい色（\(c1)）")
        // Hap Alpha（DXT5）：半分透明
        let hap5 = writeMov("hap5.mov", codec: "Hap5", frames: [frameSnappy(0x0E, dxt5(1, 1, 1, alpha: 0.5))])
        let c5 = hap5.map { colors($0, count: 1) } ?? []
        check(c5.count == 1 && near(c5[0], [255, 255, 255, 128]), "HAP：Hap Alpha（DXT5）は透明も読める（\(c5)）")
        // Hap Q（YCoCg）：(0.6, 0.5, 0.4) → Y 0.5・Co 0.1・Cg 0
        let y = 0.5, co = 0.1, cg = 0.0
        let hapQ = writeMov("hapq.mov", codec: "HapY", frames: [frameNone(0x0F, dxt5(co + 0.5 * 256 / 255, cg + 0.5 * 256 / 255, 0, alpha: y))])
        let cq = hapQ.map { colors($0, count: 1) } ?? []
        check(cq.count == 1 && near(cq[0], [102, 128, 153, 255], 16), "HAP：Hap Q（YCoCg）を元の色に戻せる（\(cq)）")
        try? FileManager.default.removeItem(at: dir)
    }

    /// 切り替え方：形ごとの現れ方と、切り替えの途中の重ね方
    static func testTransitions(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let ctx = MetalContext.shared
        let W = 160, H = 90
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead, .renderTarget]; td.storageMode = .shared
        let src = ctx.device.makeTexture(descriptor: td)!
        var px = [UInt8](repeating: 255, count: W * H * 4)
        for y in 0..<H { for x in 0..<W { let i = (y * W + x) * 4; let v = UInt8(x * 255 / W); px[i] = v; px[i + 1] = v; px[i + 2] = v } }
        src.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
        let fxp = EffectProcessor(); fxp.storageMode = .shared
        func alpha(_ kind: Transition, _ p: Double) -> [UInt8] {
            var m = Effect(kind: .transitionMask); m.values = [Double(kind.rawValue), p, 0.08, 3]
            let cb = ctx.queue.makeCommandBuffer()!
            let o = fxp.apply(EffectStack(effects: [m]), to: src, key: "tr", cb: cb, now: 1)
            cb.commit(); cb.waitUntilCompleted()
            var q = [UInt8](repeating: 0, count: W * H * 4)
            o.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            return stride(from: 3, to: q.count, by: 4).map { q[$0] }
        }
        func a(_ m: [UInt8], _ x: Int, _ y: Int) -> UInt8 { m[y * W + x] }
        func shown(_ m: [UInt8]) -> Double { Double(m.filter { $0 > 128 }.count) / Double(m.count) }
        let w = alpha(.wipe, 0.5), c = alpha(.circle, 0.5)
        var ok = a(w, 20, 45) > 240 && a(w, 140, 45) < 10 && a(c, 80, 45) > 240 && a(c, 2, 2) < 10
        var lines: [String] = []
        for k in [Transition.wipe, .circle, .noise, .luma, .glitch] {
            let s0 = shown(alpha(k, 0)), s5 = shown(alpha(k, 0.5)), s1 = shown(alpha(k, 1))
            ok = ok && s0 < 0.02 && s1 > 0.98 && s5 > 0.15 && s5 < 0.85
            lines.append(String(format: "%@ %.0f%%", k.label, s5 * 100))
        }
        check(ok, "切り替え方：0% で何も、100% で全部、途中は形のとおりに現れる（半分の所：" + lines.joined(separator: "・") + "）")
        // 切り替えの途中：消えていく絵はそのまま、新しい絵に形をかける
        let e = Engine(persistent: false)
        _ = e.placeGenerator(.solid, at: 0)
        _ = e.placeGenerator(.noise, at: 1)
        e.layers[0].fadeTime = 2
        e.layers[0].transition = .wipe
        e.trigger(0)
        wait(0.3)
        e.trigger(1)
        wait(0.3)
        _ = e.updateFrame()
        let g = e.layerGroups().first
        let draws = g?.draws ?? []
        check(draws.count == 2 && draws[0].opacity == 1 && draws[1].opacity == 1
              && draws[1].effects.effects.last?.kind == .transitionMask && (draws[1].effects.effects.last?.values[1] ?? 0) > 0,
              "切り替え方：切り替えの途中、前のクリップはそのまま残り、新しいクリップにワイプの形がかかる（\(draws.map { "\($0.opacity) \($0.effects.effects.map(\.kind.rawValue))" })）")
        let back = Engine(persistent: false)
        back.apply(e.makeState(relativeTo: nil), baseDir: nil)
        check(back.layers[0].transition == .wipe && Engine(persistent: false).layers[0].transition == .crossfade,
              "切り替え方：保存して読み込める（はじめはクロス）")
        e.stopAll()
    }

    /// 出力の分割：ひな形の数・スライスの取る所と映す所・エッジブレンド・保存
    static func testOutputMap(check: (Bool, String) -> Void) {
        // ひな形：2 台を 15% 重ねると、取る所は端から端まで、重なりは 1 台の 15%
        let two = OutputMap.preset(count: 2, overlap: 0.15, separate: true)
        let end = two[1].input[0] + two[1].input[2]
        let overlapW = two[0].input[0] + two[0].input[2] - two[1].input[0]
        check(two.count == 2 && abs(two[0].input[0]) < 1e-9 && abs(end - 1) < 1e-9 && abs(overlapW - 0.15 * two[0].input[2]) < 1e-9
              && two[0].feather[1] == 0.15 && two[1].feather[0] == 0.15 && two[0].output == 0 && two[1].output == 1,
              "出力の分割：横に 2 台・15% 重ねるひな形は、端から端まで取り、重なった側だけなじませ、出力 1・2 へ")
        let ctx = MetalContext.shared
        func tex(_ w: Int, _ h: Int, _ f: ((Int, Int) -> (UInt8, UInt8, UInt8))? = nil) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.shaderRead, .renderTarget]; td.storageMode = .shared
            let t = ctx.device.makeTexture(descriptor: td)!
            if let f {
                var px = [UInt8](repeating: 255, count: w * h * 4)
                for y in 0..<h { for x in 0..<w { let (r, g, b) = f(x, y); let i = (y * w + x) * 4; px[i] = b; px[i + 1] = g; px[i + 2] = r } }
                t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
            }
            return t
        }
        let comp = tex(200, 100) { x, _ in x < 100 ? (255, 0, 0) : (0, 0, 255) }
        func render(_ map: OutputMap, output: Int, test: Bool = false) -> [UInt8] {
            let dst = tex(160, 90)
            let cb = ctx.queue.makeCommandBuffer()!
            SliceRenderer.shared.draw(map, output: output, composite: comp, master: 1, testPattern: test, into: dst, cb: cb)
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 160 * 90 * 4)
            dst.getBytes(&px, bytesPerRow: 160 * 4, from: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0)
            return px
        }
        func rgb(_ p: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 160 + x) * 4; return (Int(p[i + 2]), Int(p[i + 1]), Int(p[i])) }
        // 1 つの出力に横に 2 つ：左の半分に、合成の左の半分（赤）。右に右の半分（青）
        var m = OutputMap(); m.enabled = true; m.slices = OutputMap.preset(count: 2)
        // 取る所を入れ替えると、出る所も入れ替わる
        var swapped = m; swapped.slices[0].input = [0.5, 0, 0.5, 1]; swapped.slices[1].input = [0, 0, 0.5, 1]
        let a = render(m, output: 0), b = render(swapped, output: 0)
        check(rgb(a, 20, 45).0 > 200 && rgb(a, 140, 45).2 > 200 && rgb(b, 20, 45).2 > 200 && rgb(b, 140, 45).0 > 200
              && rgb(render(m, output: 1), 80, 45) == (0, 0, 0),
              "出力の分割：スライスの取る所を、映す所へ出す（取る所を入れ替えると入れ替わる）。ほかの出力には出さない")
        // エッジブレンド：2 台・重ねる。出力 1 の右の端は暗く、重なった所は 2 台を足すと元の明るさ
        var e = OutputMap(); e.enabled = true
        e.slices = OutputMap.preset(count: 2, overlap: 0.3, separate: true)
        let gray = tex(200, 100) { _, _ in (180, 180, 180) }
        func renderG(_ out: Int) -> [UInt8] {
            let dst = tex(160, 90)
            let cb = ctx.queue.makeCommandBuffer()!
            SliceRenderer.shared.draw(e, output: out, composite: gray, master: 1, testPattern: false, into: dst, cb: cb)
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 160 * 90 * 4)
            dst.getBytes(&px, bytesPerRow: 160 * 4, from: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0)
            return px
        }
        let o1 = renderG(0), o2 = renderG(1)
        // 重なりのまん中：出力 1 の右から 15%（= 重なり 30% の半分）と、出力 2 の左から 15%
        let x1 = Int(160 * (1 - 0.15)), x2 = Int(160 * 0.15)
        let l1 = pow(Double(rgb(o1, x1, 45).0) / 255, 2.2), l2 = pow(Double(rgb(o2, x2, 45).0) / 255, 2.2)
        let full = pow(180.0 / 255, 2.2)
        check(rgb(o1, 20, 45).0 > 170 && rgb(o1, 158, 45).0 < 60 && abs((l1 + l2) / full - 1) < 0.08,
              String(format: "出力の分割：エッジブレンドで重なった所は暗くなり、2 台を足すと元の明るさ（%.0f%%）", (l1 + l2) / full * 100))
        // テストパターン・保存
        let tp = render(m, output: 0, test: true)
        let eng = Engine(persistent: false)
        eng.outputMap = m
        let back = Engine(persistent: false)
        back.apply(eng.makeState(relativeTo: nil), baseDir: nil)
        check(tp.contains { $0 > 100 } && back.outputMap == m, "出力の分割：テストパターンが出る。保存して読み込める")
    }

    /// 出力のマッピングの窓：吸い付く・矢印で動かす・点を足す／消す・形ごと動かす・メッシュ
    static func testMapEditor(check: (Bool, String) -> Void) {
        func near(_ a: MapP, _ b: MapP, _ e: Double = 1e-9) -> Bool { simd_length(a - b) <= e }
        // 吸い付く：8 pt 以内のいちばん近い点。遠いものは無視。点が無ければ画面の端・中央
        let targets = [MapP(0.5, 0.5), MapP(0.3, 0.3), MapP(0.508, 0.5)]
        let scale = MapP(1000, 500)
        let s1 = MapEdit.snap(MapP(0.505, 0.502), targets: targets, scale: scale)
        let s2 = MapEdit.snap(MapP(0.42, 0.62), targets: targets, scale: scale)
        let s3 = MapEdit.snap(MapP(0.996, 0.3), targets: [], scale: scale)
        check(near(s1, MapP(0.508, 0.5)) && near(s2, MapP(0.42, 0.62)) && near(s3, MapP(1, 0.3)),
              "マッピングの窓：吸い付くのは 8 pt 以内のいちばん近い点（遠いものは無視・画面の端にも）")

        // 矢印：選んだ点だけ、出力の 1 ピクセルぶん（⇧ で 10）
        var map = OutputMap()
        var mask = OutputMask()
        mask.points = [[0.2, 0.2], [0.6, 0.2], [0.6, 0.6], [0.2, 0.6]]
        map.masks = [mask]
        var sl = OutputSlice()
        sl.corners = [[0.1, 0.1], [0.9, 0.15], [0.85, 0.9], [0.12, 0.8]]
        sl.crop = [[0.5, 0.1], [0.9, 0.9], [0.1, 0.9]]
        map.slices = [sl]
        var m2 = map
        MapEdit.nudge(&m2, .mask(mask.id), .corners, selected: [0, 2], dx: 1, dy: 0, outputSize: (1920, 1080))
        let p = m2.masks[0].points
        var m3 = map
        MapEdit.nudge(&m3, .slice(sl.id), .corners, selected: [1], dx: 0, dy: 10, outputSize: (1920, 1080))
        // 切り抜き（スライスの中の座標）でも、出力の上で 1 ピクセル
        var m4 = map
        MapEdit.nudge(&m4, .slice(sl.id), .crop, selected: [0], dx: 1, dy: 0, outputSize: (1920, 1080))
        let o0 = map.slices[0].outputPoint(u: 0.5, v: 0.1)!, o1 = m4.slices[0].outputPoint(u: m4.slices[0].crop[0][0], v: m4.slices[0].crop[0][1])!
        let dpx = (o1 - o0) * MapP(1920, 1080)
        check(abs(p[0][0] - (0.2 + 1.0 / 1920)) < 1e-12 && abs(p[2][0] - (0.6 + 1.0 / 1920)) < 1e-12 && p[1] == [0.6, 0.2]
              && p[0][1] == 0.2 && abs(m3.slices[0].corners[1][1] - (0.15 + 10.0 / 1080)) < 1e-12 && m3.slices[0].corners[0] == sl.corners[0]
              && abs(dpx.x - 1) < 0.01 && abs(dpx.y) < 0.01,
              String(format: "マッピングの窓：矢印で、選んだ点だけ出力の 1 ピクセル（⇧ で 10）動く（切り抜きの点も %.3f px）", dpx.x))

        // 辺の上をクリック：その辺の 2 点の間に入る
        var m5 = map
        let at = MapEdit.insertPoint(&m5, .mask(mask.id), .corners, at: MapP(0.6, 0.4))
        let at2 = MapEdit.insertIndex([MapP(0, 0), MapP(1, 0), MapP(1, 1), MapP(0, 1)], MapP(0.5, 1.01))
        check(at == 2 && m5.masks[0].points.count == 5 && m5.masks[0].points[2] == [0.6, 0.4] && at2 == 3,
              "マッピングの窓：辺の上をクリックすると、その辺の 2 点の間に点が入る")

        // 消す：3 点は残す
        let sq = [MapP(0, 0), MapP(1, 0), MapP(1, 1), MapP(0, 1)]
        let d1 = MapEdit.deletePoints(sq, [0, 1])
        let d2 = MapEdit.deletePoints(Array(sq.prefix(3)), [1])
        let d3 = MapEdit.deletePoints(sq + [MapP(0.5, 0.5)], [4, 1])
        var m6 = map
        let ok6 = !MapEdit.deleteSelected(&m6, .slice(sl.id), .crop, [0, 1]) && m6.slices[0].crop.count == 3
        check(d1.count == 3 && d1[0] == sq[1] && d2.count == 3 && d3 == [sq[0], sq[2], sq[3]] && ok6,
              "マッピングの窓：点を消しても 3 点は残る")

        // 形ごと動かす：四隅が全部同じだけ動く
        var m7 = map
        MapEdit.moveItem(&m7, .slice(sl.id), from: map, by: MapP(0.1, -0.05))
        let movedAll = zip(m7.slices[0].corners, sl.corners).allSatisfy { abs($0[0] - $1[0] - 0.1) < 1e-12 && abs($0[1] - $1[1] + 0.05) < 1e-12 }
        check(movedAll && m7.slices[0].crop == sl.crop, "マッピングの窓：面の中をドラッグすると、四隅が全部同じだけ動く")

        // メッシュのモードに入ると 2×2 ができる。マスの数を変えても形は同じ
        var s = sl
        MapEdit.enterMesh(&s)
        let entered = s.mesh?.cols == 2 && s.mesh?.rows == 2 && s.mesh?.points.count == 9 && s.mesh == .regular(cols: 2, rows: 2)
        s.mesh!.points[4] = [0.62, 0.4]
        let before = s.mesh!
        MapEdit.setMeshSize(&s, cols: 4, rows: 4)
        let after = s.mesh!
        var worst = 0.0
        for (u, v) in [(0.5, 0.5), (0.25, 0.25), (0.75, 0.5), (0.5, 0.75), (0.0, 1.0)] {
            worst = max(worst, simd_length(after.position(u: u, v: v) - before.position(u: u, v: v)))
        }
        check(entered && after.cols == 4 && after.rows == 4 && after.points.count == 25 && worst < 0.01,
              String(format: "マッピングの窓：メッシュに入ると 2×2 ができ、マスの数を変えても形が保たれる（ずれ %.4f）", worst))
    }

    /// 前の出力の分割の描き方（全画面の 1 枚でスライスを回し、光の量を足す）。今の描き方と同じ絵になるかを比べるためだけに使う
    private static let oldSliceShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VO { float4 pos [[position]]; float2 uv; };
    vertex VO os_v(uint vid [[vertex_id]]) {
        float2 c = float2(float(vid & 1), float(vid >> 1));
        VO o; o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0); o.uv = c; return o;
    }
    struct SliceU { float3x3 hinv; float4 input; float4 feather; float4 extra; };
    struct SlicesU { int count; float master; int testPattern; float pad; };
    static float3 sliceColor(float i) {
        float3 k = abs(fract(float3(i * 0.13 + 0.05) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
        return saturate(k - 1.0);
    }
    fragment float4 os_f(VO in [[stage_in]], constant SlicesU& u [[buffer(0)]], constant SliceU* sl [[buffer(1)]],
                         texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 sum = 0.0;
        for (int i = 0; i < u.count; i++) {
            float3 h = sl[i].hinv * float3(in.uv, 1.0);
            if (h.z <= 0.0) continue;
            float2 l = h.xy / h.z;
            if (any(l < 0.0) || any(l > 1.0)) continue;
            float4 f = sl[i].feather;
            float w = 1.0;
            if (f.x > 0.0) w *= smoothstep(0.0, 1.0, l.x / f.x);
            if (f.y > 0.0) w *= smoothstep(0.0, 1.0, (1.0 - l.x) / f.y);
            if (f.z > 0.0) w *= smoothstep(0.0, 1.0, l.y / f.z);
            if (f.w > 0.0) w *= smoothstep(0.0, 1.0, (1.0 - l.y) / f.w);
            float3 c;
            if (u.testPattern != 0) {
                float2 g = abs(fract(l * 8.0) - 0.5);
                float line = step(0.46, max(g.x, g.y));
                float edge = step(min(min(l.x, 1.0 - l.x), min(l.y, 1.0 - l.y)), 0.01);
                c = mix(sliceColor(sl[i].extra.x) * 0.55, float3(1.0), max(line, edge));
            } else {
                float2 uv = sl[i].input.xy + l * sl[i].input.zw;
                c = tex.sample(s, uv).rgb;
            }
            sum += pow(max(c, 0.0), 2.2) * w;
        }
        return float4(pow(sum, 1.0 / 2.2) * u.master, 1.0);
    }
    """

    /// 出力のマッピング：メッシュ・切り抜き・マスク・取る所の回転・重なり・色・レイヤーが元の絵・ガイド・.halomap
    static func testOutputMapping(check: (Bool, String) -> Void) {
        let ctx = MetalContext.shared
        let W = 160, H = 90
        func tex(_ w: Int, _ h: Int, _ f: ((Int, Int) -> (UInt8, UInt8, UInt8))? = nil) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.shaderRead, .renderTarget]; td.storageMode = .shared
            let t = ctx.device.makeTexture(descriptor: td)!
            if let f {
                var px = [UInt8](repeating: 255, count: w * h * 4)
                for y in 0..<h { for x in 0..<w { let (r, g, b) = f(x, y); let i = (y * w + x) * 4; px[i] = b; px[i + 1] = g; px[i + 2] = r } }
                t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
            }
            return t
        }
        func read(_ t: MTLTexture) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: t.width * t.height * 4)
            t.getBytes(&px, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
            return px
        }
        func render(_ map: OutputMap, output: Int = 0, comp: MTLTexture?, layers: [UUID: MTLTexture] = [:],
                    test: Bool = false, guide: MapGuide? = nil, master: Float = 1) -> [UInt8] {
            let dst = tex(W, H)
            let cb = ctx.queue.makeCommandBuffer()!
            SliceRenderer.shared.draw(map, output: output, composite: comp, layers: layers, master: master, testPattern: test,
                                      guide: guide, into: dst, cb: cb)
            cb.commit(); cb.waitUntilCompleted()
            return read(dst)
        }
        func rgb(_ p: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * W + x) * 4; return (Int(p[i + 2]), Int(p[i + 1]), Int(p[i])) }
        func isBlack(_ p: [UInt8], _ x: Int, _ y: Int) -> Bool { let c = rgb(p, x, y); return c.0 < 8 && c.1 < 8 && c.2 < 8 }
        // 2 枚の差：大きく違う画素の割合と、平均の差
        func diff(_ a: [UInt8], _ b: [UInt8]) -> (bad: Double, mean: Double) {
            var bad = 0, sum = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
                if d > 12 { bad += 1 }
                sum += d
            }
            let n = Double(a.count / 4)
            return (Double(bad) / n, Double(sum) / n)
        }
        func one(_ s: OutputSlice) -> OutputMap { var m = OutputMap(); m.enabled = true; m.slices = [s]; return m }

        // 1. 古い形の JSON（追加の項目なし）が読めて、書いて読み直しても同じ
        let oldJSON = """
        {"enabled":true,"slices":[{"id":"6B1F4E2A-1C3D-4E5F-8A9B-0C1D2E3F4A5B","name":"左から 1","enabled":true,"output":1,
        "input":[0,0,0.6,1],"corners":[[0.1,0],[1,0],[1,1],[0,0.9]],"feather":[0,0.15,0,0]}]}
        """
        let oldMap = try? JSONDecoder().decode(OutputMap.self, from: Data(oldJSON.utf8))
        let again = oldMap.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONDecoder().decode(OutputMap.self, from: $0) }
        let os = oldMap?.slices.first
        check(oldMap != nil && oldMap == again && os?.output == 1 && os?.input == [0, 0, 0.6, 1] && os?.feather[1] == 0.15
              && os?.source == .composition && os?.mesh == nil && os?.crop.isEmpty == true && os?.opacity == 1
              && os?.gain == [1, 1, 1] && oldMap?.masks.isEmpty == true && oldMap?.blendGamma == 2.2,
              "出力のマッピング：古い形の JSON が読める（足した項目ははじめの値）。書いて読み直しても同じ")
        // 古いプロジェクト（レイヤーの印なし）も読める
        let oldLayerJSON = #"{"opacity":0.5,"blend":0,"volume":1}"#
        let ol = try? JSONDecoder().decode(Engine.SavedLayer.self, from: Data(oldLayerJSON.utf8))
        check(ol != nil && ol?.id == nil, "出力のマッピング：古いレイヤーの保存データ（印なし）も読める")

        // 2. 今までの設定で、今までと同じ絵（四隅だけ・なじませあり・テストパターン）
        let oldLib = try! ctx.device.makeLibrary(source: oldSliceShaderSource, options: nil)
        let od = MTLRenderPipelineDescriptor()
        od.vertexFunction = oldLib.makeFunction(name: "os_v")
        od.fragmentFunction = oldLib.makeFunction(name: "os_f")
        od.colorAttachments[0].pixelFormat = .bgra8Unorm
        let oldPipe = try! ctx.device.makeRenderPipelineState(descriptor: od)
        struct OldSliceU { var hinv: simd_float3x3; var input: SIMD4<Float>; var feather: SIMD4<Float>; var extra: SIMD4<Float> }
        struct OldSlicesU { var count: Int32; var master: Float; var testPattern: Int32; var pad: Float = 0 }
        func renderOld(_ map: OutputMap, output: Int = 0, comp: MTLTexture, test: Bool = false) -> [UInt8] {
            var us: [OldSliceU] = []
            for (i, s) in map.slices.enumerated() where s.enabled && s.output == output {
                let q = s.corners.map { SIMD2(Float($0[0]), Float($0[1])) }
                us.append(OldSliceU(hinv: Homography.squareToQuad(q).inverse, input: SIMD4(s.input.map(Float.init)),
                                    feather: SIMD4(s.feather.map(Float.init)), extra: SIMD4(Float(i), 0, 0, 0)))
            }
            let dst = tex(W, H)
            let cb = ctx.queue.makeCommandBuffer()!
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
            if !us.isEmpty {
                var u = OldSlicesU(count: Int32(us.count), master: 1, testPattern: test ? 1 : 0)
                enc.setRenderPipelineState(oldPipe)
                enc.setFragmentBytes(&u, length: MemoryLayout<OldSlicesU>.stride, index: 0)
                us.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                enc.setFragmentTexture(comp, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            return read(dst)
        }
        let photo = tex(200, 100) { x, y in (UInt8(x * 255 / 199), UInt8(y * 255 / 99), UInt8((x + y) % 256)) }
        var keystone = OutputSlice()
        keystone.input = [0.1, 0.05, 0.7, 0.85]
        keystone.corners = [[0.08, 0.05], [0.9, 0.12], [0.97, 0.92], [0.02, 0.85]]
        var feathered = OutputMap(); feathered.enabled = true
        feathered.slices = OutputMap.preset(count: 2, overlap: 0.3, separate: true)
        feathered.slices[1].corners = [[0, 0.1], [1, 0], [0.9, 1], [0.05, 0.95]]
        var sideBySide = OutputMap(); sideBySide.enabled = true; sideBySide.slices = OutputMap.preset(count: 3)
        let cases: [(String, OutputMap, Int, Bool)] = [
            ("四隅だけ", one(keystone), 0, false), ("なじませ 出力 1", feathered, 0, false), ("なじませ 出力 2", feathered, 1, false),
            ("横に 3 つ", sideBySide, 0, false), ("テストパターン", one(keystone), 0, true), ("テストパターン 3 つ", sideBySide, 0, true),
        ]
        var worst = (bad: 0.0, mean: 0.0)
        for (_, m, out, test) in cases {
            let d = diff(render(m, output: out, comp: photo, test: test), renderOld(m, output: out, comp: photo, test: test))
            worst = (max(worst.bad, d.bad), max(worst.mean, d.mean))
        }
        check(worst.bad < 0.01 && worst.mean < 1.0,
              String(format: "出力のマッピング：今までの設定（四隅だけ・なじませ・テストパターン）は今までと同じ絵（違う画素 %.2f%%・平均の差 %.2f）",
                     worst.bad * 100, worst.mean))

        // 3. メッシュ：等間隔のままなら四隅だけと同じ。点を動かすとその辺りがずれる。resized で形が保たれる
        var meshed = keystone
        meshed.mesh = .regular(cols: 2, rows: 2)
        let plainPic = render(one(keystone), comp: photo)
        let dm = diff(render(one(meshed), comp: photo), plainPic)
        var bent = meshed
        bent.mesh!.points[bent.mesh!.index(col: 1, row: 1)] = [0.65, 0.5]
        let bentPic = render(one(bent), comp: photo)
        // まん中（出力のまん中あたり）はずれ、角の近くはほぼ同じ
        let centerShift = abs(rgb(bentPic, 80, 45).0 - rgb(plainPic, 80, 45).0)
        let cornerShift = abs(rgb(bentPic, 16, 10).0 - rgb(plainPic, 16, 10).0)
        var smoothOff = bent; smoothOff.mesh!.smooth = false
        let rs = bent.mesh!.resized(cols: 4, rows: 4)
        var maxErr = 0.0, nodeErr = 0.0
        for k in 0...20 {
            for j in 0...20 {
                let u = Double(k) / 20, v = Double(j) / 20
                maxErr = max(maxErr, simd_length(rs.position(u: u, v: v) - bent.mesh!.position(u: u, v: v)))
            }
        }
        for j in 0...4 { for i in 0...4 {
            let u = Double(i) / 4, v = Double(j) / 4
            nodeErr = max(nodeErr, simd_length(rs.point(col: i, row: j) - bent.mesh!.position(u: u, v: v)))
        } }
        let reg = SliceMesh.regular(cols: 3, rows: 2)
        let regErr = (0...10).map { k -> Double in
            let u = Double(k) / 10, v = Double(10 - k) / 10
            return simd_length(reg.position(u: u, v: v) - SIMD2(u, v))
        }.max() ?? 1
        check(dm.bad < 0.005 && dm.mean < 0.5 && centerShift > 20 && cornerShift < 6 && regErr < 1e-9
              && smoothOff.mesh!.position(u: 0.5, v: 0.5) == SIMD2(0.65, 0.5) && rs.cols == 4 && nodeErr < 1e-9 && maxErr < 0.02,
              String(format: "出力のマッピング：メッシュは等間隔なら四隅だけと同じ（平均の差 %.2f）。点を動かすとまん中がずれ（%d）角はそのまま（%d）。点の数を変えても形が保たれる（%.3f）",
                     dm.mean, centerShift, cornerShift, maxErr))

        // 4. 切り抜き：三角の外が黒。反転で内が黒
        let gray = tex(200, 100) { _, _ in (180, 180, 180) }
        var cropped = OutputSlice()
        cropped.crop = [[0, 0], [1, 0], [0, 1]]
        let c1 = render(one(cropped), comp: gray)
        cropped.cropInvert = true
        let c2 = render(one(cropped), comp: gray)
        check(rgb(c1, 20, 15).0 > 150 && isBlack(c1, 140, 80) && isBlack(c2, 20, 15) && rgb(c2, 140, 80).0 > 150,
              "出力のマッピング：切り抜き（三角）の外は黒。反転すると中が黒")

        // 5. マスク：形の中が黒。反転で外が黒。へこんだ形でも正しい
        var masked = one(OutputSlice())
        masked.masks = [OutputMask(points: [[0, 0], [0.5, 0], [0, 0.5]])]
        let k1 = render(masked, comp: gray)
        masked.masks[0].invert = true
        let k2 = render(masked, comp: gray)
        // へこんだ形（コの字）：へこみの所は塗らない
        var concave = one(OutputSlice())
        concave.masks = [OutputMask(points: [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9], [0.1, 0.7], [0.6, 0.7], [0.6, 0.3], [0.1, 0.3]])]
        let k3 = render(concave, comp: gray)
        var otherOut = masked; otherOut.masks[0].output = 1; otherOut.masks[0].invert = false
        let k4 = render(otherOut, comp: gray)
        check(isBlack(k1, 10, 8) && rgb(k1, 140, 80).0 > 150 && rgb(k2, 10, 8).0 > 150 && isBlack(k2, 140, 80)
              && isBlack(k3, 16 * 8, 45) && isBlack(k3, 40, 20) && isBlack(k3, 40, 70) && rgb(k3, 40, 45).0 > 150
              && rgb(k3, 5, 45).0 > 150 && rgb(k4, 10, 8).0 > 150,
              "出力のマッピング：マスクの形の中は黒・反転で外が黒。へこんだ形でも、へこみは塗らない。ほかの出力のマスクはかからない")

        // 6. 取る所の回転 90° と反転（正方形の絵：左上 赤・右上 緑・左下 青・右下 白）
        let quads = tex(100, 100) { x, y in
            switch (x < 50, y < 50) {
            case (true, true): (255, 0, 0)
            case (false, true): (0, 255, 0)
            case (true, false): (0, 0, 255)
            default: (255, 255, 255)
            }
        }
        func corner(_ p: [UInt8]) -> (Int, Int, Int) { rgb(p, 20, 12) }
        var rot = OutputSlice(); rot.inputRotation = 90
        var fh = OutputSlice(); fh.flipH = true
        var fv = OutputSlice(); fv.flipV = true
        let r0 = corner(render(one(OutputSlice()), comp: quads)), r90 = corner(render(one(rot), comp: quads))
        let rh = corner(render(one(fh), comp: quads)), rv = corner(render(one(fv), comp: quads))
        // 半分の大きさの取る所を 45° 回すと、角は元の絵の外 → 黒
        var outside = OutputSlice(); outside.input = [0, 0, 1, 1]; outside.inputRotation = 45
        let ro = render(one(outside), comp: quads)
        check(r0.0 > 200 && r0.1 < 40 && r90.1 > 200 && r90.0 < 40 && rh.1 > 200 && rh.0 < 40 && rv.2 > 200 && rv.0 < 40
              && isBlack(ro, 1, 1),
              "出力のマッピング：取る所を 90° 回す（時計回り）と左上に右上の絵。左右反転で右上、上下反転で左下。元の絵の外は黒")

        // 7. 重なり：後ろのスライスが手前
        let redBlue = tex(200, 100) { x, _ in x < 100 ? (255, 0, 0) : (0, 0, 255) }
        var under = OutputSlice(); under.input = [0, 0, 0.5, 1]
        var over = OutputSlice(); over.input = [0.5, 0, 0.5, 1]; over.corners = [[0.25, 0.25], [0.75, 0.25], [0.75, 0.75], [0.25, 0.75]]
        var stack = OutputMap(); stack.enabled = true; stack.slices = [under, over]
        let st = render(stack, comp: redBlue)
        check(rgb(st, 80, 45).2 > 200 && rgb(st, 80, 45).0 < 30 && rgb(st, 10, 10).0 > 200,
              "出力のマッピング：重なった所は、後ろ（一覧の下）のスライスが手前に出る")

        // 8. 色：不透明度 0.5 で光の量が約半分。明るさ・ゲイン
        var half = OutputSlice(); half.opacity = 0.5
        let hp = render(one(half), comp: gray)
        let light = pow(Double(rgb(hp, 80, 45).0) / 255, 2.2) / pow(180.0 / 255, 2.2)
        var tinted = OutputSlice(); tinted.gain = [1, 0, 1]; tinted.brightness = 0.1
        let tp = rgb(render(one(tinted), comp: gray), 80, 45)
        check(abs(light - 0.5) < 0.06 && tp.1 < 5 && tp.0 > 195 && tp.2 > 195,
              String(format: "出力のマッピング：不透明度 0.5 で光の量が約半分（%.0f%%）。緑のゲイン 0 で緑が消え、明るさで明るく", light * 100))

        // 9. レイヤーが元の絵：そのレイヤーの絵だけが出る
        let eng = Engine(persistent: false)
        eng.syncRenderState()
        let id0 = eng.layers[0].id, id1 = eng.layers[1].id
        let back = Engine(persistent: false)
        back.apply(eng.makeState(relativeTo: nil), baseDir: nil)
        back.syncRenderState()
        let red = tex(64, 36) { _, _ in (255, 0, 0) }, blue = tex(64, 36) { _, _ in (0, 0, 255) }
        let groups = [LayerGroup(draws: [LayerDraw(texture: blue, opacity: 1, blend: .normal, holder: nil)], opacity: 1, blend: .normal, key: 1),
                      LayerGroup(draws: [LayerDraw(texture: red, opacity: 1, blend: .normal, holder: nil)], opacity: 1, blend: .normal, key: 0)]
        var layerMap = OutputMap(); layerMap.enabled = true
        var ls = OutputSlice(); ls.source = .layer(id1); ls.corners = [[0, 0], [0.5, 0], [0.5, 1], [0, 1]]
        var cs = OutputSlice(); cs.corners = [[0.5, 0], [1, 0], [1, 1], [0.5, 1]]
        var gone = OutputSlice(); gone.source = .layer(UUID()); gone.corners = [[0.25, 0.25], [0.75, 0.25], [0.75, 0.75], [0.25, 0.75]]
        layerMap.slices = [ls, cs]
        let sources = SliceLayerSources()
        let cb = ctx.queue.makeCommandBuffer()!
        let compositor = Compositor()
        let whole = compositor.composite(groups, effects: EffectStack(), width: 200, height: 100, cb: cb)
        let lt = sources.textures(for: layerMap, groups: groups, layerIndex: { eng.layerIndex(of: $0) }, width: 200, height: 100, cb: cb)
        cb.commit(); cb.waitUntilCompleted()
        let lp = render(layerMap, comp: whole, layers: lt)
        var withGone = layerMap; withGone.slices.append(gone)
        let gp = render(withGone, comp: whole, layers: lt)
        check(eng.layerIndex(of: id1) == 1 && eng.layerIndex(of: UUID()) == nil && lt[id1] != nil
              && rgb(lp, 30, 45).2 > 200 && rgb(lp, 30, 45).0 < 30 && rgb(lp, 130, 45).0 > 200 && isBlack(gp, 80, 45)
              && back.layers[0].id == id0 && back.layers[1].id == id1,
              "出力のマッピング：元の絵がレイヤーなら、そのレイヤーの絵だけが出る（無いレイヤーは黒）。レイヤーの印は保存して読み込める")

        // 10. ガイド：選んだスライスの輪郭（黄色）が出る。エンジンから描画スレッドへ渡る
        var gs = OutputSlice(); gs.corners = [[0.2, 0.2], [0.8, 0.2], [0.8, 0.8], [0.2, 0.8]]; gs.mesh = .regular(cols: 2, rows: 2)
        let guided = render(one(gs), comp: gray, guide: MapGuide(target: .slice(gs.id), mode: .mesh, selected: [4]))
        let edge = rgb(guided, 80, 18), inside = rgb(guided, 60, 30)
        eng.mapGuide = MapGuide(target: .slice(gs.id))
        let passed = eng.renderParams().mapGuide == eng.mapGuide
        eng.mapGuide = nil
        check(edge.0 > 200 && edge.1 > 170 && edge.2 < 60 && inside.0 > 150 && inside.2 > 150 && passed
              && eng.renderParams().mapGuide == nil,
              "出力のマッピング：ガイドで、選んだスライスの輪郭が黄色で出る（エンジンから描画へ渡る）")

        // 11. .halomap に書いて読める
        var full = feathered
        full.slices[0].mesh = bent.mesh
        full.slices[0].crop = [[0, 0], [1, 0], [0.5, 1]]
        full.slices[1].source = .layer(id1)
        full.slices[1].inputRotation = 30; full.slices[1].flipV = true; full.slices[1].gain = [1, 0.5, 0.2]
        full.masks = [OutputMask(name: "柱", output: 1, points: [[0.1, 0.1], [0.3, 0.1], [0.2, 0.4]], invert: true)]
        full.blendGamma = 1.8; full.backdrops = ["0": "/tmp/a.jpg"]; full.backdropOpacity = 0.3
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString).\(OutputMap.fileExtension)")
        try? full.write(to: url)
        let readBack = try? OutputMap.read(from: url)
        try? FileManager.default.removeItem(at: url)
        check(readBack == full, "出力のマッピング：.halomap に書いて読める（メッシュ・切り抜き・マスク・レイヤーも）")
    }

    /// カメラ・Syphon の絵を置く：合わせ方・左右反転。カメラを選んでいなければ透明
    static func testSourceDraw(check: (Bool, String) -> Void) {
        let ctx = MetalContext.shared
        func tex(_ w: Int, _ h: Int, shared: Bool, _ f: ((Int, Int) -> (UInt8, UInt8, UInt8))? = nil) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.shaderRead, .renderTarget]; td.storageMode = .shared
            let t = ctx.device.makeTexture(descriptor: td)!
            if let f {
                var px = [UInt8](repeating: 255, count: w * h * 4)
                for y in 0..<h { for x in 0..<w { let (r, g, b) = f(x, y); let i = (y * w + x) * 4; px[i] = b; px[i + 1] = g; px[i + 2] = r } }
                t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
            }
            return t
        }
        // 横長（4:1）の、左が赤・右が青の絵を、16:9 に置く
        let src = tex(64, 16, shared: true) { x, _ in x < 32 ? (255, 0, 0) : (0, 0, 255) }
        func draw(fit: Float, mirror: Bool) -> [UInt8] {
            let dst = tex(160, 90, shared: true)
            let cb = ctx.queue.makeCommandBuffer()!
            SyphonDraw.shared.draw(src, fit: fit, opacity: 1, mirror: mirror, premultiply: false, into: dst, cb: cb)
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 160 * 90 * 4)
            dst.getBytes(&px, bytesPerRow: 160 * 4, from: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0)
            return px
        }
        func at(_ p: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 160 + x) * 4; return (Int(p[i + 2]), Int(p[i]), Int(p[i + 3])) }
        let fit = draw(fit: 0, mirror: false), fill = draw(fit: 1, mirror: false), mir = draw(fit: 2, mirror: true)
        // 収める：上下は透明、真ん中の左は赤。いっぱいに：上も絵がある。反転：左が青
        check(at(fit, 20, 5).2 == 0 && at(fit, 20, 45).0 > 200 && at(fill, 20, 5).2 > 200 && at(mir, 20, 45).1 > 200 && at(mir, 140, 45).0 > 200,
              "カメラ・Syphon の置き方：収める（上下は透明）・いっぱいに・左右反転")
        // カメラを選んでいなければ透明（落ちない）
        let fxp = EffectProcessor(); fxp.storageMode = .shared
        let blank = tex(160, 90, shared: true)
        let cb = ctx.queue.makeCommandBuffer()!
        let out = fxp.apply(EffectStack(effects: [Effect(kind: .camera)]), to: blank, key: "cam", cb: cb, now: 1)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 1, count: 160 * 90 * 4)
        out.getBytes(&px, bytesPerRow: 160 * 4, from: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0)
        _ = CameraDevice.list()
        check(px.allSatisfy { $0 == 0 } && Effect(kind: .camera).text.isEmpty && EffectKind.camera.generatorCategory == .external,
              "カメラから：カメラを選んでいなければ透明。「ほかのアプリ・カメラから」の分類")
    }

    /// BPM の自動検出：キック・ハイハットの並びから BPM と拍の頭が分かる。何回か続けて同じなら合わせる
    static func testBeatDetect(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let sr = 48000.0
        func run(bpm: Double, offset: Double, seconds: Double) -> (BeatEstimator.Result?, Double) {
            var an = AudioAnalyzer()
            var rng = SplitMix(seed: 7)
            let spb = 60 / bpm
            var onsets: [Double] = []
            let n = 1024
            var t = 0.0
            while t < seconds {
                var buf = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let tt = t + Double(i) / sr
                    // キック（拍の頭）、ハイハット（裏）、うすいノイズ
                    let kb = (tt - offset) / spb
                    let kp = (kb - floor(kb)) * spb
                    var v = kb >= 0 ? 0.8 * sin(2 * .pi * 55 * kp) * exp(-kp * 18) : 0
                    let hp = ((kb + 0.5) - floor(kb + 0.5)) * spb
                    v += 0.15 * (rng.next() * 2 - 1) * exp(-hp * 60)
                    v += 0.02 * (rng.next() * 2 - 1)
                    buf[i] = Float(v)
                }
                _ = buf.withUnsafeBufferPointer { an.process($0.baseAddress!, count: n, sampleRate: sr, time: t, release: 0.15, autoGain: true) }
                onsets += an.onsets
                an.onsets.removeAll()
                t += Double(n) / sr
            }
            let rate = sr / Double(AudioAnalyzer.onsetHop)
            let win = Array(onsets.suffix(Int(rate * 8)))
            let end = Double(onsets.count) / rate
            return (BeatEstimator.estimate(win, rate: rate), end)
        }
        var lines: [String] = []
        var ok = true
        for (bpm, off) in [(128.0, 0.11), (95.0, 0.3), (140.0, 0.05)] {
            let (r, end) = run(bpm: bpm, offset: off, seconds: 10)
            guard let r else { ok = false; lines.append("\(Int(bpm)) → なし"); continue }
            // 本当の最後の拍の頭との違い（拍の長さで回り込む）
            let spb = 60 / bpm
            let lastTrue = off + floor((end - off) / spb) * spb
            var d = (end - r.lastBeatAgo) - lastTrue
            d -= (d / spb).rounded() * spb
            let good = abs(r.bpm - bpm) / bpm < 0.01 && abs(d) < 0.035
            ok = ok && good
            lines.append(String(format: "%.0f → %.1f（拍の頭 %+.0f ms）", bpm, r.bpm, d * 1000))
        }
        check(ok, "BPM の自動検出：キックとハイハットの音から BPM と拍の頭が分かる（" + lines.joined(separator: "・") + "）")
        // 3 回続けて同じくらいなら合わせる（保存・元に戻すには数えない）
        let e = Engine(persistent: false)
        e.bpm = 120
        e.commitUndoStep()
        let det = BeatDetector.shared
        det.forTests = true
        let now = CACurrentMediaTime()
        det.apply(BeatEstimator.Result(bpm: 127.9, lastBeatAgo: 0.1, confidence: 0.5), endTime: now, engine: e)
        let afterOne = e.bpm
        det.apply(BeatEstimator.Result(bpm: 128.1, lastBeatAgo: 0.1, confidence: 0.5), endTime: now, engine: e)
        det.apply(BeatEstimator.Result(bpm: 128.0, lastBeatAgo: 0.1, confidence: 0.5), endTime: now, engine: e)
        let b = e.beatClockForEditing().beat(at: now - 0.1)
        check(afterOne == 120 && abs(e.bpm - 128) < 0.15 && abs(b - b.rounded()) < 0.01 && !e.commitUndoStep(),
              String(format: "BPM の自動検出：3 回続けて同じくらいなら BPM（%.1f）と拍の頭を合わせる。1 回だけでは変えない。元に戻す歩にならない", e.bpm))
    }

    /// 元に戻す：設定・クリップの削除・段の追加を戻せる。再生中のクリップは止まらない
    static func testUndo(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        _ = e.placeGenerator(.solid, at: 0)
        _ = e.placeGenerator(.noise, at: 1)
        e.commitUndoStep()
        let gen = e.slots[0]
        e.trigger(0)
        wait(0.1)
        // 値を変えて戻す（再生は止まらない・同じクリップのまま）
        e.layers[0].opacity = 0.4
        e.slots[0]?.effects = [Effect(kind: .invert)]
        e.commitUndoStep()
        e.undo()
        check(abs(e.layers[0].opacity - 1) < 1e-9 && e.slots[0]?.effects.isEmpty == true && e.slots[0] === gen
              && e.activeByLayer[0] == 0,
              "元に戻す：レイヤーの不透明度・クリップのエフェクトが戻り、再生中のクリップはそのまま（止まらない・作り直さない）")
        e.redo()
        check(abs(e.layers[0].opacity - 0.4) < 1e-9 && e.slots[0]?.effects.count == 1 && e.activeByLayer[0] == 0,
              "やり直す：戻した変更をもう一度")
        // クリップを消して戻す（同じ目印・同じ種類で戻る）
        let id1 = e.slots[1]?.id
        e.clear(1)
        e.commitUndoStep()
        let gone = e.slots[1] == nil
        e.undo()
        check(gone && e.slots[1]?.id == id1 && e.slots[1]?.generator?.kind == .noise, "元に戻す：消したクリップが戻る")
        // 段を足して戻す（形が変わる操作は、全体を作り直して戻す）
        let n = e.layers.count
        e.insertLayer(at: 0)
        e.commitUndoStep()
        e.undo()
        check(e.layers.count == n && e.slots[1]?.generator?.kind == .noise && e.undoHistory.canRedo,
              "元に戻す：足した段が消えて、クリップは元の場所に戻る")
        // 細かな変化（ドラッグ）はまとめて 1 歩
        e.commitUndoStep()
        for k in 0..<10 { e.layers[0].opacity = Double(k) / 10 }
        e.commitUndoStep()
        let before = e.layers[0].opacity
        e.undo()
        check(abs(before - 0.9) < 1e-9 && abs(e.layers[0].opacity - 0.4) < 1e-9, "元に戻す：続けて動かした値は、まとめて 1 歩で戻る")
        // 見ているデッキを変えただけでは歩にならない
        let steps = e.undoHistory.canUndo
        _ = e.addDeck()
        e.commitUndoStep()
        let added = e.undoHistory.canUndo
        e.currentDeck = 0
        let changed = e.commitUndoStep()
        check(added && !changed && (steps || true), "元に戻す：見ているデッキを変えただけでは、戻す歩にならない")
        e.stopAll()
    }

    /// MIDI・キーの割り当て：覚える・つまみの値・本物の CoreMIDI を通る・光らせる判断
    static func testControls(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let hub = ControlHub.shared
        hub.forTests = true
        OSCHub.shared.forTests = true
        let saved = hub.bindings
        for b in saved { hub.remove(b.id) }
        // 覚える：ノートを押すと割り当たる。離したのでは覚えない
        hub.learn("/halo/layer/1/clip/2", title: "テスト")
        hub.handle(status: 0x80, d1: 36, d2: 0, device: "Test")      // 離した
        wait(0.05)
        let stillLearning = hub.learning != nil
        hub.handle(status: 0x91, d1: 36, d2: 100, device: "Test")    // ch2 で押した
        wait(0.05)
        let b = hub.bindings.first
        check(stillLearning && hub.learning == nil && b?.trigger.kind == .note && b?.trigger.number == 36 && b?.trigger.channel == 2
              && b?.address == "/halo/layer/1/clip/2",
              "MIDI：「覚える」のあと押したボタン（ノート 36・ch2）が割り当たる。離したのでは覚えない")
        // 同じボタンに別のものを覚えさせると、前の割り当ては外れる
        hub.learn("/halo/cue/next", title: "次へ")
        hub.handle(status: 0x91, d1: 36, d2: 90, device: "Test")
        wait(0.05)
        check(hub.bindings.count == 1 && hub.bindings[0].address == "/halo/cue/next", "MIDI：同じボタンに覚えさせ直すと、前の割り当ては外れる")
        // つまみ（CC）の値は、OSC と同じ置き場所に入り、動かし方「OSC・MIDI」で使える
        hub.handle(status: 0xB0, d1: 7, d2: 127, device: "Test")
        var pa = ParamAnim(range: 0...10); pa.mode = .osc; pa.osc = OSCLink(address: "/midi/1/cc/7")
        check(OSCHub.shared.value("/midi/1/cc/7") == 1 && pa.value(base: 0, at: 1, beat: BeatClock()) == 10,
              "MIDI：つまみ（CC 7）の値で、パラメーターが動く")
        // 本物の CoreMIDI を通る：仮の MIDI 機器から送ったノートが届く
        hub.startIfNeeded()
        var src = MIDIEndpointRef()
        var client = MIDIClientRef()
        MIDIClientCreateWithBlock("HaloVJ selftest" as CFString, &client, nil)
        MIDISourceCreateWithProtocol(client, "HaloVJ selftest source" as CFString, ._1_0, &src)
        wait(0.6)
        var list = MIDIEventList()
        let pk = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, pk, 0, 1, [0x20B0_1540])   // CC 21 = 64（ch1）
        MIDIReceivedEventList(src, &list)
        var got: Double?
        let t0 = CACurrentMediaTime()
        while got == nil && CACurrentMediaTime() - t0 < 3 { wait(0.05); got = OSCHub.shared.value("/midi/1/cc/21") }
        check(got.map { abs($0 - 64.0 / 127) < 0.01 } ?? false && hub.devices.contains { $0.contains("HaloVJ selftest") },
              "MIDI：つないだ機器（仮の機器）から送った CC が、CoreMIDI を通って届く")
        MIDIEndpointDispose(src)
        MIDIClientDispose(client)
        // 光らせる判断：出しているクリップ・押しているパッド
        let e = Engine(persistent: false)
        check(!ControlHub.isOn("/halo/layer/1/clip/1", engine: e) && ControlHub.isOn("/halo/nothing", engine: e) == false,
              "MIDI：止まっているクリップのボタンは消えたまま")
        for b in hub.bindings { hub.remove(b.id) }
    }

    /// OSC（読み書き・受信・値で動かす・決まったアドレス）と Syphon（出す・受け取る）
    static func testLink(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        // 読み書き
        let m = OSCMessage(address: "/1/fader1", args: [.float(0.25), .int(3), .string("abc")])
        let back = OSCMessage.decode(m.encode())
        // バンドル（中にメッセージ 2 つ）と、T（true）
        var bundle = Data("#bundle".utf8); bundle.append(0)
        bundle.append(Data(repeating: 0, count: 8))
        for mm in [OSCMessage(address: "/a", args: [.int(1)]), OSCMessage(address: "/b", args: [.float(0.5)])] {
            let d = mm.encode()
            withUnsafeBytes(of: UInt32(d.count).bigEndian) { bundle.append(contentsOf: $0) }
            bundle.append(d)
        }
        var tPacket = Data("/t".utf8); tPacket.append(contentsOf: [0, 0]); tPacket.append(Data(",T".utf8)); tPacket.append(contentsOf: [0, 0])
        let bm = OSCMessage.decode(bundle), tm = OSCMessage.decode(tPacket)
        check(back == [m] && bm.map(\.address) == ["/a", "/b"] && bm[1].number == 0.5 && tm.first?.number == 1
              && OSCMessage.decode(Data([1, 2, 3])).isEmpty,
              "OSC：書いて読める（数・文字・バンドル・true）。壊れたデータは無視")
        // 受信：ネットワークで届いた値で、パラメーターが動く
        let hub = OSCHub.shared
        hub.forTests = true
        let port = 39_000 + Int.random(in: 0..<500)
        hub.receivePort = port
        hub.receiveOn = true
        wait(0.3)
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .udp)
        conn.start(queue: .global())
        wait(0.2)
        conn.send(content: OSCMessage(address: "/test/fader", args: [.float(0.75)]).encode(), completion: .idempotent)
        var got: Double?
        let t0 = CACurrentMediaTime()
        while got == nil && CACurrentMediaTime() - t0 < 3 { wait(0.05); got = hub.value("/test/fader") }
        var pa = ParamAnim(range: 0...100)
        pa.mode = .osc
        pa.osc = OSCLink(address: "/test/fader")
        let pv = pa.value(base: 5, at: 1, beat: BeatClock())
        pa.osc = OSCLink(address: "/nothing")
        let none = pa.value(base: 5, at: 1, beat: BeatClock())
        check(got == 0.75 && pv == 75 && none == 5,
              "OSC：ネットワークで届いた値（\(got.map { String($0) } ?? "なし")）でパラメーターが動く。まだ届いていないアドレスは元の値のまま")
        // 覚える：次に届いたアドレスを渡す
        var learned: String?
        hub.learn { learned = $0 }
        conn.send(content: OSCMessage(address: "/2/rotary3", args: [.float(0.1)]).encode(), completion: .idempotent)
        let t1 = CACurrentMediaTime()
        while learned == nil && CACurrentMediaTime() - t1 < 3 { wait(0.05) }
        check(learned == "/2/rotary3" && !hub.learning, "OSC：「覚える」を押してから届いたアドレスを覚える")
        conn.cancel()
        hub.receiveOn = false
        // 決まったアドレス（テスト用のエンジンで）
        let e = Engine(persistent: false)
        OSCCommands.run(OSCMessage(address: "/halo/layer/1/opacity", args: [.float(0.3)]), engine: e)
        OSCCommands.run(OSCMessage(address: "/halo/master/opacity", args: [.float(0.6)]), engine: e)
        OSCCommands.run(OSCMessage(address: "/halo/bpm", args: [.float(128)]), engine: e)
        OSCCommands.run(OSCMessage(address: "/halo/blackout", args: [.int(1)]), engine: e)
        let bo = e.isBlackout
        OSCCommands.run(OSCMessage(address: "/halo/blackout", args: [.int(1)]), engine: e)
        check(abs(e.layers[0].opacity - 0.3) < 1e-6 && abs(e.masterOpacity - 0.6) < 1e-6 && abs(e.bpm - 128) < 1e-9 && bo && e.isBlackout,
              "OSC：決まったアドレスで、レイヤーの不透明度・マスター・BPM・ブラックアウトを動かせる（ブラックアウト 1 を 2 回送っても点いたまま）")
        // Syphon：自分で出した絵を、自分で受け取れる（上下も正しい）
        let ctx = MetalContext.shared
        let W = 64, H = 32
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead, .renderTarget]; td.storageMode = .shared
        let src = ctx.device.makeTexture(descriptor: td)!
        var px = [UInt8](repeating: 255, count: W * H * 4)
        for y in 0..<H { for x in 0..<W { let i = (y * W + x) * 4; px[i] = y < H / 2 ? 0 : 255; px[i + 1] = 0; px[i + 2] = y < H / 2 ? 255 : 0 } }
        src.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
        let out = SyphonOutput.shared
        out.forTests = true
        out.name = "HaloVJ selftest"
        out.enabled = true
        var frame: MTLTexture?
        let key = SyphonSource.key(app: SyphonSource.selfAppName, name: "HaloVJ selftest")
        let t2 = CACurrentMediaTime()
        while frame == nil && CACurrentMediaTime() - t2 < 5 {
            let cb = ctx.queue.makeCommandBuffer()!
            out.publish(src, cb: cb)
            cb.commit(); cb.waitUntilCompleted()
            wait(0.1)
            frame = SyphonInputs.shared.frame(key)
        }
        // 受け取った絵を「Syphon から」で描いて、上が赤・下が青か見る
        var topRed = false, bottomBlue = false
        if frame != nil {
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            var g = Effect(kind: .syphonIn); g.text = key; g.values[0] = 2
            let blank = ctx.device.makeTexture(descriptor: td)!
            let cb = ctx.queue.makeCommandBuffer()!
            let o = fxp.apply(EffectStack(effects: [g]), to: blank, key: "sy", cb: cb, now: 1)
            cb.commit(); cb.waitUntilCompleted()
            var q = [UInt8](repeating: 0, count: W * H * 4)
            o.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            let top = (4 * W + W / 2) * 4, bottom = ((H - 4) * W + W / 2) * 4
            topRed = q[top + 2] > 200 && q[top] < 60
            bottomBlue = q[bottom] > 200 && q[bottom + 2] < 60
        }
        out.enabled = false
        let servers = SyphonServerDirectory.shared().servers.map {
            "\(($0[SyphonServerDescriptionAppNameKey] as? String) ?? "?")/\(($0[SyphonServerDescriptionNameKey] as? String) ?? "?")"
        }
        check(frame != nil && topRed && bottomBlue,
              "Syphon：出した絵を受け取れて、「Syphon から」で上下が正しく描ける（受け取り \(frame != nil)・上 \(topRed)・下 \(bottomBlue)・見えるサーバー \(servers)）")
    }

    /// 音に反応させる：音の解析（低音・高音・アタック）と、パラメーターが音で動くこと
    static func testAudioReactive(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let sr = 48000.0
        func run(_ f: (Double) -> Double, seconds: Double, an: inout AudioAnalyzer, t0: Double = 0) -> [Double] {
            var out: [Double] = []
            let n = 1024
            var t = 0.0
            while t < seconds {
                let buf = (0..<n).map { Float(f(t + Double($0) / sr)) }
                out = buf.withUnsafeBufferPointer {
                    an.process($0.baseAddress!, count: n, sampleRate: sr, time: t0 + t, release: 0.15, autoGain: false)
                }
                t += Double(n) / sr
            }
            return out
        }
        var a1 = AudioAnalyzer(), a2 = AudioAnalyzer(), a3 = AudioAnalyzer()
        let lowTone = run({ 0.3 * sin(2 * .pi * 60 * $0) }, seconds: 0.5, an: &a1)
        let highTone = run({ 0.3 * sin(2 * .pi * 6000 * $0) }, seconds: 0.5, an: &a2)
        let quiet = run({ _ in 0 }, seconds: 0.5, an: &a3)
        check(lowTone[1] > lowTone[3] * 5 && highTone[3] > highTone[1] * 5 && lowTone[0] > 0.3 && quiet.allSatisfy { $0 == 0 },
              String(format: "音の解析：低い音は低音に（低 %.2f・高 %.2f）、高い音は高音に（低 %.2f・高 %.2f）、無音は 0",
                     lowTone[1], lowTone[3], highTone[1], highTone[3]))
        // アタック：静かなあとに急に低音が来たら、その瞬間を覚える
        var a4 = AudioAnalyzer()
        _ = run({ 0.01 * sin(2 * .pi * 60 * $0) }, seconds: 1, an: &a4)
        let before = a4.lastOnset
        _ = run({ 0.5 * sin(2 * .pi * 55 * $0) }, seconds: 0.1, an: &a4, t0: 1)
        check(before < 0.5 && a4.lastOnset >= 1 && a4.lastOnset < 1.1, String(format: "音の解析：キックのように低音が急に来た瞬間を「アタック」にする（前 %.2f・キック %.2f）", before, a4.lastOnset))
        // 自動で合わせる：小さな音でも、最近の山を 100% として動く
        var a5 = AudioAnalyzer()
        var small: [Double] = []
        let n = 1024
        var t = 0.0
        while t < 1 {
            let buf = (0..<n).map { Float(0.02 * sin(2 * .pi * 60 * (t + Double($0) / sr))) }
            small = buf.withUnsafeBufferPointer { a5.process($0.baseAddress!, count: n, sampleRate: sr, time: t, release: 0.15, autoGain: true) }
            t += Double(n) / sr
        }
        check(small[0] > 0.8, String(format: "音の解析：自動で合わせると、小さな音でも大きく動く（%.2f）", small[0]))

        // パラメーターが音で動く（値は決め打ち：音量 0.5・低音 1・中音 0・高音 0.25・アタック 0）
        let ar = AudioReactive.shared
        ar.setOverrideForTest([0.5, 1, 0, 0.25, 0])
        var pa = ParamAnim(range: 0...10)
        pa.mode = .audio
        pa.audio = AudioLink(band: .low, gain: 1)
        let vLow = pa.value(base: 3, at: 1, beat: BeatClock())
        pa.audio = AudioLink(band: .mid, gain: 1)
        let vMid = pa.value(base: 3, at: 1, beat: BeatClock())
        pa.audio = AudioLink(band: .level, gain: 1)
        let vLevel = pa.value(base: 3, at: 1, beat: BeatClock())
        pa.audio = AudioLink(band: .high, gain: 2)
        let vHigh = pa.value(base: 3, at: 1, beat: BeatClock())
        pa.motion = .backward
        let vRev = pa.value(base: 3, at: 1, beat: BeatClock())
        check(vLow == 10 && vMid == 0 && vLevel == 5 && abs(vHigh - 5) < 1e-9 && abs(vRev - 5) < 1e-9,
              "音で動かす：音の大きさ × 感度で「から」〜「まで」を動く（低音 \(vLow)・中音 \(vMid)・音量 \(vLevel)・高音×2 \(vHigh)）")
        // エフェクトの値も音で動く
        var e = Effect(kind: .glitchBox)
        var ga = ParamAnim(range: 0...1); ga.mode = .audio; ga.audio = AudioLink(band: .low, gain: 1)
        e.anims["0"] = ga
        let ev = e.value(0, at: 1, beat: BeatClock(), origin: 0)
        ar.setOverrideForTest([0, 0, 0, 0, 0])
        let ev0 = e.value(0, at: 1, beat: BeatClock(), origin: 0)
        check(ev == 1 && ev0 == 0, "音で動かす：エフェクトの値も音で動く（低音 100% → \(ev)、0% → \(ev0)）")
        ar.setOverrideForTest(nil)
        // 保存して読み込める。音の設定の無い前の保存データも読める
        let data = try? JSONEncoder().encode(pa)
        let back = data.flatMap { try? JSONDecoder().decode(ParamAnim.self, from: $0) }
        let old = try? JSONDecoder().decode(ParamAnim.self, from: Data(#"{"mode":2,"motion":0,"seconds":4,"beats":4,"lo":0,"hi":1,"seed":7}"#.utf8))
        check(back?.mode == .audio && back?.audio == AudioLink(band: .high, gain: 2) && old?.mode == .beat && old?.audio == nil,
              "音で動かす：保存して読み込める（前の保存データも読める）")
        // アプリの音を聞く：何人聞いても、それぞれに音が届く（録画と音に反応を同時に使える）
        var c1 = 0, c2 = 0
        let l1 = AudioOutput.shared.addMixerListener { _, _ in c1 += 1 }
        let l2 = AudioOutput.shared.addMixerListener { _, _ in c2 += 1 }
        wait(0.4)
        AudioOutput.shared.removeMixerListener(l1)
        AudioOutput.shared.removeMixerListener(l2)
        check(c1 > 0 && c2 > 0, "アプリの音：録画と音に反応の両方に、同じ音が届く（\(c1)・\(c2) 回）")
    }

    /// 録画：決めた大きさの動画ファイルができ、渡した絵が入っている。音も録れる。アプリの設定は書き換えない
    static func testRecording(check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let ctx = MetalContext.shared
        let rec = Recorder.shared
        let savedDefaults = UserDefaults.standard.dictionary(forKey: "recordSettings")
        rec.forTests = true
        var st = rec.settings
        st.codec = .h264; st.fps = 30; st.size = .p720; st.audio = false
        rec.settings = st
        let red: MTLTexture = {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 36, mipmapped: false)
            td.usage = [.shaderRead]; td.storageMode = .shared
            let t = ctx.device.makeTexture(descriptor: td)!
            var px = [UInt8](repeating: 0, count: 64 * 36 * 4)
            for i in stride(from: 0, to: px.count, by: 4) { px[i] = 0; px[i + 1] = 0; px[i + 2] = 255; px[i + 3] = 255 }
            t.replace(region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: px, bytesPerRow: 64 * 4)
            return t
        }()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vjplayer-rec-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func record(_ url: URL, frames: Int, realTime: Bool) -> URL? {
            guard rec.start(outputSize: nil, aspect: 16.0 / 9, to: url) else { return nil }
            let base = CACurrentMediaTime()
            for k in 0..<frames {
                rec.capture(red, master: 1, now: realTime ? CACurrentMediaTime() : base + (Double(k) + 0.5) / 30)
                wait(realTime ? 1.0 / 30 : 0.01)
            }
            var out: URL?? = nil
            rec.stop { out = .some($0) }
            let t0 = CACurrentMediaTime()
            while out == nil && CACurrentMediaTime() - t0 < 10 { wait(0.02) }
            return out ?? nil
        }

        func inspect(_ url: URL) -> (size: CGSize, duration: Double, audio: Bool, center: (Int, Int, Int))? {
            var result: (CGSize, Double, Bool, (Int, Int, Int))?
            var done = false
            Task {
                defer { done = true }
                let asset = AVURLAsset(url: url)
                guard let v = try? await asset.loadTracks(withMediaType: .video).first,
                      let size = try? await v.load(.naturalSize),
                      let dur = try? await asset.load(.duration) else { return }
                let audio = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
                let gen = AVAssetImageGenerator(asset: asset)
                gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
                guard let img = try? await gen.image(at: CMTime(value: 5, timescale: 30)).image else { return }
                var px = [UInt8](repeating: 0, count: 4)
                let cs = CGColorSpaceCreateDeviceRGB()
                if let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    c.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))
                }
                result = (size, dur.seconds, audio, (Int(px[0]), Int(px[1]), Int(px[2])))
            }
            let t0 = CACurrentMediaTime()
            while !done && CACurrentMediaTime() - t0 < 10 { wait(0.02) }
            return result.map { (size: $0.0, duration: $0.1, audio: $0.2, center: $0.3) }
        }

        let u1 = dir.appendingPathComponent("rec.mp4")
        let f1 = record(u1, frames: 20, realTime: false)
        let i1 = f1.flatMap(inspect)
        check(f1 == u1 && i1?.size == CGSize(width: 1280, height: 720) && abs((i1?.duration ?? 0) - 20.0 / 30) < 0.05
              && (i1?.center.0 ?? 0) > 200 && (i1?.center.1 ?? 255) < 50 && (i1?.center.2 ?? 255) < 50 && i1?.audio == false,
              String(format: "録画：1280×720・30 fps の動画になり、渡した絵（赤）が入る（%.2f 秒・真ん中 %@）",
                     i1?.duration ?? -1, i1.map { "\($0.center)" } ?? "-"))
        check(rec.activeSize() == nil && !rec.isRecording, "録画：止めたら合成の大きさの指定も消える")

        st.audio = true; st.codec = .prores422; st.size = .p720
        rec.settings = st
        let u2 = dir.appendingPathComponent("rec.mov")
        let f2 = record(u2, frames: 24, realTime: true)
        let i2 = f2.flatMap(inspect)
        check(f2 == u2 && i2?.audio == true && i2?.size == CGSize(width: 1280, height: 720) && (i2?.duration ?? 0) > 0.6,
              String(format: "録画：ProRes でも書け、音（ミキサーの出口）も入る（%.2f 秒）", i2?.duration ?? -1))
        // 大きさ：出力と同じ・決めた高さ（縦横比は出力）・H.264 の上限
        var sz = RecordSettings(); sz.size = .output
        let a = sz.pixelSize(outputSize: (1920, 1080), aspect: 16.0 / 9)
        sz.size = .p1080
        let b = sz.pixelSize(outputSize: nil, aspect: 4.0 / 3)
        sz.size = .output
        let c = sz.pixelSize(outputSize: (7680, 2160), aspect: 7680.0 / 2160)
        check(a == (1920, 1080) && b == (1440, 1080) && c.0 <= 4096 && c.0 % 2 == 0 && c.1 % 2 == 0,
              "録画：大きさは出力と同じ・決めた高さ（縦横比は出力）。H.264 の上限を超えると縮める（\(c)）")
        let after = UserDefaults.standard.dictionary(forKey: "recordSettings")
        check(NSDictionary(dictionary: savedDefaults ?? [:]).isEqual(to: after ?? [:]), "録画：テストではアプリの録画の設定を書き換えない")
        try? FileManager.default.removeItem(at: dir)
    }

    /// 開発用：重ね方の見え方を 1 枚書き出す（下 = 画像、上 = ジェネレーター。1〜3 秒を 1/30 秒ずつ進めた最後のコマ）
    static func blendPreview(mode: BlendMode, path: String, top: EffectKind, below: String?, values: [Double]) {
        let ctx = MetalContext.shared
        let W = 1280, H = 720
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead]
        let blank = ctx.device.makeTexture(descriptor: td)!
        var bottom: MTLTexture
        if let below, let img = NSImage(contentsOfFile: below)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let loader = MTKTextureLoader(device: ctx.device)
            bottom = (try? loader.newTexture(cgImage: img, options: [.SRGB: false])) ?? blank
        } else {
            bottom = blank
        }
        let genP = EffectProcessor()
        var g = Effect(kind: top)
        if top == .text { g.text = "HALO"; g.values[1] = 0.5 }
        var fx = mode.effectKind.map { Effect(kind: $0) }
        for (i, v) in values.enumerated() where fx != nil && i < fx!.values.count { fx!.values[i] = v }
        let comp = Compositor()
        comp.storageMode = .shared
        var out: MTLTexture?
        var t = 1.0
        while t < 3 {
            let cb = ctx.queue.makeCommandBuffer()!
            let topTex = genP.apply(EffectStack(effects: [g], origin: 0), to: blank, key: "top", cb: cb, now: t)
            var groups = [LayerGroup(draws: [LayerDraw(texture: bottom, opacity: 1, blend: .normal, holder: nil)],
                                     opacity: 1, blend: .normal, key: 0)]
            var tg = LayerGroup(draws: [LayerDraw(texture: topTex, opacity: 1, blend: mode, holder: nil)], opacity: 1, blend: mode, key: 1)
            if let fx { tg.blendFX = EffectStack(effects: [fx]) }
            groups.append(tg)
            out = comp.composite(groups, effects: EffectStack(), width: W, height: H, cb: cb, now: t)
            cb.commit(); cb.waitUntilCompleted()
            t += 1.0 / 30
        }
        guard let out else { return }
        var px = [UInt8](repeating: 0, count: W * H * 4)
        out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2); px[i + 3] = 255 }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
        px.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, px.count) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("書き出しました: \(path)")
    }

    static func genPreview(kind: EffectKind, path: String, time: Double, values: [Double], random: Double?) {
        let ctx = MetalContext.shared
        // VJ_PREVIEW_SIZE=幅x高さ で大きさを変えられる（重さを実際の出力の大きさで測る）
        let sz = ProcessInfo.processInfo.environment["VJ_PREVIEW_SIZE"]?.split(separator: "x").compactMap { Int($0) }
        let W = sz?.count == 2 ? sz![0] : 1280, H = sz?.count == 2 ? sz![1] : 720
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead]
        var blank = ctx.device.makeTexture(descriptor: td)!
        // VJ_PREVIEW_INPUT=画像 で、エフェクトをその画像にかけて見る
        var hasImage = false
        if !kind.isGenerator, let path = ProcessInfo.processInfo.environment["VJ_PREVIEW_INPUT"],
           let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let t = try? MTKTextureLoader(device: ctx.device).newTexture(cgImage: img, options: [.SRGB: false]) {
            blank = t
            hasImage = true
        }
        var e = Effect(kind: kind)
        for (i, v) in values.enumerated() where i < e.values.count { e.values[i] = v }
        if kind == .audioScope {
            // 見本の音：低い方が大きく、高い方へ下がるスペクトラムと、2 つの波が重なった波形
            var sp = [Float](), wv = [Float]()
            for i in 0..<128 {
                let d = Double(i)
                let v: Double = 0.95 - d / 160 + 0.15 * sin(d * 0.4)
                sp.append(Float(max(0, v)))
            }
            // 本物の音に近い波形（2048 個ぶん。続いている音）
            for i in 0..<SpectrumAnalyzer.wavePoints {
                let t = Double(i) / 512
                let v: Double = 0.6 * sin(t * 6 * .pi) + 0.3 * sin(t * 31 * .pi + 1)
                wv.append(Float(v))
            }
            AudioScopeSim.testScope = (sp, wv)
        }
        if let random, e.values.count > 8 { e.values[8] = random }
        let fxp = EffectProcessor(); fxp.storageMode = .shared
        var out = blank
        var ms = 0.0
        // GPU の時間は、ほかのアプリとの取り合いでぶれるので、20 回のうちいちばん速いもの
        ms = .infinity
        for k in 0..<22 {
            let cb = ctx.queue.makeCommandBuffer()!
            // 群れは 1 コマずつ進める（動かす分の時間も測る）
            // エフェクト（ジェネレーターでないもの）は、格子の絵にかけて見る
            var input = [e]
            if !kind.isGenerator && !hasImage {
                var g = Effect(kind: .grid); g.values = [1, 9, 0.1, kind.isStateful ? 0.6 : 0]; g.color = RGB.hsb(0.55, 0.6, 1)
                input = [g, e]
            }
            out = fxp.apply(EffectStack(effects: input), to: blank, key: "g", cb: cb,
                            now: kind.isStateful ? time + Double(k) / 60 : time)
            cb.commit(); cb.waitUntilCompleted()
            if k >= 2 { ms = min(ms, (cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        var px = [UInt8](repeating: 0, count: W * H * 4)
        out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            let b = UInt8(min(Double(px[i]) + 14 * (1 - a), 255)), r = UInt8(min(Double(px[i + 2]) + 14 * (1 - a), 255))
            px[i + 1] = UInt8(min(Double(px[i + 1]) + 14 * (1 - a), 255))
            px[i] = r; px[i + 2] = b; px[i + 3] = 255
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
        px.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, px.count) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print(String(format: "書き出しました: %@（GPU %.2f ms / %d×%d）", path, ms, W, H))
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
        let mixer = AudioOutput.shared.masterMixer
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
