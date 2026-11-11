import AppKit
import Metal

extension SelfTest {
    /// 追加のエフェクト（第 2 弾）：名前・分類・値がそろっていて、描ける。量 0 で元の絵のまま、値や時間で絵が変わる。1920×1080 での重さ
    static func testKinds2FX(check: (Bool, String) -> Void) {
        let kinds: [EffectKind] = [.blur, .lens, .polar, .tile, .keyer, .ledWall, .slices, .shake,
                                   .film, .tiltShift, .emboss, .stretch, .displace, .droste]
        let cats: [EffectKind: EffectCategory] = [.blur: .light, .lens: .shape, .polar: .shape, .tile: .shape, .keyer: .color,
                                                 .ledWall: .glitch, .slices: .glitch, .shake: .shape,
                                                 .film: .retro, .tiltShift: .light, .emboss: .light, .stretch: .glitch, .displace: .shape,
                                                 .droste: .shape]
        var bad: [String] = []
        for k in kinds {
            let back = (try? JSONEncoder().encode(Effect(kind: k))).flatMap { try? JSONDecoder().decode(Effect.self, from: $0) }
            if !EffectKind.moreEffects.contains(k) || k.isGenerator || k.category != cats[k] || k.moreLabel == nil || k.moreHelp == nil
                || NSImage(systemSymbolName: k.icon, accessibilityDescription: nil) == nil || back?.kind != k
                || !k.params.allSatisfy({ !$0.animatable || $0.animRange != nil })
                || !AddEffectMenuItems.groups.contains(where: { $0.1.contains(k) }) {
                bad.append(k.rawValue)
            }
        }
        check(bad.isEmpty, "追加のエフェクト（第 2・3 弾）：名前・印・分類・説明・動かす範囲がそろい、一覧に出て、保存して読み込める"
              + (bad.isEmpty ? "" : "（だめ：\(bad.joined(separator: "、"))）"))

        let ctx = MetalContext.shared
        func makeSource(_ W: Int, _ H: Int) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
            td.usage = [.shaderRead, .renderTarget]; td.storageMode = .shared
            let t = ctx.device.makeTexture(descriptor: td)!
            // 左右で色の違う、まだらの絵（右下に暗い所、真ん中に緑の四角）
            var px = [UInt8](repeating: 255, count: W * H * 4)
            for y in 0..<H { for x in 0..<W {
                let i = (y * W + x) * 4
                px[i] = UInt8((x * 255 / W + y * 3) % 256); px[i + 1] = UInt8(y * 255 / H); px[i + 2] = x < W / 2 ? 230 : 40
                if x > W * 2 / 5 && x < W * 3 / 5 && y > H / 3 && y < H * 2 / 3 { px[i] = 30; px[i + 1] = 220; px[i + 2] = 30 }
                if x > W * 3 / 4 && y > H * 3 / 4 { px[i] = 5; px[i + 1] = 5; px[i + 2] = 5 }
            } }
            t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
            return t
        }
        let W = 320, H = 180
        let src = makeSource(W, H)
        func bytes(_ t: MTLTexture) -> [UInt8] {
            var q = [UInt8](repeating: 0, count: t.width * t.height * 4)
            t.getBytes(&q, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
            return q
        }
        let orig = bytes(src)
        func run(_ k: EffectKind, _ vals: [Int: Double] = [:], now: Double = 3, color: RGB? = nil) -> [UInt8] {
            var e = Effect(kind: k)
            for (i, v) in vals { e.values[i] = v }
            if let color { e.color = color }
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            let cb = ctx.queue.makeCommandBuffer()!
            let out = fxp.apply(EffectStack(effects: [e]), to: src, key: "k2", cb: cb, now: now)
            cb.commit(); cb.waitUntilCompleted()
            return bytes(out)
        }
        /// 画素の差の平均（0〜255）と、いちばん大きい差
        func diff(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, max: Int) {
            var s = 0, m = 0
            for i in 0..<min(a.count, b.count) { let d = abs(Int(a[i]) - Int(b[i])); s += d; m = max(m, d) }
            return (Double(s) / Double(max(a.count, 1)), m)
        }
        func meanAlpha(_ a: [UInt8]) -> Double {
            var s = 0
            for i in stride(from: 3, to: a.count, by: 4) { s += Int(a[i]) }
            return Double(s) / Double(a.count / 4) / 255
        }

        // はじめの値で描ける（真っ黒・真っ透明でない）、絵が変わる
        var dead: [String] = []
        for k in kinds {
            let q = run(k)
            var lit = 0
            for i in stride(from: 0, to: q.count, by: 4) where Int(q[i]) + Int(q[i + 1]) + Int(q[i + 2]) > 30 { lit += 1 }
            if lit < W * H / 4 || diff(q, orig).mean < 0.5 { dead.append("\(k.rawValue)（\(lit) 画素・差 \(String(format: "%.2f", diff(q, orig).mean))）") }
        }
        check(dead.isEmpty, "追加のエフェクト（第 2・3 弾）：はじめの値で描けて、元の絵が変わる" + (dead.isEmpty ? "" : "（だめ：\(dead.joined(separator: "、"))）"))

        // 量 0 で元の絵そのまま
        let zero: [(EffectKind, [Int: Double])] = [(.blur, [0: 0]), (.lens, [1: 0]), (.tile, [0: 1, 1: 1]), (.keyer, [0: 0, 1: 0]),
                                                   (.slices, [2: 0]), (.shake, [0: 0]),
                                                   (.film, [0: 0, 2: 0, 4: 0, 5: 0, 6: 0, 7: 0, 8: 0]), (.tiltShift, [0: 0, 6: 1, 7: 1]),
                                                   (.emboss, [0: 0, 4: 1]), (.stretch, [0: 0, 1: 1]), (.displace, [0: 0]),
                                                   (.droste, [1: 1, 4: 0])]
        var notSame: [String] = []
        for (k, v) in zero {
            let d = diff(run(k, v), orig)
            if d.max > 1 { notSame.append("\(k.rawValue)（差 \(d.max)）") }
        }
        check(notSame.isEmpty, "追加のエフェクト（第 2・3 弾）：量 0 で元の絵そのまま（ぼかし・レンズ・タイル・キー抜き・スライス・ゆれ・フィルム・ミニチュア風・浮き彫り・引き伸ばし・明るさでずらす・入れ子）"
              + (notSame.isEmpty ? "" : "（だめ：\(notSame.joined(separator: "、"))）"))

        // 値を変えると絵が変わる（主な選択肢も）
        let changes: [(EffectKind, [Int: Double], [Int: Double])] = [
            (.blur, [0: 4], [0: 40]), (.blur, [1: 0], [1: 1]),
            (.lens, [0: 0], [0: 2]), (.lens, [0: 3], [0: 4]),
            (.polar, [0: 0], [0: 1]), (.polar, [3: 1], [3: 3]),
            (.tile, [0: 2], [0: 5]), (.tile, [3: 0], [3: 3]),
            (.keyer, [0: 0], [0: 1]), (.keyer, [6: 0], [6: 1]),
            (.ledWall, [1: 0], [1: 1]), (.ledWall, [0: 10], [0: 30]),
            (.slices, [3: 0], [3: 3]), (.slices, [0: 0], [0: 1]),
            (.shake, [2: 0], [2: 1]), (.shake, [0: 10], [0: 80]),
            (.film, [0: 0], [0: 1]), (.film, [2: 0], [2: 1]),
            (.tiltShift, [0: 5], [0: 60]), (.tiltShift, [5: 0], [5: 1]),
            (.emboss, [4: 0], [4: 2]), (.emboss, [1: 0], [1: 180]),
            (.stretch, [0: 0], [0: 4]), (.stretch, [1: 0.3], [1: 0.7]),
            (.displace, [2: 0], [2: 2]), (.displace, [0: 20], [0: 150]),
            (.droste, [8: 0], [8: 1]), (.droste, [0: 0.5], [0: 0.85]),
        ]
        var same: [String] = []
        for (k, a, b) in changes where diff(run(k, a), run(k, b)).mean < 0.3 { same.append("\(k.rawValue) \(a)→\(b)") }
        check(same.isEmpty, "追加のエフェクト（第 2・3 弾）：値・種類を変えると絵が変わる" + (same.isEmpty ? "" : "（だめ：\(same.joined(separator: "、"))）"))

        // 時間で動く（スライスの組み替え・ゆれ・極座標の回転・タイルの流れ）
        var still: [String] = []
        for (k, v) in [(EffectKind.slices, [4: 4.0]), (.shake, [:]), (.polar, [2: 60.0]), (.tile, [5: 0.5]),
                       (.film, [:]), (.emboss, [2: 90.0]), (.droste, [:]), (.stretch, [2: 0.5])]
            where diff(run(k, v, now: 3), run(k, v, now: 3.37)).mean < 0.3 { still.append(k.rawValue) }
        check(still.isEmpty, "追加のエフェクト（第 2・3 弾）：時間で動く（スライス・ゆれ・極座標・タイル・フィルム・浮き彫り・入れ子・引き伸ばし）" + (still.isEmpty ? "" : "（だめ：\(still.joined(separator: "、"))）"))

        // キー抜き：暗い所を抜くと右下の暗い所が透明に。色で抜くと緑の四角が透明に。逆にすると反対
        do {
            let dark = run(.keyer, [0: 0, 1: 0.2, 2: 0.05])
            let green = run(.keyer, [0: 2, 3: 0.3, 2: 0.05], color: RGB(r: 0, g: 1, b: 0))
            let inv = run(.keyer, [0: 2, 3: 0.3, 2: 0.05, 5: 1], color: RGB(r: 0, g: 1, b: 0))
            func a(_ q: [UInt8], _ x: Int, _ y: Int) -> UInt8 { q[(y * W + x) * 4 + 3] }
            check(a(dark, W - 10, H - 10) < 10 && a(dark, 10, 10) > 245 && a(green, W / 2, H / 2) < 10 && a(green, 10, 10) > 245
                  && a(inv, W / 2, H / 2) > 245 && a(inv, 10, 10) < 10 && meanAlpha(green) < 0.99,
                  "キー抜き：暗い所・選んだ色が透明になり、逆にすると反対になる")
        }

        // 重さ：1920×1080 で（いちばん速い回）
        let big = makeSource(1920, 1080)
        var times: [String] = []
        var slow: [String] = []
        let cases: [(String, EffectKind, [Int: Double], Double)] = [
            ("ぼかし", .blur, [:], 2), ("ぼかし 200px", .blur, [0: 200], 2), ("ぼかし 40px", .blur, [0: 40], 2),
            ("レンズ", .lens, [:], 1), ("極座標", .polar, [:], 1), ("タイル", .tile, [:], 1), ("キー抜き", .keyer, [:], 1),
            ("LED", .ledWall, [:], 1), ("LED RGB", .ledWall, [1: 1, 4: 1], 1), ("スライス", .slices, [:], 1), ("ゆれ", .shake, [5: 1], 1),
            ("フィルム", .film, [:], 1), ("ミニチュア風", .tiltShift, [:], 1), ("ミニチュア風 80px", .tiltShift, [0: 80], 1),
            ("浮き彫り", .emboss, [:], 1), ("引き伸ばし", .stretch, [:], 1), ("明るさでずらす", .displace, [:], 1),
            ("明るさでずらす ぼかし最大", .displace, [3: 1], 1), ("入れ子", .droste, [:], 1),
        ]
        for (name, k, vals, limit) in cases {
            var e = Effect(kind: k)
            for (i, v) in vals { e.values[i] = v }
            let fxp = EffectProcessor()
            var ms = Double.infinity
            for f in 0..<12 {
                let cb = ctx.queue.makeCommandBuffer()!
                _ = fxp.apply(EffectStack(effects: [e]), to: big, key: "k2big", cb: cb, now: 3 + Double(f) / 60)
                cb.commit(); cb.waitUntilCompleted()
                if f >= 2 { ms = min(ms, (cb.gpuEndTime - cb.gpuStartTime) * 1000) }
            }
            times.append("\(name) \(String(format: "%.2f", ms))")
            // GPU の取り合いでぶれるので、目安の 2 倍まで
            if ms > limit * 2 { slow.append(name) }
        }
        // 作業用の絵：大きさの違う 2 つの絵に、量の違うぼかし・ミニチュア風・タイルを交互にかけても、作り直さない
        do {
            let small = makeSource(640, 360)
            var b1 = Effect(kind: .blur); b1.values[0] = 60
            var b2 = Effect(kind: .blur); b2.values[0] = 3
            var b3 = Effect(kind: .blur); b3.values[0] = 30; b3.values[1] = 1
            let ts = Effect(kind: .tiltShift), tl = Effect(kind: .tile), ds = Effect(kind: .displace)
            let stack = EffectStack(effects: [b1, b2, b3, ts, tl, ds])
            let fa = EffectProcessor(), fb = EffectProcessor()
            func frame(_ f: Int) {
                let cb = ctx.queue.makeCommandBuffer()!
                _ = fa.apply(stack, to: big, key: "cacheA", cb: cb, now: 3 + Double(f) / 60)
                _ = fb.apply(stack, to: small, key: "cacheB", cb: cb, now: 3 + Double(f) / 60)
                cb.commit(); cb.waitUntilCompleted()
            }
            for f in 0..<3 { frame(f) }
            let before = MoreFX2Renderer.shared.texturesMade
            for f in 3..<13 { frame(f) }
            let made = MoreFX2Renderer.shared.texturesMade - before
            check(made == 0, "追加のエフェクト：大きさの違う 2 つの絵に、量の違うぼかしなどを交互にかけても、作業用の絵を作り直さない（10 コマで \(made) 枚）")
        }
        check(slow.isEmpty, "追加のエフェクト（第 2・3 弾）：1920×1080 で軽い（ms：\(times.joined(separator: "・"))）"
              + (slow.isEmpty ? "" : "（重い：\(slow.joined(separator: "、"))）"))
    }
}
