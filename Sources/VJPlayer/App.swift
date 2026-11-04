import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
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
        WindowGroup("VJPlayer") {
            ContentView()
                .environmentObject(engine)
        }
        .defaultSize(width: 1440, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("出力") {
                Button("出力を閉じる／元に戻す") { OutputController.shared.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("ブラックアウト") { Engine.shared.blackout() }
                    .keyboardShortcut(.escape, modifiers: [])
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

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKey(event) ? nil : event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 1〜8 / Q〜I / A〜K / Z〜, でスロットを再生（段 = レイヤー）、Esc で全レイヤーをブラックアウト
    private static func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        // テキスト入力中は横取りしない
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }

        if event.keyCode == 53 { // Esc
            Engine.shared.blackout()
            return true
        }
        guard !event.isARepeat, let ch = event.charactersIgnoringModifiers?.uppercased(),
              let i = Engine.keyLabels.firstIndex(of: ch) else { return false }
        Engine.shared.trigger(i)
        return true
    }
}
