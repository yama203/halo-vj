import AppKit
import SwiftUI

/// 数値をドラッグで変えるフィールド（Resolume のパラメータ欄のようなもの）
/// - 左右ドラッグで相対的に変化、Shift で微調整
/// - ダブルクリック / 右クリックで初期値に戻す
final class ValueDragNSView: NSView {
    var label = ""
    var value: Double = 0 { didSet { if oldValue != value { needsDisplay = true } } }
    var range: ClosedRange<Double> = 0...1
    var perPoint = 0.005
    var defaultValue = 0.0
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    /// 範囲に対する割合をバーで表示する（不透明度・音量など）
    var showsBar = false
    var onChange: ((Double) -> Void)?
    /// アニメーション中なら、今の値を返す（欄はこの値を表示し、手で動かせない）
    var live: (() -> Double)? {
        didSet {
            if (live == nil) != (oldValue == nil) { updateLiveTimer() }
        }
    }
    /// アニメーション中の説明（「→ 順 4拍」など）
    var badge = ""

    private var dragging = false
    private var liveTimer: Timer?

    private func updateLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
        if live != nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            RunLoop.main.add(t, forMode: .common)
            liveTimer = t
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { liveTimer?.invalidate(); liveTimer = nil } else if live != nil && liveTimer == nil { updateLiveTimer() }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "左右ドラッグで調整 / Shift で微調整 / ダブルクリック・右クリックで初期値"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if live != nil { return }   // アニメーション中は手で動かさない
        if event.clickCount == 2 { set(defaultValue); return }
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if live != nil { return }
        let k = event.modifierFlags.contains(.shift) ? 0.1 : 1.0
        set(value + Double(event.deltaX) * perPoint * k)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if live != nil { return }
        set(defaultValue)
    }

    private func set(_ v: Double) {
        let c = min(max(v, range.lowerBound), range.upperBound)
        guard c != value else { return }
        value = c
        onChange?(c)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSColor(white: dragging ? 0.24 : 0.17, alpha: 1).setFill()
        bg.fill()

        let shown = live?() ?? value
        let animating = live != nil
        let changed = abs(value - defaultValue) > 1e-9 || animating
        if showsBar || animating {
            let f = min(max((shown - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
            NSGraphicsContext.saveGraphicsState()
            bg.addClip()
            (animating ? NSColor.systemPurple : changed ? NSColor.systemOrange : NSColor.systemBlue)
                .withAlphaComponent(animating ? 0.45 : 0.35).setFill()
            NSBezierPath(rect: NSRect(x: r.minX, y: r.minY, width: r.width * CGFloat(f), height: r.height)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(white: 0.65, alpha: 1),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: animating ? NSColor.white : changed ? NSColor.systemOrange : NSColor.white,
        ]
        let ls = (label as NSString).size(withAttributes: labelAttrs)
        (label as NSString).draw(at: NSPoint(x: r.minX + 8, y: r.midY - ls.height / 2), withAttributes: labelAttrs)
        if animating && !badge.isEmpty {
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.systemPurple.blended(withFraction: 0.5, of: .white) ?? .white,
            ]
            (badge as NSString).draw(at: NSPoint(x: r.minX + 14 + ls.width,
                                                  y: r.midY - (badge as NSString).size(withAttributes: badgeAttrs).height / 2),
                                     withAttributes: badgeAttrs)
        }
        let text = format(shown)
        let vs = (text as NSString).size(withAttributes: valueAttrs)
        (text as NSString).draw(at: NSPoint(x: r.maxX - 8 - vs.width, y: r.midY - vs.height / 2), withAttributes: valueAttrs)
    }
}

struct ValueDrag: NSViewRepresentable {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var perPoint: Double
    var defaultValue: Double
    var showsBar = false
    var format: (Double) -> String
    var live: (() -> Double)? = nil
    var badge = ""

    func makeNSView(context: Context) -> ValueDragNSView {
        let v = ValueDragNSView()
        v.onChange = { context.coordinator.parent.value = $0 }
        apply(v)
        return v
    }

    func updateNSView(_ v: ValueDragNSView, context: Context) {
        context.coordinator.parent = self
        apply(v)
    }

    private func apply(_ v: ValueDragNSView) {
        v.label = label
        v.range = range
        v.perPoint = perPoint
        v.defaultValue = defaultValue
        v.showsBar = showsBar
        v.format = format
        v.badge = badge
        v.live = live
        v.toolTip = live != nil ? "アニメーション中（右のボタンで設定）" : "左右ドラッグで調整 / Shift で微調整 / ダブルクリック・右クリックで初期値"
        if v.value != value { v.value = value }
        v.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: ValueDrag
        init(parent: ValueDrag) { self.parent = parent }
    }
}

// MARK: - パラメーターパネル（コンポジション / レイヤー / クリップ）

/// Resolume のように、コンポジション・レイヤー・クリップの 3 階層それぞれに
/// プレビューとパラメーターを持つパネル（左下）
struct ParameterPanel: View {
    @EnvironmentObject var engine: Engine
    var previewHeight: CGFloat = 176
    /// プレビューの幅（右端の縦の線をドラッグで変える。0 = おまかせ：エフェクトが横に並ぶ大きさ）
    @AppStorage("inspectorPreviewWidth") private var previewWidthSetting = 0.0
    /// ドラッグを始めたときの幅
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        let layer = engine.layers[engine.selectedLayer]
        let clipIndex = engine.inspectedIndex.flatMap { engine.slots[$0] != nil ? $0 : nil }
        let clip = clipIndex.flatMap { engine.slots[$0] }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $engine.inspectorTab) {
                    Text("コンポジション").tag(Engine.InspectorTab.composition)
                    Text("レイヤー \(layer.name)").tag(Engine.InspectorTab.layer)
                    Text(clip.map { "クリップ：\($0.name)" } ?? "クリップ").tag(Engine.InspectorTab.clip)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .frame(maxWidth: 560)
                Spacer(minLength: 0)
                // タブごとの操作
                switch engine.inspectorTab {
                case .composition:
                    HStack(spacing: 8) {
                        ResetButton { engine.compTransform.reset() }
                        MuteButton(muted: $engine.compMuted, what: "コンポジション（出力全体）")
                    }
                case .layer:
                    LayerActions(layer: layer)
                case .clip:
                    if let clip { ClipActions(slot: clip) }
                }
            }

            GeometryReader { geo in
            let w = previewWidth(available: geo.size.width)
            // プレビューの残りにパラメーター 2 列（左：設定、右：エフェクト）が入れば横に並べる。入らなければエフェクトは下に
            let twoCol = geo.size.width - w - Self.handleWidth >= SideBySide<EmptyView, EmptyView>.twoColumnWidth
            HStack(alignment: .top, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    MetalPreview(kind: previewKind)
                        .id(engine.inspectorTab)
                    // 自由な形のマスクの点の編集
                    switch engine.inspectorTab {
                    case .composition: PolyMaskOverlay(holder: engine)
                    case .layer: PolyMaskOverlay(holder: layer)
                    case .clip:
                        if let clip {
                            PolyMaskOverlay(holder: clip, transform: ClipTransform(
                                x: Float(clip.posX), y: Float(clip.posY), scale: Float(clip.scale),
                                rotation: Float(clip.rotation * .pi / 180)))
                        }
                    }
                    Text(previewCaption(clip: clip, clipIndex: clipIndex))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                }
                .frame(width: w, height: w / max(engine.outputAspect, 0.1))
                .overlay(Rectangle().stroke(Color.gray.opacity(0.35)))

                // プレビューの大きさを変えるつまみ（ドラッグ。ダブルクリックでおまかせに戻す）
                PreviewResizeHandle(height: w / max(engine.outputAspect, 0.1), isCustom: previewWidthSetting > 0)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            let start = dragStartWidth ?? w
                            dragStartWidth = start
                            previewWidthSetting = Double(min(max(start + v.translation.width, Self.minPreviewWidth),
                                                             maxPreviewWidth(available: geo.size.width)))
                        }
                        .onEnded { _ in dragStartWidth = nil })
                    .onTapGesture(count: 2) { previewWidthSetting = 0 }

                ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                switch engine.inspectorTab {
                case .composition:
                    CompositionParams()
                case .layer:
                    LayerParams(layer: layer)
                case .clip:
                    if let clip, let clipIndex {
                        ClipParams(slot: clip)
                            .id(clipIndex)
                    } else {
                        Text("サムネイル下の名前の帯をクリックしてクリップを選びます。\n出力せずに、プレビューを見ながら調整できます。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                }
                .frame(alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
                .frame(width: twoCol ? SideBySide<EmptyView, EmptyView>.twoColumnWidth : UI.paramsWidth, alignment: .topLeading)
                .environment(\.paramsTwoColumn, twoCol)
                Spacer(minLength: 0)
            }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panelBackground))
    }

    static let handleWidth: CGFloat = 16
    static let minPreviewWidth: CGFloat = 160

    /// プレビューの最大の幅：高さに収まる大きさで、パラメーター 1 列ぶんは残す
    private func maxPreviewWidth(available: CGFloat) -> CGFloat {
        max(min(previewHeight * engine.outputAspect, available - Self.handleWidth - UI.paramsWidth), Self.minPreviewWidth)
    }

    /// 今のプレビューの幅。おまかせなら、エフェクトが横に並ぶいちばん大きな幅（入らなければ最大）
    private func previewWidth(available: CGFloat) -> CGFloat {
        let maxW = maxPreviewWidth(available: available)
        if previewWidthSetting > 0 { return min(max(CGFloat(previewWidthSetting), Self.minPreviewWidth), maxW) }
        let fitTwo = available - Self.handleWidth - SideBySide<EmptyView, EmptyView>.twoColumnWidth
        return fitTwo >= Self.minPreviewWidth ? min(fitTwo, maxW) : maxW
    }

    private var previewKind: RenderLoop.TargetKind {
        switch engine.inspectorTab {
        case .composition: .composition
        case .layer: .layer
        case .clip: .clipPreview
        }
    }

    private func previewCaption(clip: ClipSlot?, clipIndex: Int?) -> String {
        switch engine.inspectorTab {
        case .composition:
            return "コンポジション"
        case .layer:
            return "レイヤー \(engine.layers[engine.selectedLayer].name)"
        case .clip:
            guard let clipIndex else { return "クリップ" }
            let live = engine.activeByLayer[engine.layerOf(clipIndex)] == clipIndex
            return live ? "出力中" : "プレビュー（出力しない・音なし）"
        }
    }
}

