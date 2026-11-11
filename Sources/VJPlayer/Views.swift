import SwiftUI
import UniformTypeIdentifiers

/// 画面全体で使う見た目の共通部品
enum UI {
    /// 右列（出力モニター・ライブ操作）の幅
    static let sideWidth: CGFloat = 470
    static let panelBackground = Color.white.opacity(0.035)
    /// 数値欄・ボタンなどの 1 行の高さ（押しやすさ優先）
    static let rowHeight: CGFloat = 32
    /// 動かし方のボタン（幅 30・すき間 4）と数値欄の中の余白のぶん。スイッチ・選択肢の行の名前を、数値欄の名前にそろえる
    static let paramLabelInset: CGFloat = 30 + 4 + 8
    /// パラメーター欄 1 列の幅と、2 列ぶんの幅
    static let paramColumnWidth: CGFloat = 260
    static let paramsWidth: CGFloat = paramColumnWidth * 2 + 16
}

struct SectionTitle: View {
    let text: String
    var icon: String? = nil
    /// 色付きの見出し（ジェネレーターは青緑、エフェクトは紫）
    var tint: Color? = nil
    init(_ text: String, icon: String? = nil, tint: Color? = nil) { self.text = text; self.icon = icon; self.tint = tint }
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }
}

extension UI {
    /// ジェネレーター（自分で絵を描く）とエフェクト（絵に手を加える）の色。ぱっと見で見分けられるように
    static let generatorTint = Color(red: 0.25, green: 0.82, blue: 0.80)
    static let effectTint = Color(red: 0.72, green: 0.45, blue: 1.0)
}

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var layout = LayoutManager.shared
    @AppStorage("gridSize") private var gridSizeRaw = 0
    /// 境目をドラッグし始めたときの値
    @State private var dragStart: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(editCorners: $layout.editCorners)
            Divider()
            if layout.state.dockMode {
                DockRootView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            GeometryReader { g in
                let st = layout.state
                // 境目の位置（ドラッグで変えられる。別ウィンドウにしたものは場所を取らない）
                let showMonitor = layout.isShownInMain(.monitor)
                let monitorW = showMonitor ? min(max(CGFloat(st.monitorWidth), 220), max(g.size.width * 0.6, 220)) : 0
                let gridWidth = g.size.width - 24 - (showMonitor ? 12 + monitorW : 0)
                let cell = ClipGrid.cellSize(forWidth: gridWidth, columns: engine.columns,
                                             size: GridSize(rawValue: gridSizeRaw) ?? .large)
                let gridHeight = ClipGrid.contentHeight(cell: cell.height, layers: engine.layerCount)
                let monitorHeight = showMonitor ? (monitorW / max(engine.outputAspect, 0.1)) + 24 : 0
                let padHeight: CGFloat = layout.isShownInMain(.pads) ? 58 : 0
                let handle: CGFloat = 8
                let maxTop = max(g.size.height - padHeight - handle - 160, 150)
                // グリッドの高さ：おまかせなら中身に合わせる（下のパネルは 370 は残す）
                let autoTop = min(max(gridHeight, monitorHeight) + 24, max(g.size.height - 370 - handle - padHeight, 200))
                let topHeight = st.topHeight.map { min(max(CGFloat($0), 150), maxTop) } ?? autoTop
                let bottomHeight = g.size.height - topHeight - padHeight - handle
                let showSide = !layout.attachedTabs.isEmpty
                let sideW = showSide ? min(max(CGFloat(st.sideWidth), 300), max(g.size.width * 0.6, 300)) : 0
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        ClipGrid(size: CGSize(width: gridWidth, height: topHeight - 24))
                            .frame(width: gridWidth, height: topHeight - 24, alignment: .topLeading)
                        if showMonitor {
                            SplitHandle(axis: .vertical, onDrag: { dx in
                                let s = dragStart ?? monitorW
                                dragStart = s
                                layout.state.monitorWidth = Double(min(max(s - dx, 220), g.size.width * 0.6))
                            }, onEnd: { dragStart = nil }, onDoubleClick: { layout.state.monitorWidth = Double(UI.sideWidth) })
                            .frame(width: 12, height: topHeight - 24)
                            OutputMonitor()
                                .frame(width: monitorW)
                        }
                    }
                    .padding(12)
                    .frame(height: topHeight, alignment: .top)
                    // 押している間だけ効くエフェクトのパッド
                    if padHeight > 0 {
                        FXPadBar(showsTitle: true)
                            .padding(.horizontal, 12)
                            .frame(height: padHeight, alignment: .top)
                    }
                    // 上下の境目（ドラッグでグリッドの高さ。ダブルクリックでおまかせ）
                    SplitHandle(axis: .horizontal, onDrag: { dy in
                        let s = dragStart ?? topHeight
                        dragStart = s
                        layout.state.topHeight = Double(min(max(s + dy, 150), maxTop))
                    }, onEnd: { dragStart = nil }, onDoubleClick: { layout.state.topHeight = nil })
                    .frame(height: handle)
                    .overlay(Divider())
                    HStack(alignment: .top, spacing: 0) {
                        ParameterPanel(previewHeight: min(max(bottomHeight - 100, 176), 420))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showSide {
                            SplitHandle(axis: .vertical, onDrag: { dx in
                                let s = dragStart ?? sideW
                                dragStart = s
                                layout.state.sideWidth = Double(min(max(s - dx, 300), g.size.width * 0.6))
                            }, onEnd: { dragStart = nil }, onDoubleClick: { layout.state.sideWidth = Double(UI.sideWidth) })
                            .frame(width: 12)
                            SidePanel()
                                .frame(width: sideW)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .padding(12)
                    .frame(height: max(bottomHeight, 0))
                }
            }
            }
            Divider()
            StatusBar()
        }
        .overlay(alignment: .top) { ControlLearnBanner() }
        .background(WindowTitleSync(
            title: (engine.projectURL?.deletingPathExtension().lastPathComponent ?? L("名称未設定")) + " — " + AppInfo.name,
            url: engine.projectURL, edited: engine.isDirty))
        .frame(minWidth: 1300, minHeight: 800)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

