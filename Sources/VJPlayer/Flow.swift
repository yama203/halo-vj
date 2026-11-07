import Metal
import QuartzCore
import simd

// 前のコマを覚えるエフェクト：時間のずらし（スリットスキャン）と流体。

private let flowShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VO { float4 pos [[position]]; float2 uv; };
vertex VO flow_full(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o;
    o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
    o.uv = c;
    return o;
}
fragment float4 flow_copy(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}

static float fhash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float fnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(fhash(i), fhash(i + float2(1, 0)), w.x), mix(fhash(i + float2(0, 1)), fhash(i + float2(1, 1)), w.x), w.y);
}
static float flum(float4 c) { return dot(c.rgb, float3(0.2126, 0.7152, 0.0722)); }

// ============ 時間のずらし ============
// a = ずらす秒, 1 秒のコマ数, 覚えているコマ数, 最新のコマから今までの秒
// b = ずらし方, 反転, 段数, ノイズの細かさ / c = ノイズの時刻, 覚えたコマ数, 最新の番号, 縦横比 / d.x = 不透明度
struct TWU { float4 a, b, c, d; };
fragment float4 tw_draw(VO in [[stage_in]], texture2d<float> live [[texture(0)]], texture2d_array<float> hist [[texture(1)]],
                        constant TWU& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float4 now = live.sample(s, uv);
    int mode = int(u.b.x + 0.5);
    float m;
    if (mode == 0) m = 1.0 - uv.y;                               // 上ほど過去
    else if (mode == 1) m = 1.0 - uv.x;                          // 左ほど過去
    else if (mode == 2) m = 1.0 - saturate(length((uv - 0.5) * float2(u.c.w, 1.0)) / (0.5 * length(float2(u.c.w, 1.0))));
    else if (mode == 3) {
        float2 q = uv * float2(u.c.w, 1.0) * u.b.w + float2(u.c.x * 0.37, u.c.x * 0.23);
        m = saturate((fnoise(q) * 0.65 + fnoise(q * 2.03 + 5.1) * 0.35 - 0.2) / 0.6);
    } else m = saturate(flum(now) / max(now.a, 1e-4));           // 明るい所ほど過去
    if (u.b.y > 0.5) m = 1.0 - m;
    if (u.b.z > 1.5) m = floor(m * u.b.z) / (u.b.z - 1.0);
    m = saturate(m);
    // 何コマ前か（最新のコマから）。最新より新しい所は、今の絵と最新のコマを混ぜる
    float back = m * u.a.x * u.a.y - u.a.w * u.a.y;
    int cap = int(u.a.z), filled = int(u.c.y), head = int(u.c.z);
    float4 r;
    if (filled <= 0) r = now;
    else if (back <= 0.0) {
        float k = saturate(m * u.a.x * u.a.y / max(u.a.w * u.a.y, 1e-3));
        r = mix(now, hist.sample(s, uv, uint(head)), k);
    } else {
        back = min(back, float(filled - 1));
        int b0 = int(floor(back));
        int b1 = min(b0 + 1, filled - 1);
        float f = back - float(b0);
        int i0 = (head - b0 + cap * 4) % cap, i1 = (head - b1 + cap * 4) % cap;
        r = mix(hist.sample(s, uv, uint(i0)), hist.sample(s, uv, uint(i1)), f);
    }
    return mix(now, r, saturate(u.d.x));
}

// ============ 流体 ============
// a = 格子の幅, 高さ, 1 コマの秒, 縦横比 / b = 動きで押す, 絵の具を足す量, 足し方, 絵の具の残る割合
// c = 渦, 風, 速さの残る割合, 時刻 / d = 絵の具の格子の幅, 高さ, 元の絵, 不透明度
struct FU { float4 a, b, c, d, e; };   // e.x = 押し方（0 動き / 1 明るい所のまわりを回す）

