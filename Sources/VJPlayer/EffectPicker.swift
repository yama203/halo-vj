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

    /// 出す順の分類（見出し・中身）
    static func sections(includeGenerators: Bool) -> [(String, [EffectKind])] {
        var out = AddEffectMenuItems.groups.map { ($0.0.label, $0.1) }
        if includeGenerators {
            out += GeneratorCategory.allCases.map { ("ジェネレーター：" + $0.label, $0.kinds) }.filter { !$0.1.isEmpty }
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

    /// 当たったもの（名前に当たるものを先に）
    static func results(_ query: String, includeGenerators: Bool) -> [EffectKind] {
        let all = sections(includeGenerators: includeGenerators).flatMap(\.1).filter { matches($0, query) }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let kata = q.applyingTransform(.hiraganaToKatakana, reverse: false) ?? q
        let byName = all.filter { $0.label.localizedCaseInsensitiveContains(q) || $0.label.localizedCaseInsensitiveContains(kata)
            || $0.rawValue.localizedCaseInsensitiveContains(q) }
        return byName + all.filter { !byName.contains($0) }
    }

    private var results: [EffectKind] { Self.results(query, includeGenerators: includeGenerators) }

    var body: some View {
        let list = results
        VStack(alignment: .leading, spacing: 8) {
            if let targetLabel {
                Text(targetLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(includeGenerators ? "エフェクト・ジェネレーターを探す" : "エフェクトを探す（名前・英語・ひらがな）",
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
                            Text("見つかりません").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            // 何も打っていないときは分類ごとに
                            ForEach(Self.sections(includeGenerators: includeGenerators), id: \.0) { title, kinds in
                                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.top, 6).padding(.leading, 6)
                                ForEach(kinds) { k in row(k, index: list.firstIndex(of: k) ?? 0) }
                            }
                        } else {
                            ForEach(Array(list.enumerated()), id: \.element) { i, k in row(k, index: i) }
                        }
                    }
                }
                .onChange(of: highlight) { _, h in
                    if list.indices.contains(h) { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(list[h]) } }
                }
            }
            Text("↑↓ で選んで Enter・クリックで足す・Esc で閉じる")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 340, height: 420)
        .onChange(of: query) { _, _ in highlight = 0 }
        .onAppear { DispatchQueue.main.async { focused = true } }
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
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .onHover { if $0 { highlight = index } }
        .onTapGesture { choose(k) }
        .id(k)
    }

    private func move(_ d: Int, count: Int) {
        guard count > 0 else { return }
        highlight = (highlight + d + count) % count
    }

    private func choose(_ k: EffectKind) {
        pick(k)
        close()
    }
}

/// 開発用：決まった検索の文字を入れた状態の窓
struct EffectPickerPreview: View {
    let query: String
    let generators: Bool
    var body: some View {
        EffectPicker(includeGenerators: generators, targetLabel: generators ? "今のタブ：クリップ（例）" : nil,
                     pick: { _ in }, query: query)
    }
}

/// 押すと探す窓が開くボタン
struct AddEffectMenu: View {
    var title = "エフェクトを追加"
    let action: (EffectKind) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Label(title, systemImage: "plus")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help("エフェクトを名前で探して足す（「エフェクト」パネルからドラッグしても足せる。⌘E で今のタブに足す窓）")
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
        let target = "今のタブ：" + engine.currentTabName + "（ジェネレーターは " + engine.layers[engine.selectedLayer].displayName + " の空き枠へ）"
        let view = EffectPicker(includeGenerators: true, targetLabel: target, pick: { k in
            if k.isGenerator {
                if !engine.placeGeneratorInSelectedLayer(k) { NSSound.beep() }
            } else if !engine.addEffectToCurrentTab(k) {
                NSSound.beep()
            }
        }, close: { [weak self] in self?.close() })
            .environment(\.colorScheme, .dark)
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
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
            p.setFrameOrigin(NSPoint(x: f.midX - 170, y: f.maxY - 420 - 120))
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
