import AppKit
import Foundation
import Metal

// セルフテスト：出力のスナップショット（今の絵を静止画で保存・クリップにする）。
// 保存は一時フォルダだけ（録画の保存先・アプリの設定には書かない）。

extension SelfTest {
    static func testSnapshot(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vjplayer-snapshot-test", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let e = Engine(persistent: false)
        e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
        let t0 = CACurrentMediaTime()
        while e.slots[0]?.isReady != true && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
        // このエンジン用の描画ループ。画面が無いと CVDisplayLink が回らないので、ほかのテストと同じく
        // メインスレッドからコマを進める（start はしない）
        let loop = RenderLoop(engine: e)
        defer { e.stopAll() }
        /// s 秒のあいだ、60 分の 1 秒ごとに 1 コマ描く。until が true になったら途中で終わる
        func run(_ s: Double, until: () -> Bool = { false }) {
            let t = CACurrentMediaTime()
            while !until() && CACurrentMediaTime() - t < s {
                loop.tickForTest()
                wait(1.0 / 60)
            }
        }
        e.trigger(0)
        run(0.5)

        /// 撮って、終わるまで待つ
        func shoot(asClip: Bool = false) -> SnapshotResult? {
            var out: SnapshotResult?
            guard e.takeSnapshot(asClip: asClip, folder: dir, done: { out = $0 }) else { return nil }
            run(6) { out != nil }
            return out
        }
        /// 大きさ・アルファの有無と、見本の色。テストの動画はカラーバーで、左端の 1/6 が赤なので、
        /// 左から 1/12・高さの真ん中の色を見る（何も出していないときは真ん中も同じ所も黒）
        func inspect(_ url: URL?) -> (w: Int, h: Int, alpha: Bool, center: (Int, Int, Int))? {
            guard let url, let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()),
                  let c = rep.colorAt(x: rep.pixelsWide / 12, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { return nil }
            return (rep.pixelsWide, rep.pixelsHigh, rep.hasAlpha,
                    (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)))
        }

        // 赤い動画を出して 1 枚：コンポジションの大きさ（出力先に合わせるときは 16:9 なら 1920×1080）・赤の所が赤
        let r1 = shoot()
        let i1 = inspect(r1?.url)
        check(r1?.url?.pathExtension == "png" && r1?.url?.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL
              && i1?.w == 1920 && i1?.h == 1080 && i1?.alpha == false
              // テストの動画の赤は、読み込んだ絵の時点で緑が少し入る（50 くらい）。赤が強ければよい
              && (i1?.center.0 ?? 0) > 200 && (i1?.center.1 ?? 255) < 90 && (i1?.center.2 ?? 255) < 50,
              "スナップショット：今の絵が PNG になる（\(i1.map { "\($0.w)×\($0.h)・赤の所 \($0.center)・アルファ \($0.alpha)" } ?? "-")）")
        check(r1?.url?.lastPathComponent.hasPrefix("\(AppInfo.name) ") == true,
              "スナップショット：ファイル名はアプリの名前と日時（\(r1?.url?.lastPathComponent ?? "-")）")
        // 名前を見るための 1 枚を、テストが終わってから確かめられるように残す（一時フォルダの外の、テスト用の場所）
        if let u = r1?.url, let keep = ProcessInfo.processInfo.environment["VJ_SNAPSHOT_KEEP"] {
            try? FileManager.default.removeItem(atPath: keep)
            try? FileManager.default.copyItem(at: u, to: URL(fileURLWithPath: keep))
        }

