import AppKit
import SwiftUI

/// 別ウィンドウに出せるパネル
enum PanelID: String, Codable, CaseIterable, Identifiable {
    case live, scenes, cues, effects, generators, sources, pads, monitor
    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: L("ライブ")
        case .scenes: L("シーン")
        case .cues: L("キュー")
        case .effects: L("エフェクト")
        case .generators: L("ジェネレーター")
        case .sources: L("ソース")
        case .pads: L("FX パッド")
        case .monitor: L("出力モニター")
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
    /// 今のワークスペースの名前（nil = まだ選んでいない）
    var workspace: String?
    /// 閉じているパネル（どこにも出さない。開くと元の場所に戻る）
    var closed: [DockPanel] = []

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
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        closed = (try? c.decodeIfPresent([DockPanel].self, forKey: .closed)) ?? []
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

    /// persist: false はテスト用（設定を読まず、保存もしない。最初の並べ方から始める）
    init(persist: Bool = true) {
        let d = UserDefaults.standard
        readOnly = !persist || ProcessInfo.processInfo.environment["VJ_LAYOUT_JSON"] != nil
        if !persist {
            state = LayoutState()
            presets = [:]
            super.init()
            return
        }
        if let path = ProcessInfo.processInfo.environment["VJ_LAYOUT_JSON"],
           let data = FileManager.default.contents(atPath: path),
           let st = try? JSONDecoder().decode(LayoutState.self, from: data) {
            state = st
            presets = [:]
            super.init()
            return
        }
        var st = d.data(forKey: "layoutState").flatMap { try? JSONDecoder().decode(LayoutState.self, from: $0) } ?? LayoutState()
        if let w = st.workspace, let new = Self.renamedWorkspaces[w] { st.workspace = new }
        state = st
        userDefaults = d.data(forKey: "layoutWorkspaceDefaults").flatMap { try? JSONDecoder().decode([String: LayoutState].self, from: $0) } ?? [:]
        var ps = d.data(forKey: "layoutPresets").flatMap { try? JSONDecoder().decode([String: LayoutState].self, from: $0) } ?? [:]
        // 前の名前（いつもの・ポン出し・クラブ VJ）で覚えていたものは、今の名前へ
        for (old, new) in Self.renamedWorkspaces {
            if let v = ps.removeValue(forKey: old), ps[new] == nil { var v2 = v; v2.workspace = new; ps[new] = v2 }
        }
        presets = ps
        presetNames = (d.stringArray(forKey: "layoutPresetNames") ?? []).filter { ps[$0] != nil }
        super.init()
    }

    /// 画面確認用：VJ_LAYOUT_JSON=ファイル で、そのレイアウトで起動する（設定には保存しない）。テスト用のものも保存しない
    private let readOnly: Bool

    private func saveState() {
        guard !readOnly else { return }
        if let d = try? JSONEncoder().encode(state) { UserDefaults.standard.set(d, forKey: stateKey) }
    }

    private func savePresets() {
        guard !readOnly else { return }
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(userDefaults) { d.set(data, forKey: "layoutWorkspaceDefaults") }
        if let data = try? JSONEncoder().encode(presets) { d.set(data, forKey: presetsKey) }
        d.set(presetNames, forKey: presetNamesKey)
    }

    func isDetached(_ p: PanelID) -> Bool { state.detached.contains(p) }
    func isFloating(_ p: PanelID) -> Bool { state.floating.contains(p) }

    /// 右下に残っているタブ（別ウィンドウ・閉じているものは除く）
    var attachedTabs: [SidePanel.Tab] { PanelID.tabs.filter { !isDetached($0) && !isClosed($0) }.compactMap(\.tab) }

    // MARK: - 閉じる・開く

    func isClosed(_ d: DockPanel) -> Bool { state.closed.contains(d) }
    func isClosed(_ p: PanelID) -> Bool { DockPanel(rawValue: p.rawValue).map(isClosed) ?? false }
    /// メインのウィンドウに出ているか（別ウィンドウ・閉じているものは出ていない）
    func isShownInMain(_ p: PanelID) -> Bool { !isDetached(p) && !isClosed(p) }

