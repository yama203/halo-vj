import Foundation
import Network
import QuartzCore
import SwiftUI

// OSC：iPad（TouchOSC など）・TouchDesigner から操作する（受信）と、拍・音の値を TouchDesigner へ送る（送信）。
// 決まったアドレス（/halo/...）で操作でき、どのパラメーターも動かし方を「OSC」にすると、そのアドレスの値で動く。

/// OSC のメッセージ（引数は数・文字。true/false は 1/0）
struct OSCMessage: Equatable {
    var address: String
    var args: [OSCArg]

    enum OSCArg: Equatable {
        case int(Int32), float(Float), string(String)
        /// 数として読んだ値。NaN・無限大は数として扱わない（保存できなくなるので捨てる）
        var number: Double? {
            let v: Double? = switch self {
            case .int(let i): Double(i)
            case .float(let f): Double(f)
            case .string(let s): Double(s)
            }
            guard let v, v.isFinite else { return nil }
            return v
        }
    }

    /// はじめの数の引数（無ければ nil）
    var number: Double? { args.lazy.compactMap(\.number).first }

    // MARK: 書く・読む

    func encode() -> Data {
        var d = Data()
        func str(_ s: String) {
            d.append(contentsOf: Array(s.utf8)); d.append(0)
            while d.count % 4 != 0 { d.append(0) }
        }
        str(address)
        str("," + args.map { a -> String in
            switch a { case .int: "i"; case .float: "f"; case .string: "s" }
        }.joined())
        for a in args {
            switch a {
            case .int(let i): withUnsafeBytes(of: i.bigEndian) { d.append(contentsOf: $0) }
            case .float(let f): withUnsafeBytes(of: f.bitPattern.bigEndian) { d.append(contentsOf: $0) }
            case .string(let s): str(s)
            }
        }
        return d
    }

    /// パケット（メッセージかバンドル）を読む
    static func decode(_ data: Data) -> [OSCMessage] {
        let b = [UInt8](data)
        return decode(b, 0, b.count, depth: 0)
    }

    /// バンドルの入れ子はこの深さまで（それより深いものは読まない）
    static let maxBundleDepth = 8

    private static func decode(_ b: [UInt8], _ start: Int, _ end: Int, depth: Int) -> [OSCMessage] {
        guard end - start >= 4, depth <= maxBundleDepth else { return [] }
        var i = start
        func readStr() -> String? {
            guard i < end, let z = b[i..<end].firstIndex(of: 0) else { return nil }
            let s = String(decoding: b[i..<z], as: UTF8.self)
            i = z + 1
            while (i - start) % 4 != 0 { i += 1 }
            return s
        }
        func read32() -> UInt32? {
            guard i + 4 <= end else { return nil }
            let v = UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
            i += 4
            return v
        }
        if b[start] == UInt8(ascii: "#") {
            // バンドル：#bundle、時刻（8 バイト）、そのあと（大きさ、中身）の並び
            guard readStr() == "#bundle", i + 8 <= end else { return [] }
            i += 8
            var out: [OSCMessage] = []
            while i + 4 <= end, let n = read32() {
                let size = Int(n)
                guard size > 0, i + size <= end else { break }
                out += decode(b, i, i + size, depth: depth + 1)
                i += size
            }
            return out
        }
        guard let addr = readStr(), addr.hasPrefix("/") else { return [] }
        var args: [OSCArg] = []
        if i < end, let tags = readStr(), tags.hasPrefix(",") {
            for t in tags.dropFirst() {
                switch t {
                case "i": if let v = read32() { args.append(.int(Int32(bitPattern: v))) }
                case "f": if let v = read32() { args.append(.float(Float(bitPattern: v))) }
                case "s": if let s = readStr() { args.append(.string(s)) }
                case "T": args.append(.int(1))
                case "F": args.append(.int(0))
                case "d":
                    if let hi = read32(), let lo = read32() {
                        args.append(.float(Float(Double(bitPattern: UInt64(hi) << 32 | UInt64(lo)))))
                    }
                case "h":
                    if let hi = read32(), let lo = read32() { args.append(.int(Int32(truncatingIfNeeded: Int64(UInt64(hi) << 32 | UInt64(lo))))) }
                default: break
                }
            }
        }
        return [OSCMessage(address: addr, args: args)]
    }
}

