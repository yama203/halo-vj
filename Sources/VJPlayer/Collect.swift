import AppKit
import SwiftUI

// 素材をまとめて保存：使っている動画・画像を、プロジェクトのフォルダの「素材」にコピーして、
// 別の Mac へフォルダごと持っていけるようにする（プロジェクトには、素材の場所をそのフォルダからの位置で書く）。

extension Engine {
    struct CollectResult {
        var projectURL: URL
        var copied: Int
        var reused: Int
        var missing: [String]
    }

    /// まとめる中身（メインスレッドで作る）：コピーする素材と、プロジェクトの中身
    struct CollectPlan {
        var sources: [String]
        var state: SavedState
        var projDir: URL
        var name: String
    }

    func collectPlan(into folder: URL, name: String) -> CollectPlan {
        let projDir = folder.appendingPathComponent(name, isDirectory: true)
        var sources: [String] = []
        for s in slots.compactMap({ $0 }) where s.generator == nil && !s.isEffectClip {
            let p = s.url.standardizedFileURL.path
            if !sources.contains(p) { sources.append(p) }
        }
        return CollectPlan(sources: sources, state: makeState(relativeTo: projDir), projDir: projDir, name: name)
    }

    /// まとめる（コピーして、プロジェクトを書く）。別のスレッドから呼べる。progress は 0〜1
    static func collect(_ plan: CollectPlan, progress: ((Double, String) -> Void)? = nil) throws -> CollectResult {
        let fm = FileManager.default
        let projDir = plan.projDir, name = plan.name, sources = plan.sources
        let media = projDir.appendingPathComponent("素材", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        var map: [String: String] = [:]   // 元の場所 → 素材の中の名前
        var used: Set<String> = []
        var copied = 0, reused = 0
        var missing: [String] = []
        let total = Double(max(sources.count, 1))
        for (k, p) in sources.enumerated() {
            let src = URL(fileURLWithPath: p)
            progress?(Double(k) / total, src.lastPathComponent)
            guard fm.fileExists(atPath: p) else { missing.append(src.lastPathComponent); continue }
            // 名前がぶつかったら番号を付ける（中身が同じなら使い回す）
            var fileName = src.lastPathComponent
            var n = 2
            while used.contains(fileName.lowercased()) {
                fileName = src.deletingPathExtension().lastPathComponent + " \(n)." + src.pathExtension
                n += 1
            }
            used.insert(fileName.lowercased())
            let dst = media.appendingPathComponent(fileName)
            if fm.fileExists(atPath: dst.path) {
                let a = try? fm.attributesOfItem(atPath: p)[.size] as? Int, b = try? fm.attributesOfItem(atPath: dst.path)[.size] as? Int
                if a != nil && a == b { reused += 1; map[p] = fileName; continue }
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
            copied += 1
            map[p] = fileName
        }
        progress?(1, "")
        // プロジェクト：素材の場所は「素材/名前」で書く（元の場所も残す）
        var state = plan.state
        for i in state.slots.indices {
            guard var s = state.slots[i], s.generator == nil, s.effectClip != true else { continue }
            let p = URL(fileURLWithPath: s.path).standardizedFileURL.path
            if let f = map[p] {
                s.relPath = "素材/" + f
                s.path = media.appendingPathComponent(f).path
                state.slots[i] = s
            }
        }
        let url = projDir.appendingPathComponent(name).appendingPathExtension(projectExtension)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(state).write(to: url, options: .atomic)
        return CollectResult(projectURL: url, copied: copied, reused: reused, missing: missing)
    }
}

/// 「ファイル」メニューの「素材をまとめて保存…」
enum CollectMenu {
    static func run() {
        let e = Engine.shared
        let panel = NSSavePanel()
        panel.title = "素材をまとめて保存"
        panel.message = "この名前のフォルダを作り、中にプロジェクトと「素材」フォルダ（使っている動画・画像のコピー）を入れます"
        panel.nameFieldStringValue = e.projectURL?.deletingPathExtension().lastPathComponent ?? "名称未設定"
        panel.prompt = "まとめる"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.deletingLastPathComponent(), name = url.deletingPathExtension().lastPathComponent
        let prog = CollectProgress()
        let win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "素材をまとめています"
        win.contentView = NSHostingView(rootView: CollectProgressView(p: prog).padding(16).frame(width: 420))
        win.center()
        win.makeKeyAndOrderFront(nil)
        let plan = e.collectPlan(into: folder, name: name)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Engine.collect(plan) { v, f in
                DispatchQueue.main.async { prog.value = v; prog.file = f }
            } }
            DispatchQueue.main.async {
                win.orderOut(nil)
                switch result {
                case .success(let r):
                    let a = NSAlert()
                    a.messageText = "素材をまとめました"
                    a.informativeText = "コピー \(r.copied) 個" + (r.reused > 0 ? "（前にコピーしたもの \(r.reused) 個はそのまま）" : "")
                        + (r.missing.isEmpty ? "" : "。見つからなかった素材：" + r.missing.joined(separator: "、"))
                        + "\nまとめたプロジェクトを開き直します（再生中のクリップは止まります）。"
                    a.addButton(withTitle: "開き直す")
                    a.addButton(withTitle: "Finder で表示")
                    let resp = a.runModal()
                    if resp == .alertSecondButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([r.projectURL])
                    }
                    ProjectMenu.open(r.projectURL)
                case .failure(let err):
                    ProjectMenu.showError("素材をまとめられませんでした", err)
                }
            }
        }
    }
}

final class CollectProgress: ObservableObject {
    @Published var value = 0.0
    @Published var file = ""
}

private struct CollectProgressView: View {
    @ObservedObject var p: CollectProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: p.value)
            Text(p.file.isEmpty ? "…" : "コピー中：" + p.file).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