    /// 閉じられるパネル：いつもの並べ方ではグリッド・プレビュー・パラメーター以外。自由レイアウトでは、最後の 1 つ以外どれでも
    func canClose(_ d: DockPanel) -> Bool {
        guard !isClosed(d) else { return false }
        if state.dockMode {
            let visible = DockPanel.allCases.filter { !isClosed($0) && !($0.window.map(isDetached) ?? false) }
            return visible.count > 1 || !visible.contains(d)
        }
        return d.window != nil
    }

    /// パネルを閉じる（どこにも出さない。別ウィンドウなら閉じる）
    func close(_ d: DockPanel) {
        guard canClose(d) else { return }
        state.closed.append(d)
        if let p = d.window { state.detached.removeAll { $0 == p } }
        syncWindows()
    }

    /// 閉じていたパネルを開く（元の場所に戻る）
    func open(_ d: DockPanel) {
        state.closed.removeAll { $0 == d }
        // 自由レイアウトの区画に無ければ、いちばん大きい区画に足す
        if state.dockMode, let tree = state.dock, !tree.panels.contains(d) { state.dock = tree.normalized() }
        syncWindows()
    }

    func toggleClosed(_ d: DockPanel) { isClosed(d) ? open(d) : close(d) }

    /// 「パネル」のメニューに出すもの（いつもの並べ方では、閉じられないものは出さない）
    var closablePanels: [DockPanel] {
        state.dockMode ? DockPanel.allCases : DockPanel.allCases.filter { $0.window != nil }
    }

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

    // MARK: - ワークスペース（保存したレイアウト）

    /// はじめから用意してあるワークスペース
    static let builtinWorkspaces = ["Standard", "Show", "VJ"]
    /// 前の名前 → 今の名前（前に保存したものを引き継ぐ）
    static let renamedWorkspaces = ["いつもの": "Standard", "ポン出し": "Show", "クラブ VJ": "VJ"]

    static func builtinState(_ name: String) -> LayoutState? {
        var s = LayoutState()
        switch name {
        case "Standard": break
        case "Show": s.dockMode = true; s.dock = DockNode.cuePlayback
        case "VJ": s.dockMode = true; s.dock = DockNode.clubVJ
        default: return nil
        }
        s.workspace = name
        return s
    }

    /// 自分で決めたワークスペースの初期状態（「初期状態に戻す」で戻る形）
    private var userDefaults: [String: LayoutState] = [:]

    /// ワークスペースの初期状態：自分で決めたもの → はじめからのもの
    func defaultState(_ name: String) -> LayoutState? {
        if var s = userDefaults[name] { s.workspace = name; return s }
        return Self.builtinState(name)
    }

    /// 自分で初期状態を決めているか
    func hasUserDefault(_ name: String) -> Bool { userDefaults[name] != nil }

    /// 今の形を、今のワークスペースの初期状態にする
    func setCurrentAsDefault() {
        guard let name = state.workspace else { return }
        var s = snapshot()
        s.workspace = name
        userDefaults[name] = s
        presets[name] = s
        savePresets()
    }

    /// はじめからのワークスペースを、アプリの最初の形に戻す（自分で決めた初期状態も消す）
    func factoryReset(_ name: String) {
        guard let s = Self.builtinState(name) else { return }
        userDefaults[name] = nil
        presets[name] = nil
        if state.workspace == name { state = s; syncWindows() }
        savePresets()
    }

    /// 上のバーに並べるワークスペース（はじめからのもの → 自分で保存したもの）
    var workspaceNames: [String] { Self.builtinWorkspaces + presetNames.filter { !Self.builtinWorkspaces.contains($0) } }

    /// 今の並べ方（別ウィンドウの場所も入れて）
    private func snapshot() -> LayoutState {
        var s = state
        for (p, w) in windows { s.frames[p.rawValue] = NSStringFromRect(w.frame) }
        return s
    }

