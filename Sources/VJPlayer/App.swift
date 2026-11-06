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
        if let i = args.firstIndex(of: "--text-preview"), args.count > i + 1 {
            // 開発用：テキストのジェネレーターの見た目を 1 枚に並べて書き出す  VJPlayer --text-preview out.png [時刻]
            let t = args.count > i + 2 ? Double(args[i + 2]) ?? 1.3 : 1.3
            SelfTest.textPreview(path: args[i + 1], time: t)
            exit(0)
        }
        if let i = args.firstIndex(of: "--gen-preview"), args.count > i + 2, let k = EffectKind(rawValue: args[i + 1]) {
            // 開発用：ジェネレーターを 1 枚書き出す  VJPlayer --gen-preview phyllotaxis out.png [秒] [値 値 …] [--random 0.8]
            let rest = Array(args.dropFirst(i + 3))
            let nums = rest.prefix { $0 != "--random" }.compactMap(Double.init)
            let rnd = rest.firstIndex(of: "--random").flatMap { rest.count > $0 + 1 ? Double(rest[$0 + 1]) : nil }
            SelfTest.genPreview(kind: k, path: args[i + 2], time: nums.first ?? 8, values: Array(nums.dropFirst()), random: rnd)
            exit(0)
        }
        if let i = args.firstIndex(of: "--od-bench") {
            // 開発用：オーバードライブ加算の GPU 時間を測る  VJPlayer --od-bench [幅 高さ]
            let n = args.dropFirst(i + 1).compactMap(Int.init)
            SelfTest.odBench(width: n.count > 1 ? n[0] : 1920, height: n.count > 1 ? n[1] : 1080)
            exit(0)
        }
        if let i = args.firstIndex(of: "--panel-preview"), args.count > i + 3,
           let w = Double(args[i + 1]), let clip = Int(args[i + 2]) {
            // 開発用：下のパラメーターパネルを、幅 w で画像に書き出す（レイアウトの確認。プレビューの中身は出ない）
            //   VJPlayer --panel-preview 1500 クリップ番号 out.png
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            //   クリップ番号が負なら、その番目（-1 = 1 番目）のシーンを編集している所
            if clip < 0 {
                let sc = Engine.shared.scenes
                if sc.indices.contains(-clip - 1) { Engine.shared.editScene(sc[-clip - 1].id) }
            } else {
                Engine.shared.selectClip(clip)
            }
            CardPreview.writePanel(width: w, path: args[i + 3])
            exit(0)
        }
        if let i = args.firstIndex(of: "--card-preview"), args.count > i + 2, let k = EffectKind(rawValue: args[i + 1]) {
            // 開発用：エフェクトの設定パネルを 1 枚の画像に書き出す（画面には出さない）
            //   VJPlayer --card-preview strobe out.png
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            CardPreview.write(kind: k, path: args[i + 2])
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
            // 使わない標準の項目（英語の「Toggle Sidebar」・空の「表示」の中身）は出さない
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .toolbar) {
                Button("全画面表示にする／戻す") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
            // 中身の無い「Halo VJヘルプ」は出さない（ヘルプのメニューは検索だけ）
            CommandGroup(replacing: .help) {}
            CommandMenu("レイアウト") {
                LayoutMenu(layout: LayoutManager.shared)
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
        // 画面確認用：VJ_OUTPUT=window で出力ウィンドウ（テスト用）を開く。VJ_FORMAT=幅x高さ[@fps][:fit|fill|stretch] で
        // 2.5 秒後に解像度を変える（開いたウィンドウと縦横比が違うときの見え方の確認）
        let env = ProcessInfo.processInfo.environment
        if env["VJ_OUTPUT"] == "window" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { OutputController.shared.target = .window }
        }
        if let v = env["VJ_FORMAT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                var f = OutputFormat()
                let parts = v.split(separator: ":")
                let head = parts.first.map(String.init) ?? ""
                let sizeFps = head.split(separator: "@")
                let wh = sizeFps.first?.split(separator: "x").compactMap { Int($0) } ?? []
                if wh.count == 2 { f.width = wh[0]; f.height = wh[1] }
                if sizeFps.count > 1 { f.fps = Double(sizeFps[1]) ?? 0 }
                if parts.count > 1 { f.fit = ["fit": .fit, "fill": .fill, "stretch": .stretch][String(parts[1])] ?? .fit }
                Engine.shared.outputFormat = f
            }
        }
        // 画面確認用：VJ_PRINT_MENUS=1 で、メニューバーの項目の名前を書き出す（日本語になっているかの確認）
        if ProcessInfo.processInfo.environment["VJ_PRINT_MENUS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for m in NSApp.mainMenu?.items ?? [] {
                    let sub = (m.submenu?.items ?? []).filter { !$0.isSeparatorItem && !$0.isHidden && !$0.isAlternate }.map(\.title)
                    FileHandle.standardError.write("MENU \(m.title): \(sub.joined(separator: " | "))\n".data(using: .utf8)!)
                }
            }
        }
        // 画面確認用：VJ_MULTI_SELECT=番号,番号 で起動時にそのクリップを複数選択しておく
        if let v = ProcessInfo.processInfo.environment["VJ_MULTI_SELECT"] {
            let list = v.split(separator: ",").compactMap { Int($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { list.forEach { Engine.shared.toggleMultiSelect($0) } }
        }
        // 画面確認用：VJ_DOCK_DRAG=パネル名（grid など）で、自由レイアウトのタブをドラッグ中の見た目にしておく
        if let v = ProcessInfo.processInfo.environment["VJ_DOCK_DRAG"], let p = DockPanel(rawValue: v) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { DockDragState.shared.panel = p }
        }
        // 画面確認用：VJ_HOLD_PAD=番号（1 から）で起動時にそのパッドを押したままにしておく
        if let v = ProcessInfo.processInfo.environment["VJ_HOLD_PAD"], let n = Int(v) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let ps = Engine.shared.pads
                if ps.indices.contains(n - 1) { Engine.shared.padDown(ps[n - 1].id) }
            }
        }
        // 画面確認用：VJ_EDIT_SCENE=番号（1 から）で起動時にそのシーンを編集中にしておく
        if let v = ProcessInfo.processInfo.environment["VJ_EDIT_SCENE"], let n = Int(v) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let sc = Engine.shared.scenes
                if sc.indices.contains(n - 1) { Engine.shared.editScene(sc[n - 1].id) }
            }
        }
        // 画面確認用：VJ_SELECT_CLIP=番号 で起動時にそのクリップを選んでおく
        if let v = ProcessInfo.processInfo.environment["VJ_SELECT_CLIP"], let i = Int(v) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Engine.shared.selectClip(i)
                // VJ_EDIT_POLY=1 なら、そのクリップの「自由な形のマスク」を開いて点の編集を始める
                if ProcessInfo.processInfo.environment["VJ_EDIT_POLY"] != nil,
                   let e = Engine.shared.slots[i]?.effects.first(where: { $0.kind == .polyMask }) {
                    EffectUIState.shared.expanded.insert(e.id)
                    EffectUIState.shared.editingPoly = e.id
                }
            }
        }

        // 前回別ウィンドウにしていたパネルを開く（メインのウィンドウができてから）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { LayoutManager.shared.syncWindows() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            Self.handleKey(event) ? nil : event
        }
        // アプリから離れるとキーを離したのが届かないので、FX パッドは全部離す
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { _ in Engine.shared.releaseAllPads() }
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
        // FX パッド：キーを離したら（修飾キーに関係なく）離す
        if event.type == .keyUp { return Engine.shared.padKeyUp(event.keyCode) }
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
        // スペース：キューの GO、⇧スペース：1 つ戻る（キューがあるときだけ）
        if event.keyCode == 49 && !Engine.shared.cues.isEmpty {
            if !event.isARepeat { if shift { Engine.shared.backCue() } else { Engine.shared.goCue() } }
            return true
        }
        // Delete：⇧クリックで選んだクリップをまとめて削除
        if (event.keyCode == 51 || event.keyCode == 117) && !Engine.shared.multiSelection.isEmpty {
            if !event.isARepeat { SelectionMenu.delete(Engine.shared) }
            return true
        }
        // FX パッド：押している間だけ（押しっぱなしの繰り返しは無視）
        if Engine.padKeyCodes.contains(where: { $0.1 == event.keyCode }) {
            if event.isARepeat { return Engine.shared.pads.contains { p in p.key != nil && Engine.padKeyCodes.first { $0.0 == p.key }?.1 == event.keyCode } }
            return Engine.shared.padKeyDown(event.keyCode)
        }
        return false
    }
}