/// OSC の送受信と、受け取った値（アプリ全体で 1 つ）
final class OSCHub: ObservableObject {
    static let shared = OSCHub()

    @Published var receiveOn = false { didSet { if oldValue != receiveOn { restartListener(); save() } } }
    @Published var receivePort: Int = 9000 { didSet { if oldValue != receivePort { restartListener(); save() } } }
    @Published var sendOn = false { didSet { if oldValue != sendOn { restartSender(); save() } } }
    @Published var sendHost = "127.0.0.1" { didSet { if oldValue != sendHost { restartSender(); save() } } }
    @Published var sendPort: Int = 7000 { didSet { if oldValue != sendPort { restartSender(); save() } } }
    @Published private(set) var status = ""
    /// 最近届いたメッセージ（画面に出す。新しい順）。届くたびに変わるので、別の入れ物にしておく
    /// （ここが @Published だと、OSCHub を見ている上のバーの「連携」ボタンなどまで描き直してしまう）
    let recent = RecentLines(keep: 6)
    /// 「覚える」：次に届いたアドレスを渡す
    @Published private(set) var learning = false
    var forTests = false

    private let lock = NSLock()
    private var values: [String: Double] = [:]
    /// 覚えておくアドレスの数・送り元ごとのつながりの数の上限
    static let maxValues = 2048
    static let maxConnections = 64
    private var learnHandler: ((String) -> Void)?
    private var listener: NWListener?
    /// 受け口・送り口（ネットワークのキューと画面のスレッドの両方から触るので connLock の中で）
    private let connLock = NSLock()
    private var conns: [NWConnection] = []
    private var sender: NWConnection?
    private let queue = DispatchQueue(label: "VJPlayer.osc")
    private var sendTimer: DispatchSourceTimer?
    private var lastClipNames: [String] = []
    private var pendingRecent: [String] = []

    private init() {
        let d = UserDefaults.standard
        receiveOn = d.bool(forKey: "osc.receive")
        if d.object(forKey: "osc.receivePort") != nil { receivePort = d.integer(forKey: "osc.receivePort") }
        sendOn = d.bool(forKey: "osc.send")
        if let h = d.string(forKey: "osc.sendHost"), !h.isEmpty { sendHost = h }
        if d.object(forKey: "osc.sendPort") != nil { sendPort = d.integer(forKey: "osc.sendPort") }
    }

    func startIfNeeded() {
        restartListener()
        restartSender()
    }

    private func save() {
        guard !forTests else { return }
        let d = UserDefaults.standard
        d.set(receiveOn, forKey: "osc.receive"); d.set(receivePort, forKey: "osc.receivePort")
        d.set(sendOn, forKey: "osc.send"); d.set(sendHost, forKey: "osc.sendHost"); d.set(sendPort, forKey: "osc.sendPort")
    }

    // MARK: 受け取った値

    /// アドレスの今の値（届いていなければ nil）。どのスレッドからでも
    func value(_ address: String) -> Double? { lock.withLock { values[address] } }

    func learn(_ handler: @escaping (String) -> Void) {
        lock.withLock { learnHandler = handler }
        learning = true
    }

    func cancelLearn() {
        lock.withLock { learnHandler = nil }
        learning = false
    }

