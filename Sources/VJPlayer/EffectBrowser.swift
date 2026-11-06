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
                TextField(generators ? "ジェネレーターを探す" : "エフェクトを探す", text: $query)
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
                 ? "動画の代わりに置く絵。クリップの枠へドラッグ、ダブルクリックで選択中のレイヤー（\(engine.layers[engine.selectedLayer].displayName)）の空いている所へ。空きの枠の右クリックからも置ける"
                 : "付けたい所へドラッグ（クリップ・レイヤー欄・出力モニター・エフェクト欄）。ダブルクリックで今のタブ（\(targetName)）へ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    let gens = generators ? EffectKind.generators.filter(matches) : []
                    if !gens.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                            ForEach(gens) { k in
                                EffectTile(kind: k, tint: .teal) {
                                    if !engine.placeGeneratorInSelectedLayer(k) { NSSound.beep() }
                                }
                                .help(k.help + "\nクリップの枠へドラッグして置く／ダブルクリックで選択中のレイヤーの空いている所に置く")
                            }
                        }
                    }
                    if !generators {
                    ForEach(EffectCategory.allCases) { cat in
                        let items = EffectKind.allCases.filter { $0.category == cat && !$0.isBlend && !$0.isGenerator && matches($0) }
                        if !items.isEmpty {
                            SectionTitle(cat.label)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
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

    private var targetName: String {
        switch engine.inspectorTab {
        case .composition: (engine.sceneDraft != nil ? "シーンの" : "") + "コンポジション"
        case .layer: (engine.sceneDraft != nil ? "シーンの" : "") + "レイヤー " + engine.layers[engine.selectedLayer].displayName
        case .clip: engine.inspectedIndex.flatMap { engine.slots[$0]?.name }.map { "クリップ " + $0 } ?? "クリップ（未選択）"
        }
    }

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
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onDoubleClick)
        .onDrag { NSItemProvider(object: kind.dragString as NSString) }
        .help(kind.help + "\nドラッグして付ける／ダブルクリックで今のタブに付ける")
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
