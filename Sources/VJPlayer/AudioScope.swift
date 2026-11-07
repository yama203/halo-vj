import Accelerate
import Metal
import QuartzCore

// 音の形：音の入力の、周波数ごとの大きさ（スペクトラム）と波形を、そのまま絵にするジェネレーター。

/// スペクトラムと波形を作る（音声のスレッドで使う）
final class SpectrumAnalyzer {
    static let fftSize = 2048
    static let bands = 128
    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private var ring = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var window = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var peakDB: Float = -40
    private var peakAmp: Float = 0.05

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// 新しい音（モノラル）を足して、スペクトラム（帯ごと 0〜1）と波形（-1〜1、512 点）を返す
    func process(_ x: [Float], sampleRate: Double, autoGain: Bool) -> (spectrum: [Float], wave: [Float]) {
        let n = Self.fftSize
        if x.count >= n { ring = Array(x.suffix(n)) } else { ring.removeFirst(x.count); ring += x }
        // 窓をかけて FFT
        var w = [Float](repeating: 0, count: n)
        vDSP_vmul(ring, 1, window, 1, &w, 1, vDSP_Length(n))
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(n / 2)) }
                }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&sc, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        // 30 Hz〜16 kHz を、耳に近い間隔（対数）で帯に分ける
        let binHz = Float(sampleRate) / Float(n)
        var bands = [Float](repeating: 0, count: Self.bands)
        let lo: Float = 30, hi: Float = min(16000, Float(sampleRate) / 2 - binHz)
        for b in 0..<Self.bands {
            let f0 = lo * pow(hi / lo, Float(b) / Float(Self.bands)), f1 = lo * pow(hi / lo, Float(b + 1) / Float(Self.bands))
            let i0 = max(Int(f0 / binHz), 1), i1 = max(Int(f1 / binHz), i0 + 1)
            var m: Float = 0
            for i in i0..<min(i1, n / 2) { m = max(m, mags[i]) }
            bands[b] = 20 * log10(m / Float(n) + 1e-9)
        }
        // 大きさ：自動で合わせるなら、最近いちばん大きかった帯を 100% に（60 dB の幅で見せる）
        let top = bands.max() ?? -120
        peakDB = autoGain ? max(top, peakDB - 0.05) : -12
        let spectrum = bands.map { min(max(1 + ($0 - peakDB) / 60, 0), 1) }
        // 波形：最後の 1024 点を 512 点に。大きさも合わせる
        let tail = Array(ring.suffix(1024))
        var amp: Float = 0
        vDSP_maxmgv(tail, 1, &amp, vDSP_Length(tail.count))
        peakAmp = autoGain ? max(amp, peakAmp * 0.995, 0.01) : 1
        let wave = stride(from: 0, to: tail.count, by: 2).map { min(max(tail[$0] / peakAmp, -1), 1) }
        return (spectrum, wave)
    }
}

extension AudioReactive {
    /// 今のスペクトラム（帯ごと 0〜1）と波形（-1〜1）。音が無ければ 0
    func scope() -> (spectrum: [Float], wave: [Float]) { scopeLock.withLock { (scopeSpectrum, scopeWave) } }
}