    /// メッセージを受け取る（受信のスレッドから。テストからも）
    func handle(_ m: OSCMessage, runCommands: Bool = true) {
        // NaN・無限大の入ったメッセージは丸ごと捨てる（値に入ると保存できなくなる。「値なし」扱いで押す系が動かないように）
        if m.args.contains(where: { if case .float(let f) = $0 { !f.isFinite } else { false } }) { return }
        let learned: ((String) -> Void)? = lock.withLock {
            if let v = m.number {
                // 届いたアドレスの表は増えすぎないように（いっぱいなら、どれか 1 つを捨てる）
                if values[m.address] == nil, values.count >= Self.maxValues { values.remove(at: values.startIndex) }
                values[m.address] = v
            }
            let h = learnHandler
            learnHandler = nil
            return h
        }
        let line = m.address + " " + m.args.map { a -> String in
            switch a {
            case .int(let i): "\(i)"
            case .float(let f): String(format: "%.3f", f)
            case .string(let s): "\"\(s)\""
            }
        }.joined(separator: " ")
        DispatchQueue.main.async {
            self.recent.add(line)
            if let learned {
                self.learning = false
                learned(m.address)
            }
            if runCommands && !self.forTests { OSCCommands.run(m) }
        }
    }

    // MARK: 受信

    private func restartListener() {
        listener?.cancel(); listener = nil
        connLock.withLock { let old = conns; conns = []; return old }.forEach { $0.cancel() }
        guard receiveOn else { updateStatus(); return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: receivePort)),
              let l = try? NWListener(using: .udp, on: port) else {
            status = L("ポート \(receivePort) で受け取れません")
            return
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            // 切れた・やめたつながりは表から外す
            c.stateUpdateHandler = { [weak self, weak c] st in
                guard let self, let c else { return }
                switch st {
                case .failed, .cancelled: self.connLock.withLock { self.conns.removeAll { $0 === c } }
                default: break
                }
            }
            // 送り元が多すぎるときは、古いものからやめる
            let old: [NWConnection] = self.connLock.withLock {
                self.conns.append(c)
                let over = max(0, self.conns.count - Self.maxConnections)
                let out = Array(self.conns.prefix(over))
                self.conns.removeFirst(over)
                return out
            }
            old.forEach { $0.cancel() }
            c.start(queue: self.queue)
            self.receive(c)
        }
        l.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failed(let e) = st { self.status = L("受信できません：\(e.localizedDescription)") } else { self.updateStatus() }
            }
        }
        l.start(queue: queue)
        listener = l
        updateStatus()
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data { for m in OSCMessage.decode(data) { self.handle(m) } }
            if err == nil { self.receive(c) }
        }
    }

    // MARK: 送信

    private func restartSender() {
        sendTimer?.cancel(); sendTimer = nil
        connLock.withLock { let old = sender; sender = nil; return old }?.cancel()
        guard sendOn, let port = NWEndpoint.Port(rawValue: UInt16(clamping: sendPort)) else { updateStatus(); return }
        let c = NWConnection(host: NWEndpoint.Host(sendHost), port: port, using: .udp)
        c.start(queue: queue)
        connLock.withLock { sender = c }
        lastClipNames = []
        // 拍・音の値を 1 秒に 30 回送る
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in self?.sendTick() }
        t.resume()
        sendTimer = t
        updateStatus()
    }

    func send(_ m: OSCMessage) {
        connLock.withLock { sender }?.send(content: m.encode(), completion: .idempotent)
    }

    private func sendTick() {
        let now = CACurrentMediaTime()
        let clock = Engine.shared.beatClockForOSC()
        let beat = clock.beat(at: now)
        var out: [OSCMessage] = [
            OSCMessage(address: "/halo/bpm", args: [.float(Float(clock.bpm))]),
            OSCMessage(address: "/halo/beat", args: [.float(Float(beat.truncatingRemainder(dividingBy: 100_000)))]),
            OSCMessage(address: "/halo/beat/phase", args: [.float(Float(beat - floor(beat)))]),
            OSCMessage(address: "/halo/bar/phase", args: [.float(Float((beat / 4) - floor(beat / 4)))]),
        ]
        for b in AudioBand.allCases {
            let names = ["level", "low", "mid", "high", "attack"]
            out.append(OSCMessage(address: "/halo/audio/" + names[b.rawValue], args: [.float(Float(AudioReactive.shared.level(b, at: now)))]))
        }
        for m in out { send(m) }
        // 今出しているクリップの名前（変わったときだけ）
        DispatchQueue.main.async {
            let names = Engine.shared.layers.indices.map { r -> String in
                Engine.shared.activeByLayer[r].flatMap { Engine.shared.slots.indices.contains($0) ? Engine.shared.slots[$0]?.name : nil } ?? ""
            }
            guard names != self.lastClipNames else { return }
            let old = self.lastClipNames
            self.lastClipNames = names
            self.queue.async {
                for (r, n) in names.enumerated() where r >= old.count || old[r] != n {
                    self.send(OSCMessage(address: "/halo/layer/\(r + 1)/clip", args: [.string(n)]))
                }
            }
        }
    }

    private func updateStatus() {
        var s: [String] = []
        if receiveOn { s.append(L("受信：ポート \(receivePort)")) }
        if sendOn { s.append(L("送信：\(sendHost):\(sendPort)")) }
        status = s.isEmpty ? L("オフ") : s.joined(separator: L("・"))
    }

    /// この Mac の IP アドレス（iPad の送り先に入れる）
    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}