/// 見出し付きの縦並びパラメーター
struct ParamColumn<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            content
        }
        .frame(width: UI.paramColumnWidth, alignment: .topLeading)
    }
}

struct ResetButton: View {
    var label = "リセット"
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "arrow.counterclockwise")
        }
        .controlSize(.regular)
        .disabled(disabled)
    }
}

/// 位置・スケール・角度（レイヤー・コンポジション用）
/// 位置・スケール・角度を持つもの（クリップ・レイヤー・コンポジション）
protocol TransformEditable: ObservableObject, Animatable {
    var posX: Double { get set }
    var posY: Double { get set }
    var scale: Double { get set }
    var rotation: Double { get set }
}
extension TransformParams: TransformEditable {}
extension ClipSlot: TransformEditable {}

/// 位置・スケール・角度（それぞれアニメーションを付けられる）
struct TransformFields<T: TransformEditable>: View {
    @ObservedObject var t: T

    var body: some View {
        AnimField(label: "位置 X", value: $t.posX, range: -2...2, perPoint: 0.002, defaultValue: 0,
                  format: { String(format: "%+.1f%%", $0 * 100) }, key: .posX, target: t)
        AnimField(label: "位置 Y", value: $t.posY, range: -2...2, perPoint: 0.002, defaultValue: 0,
                  format: { String(format: "%+.1f%%", $0 * 100) }, key: .posY, target: t)
        AnimField(label: "スケール", value: $t.scale, range: 0...5, perPoint: 0.003, defaultValue: 1,
                  format: { String(format: "%.1f%%", $0 * 100) }, key: .scale, target: t)
        AnimField(label: "角度", value: $t.rotation, range: -720...720, perPoint: 0.25, defaultValue: 0,
                  format: { String(format: "%.1f°", $0) }, key: .rotation, target: t)
    }
}