private let scopeShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VO { float4 pos [[position]]; float2 uv; };
vertex VO sc_v(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o; o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0); o.uv = c; return o;
}
// a = 形, 帯の数, 高さ, 太さ / b = 色の付け方, 上下対称, 明るさ, 円の大きさ / c = 縦横比, 時刻
struct SCU { float4 a, b, c; float4 color; float4 pal[8]; int palCount; };
static float3 scHue(float h) { float3 k = abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0); return saturate(k - 1.0); }
static float3 scPal(constant float4* pal, int count, float x) {
    int n = max(count, 1);
    if (n == 1) return pal[0].rgb;
    float t = saturate(x) * float(n - 1);
    int i = min(int(floor(t)), n - 2);
    return mix(pal[i].rgb, pal[i + 1].rgb, t - float(i));
}
static float bandAt(constant float* sp, float x, int nb) {
    // 帯の数に合わせて、128 の帯から取る（帯の中で一番大きいもの）
    float f = saturate(x) * 128.0;
    int i0 = int(floor(f / 128.0 * float(nb))) * 128 / nb;
    int i1 = max(int(floor(f / 128.0 * float(nb)) + 1.0) * 128 / nb, i0 + 1);
    float m = 0.0;
    for (int i = i0; i < min(i1, 128); i++) m = max(m, sp[i]);
    return m;
}
fragment float4 sc_f(VO in [[stage_in]], constant SCU& u [[buffer(0)]], constant float* sp [[buffer(1)]],
                     constant float* wv [[buffer(2)]]) {
    float2 uv = in.uv;
    int shape = int(u.a.x + 0.5), nb = max(int(u.a.y + 0.5), 1);
    float hgt = u.a.z, th = u.a.w;
    bool mirror = u.b.y > 0.5;
    float k = 0.0, colorX = uv.x, colorY = 0.0;
    float A = u.c.x;
    if (shape <= 1) {
        // スペクトラム：棒（帯ごと）・線
        float y = mirror ? abs(uv.y - 0.5) * 2.0 : 1.0 - uv.y;
        if (shape == 0) {
            float cell = floor(uv.x * float(nb));
            float fx = fract(uv.x * float(nb));
            float v = bandAt(sp, (cell + 0.5) / float(nb), nb) * hgt;
            float gap = (1.0 - max(th, 0.05)) * 0.5;
            k = (fx > gap && fx < 1.0 - gap && y < v) ? 1.0 : 0.0;
            colorY = y;
        } else {
            // 帯のあいだをなめらかにつなぐ。線の太さは、坂の向きも入れて見た目の太さにする
            float f = saturate(uv.x) * 127.0;
            int i = int(floor(f));
            // なめらかな曲線（Catmull-Rom）でつなぐ
            float p0 = sp[max(i - 1, 0)], p1 = sp[i], p2 = sp[min(i + 1, 127)], p3 = sp[min(i + 2, 127)];
            float t = fract(f), t2 = t * t, t3 = t2 * t;
            float v = 0.5 * (2.0 * p1 + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3);
            float dv = 0.5 * ((-p0 + p2) + 2.0 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t + 3.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t2);
            v *= hgt;
            float d = abs(y - v);
            float w = 0.002 + th * 0.02;
            // 坂（画面の上での傾き）の分だけ、縦に測った距離を広げる
            float dvdx = dv * 127.0 * hgt;
            float fac = sqrt(1.0 + pow(dvdx / max(A, 1e-3), 2.0));
            k = 1.0 - smoothstep(w * fac, (w + fwidth(uv.y) * 1.5) * fac, d);
            colorY = v;
        }
    } else if (shape == 2) {
        // 波形
        float f = uv.x * 511.0;
        int i = int(floor(f));
        float s = mix(wv[i], wv[min(i + 1, 511)], fract(f));
        float y = 0.5 - s * 0.5 * hgt;
        float w = 0.002 + th * 0.015;
        k = 1.0 - smoothstep(w, w + fwidth(uv.y) * 1.5, abs(uv.y - y));
        if (mirror) k = max(k, 1.0 - smoothstep(w, w + fwidth(uv.y) * 1.5, abs(uv.y - (1.0 - y))));
        colorY = abs(s);
    } else {
        // 円：まわりに放射状のスペクトラム（3）・円の波形（4）
        float2 p = (uv - 0.5) * float2(A, 1.0);
        float r = length(p);
        float ang = atan2(p.x, -p.y) / 6.2831853 + 0.5;
        float R = u.b.w;
        if (mirror) ang = 1.0 - abs(ang * 2.0 - 1.0);
        colorX = ang;
        if (shape == 3) {
            float cell = floor(ang * float(nb));
            float fx = fract(ang * float(nb));
            float v = bandAt(sp, (cell + 0.5) / float(nb), nb) * hgt * 0.35;
            float gap = (1.0 - max(th, 0.05)) * 0.5;
            k = (fx > gap && fx < 1.0 - gap && r > R && r < R + v + 0.004) ? 1.0 : 0.0;
            colorY = (r - R) / max(hgt * 0.35, 1e-3);
        } else {
            float f = ang * 511.0;
            int i = int(floor(f));
            float s = mix(wv[i], wv[min(i + 1, 511)], fract(f));
            float target = R + s * 0.12 * hgt;
            float w = 0.002 + th * 0.012;
            k = 1.0 - smoothstep(w, w + fwidth(r) * 1.5, abs(r - target));
            colorY = abs(s);
        }
    }
    int cm = int(u.b.x + 0.5);
    float3 col = cm == 1 ? scHue(colorX * 0.8) : (cm == 2 ? scPal(u.pal, u.palCount, saturate(colorY)) : u.color.rgb);
    float a = saturate(k);
    return float4(col * a * u.b.z, a);
}
"""

private struct ScopeUniforms {
    var a = SIMD4<Float>.zero, b = SIMD4<Float>.zero, c = SIMD4<Float>.zero
    var color = SIMD4<Float>(1, 1, 1, 1)
    var pal: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
              SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var palCount: Int32 = 1
}

/// 音の形を描く。帯の高さは、ジェネレーターごとに少しなめらかにする（下がるときはゆっくり）
final class AudioScopeSim {
    private static let pipe: MTLRenderPipelineState = {
        let dev = MetalContext.shared.device
        let lib = try! dev.makeLibrary(source: scopeShaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "sc_v")
        d.fragmentFunction = lib.makeFunction(name: "sc_f")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try! dev.makeRenderPipelineState(descriptor: d)
    }()
    private var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
    /// テスト用：音の代わりに使う値
    static var testScope: (spectrum: [Float], wave: [Float])?

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        var (sp, wv) = Self.testScope ?? AudioReactive.shared.scope()
        if sp.count != SpectrumAnalyzer.bands { sp = [Float](repeating: 0, count: SpectrumAnalyzer.bands) }
        if wv.count != 512 { wv = [Float](repeating: 0, count: 512) }
        // なめらかさ：上がるのはすぐ、下がるのはゆっくり
        let fall = Float(pow(0.02 + 0.97 * Double(min(max(v(6), 0), 1)), max(dt, 1.0 / 60) * 60 * 0.15))
        for i in bands.indices { bands[i] = max(sp[i], bands[i] * (dt > 0 ? fall : 1)) }
        var u = ScopeUniforms()
        u.a = SIMD4(v(0).rounded(), v(1).rounded(), v(2), v(3))
        u.b = SIMD4(v(4).rounded(), v(5), v(7), v(8))
        u.c = SIMD4(Float(dst.width) / Float(max(dst.height, 1)), 0, 0, 0)
        u.color = e.color.simd
        let p = (e.palette.isEmpty ? [RGB.black, RGB.white] : Array(e.palette.prefix(8))).map(\.simd)
        func at(_ i: Int) -> SIMD4<Float> { i < p.count ? p[i] : p[p.count - 1] }
        u.pal = (at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7))
        u.palCount = Int32(p.count)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(Self.pipe)
        enc.setFragmentBytes(&u, length: MemoryLayout<ScopeUniforms>.stride, index: 0)
        bands.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        wv.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}