/// 決まったアドレス（/halo/...）で操作する。番号は 1 から（画面の表示と同じ）
enum OSCCommands {
    static let help: [(String, String)] = [
        ("/halo/layer/L/clip/C", L("L 段目の C 列目のクリップを出す（値 0 は無視）")),
        ("/halo/column/C", L("C 列目を全部の段で出す")),
        ("/halo/layer/L/stop", L("L 段目を止める")),
        ("/halo/layer/L/opacity 0〜1", L("L 段目の不透明度")),
        ("/halo/stop", L("全部止める")),
        ("/halo/master/opacity 0〜1", L("マスター不透明度")),
        ("/halo/master/volume 0〜1", L("マスター音量")),
        ("/halo/blackout [0/1]", L("ブラックアウト（値なしで切り替え）")),
        (L("/halo/bpm 数"), L("BPM を決める")),
        ("/halo/tap", L("タップテンポ")),
        ("/halo/resync", L("今を 1 拍目に")),
        ("/halo/pad/N 1/0", L("N 番目のパッドを押す・離す")),
        (L("/halo/cue/next ・/halo/cue/back ・/halo/cue/N"), L("キューを次へ・戻る・N 番目へ")),
        ("/halo/scene/N", L("N 番目のシーンを呼ぶ")),
        ("/halo/deck/N", L("N 番目のデッキにする")),
        ("/halo/record [0/1]", L("録画を始める・止める")),
        ("/halo/snapshot", L("今の絵を静止画で保存する")),
        ("/halo/snapshot/clip", L("今の絵を静止画で保存して、空いているスロットにクリップとして置く")),
        ("/halo/auto [0/1]", L("自動操縦をオン・オフ（値なしで切り替え）")),
    ]

