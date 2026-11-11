import AppKit
import SwiftUI

/// エフェクト（とジェネレーター）を名前で探して選ぶ窓。打つと絞り込み、↑↓ で選んで Enter で決める。
/// 名前・説明・英語名で探せる。ひらがなで打ってもカタカナの名前に当たる
struct EffectPicker: View {
    /// ジェネレーターも出す（⌘E の窓）
    var includeGenerators = false
    /// どこに足すか（上に小さく出す）
    var targetLabel: String? = nil
    let pick: (EffectKind) -> Void
    var close: () -> Void = {}

    @State var query = ""
    @State private var highlight = 0
    @FocusState private var focused: Bool
    @ObservedObject private var fav = EffectFavorites.shared

    /// 出す順の分類（見出し・中身）
    static func sections(includeGenerators: Bool) -> [(String, [EffectKind])] {
        var out = AddEffectMenuItems.groups.map { ($0.0.label, $0.1) }
        if includeGenerators {
            out += GeneratorCategory.allCases.map { (L("ジェネレーター：") + $0.label, $0.kinds) }.filter { !$0.1.isEmpty }
        }
        return out
    }

    /// 検索の文字に当たるか（ひらがなはカタカナにしても比べる。空白で区切るとどれも含むもの）
    static func matches(_ k: EffectKind, _ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let hay = [k.label, k.help, k.rawValue, k.isGenerator ? "ジェネレーター generator" : "エフェクト effect"]
        return words.allSatisfy { w in
            let kata = w.applyingTransform(.hiraganaToKatakana, reverse: false) ?? w
            return hay.contains { $0.localizedCaseInsensitiveContains(w) || $0.localizedCaseInsensitiveContains(kata) }
        }
    }

    /// 何も打っていないときの並び。いちばん上に「お気に入り」、次に「最近使った」、そのあと分類ごと
    /// （上の 2 つの中身は下の分類にも出る。この窓に出ない種類は入れない）
    static func emptySections(includeGenerators: Bool, favorites: [EffectKind], recents: [EffectKind]) -> [(String, [EffectKind])] {
        let base = sections(includeGenerators: includeGenerators)
        let shown = Set(base.flatMap(\.1))
        var out: [(String, [EffectKind])] = []
        let f = favorites.filter(shown.contains)
        if !f.isEmpty { out.append((L("お気に入り"), f)) }
        let r = recents.filter(shown.contains)
        if !r.isEmpty { out.append((L("最近使った"), r)) }
        return out + base
    }