    /// ワークスペースを切り替える。今のワークスペースの並べ方は覚えておく（戻ると、いじった形のまま）
    func switchWorkspace(_ name: String) {
        guard name != state.workspace else { return }
        if let cur = state.workspace {
            presets[cur] = snapshot()
            if !Self.builtinWorkspaces.contains(cur) && !presetNames.contains(cur) { presetNames.append(cur) }
        } else if !isBuiltinUnchanged(state) {
            // まだワークスペースを選んでいなかった今の並べ方は、なくさないよう「前の並べ方」として残す
            var s = snapshot()
            s.workspace = L("前の並べ方")
            presets[L("前の並べ方")] = s
            if !presetNames.contains(L("前の並べ方")) { presetNames.append(L("前の並べ方")) }
        }
        guard var next = presets[name] ?? defaultState(name) else { savePresets(); return }
        next.workspace = name
        state = next
        savePresets()
        syncWindows()
    }

    /// はじめからのワークスペースそのままか（「Standard」で何もいじっていない、など）
    private func isBuiltinUnchanged(_ s: LayoutState) -> Bool {
        var a = s; a.workspace = nil; a.frames = [:]
        return Self.builtinWorkspaces.contains { n in
            guard var b = Self.builtinState(n) else { return false }
            b.workspace = nil
            return a == b
        }
    }

    /// 今の並べ方を、名前を付けたワークスペースとして保存して、それに切り替える（同じ名前なら上書き）
    func savePreset(_ name: String) {
        var s = snapshot()
        s.workspace = name
        presets[name] = s
        // 自分で作ったワークスペースは、作ったときの形を初期状態にする
        if !Self.builtinWorkspaces.contains(name) { userDefaults[name] = s }
        if !Self.builtinWorkspaces.contains(name) && !presetNames.contains(name) { presetNames.append(name) }
        state.workspace = name
        savePresets()
    }

    func applyPreset(_ name: String) { switchWorkspace(name) }

    /// ワークスペースを初期状態に戻す（自分で決めた初期状態があればそれ、無ければアプリの最初の形）
    func resetWorkspace(_ name: String) {
        guard let s = defaultState(name) else { return }
        presets[name] = s
        if state.workspace == name { state = s; syncWindows() }
        savePresets()
    }

    /// 自分で保存したワークスペースを消す（はじめからのものは最初の形に戻す）
    func deletePreset(_ name: String) {
        if Self.builtinWorkspaces.contains(name) { factoryReset(name); return }
        presets[name] = nil
        userDefaults[name] = nil
        presetNames.removeAll { $0 == name }
        if state.workspace == name { state.workspace = nil }
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
                    Label(L("常に手前"), systemImage: "pin.fill")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(L("ほかのウィンドウより常に手前に出す"))
                Button {
                    layout.attach(panel)
                } label: {
                    Label(L("戻す"), systemImage: "rectangle.inset.filled.and.person.filled")
                }
                .controlSize(.small)
                .help(L("メインのウィンドウに戻す（閉じるボタンでも戻る）"))
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
        .help(L("ドラッグで大きさを変える（ダブルクリックでおまかせに戻す）"))
    }
}

/// 上のバーのワークスペースの切り替え（選ぶ箱。Standard・Show・VJ と自分で保存したもの）
struct WorkspaceBar: View {
    @ObservedObject var layout = LayoutManager.shared

    var body: some View {
        let cur = layout.state.workspace
        Menu {
            ForEach(layout.workspaceNames, id: \.self) { n in
                Button((cur == n ? "✓ " : "") + n + (Self.notes[n].map { L("（\($0)）") } ?? "")) { layout.switchWorkspace(n) }
            }
            Divider()
            Button(L("今の並べ方を新しいワークスペースにする…")) {
                if let n = askName(title: L("ワークスペースの名前"), initial: L("ワークスペース \(layout.presetNames.count + 1)")) {
                    layout.savePreset(n)
                }
            }
            if let cur {
                Divider()
                Button(L("今の形を「\(cur)」の初期状態にする")) { layout.setCurrentAsDefault() }
                Button(L("「\(cur)」を初期状態に戻す")) { layout.resetWorkspace(cur) }
                if LayoutManager.builtinWorkspaces.contains(cur) {
                    Button(L("「\(cur)」をアプリの最初の状態に戻す")) { layout.factoryReset(cur) }
                        .disabled(!layout.hasUserDefault(cur))
                } else {
                    Button(L("「\(cur)」を削除"), role: .destructive) { layout.deletePreset(cur) }
                }
            }
        } label: {
            Label(cur ?? L("ワークスペース"), systemImage: "rectangle.3.group")
                .frame(minWidth: 110, alignment: .leading)
        }
        .fixedSize()
        .help(L("ワークスペース：画面の並べ方。切り替えると、いじった形は覚えておく"))
        PanelMenuButton()
    }