        // 色：録画と同じ描き方なので、8 ビットの値がそのまま PNG に入る（色の変換でずれない）
        do {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 36, mipmapped: false)
            td.usage = [.shaderRead]
            let tex = MetalContext.shared.device.makeTexture(descriptor: td)!
            var px = [UInt8](repeating: 255, count: 64 * 36 * 4)
            for i in stride(from: 0, to: px.count, by: 4) { px[i] = 40; px[i + 1] = 128; px[i + 2] = 200 }
            tex.replace(region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: px, bytesPerRow: 64 * 4)
            let url = dir.appendingPathComponent("color.png")
            var ok: Bool?
            Snapshot.capture(tex, width: 64, height: 36, request: SnapshotRequest(url: url) { ok = $0 })
            let t = CACurrentMediaTime()
            while ok == nil && CACurrentMediaTime() - t < 5 { wait(0.02) }
            let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data())
            let p = rep.flatMap { r in r.bitmapData.map { d in (Int(d[0]), Int(d[1]), Int(d[2])) } }
            let srgb = rep?.colorSpace.cgColorSpace?.name == CGColorSpace.sRGB
            check(ok == true && p.map { $0 == (200, 128, 40) } == true && srgb && rep?.bitsPerSample == 8,
                  "スナップショット：色は 8 ビットの値のまま・sRGB の PNG（\(p.map { "\($0)" } ?? "-")）")
        }

        // 解像度を決めているときは、その大きさ
        e.outputFormat = OutputFormat(width: 640, height: 480)
        run(0.1)
        let i2 = inspect(shoot()?.url)
        check(i2?.w == 640 && i2?.h == 480 && (i2?.center.0 ?? 0) > 200,
              "スナップショット：解像度を決めていれば、その大きさ（\(i2.map { "\($0.w)×\($0.h)" } ?? "-")）")
        e.outputFormat = OutputFormat()
        run(0.1)

        // 続けて 2 回頼んでも、2 回目は無視（1 回目が終わるまで）
        var firstDone: SnapshotResult?
        let a = e.takeSnapshot(folder: dir) { firstDone = $0 }
        let b = e.takeSnapshot(folder: dir)
        run(6) { firstDone != nil }
        check(a && !b && firstDone?.url != nil && !e.snapshotBusy, "スナップショット：取っている途中の 2 回目は無視する")

        // 何も出していないときは黒
        e.stopAll()
        run(0.3)
        let i3 = inspect(shoot()?.url)
        check(i3?.w == 1920 && i3.map { $0.center.0 + $0.center.1 + $0.center.2 } == 0,
              "スナップショット：何も出していないときは黒（\(i3.map { "\($0.center)" } ?? "-")）")

        // クリップにする：選んでいるレイヤーの空いているスロットに、静止画のクリップが入る（再生はしない）。元に戻すと消える
        e.trigger(0)
        run(0.3)
        e.selectedLayer = 0
        e.commitUndoStep()
        let r4 = shoot(asClip: true)
        let s4 = r4?.slot
        let placed = s4.flatMap { e.slots[$0] }
        check(s4 == 1 && placed?.isImage == true && placed?.url == r4?.url && e.activeByLayer[0] == 0,
              "スナップショット：クリップにすると、選んでいるレイヤーの空いているスロットに静止画が入る（\(s4.map(String.init) ?? "-")）")
        e.undo()
        check(e.slots[1] == nil && e.slots[0] != nil, "スナップショット：置いたクリップは 1 回の元に戻すで消える")

        // 選んでいるレイヤーが埋まっていたら、上から順に空きのあるレイヤーへ
        for c in 0..<e.columns where e.slots[c] == nil { e.setSlot(c, ClipSlot(generator: Effect(kind: .solid))) }
        e.selectedLayer = 0
        let r5 = shoot(asClip: true)
        check(r5?.slot.map { e.layerOf($0) } == 1, "スナップショット：選んでいるレイヤーに空きが無ければ、上の空きのあるレイヤーに置く")

        // 空きが無いとき：保存だけして、落ちない
        for i in e.slots.indices where e.slots[i] == nil { e.setSlot(i, ClipSlot(generator: Effect(kind: .solid))) }
        let r6 = shoot(asClip: true)
        check(r6?.url != nil && r6?.slot == nil && Recorder.shared.lastError != nil,
              "スナップショット：空きが無いときは保存だけして知らせる")

        // OSC：/halo/snapshot・/halo/snapshot/clip（保存先は録画の設定。テストの間だけ一時フォルダにする）
        let rec = Recorder.shared
        let savedDefaults = UserDefaults.standard.dictionary(forKey: "recordSettings")
        let oldForTests = rec.forTests, oldSettings = rec.settings
        rec.forTests = true
        rec.settings.folder = dir
        func pngs() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".png") }.count
        }
        for i in e.slots.indices where e.layerOf(i) == 3 { e.setSlot(i, nil) }
        let n0 = pngs()
        OSCCommands.run(OSCMessage(address: "/halo/snapshot", args: []), engine: e)
        run(6) { !e.snapshotBusy && pngs() > n0 }
        let n1 = pngs()
        OSCCommands.run(OSCMessage(address: "/halo/snapshot/clip", args: []), engine: e)
        run(6) { !e.snapshotBusy && pngs() > n1 }
        let clipSlot = e.slots.indices.first { e.layerOf($0) == 3 && e.slots[$0]?.isImage == true }
        check(n1 == n0 + 1 && pngs() == n1 + 1 && clipSlot != nil,
              "スナップショット：OSC の /halo/snapshot・/halo/snapshot/clip で撮れる")
        rec.settings = oldSettings
        rec.forTests = oldForTests
        let after = UserDefaults.standard.dictionary(forKey: "recordSettings")
        check(NSDictionary(dictionary: savedDefaults ?? [:]).isEqual(to: after ?? [:]),
              "スナップショット：テストではアプリの録画の設定を書き換えない")
    }
}
