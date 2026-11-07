import AppKit
import CoreMIDI
import SwiftUI

// MIDI コントローラーとキーボードの割り当て。
// ボタン（MIDI のノート・CC、キー）→ 何をするか（OSC の決まったアドレス /halo/... と同じ）を、「覚える」で決める。
// MIDI のつまみ・フェーダーの値は OSC と同じ置き場所に入るので、どの値も動かし方「OSC・MIDI」で動かせる。
// 割り当てたクリップ・パッドは、コントローラーのボタンを光らせて返す（ノートで割り当てたもの）。

/// ボタン 1 つ（MIDI のノート・CC、またはキー）
struct ControlTrigger: Codable, Hashable {
    enum Kind: String, Codable { case note, cc, key }
    var kind: Kind
    /// MIDI のチャンネル（1〜16）。キーは 0
    var channel: Int
    /// ノート番号・CC 番号・キーのコード
    var number: Int
    /// MIDI の機器の名前（光らせて返す先。キーは nil）
    var device: String?
    /// キーの見た目（キーのときだけ）
    var keyLabel: String?

    var label: String {
        switch kind {
        case .note: "ノート \(number)（ch\(channel)）"
        case .cc: "CC \(number)（ch\(channel)）"
        case .key: "キー " + (keyLabel ?? "#\(number)")
        }
    }
    var short: String {
        switch kind {
        case .note: "N\(number)"
        case .cc: "CC\(number)"
        case .key: (keyLabel ?? "#\(number)").uppercased()
        }
    }
    /// OSC と同じ置き場所に入れるときのアドレス（MIDI の値で動かす用）
    var valueAddress: String? {
        switch kind {
        case .note: "/midi/\(channel)/note/\(number)"
        case .cc: "/midi/\(channel)/cc/\(number)"
        case .key: nil
        }
    }
    func matches(_ o: ControlTrigger) -> Bool { kind == o.kind && channel == o.channel && number == o.number }
}

/// 割り当て（ボタン → 何をするか）
struct ControlBinding: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: ControlTrigger
    /// 何をするか（/halo/... のアドレス）
    var address: String
    /// 画面に出す名前
    var title: String
}

/// 割り当てと MIDI の受け取り（アプリ全体で 1 つ）
final class ControlHub: ObservableObject {
    static let shared = ControlHub()

    @Published private(set) var bindings: [ControlBinding] = []
    /// 「覚える」の途中：これから押すボタンに割り当てるもの
    @Published private(set) var learning: (address: String, title: String)?
    /// つながっている MIDI の機器
    @Published private(set) var devices: [String] = []
    /// 最近届いた MIDI（画面に出す）
    @Published private(set) var lastMIDI = ""
    var forTests = false

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var started = false
    private var feedbackTimer: Timer?
    private var lit: [UUID: Bool] = [:]

    private init() {
        if let d = UserDefaults.standard.data(forKey: "controls.bindings"),
           let b = try? JSONDecoder().decode([ControlBinding].self, from: d) { bindings = b }
    }

    private func save() {
        guard !forTests, let d = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(d, forKey: "controls.bindings")
    }

    // MARK: 割り当て

    func learn(_ address: String, title: String) { learning = (address, title) }
    func cancelLearn() { learning = nil }

    /// 今の「覚える」に、このボタンを割り当てる（同じボタンの前の割り当ては外す）
    func bind(_ t: ControlTrigger) {
        guard let l = learning else { return }
        bindings.removeAll { $0.trigger.matches(t) || ($0.address == l.address && $0.trigger.kind == t.kind) }
        bindings.append(ControlBinding(trigger: t, address: l.address, title: l.title))
        learning = nil
        lit = [:]
        save()
    }

    func remove(_ id: UUID) {
        bindings.removeAll { $0.id == id }
        save()
    }

    func removeAll(address: String) {
        bindings.removeAll { $0.address == address }
        save()
    }

    func bindings(for address: String) -> [ControlBinding] { bindings.filter { $0.address == address } }

    /// ボタンが押された・離された（value 0〜1。メインスレッドで）
    func fire(_ t: ControlTrigger, value: Double) {
        if learning != nil {
            // 押したときだけ覚える（離したのは無視）
            if value > 0 { bind(t) }
            return
        }
        for b in bindings where b.trigger.matches(t) {
            // CC は 64 以上で押した、未満で離した
            let v = t.kind == .cc ? (value >= 0.5 ? 1.0 : 0.0) : value
            if !forTests { OSCCommands.run(OSCMessage(address: b.address, args: [.float(Float(v))])) }
        }
    }

    // MARK: キー

