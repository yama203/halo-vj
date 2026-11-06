import AppKit
import SwiftUI

/// 消えている途中のパッド
struct PadRelease {
    let start: Double
    /// 離したときの効き具合（0〜1）
    let from: Double
    let duration: Double
    /// エフェクトの時間の基準（押した時刻）
    let origin: Double
    func amount(at t: Double) -> Double { from * min(max(1 - (t - start) / max(duration, 1e-6), 0), 1) }
}

/// 描画スレッドに渡す、効いているパッド 1 つ（エフェクトと、今の効き具合の決め方）
struct PadRender {
    let stack: EffectStack
    let down: Double
    let attack: Double
    let release: PadRelease?
    var effects: [Effect] { stack.effects }
    var origin: Double { stack.origin }
    /// t の時点の効き具合（0〜1）
    func amount(at t: Double) -> Double {
        if let release { return release.amount(at: t) }
        return attack > 0 ? min(max((t - down) / attack, 0), 1) : 1
    }
}

/// 押している間だけ効くエフェクトのパッド。シーンやコンポジションとは別で、出力のいちばん最後にかかる
final class FXPad: ObservableObject, Identifiable, EffectHolder {
    let id: UUID
    /// 空なら、付けたエフェクトの名前を出す
    @Published var name: String { didSet { onChanged?() } }
    @Published var effects: [Effect] { didSet { onChanged?() } }
    /// 押している間だけ効かせるキー（"1"、"q" など。nil = なし）
    @Published var key: String? { didSet { onChanged?() } }
    /// 押してから効き切るまでの秒数（0 = いきなり全開）
    @Published var attack: Double = 0 { didSet { onChanged?() } }
    /// 離してから消え切るまでの秒数（0 = すぐ消える）
    @Published var release: Double = 0 { didSet { onChanged?() } }
    static let timeChoices: [Double] = [0, 0.25, 0.5, 1, 2, 4]
    static func timeLabel(_ s: Double) -> String { s <= 0 ? "すぐ" : (s < 1 ? String(format: "%.2g秒", s) : String(format: "%.0f秒", s)) }
    var onChanged: (() -> Void)?

    init(id: UUID = UUID(), name: String = "", effects: [Effect] = [], key: String? = nil) {
        self.id = id
        self.name = name
        self.effects = effects
        self.key = key
    }

    var displayName: String {
        if !name.isEmpty { return name }
        return effects.isEmpty ? "空き" : effects.map(\.kind.label).joined(separator: "＋")
    }
}

extension Engine {
    static let defaultPadCount = 8
    static let maxPads = 16

    struct SavedPad: Codable {
        var name: String?
        var effects: [Effect]?
        /// 効き始め・消え方の秒数
        var attack: Double?
        var release: Double?
        /// キー（"" = なし、無ければ並び順の既定）
        var key: String?
    }