    /// メインスレッドで実行する
    static func run(_ m: OSCMessage, engine: Engine? = nil) {
        let p = m.address.split(separator: "/").map(String.init)
        guard p.first == "halo" else { return }
        let e = engine ?? Engine.shared
        let v = m.number
        // ボタンを離した（0）ときは、押す系の操作をしない
        let pressed = v == nil || v! > 0.5
        func n(_ i: Int) -> Int? { p.count > i ? Int(p[i]).map { $0 - 1 } : nil }
        switch p.count >= 2 ? p[1] : "" {
        case "layer":
            guard let r = n(2), e.layers.indices.contains(r) else { return }
            let what = p.count > 3 ? p[3] : ""
            if what == "clip", let c = n(4), pressed, c >= 0, c < e.columns {
                e.trigger(e.slotIndex(deck: e.currentDeck, layer: r, column: c))
            } else if what == "stop", pressed {
                e.stopLayer(r)
            } else if what == "opacity", let v {
                e.layers[r].opacity = min(max(v, 0), 1)
            }
        case "column":
            guard let c = n(2), pressed, c >= 0, c < e.columns else { return }
            for r in e.layers.indices {
                let i = e.slotIndex(deck: e.currentDeck, layer: r, column: c)
                if e.slots.indices.contains(i), e.slots[i] != nil { e.trigger(i) }
            }
        case "stop":
            if pressed { e.stopAll() }
        case "master":
            guard let v else { return }
            if p.count > 2 && p[2] == "opacity" { e.masterOpacity = min(max(v, 0), 1) }
            if p.count > 2 && p[2] == "volume" { e.masterVolume = min(max(v, 0), 1) }
        case "blackout":
            if let v { if (v > 0.5) != e.isBlackout { e.toggleBlackout() } } else { e.toggleBlackout() }
        case "bpm":
            if let v, v >= 20, v <= 300 { e.bpm = v }
        case "tap":
            if pressed { e.tapTempo() }
        case "resync":
            if pressed { e.resyncBeat() }
        case "pad":
            guard let i = n(2), e.pads.indices.contains(i) else { return }
            if pressed { e.padDown(e.pads[i].id) } else { e.padUp(e.pads[i].id) }
        case "cue":
            guard pressed else { return }
            let w = p.count > 2 ? p[2] : ""
            if w == "next" { e.goCue() } else if w == "back" { e.backCue() } else if let i = n(2) { e.fireCue(i) }
        case "scene":
            if pressed, let i = n(2), e.scenes.indices.contains(i) { e.recallScene(e.scenes[i].id) }
        case "deck":
            if pressed, let i = n(2), e.decks.indices.contains(i) { e.currentDeck = i }
        case "record":
            if let v { if (v > 0.5) != Recorder.shared.isRecording { Recorder.shared.toggle() } } else { Recorder.shared.toggle() }
        case "snapshot":
            if pressed { e.takeSnapshot(asClip: p.count > 2 && p[2] == "clip") }
        case "auto":
            if let v { e.setAutopilot(v > 0.5) } else { e.setAutopilot(!e.autoRunner.isOn) }
        default:
            break
        }
    }
}

/// パラメーターと OSC のつなぎ方（動かし方が「OSC」のとき）
struct OSCLink: Codable, Equatable {
    var address = ""
}

// MARK: - 画面

/// 上のバーの「連携」ボタン（Syphon・OSC の設定）
struct LinkButton: View {
    @ObservedObject private var syphon = SyphonOutput.shared
    @ObservedObject private var osc = OSCHub.shared
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(syphon.enabled || osc.receiveOn || osc.sendOn ? Color.green : Color.secondary)
                Text(L("連携"))
            }
        }
        .help(L("TouchDesigner などとのやりとり：Syphon で映像を出す・OSC で操作する・拍や音の値を送る"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LinkSettings().padding(16).frame(width: 460)
        }
    }
}

