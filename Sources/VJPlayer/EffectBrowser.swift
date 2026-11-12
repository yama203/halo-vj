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
    @ObservedObject private var fav = EffectFavorites.shared

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
                    // いちばん上に「お気に入り」と「最近使った」（探しているときは出さない。下の分類の中にもある）
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let favs = fav.favorites.filter(belongsHere)
                        if !favs.isEmpty {
                            SectionTitle(L("お気に入り"), icon: "star.fill", tint: .yellow)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                                ForEach(favs) { k in tile(k) }
                            }
                        }
                        let recents = fav.recents.filter(belongsHere)
                        if !recents.isEmpty {
                            SectionTitle(L("最近使った"), icon: "clock")
                                            // 1 行ぶん（多いときは横にスクロール）
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(recents) { k in tile(k).frame(width: 190) }
                                }
                            }
                        }
                    }
                    if generators {
                    // エフェクトと同じく、分類ごとに見出しを付けて並べる
                    ForEach(GeneratorCategory.allCases) { cat in
                        let gens = cat.kinds.filter(matches)
                        if !gens.isEmpty {
                            SectionTitle(cat.label)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                                ForEach(gens) { k in tile(k) }
                            }
                        }
                    }
                    }
                    if !generators {
                    ForEach(EffectCategory.allCases) { cat in
                        let items = EffectKind.allCases.filter { $0.category == cat && $0.inEffectList && matches($0) }
                        if !items.isEmpty {
                            SectionTitle(cat.label)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                                ForEach(items) { k in tile(k) }
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

    /// このパネルに出す種類か（エフェクトのパネルにはエフェクトだけ、ジェネレーターのパネルにはジェネレーターだけ）
    private func belongsHere(_ k: EffectKind) -> Bool {
        generators ? GeneratorCategory.allCases.contains { $0.kinds.contains(k) } : k.inEffectList
    }

    private func tile(_ k: EffectKind) -> some View {
        EffectTile(kind: k, tint: generators ? .teal : .purple) { add(k) }
    }

    /// ダブルクリック：エフェクトは今のタブへ、ジェネレーターは選択中のレイヤーの空き枠へ
    private func add(_ k: EffectKind) {
        let ok = generators ? engine.placeGeneratorInSelectedLayer(k) : engine.addEffectToCurrentTab(k)
        if ok { EffectFavorites.shared.note(k) } else { NSSound.beep() }
    }
}

/// 一覧の 1 つ。ドラッグで運べる
struct EffectTile: View {
    let kind: EffectKind
    var tint = Color.purple
    let onDoubleClick: () -> Void
    @State private var hovering = false
    @ObservedObject private var fav = EffectFavorites.shared

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
        // 右上の星のぶん、名前を少し手前で切る
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.10 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(hovering ? 0.6 : 0.25)))
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            // お気に入りの星：入っていれば出たまま、入っていなければマウスを乗せたときだけ
            let on = fav.isFavorite(kind)
            if on || hovering {
                Button { fav.toggle(kind) } label: {
                    Image(systemName: on ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundStyle(on ? Color.yellow : Color.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .help(on ? L("お気に入りから外す") : L("お気に入りに入れる"))
            }
        }
        .contextMenu { FavoriteMenuItem(kind: kind) }
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

/// 右クリックの「お気に入りに入れる／お気に入りから外す」
struct FavoriteMenuItem: View {
    let kind: EffectKind
    @ObservedObject private var fav = EffectFavorites.shared

    var body: some View {
        if fav.isFavorite(kind) {
            Button { fav.toggle(kind) } label: { Label(L("お気に入りから外す"), systemImage: "star.slash") }
        } else {
            Button { fav.toggle(kind) } label: { Label(L("お気に入りに入れる"), systemImage: "star") }
        }
    }
}

/// エフェクトのドロップを受けるかどうかの判定と、受け取り
enum EffectDrop {
    static let types: [UTType] = [.plainText]

    /// providers にエフェクトが入っていれば、そのエフェクトで action を呼ぶ（メインスレッド）。入っていなければ false
    /// ジェネレーターはクリップの枠にだけ置ける（allowGenerators）。ほかの所では受け取らない。
    /// カードをドラッグしてきた（付け替え）なら move を呼ぶ（copy は ⌥ を押していたか）。move が無ければ断る
    static func handle(_ providers: [NSItemProvider], allowGenerators: Bool = false, copy: Bool = false,
                       move: ((UUID, Bool) -> Void)? = nil, _ action: @escaping (EffectKind) -> Void) -> Bool {
        loadString(providers) { s in
            if let id = EffectTransfer.moveID(s) {
                if let move { move(id, copy) } else { NSSound.beep() }
                EffectDragState.shared.end()
                return
            }
            guard let k = EffectKind.fromDragString(s) else { return }
            if k.isGenerator && !allowGenerators { NSSound.beep(); return }
            EffectFavorites.shared.note(k)
            action(k)
        }
    }
}

extension View {
    /// エフェクトをドロップできる所にする（重なっている間は紫の枠）。
    /// place を渡すと、ほかの場所のカードをドラッグしてきたとき、ここへ付け替える（⌥ で写す）
    func effectDropTarget(cornerRadius: CGFloat = 6, place: EffectPlace? = nil,
                          _ action: @escaping (EffectKind) -> Void) -> some View {
        modifier(EffectDropModifier(cornerRadius: cornerRadius,
                                    move: place.map { p in { id, copy in EffectTransfer.drop(id, to: p, copy: copy) } },
                                    action: action))
    }

    /// 付け替えを自分で受ける形（並びの「＋ エフェクト」の枠など）。move は (id, 写すか) で、付け替えたら true
    func effectDropTarget(cornerRadius: CGFloat = 6, move: @escaping (UUID, Bool) -> Bool,
                          _ action: @escaping (EffectKind) -> Void) -> some View {
        modifier(EffectDropModifier(cornerRadius: cornerRadius, move: move, action: action))
    }
}

private struct EffectDropModifier: ViewModifier {
    let cornerRadius: CGFloat
    /// 付け替え（無ければ受けない）
    let move: ((UUID, Bool) -> Bool)?
    let action: (EffectKind) -> Void
    @State private var targeted = false
    @State private var flash = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.purple, lineWidth: 3)
                .opacity(targeted || flash ? 1 : 0)
                .allowsHitTesting(false))
            .onDrop(of: EffectDrop.types, delegate: EffectDropDelegate(targeted: $targeted) { providers, copy in
                EffectDrop.handle(providers, copy: copy, move: move.map { m in { id, copy in
                    // 付け替えたら、落とした先を少しの間光らせる
                    guard m(id, copy) else { return }
                    flash = true
                    withAnimation(.easeOut(duration: 0.4)) { flash = false }
                } }, action)
            })
    }
}

/// エフェクトを選んで足すメニューの中身（分類ごと、一覧と同じ並び）。右クリックのメニューの中や、AddEffectMenu で使う
struct AddEffectMenuItems: View {
    let action: (EffectKind) -> Void

    /// 分類と、その中のエフェクト（空の分類は入れない）
    static var groups: [(EffectCategory, [EffectKind])] {
        EffectCategory.allCases.compactMap { cat in
            let items = EffectKind.allCases.filter { $0.category == cat && $0.inEffectList }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        ForEach(Self.groups, id: \.0) { cat, items in
            Section(cat.label) {
                ForEach(items) { k in
                    Button { EffectFavorites.shared.note(k); action(k) } label: { Label(k.label, systemImage: k.icon) }
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
