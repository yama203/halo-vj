import AppKit
import Combine
import Metal
import QuartzCore
import NDIShim
import SwiftUI

// NDI：同じネットワークの別の Mac・PC と映像をやりとりする。
// NDI の本体（libndi）はアプリに入れず、入っている NDI ランタイム（NDI Tools・NDI SDK・Resolume などに入っているもの）を実行時に読み込む。
// NDI® is a registered trademark of Vizrt NDI AB.

enum NDIRuntime {
    /// NDI ランタイムが読めるか（初めて呼んだときに探す）
    static var available: Bool { ndi_load() == 1 }
    static var libraryPath: String { String(cString: ndi_lib_path()) }
    static var version: String { String(cString: ndi_version_string()) }
    /// アプリに同梱した NDI を使っているか
    static var isBundled: Bool { libraryPath.contains(".app/Contents/Frameworks/") }
    /// どの NDI を使っているか（画面の表示用）
    static var sourceLabel: String {
        guard available else { return "" }
        if isBundled { return "アプリに同梱した NDI" }
        let p = libraryPath
        if p.contains("Resolume") { return "Resolume に入っている NDI" }
        if p.contains("NDI SDK") { return "NDI SDK" }
        return p
    }
}

// MARK: - 出す

/// コンポジション（四隅の調整の前・パッドのエフェクト込み）を NDI で出す
final class NDIOutput: ObservableObject {
    static let shared = NDIOutput()

    @Published var enabled = false { didSet { if oldValue != enabled { apply(); save() } } }
    @Published var name = "Halo VJ" { didSet { if oldValue != name { apply(); save() } } }
    /// 受け取っている相手の数（画面の表示用）
    @Published private(set) var connections = 0
    /// NDI ランタイムが見つからなかった
    @Published private(set) var missingRuntime = false
    var forTests = false

    private let lock = NSLock()
    private var sender: UnsafeMutableRawPointer?
    private var busy = false
    private var tex: MTLTexture?
    private var bytes: [UInt8] = []
    private var timer: Timer?
    private let queue = DispatchQueue(label: "halo.ndi.send", qos: .userInteractive)
    /// 送った枚数（テスト用）
    private(set) var sentFrames = 0

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "ndi.out")
        if let n = d.string(forKey: "ndi.name"), !n.isEmpty { name = n }
    }

    func startIfNeeded() { if enabled { apply() } }

    var isOn: Bool { lock.withLock { sender != nil } }

    private func save() {
        guard !forTests else { return }
        UserDefaults.standard.set(enabled, forKey: "ndi.out")
        UserDefaults.standard.set(name, forKey: "ndi.name")
    }

    private func apply() {
        let old = lock.withLock { () -> UnsafeMutableRawPointer? in
            let s = sender; sender = nil; return s
        }
        // 送っている途中かもしれないので、送る列の後ろで閉じる
        if let old { queue.async { ndi_send_destroy(old) } }
        timer?.invalidate(); timer = nil
        connections = 0
        guard enabled else { missingRuntime = false; return }
        guard NDIRuntime.available else { missingRuntime = true; return }
        missingRuntime = false
        let s = name.withCString { ndi_send_create($0) }
        lock.withLock { sender = s; busy = false }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let s = self.lock.withLock({ self.sender }) else { return }
            self.queue.async {
                let n = Int(ndi_send_connections(s, 0))
                DispatchQueue.main.async { if self.connections != n { self.connections = n } }
            }
        }
    }

    /// 合成の絵を送る（描画スレッド）。前の 1 枚を送り終わっていなければ、この 1 枚は飛ばす
    func publish(_ composite: MTLTexture, cb: MTLCommandBuffer) {
        let w = composite.width, h = composite.height
        guard let s = lock.withLock({ () -> UnsafeMutableRawPointer? in
            guard let s = sender, !busy else { return nil }
            busy = true
            return s
        }) else { return }
        if tex == nil || tex!.width != w || tex!.height != h {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .shared
            tex = MetalContext.shared.device.makeTexture(descriptor: td)
        }
        guard let tex else { lock.withLock { busy = false }; return }
        let r = LifeRenderer.shared
        r.fullPass(into: tex, cb: cb) { enc in
            enc.setRenderPipelineState(r.copy)
            enc.setFragmentTexture(composite, index: 0)
        }
        cb.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                let stride = w * 4
                if self.bytes.count != stride * h { self.bytes = [UInt8](repeating: 0, count: stride * h) }
                self.bytes.withUnsafeMutableBytes { p in
                    tex.getBytes(p.baseAddress!, bytesPerRow: stride, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                    // 合成の絵は色に不透明度が掛かっているので、黒の上に置いたのと同じ。不透明（BGRX）で送る
                    ndi_send_bgrx(s, Int32(w), Int32(h), Int32(stride), p.baseAddress!.assumingMemoryBound(to: UInt8.self), 60, 1)
                }
                self.lock.withLock { self.busy = false; self.sentFrames += 1 }
            }
        }
    }
}

