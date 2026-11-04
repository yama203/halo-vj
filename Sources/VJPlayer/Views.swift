import SwiftUI
import UniformTypeIdentifiers

/// 画面全体で使う見た目の共通部品
enum UI {
    /// 右列（出力モニター・ライブ操作）の幅
    static let sideWidth: CGFloat = 470
    static let panelBackground = Color.white.opacity(0.035)
    /// 数値欄・ボタンなどの 1 行の高さ（押しやすさ優先）
    static let rowHeight: CGFloat = 32
    /// パラメーター欄 1 列の幅と、2 列ぶんの幅
    static let paramColumnWidth: CGFloat = 260
    static let paramsWidth: CGFloat = paramColumnWidth * 2 + 16
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @State private var editCorners = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(editCorners: $editCorners)
            Divider()
            GeometryReader { g in
                // グリッドの高さは横幅から決める（サムネイルが縦長にならないように）。残りは下のパネルへ
                // 段が多くて入りきらないときはグリッドをスクロール
                let gridWidth = g.size.width - 24 - 12 - UI.sideWidth
                let cell = ClipGrid.cellSize(forWidth: gridWidth, columns: engine.columns)
                let gridHeight = ClipGrid.contentHeight(cell: cell.height, layers: engine.layerCount)
                let monitorHeight = (UI.sideWidth / max(engine.outputAspect, 0.1)) + 24
                let topHeight = min(max(gridHeight, monitorHeight) + 24, max(g.size.height - 370 - 1, 200))
                let bottomHeight = g.size.height - topHeight - 1
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        ClipGrid(size: CGSize(width: gridWidth, height: topHeight - 24))
                            .frame(width: gridWidth, height: topHeight - 24, alignment: .topLeading)
                        OutputMonitor(editCorners: editCorners)
                            .frame(width: UI.sideWidth)
                    }
                    .padding(12)
                    .frame(height: topHeight, alignment: .top)
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        ParameterPanel(previewHeight: min(max(bottomHeight - 100, 176), 420))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        SidePanel()
                            .frame(width: UI.sideWidth)
                            .frame(maxHeight: .infinity)
                    }
                    .padding(12)
                    .frame(height: bottomHeight)
                }
            }
        }
        .background(WindowTitleSync(
            title: (engine.projectURL?.deletingPathExtension().lastPathComponent ?? "名称未設定") + " — VJPlayer",
            url: engine.projectURL, edited: engine.isDirty))
        .frame(minWidth: 1300, minHeight: 800)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

/// 右上の出力モニター（コーナーピン後、実際に出る映像）
struct OutputMonitor: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var output = OutputController.shared
    let editCorners: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionTitle("出力")
                Circle()
                    .fill(output.target == .none ? Color.gray : Color.green)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(output.target == .none ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                MuteButton(muted: $engine.compMuted, what: "コンポジション（出力全体）")
                if editCorners {
                    Text("四隅の黄色い点をドラッグ")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.yellow)
                }
            }
            ZStack {
                MetalPreview(kind: .output)
                if editCorners { CornerPinOverlay() }
                if engine.compMuted {
                    Label("コンポジションをミュート中", systemImage: "eye.slash.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                        .allowsHitTesting(false)
                } else if engine.isBlackout {
                    Label("ブラックアウト中", systemImage: "eye.slash.fill")
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
            .overlay(Rectangle().stroke(engine.isBlackout || engine.compMuted ? Color.red
                                        : editCorners ? Color.yellow.opacity(0.6) : Color.gray.opacity(0.35),
                                        lineWidth: engine.isBlackout || engine.compMuted ? 2 : 1))
            Spacer(minLength: 0)
        }
    }

    private var statusText: String {
        switch output.target {
        case .none: return "出力なし"
        case .window: return "テスト用ウィンドウ"
        case .screen(let id):
            return output.screens.first { OutputController.displayID(of: $0) == id }
                .map { OutputController.label(of: $0) } ?? "ディスプレイ"
        }
    }
}

// MARK: - 上部バー