    /// はじめからのワークスペースの説明
    static let notes = ["Standard": L("いつもの並べ方"), "Show": L("ポン出し"), "VJ": L("FX パッドを大きく")]
}

/// パネルを出す・閉じる（✓ が出ているもの）。メニューバーの「レイアウト」と、上のバーの「パネル」
struct PanelVisibilityItems: View {
    @ObservedObject var layout: LayoutManager
    var body: some View {
        ForEach(layout.closablePanels) { d in
            Button((layout.isClosed(d) ? "　 " : "✓ ") + d.title) { layout.toggleClosed(d) }
                .disabled(!layout.isClosed(d) && !layout.canClose(d))
        }
        if !layout.state.closed.isEmpty {
            Divider()
            Button(L("閉じたパネルを全部出す")) { for d in layout.state.closed { layout.open(d) } }
        }
    }
}

/// 上のバーの「パネル」：使わないパネルを閉じる・閉じたものを出す
struct PanelMenuButton: View {
    @ObservedObject var layout = LayoutManager.shared
    var body: some View {
        Menu {
            Text(L("✓ が出ているパネル（押すと閉じる・出す）"))
            PanelVisibilityItems(layout: layout)
        } label: {
            // 幅を取らないよう絵だけ（閉じているものがあれば数を出す）
            if layout.state.closed.isEmpty {
                Image(systemName: "rectangle.split.2x2")
            } else {
                Label("\(layout.state.closed.count)", systemImage: "rectangle.split.2x2")
            }
        }
        .fixedSize()
        .help(L("使わないパネルを閉じる・閉じたパネルを出す"))
    }
}

/// パネルを閉じるボタン（× の印）
struct PanelCloseButton: View {
    let panel: DockPanel
    @ObservedObject var layout = LayoutManager.shared
    var body: some View {
        if layout.canClose(panel) {
            Button { layout.close(panel) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .controlSize(.small)
            .help(L("「\(panel.title)」を閉じる（上のバーの「パネル」か、メニューの「レイアウト」でまた出せる）"))
        }
    }
}

/// メニューバーの「レイアウト」
struct LayoutMenu: View {
    @ObservedObject var layout: LayoutManager

    var body: some View {
        PanelVisibilityItems(layout: layout)
        Divider()
        ForEach(PanelID.allCases) { p in
            Button((layout.isDetached(p) ? "✓ " : "") + L("\(p.title)を別ウィンドウに")) { layout.toggleDetached(p) }
                .disabled(layout.isClosed(p))
        }
        Divider()
        Button((layout.state.dockMode ? "✓ " : "") + L("自由レイアウト（試験中）")) { layout.setDockMode(!layout.state.dockMode) }
        if layout.state.dockMode {
            Button(L("自由レイアウトを最初の並べ方に戻す")) { layout.state.dock = DockNode.standard }
        }
        Menu(L("おすすめのレイアウト")) {
            Button(L("Show（ポン出し：グリッド・キュー・モニター・ライブ、下に FX パッド）")) { layout.switchWorkspace("Show") }
            Button(L("VJ（FX パッドを下いっぱい・ライブとシーンをモニターの下）")) { layout.switchWorkspace("VJ") }
            Button(L("Standard（いつもの並べ方）")) { layout.switchWorkspace("Standard") }
        }
        Divider()
        Button(L("今のレイアウトを保存…")) {
            if let n = askName(title: L("レイアウトの名前（同じ名前なら上書き）"), initial: L("レイアウト \(layout.presetNames.count + 1)")) {
                layout.savePreset(n)
            }
        }
        if !layout.presetNames.isEmpty {
            ForEach(layout.presetNames, id: \.self) { n in
                Button(L("「\(n)」にする")) { layout.applyPreset(n) }
            }
            Menu(L("保存したレイアウトを削除")) {
                ForEach(layout.presetNames, id: \.self) { n in
                    Button(n) { layout.deletePreset(n) }
                }
            }
        }
        Divider()
        Button(L("最初のレイアウトに戻す")) { layout.reset() }
    }
}