struct LinkSettings: View {
    @ObservedObject private var syphon = SyphonOutput.shared
    @ObservedObject private var osc = OSCHub.shared
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ほかのアプリとのやりとり")).font(.headline)
            GroupBox(L("映像（Syphon）")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(L("コンポジションを Syphon で出す"), isOn: $syphon.enabled)
                        Spacer()
                        if syphon.enabled {
                            Label(syphon.hasClients ? L("受け取られています") : L("待っています"),
                                  systemImage: syphon.hasClients ? "dot.radiowaves.left.and.right" : "circle.dotted")
                                .font(.system(size: 11)).foregroundStyle(syphon.hasClients ? .green : .secondary)
                        }
                    }
                    HStack {
                        Text(L("名前")).font(.system(size: 12))
                        TextField("Halo VJ", text: $syphon.name).frame(width: 180)
                    }
                    Text(L("TouchDesigner では Syphon Spout In TOP で受け取る。ほかのアプリの Syphon を受け取るには、ジェネレーター「Syphon から」を枠に置く"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }
            NDISettingsSection()
            GroupBox(L("操作を受け取る（OSC 受信）")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(L("受け取る"), isOn: $osc.receiveOn)
                        Text(L("ポート")).font(.system(size: 12))
                        TextField("9000", value: $osc.receivePort, format: .number.grouping(.never)).frame(width: 70)
                    }
                    Text(L("iPad（TouchOSC など）の送り先：\(OSCHub.localAddresses().first ?? L("この Mac の IP アドレス"))、ポート \(osc.receivePort)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(L("どの値も、波形ボタンで動かし方を「OSC」にして「覚える」を押し、iPad のフェーダーを動かすと、そのフェーダーで動く"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    OSCRecentList(recent: osc.recent)
                    DisclosureGroup(L("決まったアドレス"), isExpanded: $showHelp) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(OSCCommands.help, id: \.0) { a, h in
                                HStack(alignment: .top) {
                                    Text(a).font(.system(size: 10, design: .monospaced)).frame(width: 210, alignment: .leading)
                                    Text(h).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .font(.system(size: 11))
                }
                .padding(4)
            }
            GroupBox(L("MIDI コントローラー・キー")) {
                ControlSettings().padding(4)
            }
            GroupBox(L("拍・音の値を送る（OSC 送信）")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(L("送る"), isOn: $osc.sendOn)
                        Text(L("送り先")).font(.system(size: 12))
                        TextField("127.0.0.1", text: $osc.sendHost).frame(width: 120)
                        TextField("7000", value: $osc.sendPort, format: .number.grouping(.never)).frame(width: 64)
                    }
                    Text(L("1 秒に 30 回：/halo/bpm・/halo/beat（拍の数）・/halo/beat/phase・/halo/bar/phase（0〜1）・/halo/audio/level・low・mid・high・attack。クリップを出したとき：/halo/layer/L/clip（名前）。TouchDesigner では OSC In CHOP（ポートを合わせる）"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }
            Text(osc.status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// 「連携」の、最近届いた OSC の一覧（届くたびに、ここだけ描き直す）
private struct OSCRecentList: View {
    @ObservedObject var recent: RecentLines
    var body: some View {
        if !recent.lines.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(recent.lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                }
            }
            .padding(4).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// 動かし方が「OSC」のとき：アドレス・覚える・今の値
struct OSCAnimControls: View {
    @Binding var anim: ParamAnim
    @ObservedObject private var osc = OSCHub.shared
    @State private var waiting = false

    private var address: Binding<String> {
        Binding(get: { anim.osc?.address ?? "" }, set: { anim.osc = OSCLink(address: $0) })
    }
    private var reverse: Binding<Bool> {
        Binding(get: { anim.motion == .backward }, set: { anim.motion = $0 ? .backward : .forward })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(L("/1/fader1・/midi/1/cc/7"), text: address).font(.system(size: 12, design: .monospaced))
                Button(waiting ? L("待っています…") : L("覚える")) {
                    if waiting {
                        osc.cancelLearn(); waiting = false
                    } else {
                        waiting = true
                        osc.learn { a in anim.osc = OSCLink(address: a); waiting = false }
                    }
                }
                .help(L("押してから iPad や MIDI コントローラーのフェーダー・つまみを動かすと、それを覚える"))
                Toggle(L("逆"), isOn: reverse).toggleStyle(.button).controlSize(.small)
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let v = osc.value(anim.osc?.address ?? "")
                HStack(spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 3).fill(Color.cyan.opacity(0.85))
                                .frame(width: g.size.width * min(max(v ?? 0, 0), 1))
                        }
                    }
                    .frame(height: 8)
                    Text(v.map { String(format: "%.2f", $0) } ?? "—").font(.system(size: 10, design: .monospaced))
                        .frame(width: 34, alignment: .trailing)
                }
            }
            if !osc.receiveOn {
                Text(L("OSC で動かすときは、上のバーの「連携」で OSC の「受け取る」をオンに（MIDI はそのまま使える）"))
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("値 0〜1 で「から」〜「まで」を動く（1 より大きい値は 1）")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        // 画面から消えるとき、自分が覚える待ちのままならやめる（あとで届いたアドレスが、見えない所に入らないように）
        .onDisappear { if waiting { osc.cancelLearn(); waiting = false } }
    }
}
