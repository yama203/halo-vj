import Accelerate
import Metal
import QuartzCore

// 音の形：音の入力の、周波数ごとの大きさ（スペクトラム）と波形を、そのまま絵にするジェネレーター。

/// スペクトラムと波形を作る（描くときに、ジェネレーターごとに使う）
final class SpectrumAnalyzer {
    static let fftSize = 2048
    static let bands = 128
    /// 波形の点の数（音 2048 個ぶん。まっすぐな波形はその前半、円は全部を使ってつなぎ目を消す）
    static let wavePoints = 1024
    /// 切り出す音の数（スペクトラム 2048＋波形の頭をそろえるための余り）
    static let needSamples = 4096
    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var peakDB: Float = -40
    private var peakAmp: Float = 0.05

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// 最近の音（モノラル。古い方から、needSamples 個あるとよい）から、スペクトラム（帯ごと 0〜1）と波形（-1〜1、wavePoints 点）を作る
    func process(_ input: [Float], sampleRate: Double, autoGain: Bool) -> (spectrum: [Float], wave: [Float]) {
        let n = Self.fftSize, need = Self.needSamples
        let x: [Float] = input.count >= need ? Array(input.suffix(need)) : [Float](repeating: 0, count: need - input.count) + input
        // スペクトラム：最後の 2048 個に窓をかけて FFT
        var w = [Float](repeating: 0, count: n)
        Array(x.suffix(n)).withUnsafeBufferPointer { vDSP_vmul($0.baseAddress!, 1, window, 1, &w, 1, vDSP_Length(n)) }
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

        // 波形：オシロスコープのように、上がりながら 0 を横切る所を頭にそろえる（毎回ばらばらの所から切ると、波が跳ねて見える）
        let len = Self.wavePoints * 2
        // 横切りを探すのは、低い音だけにした波で（細かいギザギザで頭がぶれないように）
        var lp = [Float](repeating: 0, count: need)
        var acc: Float = 0
        for i in 0..<need { acc += (x[i] - acc) * 0.08; lp[i] = acc }
        var start = need - len
        let searchFrom = need - len - 1024
        for st in stride(from: need - len, through: max(searchFrom, 1), by: -1) where lp[st - 1] < 0 && lp[st] >= 0 {
            start = st; break
        }
        // 2 個ずつまとめて点に（まわりの 5 個を重みを付けて足し、角を取る）
        var wave = [Float](repeating: 0, count: Self.wavePoints)
        var amp: Float = 0
        for j in 0..<Self.wavePoints {
            let c = start + j * 2
            func at(_ i: Int) -> Float { x[min(max(i, 0), need - 1)] }
            let v = (at(c - 2) + 2 * at(c - 1) + 3 * at(c) + 2 * at(c + 1) + at(c + 2)) / 9
            wave[j] = v
            amp = max(amp, abs(v))
        }
        peakAmp = autoGain ? max(amp, peakAmp * 0.995, 0.01) : 1
        return (spectrum, wave.map { min(max($0 / peakAmp, -1), 1) })
    }
}

extension AudioReactive {
    /// 描くときの「今」までの音（古い方から count 個）。届くかたまりの間も、時間に合わせて少しずつ進める
    func scopeSamples(count: Int, now: Double = CACurrentMediaTime()) -> (samples: [Float], rate: Double, autoGain: Bool)? {
        let auto = autoGain
        return scopeLock.withLock {
            guard scopeWritten > 0 else { return nil }
            let N = scopeRing.count
            // 最後のかたまりの分だけ遅らせて、届いてからの時間で前へ進める
            let ahead = min(Int((now - scopeLastTime) * scopeRate), scopeLastCount)
            let end = scopeWritten - scopeLastCount + max(ahead, 0)
            let c = min(count, N - scopeLastCount)
            var out = [Float](repeating: 0, count: count)
            for k in 0..<c {
                let i = end - c + k
                if i >= 0 && i < scopeWritten { out[count - c + k] = scopeRing[i % N] }
            }
            // しばらく音が来なければ、だんだん無音に
            if now - scopeLastTime > 0.5 { return (out.map { $0 * 0 }, scopeRate, auto) }
            return (out, scopeRate, auto)
        }
    }
}

