import AppKit
import SwiftUI

/// 押している間だけ効くエフェクトのパッド。シーンやコンポジションとは別で、出力のいちばん最後にかかる
final class FXPad: ObservableObject, Identifiable, EffectHolder {
    let id: UUID
    /// 空なら、付けたエフェクトの名前を出す
    @Published var name: String { didSet { onChanged?() } }
    @Published var effects: [Effect] { didSet { onChanged?() } }
    /// 押している間だけ効かせるキー（"1"、"q" など。nil = なし）
    @Published var key: String? { didSet { onChanged?() } }
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
        guard !heldPads.isEmpty else { return }
        heldPads = [:]
        syncRenderState()
    }

    /// パッドのキーを変える（同じキーの別のパッドからは外す）
    func setPadKey(_ id: UUID, _ key: String?) {
        if let key { for p in pads where p.id != id && p.key == key { p.key = nil } }
        pads.first { $0.id == id }?.key = key
    }

    /// パッドを押した（押している間だけ効く）
    func padDown(_ id: UUID) {
        guard pads.contains(where: { $0.id == id }), heldPads[id] == nil else { return }
        heldPads[id] = CACurrentMediaTime()
        syncRenderState()
    }

    /// パッドを離した
    func padUp(_ id: UUID) {
        guard heldPads.removeValue(forKey: id) != nil else { return }
        syncRenderState()
    }

    /// 押しているパッドのエフェクト（パッドの並び順。描画用）
    func heldPadStacks() -> [EffectStack] {
        pads.compactMap { p in
            guard let t = heldPads[p.id], !p.effects.isEmpty else { return nil }
            return EffectStack(effects: p.effects, beat: beatClock, origin: t)
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
            FXPad(name: s.name ?? "", effects: s.effects ?? [],
                  key: s.key.map { $0.isEmpty ? nil : $0 } ?? Self.defaultPadKey(i))
        }
        let all = ps.isEmpty ? (0..<Self.defaultPadCount).map { FXPad(key: Self.defaultPadKey($0)) } : Array(ps)
        all.forEach(wirePad)
        return all
    }

    var savedPads: [SavedPad] {
        pads.map { SavedPad(name: $0.name.isEmpty ? nil : $0.name, effects: $0.effects.isEmpty ? nil : $0.effects,
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
            .help("押している間だけ、出力のいちばん最後にエフェクトがかかる（シーン・コンポジションとは別）。右下の「エフェクト」からパッドへドラッグして登録。⌘ドラッグで並び替え。右クリックで設定・名前・キー・空にする・削除")
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
        .help((empty ? "右下の「エフェクト」からここへドラッグして登録"
               : "押している間だけ「\(pad.displayName)」（右クリックで設定）")
              + (pad.key.map { "\nキー \($0.uppercased()) を押している間も効く" } ?? ""))
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            FXPadSettings(pad: pad)
                .environmentObject(engine)
        }
        .contextMenu {
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
            EffectsSection(holder: pad)
                .padding(12)
        }
        .frame(width: UI.paramsWidth + 24, height: 420)
    }
}
