import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--od-preview"), args.count > i + 1 {
            // 開発用：オーバードライブ加算の見え方を、決まった絵で 1 枚書き出す
            //   VJPlayer --od-preview out.png [にじみ 広がり 色相 波紋 細かさ 抑え 速さ 波紋の広がり] [時刻]
            let vals = args.dropFirst(i + 2).compactMap(Double.init)
            SelfTest.odPreview(path: args[i + 1], values: Array(vals.prefix(8)), time: vals.count > 8 ? vals[8] : 10)
            exit(0)
        }
        if let i = args.firstIndex(of: "--selftest") {
            // 画面を出さずにエンジンだけ検証する
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in SelfTest.run(paths: Array(args[(i + 1)...])) }
            app.run()
        } else {
            VJPlayerApp.main()
        }
    }
}

struct VJPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            ContentView()
                .environmentObject(engine)
                // ファイルを開いても新しいウィンドウを作らず、今のウィンドウで開く
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1440, height: 820)
        .windowResizability(.contentMinSize)
        Settings {
            SettingsView()
                .environmentObject(engine)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新規プロジェクト") { ProjectMenu.new() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("プロジェクトを開く…") { ProjectMenu.open() }
                    .keyboardShortcut("o", modifiers: .command)
                RecentProjectsMenu(engine: engine)
                Divider()
                Button("見つからない動画を探す…") { ProjectMenu.findMissing() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { ProjectMenu.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("別名で保存…") { ProjectMenu.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("出力") {
                Button("出力を閉じる／元に戻す") { OutputController.shared.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("ブラックアウト／解除") { Engine.shared.toggleBlackout() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("全レイヤーを停止") { Engine.shared.stopAll() }
                    .keyboardShortcut(.escape, modifiers: [.shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 本番中にスリープ・App Nap で止まらないようにする
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
            reason: "VJ 出力中")

        // 画面確認用：VJ_TRIGGER=番号,番号 で起動時にそのクリップを再生する
        if let v = ProcessInfo.processInfo.environment["VJ_TRIGGER"] {
            let list = v.split(separator: ",").compactMap { Int($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { list.forEach { Engine.shared.trigger($0) } }
        }
        // 画面確認用：VJ_SELECT_CLIP=番号 で起動時にそのクリップを選んでおく
        if let v = ProcessInfo.processInfo.environment["VJ_SELECT_CLIP"], let i = Int(v) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Engine.shared.selectClip(i) }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKey(event) ? nil : event
        }
    }

    /// Finder でプロジェクトファイルをダブルクリック／アイコンにドロップしたとき
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { ["halovj", "vjproj"].contains($0.pathExtension.lowercased()) }) else { return }
        // 起動直後でも画面ができてから開く
        DispatchQueue.main.async { ProjectMenu.open(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // プロジェクトを開いていて未保存の変更があれば聞く（今の状態は自動保存にも残る）
        if Engine.shared.projectURL != nil && Engine.shared.isDirty {
            return ProjectMenu.confirmDiscard("終了する") ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Esc でブラックアウト切り替え、⇧Esc で全レイヤー停止。
    /// （クリップのキー割り当ては、あとで手動で決められるようにする予定。今は割り当てなし）
    private static func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        // テキスト入力中は横取りしない
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }

        if event.keyCode == 53 { // Esc
            if event.isARepeat { return true }
            if shift { Engine.shared.stopAll() } else { Engine.shared.toggleBlackout() }
            return true
        }
        return false
    }
}