private let scopeShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VO { float4 pos [[position]]; float2 uv; };
vertex VO sc_v(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o; o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0); o.uv = c; return o;
}
// a = 形, 帯の数, 高さ, 太さ / b = 色の付け方, 上下対称, 明るさ, 円の大きさ / c = 縦横比, 波形の点の数
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
// 波形の点 f（0〜n-1）の値を、なめらかな曲線（Catmull-Rom）で。dv に傾き（点 1 つあたり）
static float waveAt(constant float* wv, float f, int n, thread float& dv) {
    int i = clamp(int(floor(f)), 0, n - 1);
    float p0 = wv[max(i - 1, 0)], p1 = wv[i], p2 = wv[min(i + 1, n - 1)], p3 = wv[min(i + 2, n - 1)];
    float t = fract(f), t2 = t * t, t3 = t2 * t;
    dv = 0.5 * ((-p0 + p2) + 2.0 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t + 3.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t2);
    return 0.5 * (2.0 * p1 + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3);
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
        // 波形：前半の点を使う。点のあいだは曲線でつなぎ、線の太さは傾きを入れて見た目の太さにする
        int nw = max(int(u.c.y + 0.5), 4);
        float span = float(nw / 2 - 1);
        float dv;
        float s = waveAt(wv, saturate(uv.x) * span, nw, dv);
        float y = 0.5 - s * 0.5 * hgt;
        float w = 0.002 + th * 0.015;
        float dydx = dv * span * 0.5 * hgt;
        float fac = sqrt(1.0 + pow(dydx / max(A, 1e-3), 2.0));
        float aa = fwidth(uv.y) * 1.5;
        k = 1.0 - smoothstep(w * fac, (w + aa) * fac, abs(uv.y - y));
        if (mirror) k = max(k, 1.0 - smoothstep(w * fac, (w + aa) * fac, abs(uv.y - (1.0 - y))));
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
            // 一周でつながるように：後半（a で 0→1）と前半を、重みを変えながら足す（0 と 1 で同じ点になる）
            int nw = max(int(u.c.y + 0.5), 4);
            float L = float(nw / 2);
            float a = ang, d0, d1;
            float s0 = waveAt(wv, L + a * (L - 1.0), nw, d0);
            float s1 = waveAt(wv, a * (L - 1.0), nw, d1);
            float wt = smoothstep(0.0, 1.0, a);
            float s = mix(s0, s1, wt) * (1.0 + 0.5 * wt * (1.0 - wt));
            float target = R + s * 0.12 * hgt;
            float w = 0.002 + th * 0.012;
            k = 1.0 - smoothstep(w, w + fwidth(r) * 1.5, abs(r - target));
            colorY = abs(s);
        }
    }
    int cm = int(u.b.x + 0.5);
    // 虹色：円は一周で色もつながるように、色相を一回りさせる
    float3 col = cm == 1 ? scHue(colorX * (shape >= 3 && !mirror ? 1.0 : 0.8)) : (cm == 2 ? scPal(u.pal, u.palCount, saturate(colorY)) : u.color.rgb);
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
    private var wave = [Float](repeating: 0, count: SpectrumAnalyzer.wavePoints)
    private let analyzer = SpectrumAnalyzer()
    /// テスト用：音の代わりに使う値
    static var testScope: (spectrum: [Float], wave: [Float])?

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        let nW = SpectrumAnalyzer.wavePoints
        var sp: [Float], wv: [Float]
        if let t = Self.testScope {
            sp = t.spectrum
            // テストの波形は長さが違ってもよい（引き伸ばして使う）
            wv = (0..<nW).map { j in t.wave.isEmpty ? 0 : t.wave[j * t.wave.count / nW] }
        } else if let s = AudioReactive.shared.scopeSamples(count: SpectrumAnalyzer.needSamples) {
            (sp, wv) = analyzer.process(s.samples, sampleRate: s.rate, autoGain: s.autoGain)
        } else {
            sp = []; wv = []
        }
        if sp.count != SpectrumAnalyzer.bands { sp = [Float](repeating: 0, count: SpectrumAnalyzer.bands) }
        if wv.count != nW { wv = [Float](repeating: 0, count: nW) }
        let smooth = Double(min(max(v(6), 0), 1))
        let frames = max(dt, 1.0 / 120) * 60
        // なめらかさ：帯は、上がるのは速め・下がるのはゆっくり。波形は前の形へ少しずつ寄せる
        let fall = Float(pow(0.02 + 0.97 * smooth, frames * 0.15))
        let rise = Float(1 - pow(0.75 * smooth, frames))
        let follow = Float(1 - pow(0.8 * smooth, frames))
        let first = dt <= 0
        for i in bands.indices {
            bands[i] = first ? sp[i] : (sp[i] > bands[i] ? bands[i] + (sp[i] - bands[i]) * rise : max(sp[i], bands[i] * fall))
        }
        for i in wave.indices { wave[i] = first ? wv[i] : wave[i] + (wv[i] - wave[i]) * follow }
        var u = ScopeUniforms()
        u.a = SIMD4(v(0).rounded(), v(1).rounded(), v(2), v(3))
        u.b = SIMD4(v(4).rounded(), v(5), v(7), v(8))
        u.c = SIMD4(Float(dst.width) / Float(max(dst.height, 1)), Float(nW), 0, 0)
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
        wave.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}
