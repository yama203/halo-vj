import AppKit
import SwiftUI

/// 別ウィンドウに出せるパネル
enum PanelID: String, Codable, CaseIterable, Identifiable {
    case live, scenes, cues, effects, generators, sources, pads, monitor
    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "ライブ"
        case .scenes: "シーン"
        case .cues: "キュー"
        case .effects: "エフェクト"
        case .generators: "ジェネレーター"
        case .sources: "ソース"
        case .pads: "FX パッド"
        case .monitor: "出力モニター"
        }
    }

    /// 右下のタブのパネルか
    var tab: SidePanel.Tab? {
        switch self {
        case .live: .live
        case .scenes: .scenes
        case .cues: .cues
        case .effects: .effects
        case .generators: .generators
        case .sources: .sources
        case .pads, .monitor: nil
        }
    }

    static let tabs: [PanelID] = [.live, .scenes, .cues, .effects, .generators, .sources]

    /// 別ウィンドウにしたときの最初の大きさ
    var defaultSize: NSSize {
        switch self {
        case .pads: NSSize(width: 900, height: 110)
        case .monitor: NSSize(width: 640, height: 400)
        default: NSSize(width: 480, height: 620)
        }
    }
}

/// 画面の並べ方（境目の位置・別ウィンドウにしたパネルとその場所）。名前を付けて保存できる
struct LayoutState: Codable, Equatable {
    /// 上の段（グリッド）の高さ。nil = おまかせ（中身に合わせる）
    var topHeight: Double?
    /// 右上の出力モニターの幅
    var monitorWidth: Double = Double(UI.sideWidth)
    /// 右下のパネルの幅
    var sideWidth: Double = Double(UI.sideWidth)
    /// 別ウィンドウにしているパネル
    var detached: [PanelID] = []
    /// 常に手前に出すウィンドウ
    var floating: [PanelID] = []
    /// 別ウィンドウの場所（NSStringFromRect）
    var frames: [String: String] = [:]
    /// 自由レイアウト（試験中）を使うか。使わないときは決まった並べ方
    var dockMode = false
    /// 自由レイアウトの区画
    var dock: DockNode?

    init() {}

    // 無い項目は既定値にする（あとで項目を足しても、前に保存したレイアウトが読める）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topHeight = try c.decodeIfPresent(Double.self, forKey: .topHeight)
        monitorWidth = try c.decodeIfPresent(Double.self, forKey: .monitorWidth) ?? Double(UI.sideWidth)
        sideWidth = try c.decodeIfPresent(Double.self, forKey: .sideWidth) ?? Double(UI.sideWidth)
        detached = (try? c.decodeIfPresent([PanelID].self, forKey: .detached)) ?? []
        floating = (try? c.decodeIfPresent([PanelID].self, forKey: .floating)) ?? []
        frames = try c.decodeIfPresent([String: String].self, forKey: .frames) ?? [:]
        dockMode = try c.decodeIfPresent(Bool.self, forKey: .dockMode) ?? false
        dock = (try? c.decodeIfPresent(DockNode.self, forKey: .dock))?.normalized() ?? (dockMode ? DockNode.standard : nil)
    }
}

