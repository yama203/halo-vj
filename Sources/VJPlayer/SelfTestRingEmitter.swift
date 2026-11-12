import Foundation
import Metal
import simd

extension SelfTest {
    /// ジェネレーター「輪から湧く粒」
    static func testRingEmitter(check: (Bool, String) -> Void) {
        let k = EffectKind.ringEmitter
        // 定義がそろう・保存して読める
        do {
            var e = Effect(kind: k)
            e.values[7] = 0.25; e.values[19] = 2
            let back = (try? JSONEncoder().encode(e)).flatMap { try? JSONDecoder().decode(Effect.self, from: $0) }
            var bad: [String] = []
            if !k.isGenerator || !EffectKind.generators.contains(k) || !EffectKind.moreGenerators.contains(k) || !k.isStateful
                || k.generatorCategory != .space || k.moreLabel == nil || k.moreHelp == nil || k.moreIcon == nil
                || e.values.count != k.params.count || k.params.count != 21 || !e.hasQuality || KindPreview.isLive(k) || !k.hasDice {
                bad.append("定義")
            }
            for p in k.params where p.animatable && p.animRange == nil { bad.append(p.label) }
            if back?.kind != k || back?.values != e.values { bad.append("保存") }
            // 粒の数・明るさ・中心はサイコロで変えない
            if k.diceable(0) || k.diceable(17) || k.diceable(3) || k.diceable(4) || !k.diceable(8) { bad.append("サイコロ") }
            if Effect(kind: k).color != RGB(r: 1.0, g: 0.88, b: 0.94) { bad.append("色") }
            check(bad.isEmpty, "輪から湧く粒：名前・印・値・説明・分類・画質がそろい、保存で戻る（数・明るさ・中心はサイコロの外）"
                  + (bad.isEmpty ? "" : "（だめ：\(bad.joined(separator: "、"))）"))
        }

        let ctx = MetalContext.shared
        func blank(_ w: Int, _ h: Int) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.shaderRead]
            return ctx.device.makeTexture(descriptor: td)!
        }
        let W = 640, H = 360
        let src = blank(W, H)
        /// 0 秒から 1/60 秒ずつ secs 秒まで進めて、最後の絵（と GPU の時間）を返す
        func run(_ fxp: EffectProcessor, _ e: Effect, from t0: Double = 0, secs: Double, key: String = "re") -> [UInt8] {
            var out = src
            for f in 0..<max(Int(secs * 60), 1) {
                let cb = ctx.queue.makeCommandBuffer()!
                out = fxp.apply(EffectStack(effects: [e]), to: src, key: key, cb: cb, now: t0 + Double(f) / 60)
                cb.commit(); cb.waitUntilCompleted()
            }
            var q = [UInt8](repeating: 0, count: W * H * 4)
            out.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            return q
        }
        func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var s = 0
            for i in stride(from: 0, to: a.count, by: 4) { s += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) }
            return Double(s) / Double(W * H * 3)
        }

        // 何コマか進めると絵が出る・真っ白でない・透明な所がある・円の外に粒が出ている・真ん中は暗い（外へ）
        do {
            let e = Effect(kind: k)
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            let a = run(fxp, e, secs: 3)
            let R = e.values[1] * Double(H), cx = Double(W) / 2, cy = Double(H) / 2
            var lit = 0, white = 0, transparent = 0, outside = 0, inner = 0, innerN = 0, onRing = 0
            for y in 0..<H { for x in 0..<W {
                let i = (y * W + x) * 4
                let s = Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])
                let d = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)
                if s > 30 { lit += 1 }
                if s > 735 { white += 1 }
                if a[i + 3] < 8 { transparent += 1 }
                if d > R * 1.1 && s > 90 { outside += 1 }
                if abs(d - R) < R * 0.04 && s > 90 { onRing += 1 }
                if d < R * 0.5 { innerN += 1; if s > 90 { inner += 1 } }
            } }
            let n = W * H
            let ring = Double(onRing) / (2 * .pi * R * R * 0.08)
            let ps: [SIMD2<Float>] = (fxp.life.peek("re/" + e.id.uuidString) as RingEmitterSim?)?.positions(Int(e.values[0])) ?? []
            let far = ps.filter { simd_length($0 - SIMD2(Float(W) / Float(H) / 2, 0.5)) > Float(e.values[1] * 1.1) }.count
            check(lit > n / 100 && white < n / 4 && transparent > n / 3 && outside > n / 500 && Double(inner) < Double(innerN) * 0.01
                  && ring > 0.3 && Double(far) > Double(ps.count) * 0.05,
                  String(format: "輪から湧く粒：絵が出て（%d 画素）・縁が明るく（縁の %.0f%% が光る）・円の外へ流れ出し（%d 画素・粒の %.0f%%）・真ん中は暗い（%d 画素）・まわりは透明",
                         lit, ring * 100, outside, Double(far) / Double(max(ps.count, 1)) * 100, inner))

            // 時間で動く。速さ 0 なら絵が変わらない
            let b = run(fxp, e, from: 3, secs: 1)
            var still = e; still.values[20] = 0
            let fs = EffectProcessor(); fs.storageMode = .shared
            _ = run(fs, still, secs: 0.5)
            let s1 = run(fs, still, from: 0.5, secs: 0.2), s2 = run(fs, still, from: 0.7, secs: 0.5)
            check(diff(a, b) > 0.5 && diff(s1, s2) == 0,
                  String(format: "輪から湧く粒：時間で動き（差 %.2f）、速さ 0 なら止まる（差 %.3f）", diff(a, b), diff(s1, s2)))

            // 出る向き「内へ」なら真ん中へも流れ込む、出る範囲を狭めると、その向きの縁だけになる
            var inward = e; inward.values[5] = 1; inward.values[8] = 0.6
            let ci = run({ let p = EffectProcessor(); p.storageMode = .shared; return p }(), inward, secs: 3)
            var narrow = e; narrow.values[13] = 60; narrow.values[7] = 1
            let cn = run({ let p = EffectProcessor(); p.storageMode = .shared; return p }(), narrow, secs: 3)
            var innerIn = 0, top = 0, bottom = 0
            for y in 0..<H { for x in 0..<W {
                let i = (y * W + x) * 4
                let d = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)
                if d < R * 0.7 && Int(ci[i]) + Int(ci[i + 1]) + Int(ci[i + 2]) > 90 { innerIn += 1 }
                let sn = Int(cn[i]) + Int(cn[i + 1]) + Int(cn[i + 2])
                if sn > 90 && abs(d - R) < R * 0.08 { if Double(y) < cy - R * 0.7 { top += 1 } else if Double(y) > cy + R * 0.7 { bottom += 1 } }
            } }
            check(innerIn > inner + 50 && top > 100 && bottom * 20 < top,
                  "輪から湧く粒：「内へ」で円の中へ流れ込み（\(innerIn) 画素）、出る範囲 60° は上の縁だけ（上 \(top)・下 \(bottom)）")
        }

        // 粒の数を最大にしても落ちない・ノイズの時刻が折り返しても崩れない
        do {
            var e = Effect(kind: k); e.values[0] = 120_000; e.values[10] = 2
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            _ = run(fxp, e, secs: 0.2)
            let sim: RingEmitterSim? = fxp.life.peek("re/" + e.id.uuidString)
            sim?.noiseTime = 63.95
            let a = run(fxp, e, from: 0.2, secs: 0.5)
            var lit = 0
            for i in stride(from: 0, to: a.count, by: 4) where Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2]) > 30 { lit += 1 }
            let ps = sim?.positions(RingEmitterSim.maxCount) ?? []
            let finite = ps.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            check(sim != nil && ps.count == 120_000 && finite && lit > W * H / 50 && (sim?.noiseTime ?? 99) < 64,
                  "輪から湧く粒：12 万粒でも描け、ノイズの時刻は 64 で折り返して（\(String(format: "%.2f", sim?.noiseTime ?? -1))）崩れない")
        }

        // 重さ：1920×1080（初期値 4 万粒で 1.5 ms 以内・12 万粒で 4 ms 以内）
        do {
            let big = blank(1920, 1080)
            func ms(_ n: Double) -> Double {
                var e = Effect(kind: k); e.values[0] = n
                let fxp = EffectProcessor(); fxp.storageMode = .shared
                var best = Double.infinity
                for f in 0..<40 {
                    let cb = ctx.queue.makeCommandBuffer()!
                    _ = fxp.apply(EffectStack(effects: [e]), to: big, key: "rp", cb: cb, now: 5 + Double(f) / 60)
                    cb.commit(); cb.waitUntilCompleted()
                    if f >= 4 { best = min(best, (cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                }
                return best
            }
            let a = ms(40_000), b = ms(120_000)
            check(a < 1.5 && b < 4, String(format: "輪から湧く粒：1920×1080 の重さ（4 万粒 %.2f ms・12 万粒 %.2f ms）", a, b))
        }
    }
}