/// 右上の出力モニター（コーナーピン後、実際に出る映像）
struct OutputMonitor: View {
    /// 右クリックの「探して追加…」で開く、エフェクトを探す窓
    @State private var showPicker = false
    @EnvironmentObject var engine: Engine
    @ObservedObject var output = OutputController.shared
    @ObservedObject private var layout = LayoutManager.shared
    private var editCorners: Bool { layout.editCorners }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionTitle(L("出力"))
                Circle()
                    .fill(output.target == .none ? Color.gray : Color.green)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(output.target == .none ? Color.secondary : Color.primary)
                    .lineLimit(1)
                EffectIcons(effects: engine.effects, size: 11)
                Spacer(minLength: 0)
                AudioMuteButton(muted: $engine.masterAudioMuted)
                // 自由レイアウトでは区画のタブの横にある
                if !layout.isDetached(.monitor) && !layout.state.dockMode {
                    DetachButton(panel: .monitor)
                    PanelCloseButton(panel: .monitor)
                }
                if editCorners {
                    Text(L("四隅の黄色い点をドラッグ"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.yellow)
                }
            }
            ZStack {
                MetalPreview(kind: .output)
                if editCorners { CornerPinOverlay() }
                if engine.compMuted {
                    Label(L("コンポジションをミュート中"), systemImage: "eye.slash.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                        .allowsHitTesting(false)
                } else if engine.isBlackout {
                    Label(L("ブラックアウト中"), systemImage: "eye.slash.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(engine.outputAspect, contentMode: .fit)
            .effectDropTarget(cornerRadius: 0) { k in
                engine.addEffect(k)
                engine.inspectorTab = .composition
            }
            .effectPickerPopover($showPicker, targetLabel: L("コンポジションに足す")) { k in
                engine.addEffectOpened(k)
                engine.inspectorTab = .composition
            }
            .contextMenu {
                Button(L("コンポジションにエフェクトを探して追加…")) { showPicker = true }
                Menu(L("コンポジションにエフェクトを追加")) {
                    AddEffectMenuItems { k in
                        engine.addEffectOpened(k)
                        engine.inspectorTab = .composition
                    }
                }
            }
            .overlay { OutputFlashOverlay() }
            .overlay(Rectangle().stroke(engine.isBlackout || engine.compMuted ? Color.red
                                        : editCorners ? Color.yellow.opacity(0.6) : Color.gray.opacity(0.35),
                                        lineWidth: engine.isBlackout || engine.compMuted ? 2 : 1))
            Spacer(minLength: 0)
        }
    }

    private var statusText: String {
        switch output.target {
        case .none: return L("出力なし")
        case .window: return L("テスト用ウィンドウ")
        case .screen(let id):
            return output.screens.first { OutputController.displayID(of: $0) == id }
                .map { OutputController.label(of: $0) } ?? L("ディスプレイ")
        }
    }
}

// MARK: - 上部バー

/// 上のバーの左端の、小さなアプリのアイコン（押すと「Halo VJ について」）
struct AppBadge: View {
    var body: some View {
        Button { NSApp.orderFrontStandardAboutPanel(nil) } label: {
            Image(nsImage: AppBadge.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help("\(AppInfo.name) " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + L("（押すとこのアプリについて）"))
    }

    /// .app ならアプリのアイコン。開発中（.app でない）は、同じ絵を Resources から
    static let icon: NSImage = {
        if Bundle.main.bundleURL.pathExtension == "app" { return NSApp.applicationIconImage }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/icon_1024.png")
        return NSImage(contentsOf: dev) ?? NSApp.applicationIconImage
    }()
}

struct TopBar: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var output = OutputController.shared
    @Binding var editCorners: Bool
    @State private var audioDevices: [AudioDevice] = AudioDevices.outputDevices()

    var body: some View {
        HStack(spacing: 10) {
            AppBadge()
            Picker(L("出力"), selection: $output.target) {
                Text(L("出力なし")).tag(OutputTarget.none)
                Text(L("ウィンドウ（テスト用）")).tag(OutputTarget.window)
                ForEach(output.screens, id: \.self) { s in
                    Text(OutputController.label(of: s)).tag(OutputTarget.screen(OutputController.displayID(of: s)))
                }
            }
            .frame(width: 240)
            .help(L("出力を閉じる／元に戻す：⌘⇧F"))
            OutputFormatButton()
            RecordButton()

            Picker(L("音声"), selection: $engine.audioDeviceUID) {
                Text(L("システム既定")).tag(String?.none)
                ForEach(audioDevices) { d in
                    Text(d.name).tag(String?.some(d.id))
                }
            }
            .frame(width: 200)

            Button {
                audioDevices = AudioDevices.outputDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L("オーディオデバイス一覧を更新"))
            AudioInputButton()
            LinkButton()
            AutopilotButton()
            UpdateBadge()

            Spacer()

            WorkspaceBar()
            Divider().frame(height: 24)

            Toggle(isOn: $editCorners) {
                Label(L("四隅を調整"), systemImage: "skew")
            }
            .toggleStyle(.button)
            .help(L("コーナーピン（四隅）を調整"))
            Button {
                engine.resetCorners()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help(L("四隅をリセット"))
            Toggle(isOn: $engine.testPattern) {
                Label(L("テストパターン"), systemImage: "grid")
            }
            .toggleStyle(.button)
            .help(L("テストパターンを出力"))
            Divider().frame(height: 24)
            BlackoutButton()
        }
        .controlSize(.large)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// ブラックアウトの切り替え。中は点滅して「今は黒を出している」ことを目立たせる
struct BlackoutButton: View {
    @EnvironmentObject var engine: Engine
    @State private var blink = false

    var body: some View {
        Button {
            engine.toggleBlackout()
        } label: {
            Label(engine.isBlackout ? L("ブラックアウト中") : L("ブラックアウト"),
                  systemImage: engine.isBlackout ? "eye.slash.fill" : "moon.fill")
                .frame(minWidth: 130)
        }
        .tint(engine.isBlackout ? .red : Color(white: 0.35))
        .buttonStyle(.borderedProminent)
        .opacity(engine.isBlackout && blink ? 0.55 : 1)
        .help(engine.isBlackout
              ? L("クリックで解除 (Esc)。クリップは裏で再生を続けています")
              : L("出力の映像と音を消す (Esc)。もう一度押すと元に戻る。フェード時間は設定（⌘,）。⇧Esc で全レイヤー停止"))
        .onChange(of: engine.isBlackout) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { blink = true }
            } else {
                withAnimation(.default) { blink = false }
            }
        }
    }
}

// MARK: - クリップグリッド

struct ClipGrid: View {
    @EnvironmentObject var engine: Engine
    static let spacing: CGFloat = 6
    static let headerWidth: CGFloat = 156
    /// レイヤー欄の右の、縦の音量フェーダーの幅
    static let volumeWidth: CGFloat = 26
    /// 左端（レイヤー欄 ＋ 音量）の幅
    static var leftWidth: CGFloat { headerWidth + 4 + volumeWidth }
    /// 上の列番号の帯と、下の「レイヤーを追加」の高さ
    static let columnBarHeight: CGFloat = 26
    /// 上のデッキのタブの高さ
    static let deckBarHeight: CGFloat = 28
    static let addRowHeight: CGFloat = 32
    /// 右端の「列を追加」ボタンの幅
    static let addColumnWidth: CGFloat = 34
    /// サムネイルの最小の横幅（これより狭くなるなら横スクロール）
    static let minCellWidth: CGFloat = 100
    let size: CGSize
    @StateObject private var drag = SlotDragState()
    /// グリッドの表示の大きさ（大・中・小）
    @AppStorage("gridSize") private var gridSizeRaw = 0
    /// キューの一覧の上にドラッグしているか（印の表示を変える）
    @ObservedObject private var cueTarget = CueDropTarget.shared

    /// 1 マスの大きさ。横幅から決め、高さは横幅の 3/4（縦長にならないように）
    static func cellSize(forWidth w: CGFloat, columns: Int, size: GridSize = .large) -> CGSize {
        switch size {
        case .medium: return CGSize(width: 120, height: 80)
        case .small: return CGSize(width: 88, height: 56)
        case .large: break
        }
        let n = CGFloat(max(columns, 1))
        let cw = max((w - leftWidth - addColumnWidth - spacing * (n + 1)) / n, minCellWidth)
        // レイヤー欄（名前・停止・不透明度）が収まる高さは確保する
        return CGSize(width: cw, height: min(max(cw * 0.75, 96), 150))
    }

    /// 全段を表示したときの高さ
    static func contentHeight(cell: CGFloat, layers: Int) -> CGFloat {
        deckBarHeight + spacing + columnBarHeight + spacing + (cell + spacing) * CGFloat(layers) + addRowHeight + 12
    }

    var body: some View {
        let gs = GridSize(rawValue: gridSizeRaw) ?? .large
        let cell = Self.cellSize(forWidth: size.width, columns: engine.columns, size: gs)
        VStack(alignment: .leading, spacing: Self.spacing) {
        SceneEditBanner()
        DeckBar()
            .frame(height: Self.deckBarHeight)
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                ColumnBar(cellWidth: cell.width)
                    .frame(height: Self.columnBarHeight)
                ForEach(engine.layers) { live in
                    let r = live.index
                    // シーンの編集中は、そのシーンのレイヤー
                    let layer = engine.viewLayer(r)
                    HStack(spacing: Self.spacing) {
                        HStack(spacing: 4) {
                            LayerHeader(layer: layer)
                                .frame(width: Self.headerWidth, height: cell.height)
                            // 音量（縦のフェーダー）と音のミュート。調整レイヤーは音が無いので空ける
                            if layer.isAdjustment {
                                Color.clear.frame(width: Self.volumeWidth, height: cell.height)
                            } else {
                                LayerVolumeStrip(layer: layer)
                                    .frame(width: Self.volumeWidth, height: cell.height)
                            }
                        }
                        // 調整レイヤーも同じ枠（エフェクトのクリップを置く）
                        ForEach(0..<engine.columns, id: \.self) { c in
                            SlotCell(index: engine.slotIndex(deck: engine.shownDeck, layer: r, column: c),
                                     width: cell.width, height: cell.height)
                        }
                    }
                }
                HStack(spacing: Self.spacing) {
                    Button {
                        engine.insertLayer(at: engine.layerCount)
                    } label: {
                        Label(L("レイヤーを追加"), systemImage: "plus")
                            .font(.system(size: 12))
                            .frame(width: Self.headerWidth - 16)
                    }
                    .controlSize(.large)
                    .disabled(engine.layerCount >= Engine.maxLayers)
                    .help(L("一番下（一番奥）にレイヤーを足す。途中に入れるときはレイヤー欄を右クリック"))
                    Button {
                        engine.insertAdjustmentLayer(at: 0)
                    } label: {
                        Label(L("調整レイヤーを追加"), systemImage: "camera.filters")
                            .font(.system(size: 12))
                    }
                    .controlSize(.large)
                    .disabled(engine.layerCount >= Engine.maxLayers)
                    .help(L("一番上に調整レイヤーを足す。そこに付けたエフェクトが、下のレイヤー全体にかかる"))
                }
            }
            .coordinateSpace(name: SlotDragState.space)
            .background(GeometryReader { g in
                Color.clear.onAppear { drag.gridOrigin = g.frame(in: .global).origin }
                    .onChange(of: g.frame(in: .global).origin) { _, o in drag.gridOrigin = o }
            })
            .onPreferenceChange(SlotFramesKey.self) { drag.frames = $0 }
            .onPreferenceChange(LayerFramesKey.self) { drag.layerFrames = $0 }
            .overlay(alignment: .topLeading) {
                // レイヤーを動かしているときの印
                if let s = drag.layerSource, let t = drag.layerTarget, t != s {
                    Label(L("L\(s + 1) → \(t + 1) 段目へ"), systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.85), in: Capsule())
                        .fixedSize()
                        .position(x: drag.location.x + 60, y: drag.location.y - 14)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                // ⌘ドラッグ中のクリップ名
                if let s = drag.source, engine.slots.indices.contains(s), let slot = engine.slots[s],
                   cueTarget.hovering || (drag.target != nil && drag.target != s) {
                    Label(cueTarget.hovering ? L("キューに足す：") + slot.name
                          : drag.group ? L("\(engine.multiSelection.count) 個を移動") : drag.copying ? L("複製：") + slot.name : slot.name,
                          systemImage: cueTarget.hovering ? "list.number" : drag.copying ? "plus.square.on.square" : "film")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((cueTarget.hovering ? Color.green : Color.accentColor).opacity(0.85), in: Capsule())
                        .fixedSize()
                        .position(x: drag.location.x, y: drag.location.y - 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: size.width, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .environmentObject(drag)
        .environment(\.gridSize, gs)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange, lineWidth: 2)
            .opacity(engine.sceneDraft != nil ? 1 : 0).allowsHitTesting(false))
        }
    }
}

/// 列番号。押すとその列のクリップを全レイヤーいっぺんに出す。出ている列は明るく
struct ColumnButton: View {
    @EnvironmentObject var engine: Engine
    let column: Int
    let cellWidth: CGFloat
    @State private var hovering = false

    var body: some View {
        let live = engine.columnIsLive(column)
        Button {
            engine.pressColumn(column)
        } label: {
            HStack(spacing: 4) {
                if hovering || live {
                    Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                }
                Text("\(column + 1)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(live ? Color.white : (hovering ? Color.primary : Color.secondary))
            .frame(width: cellWidth, height: ClipGrid.columnBarHeight)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(live ? Color.green.opacity(0.45) : Color.white.opacity(hovering ? 0.12 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(engine.sceneDraft != nil
              ? L("この列のクリップを、編集中のシーンでいっぺんに流す（空き枠のレイヤーは何も流さない）")
              : L("この列のクリップを全レイヤーいっぺんに出す（空き枠のレイヤーは止まる）。右クリックで列を足す・消す"))
    }
}

/// グリッド上の列番号の帯。右クリックで列を足す・消す。右端の＋で列を足す
struct ColumnBar: View {
    @EnvironmentObject var engine: Engine
    let cellWidth: CGFloat

    var body: some View {
        HStack(spacing: ClipGrid.spacing) {
            Color.clear.frame(width: ClipGrid.leftWidth)
            ForEach(0..<engine.columns, id: \.self) { c in
                ColumnButton(column: c, cellWidth: cellWidth)
                    .contextMenu {
                        Button(L("左に列を追加")) { engine.insertColumn(at: c) }
                            .disabled(engine.columns >= Engine.maxColumns)
                        Button(L("右に列を追加")) { engine.insertColumn(at: c + 1) }
                            .disabled(engine.columns >= Engine.maxColumns)
                        Divider()
                        Button(L("この列を削除…"), role: .destructive) { removeColumn(c) }
                            .disabled(engine.columns <= 1)
                    }
            }
            Button {
                engine.insertColumn(at: engine.columns)
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    .frame(width: ClipGrid.addColumnWidth - 14)
            }
            .controlSize(.regular)
            .disabled(engine.columns >= Engine.maxColumns)
            .help(L("右端に列を足す。途中に入れるときは列番号を右クリック"))
        }
    }

    private func removeColumn(_ c: Int) {
        if engine.columnHasClips(c) {
            guard confirmRemove(title: L("\(c + 1) 列目を削除しますか？"),
                                message: L("この列のクリップはグリッドから外れます（再生中なら止まります）。")) else { return }
        }
        engine.removeColumn(c)
    }
}

/// 消す前の確認
func confirmRemove(title: String, message: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("削除"))
    alert.addButton(withTitle: L("キャンセル"))
    alert.buttons.first?.hasDestructiveAction = true
    return alert.runModal() == .alertFirstButtonReturn
}

/// ⌘ドラッグでクリップを移動するときの状態
final class SlotDragState: ObservableObject {
    static let space = "clipGrid"
    @Published var source: Int?
    @Published var target: Int?
    /// ⌥ドラッグ（複製）中か。false なら ⌘ドラッグ（移動）
    @Published var copying = false
    /// 複数選択したクリップをまとめて動かしている
    @Published var group = false
    /// グリッドの左上（ウィンドウの中の位置。キューの一覧の上かを調べるのに使う）
    var gridOrigin: CGPoint = .zero
    /// レイヤー欄をドラッグしてレイヤーを動かしているときの、元の段と行き先の段
    @Published var layerSource: Int?
    @Published var layerTarget: Int?
    var layerFrames: [Int: CGRect] = [:]

    func layer(atY y: CGFloat) -> Int? {
        if let hit = layerFrames.first(where: { y >= $0.value.minY && y <= $0.value.maxY })?.key { return hit }
        // 上下にはみ出したら端の段
        guard let top = layerFrames.min(by: { $0.value.minY < $1.value.minY }),
              let bottom = layerFrames.max(by: { $0.value.minY < $1.value.minY }) else { return nil }
        return y < top.value.minY ? top.key : (y > bottom.value.maxY ? bottom.key : nil)
    }
    @Published var location: CGPoint = .zero
    var frames: [Int: CGRect] = [:]

    func index(at p: CGPoint) -> Int? {
        frames.first { $0.value.contains(p) }?.key
    }
}

private struct LayerFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SlotFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// グリッド左端のレイヤー欄（不透明度フェーダーと停止）。クリックでこのレイヤーを選択。
/// 重ね方・音量・トランスフォームは下のレイヤータブで。
struct LayerHeader: View {
    /// 右クリックの「探して追加…」で開く、エフェクトを探す窓
    @State private var showPicker = false
    @ObservedObject var layer: Layer
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var drag: SlotDragState

    @Environment(\.gridSize) private var gridSize

    var body: some View {
        let selected = engine.selectedLayer == layer.index
        let playing = engine.viewPlaying(layer.index).flatMap { engine.slots[$0] }

        VStack(alignment: .leading, spacing: gridSize == .large ? 6 : 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(playing != nil ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(layer.name)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .fixedSize()
                    .onTapGesture(count: 2) { renameLayer() }
                    .help(L("ダブルクリックで名前を付ける"))
                if layer.volume == 0 || layer.audioMuted {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // ソロ（出力のレイヤーに。シーンの編集中も同じ）
                if engine.layers.indices.contains(layer.index) {
                    SoloButton(layer: engine.layers[layer.index])
                        .layoutPriority(1)
                }
                MuteButton(muted: $layer.muted, what: layer.name, compact: true)
                    .layoutPriority(1)
                Button {
                    engine.viewStop(layer.index)
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11))
                        .frame(width: 18, height: 16)
                }
                .controlSize(.small)
                .disabled(playing == nil)
                .help(engine.sceneDraft != nil ? L("このシーンではこのレイヤーに何も流さない") : L("このレイヤーを停止"))
            }
            // 不透明度：左右ドラッグ（クリックだけでは変わらない）、ダブルクリックで 100%
            ValueDrag(label: L("レイヤーの不透明度"), value: $layer.opacity, range: 0...1, perPoint: 0.006,
                      defaultValue: 1, showsBar: true, format: { String(format: "%.0f%%", $0 * 100) },
                      live: layerOpacityLive, icon: "circle.lefthalf.filled")
                .frame(height: gridSize == .small ? 18 : (gridSize == .medium ? 22 : 28))
            Spacer(minLength: 0)
            // 小さい表示では、下の段（重ね方・名前）は省く
            if gridSize != .small {
            HStack(spacing: 4) {
                // 重ね方：押すとその場で選べる
                if !layer.isAdjustment { BlendMenuButton(layer: layer) }
                if !layer.isAdjustment { EffectIcons(effects: layer.effects, max: 3) }
                if let a = engine.viewPlaying(layer.index), engine.deckOf(a) != engine.shownDeck,
                   engine.decks.indices.contains(engine.deckOf(a)) {
                    Image(systemName: "square.grid.3x3.fill").font(.system(size: 10)).foregroundStyle(.orange)
                        .help(L("別のデッキ（\(engine.decks[engine.deckOf(a)].name)）のクリップを再生中"))
                }
                // 付けた名前があればそれを（シーンの編集中も、出力のレイヤーの名前）。無ければ再生中のクリップ名
                if let t = layerTitle, !t.isEmpty {
                    Text(t)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { renameLayer() }
                        .help(t + (playing.map { L("\n再生中：") + $0.name } ?? "") + L("\n（ダブルクリックで名前を変える）"))
                } else {
                    Text(playing?.name ?? "—")
                        .font(.system(size: 11))
                        .foregroundStyle(playing != nil ? Color.primary.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
            }
            }
        }
        .padding(gridSize == .large ? 8 : 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // ほかのレイヤーのソロで隠れているときは薄く
        .modifier(SoloDim(layer: engine.layers.indices.contains(layer.index) ? engine.layers[layer.index] : layer))
        // 流しているクリップのサムネイルを、うしろに薄く（何が出ているか一目で分かるように。字が読めるよう左を暗く）
        .background {
            if let img = playing?.thumbnail, !layer.isAdjustment {
                ZStack {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .opacity((layer.muted ? 0.25 : 0.55) * max(layer.opacity, 0.35))
                    LinearGradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0.35), Color.black.opacity(0.15)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(headerFill(selected: selected)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: selected ? 1.5 : 1))
        // レイヤーを動かすときの行き先
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3)
            .opacity(drag.layerSource != nil && drag.layerSource != layer.index && drag.layerTarget == layer.index ? 1 : 0)
            .allowsHitTesting(false))
        .opacity(drag.layerSource == layer.index ? 0.45 : 1)
        .background(GeometryReader { g in
            Color.clear.preference(key: LayerFramesKey.self, value: [layer.index: g.frame(in: .named(SlotDragState.space))])
        })
        .contentShape(Rectangle())
        .onTapGesture {
            engine.selectedLayer = layer.index
            engine.inspectorTab = .layer
        }
        // ドラッグで上下に動かす（不透明度の欄・ボタンの上からは動かない）
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(SlotDragState.space))
            .onChanged { v in
                if drag.layerSource == nil { drag.layerSource = layer.index }
                drag.location = v.location
                drag.layerTarget = drag.layer(atY: v.location.y)
            }
            .onEnded { _ in
                if let s = drag.layerSource, let t = drag.layerTarget, s != t { engine.moveLayer(s, to: t) }
                drag.layerSource = nil
                drag.layerTarget = nil
            })
        .effectDropTarget { k in
            layer.addEffect(k)
            engine.selectedLayer = layer.index
            engine.inspectorTab = .layer
        }
        .effectPickerPopover($showPicker, targetLabel: L("レイヤー \(layer.displayName) に足す")) { k in
            layer.addEffectOpened(k)
            engine.selectedLayer = layer.index
            engine.inspectorTab = .layer
        }
        .contextMenu {
            Button(L("名前を変える…")) { renameLayer() }
            Button(L("このレイヤーにエフェクトを探して追加…")) { showPicker = true }
            Menu(L("このレイヤーにエフェクトを追加")) {
                AddEffectMenuItems { k in
                    layer.addEffectOpened(k)
                    engine.selectedLayer = layer.index
                    engine.inspectorTab = .layer
                }
            }
            Divider()
            Button(L("上にレイヤーを追加")) { engine.insertLayer(at: layer.index) }
                .disabled(engine.layerCount >= Engine.maxLayers)
            Button(L("下にレイヤーを追加")) { engine.insertLayer(at: layer.index + 1) }
                .disabled(engine.layerCount >= Engine.maxLayers)
            Divider()
            Button(L("上へ移動")) { engine.moveLayer(layer.index, to: layer.index - 1) }
                .disabled(layer.index == 0)
            Button(L("下へ移動")) { engine.moveLayer(layer.index, to: layer.index + 1) }
                .disabled(layer.index >= engine.layerCount - 1)
            Divider()
            Button(layer.isAdjustment ? L("調整レイヤーをやめる（クリップのレイヤーに戻す）") : L("調整レイヤーにする（下のレイヤー全体にエフェクト）")) {
                layer.isAdjustment.toggle()
            }
            Divider()
            Button(L("このレイヤーを削除…"), role: .destructive) {
                let r = layer.index
                if engine.layerHasClips(r) {
                    guard confirmRemove(title: L("\(layer.name) を削除しますか？"),
                                        message: L("このレイヤーのクリップはグリッドから外れます（再生中なら止まります）。")) else { return }
                }
                engine.removeLayer(r)
            }
            .disabled(engine.layerCount <= 1)
        }
    }
}

extension LayerHeader {
    /// レイヤー欄の地の色（ミュート = 赤、選択中 = 青、調整レイヤー = 青緑）
    func headerFill(selected: Bool) -> Color {
        if layer.muted { return Color.red.opacity(0.16) }
        if selected { return Color.accentColor.opacity(0.22) }
        return layer.isAdjustment ? Color.teal.opacity(0.10) : Color.white.opacity(0.04)
    }

    /// 出力のレイヤーに付けた名前（シーンの編集中も同じ）
    var layerTitle: String? {
        engine.layers.indices.contains(layer.index) ? engine.layers[layer.index].title : nil
    }

    func renameLayer() {
        guard engine.layers.indices.contains(layer.index) else { return }
        let l = engine.layers[layer.index]
        if let t = askText(title: L("\(l.name) の名前（空にすると番号だけ）"), initial: l.title) { l.title = t }
    }

    /// 不透明度にアニメーションが付いていれば、今の値
    var layerOpacityLive: (() -> Double)? {
        let a = layer.anim(.opacity)
        guard a.isOn else { return nil }
        let base = layer.opacity, beat = engine.beatClock
        return { a.value(base: base, at: CACurrentMediaTime(), beat: beat) }
    }
}

/// 0〜100 の小さいスライダー。数字をダブルクリックで 100 に戻す。
struct MiniSlider: View {
    let icon: String
    @Binding var value: Double
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Slider(value: $value, in: 0...1)
                .controlSize(.mini)
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(value < 0.999 ? Color.orange : Color.secondary)
                .frame(width: 20, alignment: .trailing)
                .onTapGesture(count: 2) { value = 1 }
        }
        .help(help + L("（数字をダブルクリックで 100）"))
    }
}

struct SlotCell: View {
    let index: Int
    var width: CGFloat = 100
    var height: CGFloat = 80
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var drag: SlotDragState
    @Environment(\.gridSize) private var gridSize
    @State private var pressed = false
    @State private var dropTargeted = false
    @State private var hovering = false
    /// 空きの枠で、右上の＋の上を押した（離したらクリップを読み込む）
    @State private var addPressed = false
    /// 名前の帯を押した（そのままドラッグするとキューに足せる）
    @State private var stripPress = false
    /// マウスが乗っている所（上の絵 = 出す、下の名前の帯 = 選ぶ）
    @State private var zone: SlotZone?
    /// 右クリックの「探して追加…」で開く、エフェクトを探す窓
    @State private var showPicker = false

    var body: some View {
        let slot = engine.slots[index]
        let editing = engine.sceneDraft != nil
        let active = engine.viewPlaying(engine.layerOf(index)) == index
        // 編集中に、出力で再生中のクリップ（小さな印だけ）
        let liveHere = editing && engine.activeByLayer[engine.layerOf(index)] == index
        let moving = drag.source == index && !drag.copying
        let dropHere = drag.source != nil && drag.source != index && drag.target == index
        let moveTarget = dropHere && (!drag.copying || engine.canDuplicate(to: index))
        let badTarget = dropHere && drag.copying && !engine.canDuplicate(to: index)
        let picked = engine.multiSelection.contains(index)

        ZStack {
            if let slot {
                SlotContent(slot: slot, active: active, selected: engine.inspectedIndex == index,
                            hoverZone: drag.source == nil && !pressed ? (zone ?? Self.debugZones[index]) : nil)
            } else {
                // 空きの枠：クリックでこのレイヤーを停止（Arena と同じ）。右上の＋でクリップを読み込む
                RoundedRectangle(cornerRadius: 6)
                    // 調整レイヤーの行は青緑がかった色（ほかの段と見分ける）
                    .fill(adjustmentRow ? Color.teal.opacity(hovering ? 0.16 : 0.09) : Color.white.opacity(hovering ? 0.07 : 0.04))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(hovering ? Color.primary : Color.secondary.opacity(0.6))
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(addPressed ? 0.25 : (hovering ? 0.12 : 0.05))))
                            .padding(4)
                    }
            }
        }
        .frame(width: width, height: height)
        .opacity(moving ? 0.4 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(badTarget ? Color.red
                        : dropTargeted || moveTarget ? Color.accentColor
                        : (active ? (editing ? Color.orange : Color.green)
                           : (adjustmentRow ? Color.teal.opacity(0.35) : Color.gray.opacity(0.3))),
                        lineWidth: active || dropTargeted || moveTarget || badTarget ? 3 : 1)
        )
        .overlay {
            // ⇧クリックで選んだクリップ
            if picked {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.28))
                    RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if engine.slots[index] != nil {
                ControlBadge(address: "/halo/layer/\(engine.layerOf(index) + 1)/clip/\(engine.columnOf(index) + 1)")
                    .padding(.leading, 4).padding(.bottom, gridSize.stripHeight + 3)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if liveHere {
                Text(L("出力中"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: SlotFramesKey.self, value: [index: g.frame(in: .named(SlotDragState.space))])
        })
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p):
                let z: SlotZone = p.y >= height - gridSize.stripHeight ? .strip : .top
                if zone != z { zone = z }
            case .ended:
                zone = nil
            }
        }
        .help(slot == nil
              ? (adjustmentRow ? L("クリックでこのレイヤーのエフェクトを外す。右上の＋でエフェクトのクリップを作る。エフェクト一覧からドラッグでも作れる")
                               : L("クリックでこのレイヤーを停止。右上の＋・右クリック・動画のドロップでクリップを入れる"))
              : "")
        // クリックを離した時ではなく「押した瞬間」に再生する。
        // 名前の帯（または ⌘）からドラッグで移動、⌥ドラッグで複製（どちらも再生しない。⌥クリックだけなら選択）。
        // どのドラッグも、キューの一覧に落とせばキューに足す
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(SlotDragState.space))
                .onChanged { v in
                    if !pressed {
                        pressed = true
                        if slot == nil {
                            if inAddCorner(v.startLocation) {
                                addPressed = true
                            } else {
                                // 空きの枠を押した → そのレイヤーを止める（シーンの編集中は、シーンのそのレイヤーを「なし」に）
                                engine.clearMultiSelection()
                                engine.viewStop(engine.layerOf(index))
                            }
                        } else {
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.shift) && !mods.contains(.command) && !mods.contains(.option) {
                                engine.toggleMultiSelect(index)   // ⇧クリック：複数選択に足す・外す（再生しない）
                            } else if mods.contains(.command) {
                                drag.copying = false
                                // 選んだクリップの 1 つなら、選んだもの全部をまとめて動かす
                                drag.group = engine.multiSelection.count > 1 && engine.multiSelection.contains(index)
                                if !drag.group { engine.clearMultiSelection() }
                                drag.source = index
                            } else if mods.contains(.option) {
                                // 選択して、そのままドラッグすれば複製
                                engine.clearMultiSelection()
                                engine.selectClip(index)
                                drag.copying = true
                                drag.source = index
                            } else if inNameStrip(v.startLocation) {
                                engine.clearMultiSelection()
                                engine.selectClip(index)   // 名前の帯（または ⌥クリック）は選択だけ。出力しない
                                stripPress = true
                            } else {
                                engine.clearMultiSelection()
                                engine.pressSlot(index)
                            }
                        }
                    }
                    // 名前の帯からドラッグ → 動かす（グリッドの枠へ）／キューに足す（キューの一覧へ）
                    if stripPress && drag.source == nil && hypot(v.translation.width, v.translation.height) > 6 {
                        drag.copying = false
                        drag.group = false
                        drag.source = index
                    }
                    if drag.source == index {
                        drag.location = v.location
                        drag.target = drag.index(at: v.location)
                        CueDropTarget.shared.track(CGPoint(x: drag.gridOrigin.x + v.location.x,
                                                           y: drag.gridOrigin.y + v.location.y))
                    }
                }
                .onEnded { _ in
                    if drag.source == index {
                        if CueDropTarget.shared.hovering {
                            // キューの一覧に落とした → キューに足す（グリッドはそのまま）
                            engine.addClipCue(index)
                            CueDropTarget.shared.hovering = false
                        } else if let t = drag.target, t != index {
                            if drag.group {
                                if !engine.moveSelection(anchor: index, to: t) { NSSound.beep() }
                            } else if drag.copying {
                                if engine.duplicateSlot(index, to: t) { engine.selectClip(t) }
                            } else {
                                engine.moveSlot(index, to: t)
                            }
                        }
                        drag.source = nil
                        drag.target = nil
                        drag.copying = false
                        drag.group = false
                    } else if slot == nil && addPressed {
                        // 調整レイヤーの空き枠の＋ → エフェクトのクリップを作る
                        if adjustmentRow { engine.createEffectClip(at: index) } else { engine.openPanel(for: index) }
                    }
                    stripPress = false
                    addPressed = false
                    pressed = false
                }
        )
        // 動画ファイル → 読み込む。エフェクト一覧から → このクリップに付ける（空きスロットには付けない）
        .onDrop(of: [.fileURL, .plainText], isTargeted: $dropTargeted) { providers in
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                // 調整レイヤーには動画・画像は置かない
                if adjustmentRow { NSSound.beep(); return false }
                loadDropped(providers)
                return true
            }
            return EffectDrop.handle(providers, allowGenerators: !adjustmentRow) { k in
                if adjustmentRow && engine.slots[index] == nil {
                    // 調整レイヤーの空き枠 → そのエフェクトでエフェクトのクリップを作る
                    if !engine.createEffectClip(at: index, with: k) { NSSound.beep() }
                    return
                }
                if k.isGenerator {
                    // ジェネレーター → このスロットに置く（再生中のクリップは置き換えない）
                    if engine.placeGenerator(k, at: index) { engine.selectClip(index) } else { NSSound.beep() }
                    return
                }
                guard let slot = engine.slots[index] else { NSSound.beep(); return }
                slot.addEffect(k)
                engine.selectClip(index)
            }
        }
        .effectPickerPopover($showPicker, targetLabel: pickerTarget, addPicked)
        .contextMenu {
            if picked {
                let n = engine.multiSelection.count
                Section(L("選んだ \(n) 個のクリップ")) {
                    Button(L("選んだ \(n) 個を削除…"), role: .destructive) { SelectionMenu.delete(engine) }
                    if engine.decks.count > 1 {
                        Menu(L("別のデッキの同じ場所へ移動")) {
                            ForEach(Array(engine.decks.enumerated()), id: \.element.id) { d, deck in
                                if d != engine.deckOf(index) {
                                    Button(deck.name) { if !engine.moveSelection(toDeck: d) { SelectionMenu.cannotMove() } }
                                }
                            }
                        }
                    }
                    Button(L("選択を解除")) { engine.clearMultiSelection() }
                }
                Divider()
            }
            if let slot {
                Button(L("エフェクトを探して追加…")) { showPicker = true }
                Menu(L("エフェクトを追加")) {
                    AddEffectMenuItems { k in
                        slot.addEffectOpened(k)
                        engine.selectClip(index)
                        engine.inspectorTab = .clip
                    }
                }
                Divider()
                Picker(L("終わったら"), selection: Binding(get: { slot.endAction }, set: { slot.endAction = $0 })) {
                    ForEach(EndAction.allCases) { Text($0.label).tag($0) }
                }
                if slot.hasInOut { Button(L("再生範囲をリセット")) { slot.resetInOut() } }
                Button(L("速度を 1.0x に戻す")) { slot.speed = 1.0 }
                Button(L("選択（出力せずに編集）")) { engine.selectClip(index) }
                Button(L("名前を変える…")) { ClipRename.ask(slot) }
                Divider()
                ControlMenuItems(address: "/halo/layer/\(engine.layerOf(index) + 1)/clip/\(engine.columnOf(index) + 1)",
                                 verb: L("出す", note: "動詞"), title: L("L\(engine.layerOf(index) + 1) の \(engine.columnOf(index) + 1) 列目のクリップを出す"))
                Button(slot.muted ? L("ミュートを解除") : L("ミュート（映像と音を出さない）")) { slot.muted.toggle() }
                Button(L("トランスフォームをリセット")) { slot.resetTransform() }
                if !slot.isGenerator {
                    Button(L("動画ファイルを付け直す…（設定はそのまま）")) { ProjectMenu.relink(index) }
                }
                Button(L("別のクリップに差し替え…")) { engine.openPanel(for: index) }
                Button(L("キューに足す")) { engine.addClipCue(index) }
                if active {
                    Button(editing ? L("このシーンではこのレイヤーに何も流さない") : L("このレイヤーを停止")) {
                        engine.viewStop(engine.layerOf(index))
                    }
                }
                Divider()
                Button(L("このスロットを空にする"), role: .destructive) { engine.clear(index) }
            } else if adjustmentRow {
                Button(L("エフェクトのクリップを作る")) { engine.createEffectClip(at: index) }
                Menu(L("エフェクトを選んでクリップを作る")) {
                    AddEffectMenuItems { k in if !engine.createEffectClip(at: index, with: k) { NSSound.beep() } }
                }
            } else {
                Button(L("クリップを読み込む…")) { engine.openPanel(for: index) }
                Menu(L("ジェネレーターを置く")) {
                    ForEach(GeneratorCategory.allCases) { cat in
                        Section(cat.label) {
                            ForEach(cat.kinds) { k in
                                Button(k.label) { if engine.placeGenerator(k, at: index) { engine.selectClip(index) } }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 探す窓の上に出す、足す先
    private var pickerTarget: String? { engine.slots[index].map { L("クリップ \($0.name) に足す") } }

    /// 探す窓で選んだエフェクトを、このクリップに足す
    private func addPicked(_ k: EffectKind) {
        guard let slot = engine.slots[index] else { return }
        slot.addEffectOpened(k)
        engine.selectClip(index)
        engine.inspectorTab = .clip
    }

    /// 調整レイヤーの行か（シーンの編集中は、そのシーンのレイヤーで見る）
    private var adjustmentRow: Bool { engine.viewLayer(engine.layerOf(index)).isAdjustment }

    /// 空きの枠の右上の＋の上か
    private func inAddCorner(_ p: CGPoint) -> Bool {
        guard let f = drag.frames[index] else { return false }
        return p.x >= f.maxX - 30 && p.y <= f.minY + 30
    }

    /// サムネイル下の名前の帯の上か
    private func inNameStrip(_ p: CGPoint) -> Bool {
        guard let f = drag.frames[index] else { return false }
        return p.y >= f.maxY - gridSize.stripHeight
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [Int: URL] = [:]
        for (n, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { urls[n] = url } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let sorted = urls.keys.sorted().compactMap { urls[$0] }
            engine.load(urls: sorted, startingAt: index)
        }
    }
}

/// グリッドの表示の大きさ（大 = 幅いっぱい、中・小 = 小さい枠でたくさん見せる）
enum GridSize: Int {
    case large = 0, medium = 1, small = 2
    /// クリップの名前の帯の高さ
    var stripHeight: CGFloat { self == .small ? 18 : (self == .medium ? 22 : 26) }
    var nameFont: CGFloat { self == .small ? 10 : (self == .medium ? 11 : 12) }
}

private struct GridSizeKey: EnvironmentKey { static let defaultValue = GridSize.large }
extension EnvironmentValues {
    var gridSize: GridSize {
        get { self[GridSizeKey.self] }
        set { self[GridSizeKey.self] = newValue }
    }
}

/// クリップの枠のどこにマウスが乗っているか
enum SlotZone { case top, strip }

extension SlotCell {
    /// 画面確認用：VJ_HOVER=番号:top,番号:strip で、その枠にマウスが乗っている見た目にする
    static let debugZones: [Int: SlotZone] = {
        var out: [Int: SlotZone] = [:]
        for item in (ProcessInfo.processInfo.environment["VJ_HOVER"] ?? "").split(separator: ",") {
            let p = item.split(separator: ":")
            if p.count == 2, let i = Int(p[0]) { out[i] = p[1] == "strip" ? .strip : .top }
        }
        return out
    }()
}

struct SlotContent: View {
    @ObservedObject var slot: ClipSlot
    let active: Bool
    let selected: Bool
    /// マウスが乗っている所（上の絵を押すと出す、名前の帯を押すと選ぶだけ。どちらか分かるように見せる）
    var hoverZone: SlotZone? = nil
    @Environment(\.gridSize) private var gridSize
    /// 名前の帯の高さ（ここをクリックすると選択のみ）
    static let stripHeight: CGFloat = 26

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white.opacity(0.06)
                .overlay {
                    if slot.isEffectClip {
                        // エフェクトのクリップ：紫の地に、エフェクトのアイコン
                        ZStack {
                            LinearGradient(colors: [Color.purple.opacity(0.45), Color.indigo.opacity(0.3)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            HStack(spacing: 6) {
                                ForEach(slot.effects.prefix(4)) { e in
                                    Image(systemName: e.kind.icon).font(.system(size: 18, weight: .semibold))
                                        .opacity(e.enabled ? 1 : 0.35)
                                }
                                if slot.effects.isEmpty {
                                    Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 18))
                                        .opacity(0.6)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.bottom, gridSize.stripHeight)
                        }
                    } else if let img = slot.thumbnail {
                        // 黒地（出力と同じ）。暗い透明の素材は灰色の地。小さく描かれた素材は中身に寄せる。
                        // マウスを乗せている間は、市松模様の上に全体を出して透明の範囲を見せる
                        let st = slot.thumbStyle
                        let peek = hoverZone == .top && st.hasAlpha
                        ZStack {
                            if peek { CheckerBackground() } else { st.background }
                            if let z = st.zoomed, !peek {
                                Image(nsImage: z).resizable().aspectRatio(contentMode: .fit)
                                    .padding(4)
                                    .padding(.bottom, gridSize.stripHeight)
                            } else {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                    }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if !slot.isEffectClip && slot.thumbStyle.hasAlpha {
                        ThumbBadge(style: slot.thumbStyle)
                            .padding(.trailing, 3)
                            .padding(.bottom, gridSize.stripHeight + 3)
                            .allowsHitTesting(true)
                    }
                }
                .opacity(slot.isReady ? (slot.muted ? 0.35 : 1) : 0.4)
                .overlay(alignment: .topLeading) {
                    if !slot.isEffectClip { EffectIcons(effects: slot.effects).padding(4) }
                }
                .overlay(alignment: .topTrailing) {
                    if slot.muted {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                            .help(L("ミュート中（右クリックで解除）"))
                    }
                }
                .overlay {
                    // 上の絵に乗った：押すと出力に出す（▶）
                    if hoverZone == .top {
                        ZStack {
                            Color.white.opacity(0.1)
                            Image(systemName: active ? "arrow.counterclockwise" : "play.fill")
                                .font(.system(size: gridSize == .small ? 12 : 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: gridSize == .small ? 26 : 34, height: gridSize == .small ? 26 : 34)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                                .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
                        }
                        .padding(.bottom, gridSize.stripHeight)
                        .allowsHitTesting(false)
                    }
                }

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if slot.isImage { Image(systemName: "photo").font(.system(size: 10)) }
                    if slot.endAction != .hold && !slot.isImage && !slot.isEffectClip { EndActionIcon(action: slot.endAction, size: 10) }
                    if slot.hasInOut && !slot.isImage { Image(systemName: "scissors").font(.system(size: 10)) }
                    if slot.audioMuted { Image(systemName: "speaker.slash.fill").font(.system(size: 10)).foregroundStyle(.red) }
                    if slot.jumpBeats > 0 && !slot.isImage { Image(systemName: "die.face.5").font(.system(size: 10)).foregroundStyle(.purple) }
                    if slot.syncMode == .bpm {
                        Text(ParamAnim.beatsLabel(slot.syncBeats))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.purple)
                    } else if abs(slot.speed - 1) > 0.00005 {
                        Text(String(format: "%.3fx", slot.speed))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    Text(slot.errorMessage ?? slot.name)
                        .font(.system(size: gridSize.nameFont, weight: .medium))
                        .foregroundStyle(slot.errorMessage == nil ? Color.white : Color.red)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                if active {
                    ClockBar(slot: slot, color: .green, track: .clear)
                        .frame(height: 3)
                }
            }
            .frame(height: gridSize.stripHeight)
            // 名前の帯に乗った：押すと選ぶだけ（出力しない）。帯を明るい灰色にして（選択中の青と見分ける）、上の線で区切る
            .background(selected ? Color.accentColor.opacity(hoverZone == .strip ? 1 : 0.9)
                        : (hoverZone == .strip ? Color(white: 0.42).opacity(0.95) : Color.black.opacity(0.65)))
            .overlay(alignment: .top) {
                if hoverZone == .strip {
                    Rectangle().fill(Color.white.opacity(0.8)).frame(height: 1).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                if hoverZone == .strip && gridSize != .small {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.trailing, 5)
                        .allowsHitTesting(false)
                }
            }
            .help(L("名前の帯をクリック：選択（出力せずにプレビュー・編集）"))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 右下のパネル（ライブ操作 / エフェクト一覧）

struct SidePanel: View {
    enum Tab: String { case live, scenes, cues, effects, generators, sources }
    @AppStorage("sidePanelTab") private var tab = Tab.live
    @ObservedObject private var layout = LayoutManager.shared

    var body: some View {
        // 別ウィンドウにしたタブは、ここには出さない
        let tabs = layout.attachedTabs
        let shown = tabs.contains(tab) ? tab : (tabs.first ?? .live)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { shown }, set: { tab = $0 })) {
                    ForEach(tabs, id: \.self) { t in
                        Text(PanelID.tabs.first { $0.tab == t }?.title ?? "").tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                if let p = PanelID.tabs.first(where: { $0.tab == shown }) {
                    DetachButton(panel: p)
                    if let d = DockPanel(rawValue: p.rawValue) { PanelCloseButton(panel: d) }
                }
            }
            switch shown {
            case .live: LivePanel()
            case .scenes: ScenesPanel()
            case .cues: CuePanel()
            case .effects: EffectBrowser()
            case .generators: EffectBrowser(generators: true)
            case .sources: SourcePanel()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panelBackground))
    }
}

/// パネルを別ウィンドウに出すボタン
struct DetachButton: View {
    let panel: PanelID
    var body: some View {
        Button {
            LayoutManager.shared.detach(panel)
        } label: {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 11))
        }
        .controlSize(.small)
        .help(L("「\(panel.title)」を別ウィンドウに出す（常に手前にもできる。閉じるとここに戻る）"))
    }
}

// MARK: - ライブ操作パネル（右下）

/// 選択中レイヤーの再生状況（スクラブ可）と、コンポジション速度
struct LivePanel: View {
    @EnvironmentObject var engine: Engine
    /// 離したら 1.0x に戻るモード（次回起動時も保持）
    @AppStorage("speedSpringBack") private var springBack = false

    var body: some View {
        let layerName = engine.layers[engine.selectedLayer].displayName
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(L("再生中 — \(layerName)"))
            Group {
                if let slot = engine.selectedSlot {
                    PlayingClipInfo(slot: slot)
                } else {
                    Text(L("停止中"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                }
            }
            Divider()
            SectionTitle(L("テンポ"))
            BPMControl()
            Divider()
            HStack(spacing: 8) {
                SectionTitle(L("コンポジション速度"))
                Spacer(minLength: 0)
                Picker("", selection: $springBack) {
                    Text(L("離しても保持")).tag(false)
                    Text(L("離したら 1.0x")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 230)
            }
            SpeedControl(value: $engine.masterSpeed, springBack: springBack)
                .frame(height: 72)
                .help(L("左右ドラッグで速度 / Shift で微調整 / 右クリック・ダブルクリックで 1.0x"))
            Spacer(minLength: 0)
        }
    }
}

/// 再生中クリップの名前・進行バー（ドラッグでスクラブ）・時間
struct PlayingClipInfo: View {
    @ObservedObject var slot: ClipSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: slot.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(slot.isPlaying ? .green : .secondary)
                Text(slot.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if slot.endAction != .hold {
                    EndActionIcon(action: slot.endAction, size: 11).foregroundStyle(.secondary)
                        .help(L("終わったら：") + slot.endAction.label)
                }
                if slot.syncMode == .bpm {
                    Text(L("BPM 同期 ") + ParamAnim.beatsLabel(slot.syncBeats) + String(format: L("（%.3fx）"), slot.effectiveSpeed))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.purple)
                } else if abs(slot.speed - 1) > 0.00005 {
                    Text(String(format: L("クリップ %.3fx"), slot.speed))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            ScrubBar(slot: slot)
                .frame(height: 28)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !slot.isPlaying)) { _ in
                let pos = slot.position(at: CACurrentMediaTime())
                HStack {
                    Text(fmt(pos))
                    Spacer()
                    Text(L("残り ") + fmt(max(slot.outTime - pos, 0)))
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite else { return "--:--" }
        let t = Int(s)
        return String(format: "%d:%02d.%d", t / 60, t % 60, Int((s - Double(t)) * 10))
    }
}

/// 再生位置のバー。画面の更新ごとに再生時計から位置を計算するので、一定の速さで滑らかに進む。
struct ClockBar: View {
    @ObservedObject var slot: ClipSlot
    var color: Color
    var track: Color

    var body: some View {
        TimelineView(.animation(paused: !slot.isPlaying)) { _ in
            let pos = slot.position(at: CACurrentMediaTime())
            let f = slot.duration > 0 ? pos / slot.duration : 0
            GeometryReader { g in
                let d = max(slot.duration, 0.001)
                let xi = g.size.width * CGFloat(slot.inPoint / d)
                let xo = g.size.width * CGFloat(slot.outTime / d)
                ZStack(alignment: .leading) {
                    Rectangle().fill(track)
                    Rectangle().fill(color).frame(width: g.size.width * CGFloat(min(max(f, 0), 1)))
                    // イン点より前・アウト点より後は暗く
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(xi, 0))
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(g.size.width - xo, 0)).offset(x: xo)
                }
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// 進行バー。ドラッグでスクラブ（離すとその位置から再生）
struct ScrubBar: View {
    @ObservedObject var slot: ClipSlot
    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                ClockBar(slot: slot, color: .accentColor, track: Color.white.opacity(0.12))
                    .frame(height: hovering || slot.isScrubbing ? 16 : 10)
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = min(max(v.location.x / max(g.size.width, 1), 0), 1)
                        slot.scrub(to: f * slot.duration)
                    }
                    .onEnded { _ in slot.endScrub() }
            )
            .onHover { hovering = $0 }
        }
        .help(L("ドラッグで再生位置を移動（スクラブ）"))
    }
}

// MARK: - コーナーピン編集

struct CornerPinOverlay: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        GeometryReader { geo in
            let pts = engine.corners.map { CGPoint(x: CGFloat($0.x) * geo.size.width, y: CGFloat($0.y) * geo.size.height) }
            ZStack {
                Path { p in
                    p.move(to: pts[0])
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                    p.closeSubpath()
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(Color.yellow)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1))
                        .frame(width: 14, height: 14)
                        .position(pts[i])
                        .gesture(
                            DragGesture(coordinateSpace: .named("pin"))
                                .onChanged { v in
                                    let x = min(max(v.location.x / geo.size.width, 0), 1)
                                    let y = min(max(v.location.y / geo.size.height, 0), 1)
                                    engine.corners[i] = SIMD2(Float(x), Float(y))
                                }
                        )
                }
            }
            .coordinateSpace(name: "pin")
        }
    }
}

/// 複数選択の操作（確認のダイアログ付き）
enum SelectionMenu {
    static func delete(_ engine: Engine) {
        let n = engine.multiSelection.count
        guard n > 0 else { return }
        let playing = engine.multiSelection.contains { engine.activeByLayer.contains($0) }
        guard confirmRemove(title: L("選んだ \(n) 個のクリップを削除しますか？"),
                            message: L("グリッドから外れます") + (playing ? L("（再生中のものは止まります）") : "") + "。") else { return }
        engine.deleteSelection()
    }

    static func cannotMove() {
        NSSound.beep()
        let a = NSAlert()
        a.messageText = L("移動できません")
        a.informativeText = L("移動先の場所に、選んでいない別のクリップがあります。")
        a.runModal()
    }
}

/// レイヤー欄の右の縦の音量フェーダー（上下ドラッグ・⇧で微調整・ダブルクリックで 100%）と、音のミュート
struct LayerVolumeStrip: View {
    @ObservedObject var layer: Layer
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 4) {
            Button {
                layer.audioMuted.toggle()
            } label: {
                Image(systemName: layer.audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(layer.audioMuted ? Color.white : Color.secondary)
                    .frame(width: 24, height: 20)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(layer.audioMuted ? Color.red : Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(layer.audioMuted ? L("\(layer.name)の音のミュートを解除") : L("\(layer.name)の音だけを消す（映像はそのまま）"))

            GeometryReader { g in
                let h = g.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 4)
                        .fill((layer.volume < 0.999 ? Color.orange : Color.blue).opacity(0.55))
                        .frame(height: max(h * layer.volume, 0))
                    // 今の値（%）
                    Text("\(Int((layer.volume * 100).rounded()))")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, 3)
                }
                .opacity(layer.audioMuted ? 0.4 : 1)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let start = dragStart ?? layer.volume
                        dragStart = start
                        let k = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
                        layer.volume = min(max(start - Double(v.translation.height / max(h, 1)) * k, 0), 1)
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture(count: 2) { layer.volume = 1 }
                .help(L("\(layer.name)の音量 \(Int((layer.volume * 100).rounded()))%（上下ドラッグ・⇧で微調整・ダブルクリックで 100%）"))
            }
        }
    }
}