final class LayoutManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = LayoutManager()

    @Published var state: LayoutState { didSet { if state != oldValue { saveState() } } }
    /// 保存したレイアウト（名前の順は保存した順）
    @Published private(set) var presetNames: [String] = []
    private var presets: [String: LayoutState] = [:]
    /// 四隅の調整中（出力モニターが別ウィンドウでも効くようにここに持つ）
    @Published var editCorners = false

    private var windows: [PanelID: NSWindow] = [:]
    /// ウィンドウを閉じているのが、こちらの都合（レイアウトの切り替え）か
    private var closingByCode = false

    private let stateKey = "layoutState"
    private let presetsKey = "layoutPresets"
    private let presetNamesKey = "layoutPresetNames"

    override init() {
        let d = UserDefaults.standard
        if let path = ProcessInfo.processInfo.environment["VJ_LAYOUT_JSON"],
           let data = FileManager.default.contents(atPath: path),
           let st = try? JSONDecoder().decode(LayoutState.self, from: data) {
            state = st
            presets = [:]
            super.init()
            return
        }
        state = d.data(forKey: "layoutState").flatMap { try? JSONDecoder().decode(LayoutState.self, from: $0) } ?? LayoutState()
        let ps = d.data(forKey: "layoutPresets").flatMap { try? JSONDecoder().decode([String: LayoutState].self, from: $0) } ?? [:]
        presets = ps
        presetNames = (d.stringArray(forKey: "layoutPresetNames") ?? []).filter { ps[$0] != nil }
        super.init()
    }

    /// 画面確認用：VJ_LAYOUT_JSON=ファイル で、そのレイアウトで起動する（設定には保存しない）
    private let readOnly = ProcessInfo.processInfo.environment["VJ_LAYOUT_JSON"] != nil

    private func saveState() {
        guard !readOnly else { return }
        if let d = try? JSONEncoder().encode(state) { UserDefaults.standard.set(d, forKey: stateKey) }
    }

    private func savePresets() {
        guard !readOnly else { return }
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(presets) { d.set(data, forKey: presetsKey) }
        d.set(presetNames, forKey: presetNamesKey)
    }

    func isDetached(_ p: PanelID) -> Bool { state.detached.contains(p) }
    func isFloating(_ p: PanelID) -> Bool { state.floating.contains(p) }

    /// 右下に残っているタブ
    var attachedTabs: [SidePanel.Tab] { PanelID.tabs.filter { !isDetached($0) }.compactMap(\.tab) }

    // MARK: - 別ウィンドウ

    func detach(_ p: PanelID) {
        guard !isDetached(p) else { windows[p]?.makeKeyAndOrderFront(nil); return }
        state.detached.append(p)
        syncWindows()
    }

    /// メインのウィンドウに戻す
    func attach(_ p: PanelID) {
        state.detached.removeAll { $0 == p }
        syncWindows()
    }

    func toggleDetached(_ p: PanelID) { isDetached(p) ? attach(p) : detach(p) }

    func setFloating(_ p: PanelID, _ on: Bool) {
        state.floating.removeAll { $0 == p }
        if on { state.floating.append(p) }
        windows[p]?.level = on ? .floating : .normal
    }

    /// state に合わせてウィンドウを開く・閉じる・重なり方を合わせる
    func syncWindows() {
        for (p, w) in windows where !isDetached(p) {
            closingByCode = true
            w.close()
            closingByCode = false
            windows[p] = nil
        }
        for p in state.detached {
            let w = windows[p] ?? makeWindow(p)
            windows[p] = w
            if let s = state.frames[p.rawValue] {
                let r = NSRectFromString(s)
                if r.width > 50, r.height > 30, NSScreen.screens.contains(where: { $0.frame.intersects(r) }) {
                    w.setFrame(r, display: true)
                }
            }
            w.level = isFloating(p) ? .floating : .normal
            w.orderFront(nil)
        }
    }

    private func makeWindow(_ p: PanelID) -> NSWindow {
        let content = PanelWindowContent(panel: p)
            .environmentObject(Engine.shared)
            .environmentObject(self)
            .preferredColorScheme(.dark)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: p.defaultSize),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = p.title + " — " + AppInfo.name
        w.contentView = NSHostingView(rootView: content)
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.appearance = NSAppearance(named: .darkAqua)
        w.delegate = self
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { [weak self] _ in
            self?.remember(p, w)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: w, queue: .main) { [weak self] _ in
            self?.remember(p, w)
        }
        return w
    }

    private func remember(_ p: PanelID, _ w: NSWindow) {
        guard isDetached(p) else { return }
        state.frames[p.rawValue] = NSStringFromRect(w.frame)
    }

    /// ウィンドウの閉じるボタン → メインのウィンドウに戻す
    func windowWillClose(_ notification: Notification) {
        guard !closingByCode, let w = notification.object as? NSWindow,
              let p = windows.first(where: { $0.value === w })?.key else { return }
        remember(p, w)
        windows[p] = nil
        state.detached.removeAll { $0 == p }
    }

    // MARK: - 保存したレイアウト

    /// 今の並べ方を名前を付けて保存する（同じ名前なら上書き）
    func savePreset(_ name: String) {
        // 開いているウィンドウの場所を入れてから保存する
        for (p, w) in windows { state.frames[p.rawValue] = NSStringFromRect(w.frame) }
        presets[name] = state
        if !presetNames.contains(name) { presetNames.append(name) }
        savePresets()
    }

    func applyPreset(_ name: String) {
        guard let s = presets[name] else { return }
        state = s
        syncWindows()
    }

    func deletePreset(_ name: String) {
        presets[name] = nil
        presetNames.removeAll { $0 == name }
        savePresets()
    }

    /// 自由レイアウト（試験中）の切り替え
    func setDockMode(_ on: Bool) {
        if on && state.dock == nil { state.dock = DockNode.standard }
        state.dock = state.dock?.normalized()
        state.dockMode = on
    }

    /// おすすめのレイアウトにする（自由レイアウト。別ウィンドウは全部戻す）
    func applyTemplate(_ dock: DockNode) {
        var s = state
        s.dockMode = true
        s.dock = dock.normalized()
        s.detached = []
        s.floating = []
        state = s
        syncWindows()
    }

    /// 最初の並べ方に戻す（別ウィンドウは全部戻す）
    func reset() {
        state = LayoutState()
        syncWindows()
    }
}