private func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

struct CompositionParams: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        SideBySide {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 16) {
            ParamColumn(title: "トランスフォーム") {
                TransformFields(t: engine.compTransform)
            }
            ParamColumn(title: "マスター") {
                AnimField(label: "不透明度", value: $engine.masterOpacity, range: 0...1, perPoint: 0.003,
                          defaultValue: 1, showsBar: true, format: percent, key: .opacity, target: engine)
                Group {
                    HStack(spacing: 4) {
                        ValueDrag(label: "音量", value: $engine.masterVolume, range: 0...1, perPoint: 0.003,
                                  defaultValue: 1, showsBar: true, format: percent)
                            .opacity(engine.masterAudioMuted ? 0.45 : 1)
                        SoundMuteButton(muted: $engine.masterAudioMuted, what: "マスター")
                    }
                    ValueDrag(label: "速度", value: $engine.masterSpeed, range: ClipSlot.speedRange, perPoint: 0.001,
                              defaultValue: 1, format: { String(format: "%.3fx", $0) })
                }
                .frame(height: UI.rowHeight)
            }
        }
        }
        .frame(width: UI.paramsWidth, alignment: .topLeading)
        } second: {
            EffectsSection(holder: engine)
        }
    }
}

struct LayerActions: View {
    @ObservedObject var layer: Layer
    @EnvironmentObject var engine: Engine
    var body: some View {
        HStack(spacing: 8) {
            ResetButton(disabled: layer.transform.isDefault) { layer.transform.reset() }
            MuteButton(muted: $layer.muted, what: "このレイヤー")
            Button {
                engine.stopLayer(layer.index)
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .controlSize(.regular)
            .disabled(engine.activeByLayer[layer.index] == nil)
        }
    }
}

struct LayerParams: View {
    @ObservedObject var layer: Layer