kernel void fl_force(texture2d<float, access::read> vin [[texture(0)]], texture2d<float, access::write> vout [[texture(1)]],
                     texture2d<float> src [[texture(2)]], texture2d<float, access::read_write> prev [[texture(3)]],
                     constant FU& u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
    int W = int(u.a.x), H = int(u.a.y);
    if (int(g.x) >= W || int(g.y) >= H) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 cell = 1.0 / float2(W, H);
    float2 uv = (float2(g) + 0.5) * cell;
    float l = flum(src.sample(s, uv));
    float lx = flum(src.sample(s, uv + float2(cell.x, 0))) - flum(src.sample(s, uv - float2(cell.x, 0)));
    float ly = flum(src.sample(s, uv + float2(0, cell.y))) - flum(src.sample(s, uv - float2(0, cell.y)));
    float2 grad = float2(lx, ly) * 0.5;
    float4 pv = prev.read(g);
    float dl = pv.y > 0.5 ? l - pv.x : 0.0;
    prev.write(float4(l, 1.0, abs(dl), 0.0), g);
    float dt = u.a.z;
    float2 v = vin.read(g).xy;
    // 動き：明るさが変わった向きの反対へ（明るい所が動いていく向き）、マス／コマ
    float2 move = -dl * grad / (dot(grad, grad) + 0.0004);
    move = clamp(move, -3.0, 3.0);
    if (u.e.x > 0.5) {
        // 明るい所のまわりを回す（坂に直角に押す。縮まない流れでも消えずに渦になる。止まった絵でも押し続ける）
        v += float2(-grad.y, grad.x) * u.b.x * 1500.0 * dt;
    } else {
        v += move * u.b.x * 40.0 * min(dt * 60.0, 2.0);
    }
    // 風：ゆっくり動く渦のある流れ（静止画でも動くように）
    if (u.c.y > 0.0) {
        float t = u.c.w * 0.15;
        float2 q = uv * float2(u.a.w, 1.0) * 2.5;
        float e = 0.02;
        float n0 = fnoise(q + t), nx = fnoise(q + float2(e, 0) + t), ny = fnoise(q + float2(0, e) + t);
        float2 curl = float2(ny - n0, -(nx - n0)) / e;
        v += curl * u.c.y * float(H) * 0.4 * dt;
    }
    vout.write(float4(v, 0.0, 0.0), g);
}

kernel void fl_advect(texture2d<float> vel [[texture(0)]], texture2d<float> qin [[texture(1)]],
                      texture2d<float, access::write> qout [[texture(2)]], constant FU& u [[buffer(0)]],
                      constant float& keep [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
    int W = int(qout.get_width()), H = int(qout.get_height());
    if (int(g.x) >= W || int(g.y) >= H) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(g) + 0.5) / float2(W, H);
    float2 v = vel.sample(s, uv).xy;                                  // 速さの格子のマス／秒
    float2 back = uv - v * u.a.z / float2(u.a.x, u.a.y);
    qout.write(qin.sample(s, back) * keep, g);
}

kernel void fl_curl(texture2d<float, access::read> vel [[texture(0)]], texture2d<float, access::write> cu [[texture(1)]],
                    uint2 g [[thread_position_in_grid]]) {
    int W = int(vel.get_width()), H = int(vel.get_height());
    if (int(g.x) >= W || int(g.y) >= H) return;
    uint2 L = uint2(max(int(g.x) - 1, 0), g.y), R = uint2(min(int(g.x) + 1, W - 1), g.y);
    uint2 T = uint2(g.x, max(int(g.y) - 1, 0)), B = uint2(g.x, min(int(g.y) + 1, H - 1));
    float c = (vel.read(R).y - vel.read(L).y) - (vel.read(B).x - vel.read(T).x);
    cu.write(float4(c * 0.5), g);
}

