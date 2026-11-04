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
        AudioOutput.shared.engine.mainMixerNode.outputVolume = 0
        let a = ClipSlot(url: URL(fileURLWithPath: paths[0]))
        let b = ClipSlot(url: URL(fileURLWithPath: paths[1]))
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
        check(drag.maxGapMs <= steady.maxGapMs + 5 && drag.backwardJumps == 0 && drag.maxLagMs < 40,
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
        for mode in BlendMode.allCases {
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
        let c = Engine.columns
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

        e.blackout()
        check(e.activeByLayer.allSatisfy { $0 == nil } && e.layerDraws().isEmpty, "ブラックアウトで全レイヤー停止")
    }

    static func testRenderThread(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
        e.load(urls: [URL(fileURLWithPath: paths[1])], startingAt: Engine.columns)
        let t0 = CACurrentMediaTime()
        while !(e.slots[0]?.isReady == true && e.slots[Engine.columns]?.isReady == true) && CACurrentMediaTime() - t0 < 10 { wait(0.05) }

        let loop = RenderLoop(engine: e)
        let layer = CAMetalLayer()
        layer.device = MetalContext.shared.device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 1280, height: 720)
        loop.add(layer)
        e.trigger(0)
        e.trigger(Engine.columns)
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
        e.blackout()

        func fmt(_ s: RenderLoop.Stats) -> String {
            String(format: "vsync=%d 新フレーム=%d 最大間隔=%.1fms vsync最大間隔=%.1fms", s.ticks, s.newFrames, s.maxNewFrameGapMs, s.maxTickGapMs)
        }
        print("   通常時:           \(fmt(idle))")
        print("   メインが忙しい時: \(fmt(busy))")
        check(busy.newFrames >= 27 && busy.maxNewFrameGapMs < 50,
              "メインスレッドが 1 秒ふさがっていても、出力の映像は 30fps で更新され続ける")
    }

    static func testPreviews(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let e = Engine(persistent: false)
        let c = Engine.columns
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
        e.blackout()
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