    var body: some View {
        SideBySide {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 16) {
            ParamColumn(title: "トランスフォーム") {
                TransformFields(t: layer.transform)
            }
            ParamColumn(title: "ミックス") {
                Toggle(isOn: $layer.isAdjustment) {
                    Label("調整レイヤー", systemImage: "camera.filters")
                }
                .toggleStyle(.switch)
                .frame(height: UI.rowHeight)
                .help("オン：このレイヤーのクリップは使わず、付けたエフェクトを下のレイヤー全体にかける。不透明度がかかり具合")
                BlendChoice(blend: $layer.blend)
                AnimField(label: "不透明度", value: $layer.opacity, range: 0...1, perPoint: 0.003,
                          defaultValue: 1, showsBar: true, format: percent, key: .opacity, target: layer)
                Group {
                    HStack(spacing: 4) {
                        ValueDrag(label: "音量", value: $layer.volume, range: 0...1, perPoint: 0.003,
                                  defaultValue: 1, showsBar: true, format: percent)
                            .opacity(layer.audioMuted ? 0.45 : 1)
                        SoundMuteButton(muted: $layer.audioMuted, what: "このレイヤー")
                    }
                    ValueDrag(label: "切り替えフェード", value: $layer.fadeTime, range: 0...10, perPoint: 0.01,
                              defaultValue: 0, format: fadeSeconds)
                        .help("このレイヤーでクリップを切り替えるときのクロスフェード時間（映像・音とも）。0 でカット")
                }
                .frame(height: UI.rowHeight)
            }
        }
        if layer.blend.isSpecial {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("重ね方：" + layer.blend.label)
                EffectCard(effect: $layer.blendFX, isFirst: true, isLast: true, move: { _ in }, remove: {
                    layer.blend = .add
                }, isBlendSettings: true)
            }
            .frame(width: UI.paramsWidth, alignment: .leading)
            .padding(.top, 14)
        }
        }
        .frame(width: UI.paramsWidth, alignment: .topLeading)
        } second: {
            EffectsSection(holder: layer)
        }
    }
}

/// フェード時間の表示（0 は「カット」）
func fadeSeconds(_ v: Double) -> String {
    v < 0.005 ? "カット" : String(format: "%.2f 秒", v)
}