kernel void fl_vort(texture2d<float, access::read> vin [[texture(0)]], texture2d<float, access::read> cu [[texture(1)]],
                    texture2d<float, access::write> vout [[texture(2)]], constant FU& u [[buffer(0)]],
                    uint2 g [[thread_position_in_grid]]) {
    int W = int(vin.get_width()), H = int(vin.get_height());
    if (int(g.x) >= W || int(g.y) >= H) return;
    uint2 L = uint2(max(int(g.x) - 1, 0), g.y), R = uint2(min(int(g.x) + 1, W - 1), g.y);
    uint2 T = uint2(g.x, max(int(g.y) - 1, 0)), B = uint2(g.x, min(int(g.y) + 1, H - 1));
    float2 n = float2(abs(cu.read(R).x) - abs(cu.read(L).x), abs(cu.read(B).x) - abs(cu.read(T).x)) * 0.5;
    n /= length(n) + 1e-5;
    float c = cu.read(g).x;
    float2 v = vin.read(g).xy + float2(n.y, -n.x) * c * u.c.x * 30.0 * u.a.z;
    // 端では外へ出ない
    if (g.x == 0 || int(g.x) == W - 1) v.x = 0.0;
    if (g.y == 0 || int(g.y) == H - 1) v.y = 0.0;
    vout.write(float4(v, 0.0, 0.0), g);
}

kernel void fl_div(texture2d<float, access::read> vel [[texture(0)]], texture2d<float, access::write> dv [[texture(1)]],
                   uint2 g [[thread_position_in_grid]]) {
    int W = int(vel.get_width()), H = int(vel.get_height());
    if (int(g.x) >= W || int(g.y) >= H) return;
    uint2 L = uint2(max(int(g.x) - 1, 0), g.y), R = uint2(min(int(g.x) + 1, W - 1), g.y);
    uint2 T = uint2(g.x, max(int(g.y) - 1, 0)), B = uint2(g.x, min(int(g.y) + 1, H - 1));
    float d = (vel.read(R).x - vel.read(L).x + vel.read(B).y - vel.read(T).y) * 0.5;
    dv.write(float4(d), g);
}

kernel void fl_jacobi(texture2d<float, access::read> pin [[texture(0)]], texture2d<float, access::read> dv [[texture(1)]],
                      texture2d<float, access::write> pout [[texture(2)]], uint2 g [[thread_position_in_grid]]) {
    int W = int(pin.get_width()), H = int(pin.get_height());
    if (int(g.x) >= W || int(g.y) >= H) return;
    uint2 L = uint2(max(int(g.x) - 1, 0), g.y), R = uint2(min(int(g.x) + 1, W - 1), g.y);
    uint2 T = uint2(g.x, max(int(g.y) - 1, 0)), B = uint2(g.x, min(int(g.y) + 1, H - 1));
    float p = (pin.read(L).x + pin.read(R).x + pin.read(T).x + pin.read(B).x - dv.read(g).x) * 0.25;
    pout.write(float4(p), g);
}

kernel void fl_project(texture2d<float, access::read> vin [[texture(0)]], texture2d<float, access::read> pr [[texture(1)]],
                       texture2d<float, access::write> vout [[texture(2)]], uint2 g [[thread_position_in_grid]]) {
    int W = int(vin.get_width()), H = int(vin.get_height());
    if (int(g.x) >= W || int(g.y) >= H) return;
    uint2 L = uint2(max(int(g.x) - 1, 0), g.y), R = uint2(min(int(g.x) + 1, W - 1), g.y);
    uint2 T = uint2(g.x, max(int(g.y) - 1, 0)), B = uint2(g.x, min(int(g.y) + 1, H - 1));
    float2 v = vin.read(g).xy - float2(pr.read(R).x - pr.read(L).x, pr.read(B).x - pr.read(T).x) * 0.5;
    vout.write(float4(v, 0.0, 0.0), g);
}

// 絵の具：流してから、元の絵から足す（足し方：動いた所・明るい所・全体）
kernel void fl_dye(texture2d<float> vel [[texture(0)]], texture2d<float> din [[texture(1)]],
                   texture2d<float, access::write> dout [[texture(2)]], texture2d<float> src [[texture(3)]],
                   texture2d<float> prev [[texture(4)]], constant FU& u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
    int W = int(dout.get_width()), H = int(dout.get_height());
    if (int(g.x) >= W || int(g.y) >= H) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(g) + 0.5) / float2(W, H);
    float2 v = vel.sample(s, uv).xy;
    float2 back = uv - v * u.a.z / float2(u.a.x, u.a.y);
    float4 d = din.sample(s, back) * u.b.w;
    float4 c = src.sample(s, uv);
    int mode = int(u.b.z + 0.5);
    float mask = mode == 0 ? saturate(prev.sample(s, uv).z * 12.0) : (mode == 1 ? smoothstep(0.25, 0.9, flum(c)) : 1.0);
    float k = saturate(u.b.y * mask * u.a.z * 10.0);
    dout.write(mix(d, c, k), g);
}