    /// キーが押された（AppDelegate から）。割り当てがあれば、または覚えている途中なら使う
    func key(_ event: NSEvent, down: Bool) -> Bool {
        let code = Int(event.keyCode)
        let label = event.charactersIgnoringModifiers?.uppercased() ?? ""
        let t = ControlTrigger(kind: .key, channel: 0, number: code, device: nil, keyLabel: label == " " ? "スペース" : label)
        if learning != nil {
            guard down else { return true }
            if code == 53 { cancelLearn(); return true }   // Esc でやめる
            bind(t)
            return true
        }
        guard bindings.contains(where: { $0.trigger.matches(t) }) else { return false }
        if down && event.isARepeat { return true }
        fire(t, value: down ? 1 : 0)
        return true
    }

    // MARK: MIDI

    func startIfNeeded() {
        guard !started else { return }
        started = true
        let st = MIDIClientCreateWithBlock("Halo VJ" as CFString, &client) { [weak self] n in
            if n.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.connectSources() } }
        }
        guard st == noErr else { return }
        MIDIInputPortCreateWithProtocol(client, "Halo VJ 入力" as CFString, ._1_0, &inPort) { [weak self] list, src in
            self?.receive(list, source: src)
        }
        MIDIOutputPortCreate(client, "Halo VJ 出力" as CFString, &outPort)
        connectSources()
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.sendFeedback() }
    }

    /// 機器の名前（つないだときに覚えておく。メッセージのたびに聞くと遅れる）
    private let nameLock = NSLock()
    private var sourceNames: [MIDIEndpointRef: String] = [:]

    private func connectSources() {
        var names: [String] = []
        var byRef: [MIDIEndpointRef: String] = [:]
        for i in 0..<MIDIGetNumberOfSources() {
            let s = MIDIGetSource(i)
            // 名前を refCon に入れておく（どの機器から来たか分かるように）
            let name = Self.name(s)
            names.append(name)
            byRef[s] = name
            let ref = UnsafeMutableRawPointer(bitPattern: Int(s))
            MIDIPortConnectSource(inPort, s, ref)
        }
        nameLock.withLock { sourceNames = byRef }
        devices = names
        lit = [:]
    }

    static func name(_ obj: MIDIObjectRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() { return s as String }
        if MIDIObjectGetStringProperty(obj, kMIDIPropertyName, &cf) == noErr, let s = cf?.takeRetainedValue() { return s as String }
        return "MIDI"
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>, source: UnsafeMutableRawPointer?) {
        let srcRef = MIDIEndpointRef(UInt(bitPattern: source))
        let device = srcRef == 0 ? "MIDI" : (nameLock.withLock { sourceNames[srcRef] } ?? Self.name(srcRef))
        for packet in list.unsafeSequence() {
            let words = MIDIEventPacket.WordCollection(packet)
            for w in words {
                // MIDI 1.0 のチャンネルのメッセージ（UMP の種類 2）
                guard w >> 28 == 0x2 else { continue }
                let status = UInt8((w >> 16) & 0xFF), d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
                handle(status: status, d1: d1, d2: d2, device: device)
            }
        }
    }

    /// MIDI のメッセージ 1 つ（受信のスレッドから。テストからも）
    func handle(status: UInt8, d1: Int, d2: Int, device: String) {
        let ch = Int(status & 0x0F) + 1
        let t: ControlTrigger
        let v: Double
        switch status & 0xF0 {
        case 0x90: t = ControlTrigger(kind: .note, channel: ch, number: d1, device: device); v = Double(d2) / 127
        case 0x80: t = ControlTrigger(kind: .note, channel: ch, number: d1, device: device); v = 0
        case 0xB0: t = ControlTrigger(kind: .cc, channel: ch, number: d1, device: device); v = Double(d2) / 127
        default: return
        }
        // つまみ・フェーダーの値は OSC と同じ置き場所へ（動かし方「OSC・MIDI」で使う。覚えるもこれで）
        if let a = t.valueAddress {
            OSCHub.shared.handle(OSCMessage(address: a, args: [.float(Float(v))]), runCommands: false)
        }
        DispatchQueue.main.async {
            self.lastMIDI = "\(device)：" + t.label + String(format: " = %.0f", v * 127)
            self.fire(t, value: v)
        }
    }

    // MARK: 光らせて返す

    /// 割り当てたクリップ・パッドの今の状態を、そのボタンの光で返す（変わったときだけ送る）
    private func sendFeedback() {
        guard outPort != 0, !bindings.isEmpty else { return }
        let e = Engine.shared
        var dests: [String: MIDIEndpointRef] = [:]
        for i in 0..<MIDIGetNumberOfDestinations() { let d = MIDIGetDestination(i); dests[Self.name(d)] = d }
        for b in bindings where b.trigger.kind == .note {
            guard let dev = b.trigger.device, let dest = dests[dev] else { continue }
            let on = Self.isOn(b.address, engine: e)
            guard lit[b.id] != on else { continue }
            lit[b.id] = on
            let status = UInt32(0x90 | UInt8(b.trigger.channel - 1))
            let word: UInt32 = 0x2000_0000 | status << 16 | UInt32(b.trigger.number) << 8 | (on ? 127 : 0)
            var list = MIDIEventList()
            let p = MIDIEventListInit(&list, ._1_0)
            _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, p, 0, 1, [word])
            MIDISendEventList(outPort, dest, &list)
        }
    }

    /// そのアドレスのものが今「点いている」か（クリップを出している・パッドを押している・ブラックアウト中・録画中）
    static func isOn(_ address: String, engine e: Engine) -> Bool {
        let p = address.split(separator: "/").map(String.init)
        guard p.count >= 2, p[0] == "halo" else { return false }
        func n(_ i: Int) -> Int? { p.count > i ? Int(p[i]).map { $0 - 1 } : nil }
        switch p[1] {
        case "layer":
            guard p.count > 4, p[3] == "clip", let r = n(2), let c = n(4), e.layers.indices.contains(r) else { return false }
            return e.activeByLayer[r] == e.slotIndex(deck: e.currentDeck, layer: r, column: c)
        case "pad":
            guard let i = n(2), e.pads.indices.contains(i) else { return false }
            return e.isPadHeld(e.pads[i].id)
        case "blackout": return e.isBlackout
        case "record": return Recorder.shared.isRecording
        default: return false
        }
    }
}

