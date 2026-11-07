import AppKit
import Metal
import QuartzCore
import Syphon
import SwiftUI

// ほかのアプリ（TouchDesigner など）とのやりとり：映像は Syphon、値は OSC（OSC.swift）。

// MARK: - Syphon 出力

/// コンポジション（四隅の調整の前・パッドのエフェクト込み）を Syphon で公開する
final class SyphonOutput: ObservableObject {
    static let shared = SyphonOutput()

    @Published var enabled = false { didSet { if oldValue != enabled { apply(); save() } } }
    @Published var name = "Halo VJ" { didSet { if oldValue != name { apply(); save() } } }
    /// 見ているアプリがあるか（画面の表示用）
    @Published private(set) var hasClients = false
    var forTests = false

    private let lock = NSLock()
    private var server: SyphonMetalServer?
    private var timer: Timer?

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "syphon.out")
        if let n = d.string(forKey: "syphon.name"), !n.isEmpty { name = n }
    }

    func startIfNeeded() { apply() }

    private func save() {
        guard !forTests else { return }
        UserDefaults.standard.set(enabled, forKey: "syphon.out")
        UserDefaults.standard.set(name, forKey: "syphon.name")
    }

    private func apply() {
        let old = lock.withLock { () -> SyphonMetalServer? in
            let s = server; server = nil; return s
        }
        old?.stop()
        timer?.invalidate(); timer = nil
        hasClients = false
        guard enabled else { return }
        let s = SyphonMetalServer(name: name, device: MetalContext.shared.device, options: nil)
        lock.withLock { server = s }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let h = self.lock.withLock { self.server?.hasClients ?? false }
            if h != self.hasClients { self.hasClients = h }
        }
    }

    /// 公開する大きさ（描画スレッドが合成の大きさを決めるのに使う。出していなければ nil）
    func activeSize(outputSize: (Int, Int)?, aspect: Double) -> (Int, Int)? {
        guard lock.withLock({ server != nil }) else { return nil }
        if let o = outputSize { return o }
        let h = 1080
        return (max(Int((Double(h) * max(aspect, 0.1)).rounded()) & ~1, 2), h)
    }

    /// 合成の絵を公開する（描画スレッド）
    func publish(_ texture: MTLTexture, cb: MTLCommandBuffer) {
        guard let s = lock.withLock({ server }) else { return }
        s.publishFrameTexture(texture, on: cb, imageRegion: NSRect(x: 0, y: 0, width: texture.width, height: texture.height),
                              flipped: false)
    }
}

// MARK: - Syphon 入力

/// Syphon で公開されている映像（アプリ名とサーバー名で覚える。UUID は起動のたびに変わるので）
struct SyphonSource: Hashable, Identifiable {
    let app: String
    let name: String
    var id: String { Self.key(app: app, name: name) }
    var label: String { name.isEmpty ? app : "\(app) – \(name)" }
    static func key(app: String, name: String) -> String { app + "\n" + name }
    /// Syphon が自分のアプリに付ける名前（.app から起動すると「Halo VJ」、そうでなければ実行ファイルの名前）
    static var selfAppName: String { NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName }

    static func list() -> [SyphonSource] {
        let servers = SyphonServerDirectory.shared().servers
        return servers.compactMap { d in
            let app = d[SyphonServerDescriptionAppNameKey] as? String ?? ""
            let name = d[SyphonServerDescriptionNameKey] as? String ?? ""
            // 自分の出力は入れない（自分を映すと無限に重なる）
            if (app == selfAppName || app == ProcessInfo.processInfo.processName) && name == SyphonOutput.shared.name { return nil }
            return SyphonSource(app: app, name: name)
        }
    }
}

/// Syphon の映像を受け取る（受け取り口はアプリ全体で、サーバーごとに 1 つ）
final class SyphonInputs {
    static let shared = SyphonInputs()
    private let lock = NSLock()
    private var clients: [String: (client: SyphonMetalClient, last: MTLTexture?, used: Double)] = [:]

    /// key（アプリ名＋サーバー名）の今の絵（無ければ nil）。どのスレッドからでも
    func frame(_ key: String) -> MTLTexture? {
        let now = CACurrentMediaTime()
        return lock.withLock {
            if clients[key] == nil {
                // しばらく使っていない受け取り口は閉じる
                for (k, v) in clients where now - v.used > 10 { v.client.stop(); clients[k] = nil }
                let parts = key.components(separatedBy: "\n")
                guard parts.count == 2,
                      let desc = SyphonServerDirectory.shared().servers(matchingName: parts[1], appName: parts[0]).first
                else { return nil }
                let c = SyphonMetalClient(serverDescription: desc, device: MetalContext.shared.device, options: nil,
                                          newFrameHandler: nil)
                clients[key] = (c, nil, now)
            }
            guard var e = clients[key] else { return nil }
            if !e.client.isValid {
                e.client.stop()
                clients[key] = nil
                return e.last
            }
            if let t = e.client.newFrameImage() { e.last = t }
            e.used = now
            clients[key] = e
            return e.last
        }
    }
}

