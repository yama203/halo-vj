import SwiftUI
import UniformTypeIdentifiers

/// エフェクトの一覧（Resolume の Effects ブラウザのようなもの）。
/// 付けたい所へドラッグする：クリップのサムネイル／レイヤー欄／出力モニター（コンポジション）／下のエフェクト欄。
/// ダブルクリックで、今開いているタブ（コンポジション・レイヤー・クリップ）に付く。
struct EffectBrowser: View {
    @EnvironmentObject var engine: Engine
    /// true ならジェネレーターの一覧（クリップの枠に置くもの）
    var generators = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(generators ? L("ジェネレーターを探す") : L("エフェクトを探す"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))

            Text(generators
                 ? L("動画の代わりに置く絵。クリップの枠へドラッグ、ダブルクリックで選択中のレイヤー（\(engine.layers[engine.selectedLayer].displayName)）の空いている所へ。空きの枠の右クリックからも置ける")
                 : L("付けたい所へドラッグ（クリップ・レイヤー欄・出力モニター・エフェクト欄）。ダブルクリックで今のタブ（\(targetName)）へ"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if generators {
                    // エフェクトと同じく、分類ごとに見出しを付けて並べる
                    ForEach(GeneratorCategory.allCases) { cat in
                        let gens = cat.kinds.filter(matches)
                        if !gens.isEmpty {
                            SectionTitle(cat.label)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                                ForEach(gens) { k in
                                    EffectTile(kind: k, tint: .teal) {
                                        if !engine.placeGeneratorInSelectedLayer(k) { NSSound.beep() }
                                    }
                                }
                            }
                        }
                    }
                    }
                    if !generators {
                    ForEach(EffectCategory.allCases) { cat in
                        let items = EffectKind.allCases.filter { $0.category == cat && !$0.isBlend && !$0.isGenerator && $0 != .transitionMask && matches($0) }
                        if !items.isEmpty {
                            SectionTitle(cat.label)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                                ForEach(items) { k in
                                    EffectTile(kind: k) { add(k) }
                                }
                            }
                        }
                    }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        // 検索欄に勝手に入力カーソルが入ると Esc（ブラックアウト）が効かなくなるので外しておく
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    }

    private func matches(_ k: EffectKind) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return k.label.localizedCaseInsensitiveContains(q) || k.help.localizedCaseInsensitiveContains(q)
            || k.rawValue.localizedCaseInsensitiveContains(q)
    }

    private var targetName: String { engine.currentTabName }

    private func add(_ k: EffectKind) {
        if !engine.addEffectToCurrentTab(k) { NSSound.beep() }
    }
}

/// 一覧の 1 つ。ドラッグで運べる
struct EffectTile: View {
    let kind: EffectKind
    var tint = Color.purple
    let onDoubleClick: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(kind.help).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.10 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(hovering ? 0.6 : 0.25)))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            // カーソルを合わせると、そばに動く見本を出す（説明もそこに出すので、ふつうのヒントは出さない）
            if inside { KindPreviewPanel.shared.hover(kind) } else { KindPreviewPanel.shared.leave(kind) }
        }
        .onDisappear { KindPreviewPanel.shared.leave(kind) }
        .onTapGesture(count: 2) { KindPreviewPanel.shared.hide(); onDoubleClick() }
        .onDrag {
            KindPreviewPanel.shared.hide()
            return NSItemProvider(object: kind.dragString as NSString)
        }
    }
}

/// エフェクトのドロップを受けるかどうかの判定と、受け取り
enum EffectDrop {
    static let types: [UTType] = [.plainText]

    /// providers にエフェクトが入っていれば、そのエフェクトで action を呼ぶ（メインスレッド）。入っていなければ false
    /// ジェネレーターはクリップの枠にだけ置ける（allowGenerators）。ほかの所では受け取らない
    static func handle(_ providers: [NSItemProvider], allowGenerators: Bool = false,
                       _ action: @escaping (EffectKind) -> Void) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let k = EffectKind.fromDragString(s) else { return }
            if k.isGenerator && !allowGenerators { DispatchQueue.main.async { NSSound.beep() }; return }
            DispatchQueue.main.async { action(k) }
        }
        return true
    }
}

extension View {
    /// エフェクトをドロップできる所にする（重なっている間は紫の枠）
    func effectDropTarget(cornerRadius: CGFloat = 6, _ action: @escaping (EffectKind) -> Void) -> some View {
        modifier(EffectDropModifier(cornerRadius: cornerRadius, action: action))
    }
}

private struct EffectDropModifier: ViewModifier {
    let cornerRadius: CGFloat
    let action: (EffectKind) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.purple, lineWidth: 3)
                .opacity(targeted ? 1 : 0)
                .allowsHitTesting(false))
            .onDrop(of: EffectDrop.types, isTargeted: $targeted) { EffectDrop.handle($0, action) }
    }
}

/// エフェクトを選んで足すメニューの中身（分類ごと、一覧と同じ並び）。右クリックのメニューの中や、AddEffectMenu で使う
struct AddEffectMenuItems: View {
    let action: (EffectKind) -> Void

    /// 分類と、その中のエフェクト（空の分類は入れない）
    static var groups: [(EffectCategory, [EffectKind])] {
        EffectCategory.allCases.compactMap { cat in
            let items = EffectKind.allCases.filter { $0.category == cat && !$0.isBlend && !$0.isGenerator && $0 != .transitionMask }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        ForEach(Self.groups, id: \.0) { cat, items in
            Section(cat.label) {
                ForEach(items) { k in
                    Button { action(k) } label: { Label(k.label, systemImage: k.icon) }
                }
            }
        }
    }
}

extension EffectHolder {
    /// 最後に足して、カードを開いておく
    @discardableResult
    func addEffectOpened(_ kind: EffectKind) -> Effect {
        let e = insertEffect(kind, at: effects.count)
        EffectUIState.shared.expanded.insert(e.id)
        return e
    }
}
