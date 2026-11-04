import Metal
import AppKit
import QuartzCore
import CoreVideo
import simd

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    return o;
}

struct Uniforms {
    float3x3 hinv;     // 出力座標(0..1) -> 映像UV(0..1) への射影変換
    float2 viewSize;
    int mode;          // 0: 黒, 1: 映像, 2: テストパターン
    float master;      // マスター不透明度
};

static float4 testPattern(float2 uv, float2 px) {
    float2 g = uv * float2(16.0, 9.0);
    float2 fw = fwidth(g) * 1.2;
    float2 f = fract(g);
    float grid = max(step(f.x, fw.x) + step(1.0 - fw.x, f.x), step(f.y, fw.y) + step(1.0 - fw.y, f.y));
    float2 e = min(uv, 1.0 - uv) / fwidth(uv);
    float border = step(min(e.x, e.y), 4.0);
    float diag = step(abs(uv.x - uv.y) / fwidth(uv.x - uv.y), 1.0) + step(abs(uv.x + uv.y - 1.0) / fwidth(uv.x + uv.y), 1.0);
    float3 c = float3(0.12);
    c = mix(c, float3(0.8), saturate(grid));
    c = mix(c, float3(0.2, 0.7, 1.0), saturate(diag));
    c = mix(c, float3(1.0, 0.2, 0.2), border);
    return float4(c, 1.0);
}

fragment float4 fmain(VOut in [[stage_in]],
                      constant Uniforms& u [[buffer(0)]],
                      texture2d<float> tex [[texture(0)]],
                      sampler s [[sampler(0)]]) {
    float2 q = in.pos.xy / u.viewSize;
    float3 h = u.hinv * float3(q, 1.0);
    if (h.z <= 0.0) return float4(0, 0, 0, 1);
    float2 uv = h.xy / h.z;
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);
    if (u.mode == 2) return testPattern(uv, in.pos.xy);
    if (u.mode == 0) return float4(0, 0, 0, 1);
    return float4(tex.sample(s, uv).rgb * u.master, 1.0);
}

// レイヤー合成。重ね方そのものはパイプラインのブレンド設定で決まる（Compositor 参照）
struct LayerUniforms {
    float3x3 inv;      // 出力のピクセル → クリップの UV（クリップ・レイヤー・コンポジションのトランスフォームを合成した逆行列）
    float opacity;
    int blend;         // 0: 通常, 1: 加算, 2: スクリーン, 3: 乗算
    int premul;        // 1: 色に不透明度が掛かった絵（レイヤーのエフェクトを通した絵）
};

fragment float4 flayer(VOut in [[stage_in]],
                       constant LayerUniforms& u [[buffer(0)]],
                       texture2d<float> tex [[texture(0)]],
                       sampler s [[sampler(0)]]) {
    float2 uv = (u.inv * float3(in.pos.xy, 1.0)).xy;
    // クリップの外は透明。縁は 1 ピクセルぶんぼかしてギザギザを抑える
    float2 e = min(uv, 1.0 - uv) / max(fwidth(uv), float2(1e-6));
    float cover = saturate(min(e.x, e.y) + 0.5);
    float4 c = tex.sample(s, saturate(uv));
    if (u.premul == 1) {
        float cov = saturate(u.opacity * cover);
        float k = c.a * cov;
        if (u.blend == 3) return float4(mix(float3(1.0), c.rgb / max(c.a, 1e-4), k), 1.0);
        return float4(c.rgb * cov, k);
    }
    float k = saturate(c.a * u.opacity * cover);
    if (u.blend == 3) return float4(mix(float3(1.0), c.rgb, k), 1.0);
    return float4(c.rgb * k, k);
}

// エフェクト（1 つずつ）。入出力は「色に不透明度が掛かった」絵
struct EffectUniforms {
    int kind;          // 0: ミラー, 1: カラーライズ, 2: レベル, 3: ポスタライズ
    float4 a;
    float4 b;
    float2 size;
    float4 color;      // カラーライズの色
    float4 pal[8];     // カラーライズのパレット（暗い → 明るい）
    int palCount;
};

constant float bayer4[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

static float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

static float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), saturate(p - 1.0), c.y);
}

static float3 hueShift(float3 c, float h) {
    float3 hsv = rgb2hsv(c);
    hsv.x = fract(hsv.x + h);
    return hsv2rgb(hsv);
}

static float3 pureHue(float h) {
    float3 k = abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return saturate(k - 1.0);
}