private let syphonDrawSource = """
#include <metal_stdlib>
using namespace metal;
struct VO { float4 pos [[position]]; float2 uv; };
vertex VO sy_v(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o; o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0); o.uv = c; return o;
}
// a = 合わせ方（0 収める / 1 いっぱい / 2 引き伸ばす）, 受け取った絵の縦横比, 出す絵の縦横比, 不透明度
// b = 左右反転, 色に不透明度を掛けるか
struct SYU { float4 a; float4 b; };
fragment float4 sy_f(VO in [[stage_in]], constant SYU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float4 a = u.a;
    float2 uv = in.uv;
    if (u.b.x > 0.5) uv.x = 1.0 - uv.x;
    int m = int(a.x + 0.5);
    float r = a.y / max(a.z, 1e-4);
    if (m == 0) { if (r > 1.0) uv.y = (uv.y - 0.5) * r + 0.5; else uv.x = (uv.x - 0.5) / r + 0.5; }
    else if (m == 1) { if (r > 1.0) uv.x = (uv.x - 0.5) / r + 0.5; else uv.y = (uv.y - 0.5) * r + 0.5; }
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0.0);
    float4 c = t.sample(s, uv);
    // Syphon の絵は色に不透明度が掛かっていないので掛ける
    if (u.b.y > 0.5) c.rgb *= c.a;
    return c * a.w;
}
"""

final class SyphonDraw {
    static let shared = SyphonDraw()
    let pipe: MTLRenderPipelineState
    private init() {
        let dev = MetalContext.shared.device
        let lib = try! dev.makeLibrary(source: syphonDrawSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "sy_v")
        d.fragmentFunction = lib.makeFunction(name: "sy_f")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipe = try! dev.makeRenderPipelineState(descriptor: d)
    }

    /// Syphon の絵を dst に置く（無ければ透明）
    func render(_ e: Effect, into dst: MTLTexture, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let src = e.text.isEmpty ? nil : SyphonInputs.shared.frame(e.text)
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        draw(src, fit: v(0).rounded(), opacity: v(1), mirror: false, premultiply: true, into: dst, cb: cb)
    }

    /// カメラの絵を dst に置く（無ければ透明）
    func renderCamera(_ e: Effect, into dst: MTLTexture, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let f = e.text.isEmpty ? nil : CameraInputs.shared.frame(e.text)
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        draw(f?.0, fit: v(0).rounded(), opacity: v(2), mirror: v(1) > 0.5, premultiply: false, into: dst, cb: cb)
        // カメラの絵の入れ物は、GPU が使い終わるまで持っておく
        if let keep = f?.1 { cb.addCompletedHandler { _ in _ = keep } }
    }

    /// 受け取った絵（無ければ透明）を、合わせ方・反転・濃さで dst に置く
    func draw(_ src: MTLTexture?, fit: Float, opacity: Float, mirror: Bool, premultiply: Bool, into dst: MTLTexture,
              cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        if let src {
            var u = (SIMD4(fit, Float(src.width) / Float(max(src.height, 1)), Float(dst.width) / Float(max(dst.height, 1)), opacity),
                     SIMD4<Float>(mirror ? 1 : 0, premultiply ? 1 : 0, 0, 0))
            enc.setRenderPipelineState(pipe)
            enc.setFragmentBytes(&u, length: 32, index: 0)
            enc.setFragmentTexture(src, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // GPU が使い終わるまで絵を持っておく
            cb.addCompletedHandler { _ in _ = src }
        }
        enc.endEncoding()
    }
}

/// ジェネレーター「Syphon から」の、受け取る映像の選び方
struct SyphonSourcePicker: View {
    @Binding var effect: Effect
    @State private var sources: [SyphonSource] = SyphonSource.list()

    var body: some View {
        HStack(spacing: 8) {
            Text("映像").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: $effect.text) {
                Text("（選ぶ）").tag("")
                ForEach(sources) { s in Text(s.label).tag(s.id) }
                if !effect.text.isEmpty && !sources.contains(where: { $0.id == effect.text }) {
                    Text(effect.text.replacingOccurrences(of: "\n", with: " – ") + "（今は見つからない）").tag(effect.text)
                }
            }
            .labelsHidden()
            Button { sources = SyphonSource.list() } label: { Image(systemName: "arrow.clockwise") }
                .help("Syphon で公開されている映像の一覧を更新")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.SyphonServerAnnounce)) { _ in
            sources = SyphonSource.list()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.SyphonServerRetire)) { _ in
            sources = SyphonSource.list()
        }
    }
}
