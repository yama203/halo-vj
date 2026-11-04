import SwiftUI
import UniformTypeIdentifiers

/// 画面全体で使う見た目の共通部品
enum UI {
    /// 右列（出力モニター・ライブ操作）の幅
    static let sideWidth: CGFloat = 470
    static let panelBackground = Color.white.opacity(0.035)
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
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
                let gridWidth = g.size.width - 24 - 12 - UI.sideWidth
                let cell = ClipGrid.cellHeight(forWidth: gridWidth)
                let gridHeight = cell * CGFloat(Engine.layerCount) + ClipGrid.spacing * CGFloat(Engine.layerCount - 1)
                let monitorHeight = (UI.sideWidth / max(engine.outputAspect, 0.1)) + 24
                let topHeight = min(max(gridHeight, monitorHeight) + 24, max(g.size.height - 262 - 1, 200))
                let bottomHeight = g.size.height - topHeight - 1
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        ClipGrid(cellHeight: cell)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        OutputMonitor(editCorners: editCorners)
                            .frame(width: UI.sideWidth)
                    }
                    .padding(12)
                    .frame(height: topHeight, alignment: .top)
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        ParameterPanel(previewHeight: min(max(bottomHeight - 100, 176), 420))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        LivePanel()
                            .frame(width: UI.sideWidth)
                            .frame(maxHeight: .infinity)
                    }
                    .padding(12)
                    .frame(height: bottomHeight)
                }
            }
        }
        .frame(minWidth: 1240, minHeight: 760)
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
                if editCorners {
                    Text("四隅の黄色い点をドラッグ")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.yellow)
                }
            }
            ZStack {
                MetalPreview(kind: .output)
                if editCorners { CornerPinOverlay() }
            }
            .aspectRatio(engine.outputAspect, contentMode: .fit)
            .overlay(Rectangle().stroke(editCorners ? Color.yellow.opacity(0.6) : Color.gray.opacity(0.35)))
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
            Divider().frame(height: 18)
            Button {
                engine.blackout()
            } label: {
                Label("ブラックアウト", systemImage: "stop.fill")
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .help("全レイヤーを停止して黒に (Esc)")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - クリップグリッド

struct ClipGrid: View {
    @EnvironmentObject var engine: Engine
    static let spacing: CGFloat = 6
    static let headerWidth: CGFloat = 124
    let cellHeight: CGFloat
    @StateObject private var drag = SlotDragState()

    /// グリッドの横幅から、1 段の高さ（サムネイル横幅の 3/4）を決める
    static func cellHeight(forWidth w: CGFloat) -> CGFloat {
        let cellWidth = (w - headerWidth - spacing * CGFloat(Engine.columns)) / CGFloat(Engine.columns)
        return min(max(cellWidth * 0.75, 64), 140)
    }

    var body: some View {
        let h = cellHeight
        Group {
            VStack(spacing: Self.spacing) {
                ForEach(0..<Engine.layerCount, id: \.self) { r in
                    HStack(spacing: Self.spacing) {
                        LayerHeader(layer: engine.layers[r])
                            .frame(width: Self.headerWidth, height: h)
                        ForEach(0..<Engine.columns, id: \.self) { c in
                            SlotCell(index: r * Engine.columns + c, height: h)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .coordinateSpace(name: SlotDragState.space)
        .onPreferenceChange(SlotFramesKey.self) { drag.frames = $0 }
        .overlay(alignment: .topLeading) {
            // ⌘ドラッグ中のクリップ名
            if let s = drag.source, let slot = engine.slots[s] {
                Label(slot.name, systemImage: "film")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.85), in: Capsule())
                    .fixedSize()
                    .position(x: drag.location.x, y: drag.location.y - 14)
                    .allowsHitTesting(false)
            }
        }
        .environmentObject(drag)
    }
}

/// ⌘ドラッグでクリップを移動するときの状態
final class SlotDragState: ObservableObject {
    static let space = "clipGrid"
    @Published var source: Int?
    @Published var target: Int?
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

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(playing != nil ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(layer.name)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .fixedSize()
                Spacer(minLength: 0)
                if layer.volume == 0 {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Button {
                    engine.stopLayer(layer.index)
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .disabled(playing == nil)
                .help("このレイヤーを停止")
            }
            MiniSlider(icon: "circle.lefthalf.filled", value: $layer.opacity, help: "不透明度")
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if layer.blend != .normal {
                    Text(layer.blend.label)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.purple.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                }
                Text(playing?.name ?? "—")
                    .font(.system(size: 10))
                    .foregroundStyle(playing != nil ? Color.primary.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            engine.selectedLayer = layer.index
            engine.inspectorTab = .layer
        }
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
    var height: CGFloat = 80
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var drag: SlotDragState
    @State private var pressed = false
    @State private var dropTargeted = false

    var body: some View {
        let slot = engine.slots[index]
        let active = engine.activeByLayer[Engine.layerOf(index)] == index
        let moving = drag.source == index
        let moveTarget = drag.source != nil && drag.source != index && drag.target == index

        ZStack {
            if let slot {
                SlotContent(slot: slot, active: active, selected: engine.inspectedIndex == index)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.04))
                    .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
            }
            VStack {
                HStack {
                    Text(Engine.keyLabels[index])
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    Spacer()
                }
                Spacer()
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .opacity(moving ? 0.4 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(dropTargeted || moveTarget ? Color.accentColor : (active ? Color.green : Color.gray.opacity(0.3)),
                        lineWidth: active || dropTargeted || moveTarget ? 3 : 1)
        )
        .background(GeometryReader { g in
            Color.clear.preference(key: SlotFramesKey.self, value: [index: g.frame(in: .named(SlotDragState.space))])
        })
        .contentShape(Rectangle())
        // クリックを離した時ではなく「押した瞬間」に再生する。⌘を押しながらドラッグすると移動（再生しない）
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(SlotDragState.space))
                .onChanged { v in
                    if !pressed {
                        pressed = true
                        if slot != nil {
                            if NSEvent.modifierFlags.contains(.command) {
                                drag.source = index
                            } else if NSEvent.modifierFlags.contains(.option) || inNameStrip(v.startLocation) {
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
                        if let t = drag.target { engine.moveSlot(index, to: t) }
                        drag.source = nil
                        drag.target = nil
                    } else if slot == nil {
                        engine.openPanel(for: index)
                    }
                    pressed = false
                }
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
        .contextMenu {
            if let slot {
                Toggle("ループ再生", isOn: Binding(get: { slot.loop }, set: { slot.loop = $0 }))
                Button("速度を 1.0x に戻す") { slot.speed = 1.0 }
                Button("選択（出力せずに編集）") { engine.selectClip(index) }
                Button("トランスフォームをリセット") { slot.resetTransform() }
                Button("別のクリップに差し替え…") { engine.openPanel(for: index) }
                if active {
                    Button("このレイヤーを停止") { engine.stopLayer(Engine.layerOf(index)) }
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
    static let stripHeight: CGFloat = 20

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white.opacity(0.06)
                .overlay {
                    if let img = slot.thumbnail {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .clipped()
                .opacity(slot.isReady ? 1 : 0.4)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if slot.loop { Image(systemName: "repeat").font(.system(size: 9)) }
                    if abs(slot.speed - 1) > 0.00005 {
                        Text(String(format: "%.3fx", slot.speed))
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    Text(slot.errorMessage ?? slot.name)
                        .font(.system(size: 10))
                        .foregroundStyle(slot.errorMessage == nil ? Color.white : Color.red)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
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
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
            }
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
                .controlSize(.small)
                .frame(width: 190)
            }
            SpeedControl(value: $engine.masterSpeed, springBack: springBack)
                .frame(height: 54)
                .help("左右ドラッグで速度 / Shift で微調整 / 右クリック・ダブルクリックで 1.0x")
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panelBackground))
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
                Text(slot.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if slot.loop { Image(systemName: "repeat").font(.system(size: 11)).foregroundStyle(.secondary) }
                if abs(slot.speed - 1) > 0.00005 {
                    Text(String(format: "クリップ %.3fx", slot.speed))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            ScrubBar(slot: slot)
                .frame(height: 14)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !slot.isPlaying)) { _ in
                let pos = slot.position(at: CACurrentMediaTime())
                HStack {
                    Text(fmt(pos))
                    Spacer()
                    Text("残り " + fmt(max(slot.duration - pos, 0)))
                }
                .font(.system(size: 11, design: .monospaced))
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
                ZStack(alignment: .leading) {
                    Rectangle().fill(track)
                    Rectangle().fill(color).frame(width: g.size.width * CGFloat(min(max(f, 0), 1)))
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
                    .frame(height: hovering || slot.isScrubbing ? 10 : 6)
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