fragment float4 fl_draw(VO in [[stage_in]], texture2d<float> dye [[texture(0)]], texture2d<float> src [[texture(1)]],
                        constant FU& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 d = dye.sample(s, in.uv);
    d = float4(min(d.rgb, float3(saturate(d.a))), saturate(d.a));
    float4 c = src.sample(s, in.uv);
    float4 r = d + c * u.d.z * (1.0 - d.a);
    return mix(c, r, saturate(u.d.w));
}
"""

final class FlowRenderer {
    static let shared = FlowRenderer()
    let device = MetalContext.shared.device
    let twDraw, copy, flDraw: MTLRenderPipelineState
    let force, advect, curl, vort, div, jacobi, project, dye: MTLComputePipelineState

    private init() {
        let dev = MetalContext.shared.device
        let lib: MTLLibrary
        do { lib = try dev.makeLibrary(source: flowShaderSource, options: nil) } catch {
            fatalError("時間のずらし・流体のシェーダーを作れません: \(error)")
        }
        func r(_ f: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "flow_full")
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try! dev.makeRenderPipelineState(descriptor: d)
        }
        func k(_ n: String) -> MTLComputePipelineState { try! dev.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
        twDraw = r("tw_draw"); copy = r("flow_copy"); flDraw = r("fl_draw")
        force = k("fl_force"); advect = k("fl_advect"); curl = k("fl_curl"); vort = k("fl_vort")
        div = k("fl_div"); jacobi = k("fl_jacobi"); project = k("fl_project"); dye = k("fl_dye")
    }

    func texture(_ w: Int, _ h: Int, _ f: MTLPixelFormat, slices: Int = 0, renderTarget: Bool = false) -> MTLTexture? {
        let td = MTLTextureDescriptor()
        td.textureType = slices > 0 ? .type2DArray : .type2D
        td.pixelFormat = f
        td.width = w; td.height = h
        if slices > 0 { td.arrayLength = slices }
        td.usage = renderTarget ? [.renderTarget, .shaderRead] : [.shaderRead, .shaderWrite]
        td.storageMode = .private
        return device.makeTexture(descriptor: td)
    }

    static func grid(_ enc: MTLComputeCommandEncoder, _ w: Int, _ h: Int) {
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }
}

// MARK: - 時間のずらし

final class TimeWarpSim {
    static let fps = 30.0
    var hist: MTLTexture?
    var cap = 0, head = 0, filled = 0
    var lastPush = -1.0
    var w = 0, h = 0

    func render(_ e: Effect, input: MTLTexture, into dst: MTLTexture, now: Double, stack: EffectStack, mixAmt: Float,
                cb: MTLCommandBuffer) {
        let r = FlowRenderer.shared
        func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
        let secs = min(max(v(0), 0.05), 4)
        // 覚えておく絵は高さ 540 まで（メモリを使いすぎないように）
        let hh = min(input.height, 540)
        let ww = max(Int((Double(input.width) / Double(max(input.height, 1)) * Double(hh)).rounded()), 1)
        let need = min(Int((secs * Self.fps).rounded(.up)) + 2, 124)
        if hist == nil || ww != w || hh != h || need > cap {
            w = ww; h = hh; cap = max(need, 8)
            hist = r.texture(w, h, .bgra8Unorm, slices: cap, renderTarget: true)
            head = 0; filled = 0; lastPush = -1
        }
        guard let hist else { return }
        // 時刻が戻った（巻き戻し・テスト）ら、覚えた絵を捨てる
        if lastPush >= 0 && now < lastPush - 0.001 { filled = 0; lastPush = -1 }
        if lastPush < 0 || now - lastPush >= 1 / Self.fps - 0.002 {
            head = filled == 0 ? 0 : (head + 1) % cap
            filled = min(filled + 1, cap)
            lastPush = now
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = hist
            rpd.colorAttachments[0].slice = head
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(r.copy)
                enc.setFragmentTexture(input, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
        }
        var u = (SIMD4(Float(secs), Float(Self.fps), Float(cap), Float(max(now - lastPush, 0))),
                 SIMD4(Float(v(1).rounded()), Float(v(2)), Float(v(3).rounded()), Float(max(v(4), 0.1))),
                 SIMD4(Float((v(5) * max(now - stack.origin, 0)).truncatingRemainder(dividingBy: 10000)), Float(filled),
                       Float(head), Float(Double(input.width) / Double(max(input.height, 1)))),
                 SIMD4(mixAmt, 0, 0, 0))
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(r.twDraw)
        enc.setFragmentTexture(input, index: 0)
        enc.setFragmentTexture(hist, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride * 4, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

// MARK: - 流体

final class FluidSim {
    var vel: [MTLTexture] = []
    var prs: [MTLTexture] = []
    var div: MTLTexture?, curl: MTLTexture?, prev: MTLTexture?
    var dye: [MTLTexture] = []
    var gw = 0, gh = 0, dw = 0, dh = 0
    var time = 0.0
    var fresh = true

    struct Params {
        var push = 1.0, inject = 0.4, injectMode = 0, dyeKeep = 0.7, vortex = 0.4, wind = 0.25, viscosity = 0.3
        var keepOriginal = 0.5, grid = 1, pushMode = 0
    }

    func render(_ e: Effect, input: MTLTexture, into dst: MTLTexture, dt rawDt: Double, now: Double, stack: EffectStack,
                mixAmt: Float, cb: MTLCommandBuffer) {
        func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
        run(source: input, force: input, into: dst, dt: rawDt,
            params: Params(push: v(0), inject: v(1), injectMode: Int(v(2).rounded()), dyeKeep: v(3), vortex: v(4), wind: v(5),
                           viscosity: v(6), keepOriginal: v(7), grid: Int(v(8).rounded()), pushMode: 0),
            mixAmt: mixAmt, cb: cb)
    }

    /// source = 絵の具のもと（出す絵の下地）, force = 流れを押す絵
    func run(source input: MTLTexture, force: MTLTexture, into dst: MTLTexture, dt rawDt: Double, params pr: Params,
             mixAmt: Float, cb: MTLCommandBuffer) {
        let r = FlowRenderer.shared
        let A = Double(input.width) / Double(max(input.height, 1))
        let gH = [96, 160, 256][min(max(pr.grid, 0), 2)]
        let gW = max(Int((Double(gH) * A).rounded()), 4)
        let dH = min(max(input.height, 8), 540)
        let dW = max(Int((Double(dH) * A).rounded()), 4)
        if gW != gw || gH != gh || dW != dw || dH != dh || vel.isEmpty {
            gw = gW; gh = gH; dw = dW; dh = dH
            vel = (0..<2).compactMap { _ in r.texture(gw, gh, .rgba16Float) }
            prs = (0..<2).compactMap { _ in r.texture(gw, gh, .r16Float) }
            div = r.texture(gw, gh, .r16Float); curl = r.texture(gw, gh, .r16Float)
            prev = r.texture(gw, gh, .rgba16Float)
            dye = (0..<2).compactMap { _ in r.texture(dw, dh, .rgba16Float) }
            fresh = true
        }
        guard vel.count == 2, prs.count == 2, dye.count == 2, let div, let curl, let prev else { return }
        if fresh, let b = cb.makeBlitCommandEncoder() {
            // はじめは空っぽ（private のテクスチャは中身が決まっていないので、0 で埋める）
            for t in vel + prs + dye + [div, curl, prev] {
                let bpp = t.pixelFormat == .r16Float ? 2 : 8
                let zeros = [UInt8](repeating: 0, count: t.width * t.height * bpp)
                if let tmp = r.device.makeBuffer(bytes: zeros, length: zeros.count, options: .storageModeShared) {
                    b.copy(from: tmp, sourceOffset: 0, sourceBytesPerRow: t.width * bpp, sourceBytesPerImage: zeros.count,
                           sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: t, destinationSlice: 0,
                           destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                }
            }
            b.endEncoding()
            fresh = false
        }
        let dt = min(max(rawDt, 0), 1.0 / 20)
        time += dt
        // 残る割合（1 秒あたり → このコマ）
        let dyeKeep = pr.dyeKeep >= 0.999 ? 1 : pow(0.02 + 0.97 * pow(min(max(pr.dyeKeep, 0), 1), 0.35), dt)
        let velKeep = pow(0.05 + 0.94 * (1 - min(max(pr.viscosity, 0), 1)), dt)
        var u = (SIMD4(Float(gw), Float(gh), Float(dt), Float(A)),
                 SIMD4(Float(max(pr.push, 0)), Float(max(pr.inject, 0)), Float(pr.injectMode), Float(dyeKeep)),
                 SIMD4(Float(max(pr.vortex, 0)), Float(max(pr.wind, 0)), Float(velKeep), Float(time.truncatingRemainder(dividingBy: 10000))),
                 SIMD4(Float(dw), Float(dh), Float(min(max(pr.keepOriginal, 0), 1)), mixAmt),
                 SIMD4(Float(pr.pushMode), 0, 0, 0))
        let ul = MemoryLayout<SIMD4<Float>>.stride * 5
        if dt > 0, let enc = cb.makeComputeCommandEncoder() {
            // 1. 動きと風で押す
            enc.setComputePipelineState(r.force)
            enc.setTextures([vel[0], vel[1], force, prev], range: 0..<4)
            enc.setBytes(&u, length: ul, index: 0)
            FlowRenderer.grid(enc, gw, gh)
            // 2. 速さを速さで流す
            var vk = Float(velKeep)
            enc.setComputePipelineState(r.advect)
            enc.setTextures([vel[1], vel[1], vel[0]], range: 0..<3)
            enc.setBytes(&u, length: ul, index: 0)
            enc.setBytes(&vk, length: 4, index: 1)
            FlowRenderer.grid(enc, gw, gh)
            // 3. 渦を強める
            enc.setComputePipelineState(r.curl)
            enc.setTextures([vel[0], curl], range: 0..<2)
            FlowRenderer.grid(enc, gw, gh)
            enc.setComputePipelineState(r.vort)
            enc.setTextures([vel[0], curl, vel[1]], range: 0..<3)
            enc.setBytes(&u, length: ul, index: 0)
            FlowRenderer.grid(enc, gw, gh)
            // 4. 縮まない流れにする（圧力を求めて引く）
            enc.setComputePipelineState(r.div)
            enc.setTextures([vel[1], div], range: 0..<2)
            FlowRenderer.grid(enc, gw, gh)
            enc.setComputePipelineState(r.jacobi)
            for i in 0..<24 {
                enc.setTextures([prs[i % 2], div, prs[1 - i % 2]], range: 0..<3)
                FlowRenderer.grid(enc, gw, gh)
            }
            enc.setComputePipelineState(r.project)
            enc.setTextures([vel[1], prs[0], vel[0]], range: 0..<3)
            FlowRenderer.grid(enc, gw, gh)
            // 5. 絵の具を流して足す
            enc.setComputePipelineState(r.dye)
            enc.setTextures([vel[0], dye[0], dye[1], input, prev], range: 0..<5)
            enc.setBytes(&u, length: ul, index: 0)
            FlowRenderer.grid(enc, dw, dh)
            enc.endEncoding()
            dye.swapAt(0, 1)
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(r.flDraw)
        enc.setFragmentTexture(dye[0], index: 0)
        enc.setFragmentTexture(input, index: 1)
        enc.setFragmentBytes(&u, length: ul, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}
