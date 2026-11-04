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

    private var dragging = false

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
        if event.clickCount == 2 { set(defaultValue); return }
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let k = event.modifierFlags.contains(.shift) ? 0.1 : 1.0
        set(value + Double(event.deltaX) * perPoint * k)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
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

        let changed = abs(value - defaultValue) > 1e-9
        if showsBar {
            let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            NSGraphicsContext.saveGraphicsState()
            bg.addClip()
            (changed ? NSColor.systemOrange : NSColor.systemBlue).withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: NSRect(x: r.minX, y: r.minY, width: r.width * CGFloat(f), height: r.height)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor(white: 0.65, alpha: 1),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: changed ? NSColor.systemOrange : NSColor.white,
        ]
        let ls = (label as NSString).size(withAttributes: labelAttrs)
        (label as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.midY - ls.height / 2), withAttributes: labelAttrs)
        let text = format(value)
        let vs = (text as NSString).size(withAttributes: valueAttrs)
        (text as NSString).draw(at: NSPoint(x: r.maxX - 6 - vs.width, y: r.midY - vs.height / 2), withAttributes: valueAttrs)
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
                .frame(maxWidth: 520)
                Spacer(minLength: 0)
                // タブごとの操作
                switch engine.inspectorTab {
                case .composition:
                    ResetButton { engine.compTransform.reset() }
                case .layer:
                    LayerActions(layer: layer)
                case .clip:
                    if let clip { ClipActions(slot: clip) }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .topLeading) {
                    MetalPreview(kind: previewKind)
                        .id(engine.inspectorTab)
                    Text(previewCaption(clip: clip, clipIndex: clipIndex))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                }
                .aspectRatio(engine.outputAspect, contentMode: .fit)
                .overlay(Rectangle().stroke(Color.gray.opacity(0.35)))
                // パラメーター欄の幅を確保した残りに収める
                .frame(maxWidth: .infinity, maxHeight: previewHeight, alignment: .topLeading)

                Group {

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
                .frame(width: 476, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panelBackground))
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
            let live = engine.activeByLayer[Engine.layerOf(clipIndex)] == clipIndex
            return live ? "出力中" : "プレビュー（出力しない・音なし）"
        }
    }
}

/// 見出し付きの縦並びパラメーター
struct ParamColumn<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title)
            content
        }
        .frame(width: 230, alignment: .topLeading)
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
        .controlSize(.small)
        .disabled(disabled)
    }
}

/// 位置・スケール・角度（レイヤー・コンポジション用）
struct TransformFields: View {
    @ObservedObject var t: TransformParams

    var body: some View {
        Group {
            ValueDrag(label: "位置 X", value: $t.posX, range: -2...2, perPoint: 0.002, defaultValue: 0,
                      format: { String(format: "%+.1f%%", $0 * 100) })
            ValueDrag(label: "位置 Y", value: $t.posY, range: -2...2, perPoint: 0.002, defaultValue: 0,
                      format: { String(format: "%+.1f%%", $0 * 100) })
            ValueDrag(label: "スケール", value: $t.scale, range: 0...5, perPoint: 0.003, defaultValue: 1,
                      format: { String(format: "%.1f%%", $0 * 100) })
            ValueDrag(label: "角度", value: $t.rotation, range: -360...360, perPoint: 0.25, defaultValue: 0,
                      format: { String(format: "%.1f°", $0) })
        }
        .frame(height: 26)
    }
}

private func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

struct CompositionParams: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ParamColumn(title: "トランスフォーム") {
                TransformFields(t: engine.compTransform)
            }
            ParamColumn(title: "マスター") {
                Group {
                    ValueDrag(label: "不透明度", value: $engine.masterOpacity, range: 0...1, perPoint: 0.003,
                              defaultValue: 1, showsBar: true, format: percent)
                    ValueDrag(label: "音量", value: $engine.masterVolume, range: 0...1, perPoint: 0.003,
                              defaultValue: 1, showsBar: true, format: percent)
                    ValueDrag(label: "速度", value: $engine.masterSpeed, range: ClipSlot.speedRange, perPoint: 0.001,
                              defaultValue: 1, format: { String(format: "%.3fx", $0) })
                }
                .frame(height: 26)
            }
        }
    }
}

struct LayerActions: View {
    @ObservedObject var layer: Layer
    @EnvironmentObject var engine: Engine
    var body: some View {
        HStack(spacing: 8) {
            ResetButton(disabled: layer.transform.isDefault) { layer.transform.reset() }
            Button {
                engine.stopLayer(layer.index)
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .controlSize(.small)
            .disabled(engine.activeByLayer[layer.index] == nil)
        }
    }
}

struct LayerParams: View {
    @ObservedObject var layer: Layer

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ParamColumn(title: "トランスフォーム") {
                TransformFields(t: layer.transform)
            }
            ParamColumn(title: "ミックス") {
                Picker("", selection: $layer.blend) {
                    ForEach(BlendMode.allCases) { Text("重ね方：" + $0.label).tag($0) }
                }
                .labelsHidden()
                .frame(height: 26)
                Group {
                    ValueDrag(label: "不透明度", value: $layer.opacity, range: 0...1, perPoint: 0.003,
                              defaultValue: 1, showsBar: true, format: percent)
                    ValueDrag(label: "音量", value: $layer.volume, range: 0...1, perPoint: 0.003,
                              defaultValue: 1, showsBar: true, format: percent)
                }
                .frame(height: 26)
            }
        }
    }
}

struct ClipActions: View {
    @ObservedObject var slot: ClipSlot
    var body: some View {
        HStack(spacing: 10) {
            Toggle("ループ", isOn: $slot.loop).controlSize(.small)
            ResetButton(disabled: !slot.hasCustomTransform) { slot.resetTransform() }
                .help("位置・スケール・角度・不透明度・音量を初期値に戻す（速度はそのまま）")
        }
    }
}

struct ClipParams: View {
    @ObservedObject var slot: ClipSlot

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ParamColumn(title: "トランスフォーム") {
                Group {
                    ValueDrag(label: "位置 X", value: $slot.posX, range: -2...2, perPoint: 0.002, defaultValue: 0,
                              format: { String(format: "%+.1f%%", $0 * 100) })
                    ValueDrag(label: "位置 Y", value: $slot.posY, range: -2...2, perPoint: 0.002, defaultValue: 0,
                              format: { String(format: "%+.1f%%", $0 * 100) })
                    ValueDrag(label: "スケール", value: $slot.scale, range: 0...5, perPoint: 0.003, defaultValue: 1,
                              format: { String(format: "%.1f%%", $0 * 100) })
                    ValueDrag(label: "角度", value: $slot.rotation, range: -360...360, perPoint: 0.25, defaultValue: 0,
                              format: { String(format: "%.1f°", $0) })
                }
                .frame(height: 26)
            }
            ParamColumn(title: "ミックス・再生") {
                Group {
                    ValueDrag(label: "不透明度", value: $slot.opacity, range: 0...1, perPoint: 0.003, defaultValue: 1,
                              showsBar: true, format: percent)
                    ValueDrag(label: "音量", value: $slot.clipVolume, range: 0...1, perPoint: 0.003, defaultValue: 1,
                              showsBar: true, format: percent)
                    ValueDrag(label: "クリップ速度", value: $slot.speed, range: ClipSlot.speedRange, perPoint: 0.001,
                              defaultValue: 1, format: { String(format: "%.3fx", $0) })
                }
                .frame(height: 26)
            }
        }
    }
}