/// 別ウィンドウの中身：上に「常に手前」「戻す」、下にパネル
struct PanelWindowContent: View {
    let panel: PanelID
    @EnvironmentObject var layout: LayoutManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(panel.title).font(.system(size: 13, weight: .bold))
                Spacer(minLength: 0)
                Toggle(isOn: Binding(get: { layout.isFloating(panel) }, set: { layout.setFloating(panel, $0) })) {
                    Label("常に手前", systemImage: "pin.fill")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("ほかのウィンドウより常に手前に出す")
                Button {
                    layout.attach(panel)
                } label: {
                    Label("戻す", systemImage: "rectangle.inset.filled.and.person.filled")
                }
                .controlSize(.small)
                .help("メインのウィンドウに戻す（閉じるボタンでも戻る）")
            }
            Group {
                switch panel {
                case .live: LivePanel()
                case .scenes: ScenesPanel()
                case .cues: CuePanel()
                case .effects: EffectBrowser()
                case .generators: EffectBrowser(generators: true)
                case .sources: SourcePanel()
                case .pads: FXPadBar()
                case .monitor: OutputMonitor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(minWidth: 240, minHeight: 80)
        .background(UI.panelBackground)
    }
}

/// 境目のつまみ。ドラッグで大きさを変える。ダブルクリックで元に戻す
struct SplitHandle: View {
    enum Axis { case horizontal, vertical }
    /// .vertical = 左右に動かす縦の線、.horizontal = 上下に動かす横の線
    let axis: Axis
    let onDrag: (CGFloat) -> Void
    var onEnd: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(dragging ? 0.9 : (hovering ? 0.6 : 0)))
                .frame(width: axis == .vertical ? 3 : nil, height: axis == .horizontal ? 3 : nil)
        }
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h { (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                dragging = true
                onDrag(axis == .vertical ? v.translation.width : v.translation.height)
            }
            .onEnded { _ in
                dragging = false
                onEnd()
            })
        .onTapGesture(count: 2) { onDoubleClick() }
        .help("ドラッグで大きさを変える（ダブルクリックでおまかせに戻す）")
    }
}

/// メニューバーの「レイアウト」
struct LayoutMenu: View {
    @ObservedObject var layout: LayoutManager

    var body: some View {
        ForEach(PanelID.allCases) { p in
            Button((layout.isDetached(p) ? "✓ " : "") + p.title + "を別ウィンドウに") { layout.toggleDetached(p) }
        }
        Divider()
        Button((layout.state.dockMode ? "✓ " : "") + "自由レイアウト（試験中）") { layout.setDockMode(!layout.state.dockMode) }
        if layout.state.dockMode {
            Button("自由レイアウトを最初の並べ方に戻す") { layout.state.dock = DockNode.standard }
        }
        Menu("おすすめのレイアウト") {
            Button("ポン出し（グリッド・モニター・ライブ・キュー、下に FX パッド）") { layout.applyTemplate(DockNode.cuePlayback) }
            Button("クラブ VJ（FX パッドを下いっぱい・ライブとシーンをモニターの下）") { layout.applyTemplate(DockNode.clubVJ) }
            Button("いつもの並べ方（自由レイアウト）") { layout.applyTemplate(DockNode.standard) }
        }
        Divider()
        Button("今のレイアウトを保存…") {
            if let n = askName(title: "レイアウトの名前（同じ名前なら上書き）", initial: "レイアウト \(layout.presetNames.count + 1)") {
                layout.savePreset(n)
            }
        }
        if !layout.presetNames.isEmpty {
            ForEach(layout.presetNames, id: \.self) { n in
                Button("「\(n)」にする") { layout.applyPreset(n) }
            }
            Menu("保存したレイアウトを削除") {
                ForEach(layout.presetNames, id: \.self) { n in
                    Button(n) { layout.deletePreset(n) }
                }
            }
        }
        Divider()
        Button("最初のレイアウトに戻す") { layout.reset() }
    }
}