/// レイヤー欄のソロボタン（S）。ソロのレイヤーだけが出る（映像と音。確認用で保存しない）
struct SoloButton: View {
    @ObservedObject var layer: Layer
    var body: some View {
        Button {
            layer.solo.toggle()
        } label: {
            Text("S")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(layer.solo ? Color.black : Color.secondary)
                .frame(width: 18, height: 16)
        }
        .buttonStyle(.bordered)
        .tint(layer.solo ? Color.yellow : nil)
        .background(RoundedRectangle(cornerRadius: 5).fill(layer.solo ? Color.yellow : Color.clear))
        .controlSize(.small)
        .help(layer.solo ? L("\(layer.name) のソロを外す") : L("\(layer.name) をソロにする（ソロのレイヤーだけが出る。いくつでも。確認用で保存しない）"))
    }
}

/// レイヤー欄の重ね方のボタン。押すと選べる（通常以外は紫）
struct BlendMenuButton: View {
    @ObservedObject var layer: Layer
    var body: some View {
        Menu {
            ForEach(BlendMode.allCases) { b in
                Button((layer.blend == b ? "✓ " : "") + b.label) { layer.blend = b }
            }
        } label: {
            Text(layer.blend.shortLabel)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(layer.blend == .normal ? Color.secondary : Color.white)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3)
            .fill(layer.blend == .normal ? Color.white.opacity(0.08) : Color.purple.opacity(0.55)))
        .help(L("重ね方：") + layer.blend.label + L("（押して選ぶ）"))
    }
}

/// ほかのレイヤーのソロで隠れているレイヤーを薄く見せる
struct SoloDim: ViewModifier {
    @ObservedObject var layer: Layer
    func body(content: Content) -> some View {
        content.opacity(layer.soloHidden ? 0.4 : 1)
    }
}