/// 開発用：エフェクトの設定パネルを画像にする
enum CardPreview {
    struct Host: View {
        static let cardWidth = ProcessInfo.processInfo.environment["VJ_CARD_WIDTH"].flatMap(Double.init).map { CGFloat($0) } ?? UI.paramsWidth
        @State var effect: Effect
        @State var blend = BlendMode.normal
        @State var other = Effect(kind: .mirror)
        @State var anim: ParamAnim = { var a = ParamAnim(range: 0...1); a.mode = .beat; return a }()
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                EffectCard(effect: $other, isFirst: true, isLast: false, move: { _ in }, remove: {})
                EffectCard(effect: $effect, isFirst: false, isLast: true, move: { _ in }, remove: {})
                    .onAppear { EffectUIState.shared.expanded.insert(effect.id) }
                ParamColumns {
                    BlendChoice(blend: $blend)
                        .frame(width: min(UI.paramColumnWidth, Self.cardWidth))
                    AnimEditor(anim: $anim, defaultRange: 0...1, format: EffectParam.percent, range: 0...1, perPoint: 0.003)
                        .frame(width: min(UI.paramColumnWidth, Self.cardWidth))
                }
            }
                // VJ_CARD_WIDTH で細い幅のときの見た目も確かめられる
                .environment(\.paramsWidth, Self.cardWidth)
                .frame(width: Self.cardWidth + 20)
                .padding(12)
                .background(Color(white: 0.16))
                .environment(\.colorScheme, .dark)
                .environmentObject(Engine.shared)
        }
    }

    static func writePanel(width: Double, path: String) {
        // VJ_INSPECTOR_TAB=composition|layer|clip でタブを選ぶ。VJ_PANEL_HEIGHT を付けると設定部分だけをその高さで
        let env = ProcessInfo.processInfo.environment
        if let t = env["VJ_INSPECTOR_TAB"].flatMap(Engine.InspectorTab.init(rawValue:)) { Engine.shared.inspectorTab = t }
        let height = env["VJ_PANEL_HEIGHT"].flatMap(Double.init) ?? 420
        let root = Group {
            if env["VJ_PANEL_HEIGHT"] != nil { ParameterPanel(part: .settings) } else { ParameterPanel(previewHeight: 300) }
        }
            .frame(width: width, height: height)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
            .environmentObject(Engine.shared)
        snapshot(NSHostingView(rootView: root), size: NSSize(width: width, height: height), path: path)
    }

    private static func snapshot(_ view: NSView, size: NSSize, path: String) {
        let win = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func write(kind: EffectKind, path: String) {
        var e = Effect(kind: kind)
        // 動かす値があれば 1 つ目を BPM で動かしておく（動きの設定の見た目も確かめる）
        if let i = kind.params.firstIndex(where: { $0.animatable }) {
            var a = e.anim(i); a.mode = .beat; e.setAnim(i, a)
        }
        let view = NSHostingView(rootView: Host(effect: e))
        let size = view.fittingSize
        let win = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
