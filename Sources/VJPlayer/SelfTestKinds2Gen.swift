import Foundation
import Metal
import simd

// 追加のジェネレーター 第 2 弾のテスト（プラズマ・オーロラ・星雲・トルシェ・六角・文字の雨・ワイヤーフレーム・モアレ）

extension SelfTest {
    static func testKinds2Gen(check: (Bool, String) -> Void) {
        let kinds = EffectKind.moreGenerators2
        // 名前・値・説明・分類がそろっていて、ジェネレーターの一覧に並ぶ。保存しても名前で戻る
        var bad: [String] = []
        for k in kinds {
            let e = Effect(kind: k)
            let raw = (try? JSONEncoder().encode(e)).flatMap { try? JSONDecoder().decode(Effect.self, from: $0) }
            if !k.isGenerator || !EffectKind.generators.contains(k) || !EffectKind.moreGenerators.contains(k)
                || k.generatorCategory == nil || k.moreLabel == nil || k.moreHelp == nil || k.moreIcon == nil
                || e.values.count != k.params.count || !e.hasQuality || KindPreview.isLive(k) || raw?.kind != k {
                bad.append(k.rawValue)
            }
            // 動かせる値には、動かすと気持ちいい範囲が付いている
            for p in k.params where p.animatable && p.animRange == nil { bad.append("\(k.rawValue)・\(p.label)") }
        }
        check(bad.isEmpty, "追加のジェネレーター 第 2 弾 8 個：名前・印・値・説明・分類・画質がそろい、保存で戻る" + (bad.isEmpty ? "" : "（だめ：\(bad.joined(separator: "、"))）"))

        // 描いてみる：何か出る・真っ白でない・時間で動く・値を変えると絵が変わる・まわりが透明なものは透明な所がある
        let ctx = MetalContext.shared
        let W = 320, H = 180
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead]
        let blank = ctx.device.makeTexture(descriptor: td)!
        func draw(_ e: Effect, at t: Double) -> [UInt8] {
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            let cb = ctx.queue.makeCommandBuffer()!
            let out = fxp.apply(EffectStack(effects: [e]), to: blank, key: "k2", cb: cb, now: t)
            cb.commit(); cb.waitUntilCompleted()
            var q = [UInt8](repeating: 0, count: W * H * 4)
            out.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            return q
        }
        func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var s = 0
            for i in stride(from: 0, to: a.count, by: 4) { s += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) }
            return Double(s) / Double(W * H * 3)
        }
        // まわりが透明（加算で重ねやすい）なもの
        let clear: Set<EffectKind> = [.aurora, .truchet, .hexGrid, .codeRain, .wireframe, .moire, .nebula]
        // 値を変えて見るもの（番号, 値）
        let change: [EffectKind: (Int, Double)] = [.plasma: (3, 3), .aurora: (4, 1), .nebula: (7, 2), .truchet: (1, 2),
                                                   .hexGrid: (3, 2), .codeRain: (7, 2), .wireframe: (0, 3), .moire: (0, 1)]
        bad = []
        for k in kinds {
            let e = Effect(kind: k)
            let a = draw(e, at: 3), b = draw(e, at: 5.5)
            var lit = 0, white = 0, transparent = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                let s = Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])
                if s > 30 { lit += 1 }
                if s > 735 { white += 1 }
                if a[i + 3] < 8 { transparent += 1 }
            }
            var e2 = e
            if let (i, v) = change[k] { e2.values[i] = v }
            let c = draw(e2, at: 3)
            let n = W * H
            var why: [String] = []
            if lit < n / 50 { why.append("暗い \(lit)") }
            if white > n / 3 { why.append("真っ白 \(white)") }
            if diff(a, b) < 0.5 { why.append("動かない") }
            if diff(a, c) < 0.5 { why.append("値で変わらない") }
            if clear.contains(k) && transparent < n / 50 { why.append("透明な所が無い") }
            if !why.isEmpty { bad.append("\(k.rawValue)（\(why.joined(separator: "・"))）") }
        }
        check(bad.isEmpty, "追加のジェネレーター 第 2 弾：絵が出る・真っ白でない・時間で動く・値で変わる・まわりは透明" + (bad.isEmpty ? "" : "（だめ：\(bad.joined(separator: "、"))）"))

        // 線の太さは高さ 1080 を基準：描く大きさを半分にしても、線の太さの割合は同じ（ワイヤーフレーム）
        let segFull = MoreGen2Renderer.wireframeSegs(Effect(kind: .wireframe), v: { Float(Effect(kind: .wireframe).value($0)) }, t: 1, size: SIMD2(1920, 1080))
        let segHalf = MoreGen2Renderer.wireframeSegs(Effect(kind: .wireframe), v: { Float(Effect(kind: .wireframe).value($0)) }, t: 1, size: SIMD2(960, 540))
        let ok = segFull.count == 12 && segHalf.count == 12 && abs(segFull[0].info.x / 1080 - segHalf[0].info.x / 540) < 1e-5
            && zip(segFull, segHalf).allSatisfy { simd_distance($0.ab, $1.ab) < 1e-5 }
        // 形ごとの辺の数（二十面体は 30 本）
        let edges = MoreGen2Renderer.shapes.map(\.count)
        check(ok && edges[0] == 12 && edges[1] == 6 && edges[2] == 12 && edges[3] == 30 && edges[6] == 8,
              "回るワイヤーフレーム：辺の数が正しく（立方体 12・四面体 6・八面体 12・二十面体 30・ピラミッド 8）、線の太さは描く大きさに比例する（\(edges)）")
        testKinds3Gen(check: check)
    }

    /// 第 3 弾（放射の光・稜線・玉ぼけ・うず巻き・細胞・リサージュ・花火・炎）
    static func testKinds3Gen(check: (Bool, String) -> Void) {
        let kinds = EffectKind.moreGenerators3
        var bad: [String] = []
        for k in kinds {
            let e = Effect(kind: k)
            let raw = (try? JSONEncoder().encode(e)).flatMap { try? JSONDecoder().decode(Effect.self, from: $0) }
            if !k.isGenerator || !EffectKind.generators.contains(k) || !EffectKind.moreGenerators.contains(k)
                || k.generatorCategory == nil || k.moreLabel == nil || k.moreHelp == nil || k.moreIcon == nil
                || e.values.count != k.params.count || !e.hasQuality || KindPreview.isLive(k) || raw?.kind != k || !k.hasDice {
                bad.append(k.rawValue)
            }
            for p in k.params where p.animatable && p.animRange == nil { bad.append("\(k.rawValue)・\(p.label)") }
        }
        check(bad.isEmpty, "追加のジェネレーター 第 3 弾 8 個：名前・印・値・説明・分類・画質がそろい、保存で戻る" + (bad.isEmpty ? "" : "（だめ：\(bad.joined(separator: "、"))）"))

        let ctx = MetalContext.shared
        let W = 320, H = 180
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead]
        let blank = ctx.device.makeTexture(descriptor: td)!
        func draw(_ e: Effect, at t: Double) -> [UInt8] {
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            let cb = ctx.queue.makeCommandBuffer()!
            let out = fxp.apply(EffectStack(effects: [e]), to: blank, key: "k3", cb: cb, now: t)
            cb.commit(); cb.waitUntilCompleted()
            var q = [UInt8](repeating: 0, count: W * H * 4)
            out.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            return q
        }
        func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var s = 0
            for i in stride(from: 0, to: a.count, by: 4) { s += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) }
            return Double(s) / Double(W * H * 3)
        }
        let clear: Set<EffectKind> = [.sunburst, .ridgeLines, .bokeh, .voronoi, .lissajous, .fireworks, .fire]
        let change: [EffectKind: (Int, Double)] = [.sunburst: (0, 6), .ridgeLines: (1, 1), .bokeh: (6, 1), .spiral: (4, 2),
                                                   .voronoi: (2, 1), .lissajous: (0, 7), .fireworks: (9, 1), .fire: (8, 2)]
        bad = []
        for k in kinds {
            let e = Effect(kind: k)
            let a = draw(e, at: 4), b = draw(e, at: 6.5)
            var lit = 0, white = 0, transparent = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                let s = Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])
                if s > 30 { lit += 1 }
                if s > 735 { white += 1 }
                if a[i + 3] < 8 { transparent += 1 }
            }
            var e2 = e
            if let (i, v) = change[k] { e2.values[i] = v }
            let c = draw(e2, at: 4)
            let n = W * H
            var why: [String] = []
            if lit < n / 200 { why.append("暗い \(lit)") }
            if white > n / 3 { why.append("真っ白 \(white)") }
            if diff(a, b) < 0.3 { why.append("動かない") }
            if diff(a, c) < 0.3 { why.append("値で変わらない") }
            if clear.contains(k) && transparent < n / 50 { why.append("透明な所が無い") }
            if !why.isEmpty { bad.append("\(k.rawValue)（\(why.joined(separator: "・"))）") }
        }
        check(bad.isEmpty, "追加のジェネレーター 第 3 弾：絵が出る・真っ白でない・時間で動く・値で変わる・まわりは透明" + (bad.isEmpty ? "" : "（だめ：\(bad.joined(separator: "、"))）"))

        // CPU で作る線と粒：リサージュは 1 本 384 区切りで本数ぶん。花火は線分の上限（fireworkSegBudget）まで
        let li = Effect(kind: .lissajous)
        var li4 = li; li4.values[10] = 4
        let ls1 = MoreGen2Renderer.lissajousSegs(li, v: { Float(li.value($0)) }, t: 2, size: SIMD2(1920, 1080))
        let ls4 = MoreGen2Renderer.lissajousSegs(li4, v: { Float(li4.value($0)) }, t: 2, size: SIMD2(1920, 1080))
        var fw = Effect(kind: .fireworks)
        fw.values[0] = 6; fw.values[2] = 120; fw.values[4] = 1
        var most = 0
        for i in 0..<40 {
            let segs = MoreGen2Renderer.fireworkSegs(fw, v: { Float(fw.value($0)) }, t: 10 + Float(i) * 0.25, size: SIMD2(1920, 1080))
            most = max(most, segs.count)
        }
        // 同じ時刻なら同じ絵（前のコマを覚えていない）
        let f1 = MoreGen2Renderer.fireworkSegs(fw, v: { Float(fw.value($0)) }, t: 12.3, size: SIMD2(1920, 1080))
        let f2 = MoreGen2Renderer.fireworkSegs(fw, v: { Float(fw.value($0)) }, t: 12.3, size: SIMD2(1920, 1080))
        let same = f1.count == f2.count && zip(f1, f2).allSatisfy { $0.ab == $1.ab }
        check(ls1.count == 384 && ls4.count == 384 * 4 && most > 0 && most <= MoreGen2Renderer.fireworkSegBudget && same,
              "リサージュ・花火：線分の数が決まりどおり（リサージュ \(ls1.count)・\(ls4.count)、花火いちばん多くて \(most)）、花火は時刻だけで決まる")

        // 花火：6 発/秒・しだれ（いちばん重なる）でも、どの発も寿命の終わり（ほぼ消えるまで）出続け、線分は上限以内
        do {
            var fw6 = Effect(kind: .fireworks)
            fw6.values[0] = 6; fw6.values[2] = 120; fw6.values[4] = 1; fw6.values[9] = 2
            let rate: Float = 6, life: Float = 3.6
            var cut: [String] = [], top = 0
            for i in 0..<120 {
                let t = 20 + Float(i) * 0.05
                let segs = MoreGen2Renderer.fireworkSegs(fw6, v: { Float(fw6.value($0)) }, t: t, size: SIMD2(1920, 1080))
                top = max(top, segs.count)
                let ids = Set(segs.map { Int($0.info.z) })
                for k in 0...Int(t * rate) {
                    let tk = (Float(k) + 0.7 * MoreGen2Renderer.hash(k, 1)) / rate
                    let rise: Float = 0.8 + 0.4 * MoreGen2Renderer.hash(k, 5)
                    // 開いてから寿命の 9 割（明るさ 1 割以下）までは、出ていないといけない
                    if t >= tk && t - tk - rise < life * 0.9 && !ids.contains(k) { cut.append("\(k)@\(t)") }
                }
            }
            check(cut.isEmpty && top <= MoreGen2Renderer.fireworkSegBudget,
                  "花火：6 発/秒・しだれでも途中で消える発が無く（\(cut.prefix(3).joined(separator: "・"))）、線分は上限以内（いちばん多くて \(top)・上限 \(MoreGen2Renderer.fireworkSegBudget)）")
        }
    }
}
