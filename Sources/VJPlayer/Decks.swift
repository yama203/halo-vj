import AppKit
import SwiftUI

/// グリッドの上のデッキのタブ。クリックで表示するデッキを切り替える（再生中のクリップはそのまま続く）。
/// 右クリックで名前・複製・削除。＋で空のデッキを足す
struct DeckBar: View {
    @EnvironmentObject var engine: Engine
    /// グリッドの表示の大きさ（大・中・小）
    @AppStorage("gridSize") private var gridSizeRaw = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help("デッキ：グリッドを何枚も持てる。シーンは保存したときのデッキを覚えていて、呼び出すとそのデッキになる")
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(engine.decks.enumerated()), id: \.element.id) { d, deck in
                        DeckTab(index: d, deck: deck)
                    }
                    Button {
                        engine.addDeck()
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    }
                    .controlSize(.small)
                    .padding(.leading, 2)
                    .help("空のデッキを足す（今のデッキを複製するときはタブを右クリック）")
                }
            }
            .scrollIndicators(.never)
            Picker("", selection: $gridSizeRaw) {
                Text("大").tag(0)
                Text("中").tag(1)
                Text("小").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("グリッドの表示の大きさ（小さくすると、たくさんのクリップが見える）")
        }
    }
}

private struct DeckTab: View {
    @EnvironmentObject var engine: Engine
    let index: Int
    let deck: Engine.Deck
    @State private var hovering = false

    var body: some View {
        let on = engine.shownDeck == index
        let live = engine.activeByLayer.contains { $0.map { engine.deckOf($0) == index } ?? false }
        HStack(spacing: 5) {
            Circle().fill(live ? Color.green : Color.gray.opacity(0.35)).frame(width: 6, height: 6)
            Text(deck.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(on ? Color.accentColor.opacity(0.85) : Color.white.opacity(hovering ? 0.12 : 0.06)))
        .foregroundStyle(on ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { engine.showDeck(index) }
        .help(live ? "\(deck.name)（再生中のクリップあり）" : deck.name)
        .contextMenu {
            Button("名前を変える…") {
                if let n = askName(title: "デッキの名前", initial: deck.name) { engine.renameDeck(index, to: n) }
            }
            Button("複製") { engine.addDeck(duplicating: index) }
            Divider()
            Button("削除…", role: .destructive) { remove() }
                .disabled(engine.decks.count <= 1)
        }
    }

    private func remove() {
        let users = engine.scenes.filter { $0.deck == deck.id }.map(\.name)
        var msg = engine.deckHasClips(index) ? "このデッキのクリップはすべて外れます（再生中なら止まります）。" : ""
        if !users.isEmpty { msg += "このデッキを使っているシーン（\(users.joined(separator: "、"))）は 1 枚目のデッキを使うようになります。" }
        if !msg.isEmpty {
            guard confirmRemove(title: "「\(deck.name)」を削除しますか？", message: msg) else { return }
        }
        engine.removeDeck(index)
    }
}

/// 名前を入れてもらう（キャンセル・空なら nil）
func askName(title: String, initial: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "キャンセル")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
}