// MARK: - 画面

/// 「覚える」の途中に、画面の上に出す案内
struct ControlLearnBanner: View {
    @ObservedObject private var hub = ControlHub.shared
    var body: some View {
        if let l = hub.learning {
            HStack(spacing: 10) {
                Image(systemName: "pianokeys").font(.system(size: 14, weight: .semibold))
                Text("「\(l.title)」に割り当て：コントローラーのボタンかキーを押す（Esc でやめる）")
                    .font(.system(size: 13, weight: .semibold))
                Button("やめる") { hub.cancelLearn() }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.orange.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 6)
            .padding(.top, 8)
        }
    }
}

/// 右クリックのメニューに入れる「MIDI・キーで○○」
struct ControlMenuItems: View {
    let address: String
    let verb: String
    let title: String
    @ObservedObject private var hub = ControlHub.shared
    var body: some View {
        let bs = hub.bindings(for: address)
        Button("MIDI・キーで\(verb)（覚える）…") { hub.learn(address, title: title) }
        if !bs.isEmpty {
            Button("割り当てを外す（" + bs.map(\.trigger.short).joined(separator: "・") + "）") { hub.removeAll(address: address) }
        }
    }
}

/// クリップ・パッドの上に出す、割り当てたボタンの名前
struct ControlBadge: View {
    let address: String
    @ObservedObject private var hub = ControlHub.shared
    var body: some View {
        let bs = hub.bindings(for: address)
        if !bs.isEmpty {
            Text(bs.map(\.trigger.short).joined(separator: " "))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                .help("割り当て：" + bs.map(\.trigger.label).joined(separator: "・"))
        }
    }
}

/// 「連携」の中の、MIDI・キーの欄
struct ControlSettings: View {
    @ObservedObject private var hub = ControlHub.shared
    private static let actions: [(String, String)] = [
        ("/halo/cue/next", "キューを次へ"), ("/halo/cue/back", "キューを戻す"), ("/halo/blackout", "ブラックアウト"),
        ("/halo/tap", "タップテンポ"), ("/halo/resync", "今を 1 拍目に"), ("/halo/stop", "全部止める"), ("/halo/record", "録画"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hub.devices.isEmpty ? "MIDI の機器：つながっていません" : "MIDI の機器：" + hub.devices.joined(separator: "・"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !hub.lastMIDI.isEmpty {
                Text("届いた：" + hub.lastMIDI).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("クリップ・パッドは右クリックの「MIDI・キーで…（覚える）」で割り当てる。つまみ・フェーダーは、値の波形ボタンで動かし方を「OSC・MIDI」にして「覚える」")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text("割り当てる：").font(.system(size: 11))
                Menu("操作を選ぶ") {
                    ForEach(Self.actions, id: \.0) { a, t in Button(t) { hub.learn(a, title: t) } }
                }
                .fixedSize()
            }
            if !hub.bindings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(hub.bindings) { b in
                            HStack {
                                Text(b.trigger.label).font(.system(size: 10, design: .monospaced)).frame(width: 140, alignment: .leading)
                                Text(b.title).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Button { hub.remove(b.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }
}