struct ClipActions: View {
    @ObservedObject var slot: ClipSlot
    var body: some View {
        HStack(spacing: 10) {
            ResetButton(disabled: !slot.hasCustomTransform) { slot.resetTransform() }
                .help("位置・スケール・角度・不透明度・音量を初期値に戻す（速度はそのまま）")
            MuteButton(muted: $slot.muted, what: "このクリップ")
        }
    }
}

struct ClipParams: View {
    @ObservedObject var slot: ClipSlot

    var body: some View {
        SideBySide {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 16) {
            ParamColumn(title: "トランスフォーム") {
                TransformFields(t: slot)
            }
            ParamColumn(title: "ミックス・再生") {
                AnimField(label: "不透明度", value: $slot.opacity, range: 0...1, perPoint: 0.003, defaultValue: 1,
                          showsBar: true, format: percent, key: .opacity, target: slot)
                if !slot.isGenerator {
                    HStack(spacing: 4) {
                        ValueDrag(label: "音量", value: $slot.clipVolume, range: 0...1, perPoint: 0.003,
                                  defaultValue: 1, showsBar: true, format: percent)
                            .opacity(slot.audioMuted ? 0.45 : 1)
                        SoundMuteButton(muted: $slot.audioMuted, what: "このクリップ")
                    }
                    .frame(height: UI.rowHeight)
                }
                if !slot.isGenerator { ClipSpeedFields(slot: slot) }
            }
        }
        if slot.generator != nil {
            // ジェネレーター：再生範囲・速度の代わりに、絵の設定
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("ジェネレーター：" + (slot.generator?.kind.label ?? ""))
                EffectCard(effect: Binding(get: { slot.generator ?? Effect(kind: .solid) }, set: { slot.generator = $0 }),
                           origin: slot.animOrigin, isFirst: true, isLast: true, move: { _ in }, remove: {},
                           isBlendSettings: true)
            }
            .frame(width: UI.paramsWidth, alignment: .leading)
            .padding(.top, 10)
        } else {
            PlayRangeSection(slot: slot)
                .padding(.top, 10)
        }
        }
        .frame(width: UI.paramsWidth, alignment: .topLeading)
        } second: {
            EffectsSection(holder: slot)
        }
    }
}

/// クリップの速度：手動（数値）か、BPM 同期（再生範囲を何拍で 1 周するか）
struct ClipSpeedFields: View {
    @ObservedObject var slot: ClipSlot
    @EnvironmentObject var engine: Engine

    var body: some View {
        Picker("", selection: $slot.syncMode) {
            ForEach(SyncMode.allCases) { Text("速度：" + $0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .help("BPM 同期：再生範囲（イン点〜アウト点）を決めた拍数でちょうど 1 周する速さで再生。BPM を変えると付いていく（クリップ速度・コンポジション速度は効かない）")
        if slot.syncMode == .free {
            ValueDrag(label: "クリップ速度", value: $slot.speed, range: ClipSlot.speedRange, perPoint: 0.001,
                      defaultValue: 1, format: { String(format: "%.3fx", $0) })
                .frame(height: UI.rowHeight)
        } else {
            HStack(spacing: 6) {
                ChoiceButtons(selection: $slot.syncBeats, items: ClipSlot.syncBeatChoices.map { ($0, beatShort($0)) },
                              fontSize: 11)
                    .help("再生範囲を何拍で 1 周するか")
                Text("拍で1周").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                let raw = slot.bpmRate
                let clipped = !ClipSlot.syncRateRange.contains(raw)
                Text(String(format: "= %.3fx", slot.effectiveSpeed) + (clipped ? "（上限）" : ""))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(clipped ? Color.red : Color.purple)
                    .fixedSize()
                    .help(clipped ? "この拍数だと速すぎる（遅すぎる）ので、端の速さで止めています" : "今の BPM での再生速度")
            }
            .frame(height: UI.rowHeight)
        }
    }
}

/// 再生範囲（イン点・アウト点）と、終わったときの動き
struct PlayRangeSection: View {
    @ObservedObject var slot: ClipSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("再生範囲")
                Spacer()
                if slot.hasInOut {
                    Button("範囲をリセット") { slot.resetInOut() }
                        .controlSize(.regular)
                }
            }
            InOutBar(slot: slot)
                .frame(height: 40)
            HStack(spacing: 12) {
                timeLabel("イン", slot.inPoint, changed: slot.inPoint > 0)
                timeLabel("アウト", slot.outTime, changed: slot.outPoint != nil)
                Spacer()
                Text(String(format: "長さ %.2f 秒", max(slot.outTime - slot.inPoint, 0)))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12).monospacedDigit())
            HStack(spacing: 8) {
                Text("終わったら").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $slot.endAction) {
                    ForEach(EndAction.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
            }
            .help("アウト点まで来たとき：ループ＝イン点から繰り返す／最後で停止＝最後のコマで止める／ブラックアウト＝このレイヤーを消す")
            HStack(spacing: 8) {
                Text("ジャンプ").font(.system(size: 12)).foregroundStyle(.secondary)
                ChoiceButtons(selection: $slot.jumpBeats,
                              items: ClipSlot.jumpChoices.map { ($0, $0 == 0 ? "しない" : beatShort($0)) })
                Text("拍ごと").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
            }
            .help("BPM の拍の頭で、再生範囲の中のランダムな位置へ飛ぶ（音も一緒に飛ぶ）。テンポは右下の BPM / TAP で")
        }
        .frame(width: UI.paramsWidth, alignment: .leading)
    }