fragment float4 feffect(VOut in [[stage_in]],
                        constant EffectUniforms& u [[buffer(0)]],
                        texture2d<float> tex [[texture(0)]],
                        sampler s [[sampler(0)]]) {
    float2 px = in.pos.xy;
    float2 uv = px / u.size;
    if (u.kind == 0) {
        int h = int(u.a.x + 0.5), v = int(u.a.y + 0.5);
        if (h == 1 && uv.x > 0.5) uv.x = 1.0 - uv.x;
        if (h == 2 && uv.x < 0.5) uv.x = 1.0 - uv.x;
        if (v == 1 && uv.y > 0.5) uv.y = 1.0 - uv.y;
        if (v == 2 && uv.y < 0.5) uv.y = 1.0 - uv.y;
        return tex.sample(s, uv);
    }
    float2 cellPx = px;
    if (u.kind == 3 && u.a.z > 1.5) {
        // ドット：大きな四角ごとに同じ色にする
        float d = u.a.z;
        cellPx = floor(px / d);
        uv = (cellPx * d + d * 0.5) / u.size;
    }
    float4 c = tex.sample(s, uv);
    float alpha = c.a;
    float3 rgb = alpha > 1e-4 ? c.rgb / alpha : float3(0.0);
    if (u.kind == 1) {
        float L = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float3 tint;
        if (int(u.a.x + 0.5) == 1) {
            // パレット：暗い所は左の色、明るい所は右の色。あいだはなめらかにつなぐ
            int n = max(u.palCount, 1);
            float x = saturate(L) * float(n - 1);
            int i = min(int(floor(x)), n - 2);
            tint = n == 1 ? u.pal[0].rgb : mix(u.pal[max(i, 0)].rgb, u.pal[max(i, 0) + 1].rgb, x - float(max(i, 0)));
        } else if (u.a.y > 0.5) {
            // カラー・明るさを保つ：色相と彩度だけその色にして、明るさは元のまま
            float cmax = max(u.color.r, max(u.color.g, u.color.b));
            float cmin = min(u.color.r, min(u.color.g, u.color.b));
            float cl = (cmax + cmin) * 0.5;
            float sat = cmax - cmin < 1e-4 ? 0.0 : (cmax - cmin) / (1.0 - abs(2.0 * cl - 1.0));
            float3 hue = cmax - cmin < 1e-4 ? float3(0.5) : (u.color.rgb - cmin) / (cmax - cmin);
            float C = (1.0 - abs(2.0 * L - 1.0)) * saturate(sat);
            tint = saturate(L + C * (hue - 0.5));
        } else {
            // カラー・明るさを保たない：黒は黒、灰色はその色を暗くしたもの、白はその色そのもの
            tint = u.color.rgb * L;
        }
        // 色相をずらす（動かすと色が回る）
        if (u.a.w > 0.001) tint = hueShift(tint, u.a.w / 360.0);
        rgb = mix(rgb, tint, u.a.z);
    } else if (u.kind == 2) {
        float3 v = saturate((rgb - u.a.x) / max(u.a.y - u.a.x, 1e-4));
        v = pow(v, float3(1.0 / max(u.a.z, 0.01)));
        rgb = mix(float3(u.a.w), float3(u.b.x), v);
    } else if (u.kind == 3) {
        float n = max(u.a.x, 2.0) - 1.0;
        int2 q = int2(cellPx) & 3;
        float t = bayer4[q.x + q.y * 4] / 16.0 - 0.5 + 1.0 / 32.0;
        rgb = saturate(floor(rgb * n + 0.5 + u.a.y * t) / n);
    }
    return float4(rgb * alpha, alpha);
}

// ---- 特殊合成：オーバードライブ加算 ----
// 下の絵 + このレイヤー で 100% を超えた分（あふれ）を、にじみ・色相ずれ・歪みに変える
struct ODUniforms {
    float3x3 inv;      // 出力のピクセル → このレイヤーの絵の UV
    float opacity;
    float4 a;          // にじみ, にじみの広がり(px), 色相ずれ(度), 波紋の強さ
    float4 b;          // 波紋の細かさ, 白飛びの抑え, 時刻, 縮小率（あふれの絵は 1/scale の大きさ）
    float4 c;          // 波紋の速さ, 波紋の広がり(px), 波紋の山の縮小率, 大きさの倍率（出力の高さ / 1080）
    float2 size;       // 出力の大きさ
};

static float4 odLayer(constant ODUniforms& u, texture2d<float> tex, sampler s, float2 px) {
    float2 uv = (u.inv * float3(px, 1.0)).xy;
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0.0);
    return tex.sample(s, uv) * u.opacity;   // 色に不透明度が掛かった絵
}

// あふれた分（縮小した絵に書く）
fragment float4 fodOver(VOut in [[stage_in]], constant ODUniforms& u [[buffer(0)]],
                        texture2d<float> below [[texture(0)]], texture2d<float> layer [[texture(1)]],
                        sampler s [[sampler(0)]]) {
    // 縮めた 1 ピクセルが受け持つ範囲（scale x scale）を平均する（小さく光る所を取りこぼさない）
    int n = max(int(u.b.w + 0.5), 1);
    float2 base = (in.pos.xy - 0.5) * u.b.w;
    float3 acc = float3(0.0);
    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            float2 px = base + float2(x, y) + 0.5;
            float3 sum = below.sample(s, px / u.size).rgb + odLayer(u, layer, s, px).rgb;
            acc += max(sum - 1.0, 0.0);
        }
    }
    return float4(acc / float(n * n), 1.0);
}

// ぼかし（縦か横の 1 方向。13 点）
struct BlurUniforms { float2 dir; float radius; };
fragment float4 fblur(VOut in [[stage_in]], constant BlurUniforms& u [[buffer(0)]],
                      texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 uv = in.pos.xy / size;
    float3 acc = float3(0.0); float wsum = 0.0;
    for (int i = -6; i <= 6; i++) {
        float t = float(i) / 6.0;
        float w = exp(-t * t * 2.0);
        acc += tex.sample(s, uv + u.dir * t * u.radius / size).rgb * w;
        wsum += w;
    }
    return float4(acc / wsum, 1.0);
}

static float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), w.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), w.x), w.y);
}

