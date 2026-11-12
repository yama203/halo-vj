import AppKit
import SwiftUI
import UniformTypeIdentifiers

// エフェクトを別の場所へ付け替える（移す・写す）。
// カードの名前の行をドラッグして、ほかのクリップ・レイヤー・コンポジションへ落とす（⌥ を押していれば写す）。
// 右クリックの「移す／写す」からも同じことができる。値・動かし方・不透明度など、Effect が持つものは全部そのまま

/// エフェクトの置き場所
enum EffectPlace: Equatable {
    case composition
    case layer(Int)
    case clip(UUID)        // ClipSlot の id
}

extension Engine {
    /// id のエフェクトが今どこにあるか（コンポジション・全部のレイヤー・全部のデッキのクリップから探す）。
    /// シーンの編集中は、画面に出ているシーンのコンポジション・レイヤーから探す
    func effectLocation(_ id: UUID) -> (place: EffectPlace, index: Int)? {
        if let h = effectHolder(.composition), let i = h.effects.firstIndex(where: { $0.id == id }) {
            return (.composition, i)
        }
        for r in layers.indices {
            if let i = viewLayer(r).effects.firstIndex(where: { $0.id == id }) { return (.layer(r), i) }
        }
        for s in slots.compactMap({ $0 }) {
            if let i = s.effects.firstIndex(where: { $0.id == id }) { return (.clip(s.id), i) }
        }
        return nil
    }

    /// 置き場所の持ち主（無ければ nil）。シーンの編集中は、そのシーンのコンポジション・レイヤー
    func effectHolder(_ place: EffectPlace) -> (any EffectHolder)? {
        switch place {
        case .composition: return sceneDraft ?? self
        case .layer(let r): return layers.indices.contains(r) ? viewLayer(r) : nil
        case .clip(let id): return slots.first { $0?.id == id } ?? nil
        }
    }

    /// その種類を、その置き場所に付けられるか。
    /// 一覧から落とすときの決まりと同じ：ジェネレーターはクリップ本体になるもので、並びには入れない。
    /// 重ね方（特殊合成）の値と切り替えの形は内部用。空の枠・無いレイヤーには付けない
    func canHold(_ kind: EffectKind, at place: EffectPlace) -> Bool {
        guard !kind.isGenerator, !kind.isBlend, kind != .transitionMask else { return false }
        return effectHolder(place) != nil
    }

    /// 付け替える。index が nil なら最後。copy なら元を残して新しい id で入れる。変えたら true
    @discardableResult
    func transferEffect(_ id: UUID, to place: EffectPlace, at index: Int? = nil, copy: Bool = false) -> Bool {
        transferEffectID(id, to: place, at: index, copy: copy) != nil
    }

    /// transferEffect と同じ。入れたエフェクトの id を返す（写したときは新しい id。変えなければ nil）。
    /// index は「入ったあとの位置」。同じ並びの中を移すときは moveEffect(_:to:) と同じ決まり
    @discardableResult
    func transferEffectID(_ id: UUID, to place: EffectPlace, at index: Int? = nil, copy: Bool = false) -> UUID? {
        guard let from = effectLocation(id), let src = effectHolder(from.place), let dst = effectHolder(place) else { return nil }
        let e = src.effects[from.index]
        guard canHold(e.kind, at: place) else { return nil }
        if src === dst && !copy {
            // 同じ並びの中：今までの並べ替えと同じ
            let j = min(max(index ?? src.effects.count - 1, 0), src.effects.count - 1)
            guard j != from.index else { return nil }
            commitUndoStep()
            src.moveEffect(id, to: j)
            commitUndoStep()
            return id
        }
        var moved = e
        if copy { moved.id = UUID() }
        // 元に戻すの 1 歩にまとめる（前の変更とは分け、外すのと入れるのを 1 歩に）
        commitUndoStep()
        if !copy { src.removeEffect(id) }
        let n = dst.effects.count
        dst.effects.insert(moved, at: min(max(index ?? n, 0), n))
        commitUndoStep()
        return moved.id
    }

    /// 置き場所の名前（右クリックのメニュー用）
    func effectPlaceName(_ place: EffectPlace) -> String {
        switch place {
        case .composition:
            return sceneDraft != nil ? L("シーンのコンポジション") : L("コンポジション")
        case .layer(let r):
            let name = layers.indices.contains(r) ? layers[r].displayName : "L\(r + 1)"
            return sceneDraft != nil ? L("シーンのレイヤー \(name)") : L("レイヤー \(name)")
        case .clip(let id):
            let name = slots.first { $0?.id == id }??.name ?? ""
            return L("クリップ「\(name)」")
        }
    }