// MARK: - 探す

/// ネットワークの NDI の送り手を探す（アプリ全体で 1 つ）
final class NDIFinder {
    static let shared = NDIFinder()
    private let lock = NSLock()
    private var finder: UnsafeMutableRawPointer?

    /// 今見つかっている送り手の名前（「機械の名前 (送り手の名前)」）。自分の出力は入れない
    func sources(includeSelf: Bool = false) -> [String] {
        let all: [String] = lock.withLock {
            if finder == nil { finder = ndi_find_create() }
            guard let finder else { return [] }
            var buf = [CChar](repeating: 0, count: 65536)
            _ = ndi_find_sources(finder, &buf, Int32(buf.count))
            let s = String(cString: buf)
            return s.isEmpty ? [] : s.components(separatedBy: "\n")
        }
        guard !includeSelf, NDIOutput.shared.isOn else { return all }
        // 自分の出力は入れない（自分を映すと無限に重なる）
        let mine = "(\(NDIOutput.shared.name))"
        return all.filter { !$0.hasSuffix(mine) }
    }
}

// MARK: - 受け取る

/// NDI の送り手 1 つから受け取る（裏のスレッドで待って、届いた絵を GPU の絵にする）
final class NDIReceiver {
    let source: String
    private let lock = NSLock()
    private var latest: MTLTexture?
    private var pool: [MTLTexture] = []
    private var next = 0
    private var poolAlpha = true
    private var running = true
    private(set) var finished = false
    var used = CACurrentMediaTime()
    /// 受け取った枚数（テスト用）
    private(set) var frames = 0

    init(source: String) {
        self.source = source
        let t = Thread { [weak self] in self?.loop() }
        t.name = "halo.ndi.recv"
        t.qualityOfService = .userInteractive
        t.start()
    }

    var frame: MTLTexture? { lock.withLock { used = CACurrentMediaTime(); return latest } }

    func stop() { lock.withLock { running = false } }

    private func loop() {
        let r = source.withCString { ndi_recv_create($0) }
        defer {
            if let r { ndi_recv_destroy(r) }
            lock.withLock { finished = true; latest = nil; pool = [] }
        }
        guard let r else { return }
        var v = ndi_video_t()
        while true {
            let (go, idle) = lock.withLock { (running, CACurrentMediaTime() - used) }
            // しばらく使われていなければやめる
            if !go || idle > 10 { break }
            guard ndi_recv_capture(r, 100, &v) == 1 else { continue }
            upload(v)
            ndi_recv_free(r, &v)
        }
    }

    private func upload(_ v: ndi_video_t) {
        let w = Int(v.width), h = Int(v.height)
        guard w > 0, h > 0, let data = v.data else { return }
        let alpha = v.has_alpha != 0
        // 3 枚を順に使う（GPU が読んでいる絵には書かない）
        if pool.first.map({ $0.width != w || $0.height != h }) ?? true || poolAlpha != alpha {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.shaderRead]
            td.storageMode = .shared
            // BGRX のときは、不透明度を 1 として読む
            if !alpha { td.swizzle = MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .one) }
            pool = (0..<3).compactMap { _ in MetalContext.shared.device.makeTexture(descriptor: td) }
            poolAlpha = alpha
            next = 0
        }
        guard pool.count == 3 else { return }
        let t = pool[next]
        next = (next + 1) % 3
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: Int(v.stride))
        lock.withLock { latest = t; frames += 1 }
    }
}

