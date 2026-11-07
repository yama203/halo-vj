import Metal
import QuartzCore
import simd

// 下の絵を読む重ね方：差分・オーバーレイ・ソフトライト・覆い焼き・色相だけ・明るさだけ（値なし）と、
// 絡み合う重ね方：屈折・光で照らす・流し込む・干渉・色を借りる・溶け込む（値はレイヤーの blendFX）。
// どれも、ここまでに重ねた下の絵を写し取り、このレイヤーの絵（トランスフォームをかけて置いたもの）と混ぜて書き戻す。

private let blendShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VO { float4 pos [[position]]; float2 uv; };
vertex VO bl_full(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o;
    o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
    o.uv = c;
    return o;
}

// このレイヤーの絵を、出力の場所に置く（色に不透明度が掛かった絵のまま。scale は縮めた絵のとき）
struct PU { float3x3 inv; float scale; };
fragment float4 bl_place(VO in [[stage_in]], constant PU& u [[buffer(0)]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = in.pos.xy * u.scale;
    float2 uv = (u.inv * float3(px, 1.0)).xy;
    float2 e = min(uv, 1.0 - uv) / max(fwidth(uv), float2(1e-6));
    float cover = saturate(min(e.x, e.y) + 0.5);
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0.0);
    return tex.sample(s, uv) * cover;
}

static float blum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static float3 setLum(float3 c, float l) {
    float d = l - blum(c);
    c += d;
    float L = blum(c), n = min(c.r, min(c.g, c.b)), x = max(c.r, max(c.g, c.b));
    if (n < 0.0) c = L + (c - L) * L / max(L - n, 1e-5);
    if (x > 1.0) c = L + (c - L) * (1.0 - L) / max(x - L, 1e-5);
    return c;
}
static float sat(float3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }
static float3 setSat(float3 c, float s) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    if (mx - mn < 1e-5) return float3(0.0);
    return (c - mn) * s / (mx - mn);
}
static float3 bhue(float h) {
    float3 k = abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return saturate(k - 1.0);
}
static float bhash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float bnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(bhash(i), bhash(i + float2(1, 0)), w.x), mix(bhash(i + float2(0, 1)), bhash(i + float2(1, 1)), w.x), w.y);
}

// a, b = 値 / c = 時刻, 大きさの倍率（出力の高さ / 1080）, 重ね方の番号, 不透明度 / size = 出力の大きさ
struct BU { float4 a, b, c; float2 size; };

