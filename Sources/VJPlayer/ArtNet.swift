import AppKit
import Metal
import SwiftUI

// 照明（Art-Net / DMX）：コンポジションの色で、照明・LED テープを光らせる。
// 灯体ごとに、コンポジションのどこの色を（点、または線の上に並んだ点）、どのユニバースの何チャンネル目から送るかを決める。
// コンポジションを小さく（128×72）縮めて読み、1 秒に 40 回、Art-Net（UDP 6454）で送る。プロジェクトに保存される。

struct DMXFixture: Codable, Identifiable, Equatable {
    enum Kind: Int, Codable, CaseIterable, Identifiable {
        case rgb, rgbw, dimmer, line
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .rgb: "RGB（1 点）"
            case .rgbw: "RGBW（1 点）"
            case .dimmer: "明るさだけ（1 点）"
            case .line: "LED テープ（線・RGB）"
            }
        }
        var channelsPerPixel: Int { self == .rgbw ? 4 : (self == .dimmer ? 1 : 3) }
    }
    var id = UUID()
    var name = "灯体"
    var kind = Kind.rgb
    /// ユニバース（0 から）
    var universe = 0
    /// 先頭のチャンネル（1〜512）
    var channel = 1
    /// LED テープの点の数
    var pixels = 30
    /// 取る所：コンポジションの左上を 0,0、右下を 1,1（線は始まりと終わり）
    var start: [Double] = [0.5, 0.5]
    var end: [Double] = [0.9, 0.5]

    var channelCount: Int { kind.channelsPerPixel * (kind == .line ? max(pixels, 1) : 1) }

    init() {}

    /// 読むとき：足りない値は初めの値に、取る所はかならず 2 つの数にする（壊れたファイルでも落ちないように）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DMXFixture()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? d.kind
        universe = try c.decodeIfPresent(Int.self, forKey: .universe) ?? d.universe
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? d.channel
        pixels = min(max(try c.decodeIfPresent(Int.self, forKey: .pixels) ?? d.pixels, 1), 4096)
        func two(_ a: [Double]?, _ def: [Double]) -> [Double] {
            guard let a else { return def }
            return [a.count > 0 ? a[0] : def[0], a.count > 1 ? a[1] : def[1]]
        }
        start = two(try c.decodeIfPresent([Double].self, forKey: .start), d.start)
        end = two(try c.decodeIfPresent([Double].self, forKey: .end), d.end)
    }
}

struct DMXMap: Codable, Equatable {
    var fixtures: [DMXFixture] = []
    var brightness = 1.0
    var gamma = 2.2

    /// 小さく縮めた絵（BGRA、w × h）から、ユニバースごとの 512 チャンネルを作る
    func universes(pixels px: [UInt8], width w: Int, height h: Int) -> [Int: [UInt8]] {
        var out: [Int: [UInt8]] = [:]
        func color(_ x: Double, _ y: Double) -> (Double, Double, Double) {
            guard w > 0, h > 0, px.count >= w * h * 4 else { return (0, 0, 0) }
            let ix = min(max(Int((x * Double(w)).rounded(.down)), 0), w - 1), iy = min(max(Int((y * Double(h)).rounded(.down)), 0), h - 1)
            let i = (iy * w + ix) * 4
            return (Double(px[i + 2]) / 255, Double(px[i + 1]) / 255, Double(px[i]) / 255)
        }
        func level(_ v: Double) -> UInt8 { UInt8(min(max(pow(min(max(v, 0), 1), gamma) * brightness * 255, 0), 255).rounded()) }
        // 取る所（壊れたファイルで数が足りなくても落ちないように）
        func pt(_ a: [Double]) -> (Double, Double) { (a.count > 0 ? a[0] : 0.5, a.count > 1 ? a[1] : 0.5) }
        for f in fixtures {
            let s0 = pt(f.start), e0 = pt(f.end)
            var ch = max(f.channel, 1) - 1
            var uni = max(f.universe, 0)
            let n = f.kind == .line ? max(f.pixels, 1) : 1
            for k in 0..<n {
                let t = n > 1 ? Double(k) / Double(n - 1) : 0
                let x = f.kind == .line ? s0.0 + (e0.0 - s0.0) * t : s0.0
                let y = f.kind == .line ? s0.1 + (e0.1 - s0.1) * t : s0.1
                let (r, g, b) = color(x, y)
                let vals: [UInt8]
                switch f.kind {
                case .rgb, .line: vals = [level(r), level(g), level(b)]
                case .rgbw:
                    // 白：3 色のうち一番小さい分を白で出す
                    let wv = min(r, g, b)
                    vals = [level(r - wv), level(g - wv), level(b - wv), level(wv)]
                case .dimmer: vals = [level(0.2126 * r + 0.7152 * g + 0.0722 * b)]
                }
                for v in vals {
                    // 512 を超えたら次のユニバースへ
                    if ch >= 512 { ch = 0; uni += 1 }
                    if out[uni] == nil { out[uni] = [UInt8](repeating: 0, count: 512) }
                    out[uni]![ch] = v
                    ch += 1
                }
            }
        }
        return out
    }
}