    private func timeLabel(_ title: String, _ t: Double, changed: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(clipTime(t)).foregroundStyle(changed ? Color.orange : Color.primary)
        }
    }
}

/// 時間の表示（分:秒.百分の一）
func clipTime(_ s: Double) -> String {
    guard s.isFinite else { return "--:--" }
    let cs = Int((s * 100).rounded())
    return String(format: "%d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
}

/// クリップ全体の中でイン点・アウト点をドラッグで決めるバー。
/// 両端のつまみを動かす。ダブルクリックでそのつまみを初期値に戻す。再生中なら再生位置も出す。
struct InOutBar: View {
    @ObservedObject var slot: ClipSlot
    /// ドラッグを始めたときのつまみの位置
    @State private var inOrigin: CGFloat?
    @State private var outOrigin: CGFloat?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let d = max(slot.duration, 0.001)
            let xi = CGFloat(slot.inPoint / d) * w
            let xo = CGFloat(slot.outTime / d) * w
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06))
                // 使う範囲
                Rectangle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(xo - xi, 1))
                    .offset(x: xi)
                // 再生位置
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !slot.isPlaying)) { _ in
                    let p = slot.position(at: CACurrentMediaTime())
                    Rectangle().fill(Color.white)
                        .frame(width: 2)
                        .offset(x: CGFloat(p / d) * w - 1)
                        .opacity(slot.isPlaying || slot.isScrubbing ? 1 : 0)
                }
                .allowsHitTesting(false)
                handle(x: xi, isIn: true, width: w, duration: d)
                handle(x: xo, isIn: false, width: w, duration: d)
            }
        }
        .transaction { $0.animation = nil }
    }

    private func handle(x: CGFloat, isIn: Bool, width w: CGFloat, duration d: Double) -> some View {
        let changed = isIn ? slot.inPoint > 0 : slot.outPoint != nil
        // 見た目は細い [ ] だが、つかめる幅は広めにとる
        let grab: CGFloat = 24
        let c = grab / 2
        return GeometryReader { g in
            let h = g.size.height
            ZStack {
                Rectangle().fill(changed ? Color.orange : Color.white.opacity(0.8)).frame(width: 3)
                Path { p in
                    let s: CGFloat = isIn ? 1 : -1
                    p.move(to: CGPoint(x: c + s * 7, y: 1)); p.addLine(to: CGPoint(x: c, y: 1))
                    p.addLine(to: CGPoint(x: c, y: h - 1)); p.addLine(to: CGPoint(x: c + s * 7, y: h - 1))
                }
                .stroke(changed ? Color.orange : Color.white.opacity(0.8), lineWidth: 3)
            }
        }
        .frame(width: grab)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        .offset(x: x - c)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    let origin: CGFloat
                    if isIn { origin = inOrigin ?? x; inOrigin = origin } else { origin = outOrigin ?? x; outOrigin = origin }
                    let t = Double(min(max(origin + v.translation.width, 0), w) / w) * d
                    if isIn { slot.setInOut(in: t) } else { slot.setInOut(out: .some(t)) }
                }
                .onEnded { _ in inOrigin = nil; outOrigin = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if isIn { slot.setInOut(in: 0) } else { slot.setInOut(out: .some(nil)) }
        })
        .help(isIn ? "イン点（ドラッグで移動、ダブルクリックで先頭に戻す）" : "アウト点（ドラッグで移動、ダブルクリックで最後に戻す）")
    }
}