    /// 右クリックの「移す／写す」に出す先：コンポジション・全部のレイヤー・選んでいるクリップと再生中のクリップ
    var effectMenuPlaces: [EffectPlace] {
        var list: [EffectPlace] = [.composition]
        list += layers.indices.map { .layer($0) }
        var clips: [UUID] = []
        if let i = inspectedIndex, slots.indices.contains(i), let s = slots[i] { clips.append(s.id) }
        for r in layers.indices {
            if let i = viewPlaying(r), slots.indices.contains(i), let s = slots[i], !clips.contains(s.id) { clips.append(s.id) }
        }
        return list + clips.map { .clip($0) }
    }
}

// MARK: - ドラッグ中の状態

/// エフェクトのカードをドラッグしている間だけ true（パラメーターの上のタブに受け口を出す）。
/// これを見るのは受け口の小さな View だけにする（カードやパラメーター全体を描き直さない）
final class EffectDragState: ObservableObject {
    static let shared = EffectDragState()
    @Published private(set) var active = false
    private var timer: Timer?

    func begin(_ id: UUID) {
        EffectUIState.shared.dragging = id
        if !active { active = true }
        timer?.invalidate()
        // システムのドラッグは終わりが確実には分からないので、マウスのボタンを離したら消す
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self?.timer?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.end() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func end() {
        timer?.invalidate()
        timer = nil
        EffectUIState.shared.dragging = nil
        if active { active = false }
    }
}

/// 付け替えたエフェクトのカードを少しの間光らせる（どこへ行ったか分かるように）
final class EffectFlash: ObservableObject {
    static let shared = EffectFlash()
    @Published private(set) var id: UUID?
    private var work: DispatchWorkItem?

    func flash(_ id: UUID) {
        self.id = id
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.id = nil }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }
}

/// カードの枠を光らせる（EffectFlash を見る小さな View）
struct EffectFlashMark: View {
    let id: UUID
    @ObservedObject private var flash = EffectFlash.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.purple, lineWidth: 3)
            .padding(-4)
            .opacity(flash.id == id ? 1 : 0)
            .animation(.easeOut(duration: 0.4), value: flash.id == id)
            .allowsHitTesting(false)
    }
}

// MARK: - 落としたとき

enum EffectTransfer {
    /// ⌥ を押していれば写す
    static var copyKey: Bool { NSEvent.modifierFlags.contains(.option) }

    /// ドラッグの文字列から、付け替えるエフェクトの id を取り出す（一覧からの種類なら nil）
    static func moveID(_ s: String) -> UUID? {
        guard s.hasPrefix(EffectUIState.movePrefix) else { return nil }
        return UUID(uuidString: String(s.dropFirst(EffectUIState.movePrefix.count)))
    }

    /// 置き場所へ落とした（右クリックのメニューからも）。断るときはビープ。
    /// 元と同じ場所・同じ位置なら何もしない（ビープも鳴らさない）。付け替えたら true
    @discardableResult
    static func drop(_ id: UUID, to place: EffectPlace, at index: Int? = nil, copy: Bool, engine: Engine = .shared) -> Bool {
        defer { EffectDragState.shared.end() }
        guard let from = engine.effectLocation(id), let src = engine.effectHolder(from.place),
              engine.canHold(src.effects[from.index].kind, at: place) else { NSSound.beep(); return false }
        if !copy && from.place == place {
            let j = min(max(index ?? src.effects.count - 1, 0), src.effects.count - 1)
            if j == from.index { return false }
        }
        guard let newID = engine.transferEffectID(id, to: place, at: index, copy: copy) else { NSSound.beep(); return false }
        // 開いていたカードは、写した先でも開いておく（移したときは id が同じなのでそのまま）
        let ui = EffectUIState.shared
        if copy && ui.expanded.contains(id) { ui.expanded.insert(newID) }
        EffectFlash.shared.flash(newID)
        return true
    }

    /// 並び（holder）へ落とした。置き場所が分かればエンジンで付け替える。
    /// 置き場所の無い並び（FX パッド）は、その並びの中の並べ替え・複製だけ
    @discardableResult
    static func receive(_ id: UUID, into holder: any EffectHolder, place: EffectPlace?, at index: Int?, copy: Bool) -> Bool {
        if let place { return drop(id, to: place, at: index, copy: copy) }
        defer { EffectDragState.shared.end() }
        guard let i = holder.effects.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return false }
        if copy {
            var c = holder.effects[i]
            c.id = UUID()
            let n = holder.effects.count
            holder.effects.insert(c, at: min(max(index ?? n, 0), n))
        } else {
            holder.moveEffect(id, to: index ?? holder.effects.count - 1)
        }
        return true
    }
}

extension EffectDrop {
    /// 落とされた文字列を取り出す（メインスレッドで呼ぶ）。文字列が無ければ false
    static func loadString(_ providers: [NSItemProvider], _ action: @escaping (String) -> Void) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String else { return }
            DispatchQueue.main.async { action(s) }
        }
        return true
    }
}

