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
    float k = saturate(c.a * u.opacity * cover);
    if (u.blend == 3) return float4(mix(float3(1.0), c.rgb, k), 1.0);
    return float4(c.rgb * k, k);
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
}

final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let layerPipelines: [BlendMode: MTLRenderPipelineState]
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
            case .add:      // 下 + 上
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

/// レイヤーを重ねて1枚の画像にする（コーナーピンをかける前の画）
final class Compositor {
    private let ctx = MetalContext.shared
    private(set) var target: MTLTexture?
    /// セルフテストで中身を読むときは .shared にする
    var storageMode: MTLStorageMode = .private

    /// layers は奥 → 手前の順
    func composite(_ layers: [LayerDraw], width: Int, height: Int, cb: MTLCommandBuffer) -> MTLTexture? {
        let w = max(width, 1), h = max(height, 1)
        if target?.width != w || target?.height != h {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = storageMode
            target = ctx.device.makeTexture(descriptor: td)
        }
        guard let target else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setFragmentSamplerState(ctx.sampler, index: 0)
        for l in layers {
            guard let p = ctx.layerPipelines[l.blend] else { continue }
            let fw = Float(w), fh = Float(h)
            // UV → ピクセル（出力いっぱい）→ クリップ → レイヤー → コンポジション
            let uvToPx = simd_float3x3(diagonal: SIMD3(fw, fh, 1))
            let m = l.compTransform.matrix(width: fw, height: fh)
                * l.layerTransform.matrix(width: fw, height: fh)
                * l.transform.matrix(width: fw, height: fh)
                * uvToPx
            var u = LayerUniforms(inv: m.inverse, opacity: l.opacity * l.transform.opacity,
                                  blend: Int32(l.blend.rawValue))
            enc.setRenderPipelineState(p)
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentTexture(l.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        return target
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
        let draws = params.testPattern ? [] : engine.layerDraws()
        let kinds = Set(current.map { $0.2 })
        let clipDraws = kinds.contains(.clipPreview) ? engine.previewDraws() : []
        let layerDraws = kinds.contains(.layer) ? engine.layerPreviewDraws() : []
        let plain = RenderParams(homographyInverse: matrix_identity_float3x3, testPattern: false, master: 1)
        for (id, layer, kind) in current {
            let comp = compositors[id] ?? Compositor()
            compositors[id] = comp
            switch kind {
            case .output:
                render(layer, compositor: comp, draws: draws, params: params)
            case .composition:
                var p = plain
                p.master = params.master
                render(layer, compositor: comp, draws: params.testPattern ? engine.layerDraws() : draws, params: p)
            case .layer:
                render(layer, compositor: comp, draws: layerDraws, params: plain)
            case .clipPreview:
                render(layer, compositor: comp, draws: clipDraws, params: plain)
            }
        }
    }

    private func render(_ layer: CAMetalLayer, compositor: Compositor, draws: [LayerDraw],
                        params: RenderParams) {
        guard let drawable = layer.nextDrawable(), let cb = ctx.queue.makeCommandBuffer() else { return }
        let w = drawable.texture.width, h = drawable.texture.height
        let composite = draws.isEmpty ? nil : compositor.composite(draws, width: w, height: h, cb: cb)

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
        cb.addCompletedHandler { _ in _ = draws }
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