    /// パッドに割り当てられるキーと、そのキーコード（US・JIS 配列で同じ位置のもの）
    static let padKeyCodes: [(String, UInt16)] = [
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29),
        ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("t", 17), ("y", 16), ("u", 32), ("i", 34), ("o", 31), ("p", 35),
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("g", 5), ("h", 4), ("j", 38), ("k", 40), ("l", 37),
        ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11), ("n", 45), ("m", 46),
    ]
    /// 並び順の既定のキー（1〜9、0）
    static func defaultPadKey(_ i: Int) -> String? { i < 10 ? String((i + 1) % 10) : nil }

    /// キーボード：キーコードのパッドを押す。割り当てのあるキーなら true
    @discardableResult
    func padKeyDown(_ code: UInt16) -> Bool {
        guard let k = Self.padKeyCodes.first(where: { $0.1 == code })?.0 else { return false }
        let hit = pads.filter { $0.key == k }
        hit.forEach { padDown($0.id) }
        return !hit.isEmpty
    }

    @discardableResult
    func padKeyUp(_ code: UInt16) -> Bool {
        guard let k = Self.padKeyCodes.first(where: { $0.1 == code })?.0 else { return false }
        let hit = pads.filter { $0.key == k }
        hit.forEach { padUp($0.id) }
        return !hit.isEmpty
    }

    /// 全部離す（アプリから離れたときなど、キーを離したのが届かないことがあるので）
    func releaseAllPads() {
        guard !heldPads.isEmpty || !releasingPads.isEmpty else { return }
        heldPads = [:]
        releasingPads = [:]
        syncRenderState()
    }

    /// パッドのキーを変える（同じキーの別のパッドからは外す）
    func setPadKey(_ id: UUID, _ key: String?) {
        if let key { for p in pads where p.id != id && p.key == key { p.key = nil } }
        pads.first { $0.id == id }?.key = key
    }

    /// パッドを押した（押している間だけ効く。効き始めの秒数があれば、だんだん効く）
    func padDown(_ id: UUID) {
        guard let pad = pads.first(where: { $0.id == id }), heldPads[id] == nil else { return }
        let now = CACurrentMediaTime()
        if let r = releasingPads.removeValue(forKey: id) {
            // 消えている途中でもう一度押した → 今の効き具合から続けて上げる
            let k = r.amount(at: now)
            heldPads[id] = now - k * pad.attack
            padOrigins[id] = r.origin
        } else {
            heldPads[id] = now
            padOrigins[id] = now
        }
        syncRenderState()
    }

    /// パッドを離した（消え方の秒数があれば、だんだん消える）
    func padUp(_ id: UUID) {
        guard let down = heldPads.removeValue(forKey: id) else { return }
        let now = CACurrentMediaTime()
        if let pad = pads.first(where: { $0.id == id }), pad.release > 0, !pad.effects.isEmpty {
            let k = pad.attack > 0 ? min(max((now - down) / pad.attack, 0), 1) : 1
            let r = PadRelease(start: now, from: k, duration: pad.release, origin: padOrigins[id] ?? down)
            releasingPads[id] = r
            DispatchQueue.main.asyncAfter(deadline: .now() + pad.release + 0.05) { [weak self] in
                guard let self, self.releasingPads[id]?.start == r.start else { return }
                self.releasingPads[id] = nil
                self.syncRenderState()
            }
        }
        syncRenderState()
    }

    /// 効いているパッド（押している・消えている途中）。パッドの並び順。描画用
    func heldPadStacks() -> [PadRender] {
        pads.compactMap { p in
            guard !p.effects.isEmpty else { return nil }
            if let t = heldPads[p.id] {
                return PadRender(stack: EffectStack(effects: p.effects, beat: beatClock, origin: padOrigins[p.id] ?? t),
                                 down: t, attack: p.attack, release: nil)
            }
            if let r = releasingPads[p.id] {
                return PadRender(stack: EffectStack(effects: p.effects, beat: beatClock, origin: r.origin),
                                 down: 0, attack: p.attack, release: r)
            }
            return nil
        }
    }

    func addPad() {
        guard pads.count < Self.maxPads else { return }
        let used = Set(pads.compactMap(\.key))
        let p = FXPad(key: Self.defaultPadKey(pads.count).flatMap { used.contains($0) ? nil : $0 })
        wirePad(p)
        pads.append(p)
        scheduleSave()
    }

    /// パッドを並び替える（id のパッドを index 番目へ）
    func movePad(_ id: UUID, to index: Int) {
        guard let i = pads.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(index, 0), pads.count - 1)
        guard i != j else { return }
        let p = pads.remove(at: i)
        pads.insert(p, at: j)
        syncRenderState()
        scheduleSave()
    }

    func removePad(_ id: UUID) {
        guard pads.count > 1 else { return }
        heldPads.removeValue(forKey: id)
        pads.removeAll { $0.id == id }
        syncRenderState()
        scheduleSave()
    }

    func wirePad(_ p: FXPad) {
        p.onChanged = { [weak self] in
            self?.syncRenderState()
            self?.scheduleSave()
        }
    }

    func makePads(_ saved: [SavedPad]?) -> [FXPad] {
        let ps = (saved ?? []).prefix(Self.maxPads).enumerated().map { i, s in
            let p = FXPad(name: s.name ?? "", effects: s.effects ?? [],
                          key: s.key.map { $0.isEmpty ? nil : $0 } ?? Self.defaultPadKey(i))
            p.attack = max(s.attack ?? 0, 0)
            p.release = max(s.release ?? 0, 0)
            return p
        }
        let all = ps.isEmpty ? (0..<Self.defaultPadCount).map { FXPad(key: Self.defaultPadKey($0)) } : Array(ps)
        all.forEach(wirePad)
        return all
    }

    var savedPads: [SavedPad] {
        pads.map { SavedPad(name: $0.name.isEmpty ? nil : $0.name, effects: $0.effects.isEmpty ? nil : $0.effects,
                            attack: $0.attack > 0 ? $0.attack : nil, release: $0.release > 0 ? $0.release : nil,
                            key: $0.key ?? "") }
    }
}

// MARK: - 画面

/// パッドを ⌘ドラッグで並び替えるときの状態
final class PadDragState: ObservableObject {
    static let space = "fxPadBar"
    @Published var source: UUID?
    @Published var target: Int?
    var frames: [UUID: CGRect] = [:]
}