fragment float4 bl_mix(VO in [[stage_in]], constant BU& u [[buffer(0)]],
                       texture2d<float> below [[texture(0)]], texture2d<float> layer [[texture(1)]],
                       texture2d<float> extra [[texture(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 px = in.pos.xy;
    float3 B = below.sample(s, uv).rgb;
    float4 L = layer.sample(s, uv);
    float a = saturate(L.a);
    float3 Lu = a > 1e-4 ? saturate(L.rgb / a) : float3(0.0);
    float op = saturate(u.c.w);
    int mode = int(u.c.z + 0.5);
    float k = u.c.y;
    float3 r = B;
    if (mode <= 12) {
        // 値の無い重ね方：色を混ぜてから、このレイヤーの不透明度で下の絵と混ぜる
        float3 f = B;
        if (mode == 7) f = abs(B - Lu);
        else if (mode == 8) f = select(1.0 - 2.0 * (1.0 - B) * (1.0 - Lu), 2.0 * B * Lu, B < 0.5);
        else if (mode == 9) f = (1.0 - 2.0 * Lu) * B * B + 2.0 * Lu * B;
        else if (mode == 10) f = min(B / max(1.0 - Lu, 1e-3), 1.0);
        else if (mode == 11) f = setLum(setSat(Lu, sat(B)), blum(B));
        else if (mode == 12) f = setLum(B, blum(Lu));
        return float4(mix(B, f, a * op), 1.0);
    }
    if (mode == 13) {
        // 屈折：このレイヤーの明るさを高さにして、坂の向きに下の絵をずらす
        float rr = (2.0 + u.a.y * 26.0) * k;
        float2 dx = float2(rr, 0) / u.size, dy = float2(0, rr) / u.size;
        float2 g = float2(blum(layer.sample(s, uv + dx).rgb) - blum(layer.sample(s, uv - dx).rgb),
                          blum(layer.sample(s, uv + dy).rgb) - blum(layer.sample(s, uv - dy).rgb)) * 0.5;
        g += float2(blum(layer.sample(s, uv + 2.0 * dx).rgb) - blum(layer.sample(s, uv - 2.0 * dx).rgb),
                    blum(layer.sample(s, uv + 2.0 * dy).rgb) - blum(layer.sample(s, uv - 2.0 * dy).rgb)) * 0.25;
        float2 off = -g * u.a.x * k * op / u.size * 4.0;
        float ca = u.a.z;
        float3 R = float3(below.sample(s, uv + off * (1.0 + ca * 0.6)).r, below.sample(s, uv + off).g,
                          below.sample(s, uv + off * (1.0 - ca * 0.6)).b);
        float gl = length(g);
        float rim = u.a.w * saturate(gl * 6.0) * saturate(dot(g / max(gl, 1e-5), float2(0.6, 0.8)) * 0.5 + 0.5);
        r = R + rim * op;
        float show = u.b.x;
        r = r * (1.0 - a * show) + L.rgb * show;
        return float4(mix(B, r, op), 1.0);
    }
    if (mode == 14) {
        // 光で照らす：extra = ぼかした光（このレイヤー）
        float3 glow = extra.sample(s, uv).rgb;
        float3 light = (glow * 5.0 + L.rgb * 0.6) * u.a.z;
        float l = blum(light);
        float3 tint = mix(float3(l), light, u.a.w);
        r = B * ((1.0 - u.a.x) + tint) + L.rgb * u.b.x;
        return float4(mix(B, r, op), 1.0);
    }
    if (mode == 15) {
        // 流し込む：extra = かき混ぜた下の絵
        r = extra.sample(s, uv).rgb;
        float show = u.b.y;
        r = r * (1.0 - a * show) + L.rgb * show;
        return float4(mix(B, r, op), 1.0);
    }
    if (mode == 16) {
        // 干渉：2 つの明るさを波にして重ねる（細かすぎる所は平らに）
        float ph = (blum(B) - blum(L.rgb)) * u.a.x + u.c.x * u.a.y;
        float w = 0.5 + 0.5 * cos(6.2831853 * ph);
        float sh = 0.5 * (1.0 - u.a.w);
        w = smoothstep(0.5 - sh - 0.001, 0.5 + sh + 0.001, w);
        w = mix(w, 0.5, saturate(fwidth(ph) * 1.5 - 0.3));
        int cm = int(u.b.x + 0.5);
        float3 col = cm == 0 ? B : (cm == 1 ? mix(B, Lu, a) : bhue(fract(ph * 0.1 + blum(B) * 0.3)) * max(blum(B), 0.35) * 1.4);
        r = col * mix(1.0, w * (cm == 2 ? 1.0 : 1.6), u.a.z);
        return float4(mix(B, saturate(r), op), 1.0);
    }
    if (mode == 17) {
        // 色を借りる：下の明るさ（形）に、このレイヤーの色を塗る
        float lb = saturate((blum(B) - 0.5) * u.a.y + 0.5);
        float4 C;
        if (int(u.a.x + 0.5) == 1) {
            C = layer.sample(s, float2(fract(lb * 0.98 + 0.01 + u.a.z), u.a.w));
            float ca = saturate(C.a);
            float3 cu = ca > 1e-4 ? C.rgb / ca : float3(0.0);
            r = mix(B, cu, ca);
        } else {
            C = layer.sample(s, uv + float2(lb * u.a.z, 0.0));
            float ca = saturate(C.a);
            float3 cu = ca > 1e-4 ? C.rgb / ca : float3(0.0);
            r = mix(B, cu * lb * 1.4, ca);
        }
        r = mix(r, B, u.b.x);
        return float4(mix(B, saturate(r), op), 1.0);
    }
    // 溶け込む：下の明るさ（など）の低い所から順に、このレイヤーへ溶ける。境目は光る
    int dm = int(u.a.y + 0.5);
    float2 q = uv * float2(u.size.x / u.size.y, 1.0) * 3.0 + u.c.x * 0.05;
    float nz = bnoise(q) * 0.65 + bnoise(q * 2.3 + 4.1) * 0.35;
    float m = dm == 0 ? blum(B) : (dm == 1 ? 1.0 - blum(B) : (dm == 2 ? nz : 1.0 - blum(L.rgb)));
    m = mix(m, nz, u.b.y * (dm == 2 ? 0.0 : 0.6));
    float soft = max(u.a.z, 0.002);
    float t = u.a.x * (1.0 + 2.0 * soft) - soft;
    float kk = 1.0 - smoothstep(t - soft, t + soft, m);
    float3 over = L.rgb + B * (1.0 - a);
    r = mix(B, over, kk);
    float edge = exp(-pow((m - t) / (soft * 1.5 + 0.01), 2.0));
    if (u.a.x > 0.001 && u.a.x < 0.999) r += edge * u.a.w * mix(bhue(u.b.x / 360.0), float3(1.0), 0.25);
    return float4(mix(B, saturate(r), op), 1.0);
}
"""

private struct PlaceUniforms {
    var inv: simd_float3x3
    var scale: Float
}

private struct BlendUniforms {
    var a: SIMD4<Float>, b: SIMD4<Float>, c: SIMD4<Float>
    var size: SIMD2<Float>
}

final class BlendRenderer {
    static let shared = BlendRenderer()
    let place8, place16, mix: MTLRenderPipelineState

    private init() {
        let dev = MetalContext.shared.device
        let lib: MTLLibrary
        do { lib = try dev.makeLibrary(source: blendShaderSource, options: nil) } catch {
            fatalError("重ね方のシェーダーを作れません: \(error)")
        }
        func r(_ f: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "bl_full")
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = fmt
            return try! dev.makeRenderPipelineState(descriptor: d)
        }
        place8 = r("bl_place", .bgra8Unorm)
        place16 = r("bl_place", .rgba16Float)
        mix = r("bl_mix", .bgra8Unorm)
    }
}

/// 合成ごとに 1 つ（作業用の絵と、流し込むの流れを持つ）
final class SpecialBlender {
    private let ctx = MetalContext.shared
    private var below: MTLTexture?
    private var placed: MTLTexture?
    private var flowOut: MTLTexture?
    private var low: [MTLTexture] = []
    private var fluids: [Int: (sim: FluidSim, last: Double)] = [:]

    private func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        return ctx.device.makeTexture(descriptor: td)
    }

    private func pass(_ dst: MTLTexture, _ pipe: MTLRenderPipelineState, cb: MTLCommandBuffer,
                      _ setup: (MTLRenderCommandEncoder) -> Void) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        e.setRenderPipelineState(pipe)
        e.setFragmentSamplerState(ctx.sampler, index: 0)
        setup(e)
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        e.endEncoding()
    }

    func blend(_ g: LayerGroup, layer: MTLTexture, matrix: simd_float3x3, opacity: Float, target: MTLTexture,
               cb: MTLCommandBuffer, now: Double) {
        let r = BlendRenderer.shared
        let w = target.width, h = target.height
        if below?.width != w || below?.height != h {
            below = tex(w, h); placed = tex(w, h); flowOut = tex(w, h)
        }
        guard let below, let placed, let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: target, to: below)
        blit.endEncoding()
        // このレイヤーを出力の場所に置く
        var pu = PlaceUniforms(inv: matrix.inverse, scale: 1)
        pass(placed, r.place8, cb: cb) { e in
            e.setFragmentBytes(&pu, length: MemoryLayout<PlaceUniforms>.stride, index: 0)
            e.setFragmentTexture(layer, index: 0)
        }
        let fx = g.blendFX.effects.first.flatMap { $0.kind == g.blend.effectKind ? $0 : nil }
            ?? g.blend.effectKind.map { Effect(kind: $0) }
        func v(_ i: Int) -> Float {
            guard let fx, i < fx.kind.params.count else { return 0 }
            return Float(fx.value(i, at: now, beat: g.blendFX.beat, origin: g.blendFX.origin))
        }
        let k = Float(h) / 1080
        var u = BlendUniforms(a: SIMD4(v(0), v(1), v(2), v(3)), b: SIMD4(v(4), v(5), 0, 0),
                              c: SIMD4(Float(now.truncatingRemainder(dividingBy: 1000)), k, Float(g.blend.rawValue), opacity),
                              size: SIMD2(Float(w), Float(h)))
        var extra: MTLTexture = ctx.dummyTexture
        switch g.blend {
        case .light:
            // 光：1/4 の大きさに縮めて、光の広がりだけぼかす
            let lw = max(w / 4, 1), lh = max(h / 4, 1)
            if low.count != 2 || low[0].width != lw || low[0].height != lh {
                low = (0..<2).compactMap { _ in tex(lw, lh, .rgba16Float) }
            }
            guard low.count == 2 else { break }
            var lp = PlaceUniforms(inv: matrix.inverse, scale: 4)
            pass(low[0], r.place16, cb: cb) { e in
                e.setFragmentBytes(&lp, length: MemoryLayout<PlaceUniforms>.stride, index: 0)
                e.setFragmentTexture(layer, index: 0)
            }
            let radius = v(1) * k / 4
            for _ in 0..<2 {
                for (src, dst, dir) in [(low[0], low[1], SIMD2<Float>(1, 0)), (low[1], low[0], SIMD2<Float>(0, 1))] {
                    var bu = BlurUniforms(dir: dir, radius: radius * 0.7)
                    pass(dst, ctx.blurPipeline, cb: cb) { e in
                        e.setFragmentBytes(&bu, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                        e.setFragmentTexture(src, index: 0)
                    }
                }
            }
            extra = low[0]
        case .flowInto:
            // 流し込む：このレイヤーの動き（明るさ）で流れを押し、下の絵を絵の具にして流す
            guard let flowOut else { break }
            let key = g.key
            var entry = fluids[key] ?? (FluidSim(), -1)
            var dt = entry.last < 0 ? 0 : now - entry.last
            if dt < 0 || dt > 0.5 { dt = 0 }
            entry.last = now
            fluids[key] = entry
            entry.sim.run(source: below, force: placed, into: flowOut, dt: dt,
                          params: FluidSim.Params(push: Double(v(0)) * 6, inject: Double(v(2)) * 0.6 + 0.02, injectMode: 2,
                                                  dyeKeep: 1, vortex: Double(v(3)), wind: 0, viscosity: Double(v(4)),
                                                  keepOriginal: 1, grid: 1, pushMode: Int(v(1).rounded())),
                          mixAmt: 1, cb: cb)
            extra = flowOut
        default:
            break
        }
        pass(target, r.mix, cb: cb) { e in
            e.setFragmentBytes(&u, length: MemoryLayout<BlendUniforms>.stride, index: 0)
            e.setFragmentTexture(below, index: 0)
            e.setFragmentTexture(placed, index: 1)
            e.setFragmentTexture(extra, index: 2)
        }
    }
}