fragment float4 fodFinal(VOut in [[stage_in]], constant ODUniforms& u [[buffer(0)]],
                         texture2d<float> below [[texture(0)]], texture2d<float> layer [[texture(1)]],
                         texture2d<float> glow [[texture(2)]], texture2d<float> ripple [[texture(3)]],
                         sampler s [[sampler(0)]]) {
    float2 px = in.pos.xy;
    float2 uv = px / u.size;
    float3 g = glow.sample(s, uv).rgb;                      // ぼかしたあふれ
    float gl = max(g.r, max(g.g, g.b));
    // 波紋：あふれた所を山にして（大きくぼかした別の絵）、そこから外へ同心円の波が広がっていく。
    // 山の高さが同じ所を同じ位相にするので、明るい所を囲む輪になる。輪に沿って絵を押し出し、波の頂を光らせる
    float2 rsize = float2(ripple.get_width(), ripple.get_height());
    float2 tx = float2(1.0 / rsize.x, 0.0), ty = float2(0.0, 1.0 / rsize.y);
    float3 lw = float3(0.3333);
    float h = dot(ripple.sample(s, uv).rgb, lw);
    float2 grad = float2(dot(ripple.sample(s, uv + tx).rgb, lw) - dot(ripple.sample(s, uv - tx).rgb, lw),
                         dot(ripple.sample(s, uv + ty).rgb, lw) - dot(ripple.sample(s, uv - ty).rgb, lw));
    float gm = length(grad);
    float2 dir = gm > 1e-9 ? -grad / gm : float2(0.0);       // 明るい所から外向き
    // 山は光った所をぼかした形（ガウス）。その傾き÷高さ×σ² が、光った所からの距離になる（明るさに関係なく求まる）
    float spread = max(u.c.y, 1.0);
    float sigma = 0.5 * spread;
    float gradPx = gm / (2.0 * max(u.c.z, 1.0));             // 1 ピクセルあたりの傾き
    float dist = h > 1e-7 ? sigma * sigma * gradPx / h : 1e9;
    float wavelength = max(1600.0 / max(u.b.x, 1.0), 6.0) * u.c.w;   // 細かさ 24 で約 67px ごと（1080p）
    float phase = 6.2831853 * (dist / wavelength - u.b.z * u.c.x);   // 時間とともに外へ広がる
    float wave = sin(phase);
    float env = (1.0 - smoothstep(0.55 * spread, spread, dist)) * smoothstep(1e-7, 1e-5, h);
    float2 off = dir * wave * u.a.w * 14.0 * u.c.w * env;
    float3 sum = below.sample(s, (px + off) / u.size).rgb + odLayer(u, layer, s, px + off).rgb;
    float crest = pow(max(wave, 0.0), 10.0) * env * u.a.w;  // 波の頂の光（細い輪）
    // 色相ずれ：あふれた量だけ色を回す
    float over = max(max(sum.r, max(sum.g, sum.b)) - 1.0, 0.0);
    if (u.a.z > 0.001 && over > 0.0) {
        float v = max(sum.r, max(sum.g, sum.b));
        sum = hueShift(sum / v, over * u.a.z / 360.0) * v;
    }
    // 白飛びの抑え：1 の手前から寝かせる（0 なら切り捨て）
    float k = 1.0 - 0.35 * u.b.y;
    float3 soft = select(sum, k + (1.0 - k) * (1.0 - exp(-(sum - k) / max(1.0 - k, 1e-3))), sum > k);
    float3 col = soft;
    // にじみ（ハレーション）：あふれをぼかして足す。色相ずれと同じだけ色を回す
    float3 halo = g;
    if (u.a.z > 0.001 && gl > 0.0) halo = hueShift(g / gl, gl * u.a.z / 360.0) * gl;
    col += halo * u.a.x;
    float3 rc = dot(ripple.sample(s, uv).rgb, lw) > 0.0 ? ripple.sample(s, uv).rgb / max(h * 3.0, 1e-4) : float3(1.0);
    if (u.a.z > 0.001) rc = hueShift(saturate(rc), 0.5 * u.a.z / 360.0);
    col += crest * 0.8 * saturate(rc);
    return float4(saturate(col), 1.0);
}
"""

struct Uniforms {
    var hinv: simd_float3x3
    var viewSize: SIMD2<Float>
    var mode: Int32
    var master: Float = 1
}

struct LayerUniforms {
    var inv: simd_float3x3
    var opacity: Float
    var blend: Int32
    var premul: Int32 = 0
}

struct ODUniforms {
    var inv: simd_float3x3
    var opacity: Float
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>
    var size: SIMD2<Float>
}

struct BlurUniforms {
    var dir: SIMD2<Float>
    var radius: Float
}

struct EffectUniforms {
    var kind: Int32
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var size: SIMD2<Float>
    var color = SIMD4<Float>(1, 1, 1, 1)
    var pal: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
              SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var palCount: Int32 = 0
}

extension ClipTransform {
    /// 出力（w x h ピクセル）の中心を基準に、移動・回転・拡大する行列（ピクセル → ピクセル）
    func matrix(width w: Float, height h: Float) -> simd_float3x3 {
        let c = SIMD2(w / 2, h / 2)
        let to = c + SIMD2(x * w, -y * h)
        let co = cos(rotation), si = sin(rotation)
        let s = max(scale, 0.0001)
        // 列優先: T(to) * R * S * T(-c)
        let rs = simd_float3x3(columns: (SIMD3(co * s, si * s, 0), SIMD3(-si * s, co * s, 0), SIMD3(0, 0, 1)))
        let t1 = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(to.x, to.y, 1)))
        let t0 = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-c.x, -c.y, 1)))
        return t1 * rs * t0
    }
}

/// 合成する1レイヤーぶん
struct LayerDraw {
    let texture: MTLTexture
    /// レイヤーの不透明度（クリップの不透明度は transform 側）
    let opacity: Float
    let blend: BlendMode
    var transform = ClipTransform()
    /// レイヤー・コンポジションのトランスフォーム（不透明度は使わない）
    var layerTransform = ClipTransform()
    var compTransform = ClipTransform()
    /// GPU が使い終わるまで保持しておく映像フレーム
    let holder: FrameHolder?
    /// クリップのエフェクト（トランスフォームの前にかける）
    var effects = EffectStack()
    /// エフェクト用の作業テクスチャを使い分ける番号
    var effectKey = 0
}

/// 1 レイヤーぶんの描画（クロスフェード中はクリップ 2 つ）
struct LayerGroup {
    /// 奥 → 手前。opacity はクロスフェードの割合だけ（レイヤーの不透明度は下の opacity）
    var draws: [LayerDraw]
    var opacity: Float
    var blend: BlendMode
    var effects = EffectStack()
    /// 作業テクスチャ・コマ間引きの使い回しに使う番号（レイヤー）
    var key = 0
    /// 調整レイヤー：draws は空で、ここまでに重ねた絵全体に effects をかけ、opacity の割合で混ぜる
    var isAdjustment = false
    /// 特殊合成（オーバードライブ加算など）の値。blend が特殊合成のときに使う
    var blendFX = EffectStack()
}

final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let layerPipelines: [BlendMode: MTLRenderPipelineState]
    /// レイヤーのエフェクト用に、クリップを透明な下地に重ねる（不透明度も書く）
    let accumPipeline: MTLRenderPipelineState
    let effectPipeline: MTLRenderPipelineState
    /// オーバードライブ加算：あふれ・ぼかし・仕上げ
    let odOverPipeline: MTLRenderPipelineState
    let blurPipeline: MTLRenderPipelineState
    let odFinalPipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let textureCache: CVMetalTextureCache
    let dummyTexture: MTLTexture

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal が使えません")
        }
        self.device = device
        self.queue = queue

        let library = try! device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vmain")
        desc.fragmentFunction = library.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        var lp: [BlendMode: MTLRenderPipelineState] = [:]
        for mode in BlendMode.allCases {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vmain")
            d.fragmentFunction = library.makeFunction(name: "flayer")
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.writeMask = [.red, .green, .blue]
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceAlphaBlendFactor = .zero
            ca.destinationAlphaBlendFactor = .one
            // シェーダーは「色 × 不透明度」を出す（乗算だけは mix(1, 色, 不透明度)）
            switch mode {
            case .normal:   // 下 × (1 - a) + 上
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            case .add, .overdrive:      // 下 + 上（オーバードライブは別のシェーダーで混ぜる。これは使わない）
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .one
            case .screen:   // 下 + 上 × (1 - 下)
                ca.sourceRGBBlendFactor = .oneMinusDestinationColor
                ca.destinationRGBBlendFactor = .one
            case .multiply: // 下 × 上
                ca.sourceRGBBlendFactor = .zero
                ca.destinationRGBBlendFactor = .sourceColor
            }
            lp[mode] = try! device.makeRenderPipelineState(descriptor: d)
        }
        layerPipelines = lp

        let ad = MTLRenderPipelineDescriptor()
        ad.vertexFunction = library.makeFunction(name: "vmain")
        ad.fragmentFunction = library.makeFunction(name: "flayer")
        let ac = ad.colorAttachments[0]!
        ac.pixelFormat = .bgra8Unorm
        ac.isBlendingEnabled = true
        ac.rgbBlendOperation = .add
        ac.alphaBlendOperation = .add
        ac.sourceRGBBlendFactor = .one
        ac.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ac.sourceAlphaBlendFactor = .one
        ac.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        accumPipeline = try! device.makeRenderPipelineState(descriptor: ad)

        let ed = MTLRenderPipelineDescriptor()
        ed.vertexFunction = library.makeFunction(name: "vmain")
        ed.fragmentFunction = library.makeFunction(name: "feffect")
        ed.colorAttachments[0].pixelFormat = .bgra8Unorm
        effectPipeline = try! device.makeRenderPipelineState(descriptor: ed)

        func plain(_ f: String, _ fmt: MTLPixelFormat = .bgra8Unorm) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vmain")
            d.fragmentFunction = library.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = fmt
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        // あふれ・ぼかしは細かい値の差（波紋の山の傾き）を使うので 16bit の小数で持つ
        odOverPipeline = plain("fodOver", .rgba16Float)
        blurPipeline = plain("fblur", .rgba16Float)
        odFinalPipeline = plain("fodFinal")

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache!

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dummyTexture = device.makeTexture(descriptor: td)!
    }
}

/// エフェクトを順にかける。作業テクスチャは「番号」ごとに 2 枚持って使い回す（描画スレッドだけが使う）
final class EffectProcessor {
    private let ctx = MetalContext.shared
    private var pools: [String: [MTLTexture]] = [:]
    var storageMode: MTLStorageMode = .private

    private func textures(_ key: String, width w: Int, height h: Int) -> [MTLTexture] {
        if let p = pools[key], p[0].width == w, p[0].height == h { return p }
        let p = (0..<2).compactMap { _ -> MTLTexture? in
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = storageMode
            return ctx.device.makeTexture(descriptor: td)
        }
        pools[key] = p
        return p
    }

    /// input にエフェクトを上から順にかけた結果（エフェクトが無ければ input のまま）
    func apply(_ stack: EffectStack, to input: MTLTexture, key: String, cb: MTLCommandBuffer,
               now: Double = CACurrentMediaTime()) -> MTLTexture {
        let effects = stack.spatial
        guard !effects.isEmpty else { return input }
        let pool = textures(key, width: input.width, height: input.height)
        guard pool.count == 2 else { return input }
        var src = input
        for (i, e) in effects.enumerated() {
            let dst = pool[i % 2]
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return src }
            var (va, vb) = e.shaderValues(at: now, beat: stack.beat, origin: stack.origin)
            // ドットの大きさ（px）は 1080p での大きさ。絵の大きさに比例させて、プレビューと出力で同じ見え方に
            if e.kind == .posterize { va.z = max(va.z * Float(input.height) / 1080, 1) }
            var u = EffectUniforms(kind: e.kind.shaderIndex, a: va, b: vb,
                                   size: SIMD2(Float(input.width), Float(input.height)))
            u.color = e.color.simd
            let p = (e.palette.isEmpty ? [RGB.black, RGB.white] : Array(e.palette.prefix(Effect.maxPalette))).map(\.simd)
            func at(_ i: Int) -> SIMD4<Float> { i < p.count ? p[i] : p[p.count - 1] }
            u.pal = (at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7))
            u.palCount = Int32(p.count)
            enc.setRenderPipelineState(ctx.effectPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentSamplerState(ctx.sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            src = dst
        }
        return src
    }
}

/// レイヤーを重ねて1枚の画像にする（コーナーピンをかける前の画）。
/// クリップ → レイヤー → コンポジションの順にエフェクトをかける
final class Compositor {
    private let ctx = MetalContext.shared
    private(set) var target: MTLTexture?
    /// セルフテストで中身を読むときは .shared にする
    var storageMode: MTLStorageMode = .private {
        didSet { fx.storageMode = storageMode }
    }
    private let fx = EffectProcessor()
    /// レイヤーのエフェクト用：クリップを重ねる下地（レイヤーごと）
    private var groupTargets: [Int: MTLTexture] = [:]
    /// ポスタライズ時間：前のコマの絵（レイヤーごと・コンポジション）
    private var groupCache: [Int: (tick: Int64, texture: MTLTexture, comp: ClipTransform)] = [:]
    private var compCache: (tick: Int64, texture: MTLTexture)?

    /// 1 枚ずつ重ねる（エフェクトなし。テスト用）。layers は奥 → 手前の順
    func composite(_ layers: [LayerDraw], width: Int, height: Int, cb: MTLCommandBuffer) -> MTLTexture? {
        composite(layers.map { LayerGroup(draws: [$0], opacity: 1, blend: $0.blend, key: -1) },
                  effects: EffectStack(), width: width, height: height, cb: cb)
    }

    /// groups は奥 → 手前の順。effects はコンポジションのエフェクト
    func composite(_ groups: [LayerGroup], effects: EffectStack, width: Int, height: Int,
                   cb: MTLCommandBuffer, now: Double = CACurrentMediaTime()) -> MTLTexture? {
        let w = max(width, 1), h = max(height, 1)
        // ポスタライズ時間（コンポジション）：同じコマの間は前の絵をそのまま使う
        let compTick = effects.tick(at: now)
        if let compTick, let c = compCache, c.tick == compTick, c.texture.width == w, c.texture.height == h {
            return c.texture
        }
        if target?.width != w || target?.height != h {
            target = makeTexture(w, h)
        }
        guard let target else { return nil }
        let fw = Float(w), fh = Float(h)
        let uvToPx = simd_float3x3(diagonal: SIMD3(fw, fh, 1))

        // 1. クリップ・レイヤーのエフェクト（下ごしらえ）。最後に重ねるものを並べる
        struct Final {
            var texture: MTLTexture?; var matrix: simd_float3x3; var opacity: Float; var blend: BlendMode; var premul: Bool
            /// 調整レイヤー：ここまでの絵にかけるエフェクト
            var adjust: LayerGroup? = nil
            /// 特殊合成：下の絵を読んで混ぜる
            var special: LayerGroup? = nil
        }
        var finals: [Final] = []
        for g in groups {
            if g.isAdjustment {
                finals.append(Final(texture: nil, matrix: uvToPx, opacity: g.opacity, blend: .normal, premul: false, adjust: g))
                continue
            }
            // クリップのエフェクト
            var draws = g.draws
            for i in draws.indices where !draws[i].effects.spatial.isEmpty {
                let d = draws[i]
                let out = fx.apply(d.effects, to: d.texture, key: "c\(d.effectKey)", cb: cb, now: now)
                draws[i] = LayerDraw(texture: out, opacity: d.opacity, blend: d.blend, transform: d.transform,
                                     layerTransform: d.layerTransform, compTransform: d.compTransform,
                                     holder: d.holder, effects: d.effects, effectKey: d.effectKey)
            }
            if g.effects.isEmpty && !g.blend.isSpecial {
                for d in draws {
                    let m = d.compTransform.matrix(width: fw, height: fh)
                        * d.layerTransform.matrix(width: fw, height: fh)
                        * d.transform.matrix(width: fw, height: fh) * uvToPx
                    finals.append(Final(texture: d.texture, matrix: m, opacity: g.opacity * d.opacity * d.transform.opacity,
                                        blend: g.blend, premul: false))
                }
                continue
            }
            // レイヤーのエフェクト：このレイヤーのクリップを透明な下地に重ねてから、エフェクトをかける
            let comp = draws.first?.compTransform ?? groupCache[g.key]?.comp ?? ClipTransform()
            let tick = g.effects.tick(at: now)
            var layerTex: MTLTexture?
            if let tick, let c = groupCache[g.key], c.tick == tick, c.texture.width == w, c.texture.height == h {
                layerTex = c.texture
            } else if !draws.isEmpty {
                let gt: MTLTexture
                if let t = groupTargets[g.key], t.width == w, t.height == h { gt = t } else {
                    guard let t = makeTexture(w, h) else { continue }
                    groupTargets[g.key] = t
                    gt = t
                }
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = gt
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].storeAction = .store
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
                enc.setFragmentSamplerState(ctx.sampler, index: 0)
                enc.setRenderPipelineState(ctx.accumPipeline)
                for d in draws {
                    let m = d.layerTransform.matrix(width: fw, height: fh) * d.transform.matrix(width: fw, height: fh) * uvToPx
                    var u = LayerUniforms(inv: m.inverse, opacity: d.opacity * d.transform.opacity, blend: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                    enc.setFragmentTexture(d.texture, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                enc.endEncoding()
                let out = fx.apply(g.effects, to: gt, key: "l\(g.key)", cb: cb, now: now)
                layerTex = out
                if let tick {
                    // 次のコマまで同じ絵を使うので、作業テクスチャとは別に取っておく
                    let keep = groupCache[g.key]?.texture
                    let dst = (keep?.width == w && keep?.height == h && keep !== out) ? keep! : makeTexture(w, h)
                    if let dst, let blit = cb.makeBlitCommandEncoder() {
                        blit.copy(from: out, to: dst)
                        blit.endEncoding()
                        groupCache[g.key] = (tick, dst, comp)
                        layerTex = dst
                    }
                } else {
                    groupCache[g.key] = nil
                }
            }
            if let layerTex {
                finals.append(Final(texture: layerTex, matrix: comp.matrix(width: fw, height: fh) * uvToPx,
                                    opacity: g.opacity, blend: g.blend, premul: true,
                                    special: g.blend.isSpecial ? g : nil))
            }
        }

        // 2. 重ねる（調整レイヤーが来たら、そこまでの絵にエフェクトをかけてから続ける）
        func beginPass(clear: Bool) -> MTLRenderCommandEncoder? {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = clear ? .clear : .load
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let enc = cb.makeRenderCommandEncoder(descriptor: rpd)
            enc?.setFragmentSamplerState(ctx.sampler, index: 0)
            return enc
        }
        guard var enc = beginPass(clear: true) else { return nil }
        for f in finals {
            var texture = f.texture
            if let adj = f.adjust {
                enc.endEncoding()
                let key = 20000 + adj.key
                let tick = adj.effects.tick(at: now)
                if let tick, let c = groupCache[key], c.tick == tick, c.texture.width == w, c.texture.height == h {
                    texture = c.texture
                } else {
                    let out = fx.apply(adj.effects, to: target, key: "a\(adj.key)", cb: cb, now: now)
                    // ポスタライズ時間だけのときも、前のコマの絵を取っておく（下のレイヤー全体がカクカクになる）
                    if let tick, let dst = (groupCache[key]?.texture.width == w && groupCache[key]?.texture.height == h)
                        ? groupCache[key]!.texture : makeTexture(w, h), let blit = cb.makeBlitCommandEncoder() {
                        blit.copy(from: out, to: dst)
                        blit.endEncoding()
                        groupCache[key] = (tick, dst, ClipTransform())
                        texture = dst
                    } else {
                        if tick == nil { groupCache[key] = nil }
                        texture = out === target ? nil : out
                    }
                }
                guard let e = beginPass(clear: false) else { return nil }
                enc = e
            }
            if let sp = f.special, let texture {
                // 特殊合成：下の絵を写し取ってから、シェーダーで混ぜて書き戻す
                enc.endEncoding()
                overdrive(sp, layer: texture, matrix: f.matrix, opacity: f.opacity, target: target,
                          width: w, height: h, cb: cb, now: now)
                guard let e = beginPass(clear: false) else { return nil }
                enc = e
                continue
            }
            guard let texture, let p = ctx.layerPipelines[f.blend] else { continue }
            var u = LayerUniforms(inv: f.matrix.inverse, opacity: f.opacity, blend: Int32(f.blend.rawValue),
                                  premul: f.premul ? 1 : 0)
            enc.setRenderPipelineState(p)
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()

        // 3. コンポジションのエフェクト
        let result = fx.apply(effects, to: target, key: "comp", cb: cb, now: now)
        if let compTick {
            let keep = compCache?.texture
            if let dst = (keep?.width == w && keep?.height == h) ? keep : makeTexture(w, h),
               let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: result, to: dst)
                blit.endEncoding()
                compCache = (compTick, dst)
                return dst
            }
        } else {
            compCache = nil
        }
        return result
    }

    /// オーバードライブ加算（下の絵 + このレイヤーで 100% を超えた分を、にじみ・色相ずれ・歪みに）
    private var odBelow: MTLTexture?
    private var odLow: [MTLTexture] = []
    /// 波紋の山（もっと小さく縮めて大きくぼかす）
    private var odRipple: [MTLTexture] = []
    private func overdrive(_ g: LayerGroup, layer: MTLTexture, matrix: simd_float3x3, opacity: Float,
                           target: MTLTexture, width w: Int, height h: Int, cb: MTLCommandBuffer, now: Double) {
        let scale = 4
        let lw = max(w / scale, 1), lh = max(h / scale, 1)
        if odBelow?.width != w || odBelow?.height != h { odBelow = makeTexture(w, h) }
        if odLow.count != 2 || odLow[0].width != lw || odLow[0].height != lh {
            odLow = (0..<2).compactMap { _ in makeTexture(lw, lh, .rgba16Float) }
        }
        let rscale = 32
        let rw = max(w / rscale, 1), rh = max(h / rscale, 1)
        if odRipple.count != 2 || odRipple[0].width != rw || odRipple[0].height != rh {
            odRipple = (0..<2).compactMap { _ in makeTexture(rw, rh, .rgba16Float) }
        }
        guard let below = odBelow, odLow.count == 2, odRipple.count == 2, let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: target, to: below)
        blit.endEncoding()

        let fx = g.blendFX.effects.first ?? Effect(kind: .overdrive)
        func v(_ i: Int) -> Float { Float(fx.value(i, at: now, beat: g.blendFX.beat, origin: g.blendFX.origin)) }
        // px の値は 1080p の出力での大きさ。プレビューでも本番の出力でも、画面に対して同じ見え方になるように比例させる
        let k = Float(h) / 1080
        var u = ODUniforms(inv: matrix.inverse, opacity: opacity,
                           a: SIMD4(v(0), v(1), v(2), v(3)),
                           b: SIMD4(v(4), v(5), Float(now.truncatingRemainder(dividingBy: 1000)), Float(scale)),
                           c: SIMD4(v(6), v(7) * k, Float(rscale), k),
                           size: SIMD2(Float(w), Float(h)))
        func pass(_ dst: MTLTexture, _ pipe: MTLRenderPipelineState, _ setup: (MTLRenderCommandEncoder) -> Void) {
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
        // 1. あふれ（1/4 の大きさ）
        pass(odLow[0], ctx.odOverPipeline) { e in
            e.setFragmentBytes(&u, length: MemoryLayout<ODUniforms>.stride, index: 0)
            e.setFragmentTexture(below, index: 0)
            e.setFragmentTexture(layer, index: 1)
        }
        // 2. ぼかす（横 → 縦）
        let radius = v(1) * k / Float(scale)
        for (src, dst, dir) in [(odLow[0], odLow[1], SIMD2<Float>(1, 0)), (odLow[1], odLow[0], SIMD2<Float>(0, 1))] {
            var bu = BlurUniforms(dir: dir, radius: radius)
            pass(dst, ctx.blurPipeline) { e in
                e.setFragmentBytes(&bu, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                e.setFragmentTexture(src, index: 0)
            }
        }
        // 2b. 波紋の山：1/16 の大きさで、波紋の広がりだけ大きくぼかす
        if v(3) > 0.001 {
            var ru = u
            ru.b.w = Float(rscale)
            pass(odRipple[0], ctx.odOverPipeline) { e in
                e.setFragmentBytes(&ru, length: MemoryLayout<ODUniforms>.stride, index: 0)
                e.setFragmentTexture(below, index: 0)
                e.setFragmentTexture(layer, index: 1)
            }
            // 3 回ぼかして、全体で σ = 広がり/2 になるように（1 回あたりの半径は 13 点で無理なく届く大きさ）
            let rr = v(7) * k / (Float(rscale) * 1.732)
            for _ in 0..<3 {
                for (src, dst, dir) in [(odRipple[0], odRipple[1], SIMD2<Float>(1, 0)), (odRipple[1], odRipple[0], SIMD2<Float>(0, 1))] {
                    var bu = BlurUniforms(dir: dir, radius: rr)
                    pass(dst, ctx.blurPipeline) { e in
                        e.setFragmentBytes(&bu, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                        e.setFragmentTexture(src, index: 0)
                    }
                }
            }
        }
        // 3. 仕上げて、合成先に書き戻す
        pass(target, ctx.odFinalPipeline) { e in
            e.setFragmentBytes(&u, length: MemoryLayout<ODUniforms>.stride, index: 0)
            e.setFragmentTexture(below, index: 0)
            e.setFragmentTexture(layer, index: 1)
            e.setFragmentTexture(odLow[0], index: 2)
            e.setFragmentTexture(odRipple[0], index: 3)
        }
    }

    private func makeTexture(_ w: Int, _ h: Int, _ fmt: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = storageMode
        return ctx.device.makeTexture(descriptor: td)
    }
}

/// 描画ループ。ディスプレイの vsync ごとに専用スレッド（CVDisplayLink）で動く。
/// メインスレッド（画面操作・SwiftUI）が忙しくても、出力の映像は止まらない。
/// 1 vsync ごとに: 各レイヤーの新しいフレームを取り込む → 登録された全ての画面（出力・プレビュー）に描く
final class RenderLoop {
    static let shared = RenderLoop(engine: .shared)

    struct Stats {
        var ticks = 0
        var newFrames = 0
        var maxNewFrameGapMs = 0.0
        var maxTickGapMs = 0.0
    }

    private let ctx = MetalContext.shared
    private let engine: Engine
    private var link: CVDisplayLink?

    // 下の 3 つは lock の中で触る
    private let lock = NSLock()
    /// 描画先の種類。出力（とその縮小プレビュー）か、選択中クリップのプレビューか
    enum TargetKind {
        /// 出力（コーナーピン・マスター込み）。操作画面の出力モニターも同じ
        case output
        /// コンポジション：全レイヤーの合成（コーナーピンなし、マスター込み）
        case composition
        /// 選択中のレイヤーだけ
        case layer
        /// 選択中のクリップだけ（出力していなくてもプレビュー用に再生）
        case clipPreview
    }
    private var targets: [ObjectIdentifier: (layer: CAMetalLayer, visible: Bool, kind: TargetKind)] = [:]
    private var stats = Stats()
    private var lastTick = 0.0
    private var lastNewFrame = 0.0

    /// 描画スレッドだけが触る
    private var compositors: [ObjectIdentifier: Compositor] = [:]

    init(engine: Engine) {
        self.engine = engine
    }

    func start() {
        guard link == nil else { return }
        var l: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&l)
        guard let l else { NSLog("VJPlayer: CVDisplayLink を作れません"); return }
        CVDisplayLinkSetOutputHandler(l) { [weak self] _, _, _, _, _ in
            autoreleasepool { self?.tick() }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(l)
        link = l
    }

    func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
    }

    /// vsync を合わせるディスプレイ（出力先）。nil ならメインディスプレイ
    func setDisplay(_ id: CGDirectDisplayID?) {
        guard let link else { return }
        CVDisplayLinkSetCurrentCGDisplay(link, id ?? CGMainDisplayID())
    }

    func add(_ layer: CAMetalLayer, visible: Bool = true, kind: TargetKind = .output) {
        lock.withLock { targets[ObjectIdentifier(layer)] = (layer, visible, kind) }
        start()
    }

    func remove(_ layer: CAMetalLayer) {
        _ = lock.withLock { targets.removeValue(forKey: ObjectIdentifier(layer)) }
    }

    /// 隠れているウィンドウには描かない（描こうとすると次の描画先を待たされて全体が止まるため）
    func setVisible(_ layer: CAMetalLayer, _ visible: Bool) {
        lock.withLock { targets[ObjectIdentifier(layer)]?.visible = visible }
    }

    func resetStats() {
        lock.withLock {
            stats = Stats()
            lastTick = 0
            lastNewFrame = CACurrentMediaTime()
        }
    }

    func currentStats() -> Stats {
        lock.withLock { stats }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let updated = engine.updateFrame()
        let current: [(ObjectIdentifier, CAMetalLayer, TargetKind)] = lock.withLock {
            stats.ticks += 1
            if lastTick > 0 { stats.maxTickGapMs = max(stats.maxTickGapMs, (now - lastTick) * 1000) }
            lastTick = now
            if updated > 0 {
                stats.newFrames += 1
                if lastNewFrame > 0 { stats.maxNewFrameGapMs = max(stats.maxNewFrameGapMs, (now - lastNewFrame) * 1000) }
                lastNewFrame = now
            }
            return targets.filter { $0.value.visible }.map { ($0.key, $0.value.layer, $0.value.kind) }
        }
        compositors = compositors.filter { id, _ in current.contains { $0.0 == id } }

        let params = engine.renderParams()
        let groups = engine.layerGroups()
        let compFX = engine.compEffects()
        let kinds = Set(current.map { $0.2 })
        let clipGroups = kinds.contains(.clipPreview)
            ? engine.previewDraws().map { LayerGroup(draws: [$0], opacity: 1, blend: .normal, key: 1000) } : []
        let layerGroups = kinds.contains(.layer) ? engine.layerPreviewGroups() : []
        let plain = RenderParams(homographyInverse: matrix_identity_float3x3, testPattern: false, master: 1)
        for (id, layer, kind) in current {
            let comp = compositors[id] ?? Compositor()
            compositors[id] = comp
            switch kind {
            case .output:
                render(layer, compositor: comp, groups: params.testPattern ? [] : groups, effects: compFX, params: params)
            case .composition:
                var p = plain
                p.master = params.compMaster
                render(layer, compositor: comp, groups: groups, effects: compFX, params: p)
            case .layer:
                render(layer, compositor: comp, groups: layerGroups, effects: EffectStack(), params: plain)
            case .clipPreview:
                render(layer, compositor: comp, groups: clipGroups, effects: EffectStack(), params: plain)
            }
        }
    }

    private func render(_ layer: CAMetalLayer, compositor: Compositor, groups: [LayerGroup], effects: EffectStack,
                        params: RenderParams) {
        guard let drawable = layer.nextDrawable(), let cb = ctx.queue.makeCommandBuffer() else { return }
        let w = drawable.texture.width, h = drawable.texture.height
        let composite = groups.isEmpty ? nil
            : compositor.composite(groups, effects: effects, width: w, height: h, cb: cb)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let mode: Int32 = params.testPattern ? 2 : (composite == nil ? 0 : 1)
        var u = Uniforms(hinv: params.homographyInverse, viewSize: SIMD2(Float(w), Float(h)), mode: mode,
                         master: params.master)
        enc.setRenderPipelineState(ctx.pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(composite ?? ctx.dummyTexture, index: 0)
        enc.setFragmentSamplerState(ctx.sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        // GPU が使い終わるまで映像バッファを保持する
        cb.addCompletedHandler { _ in _ = groups }
        cb.present(drawable)
        cb.commit()
    }
}

/// 出力ウィンドウとプレビューの描画先。描画は RenderLoop が専用スレッドで行う。
final class MetalLayerView: NSView {
    let metalLayer = CAMetalLayer()
    let kind: RenderLoop.TargetKind
    private var occlusionObserver: NSObjectProtocol?

    init(frame: NSRect, kind: RenderLoop.TargetKind = .output) {
        self.kind = kind
        super.init(frame: frame)
        metalLayer.device = MetalContext.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.displaySyncEnabled = true
        metalLayer.maximumDrawableCount = 3
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else {
            RenderLoop.shared.remove(metalLayer)
            return
        }
        updateDrawableSize()
        RenderLoop.shared.add(metalLayer, visible: window.occlusionState.contains(.visible), kind: kind)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, let w = self.window else { return }
            RenderLoop.shared.setVisible(self.metalLayer, w.occlusionState.contains(.visible))
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        RenderLoop.shared.remove(metalLayer)
    }
}

enum Homography {
    /// 単位正方形 (0,0)(1,0)(1,1)(0,1) を四隅 p0(TL) p1(TR) p2(BR) p3(BL) に写す行列
    static func squareToQuad(_ p: [SIMD2<Float>]) -> simd_float3x3 {
        let (x0, y0) = (p[0].x, p[0].y)
        let (x1, y1) = (p[1].x, p[1].y)
        let (x2, y2) = (p[2].x, p[2].y)
        let (x3, y3) = (p[3].x, p[3].y)
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        let den = dx1 * dy2 - dx2 * dy1
        let g = abs(den) < 1e-9 ? 0 : (dx3 * dy2 - dx2 * dy3) / den
        let h = abs(den) < 1e-9 ? 0 : (dx1 * dy3 - dx3 * dy1) / den
        let a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0
        let d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0
        return simd_float3x3(rows: [
            SIMD3(a, b, c),
            SIMD3(d, e, f),
            SIMD3(g, h, 1),
        ])
    }
}