private struct PadFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// グリッドの下のパッドの列
struct FXPadBar: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var drag = PadDragState()

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label("FX パッド", systemImage: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.purple)
                Text("押している間だけ")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: ClipGrid.leftWidth - 8, alignment: .leading)
            .contextMenu {
                Button(LayoutManager.shared.isDetached(.pads) ? "メインのウィンドウに戻す" : "別ウィンドウに出す") {
                    LayoutManager.shared.toggleDetached(.pads)
                }
            }
            .help("押している間だけ、出力のいちばん最後にエフェクトがかかる（シーン・コンポジションとは別）。「エフェクト」パネルからパッドへドラッグして登録。⌘ドラッグで並び替え。右クリックで設定・名前・キー・空にする・削除")
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(engine.pads) { p in
                        FXPadButton(pad: p, held: engine.heldPads[p.id] != nil)
                    }
                    if engine.pads.count < Engine.maxPads {
                        Button {
                            engine.addPad()
                        } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        }
                        .controlSize(.small)
                        .help("パッドを足す")
                    }
                }
                .padding(.vertical, 2)
                .coordinateSpace(name: PadDragState.space)
                .onPreferenceChange(PadFramesKey.self) { drag.frames = $0 }
            }
            .scrollIndicators(.never)
            .environmentObject(drag)
        }
    }
}

struct FXPadButton: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var drag: PadDragState
    @ObservedObject var pad: FXPad
    let held: Bool
    @State private var pressing = false
    @State private var showSettings = false
    @State private var dropTargeted = false

    var body: some View {
        let empty = pad.effects.isEmpty
        ZStack(alignment: .topLeading) {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                if empty {
                    Image(systemName: "plus.circle.dashed").font(.system(size: 13))
                } else {
                    ForEach(pad.effects.prefix(3)) { e in
                        Image(systemName: e.kind.icon).font(.system(size: 13))
                    }
                }
            }
            Text(pad.displayName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let k = pad.key {
                Text(k.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.45)))
                    .padding(.top, 3)
                    .padding(.leading, -2)
            }
            // 効き方の形（右上）：縦の線 = いきなり、斜め = だんだん
            if !empty {
                PadEnvelopeIcon(attack: pad.attack, release: pad.release)
                    .frame(width: 22, height: 9)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.top, 5)
                    .padding(.trailing, -1)
                    .opacity(pad.attack > 0 || pad.release > 0 ? 1 : 0.55)
            }
        }
        .foregroundStyle(held ? Color.white : (empty ? Color.secondary : Color.primary))
        .padding(.horizontal, 6)
        .frame(width: 104, height: 46)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(held ? Color.purple : Color.purple.opacity(empty ? 0.06 : 0.18)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(dropTargeted ? Color.purple : Color.purple.opacity(held ? 1 : 0.4),
                    style: StrokeStyle(lineWidth: dropTargeted ? 3 : 1, dash: empty && !dropTargeted ? [4, 3] : [])))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3)
            .opacity(moveTarget ? 1 : 0).allowsHitTesting(false))
        .opacity(drag.source == pad.id ? 0.4 : 1)
        .background(GeometryReader { g in
            Color.clear.preference(key: PadFramesKey.self, value: [pad.id: g.frame(in: .named(PadDragState.space))])
        })
        .contentShape(Rectangle())
        // 押した瞬間に効き、離すと消える。⌘ドラッグは並び替え
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(PadDragState.space))
            .onChanged { v in
                if !pressing {
                    pressing = true
                    if NSEvent.modifierFlags.contains(.command) {
                        drag.source = pad.id
                    } else if empty {
                        showSettings = true
                    } else {
                        engine.padDown(pad.id)
                    }
                }
                if drag.source == pad.id {
                    let id = drag.frames.first { $0.value.contains(v.location) }?.key
                    drag.target = id.flatMap { id in engine.pads.firstIndex { $0.id == id } }
                }
            }
            .onEnded { _ in
                pressing = false
                if drag.source == pad.id {
                    if let t = drag.target { engine.movePad(pad.id, to: t) }
                    drag.source = nil
                    drag.target = nil
                } else {
                    engine.padUp(pad.id)
                }
            })
        .onDrop(of: EffectDrop.types, isTargeted: $dropTargeted) { providers in
            EffectDrop.handle(providers) { k in pad.addEffect(k) }
        }
        .help((empty ? "「エフェクト」パネルからここへドラッグして登録"
               : "押している間だけ「\(pad.displayName)」（右クリックで設定）")
              + (pad.key.map { "\nキー \($0.uppercased()) を押している間も効く" } ?? ""))
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            FXPadSettings(pad: pad)
                .environmentObject(engine)
        }
        .contextMenu { PadContextMenu(pad: pad, showSettings: $showSettings) }
    }
}