/// ミュートの切り替え（再生は続けたまま、映像と音を出さない）。ミュート中は赤
struct MuteButton: View {
    @Binding var muted: Bool
    let what: String
    var compact = false

    var body: some View {
        Group {
            if muted {
                button.buttonStyle(.borderedProminent).tint(.red)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.regular)
        .help(muted ? "\(what)のミュートを解除" : "\(what)をミュート（再生は続けたまま、映像と音を出さない）")
    }

    private var button: some View {
        Button {
            muted.toggle()
        } label: {
            if compact {
                Image(systemName: muted ? "eye.slash.fill" : "eye")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 16)
            } else {
                Label(muted ? "ミュート中" : "ミュート", systemImage: muted ? "eye.slash.fill" : "eye")
            }
        }
    }
}


/// 音だけのミュート（映像は出る）。音量の欄の横に置く
/// 出力の上の「音をミュート」（マスターの音だけ消す。映像はブラックアウトやコンポジションのミュートで）
struct AudioMuteButton: View {
    @Binding var muted: Bool

    var body: some View {
        Group {
            if muted {
                button.buttonStyle(.borderedProminent).tint(.red)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.regular)
        .help(muted ? "音のミュートを解除" : "出力の音だけを消す（映像はそのまま）")
    }

    private var button: some View {
        Button {
            muted.toggle()
        } label: {
            Label(muted ? "音ミュート中" : "音ミュート", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
    }
}

struct SoundMuteButton: View {
    @Binding var muted: Bool
    let what: String

    var body: some View {
        Button {
            muted.toggle()
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(muted ? Color.white : Color.secondary)
                .frame(width: 30, height: UI.rowHeight)
                .background(RoundedRectangle(cornerRadius: 5).fill(muted ? Color.red : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(muted ? "\(what)の音のミュートを解除" : "\(what)の音だけを消す（映像はそのまま）")
    }
}

/// パラメーター（左）とエフェクト欄（右）。パネルに幅があれば横に並べ、無ければ縦に積む
struct SideBySide<A: View, B: View>: View {
    static var gap: CGFloat { 20 }
    /// 2 列にしたときの幅（右端のスクロールバーの分も）
    static var twoColumnWidth: CGFloat { UI.paramsWidth * 2 + gap + 12 }
    @Environment(\.paramsTwoColumn) private var twoCol
    @ViewBuilder var first: A
    @ViewBuilder var second: B

    var body: some View {
        if twoCol {
            HStack(alignment: .top, spacing: Self.gap) {
                first
                second.frame(width: UI.paramsWidth, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                first
                second
            }
        }
    }
}

private struct ParamsTwoColumnKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// パラメーター欄を 2 列（右にエフェクト）にするか
    var paramsTwoColumn: Bool {
        get { self[ParamsTwoColumnKey.self] }
        set { self[ParamsTwoColumnKey.self] = newValue }
    }
}

/// プレビューの右の、大きさを変えるつまみ（縦の細い線）
struct PreviewResizeHandle: View {
    let height: CGFloat
    let isCustom: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(hovering ? Color.accentColor : Color.gray.opacity(isCustom ? 0.6 : 0.35))
                .frame(width: hovering ? 4 : 3, height: min(max(height * 0.35, 28), 80))
        }
        .frame(width: ParameterPanel.handleWidth, height: height)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .help("ドラッグでプレビューの大きさを変える。ダブルクリックでおまかせ（エフェクトが横に並ぶ大きさ）に戻す")
    }
}
