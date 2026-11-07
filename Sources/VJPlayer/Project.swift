import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// プロジェクトファイル（.halovj）のメニュー操作：新規・開く・保存・別名で保存・最近使った・見つからない動画を探す
enum ProjectMenu {
    static var engine: Engine { .shared }
    static var fileType: UTType {
        UTType("local.yama.halovj.project") ?? UTType(filenameExtension: Engine.projectExtension) ?? .json
    }
    /// 開けるもの：今の .halovj と、名前を変える前の .vjproj
    static var openTypes: [UTType] {
        [Engine.projectExtension, "vjproj"].compactMap { UTType(filenameExtension: $0) }
    }

    /// 未保存の変更があれば「保存しますか？」と聞く。続けてよければ true
    static func confirmDiscard(_ action: String) -> Bool {
        guard engine.isDirty else { return true }
        let alert = NSAlert()
        let name = engine.projectURL?.deletingPathExtension().lastPathComponent ?? "名称未設定"
        alert.messageText = "「\(name)」の変更を保存しますか？"
        alert.informativeText = "保存しないと、\(action)前の変更はプロジェクトファイルに残りません。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "保存しない")
        alert.addButton(withTitle: "キャンセル")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    static func new() {
        guard confirmDiscard("新規にする") else { return }
        engine.newProject()
    }

    static func open() {
        guard confirmDiscard("開く") else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = openTypes
        panel.allowsMultipleSelection = false
        panel.message = "Halo VJ のプロジェクト（.\(Engine.projectExtension)。以前の .vjproj も開けます）を選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, confirmed: true)
    }

    static func open(_ url: URL, confirmed: Bool = false) {
        guard confirmed || confirmDiscard("開く") else { return }
        do {
            try engine.openProject(url)
        } catch {
            showError("開けませんでした", error)
            return
        }
        if engine.missingCount > 0 { offerFindMissing() }
    }

    /// 保存する（まだ名前が無ければ別名で保存）。保存できたら true
    @discardableResult
    static func save() -> Bool {
        guard let url = engine.projectURL else { return saveAs() }
        do {
            try engine.saveProject(to: url)
            return true
        } catch {
            showError("保存できませんでした", error)
            return false
        }
    }

    @discardableResult
    static func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = engine.projectURL?.lastPathComponent ?? "名称未設定.\(Engine.projectExtension)"
        if let dir = engine.projectURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.message = "動画と同じフォルダ（またはその上）に保存すると、フォルダごと動かしても開けます"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try engine.saveProject(to: url)
            return true
        } catch {
            showError("保存できませんでした", error)
            return false
        }
    }

    /// 見つからない動画があるとき：フォルダを選んで同じ名前の動画を探す
    static func offerFindMissing() {
        let n = engine.missingCount
        guard n > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "\(n) 個の動画が見つかりません"
        alert.informativeText = "動画が入っているフォルダを選ぶと、同じ名前のファイルを探して付け直します（設定はそのまま）。あとからメニューの「見つからない動画を探す…」でもできます。"
        alert.addButton(withTitle: "フォルダを選ぶ…")
        alert.addButton(withTitle: "あとで")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        findMissing()
    }

    static func findMissing() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "見つからない動画が入っているフォルダを選んでください（中のフォルダも探します）"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let before = engine.missingCount
        let found = engine.relinkMissing(searchingIn: dir)
        let alert = NSAlert()
        alert.messageText = found > 0 ? "\(found) 個を付け直しました" : "見つかりませんでした"
        let left = before - found
        alert.informativeText = left > 0 ? "まだ \(left) 個見つかりません。クリップを右クリック →「動画ファイルを付け直す…」で 1 つずつ選べます。" : ""
        alert.runModal()
    }

    /// 1 つのクリップの動画を選び直す（設定はそのまま）
    static func relink(_ index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie] + StillImage.openTypes
        panel.message = "このクリップの動画ファイルを選んでください（位置・エフェクトなどの設定はそのまま）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.relinkSlot(index, to: url)
    }

    static func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// ウィンドウのタイトル（プロジェクト名）と、未保存の印（閉じるボタンの点）を合わせる
struct WindowTitleSync: NSViewRepresentable {
    let title: String
    let url: URL?
    let edited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.title = title
            w.representedURL = url
            w.isDocumentEdited = edited
        }
    }
}

/// 「ファイル」メニューの「最近使ったプロジェクト」
struct RecentProjectsMenu: View {
    @ObservedObject var engine: Engine

    var body: some View {
        Menu("最近使ったプロジェクト") {
            let list = engine.recentProjects
            ForEach(list, id: \.self) { u in
                Button(u.deletingPathExtension().lastPathComponent) { ProjectMenu.open(u) }
            }
            if !list.isEmpty {
                Divider()
                Button("履歴を消去") { engine.clearRecent() }
            }
        }
    }
}