/// エフェクトを落とせる所の受け口。付け替えのドラッグ中は、⌥ で「＋」（写す）、ふつうは「移す」のカーソルにする
struct EffectDropDelegate: DropDelegate {
    var types: [UTType] = EffectDrop.types
    @Binding var targeted: Bool
    var onEnter: (() -> Void)? = nil
    var onExit: (() -> Void)? = nil
    /// (中身, 写すか)
    let perform: ([NSItemProvider], Bool) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: types) }

    func dropEntered(info: DropInfo) {
        targeted = true
        onEnter?()
    }

    func dropExited(info: DropInfo) {
        targeted = false
        onExit?()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard EffectUIState.shared.dragging != nil else { return DropProposal(operation: .copy) }
        return DropProposal(operation: EffectTransfer.copyKey ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        onExit?()
        return perform(info.itemProviders(for: types), EffectTransfer.copyKey)
    }
}

// MARK: - パラメーターの上のタブ（ドラッグ中だけ受け口を重ねる）

/// タブの上に重ねる 3 つの受け口。止めておくとそのタブに切り替わり、落とすとその相手の最後に付く
struct EffectTabDropZones: View {
    /// 見るだけ（変わっても描き直さない）
    let engine: Engine
    @ObservedObject private var drag = EffectDragState.shared

    var body: some View {
        if drag.active {
            HStack(spacing: 2) {
                ForEach([Engine.InspectorTab.composition, .layer, .clip], id: \.self) { tab in
                    EffectTabDropZone(tab: tab, engine: engine)
                }
            }
        }
    }
}

private struct EffectTabDropZone: View {
    let tab: Engine.InspectorTab
    let engine: Engine
    @State private var targeted = false
    @State private var flash = false
    @State private var pending: DispatchWorkItem?

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.purple.opacity(targeted || flash ? 0.3 : 0.001))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color.purple, lineWidth: 2)
                .opacity(targeted || flash ? 1 : 0.35))
            .contentShape(Rectangle())
            .onDrop(of: EffectDrop.types, delegate: EffectDropDelegate(targeted: $targeted, onEnter: {
                // 0.6 秒止めると、そのタブに切り替わる（カードの間へ落として位置を決められる）
                pending?.cancel()
                let w = DispatchWorkItem { engine.inspectorTab = tab }
                pending = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
            }, onExit: {
                pending?.cancel()
                pending = nil
            }) { providers, copy in
                EffectDrop.loadString(providers) { s in
                    guard let id = EffectTransfer.moveID(s) else { EffectDragState.shared.end(); return }
                    guard let place = self.place else { EffectDragState.shared.end(); NSSound.beep(); return }
                    if EffectTransfer.drop(id, to: place, copy: copy, engine: engine) {
                        flash = true
                        withAnimation(.easeOut(duration: 0.4)) { flash = false }
                    }
                }
            })
            .help(L("ここで止めるとこのタブに切り替わる。落とすと最後に付く"))
    }

    /// そのタブの相手（選んでいるレイヤー・クリップ）
    private var place: EffectPlace? {
        switch tab {
        case .composition: return .composition
        case .layer: return .layer(engine.selectedLayer)
        case .clip:
            guard let i = engine.inspectedIndex, engine.slots.indices.contains(i), let s = engine.slots[i] else { return nil }
            return .clip(s.id)
        }
    }
}

// MARK: - 右クリックの「移す／写す」

/// カードの名前の行の右クリック：ほかの場所へ移す・写す
struct EffectTransferMenu: View {
    let id: UUID
    let kind: EffectKind

    var body: some View {
        let engine = Engine.shared
        let here = engine.effectLocation(id)?.place
        let places = engine.effectMenuPlaces
        Menu(L("移す")) { items(engine, places, here: here, copy: false) }
        Menu(L("写す")) { items(engine, places, here: here, copy: true) }
    }

    @ViewBuilder
    private func items(_ engine: Engine, _ places: [EffectPlace], here: EffectPlace?, copy: Bool) -> some View {
        ForEach(Array(places.enumerated()), id: \.offset) { i, p in
            // コンポジション・レイヤー・クリップの間に線
            if i > 0, Self.group(p) != Self.group(places[i - 1]) { Divider() }
            Button(engine.effectPlaceName(p)) { EffectTransfer.drop(id, to: p, copy: copy, engine: engine) }
                .disabled(here == nil || p == here || !engine.canHold(kind, at: p))
        }
    }

    private static func group(_ p: EffectPlace) -> Int {
        switch p {
        case .composition: 0
        case .layer: 1
        case .clip: 2
        }
    }
}

/// 名前の行に右クリックの「移す／写す」を付ける（enabled のときだけ）
struct EffectTransferMenuModifier: ViewModifier {
    let enabled: Bool
    let id: UUID
    let kind: EffectKind

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu { EffectTransferMenu(id: id, kind: kind) }
        } else {
            content
        }
    }
}