    /// 当たったもの（名前に当たるものを先に。同じ当たり方の中ではお気に入りを先に）。
    /// 何も打っていないときは emptySections の順（お気に入り・最近使ったは 2 回出る）
    static func results(_ query: String, includeGenerators: Bool,
                        favorites: [EffectKind] = [], recents: [EffectKind] = []) -> [EffectKind] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return emptySections(includeGenerators: includeGenerators, favorites: favorites, recents: recents).flatMap(\.1)
        }
        let all = sections(includeGenerators: includeGenerators).flatMap(\.1).filter { matches($0, query) }
        let kata = q.applyingTransform(.hiraganaToKatakana, reverse: false) ?? q
        let byName = all.filter { $0.label.localizedCaseInsensitiveContains(q) || $0.label.localizedCaseInsensitiveContains(kata)
            || $0.rawValue.localizedCaseInsensitiveContains(q) }
        let fav = Set(favorites)
        func favFirst(_ ks: [EffectKind]) -> [EffectKind] { ks.filter(fav.contains) + ks.filter { !fav.contains($0) } }
        return favFirst(byName) + favFirst(all.filter { !byName.contains($0) })
    }

    /// 画面に出る行の並び（区分の見出し・中身）。検索中は見出しの無い 1 つの区分
    static func rows(_ query: String, includeGenerators: Bool,
                     favorites: [EffectKind], recents: [EffectKind]) -> [(String, [EffectKind])] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return emptySections(includeGenerators: includeGenerators, favorites: favorites, recents: recents)
        }
        return [("", results(query, includeGenerators: includeGenerators, favorites: favorites, recents: recents))]
    }

    /// 星を押して並びが変わったあと、同じ種類を指す番号（同じ区分の行。無ければ同じ種類の最初の行）。
    /// 番号のままだと、並びがずれて、すぐ Enter で隣の別の種類が足されてしまうので
    static func reselect(_ index: Int, before: [(String, [EffectKind])], after: [(String, [EffectKind])]) -> Int? {
        var i = index
        var section: String?, kind: EffectKind?
        for sec in before {
            if i < sec.1.count { section = sec.0; kind = sec.1[i]; break }
            i -= sec.1.count
        }
        guard let kind else { return nil }
        var start = 0, first: Int?
        for sec in after {
            if let j = sec.1.firstIndex(of: kind) {
                if sec.0 == section { return start + j }
                if first == nil { first = start + j }
            }
            start += sec.1.count
        }
        return first
    }

    /// 星を押す。選んでいた行が同じ種類を指したままになるよう、番号を付け直す
    private func toggleFavorite(_ k: EffectKind) {
        func now() -> [(String, [EffectKind])] {
            Self.rows(query, includeGenerators: includeGenerators, favorites: fav.favorites, recents: fav.recents)
        }
        let before = now()
        fav.toggle(k)
        if let i = Self.reselect(highlight, before: before, after: now()) { highlight = i }
    }

    private var results: [EffectKind] {
        Self.results(query, includeGenerators: includeGenerators, favorites: fav.favorites, recents: fav.recents)
    }

    var body: some View {
        let list = results
        HStack(alignment: .top, spacing: 12) {
            search(list)
            // 選んでいるものの、動く見本
            VStack(alignment: .leading) {
                if list.indices.contains(highlight) {
                    KindPreviewCard(kind: list[highlight], width: 270)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 270)
        }
        .padding(12)
        .frame(width: 340 + 270 + 12, height: 420)
        .onChange(of: query) { _, _ in highlight = 0 }
        .onAppear {
            DispatchQueue.main.async { focused = true }
            KindPreview.shared.show(list.indices.contains(highlight) ? list[highlight] : nil)
        }
        .onChange(of: list.indices.contains(highlight) ? list[highlight] : nil) { _, k in KindPreview.shared.show(k) }
        .onDisappear { KindPreview.shared.show(nil) }
    }

    private func search(_ list: [EffectKind]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let targetLabel {
                Text(targetLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(includeGenerators ? L("エフェクト・ジェネレーターを探す") : L("エフェクトを探す（名前・英語・ひらがな）"),
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { if list.indices.contains(highlight) { choose(list[highlight]) } }
                    .onKeyPress(.downArrow) { move(1, count: list.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: list.count); return .handled }
                    .onExitCommand { close() }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        if list.isEmpty {
                            Text(L("見つかりません")).font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            // 何も打っていないときは分類ごとに（上にお気に入り・最近使った）
                            let secs = Self.emptySections(includeGenerators: includeGenerators,
                                                          favorites: fav.favorites, recents: fav.recents)
                            let starts = secs.indices.map { i in secs[..<i].reduce(0) { $0 + $1.1.count } }
                            ForEach(Array(secs.enumerated()), id: \.offset) { si, sec in
                                Text(sec.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.top, 6).padding(.leading, 6)
                                ForEach(Array(sec.1.enumerated()), id: \.offset) { j, k in row(k, index: starts[si] + j) }
                            }
                        } else {
                            ForEach(Array(list.enumerated()), id: \.offset) { i, k in row(k, index: i) }
                        }
                    }
                }
                .onChange(of: highlight) { _, h in
                    if list.indices.contains(h) { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(h) } }
                }
            }
            Text(L("↑↓ で選んで Enter・クリックで足す・Esc で閉じる"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(width: 316)
    }

    private func row(_ k: EffectKind, index: Int) -> some View {
        let on = index == highlight
        let tint: Color = k.isGenerator ? .teal : .purple
        return HStack(spacing: 8) {
            Image(systemName: k.icon).font(.system(size: 14)).foregroundStyle(on ? Color.white : tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(k.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(k.help).font(.system(size: 10)).foregroundStyle(on ? Color.white.opacity(0.8) : .secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            // 右端の星：お気に入りなら出たまま、選んでいる行では押して入れられる
            let isFav = fav.isFavorite(k)
            if isFav || on {
                Button { toggleFavorite(k) } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundStyle(isFav ? Color.yellow : Color.white.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isFav ? L("お気に入りから外す") : L("お気に入りに入れる"))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .onHover { if $0 { highlight = index } }
        .onTapGesture { choose(k) }
        .contextMenu { FavoriteMenuItem(kind: k) }
        .id(index)
    }

    private func move(_ d: Int, count: Int) {
        guard count > 0 else { return }
        highlight = (highlight + d + count) % count
    }

    private func choose(_ k: EffectKind) {
        EffectFavorites.shared.note(k)
        pick(k)
        close()
    }
}

/// 開発用：決まった検索の文字を入れた状態の窓
struct EffectPickerPreview: View {
    let query: String
    let generators: Bool
    var body: some View {
        EffectPicker(includeGenerators: generators, targetLabel: generators ? L("今のタブ：クリップ（例）") : nil,
                     pick: { _ in }, query: query)
    }
}

/// 押すと探す窓が開くボタン
struct AddEffectMenu: View {
    var title = L("エフェクトを追加")
    let action: (EffectKind) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Label(title, systemImage: "plus")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(L("エフェクトを名前で探して足す（「エフェクト」パネルからドラッグしても足せる。⌘E で今のタブに足す窓）"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            EffectPicker(pick: action, close: { open = false })
        }
    }
}

extension View {
    /// 右クリックの「探して追加…」から開く、エフェクトを探す窓
    func effectPickerPopover(_ isPresented: Binding<Bool>, targetLabel: String? = nil,
                             _ action: @escaping (EffectKind) -> Void) -> some View {
        popover(isPresented: isPresented, arrowEdge: .bottom) {
            EffectPicker(targetLabel: targetLabel, pick: action, close: { isPresented.wrappedValue = false })
        }
    }
}

/// ⌘E：今のタブ（コンポジション・レイヤー・クリップ）にエフェクトを足す／選択中のレイヤーにジェネレーターを置く窓。
/// 画面の上の方に浮かぶ（Spotlight のように）
final class EffectSearchPanel: NSObject, NSWindowDelegate {
    static let shared = EffectSearchPanel()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        show()
    }

    func show() {
        let engine = Engine.shared
        let target = L("今のタブ：\(engine.currentTabName)（ジェネレーターは \(engine.layers[engine.selectedLayer].displayName) の空き枠へ）")
        let view = EffectPicker(includeGenerators: true, targetLabel: target, pick: { k in
            if k.isGenerator {
                if !engine.placeGeneratorInSelectedLayer(k) { NSSound.beep() }
            } else if !engine.addEffectToCurrentTab(k) {
                NSSound.beep()
            }
        }, close: { [weak self] in self?.close() })
            .environment(\.colorScheme, .dark)
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 622, height: 444),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = true
            p.delegate = self
            return p
        }()
        p.contentView = NSHostingView(rootView: view)
        if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            let f = main.frame
            p.setFrameOrigin(NSPoint(x: f.midX - 311, y: f.maxY - 444 - 120))
        } else {
            p.center()
        }
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    /// ほかの所を押したら閉じる
    func windowDidResignKey(_ notification: Notification) { close() }
}