extension FXPadButton {
    private var index: Int? { engine.pads.firstIndex { $0.id == pad.id } }
    /// ⌘ドラッグで、ここへ動かそうとしている
    private var moveTarget: Bool {
        guard let s = drag.source, s != pad.id, let t = drag.target else { return false }
        return engine.pads.indices.contains(t) && engine.pads[t].id == pad.id
    }
}

/// パッドの設定（エフェクトの並び・値）
private struct FXPadSettings: View {
    @ObservedObject var pad: FXPad

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionTitle("効き方")
                    PadEnvelopeIcon(attack: pad.attack, release: pad.release)
                        .frame(width: 36, height: 12)
                        .foregroundStyle(.purple)
                    Spacer(minLength: 0)
                }
                timeRow("効き始め", $pad.attack, help: "押してから全開になるまで。すぐ = いきなり全開")
                timeRow("離したとき", $pad.release, help: "離してから消え切るまで。すぐ = すぐ消える")
                EffectsSection(holder: pad)
            }
            .padding(12)
        }
        .frame(width: UI.paramsWidth + 24, height: 480)
    }

    private func timeRow(_ label: String, _ v: Binding<Double>, help: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            ChoiceButtons(selection: v, items: FXPad.timeChoices.map { ($0, FXPad.timeLabel($0)) }, height: 24, fontSize: 11)
        }
        .help(help)
    }
}

/// 効き方の形：押した所から全開までの立ち上がり（縦 = いきなり、斜め = だんだん）と、離したあとの消え方
struct PadEnvelopeIcon: View {
    let attack: Double
    let release: Double

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            // 秒数が長いほど斜めをゆるく（最大で幅の 4 割）
            let a = attack > 0 ? w * 0.4 * min(0.35 + attack / 2, 1) : 0
            let r = release > 0 ? w * 0.4 * min(0.35 + release / 2, 1) : 0
            Path { p in
                p.move(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: a, y: 1))
                p.addLine(to: CGPoint(x: w - r, y: 1))
                p.addLine(to: CGPoint(x: w, y: h))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// パッドの右クリック：効き始め・離したときの秒数
private struct PadTimeMenus: View {
    @ObservedObject var pad: FXPad

    var body: some View {
        Menu("効き始め（" + FXPad.timeLabel(pad.attack) + "）") {
            ForEach(FXPad.timeChoices, id: \.self) { t in
                Button(label(t, current: pad.attack, zero: "すぐ（いきなり全開）", suffix: "かけて")) { pad.attack = t }
            }
        }
        Menu("離したとき（" + FXPad.timeLabel(pad.release) + "）") {
            ForEach(FXPad.timeChoices, id: \.self) { t in
                Button(label(t, current: pad.release, zero: "すぐ消える", suffix: "かけて消える")) { pad.release = t }
            }
        }
    }

    private func label(_ t: Double, current: Double, zero: String, suffix: String) -> String {
        let mark = current == t ? "✓ " : ""
        let text = t == 0 ? zero : FXPad.timeLabel(t) + suffix
        return mark + text
    }
}

/// パッドの右クリックのメニュー
private struct PadContextMenu: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var pad: FXPad
    @Binding var showSettings: Bool
    private var empty: Bool { pad.effects.isEmpty }
    private var index: Int? { engine.pads.firstIndex { $0.id == pad.id } }

    var body: some View {
            Button("設定…") { showSettings = true }
            Button("名前を変える…") {
                if let n = askName(title: "パッドの名前（空にするとエフェクト名）", initial: pad.name) { pad.name = n }
            }
            if !pad.name.isEmpty { Button("名前を戻す") { pad.name = "" } }
            Menu("キー" + (pad.key.map { "（\($0.uppercased())）" } ?? "（なし）")) {
                Button((pad.key == nil ? "✓ " : "") + "なし") { engine.setPadKey(pad.id, nil) }
                Divider()
                ForEach(Engine.padKeyCodes.map(\.0), id: \.self) { k in
                    let owner = engine.pads.first { $0.key == k && $0.id != pad.id }
                    Button((pad.key == k ? "✓ " : "") + k.uppercased() + (owner.map { "（\($0.displayName) から移す）" } ?? "")) {
                        engine.setPadKey(pad.id, k)
                    }
                }
            }
            PadTimeMenus(pad: pad)
            Button("空にする") { pad.effects = [] }
                .disabled(empty)
            Divider()
            Button("左へ移動") { if let i = index { engine.movePad(pad.id, to: i - 1) } }
                .disabled(index == 0)
            Button("右へ移動") { if let i = index { engine.movePad(pad.id, to: i + 1) } }
                .disabled(index == engine.pads.count - 1)
            Divider()
            Button("このパッドを削除", role: .destructive) { engine.removePad(pad.id) }
                .disabled(engine.pads.count <= 1)
            }
}