struct TopBar: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var output = OutputController.shared
    @Binding var editCorners: Bool
    @State private var audioDevices: [AudioDevice] = AudioDevices.outputDevices()

    var body: some View {
        HStack(spacing: 14) {
            Picker("出力", selection: $output.target) {
                Text("出力なし").tag(OutputTarget.none)
                Text("ウィンドウ（テスト用）").tag(OutputTarget.window)
                ForEach(output.screens, id: \.self) { s in
                    Text(OutputController.label(of: s)).tag(OutputTarget.screen(OutputController.displayID(of: s)))
                }
            }
            .frame(width: 280)
            .help("出力を閉じる／元に戻す：⌘⇧F")

            Picker("音声", selection: $engine.audioDeviceUID) {
                Text("システム既定").tag(String?.none)
                ForEach(audioDevices) { d in
                    Text(d.name).tag(String?.some(d.id))
                }
            }
            .frame(width: 240)

            Button {
                audioDevices = AudioDevices.outputDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("オーディオデバイス一覧を更新")

            Spacer()

            Toggle(isOn: $editCorners) {
                Label("四隅を調整", systemImage: "skew")
            }
            .toggleStyle(.button)
            .help("コーナーピン（四隅）を調整")
            Button {
                engine.resetCorners()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("四隅をリセット")
            Toggle(isOn: $engine.testPattern) {
                Label("テストパターン", systemImage: "grid")
            }
            .toggleStyle(.button)
            .help("テストパターンを出力")
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
            Label(engine.isBlackout ? "ブラックアウト中" : "ブラックアウト",
                  systemImage: engine.isBlackout ? "eye.slash.fill" : "moon.fill")
                .frame(minWidth: 130)
        }
        .tint(engine.isBlackout ? .red : Color(white: 0.35))
        .buttonStyle(.borderedProminent)
        .opacity(engine.isBlackout && blink ? 0.55 : 1)
        .help(engine.isBlackout
              ? "クリックで解除 (Esc)。クリップは裏で再生を続けています"
              : "出力の映像と音を消す (Esc)。もう一度押すと元に戻る。フェード時間は設定（⌘,）。⇧Esc で全レイヤー停止")
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
    /// 上の列番号の帯と、下の「レイヤーを追加」の高さ
    static let columnBarHeight: CGFloat = 26
    static let addRowHeight: CGFloat = 32
    /// 右端の「列を追加」ボタンの幅
    static let addColumnWidth: CGFloat = 34
    /// サムネイルの最小の横幅（これより狭くなるなら横スクロール）
    static let minCellWidth: CGFloat = 100
    let size: CGSize
    @StateObject private var drag = SlotDragState()

    /// 1 マスの大きさ。横幅から決め、高さは横幅の 3/4（縦長にならないように）
    static func cellSize(forWidth w: CGFloat, columns: Int) -> CGSize {
        let n = CGFloat(max(columns, 1))
        let cw = max((w - headerWidth - addColumnWidth - spacing * (n + 1)) / n, minCellWidth)
        // レイヤー欄（名前・停止・不透明度）が収まる高さは確保する
        return CGSize(width: cw, height: min(max(cw * 0.75, 96), 150))
    }

    /// 全段を表示したときの高さ
    static func contentHeight(cell: CGFloat, layers: Int) -> CGFloat {
        columnBarHeight + spacing + (cell + spacing) * CGFloat(layers) + addRowHeight + 12
    }

    var body: some View {
        let cell = Self.cellSize(forWidth: size.width, columns: engine.columns)
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                ColumnBar(cellWidth: cell.width)
                    .frame(height: Self.columnBarHeight)
                ForEach(engine.layers) { layer in
                    let r = layer.index
                    HStack(spacing: Self.spacing) {
                        LayerHeader(layer: layer)
                            .frame(width: Self.headerWidth, height: cell.height)
                        ForEach(0..<engine.columns, id: \.self) { c in
                            SlotCell(index: r * engine.columns + c, width: cell.width, height: cell.height)
                        }
                    }
                }
                Button {
                    engine.insertLayer(at: engine.layerCount)
                } label: {
                    Label("レイヤーを追加", systemImage: "plus")
                        .font(.system(size: 12))
                        .frame(width: Self.headerWidth - 16)
                }
                .controlSize(.large)
                .disabled(engine.layerCount >= Engine.maxLayers)
                .help("一番下（一番奥）にレイヤーを足す。途中に入れるときはレイヤー欄を右クリック")
            }
            .coordinateSpace(name: SlotDragState.space)
            .onPreferenceChange(SlotFramesKey.self) { drag.frames = $0 }
            .overlay(alignment: .topLeading) {
                // ⌘ドラッグ中のクリップ名
                if let s = drag.source, engine.slots.indices.contains(s), let slot = engine.slots[s],
                   let t = drag.target, t != s {
                    Label(drag.copying ? "複製：" + slot.name : slot.name,
                          systemImage: drag.copying ? "plus.square.on.square" : "film")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.85), in: Capsule())
                        .fixedSize()
                        .position(x: drag.location.x, y: drag.location.y - 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: size.width, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .environmentObject(drag)
    }
}

/// グリッド上の列番号の帯。右クリックで列を足す・消す。右端の＋で列を足す
struct ColumnBar: View {
    @EnvironmentObject var engine: Engine
    let cellWidth: CGFloat

    var body: some View {
        HStack(spacing: ClipGrid.spacing) {
            Color.clear.frame(width: ClipGrid.headerWidth)
            ForEach(0..<engine.columns, id: \.self) { c in
                Text("\(c + 1)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: cellWidth, height: ClipGrid.columnBarHeight)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)))
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("左に列を追加") { engine.insertColumn(at: c) }
                            .disabled(engine.columns >= Engine.maxColumns)
                        Button("右に列を追加") { engine.insertColumn(at: c + 1) }
                            .disabled(engine.columns >= Engine.maxColumns)
                        Divider()
                        Button("この列を削除…", role: .destructive) { removeColumn(c) }
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
            .help("右端に列を足す。途中に入れるときは列番号を右クリック")
        }
    }

    private func removeColumn(_ c: Int) {
        if engine.columnHasClips(c) {
            guard confirmRemove(title: "\(c + 1) 列目を削除しますか？",
                                message: "この列のクリップはグリッドから外れます（再生中なら止まります）。") else { return }
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
    alert.addButton(withTitle: "削除")
    alert.addButton(withTitle: "キャンセル")
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
    @Published var location: CGPoint = .zero
    var frames: [Int: CGRect] = [:]

    func index(at p: CGPoint) -> Int? {
        frames.first { $0.value.contains(p) }?.key
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
    @ObservedObject var layer: Layer
    @EnvironmentObject var engine: Engine

    var body: some View {
        let selected = engine.selectedLayer == layer.index
        let playing = engine.activeByLayer[layer.index].flatMap { engine.slots[$0] }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(playing != nil ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(layer.name)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .fixedSize()
                if layer.volume == 0 || layer.audioMuted {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                MuteButton(muted: $layer.muted, what: layer.name, compact: true)
                Button {
                    engine.stopLayer(layer.index)
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11))
                        .frame(width: 18, height: 16)
                }
                .controlSize(.regular)
                .disabled(playing == nil)
                .help("このレイヤーを停止")
            }
            // 不透明度：左右ドラッグ（クリックだけでは変わらない）、ダブルクリックで 100%
            ValueDrag(label: "不透明度", value: $layer.opacity, range: 0...1, perPoint: 0.006,
                      defaultValue: 1, showsBar: true, format: { String(format: "%.0f%%", $0 * 100) },
                      live: layerOpacityLive)
                .frame(height: 28)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if layer.blend != .normal {
                    Text(layer.blend.label)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                }
                Text(playing?.name ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(playing != nil ? Color.primary.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(layer.muted ? Color.red.opacity(0.16)
                  : selected ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            engine.selectedLayer = layer.index
            engine.inspectorTab = .layer
        }
        .effectDropTarget { k in
            layer.addEffect(k)
            engine.selectedLayer = layer.index
            engine.inspectorTab = .layer
        }
        .contextMenu {
            Button("上にレイヤーを追加") { engine.insertLayer(at: layer.index) }
                .disabled(engine.layerCount >= Engine.maxLayers)
            Button("下にレイヤーを追加") { engine.insertLayer(at: layer.index + 1) }
                .disabled(engine.layerCount >= Engine.maxLayers)
            Divider()
            Button("このレイヤーを削除…", role: .destructive) {
                let r = layer.index
                if engine.layerHasClips(r) {
                    guard confirmRemove(title: "\(layer.name) を削除しますか？",
                                        message: "このレイヤーのクリップはグリッドから外れます（再生中なら止まります）。") else { return }
                }
                engine.removeLayer(r)
            }
            .disabled(engine.layerCount <= 1)
        }
    }
}

extension LayerHeader {
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
        .help(help + "（数字をダブルクリックで 100）")
    }
}

struct SlotCell: View {
    let index: Int
    var width: CGFloat = 100
    var height: CGFloat = 80
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var drag: SlotDragState
    @State private var pressed = false
    @State private var dropTargeted = false

    var body: some View {
        let slot = engine.slots[index]
        let active = engine.activeByLayer[engine.layerOf(index)] == index
        let moving = drag.source == index && !drag.copying
        let dropHere = drag.source != nil && drag.source != index && drag.target == index
        let moveTarget = dropHere && (!drag.copying || engine.canDuplicate(to: index))
        let badTarget = dropHere && drag.copying && !engine.canDuplicate(to: index)

        ZStack {
            if let slot {
                SlotContent(slot: slot, active: active, selected: engine.inspectedIndex == index)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.04))
                    .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
            }
        }
        .frame(width: width, height: height)
        .opacity(moving ? 0.4 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(badTarget ? Color.red
                        : dropTargeted || moveTarget ? Color.accentColor : (active ? Color.green : Color.gray.opacity(0.3)),
                        lineWidth: active || dropTargeted || moveTarget || badTarget ? 3 : 1)
        )
        .background(GeometryReader { g in
            Color.clear.preference(key: SlotFramesKey.self, value: [index: g.frame(in: .named(SlotDragState.space))])
        })
        .contentShape(Rectangle())
        // クリックを離した時ではなく「押した瞬間」に再生する。
        // ⌘ドラッグで移動、⌥ドラッグで複製（どちらも再生しない。⌥クリックだけなら選択）
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(SlotDragState.space))
                .onChanged { v in
                    if !pressed {
                        pressed = true
                        if slot != nil {
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.command) {
                                drag.copying = false
                                drag.source = index
                            } else if mods.contains(.option) {
                                // 選択して、そのままドラッグすれば複製
                                engine.selectClip(index)
                                drag.copying = true
                                drag.source = index
                            } else if inNameStrip(v.startLocation) {
                                engine.selectClip(index)   // 名前の帯（または ⌥クリック）は選択だけ。出力しない
                            } else {
                                engine.trigger(index)
                            }
                        }
                    }
                    if drag.source == index {
                        drag.location = v.location
                        drag.target = drag.index(at: v.location)
                    }
                }
                .onEnded { _ in
                    if drag.source == index {
                        if let t = drag.target, t != index {
                            if drag.copying {
                                if engine.duplicateSlot(index, to: t) { engine.selectClip(t) }
                            } else {
                                engine.moveSlot(index, to: t)
                            }
                        }
                        drag.source = nil
                        drag.target = nil
                        drag.copying = false
                    } else if slot == nil {
                        engine.openPanel(for: index)
                    }
                    pressed = false
                }
        )
        // 動画ファイル → 読み込む。エフェクト一覧から → このクリップに付ける（空きスロットには付けない）
        .onDrop(of: [.fileURL, .plainText], isTargeted: $dropTargeted) { providers in
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                loadDropped(providers)
                return true
            }
            return EffectDrop.handle(providers) { k in
                guard let slot = engine.slots[index] else { NSSound.beep(); return }
                slot.addEffect(k)
                engine.selectClip(index)
            }
        }
        .contextMenu {
            if let slot {
                Picker("終わったら", selection: Binding(get: { slot.endAction }, set: { slot.endAction = $0 })) {
                    ForEach(EndAction.allCases) { Text($0.label).tag($0) }
                }
                if slot.hasInOut { Button("再生範囲をリセット") { slot.resetInOut() } }
                Button("速度を 1.0x に戻す") { slot.speed = 1.0 }
                Button("選択（出力せずに編集）") { engine.selectClip(index) }
                Button(slot.muted ? "ミュートを解除" : "ミュート（映像と音を出さない）") { slot.muted.toggle() }
                Button("トランスフォームをリセット") { slot.resetTransform() }
                Button("動画ファイルを付け直す…（設定はそのまま）") { ProjectMenu.relink(index) }
                Button("別のクリップに差し替え…") { engine.openPanel(for: index) }
                if active {
                    Button("このレイヤーを停止") { engine.stopLayer(engine.layerOf(index)) }
                }
                Divider()
                Button("このスロットを空にする", role: .destructive) { engine.clear(index) }
            } else {
                Button("クリップを読み込む…") { engine.openPanel(for: index) }
            }
        }
    }

    /// サムネイル下の名前の帯の上か
    private func inNameStrip(_ p: CGPoint) -> Bool {
        guard let f = drag.frames[index] else { return false }
        return p.y >= f.maxY - SlotContent.stripHeight
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

struct SlotContent: View {
    @ObservedObject var slot: ClipSlot
    let active: Bool
    let selected: Bool
    /// 名前の帯の高さ（ここをクリックすると選択のみ）
    static let stripHeight: CGFloat = 26

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white.opacity(0.06)
                .overlay {
                    if let img = slot.thumbnail {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .clipped()
                .opacity(slot.isReady ? (slot.muted ? 0.35 : 1) : 0.4)
                .overlay(alignment: .topTrailing) {
                    if slot.muted {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                            .help("ミュート中（右クリックで解除）")
                    }
                }

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if slot.endAction != .hold { Image(systemName: slot.endAction.icon).font(.system(size: 10)) }
                    if slot.hasInOut { Image(systemName: "scissors").font(.system(size: 10)) }
                    if slot.audioMuted { Image(systemName: "speaker.slash.fill").font(.system(size: 10)).foregroundStyle(.red) }
                    if slot.jumpBeats > 0 { Image(systemName: "die.face.5").font(.system(size: 10)).foregroundStyle(.purple) }
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
                        .font(.system(size: 12, weight: .medium))
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
            .frame(height: Self.stripHeight)
            .background(selected ? Color.accentColor.opacity(0.9) : Color.black.opacity(0.65))
            .help("名前の帯をクリック：選択（出力せずにプレビュー・編集）")
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 右下のパネル（ライブ操作 / エフェクト一覧）

struct SidePanel: View {
    enum Tab: String { case live, effects }
    @AppStorage("sidePanelTab") private var tab = Tab.live

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text("ライブ").tag(Tab.live)
                Text("エフェクト").tag(Tab.effects)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            switch tab {
            case .live: LivePanel()
            case .effects: EffectBrowser()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panelBackground))
    }
}

// MARK: - ライブ操作パネル（右下）

/// 選択中レイヤーの再生状況（スクラブ可）と、コンポジション速度
struct LivePanel: View {
    @EnvironmentObject var engine: Engine
    /// 離したら 1.0x に戻るモード（次回起動時も保持）
    @AppStorage("speedSpringBack") private var springBack = false

    var body: some View {
        let layerName = engine.layers[engine.selectedLayer].name
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("再生中 — \(layerName)")
            Group {
                if let slot = engine.selectedSlot {
                    PlayingClipInfo(slot: slot)
                } else {
                    Text("停止中")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                }
            }
            Divider()
            SectionTitle("テンポ")
            BPMControl()
            Divider()
            HStack(spacing: 8) {
                SectionTitle("コンポジション速度")
                Spacer(minLength: 0)
                Picker("", selection: $springBack) {
                    Text("離しても保持").tag(false)
                    Text("離したら 1.0x").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 230)
            }
            SpeedControl(value: $engine.masterSpeed, springBack: springBack)
                .frame(height: 72)
                .help("左右ドラッグで速度 / Shift で微調整 / 右クリック・ダブルクリックで 1.0x")
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
                    Image(systemName: slot.endAction.icon).font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("終わったら：" + slot.endAction.label)
                }
                if slot.syncMode == .bpm {
                    Text("BPM 同期 " + ParamAnim.beatsLabel(slot.syncBeats) + String(format: "（%.3fx）", slot.effectiveSpeed))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.purple)
                } else if abs(slot.speed - 1) > 0.00005 {
                    Text(String(format: "クリップ %.3fx", slot.speed))
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
                    Text("残り " + fmt(max(slot.outTime - pos, 0)))
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
        .help("ドラッグで再生位置を移動（スクラブ）")
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
