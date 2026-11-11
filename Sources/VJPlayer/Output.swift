import AppKit
import SwiftUI

enum OutputTarget: Hashable {
    case none
    case window
    case screen(CGDirectDisplayID)
}

/// 出力ウィンドウ（別ディスプレイにフルスクリーン、またはテスト用の通常ウィンドウ）を管理する
final class OutputController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = OutputController()

    @Published var target: OutputTarget = .none {
        didSet {
            if oldValue != target {
                if target != .none { lastTarget = target }
                apply()
            }
        }
    }
    /// 最後に使った出力先（⌘⇧F で戻すため）
    private(set) var lastTarget: OutputTarget = .none

    /// 出力を閉じる／直前の出力先に戻す
    func toggle() {
        if target != .none {
            target = .none
        } else if lastTarget != .none {
            target = lastTarget
        }
    }
    @Published private(set) var screens: [NSScreen] = NSScreen.screens

    /// 出力の分割で使う出力の数（出力 1 は target、2・3 は extra）
    static let maxOutputs = 3
    @Published var extra: [OutputTarget] = [.none, .none] {
        didSet { for i in extra.indices where i >= oldValue.count || oldValue[i] != extra[i] { applyExtra(i) } }
    }
    private var extraWindows: [Int: NSWindow] = [:]

    /// 出力 i（0 = 出力 1）の出力先
    func binding(_ i: Int) -> Binding<OutputTarget> {
        Binding(get: { i == 0 ? self.target : self.extra[i - 1] },
                set: { v in if i == 0 { self.target = v } else { self.extra[i - 1] = v } })
    }

    /// 出力 i の画面の縦横比（出していなければ 16:9）
    func aspect(of i: Int) -> CGFloat {
        let t = i == 0 ? target : extra[i - 1]
        if case .screen(let id) = t, let s = screens.first(where: { Self.displayID(of: $0) == id }) {
            return s.frame.width / max(s.frame.height, 1)
        }
        if i == 0 { return Engine.shared.screenAspect }
        return 16.0 / 9.0
    }

    private func applyExtra(_ i: Int) {
        extraWindows[i]?.delegate = nil
        extraWindows[i]?.orderOut(nil)
        extraWindows[i] = nil
        let out = i + 1
        switch extra[i] {
        case .none:
            return
        case .window:
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                             styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = L("出力 \(out + 1)")
            w.isReleasedWhenClosed = false
            w.contentView = MetalLayerView(frame: w.contentLayoutRect, kind: .output, output: out)
            w.center()
            extraWindows[i] = w
            w.makeKeyAndOrderFront(nil)
        case .screen(let id):
            guard let screen = screens.first(where: { Self.displayID(of: $0) == id }) else { extra[i] = .none; return }
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.setFrame(screen.frame, display: true)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.backgroundColor = .black
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.contentView = MetalLayerView(frame: w.contentLayoutRect, kind: .output, output: out)
            extraWindows[i] = w
            w.orderFrontRegardless()
        }
    }

    private var window: NSWindow?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screensChanged()
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func label(of screen: NSScreen) -> String {
        let s = screen.frame.size
        let main = screen == NSScreen.screens.first ? L("（メイン）") : ""
        return "\(screen.localizedName) \(Int(s.width))×\(Int(s.height))\(main)"
    }

    private func screensChanged() {
        screens = NSScreen.screens
        for i in extra.indices {
            if case .screen(let id) = extra[i], !screens.contains(where: { Self.displayID(of: $0) == id }) { extra[i] = .none }
        }
        // 出力先のディスプレイが抜かれたら出力を閉じる
        if case .screen(let id) = target, !screens.contains(where: { Self.displayID(of: $0) == id }) {
            target = .none
        } else {
            apply()
        }
    }

    private func apply() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil

        let engine = Engine.shared
        switch target {
        case .none:
            RenderLoop.shared.setDisplay(nil)
            return

        case .window:
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                             styleMask: [.titled, .resizable, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = L("出力")
            // 解像度を決めていればその縦横比、無ければ 16:9
            let a = engine.outputFormat.aspect ?? 16.0 / 9.0
            w.setContentSize(NSSize(width: 960, height: (960 / a).rounded()))
            w.contentAspectRatio = NSSize(width: a, height: 1)
            w.center()
            install(on: w)
            engine.screenAspect = a
            RenderLoop.shared.setDisplay(nil)
            w.makeKeyAndOrderFront(nil)

        case .screen(let id):
            guard let screen = screens.first(where: { Self.displayID(of: $0) == id }) else {
                target = .none
                return
            }
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                             backing: .buffered, defer: false, screen: screen)
            w.setFrame(screen.frame, display: true)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.backgroundColor = .black
            w.hasShadow = false
            install(on: w)
            engine.screenAspect = screen.frame.width / max(screen.frame.height, 1)
            RenderLoop.shared.setDisplay(id)
            w.orderFrontRegardless()
        }
    }

    private func install(on w: NSWindow) {
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = MetalLayerView(frame: w.contentLayoutRect)
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        // 「出力」ウィンドウを閉じたら出力なしに戻す
        DispatchQueue.main.async { self.target = .none }
    }
}

/// 操作画面のプレビュー（出力と同じ見た目）
struct MetalPreview: NSViewRepresentable {
    var kind: RenderLoop.TargetKind = .output
    func makeNSView(context: Context) -> MetalLayerView { MetalLayerView(frame: .zero, kind: kind) }
    func updateNSView(_ nsView: MetalLayerView, context: Context) {}
}