/// Art-Net の送り（アプリ全体で 1 つ）
final class ArtNetOutput: ObservableObject {
    static let shared = ArtNetOutput()
    @Published var enabled = false { didSet { if oldValue != enabled { save(); restart() } } }
    @Published var host = "255.255.255.255" { didSet { if oldValue != host { save(); lock.withLock { sendHost = host } } } }
    @Published private(set) var status = ""
    var port: UInt16 = 6454
    var forTests = false

    private let queue = DispatchQueue(label: "VJPlayer.artnet")
    private let lock = NSLock()
    private var latest: (px: [UInt8], w: Int, h: Int)?
    private var map = DMXMap()
    private var timer: DispatchSourceTimer?
    /// 送り先（送るキューで読む写し。lock の中で）
    private var sendHost = "255.255.255.255"
    /// ここから下は送るキューの中だけで触る
    private var sock: Int32 = -1
    private var seq: UInt8 = 0

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "artnet.enabled")
        if let h = d.string(forKey: "artnet.host"), !h.isEmpty { host = h }
        sendHost = host
    }

    private func save() {
        guard !forTests else { return }
        UserDefaults.standard.set(enabled, forKey: "artnet.enabled")
        UserDefaults.standard.set(host, forKey: "artnet.host")
    }

    func startIfNeeded() { restart() }

    /// 描画スレッドから：小さく縮めた今の絵
    func update(pixels: [UInt8], width: Int, height: Int) { lock.withLock { latest = (pixels, width, height) } }
    func setMap(_ m: DMXMap) { lock.withLock { map = m } }
    var isOn: Bool { lock.withLock { timer != nil } }

    private func restart() {
        let old = lock.withLock { () -> DispatchSourceTimer? in let t = timer; timer = nil; return t }
        old?.cancel()
        let on = enabled
        // 送り口は送るキューの中で閉じる・開く（送っている最中に閉じないように）
        queue.sync {
            if sock >= 0 { close(sock); sock = -1 }
            guard on else { return }
            sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            var one: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        guard on else { status = "オフ"; return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 40)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        lock.withLock { timer = t }
        status = "送っています（\(host)）"
    }

    private func tick() {
        guard let (px, w, h) = lock.withLock({ latest }) else { return }
        let m = lock.withLock { map }
        let unis = m.universes(pixels: px, width: w, height: h)
        seq = seq == 255 ? 1 : seq + 1
        for (u, data) in unis.sorted(by: { $0.key < $1.key }) { send(Self.packet(universe: u, data: data, sequence: seq)) }
    }

    func send(_ d: [UInt8]) {
        guard sock >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let h = lock.withLock { sendHost }
        guard inet_pton(AF_INET, h, &addr.sin_addr) == 1 else { return }
        _ = d.withUnsafeBytes { b in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, b.baseAddress, d.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// ArtDmx のパケット
    static func packet(universe: Int, data: [UInt8], sequence: UInt8) -> [UInt8] {
        var d = Array("Art-Net".utf8) + [0]
        d += [0x00, 0x50]          // OpDmx（下位から）
        d += [0x00, 14]            // プロトコルの版
        d += [sequence, 0]         // 順番・物理ポート
        d += [UInt8(universe & 0xFF), UInt8((universe >> 8) & 0x7F)]
        var body = Array(data.prefix(512))
        if body.count % 2 == 1 { body.append(0) }
        if body.isEmpty { body = [0, 0] }
        d += [UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
        return d + body
    }
}

// MARK: - 描画スレッドから：コンポジションを小さく読む

final class DMXSampler {
    static let shared = DMXSampler()
    static let w = 128, h = 72
    private var tex: MTLTexture?

    func sample(_ composite: MTLTexture, cb: MTLCommandBuffer) {
        if tex == nil {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.w, height: Self.h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .shared
            tex = MetalContext.shared.device.makeTexture(descriptor: td)
        }
        guard let tex else { return }
        let r = LifeRenderer.shared
        r.fullPass(into: tex, cb: cb) { enc in
            enc.setRenderPipelineState(r.copy)
            enc.setFragmentTexture(composite, index: 0)
        }
        cb.addCompletedHandler { _ in
            var px = [UInt8](repeating: 0, count: Self.w * Self.h * 4)
            tex.getBytes(&px, bytesPerRow: Self.w * 4, from: MTLRegionMake2D(0, 0, Self.w, Self.h), mipmapLevel: 0)
            ArtNetOutput.shared.update(pixels: px, width: Self.w, height: Self.h)
        }
    }
}

// MARK: - 編集の窓

final class DMXWindow: NSObject, NSWindowDelegate {
    static let shared = DMXWindow()
    private var window: NSWindow?
    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "照明（Art-Net / DMX）"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: DMXEditor().environmentObject(Engine.shared).preferredColorScheme(.dark))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { window = nil }
}

struct DMXEditor: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var out = ArtNetOutput.shared
    @State private var selected: UUID?
    private var selIndex: Int? { engine.dmxMap.fixtures.firstIndex { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Toggle("Art-Net で送る", isOn: $out.enabled).toggleStyle(.switch)
                Text("送り先").font(.system(size: 12))
                TextField("255.255.255.255", text: $out.host).frame(width: 150)
                Text(out.status).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                ValueDrag(label: "明るさ", value: $engine.dmxMap.brightness, range: 0...1, perPoint: 0.003, defaultValue: 1,
                          format: EffectParam.percent).frame(width: 200, height: 26)
                ValueDrag(label: "ガンマ", value: $engine.dmxMap.gamma, range: 1...3, perPoint: 0.003, defaultValue: 2.2,
                          format: { String(format: "%.2f", $0) }).frame(width: 200, height: 26)
                    .help("LED は暗い所が明るく見えがちなので、2.2 くらいで画面の見た目に近くなる")
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("灯体").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Menu { ForEach(DMXFixture.Kind.allCases) { k in Button(k.label) { add(k) } } } label: { Image(systemName: "plus") }
                            .fixedSize()
                        Button { if let i = selIndex { engine.dmxMap.fixtures.remove(at: i); selected = nil } } label: { Image(systemName: "minus") }
                            .disabled(selIndex == nil)
                    }
                    List(selection: $selected) {
                        ForEach(engine.dmxMap.fixtures) { f in
                            HStack {
                                Text(f.name).lineLimit(1)
                                Spacer()
                                Text("U\(f.universe) ch\(f.channel)–\(f.channel + f.channelCount - 1)")
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .tag(f.id)
                        }
                    }
                    .frame(height: 200)
                    if let i = selIndex { DMXFixtureDetail(f: $engine.dmxMap.fixtures[i]) }
                }
                .frame(width: 300)
                VStack(alignment: .leading, spacing: 6) {
                    Text("取る所：点・線の端をドラッグ").font(.system(size: 11)).foregroundStyle(.secondary)
                    ZStack {
                        MetalPreview(kind: .composition)
                        DMXOverlay(map: $engine.dmxMap, selected: $selected)
                    }
                    .aspectRatio(engine.outputAspect, contentMode: .fit)
                    .overlay(Rectangle().stroke(Color.gray.opacity(0.4)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 860, minHeight: 520)
        .onAppear { if selected == nil { selected = engine.dmxMap.fixtures.first?.id } }
    }

    private func add(_ k: DMXFixture.Kind) {
        var f = DMXFixture()
        f.kind = k
        f.name = k == .line ? "LED テープ \(engine.dmxMap.fixtures.count + 1)" : "灯体 \(engine.dmxMap.fixtures.count + 1)"
        // 次の空いているチャンネルから
        let used = engine.dmxMap.fixtures.filter { $0.universe == 0 }.map { $0.channel + $0.channelCount - 1 }.max() ?? 0
        f.channel = min(used + 1, 512)
        if k == .line { f.start = [0.1, 0.5]; f.end = [0.9, 0.5] }
        engine.dmxMap.fixtures.append(f)
        selected = f.id
    }
}

private struct DMXFixtureDetail: View {
    @Binding var f: DMXFixture
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("名前", text: $f.name)
            Picker("種類", selection: $f.kind) { ForEach(DMXFixture.Kind.allCases) { Text($0.label).tag($0) } }
            HStack {
                Stepper("ユニバース \(f.universe)", value: $f.universe, in: 0...32767)
            }
            HStack {
                Stepper("先頭 ch \(f.channel)", value: $f.channel, in: 1...512)
            }
            if f.kind == .line {
                Stepper("点の数 \(f.pixels)", value: $f.pixels, in: 1...680)
            }
            Text("使うチャンネル：\(f.channelCount)（\(f.kind.channelsPerPixel) ch × \(f.kind == .line ? f.pixels : 1)）。512 を超えた分は次のユニバースへ")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
}

private struct DMXOverlay: View {
    @Binding var map: DMXMap
    @Binding var selected: UUID?
    var body: some View {
        GeometryReader { g in
            ForEach(Array(map.fixtures.enumerated()), id: \.element.id) { i, f in
                let p0 = CGPoint(x: f.start[0] * g.size.width, y: f.start[1] * g.size.height)
                let p1 = CGPoint(x: f.end[0] * g.size.width, y: f.end[1] * g.size.height)
                let sel = f.id == selected
                if f.kind == .line {
                    Path { p in p.move(to: p0); p.addLine(to: p1) }.stroke(sel ? Color.yellow : Color.white.opacity(0.7), lineWidth: sel ? 2 : 1)
                    handle(p1, sel) { v in map.fixtures[i].end = [min(max(v.x / g.size.width, 0), 1), min(max(v.y / g.size.height, 0), 1)]; selected = f.id }
                }
                handle(p0, sel) { v in map.fixtures[i].start = [min(max(v.x / g.size.width, 0), 1), min(max(v.y / g.size.height, 0), 1)]; selected = f.id }
                Text(f.name).font(.system(size: 9, weight: .bold)).foregroundStyle(.white).position(x: p0.x, y: p0.y - 12)
            }
        }
    }
    private func handle(_ p: CGPoint, _ sel: Bool, _ moved: @escaping (CGPoint) -> Void) -> some View {
        Circle().fill(sel ? Color.yellow : Color.white).frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.black, lineWidth: 1))
            .position(p)
            .gesture(DragGesture().onChanged { moved($0.location) })
    }
}
