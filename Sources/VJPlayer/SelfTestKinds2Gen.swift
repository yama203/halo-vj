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
    }
}