/// NDI の受け取り口（送り手ごとに 1 つ。しばらく使わなければ閉じる）
final class NDIInputs {
    static let shared = NDIInputs()
    private let lock = NSLock()
    private var receivers: [String: NDIReceiver] = [:]

    /// 送り手の今の絵（まだ無ければ nil）。どのスレッドからでも
    func frame(_ source: String) -> MTLTexture? {
        guard NDIRuntime.available else { return nil }
        return lock.withLock {
            receivers = receivers.filter { !$0.value.finished }
            if receivers[source] == nil { receivers[source] = NDIReceiver(source: source) }
            return receivers[source]?.frame
        }
    }

    func receiver(_ source: String) -> NDIReceiver? { lock.withLock { receivers[source] } }

    func stopAll() {
        lock.withLock { for r in receivers.values { r.stop() }; receivers = [:] }
    }
}

extension SyphonDraw {
    /// NDI の絵を dst に置く（無ければ透明）
    func renderNDI(_ e: Effect, into dst: MTLTexture, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let src = e.text.isEmpty ? nil : NDIInputs.shared.frame(e.text)
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        // NDI の BGRA は色に不透明度が掛かっていないので掛ける
        draw(src, fit: v(0).rounded(), opacity: v(1), mirror: false, premultiply: true, into: dst, cb: cb)
    }
}

// MARK: - 画面

/// ジェネレーター「NDI から」の、受け取る映像の選び方
struct NDISourcePicker: View {
    @Binding var effect: Effect
    @State private var sources: [String] = []
    @State private var available = true
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("映像").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $effect.text) {
                    Text("（選ぶ）").tag("")
                    ForEach(sources, id: \.self) { s in Text(s).tag(s) }
                    if !effect.text.isEmpty && !sources.contains(effect.text) {
                        Text(effect.text + "（今は見つからない）").tag(effect.text)
                    }
                }
                .labelsHidden()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("NDI で出している映像の一覧を更新")
            }
            if !available {
                NDIMissingNote()
            } else if sources.isEmpty {
                Text("探しています…（同じネットワークで NDI を出しているものが出てきます）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            NDITrademarkNote()
        }
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        available = NDIRuntime.available
        if available { sources = NDIFinder.shared.sources() }
    }
}

/// NDI の商標の表記と ndi.video へのリンク（NDI を使う・選ぶ所に置く決まり）
struct NDITrademarkNote: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("NDI® is a registered trademark of Vizrt NDI AB.")
            Link("ndi.video", destination: URL(string: "https://ndi.video")!)
        }
        .font(.system(size: 10)).foregroundStyle(.tertiary)
    }
}

struct NDIMissingNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("NDI ランタイムが見つかりません。NDI Tools（ndi.video）を入れると使えます")
                .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            Link("ndi.video を開く", destination: URL(string: "https://ndi.video/tools/")!).font(.system(size: 11))
        }
    }
}

/// 「連携」の窓の NDI の欄
struct NDISettingsSection: View {
    @ObservedObject private var ndi = NDIOutput.shared

    var body: some View {
        GroupBox("映像（NDI）") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("コンポジションを NDI で出す", isOn: $ndi.enabled)
                    Spacer()
                    if ndi.enabled && !ndi.missingRuntime {
                        Label(ndi.connections > 0 ? "\(ndi.connections) か所で受け取られています" : "待っています",
                              systemImage: ndi.connections > 0 ? "dot.radiowaves.left.and.right" : "circle.dotted")
                            .font(.system(size: 11)).foregroundStyle(ndi.connections > 0 ? .green : .secondary)
                    }
                }
                HStack {
                    Text("名前").font(.system(size: 12))
                    TextField("Halo VJ", text: $ndi.name).frame(width: 180)
                }
                if ndi.missingRuntime { NDIMissingNote() }
                Text("同じネットワークの別の Mac・PC（TouchDesigner の NDI In TOP・Resolume・OBS など）で受け取れる。ほかの NDI を受け取るには、ジェネレーター「NDI から」を枠に置く")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if NDIRuntime.available {
                    Text("使っている NDI：\(NDIRuntime.sourceLabel)（\(NDIRuntime.version.components(separatedBy: " ").last ?? "")）")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                NDITrademarkNote()
            }
            .padding(4)
        }
        .onAppear { _ = NDIRuntime.available }
    }
}
