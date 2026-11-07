import AppKit
import SwiftUI

/// 数値をドラッグで変えるフィールド（Resolume のパラメータ欄のようなもの）
/// - 左右ドラッグで相対的に変化、Shift で微調整
/// - ダブルクリック / 右クリックで初期値に戻す
final class ValueDragNSView: NSView {
    var label = ""
    /// 文字の代わりに出す記号（SF Symbols の名前）。狭い所（レイヤー欄）用
    var icon: String?
    var value: Double = 0 { didSet { if oldValue != value { needsDisplay = true } } }
    var range: ClosedRange<Double> = 0...1
    var perPoint = 0.005
    var defaultValue = 0.0
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    /// 範囲に対する割合をバーで表示する（不透明度・音量など）
    var showsBar = false
    /// 値の見せ方（バーの代わりの小さな絵）
    var style = ValueStyle.plain
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

    /// マイナスの値の色（プラスは橙）
    static let minusColor = NSColor(calibratedRed: 0.30, green: 0.78, blue: 1.0, alpha: 1)

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
        // プラスにもマイナスにもなる値（位置・角度・速さなど）は、プラスを橙、マイナスを水色にして見分ける
        let signed = range.lowerBound < 0 && range.upperBound > 0
        let changedColor = signed && shown < 0 ? Self.minusColor : NSColor.systemOrange
        if showsBar || animating {
            // 範囲のどこにいるかをバーで。プラス・マイナスのある値は 0 の所から今の値まで
            let span = range.upperBound - range.lowerBound
            let f = CGFloat(min(max((shown - range.lowerBound) / span, 0), 1))
            let z = signed ? CGFloat((0 - range.lowerBound) / span) : 0
            NSGraphicsContext.saveGraphicsState()
            bg.addClip()
            (animating ? NSColor.systemPurple : changed ? changedColor : NSColor.systemBlue)
                .withAlphaComponent(animating ? 0.45 : 0.35).setFill()
            NSBezierPath(rect: NSRect(x: r.minX + r.width * min(z, f), y: r.minY, width: r.width * abs(f - z), height: r.height)).fill()
            if signed {
                NSColor(white: 1, alpha: 0.35).setFill()
                NSBezierPath(rect: NSRect(x: r.minX + r.width * z - 0.5, y: r.minY, width: 1, height: r.height)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        } else if signed && abs(shown) > 1e-9 && !style.hasGlyph {
            // 0 の所から今の値まで、下に細い線（どちら向きにどれだけか）
            let span = range.upperBound - range.lowerBound
            let x0 = r.minX + r.width * CGFloat((0 - range.lowerBound) / span)
            let x1 = r.minX + r.width * CGFloat(min(max((shown - range.lowerBound) / span, 0), 1))
            NSGraphicsContext.saveGraphicsState()
            bg.addClip()
            (shown < 0 ? Self.minusColor : NSColor.systemOrange).withAlphaComponent(changed ? 0.9 : 0.4).setFill()
            NSBezierPath(rect: NSRect(x: min(x0, x1), y: r.maxY - 3, width: max(abs(x1 - x0), 1.5), height: 3)).fill()
            NSColor(white: 1, alpha: 0.35).setFill()
            NSBezierPath(rect: NSRect(x: x0 - 0.5, y: r.maxY - 5, width: 1, height: 5)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(white: 0.65, alpha: 1),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: icon != nil && r.height < 24 ? 11 : 13, weight: .semibold),
            .foregroundColor: animating ? NSColor.white : changed ? changedColor : NSColor.white,
        ]
        var ls = (label as NSString).size(withAttributes: labelAttrs)
        let small = r.height < 24
        if let icon, let img = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: small ? 9 : 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(hierarchicalColor: NSColor(white: 0.7, alpha: 1)))) {
            // 記号だけ（文字は出さない）
            let s = img.size
            img.draw(in: NSRect(x: r.minX + (small ? 6 : 8), y: r.midY - s.height / 2, width: s.width, height: s.height))
            ls = NSSize(width: s.width, height: s.height)
        } else {
            (label as NSString).draw(at: NSPoint(x: r.minX + 8, y: r.midY - ls.height / 2), withAttributes: labelAttrs)
        }
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
        let vx = r.maxX - (icon != nil && r.height < 24 ? 6 : 8) - vs.width
        (text as NSString).draw(at: NSPoint(x: vx, y: r.midY - vs.height / 2), withAttributes: valueAttrs)
        // 値の左に小さな絵（位置・大きさ・角度）。名前とぶつかるほど狭ければ出さない
        if style.hasGlyph {
            let gw: CGFloat = 34, gh = min(r.height - 8, 20)
            // 数字の幅で絵が動かないように、いちばん長くなる数字（範囲の両端）の分を空けて置く
            let widest = [range.lowerBound, range.upperBound, -range.upperBound]
                .map { (format($0) as NSString).size(withAttributes: valueAttrs).width }.max() ?? vs.width
            let gx = r.maxX - (icon != nil && r.height < 24 ? 6 : 8) - max(widest, vs.width) - 10 - gw
            if gx > r.minX + 8 + ls.width + 6 {
                let accent = animating ? NSColor.systemPurple.blended(withFraction: 0.3, of: .white) ?? .systemPurple
                    : changed ? changedColor : NSColor(white: 0.85, alpha: 1)
                drawGlyph(NSRect(x: gx, y: r.midY - gh / 2, width: gw, height: gh), value: shown, accent: accent)
            }
        }
    }

    /// 位置：画面の枠と、クリップの中心の点（動かす向きに線）。大きさ：画面の枠とクリップの大きさの四角。角度：文字盤
    private func drawGlyph(_ g: NSRect, value v: Double, accent: NSColor) {
        let frameColor = NSColor(white: 1, alpha: 0.32)
        // 画面の枠（16:9 くらい、絵の真ん中）
        func screenRect(_ k: CGFloat) -> NSRect {
            let h = min(g.height, g.width * 9 / 16) * k, w = h * 16 / 9
            return NSRect(x: g.midX - w / 2, y: g.midY - h / 2, width: w, height: h)
        }
        switch style {
        case .position(let horizontal):
            // 画面は絵の中の 2/3。はみ出した分は外の余白に（それより外は縁で止めて、白抜き）
            let sr = screenRect(0.72)
            frameColor.setStroke()
            let fr = NSBezierPath(roundedRect: sr, xRadius: 1.5, yRadius: 1.5); fr.lineWidth = 1; fr.stroke()
            let half = horizontal ? sr.width : sr.height
            let limit = horizontal ? (g.width / 2 - 2) : (g.height / 2 - 2)
            let raw = CGFloat(v) * half
            let off = min(max(raw, -limit), limit)
            let outside = abs(raw) > limit
            // 動かす向きのガイド線
            NSColor(white: 1, alpha: 0.18).setFill()
            if horizontal {
                NSBezierPath(rect: NSRect(x: g.minX, y: sr.midY - 0.5, width: g.width, height: 1)).fill()
            } else {
                NSBezierPath(rect: NSRect(x: sr.midX - 0.5, y: g.minY, width: 1, height: g.height)).fill()
            }
            // 上がプラス（画面の座標は下向きなので反対に）
            let c = horizontal ? NSPoint(x: sr.midX + off, y: sr.midY) : NSPoint(x: sr.midX, y: sr.midY - off)
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7))
            if outside { accent.setStroke(); dot.lineWidth = 1.5; dot.stroke() } else { accent.setFill(); dot.fill() }
        case .scale:
            // 大きい方が絵に収まるように：100% より大きいと、画面の枠の方が小さく見える
            let s = CGFloat(max(v, 0))
            let box = max(1, s)
            let full = screenRect(1)
            func centered(_ k: CGFloat) -> NSRect {
                let w = full.width * k, h = full.height * k
                return NSRect(x: g.midX - w / 2, y: g.midY - h / 2, width: w, height: h)
            }
            let sr = centered(1 / box)
            frameColor.setStroke()
            let fr = NSBezierPath(roundedRect: sr, xRadius: 1.5, yRadius: 1.5); fr.lineWidth = 1; fr.stroke()
            let cr = centered(max(s / box, 0.04))
            accent.withAlphaComponent(0.28).setFill()
            NSBezierPath(rect: cr).fill()
            accent.setStroke()
            let cp = NSBezierPath(rect: cr.insetBy(dx: 0.5, dy: 0.5)); cp.lineWidth = 1; cp.stroke()
        case .angle:
            // 文字盤：上が 0°、時計回りがプラス。1 周を超えた分は外の輪を濃く
            let rad = min(g.height, g.width) / 2 - 1
            let c = NSPoint(x: g.midX, y: g.midY)
            func point(_ deg: Double, _ rr: CGFloat) -> NSPoint {
                let a = deg * .pi / 180
                return NSPoint(x: c.x + CGFloat(sin(a)) * rr, y: c.y - CGFloat(cos(a)) * rr)
            }
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
            frameColor.setStroke(); ring.lineWidth = 1; ring.stroke()
            let turns = Int(abs(v) / 360)
            if turns > 0 { accent.withAlphaComponent(0.45).setStroke(); ring.lineWidth = 2; ring.stroke() }
            // 0° から今の角度までの扇
            let rest = v.truncatingRemainder(dividingBy: 360)
            if abs(rest) > 0.5 {
                let fan = NSBezierPath(); fan.move(to: c)
                let n = max(Int(abs(rest) / 6), 2)
                for i in 0...n { fan.line(to: point(rest * Double(i) / Double(n), rad - 1)) }
                fan.close()
                accent.withAlphaComponent(0.25).setFill(); fan.fill()
            }
            // 針
            let needle = NSBezierPath(); needle.move(to: c); needle.line(to: point(v, rad - 1))
            needle.lineWidth = 2; needle.lineCapStyle = .round
            accent.setStroke(); needle.stroke()
            NSColor(white: 1, alpha: 0.5).setFill()
            NSBezierPath(rect: NSRect(x: c.x - 0.5, y: c.y - rad, width: 1, height: 2.5)).fill()
        default:
            break
        }
    }
}

/// 数値欄の見せ方（バーが合わない値は、値の左に小さな絵を出す）
enum ValueStyle: Equatable {
    case plain
    /// 位置（画面の枠とクリップの中心）。horizontal = 横（X）
    case position(horizontal: Bool)
    /// 大きさ（画面の枠とクリップの四角）
    case scale
    /// 角度（文字盤）
    case angle

    var hasGlyph: Bool { self != .plain }
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
    var icon: String? = nil
    var style = ValueStyle.plain

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
        v.icon = icon
        v.range = range
        v.perPoint = perPoint
        v.defaultValue = defaultValue
        v.showsBar = showsBar
        v.style = style
        v.format = format
        v.badge = badge
        v.live = live
        v.toolTip = (icon != nil ? label + "\n" : "")
            + (live != nil ? "アニメーション中（右のボタンで設定）" : "左右ドラッグで調整 / Shift で微調整 / ダブルクリック・右クリックで初期値")
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
    /// 枠（余白と背景）を付けるか。自由レイアウトの区画の中では付けない
    var framed = true
    /// 出すもの（いつもは全部。自由レイアウトではプレビューだけ・設定だけにもできる）
    var part = Part.all
    /// プレビューの幅（右端の縦の線をドラッグで変える。0 = おまかせ：エフェクトが横に並ぶ大きさ）
    @AppStorage("inspectorPreviewWidth") private var previewWidthSetting = 0.0
    /// ドラッグを始めたときの幅
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            GeometryReader { geo in
                switch part {
                case .all:
                    allParts(geo.size)
                case .preview:
                    // プレビューだけ：区画いっぱいに（縦横比はそのまま）
                    let a = max(engine.outputAspect, 0.1)
                    let w = min(geo.size.width, geo.size.height * a)
                    preview
                        .frame(width: w, height: w / a)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                case .settings:
                    // 設定だけ：区画の幅いっぱいに（2 列が入れば横に並べる。1 列も入らなければ横にもスクロール）
                    settings(twoCol: geo.size.width >= SideBySide<EmptyView, EmptyView>.twoColumnWidth)
                        .environment(\.paramsWidth, min(max(geo.size.width - 14, 160), UI.paramsWidth))
                        .frame(width: geo.size.width, alignment: .topLeading)
                }
            }
        }
        .padding(framed ? 12 : 0)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(framed ? UI.panelBackground : Color.clear))
    }

    /// 自由レイアウトで、プレビューと設定を別々の区画に置くとき
    enum Part { case all, preview, settings }

    // シーンの編集中は、そのシーンのレイヤー・コンポジション
    private var layer: Layer { engine.viewLayer(engine.selectedLayer) }
    private var clipIndex: Int? { engine.inspectedIndex.flatMap { engine.slots[$0] != nil ? $0 : nil } }
    private var clip: ClipSlot? { clipIndex.flatMap { engine.slots[$0] } }

    /// 上の段：コンポジション・レイヤー・クリップの切り替えと、タブごとの操作
    @ViewBuilder private var header: some View {
        let layer = self.layer, clip = self.clip, draft = engine.sceneDraft
        // 幅が足りないときは短い名前に切り替える（見切れて読めなくならないように）
        ViewThatFits(in: .horizontal) {
            tabPicker(short: part == .preview, clip: clip).fixedSize()
            tabPicker(short: true, clip: clip).fixedSize()
            tabPicker(short: true, clip: clip).frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabPicker(short: Bool, clip: ClipSlot?) -> some View {
        let layerName = engine.layers[min(engine.selectedLayer, engine.layers.count - 1)].displayName
        return Picker("", selection: $engine.inspectorTab) {
            Text(short ? "コンポ" : "コンポジション").tag(Engine.InspectorTab.composition)
            Text(short ? layerName : "レイヤー \(layerName)").tag(Engine.InspectorTab.layer)
            Text(clip.map { short ? "クリップ" : "クリップ：\($0.name)" } ?? "クリップ").tag(Engine.InspectorTab.clip)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(part == .preview ? .regular : .large)
        .frame(maxWidth: 560)
    }

    /// プレビューと設定を横に並べる（いつもの形）
    @ViewBuilder private func allParts(_ size: CGSize) -> some View {
        let w = previewWidth(available: size.width)
        // プレビューの残りにパラメーター 2 列（左：設定、右：エフェクト）が入れば横に並べる。入らなければエフェクトは下に
        let twoCol = size.width - w - Self.handleWidth >= SideBySide<EmptyView, EmptyView>.twoColumnWidth
        HStack(alignment: .top, spacing: 0) {
            preview
                .frame(width: w, height: w / max(engine.outputAspect, 0.1))

            // プレビューの大きさを変えるつまみ（ドラッグ。ダブルクリックでおまかせに戻す）
            PreviewResizeHandle(height: w / max(engine.outputAspect, 0.1), isCustom: previewWidthSetting > 0)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let start = dragStartWidth ?? w
                        dragStartWidth = start
                        previewWidthSetting = Double(min(max(start + v.translation.width, Self.minPreviewWidth),
                                                         maxPreviewWidth(available: size.width)))
                    }
                    .onEnded { _ in dragStartWidth = nil })
                .onTapGesture(count: 2) { previewWidthSetting = 0 }

            settings(twoCol: twoCol)
                .frame(width: twoCol ? SideBySide<EmptyView, EmptyView>.twoColumnWidth : UI.paramsWidth, alignment: .topLeading)
            Spacer(minLength: 0)
        }
    }

    /// プレビュー（自由な形のマスクの点の編集と、説明付き）
    @ViewBuilder private var preview: some View {
        let layer = self.layer, clip = self.clip, draft = engine.sceneDraft
        ZStack(alignment: .topLeading) {
            MetalPreview(kind: previewKind)
                // 描き方（クリップ・出力など）が変わったら作り直す
                .id("\(engine.inspectorTab)-\(previewKind)")
            switch engine.inspectorTab {
            case .composition:
                if let draft { PolyMaskOverlay(holder: draft) } else { PolyMaskOverlay(holder: engine) }
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
        .overlay(Rectangle().stroke(Color.gray.opacity(0.35)))
    }

    /// 設定（タブごとの数値とエフェクト。縦にスクロール）
    @ViewBuilder private func settings(twoCol: Bool) -> some View {
        let layer = self.layer, clip = self.clip, clipIndex = self.clipIndex, draft = engine.sceneDraft
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                switch engine.inspectorTab {
                case .composition:
                    if let draft {
                        SceneCompParams(draft: draft).id(ObjectIdentifier(draft))
                    } else {
                        CompositionParams()
                    }
                case .layer:
                    LayerParams(layer: layer).id(ObjectIdentifier(layer))
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
        .environment(\.paramsTwoColumn, twoCol)
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
        case .composition: engine.sceneDraft != nil ? .scenePreview : .composition
        case .layer: .layer
        // エフェクトのクリップは絵を持たないので、出力（コンポジション）を見せる
        case .clip: (clip?.isEffectClip == true ? .composition : .clipPreview)
        }
    }

    private func previewCaption(clip: ClipSlot?, clipIndex: Int?) -> String {
        switch engine.inspectorTab {
        case .composition:
            return engine.editingScene.map { "シーン「\($0.name)」（出力しない・音なし）" } ?? "コンポジション"
        case .layer:
            let name = "レイヤー \(engine.layers[engine.selectedLayer].displayName)"
            return engine.editingScene.map { "シーン「\($0.name)」の\(name)（出力しない）" } ?? name
        case .clip:
            guard let clipIndex else { return "クリップ" }
            let live = engine.activeByLayer[engine.layerOf(clipIndex)] == clipIndex
            if clip?.isEffectClip == true { return live ? "出力（このエフェクトがかかっている）" : "出力（このエフェクトはまだかかっていない）" }
            return live ? "出力中" : "プレビュー（出力しない・音なし）"
        }
    }
}

/// 見出し付きの縦並びパラメーター
struct ParamColumn<Content: View, Accessory: View>: View {
    @Environment(\.paramsWidth) private var w
    let title: String
    /// 見出しの右に置く小さなボタン（リセット・停止など）
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                SectionTitle(title)
                Spacer(minLength: 0)
                accessory
            }
            .frame(height: 18)
            content
        }
        .frame(width: w < UI.paramsWidth - 1 ? w : UI.paramColumnWidth, alignment: .topLeading)
    }
}

extension ParamColumn where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// 見出しの右の小さなボタン（アイコンだけ）
struct MiniButton: View {
    let icon: String
    var label = ""
    var disabled = false
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                if !label.isEmpty { Text(label).font(.system(size: 10, weight: .semibold)) }
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.secondary)
        .disabled(disabled)
        .help(help)
    }
}

/// 不透明度の横の「映像を出さない」ボタン（音量の横の音のミュートと同じ形）
struct VisibilityButton: View {
    @Binding var muted: Bool
    let what: String

    var body: some View {
        Button {
            muted.toggle()
        } label: {
            Image(systemName: muted ? "eye.slash.fill" : "eye")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(muted ? Color.white : Color.secondary)
                .frame(width: 30, height: UI.rowHeight)
                .background(RoundedRectangle(cornerRadius: 5).fill(muted ? Color.red : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(muted ? "\(what)のミュートを解除" : "\(what)をミュート（再生は続けたまま、映像と音を出さない）")
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
                  format: { String(format: "%+.1f%%", $0 * 100) }, style: .position(horizontal: true), key: .posX, target: t)
        AnimField(label: "位置 Y", value: $t.posY, range: -2...2, perPoint: 0.002, defaultValue: 0,
                  format: { String(format: "%+.1f%%", $0 * 100) }, style: .position(horizontal: false), key: .posY, target: t)
        AnimField(label: "スケール", value: $t.scale, range: 0...5, perPoint: 0.003, defaultValue: 1,
                  format: { String(format: "%.1f%%", $0 * 100) }, style: .scale, key: .scale, target: t)
        AnimField(label: "角度", value: $t.rotation, range: -720...720, perPoint: 0.25, defaultValue: 0,
                  format: { String(format: "%.1f°", $0) }, style: .angle, key: .rotation, target: t)
    }
}

private func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

struct CompositionParams: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        SideBySide {
        VStack(alignment: .leading, spacing: 0) {
        ParamColumns {
            ParamColumn(title: "トランスフォーム") {
                MiniButton(icon: "arrow.counterclockwise", label: "リセット",
                           disabled: engine.compTransform.isDefault && engine.masterOpacity == 1,
                           help: "位置・スケール・角度・不透明度を初期値に戻す") { engine.compTransform.reset(); engine.masterOpacity = 1 }
            } content: {
                TransformFields(t: engine.compTransform)
                // 「映像を出さない」は動かし方のボタンの右に（開いた設定が欄の幅いっぱいに出るように）
                AnimField(label: "不透明度", value: $engine.masterOpacity, range: 0...1, perPoint: 0.003,
                              defaultValue: 1, showsBar: true, format: percent, key: .opacity, target: engine,
                          trailing: AnyView(VisibilityButton(muted: $engine.compMuted, what: "コンポジション（出力全体）")))
            }
            ParamColumn(title: "マスター") {
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
        .paramsFrame()
        } second: {
            EffectsSection(holder: engine)
        }
    }
}

/// レイヤーの「ミックス」の見出しの右：このレイヤーを止める（シーンの編集中は、シーンのこのレイヤーを「なし」に）
struct LayerStopMini: View {
    @ObservedObject var layer: Layer
    @EnvironmentObject var engine: Engine
    var body: some View {
        MiniButton(icon: "stop.fill", label: "停止", disabled: engine.viewPlaying(layer.index) == nil,
                   help: engine.sceneDraft != nil ? "このシーンではこのレイヤーに何も流さない" : "このレイヤーを停止") {
            engine.viewStop(layer.index)
        }
    }
}

struct LayerParams: View {
    @ObservedObject var layer: Layer

    var body: some View {
        SideBySide {
        VStack(alignment: .leading, spacing: 0) {
        ParamColumns {
            ParamColumn(title: "トランスフォーム") {
                MiniButton(icon: "arrow.counterclockwise", label: "リセット", disabled: layer.transform.isDefault && layer.opacity == 1,
                           help: "位置・スケール・角度・不透明度を初期値に戻す") { layer.transform.reset(); layer.opacity = 1 }
            } content: {
                TransformFields(t: layer.transform)
                // 「映像を出さない」は動かし方のボタンの右に（開いた設定が欄の幅いっぱいに出るように）
                AnimField(label: "不透明度", value: $layer.opacity, range: 0...1, perPoint: 0.003,
                              defaultValue: 1, showsBar: true, format: percent, key: .opacity, target: layer,
                          trailing: AnyView(VisibilityButton(muted: $layer.muted, what: "このレイヤー")))
            }
            ParamColumn(title: "ミックス") {
                LayerStopMini(layer: layer)
            } content: {
                Toggle(isOn: $layer.isAdjustment) {
                    Label("調整レイヤー", systemImage: "camera.filters")
                }
                .toggleStyle(.switch)
                .frame(height: UI.rowHeight)
                .help("オン：このレイヤーのクリップは使わず、付けたエフェクトを下のレイヤー全体にかける。不透明度がかかり具合")
                BlendChoice(blend: $layer.blend)
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
                VStack(alignment: .leading, spacing: 3) {
                    Text("切り替え方").font(.system(size: 11)).foregroundStyle(.secondary)
                    ChoiceButtons(selection: $layer.transition, items: Transition.allCases.map { ($0, $0.label) })
                        .help(Transition.allCases.map { $0.label + "：" + $0.help }.joined(separator: "\n")
                              + "\n（切り替えフェードの時間をかけて切り替わる。重ね方が「通常」のとき）")
                }
                .opacity(layer.fadeTime < 0.005 ? 0.5 : 1)
            }
        }
        if layer.blend.isSpecial {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("重ね方：" + layer.blend.label)
                EffectCard(effect: $layer.blendFX, isFirst: true, isLast: true, move: { _ in }, remove: {
                    layer.blend = .add
                }, isBlendSettings: true)
            }
            .paramsFrame(alignment: .leading)
            .padding(.top, 14)
        }
        }
        .paramsFrame()
        } second: {
            EffectsSection(holder: layer)
        }
    }
}

/// フェード時間の表示（0 は「カット」）
func fadeSeconds(_ v: Double) -> String {
    v < 0.005 ? "カット" : String(format: "%.2f 秒", v)
}

struct ClipParams: View {
    @ObservedObject var slot: ClipSlot

    var body: some View {
        if slot.isEffectClip {
            EffectClipParams(slot: slot)
        } else {
            mediaParams
        }
    }

    @ViewBuilder private var mediaParams: some View {
        SideBySide {
        VStack(alignment: .leading, spacing: 0) {
        ClipNameField(slot: slot)
            .padding(.bottom, 8)
        ParamColumns {
            ParamColumn(title: "トランスフォーム") {
                MiniButton(icon: "arrow.counterclockwise", label: "リセット", disabled: !slot.hasCustomTransform,
                           help: "位置・スケール・角度・不透明度・音量を初期値に戻す（速度はそのまま）") { slot.resetTransform() }
            } content: {
                TransformFields(t: slot)
                // 「映像を出さない」は動かし方のボタンの右に（開いた設定が欄の幅いっぱいに出るように）
                AnimField(label: "不透明度", value: $slot.opacity, range: 0...1, perPoint: 0.003, defaultValue: 1,
                              showsBar: true, format: percent, key: .opacity, target: slot,
                          trailing: AnyView(VisibilityButton(muted: $slot.muted, what: "このクリップ")))
            }
            // 静止画・ジェネレーターには音も再生範囲も無いので出さない
            if !slot.isStill {
                ParamColumn(title: "音・再生") {
                    HStack(spacing: 4) {
                        ValueDrag(label: "音量", value: $slot.clipVolume, range: 0...1, perPoint: 0.003,
                                  defaultValue: 1, showsBar: true, format: percent)
                            .opacity(slot.audioMuted ? 0.45 : 1)
                        SoundMuteButton(muted: $slot.audioMuted, what: "このクリップ")
                    }
                    .frame(height: UI.rowHeight)
                    ClipSpeedFields(slot: slot)
                }
            }
        }
        if slot.generator != nil {
            // ジェネレーター：再生範囲・速度の代わりに、絵の設定
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("ジェネレーター：" + (slot.generator?.kind.label ?? ""),
                             icon: slot.generator?.kind.icon ?? "sparkles", tint: UI.generatorTint)
                EffectCard(effect: Binding(get: { slot.generator ?? Effect(kind: .solid) }, set: { slot.generator = $0 }),
                           origin: slot.animOrigin, isFirst: true, isLast: true, move: { _ in }, remove: {},
                           isBlendSettings: true)
            }
            .paramsFrame(alignment: .leading)
            .padding(.top, 10)
        } else if slot.isImage {
            // 静止画：再生範囲は無い。動く画像（GIF など）は速度だけ
            VStack(alignment: .leading, spacing: 8) {
                Text((slot.isAnimatedImage
                      ? String(format: "動く画像（%@・1 周 %.2f 秒）", slot.url.pathExtension.uppercased(), slot.animationDuration)
                      : "静止画（\(slot.url.pathExtension.uppercased())）") + (slot.errorMessage.map { "\n" + $0 } ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(slot.errorMessage == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                if slot.isAnimatedImage {
                    ValueDrag(label: "速度", value: $slot.speed, range: ClipSlot.speedRange, perPoint: 0.005,
                              defaultValue: 1, format: { String(format: "%.2fx", $0) })
                        .frame(height: UI.rowHeight)
                        .help("動く画像の速さ（コンポジション速度も掛かる）。ダブルクリックで 1.00x")
                }
            }
            .paramsFrame(alignment: .leading)
            .padding(.top, 10)
        } else {
            PlayRangeSection(slot: slot)
                .padding(.top, 10)
        }
        }
        .paramsFrame()
        } second: {
            EffectsSection(holder: slot)
        }
    }
}

/// クリップの見かけの名前の欄（空なら元の名前を薄く出す）
struct ClipNameField: View {
    @ObservedObject var slot: ClipSlot

    var body: some View {
        HStack(spacing: 6) {
            Text("名前").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(slot.autoName, text: $slot.title)
                .textFieldStyle(.roundedBorder)
                .help("クリップの枠などに出る名前。空にすると元の名前（" + slot.autoName + "）")
            if !slot.title.isEmpty {
                Button { slot.title = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("元の名前（" + slot.autoName + "）に戻す")
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

/// クリップの名前を変える（右クリックメニューから）
enum ClipRename {
    static func ask(_ slot: ClipSlot) {
        if let t = askText(title: "クリップの名前（空にすると元の名前「\(slot.autoName)」）", initial: slot.title) {
            slot.title = t
        }
    }
}

/// エフェクトのクリップ（調整レイヤーの枠）の設定：名前と、エフェクトの並び
struct EffectClipParams: View {
    @ObservedObject var slot: ClipSlot

    var body: some View {
        SideBySide {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("エフェクトのクリップ")
                HStack(spacing: 6) {
                    Text("名前").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField(slot.autoName, text: $slot.title)
                        .textFieldStyle(.roundedBorder)
                }
                Text("押すと、右のエフェクトがこのレイヤーより下の絵全体にかかる（レイヤーの不透明度がかかり具合）。同じ段の別の枠を押すと切り替わり、空きの枠を押すと外れる。レイヤー自体に付けたエフェクトは、いつも一緒にかかる。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .paramsFrame()
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
            // 端のコマ（イン点のコマと、アウト点の直前のコマ）。黒などが残っていないか見ながら決められる
            HStack(spacing: 8) {
                EdgeFrame(slot: slot, isIn: true)
                Spacer(minLength: 0)
                EdgeFrame(slot: slot, isIn: false)
            }
            InOutBar(slot: slot)
                .frame(height: 40)
            // 細いときはイン・アウトを 2 段に
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    inControls
                    Spacer(minLength: 4)
                    outControls
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) { inControls; Spacer(minLength: 0) }
                    HStack(spacing: 6) { outControls; Spacer(minLength: 0) }
                }
            }
            .font(.system(size: 12).monospacedDigit())
            Text(String(format: "長さ %.2f 秒（%.0f コマ）", max(slot.outTime - slot.inPoint, 0),
                        (max(slot.outTime - slot.inPoint, 0) / slot.frameLength).rounded()))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            // 細いときは見出しを上に、さらに細いときはアイコンだけ
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    endLabel
                    endPicker(iconOnly: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    endLabel
                    endPicker(iconOnly: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    endLabel
                    endPicker(iconOnly: true).frame(minWidth: 0, maxWidth: .infinity)
                }
            }
            .help("アウト点まで来たとき：ループ＝イン点から繰り返す／最後で停止＝最後のコマで止める／ブラックアウト＝このレイヤーを消す")
            Group {
                if narrow {
                    // 細いときは見出しを上に、ボタンは 2 段
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ジャンプ（拍ごと）").font(.system(size: 12)).foregroundStyle(.secondary)
                        ChoiceButtons(selection: $slot.jumpBeats, items: jumpItems, columns: 4)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("ジャンプ").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                        ChoiceButtons(selection: $slot.jumpBeats, items: jumpItems)
                        Text("拍ごと").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    }
                }
            }
            .help("BPM の拍の頭で、再生範囲の中のランダムな位置へ飛ぶ（音も一緒に飛ぶ）。テンポは「ライブ」パネルの BPM / TAP で")
        }
        .paramsFrame(alignment: .leading)
    }

    @Environment(\.paramsWidth) private var w
    private var narrow: Bool { w < 420 }
    private var jumpItems: [(Double, String)] { ClipSlot.jumpChoices.map { ($0, $0 == 0 ? "しない" : beatShort($0)) } }

    private var inControls: some View {
        HStack(spacing: 6) {
            timeLabel("イン", slot.inPoint, changed: slot.inPoint > 0)
            FrameStepButtons(help: "イン点") { slot.stepIn($0) }
        }
    }

    private var outControls: some View {
        HStack(spacing: 6) {
            timeLabel("アウト", slot.outTime, changed: slot.outPoint != nil)
            FrameStepButtons(help: "アウト点") { slot.stepOut($0) }
        }
    }

    private var endLabel: some View {
        Text("終わったら").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
    }

    private func endPicker(iconOnly: Bool) -> some View {
        Picker("", selection: $slot.endAction) {
            ForEach(EndAction.allCases) { a in
                Group {
                    if iconOnly { Image(systemName: a.icon) } else { Label(a.label, systemImage: a.icon) }
                }
                .help(a.label)
                .tag(a)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
    }

    private func timeLabel(_ title: String, _ t: Double, changed: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(clipTime(t)).foregroundStyle(changed ? Color.orange : Color.primary)
        }
        .fixedSize()
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
/// イン点・アウト点を 1 コマずつ動かすボタン（⇧で 10 コマ）
struct FrameStepButtons: View {
    let help: String
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("chevron.left", -1)
            button("chevron.right", 1)
        }
    }

    private func button(_ icon: String, _ dir: Int) -> some View {
        Button {
            step(dir * (NSEvent.modifierFlags.contains(.shift) ? 10 : 1))
        } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help + "を 1 コマ" + (dir < 0 ? "前" : "後ろ") + "へ（⇧を押しながらで 10 コマ）")
    }
}

/// 再生範囲の端のコマ：イン点のコマ／アウト点の直前（最後に映る）コマ。動かすと描き直す
struct EdgeFrame: View {
    @ObservedObject var slot: ClipSlot
    let isIn: Bool
    @State private var image: CGImage?

    private var time: Double { isIn ? slot.inPoint : max(slot.outTime - slot.frameLength, 0) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(isIn ? "最初のコマ" : "最後のコマ")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: 136)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.35)))
        // ドラッグ中は少し待ってから描く（描きすぎない）
        .task(id: "\(time)-\(slot.duration)") {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            let img = await slot.exactFrame(at: time)
            if !Task.isCancelled { image = img }
        }
        .help(isIn ? "イン点のコマ（ここから再生）" : "アウト点の直前のコマ（ここまで映る）")
    }
}

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
                // クリップのコマを並べる（どこが黒いかなどが見える）
                if !slot.filmstrip.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(slot.filmstrip.indices, id: \.self) { k in
                            Image(decorative: slot.filmstrip[k], scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: w / CGFloat(slot.filmstrip.count), height: g.size.height)
                                .clipped()
                        }
                    }
                    .opacity(0.75)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    // 使わない所は暗く
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: max(xi, 0))
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: max(w - xo, 0)).offset(x: xo)
                }
                // 使う範囲
                Rectangle()
                    .fill(Color.accentColor.opacity(slot.filmstrip.isEmpty ? 0.35 : 0.15))
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
        .onAppear { slot.loadFilmstrip() }
        .onChange(of: slot.duration) { _, _ in slot.loadFilmstrip() }
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
        .controlSize(compact ? .small : .regular)
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
                second.paramsFrame()
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
private struct ParamsWidthKey: EnvironmentKey { static let defaultValue = UI.paramsWidth }
extension EnvironmentValues {
    /// パラメーター欄に使える幅（狭いと、2 つの列を縦に積んで幅いっぱいに広げる）
    var paramsWidth: CGFloat {
        get { self[ParamsWidthKey.self] }
        set { self[ParamsWidthKey.self] = newValue }
    }
}

extension View {
    /// パラメーター欄の幅にする（狭い所では狭く）
    func paramsFrame(alignment: Alignment = .topLeading) -> some View { modifier(ParamsFrame(alignment: alignment)) }
}

private struct ParamsFrame: ViewModifier {
    let alignment: Alignment
    @Environment(\.paramsWidth) private var w
    func body(content: Content) -> some View { content.frame(width: w, alignment: alignment) }
}

/// 2 つの列（トランスフォーム・ミックスなど）。幅があれば横に、狭ければ縦に積む
struct ParamColumns<Content: View>: View {
    @Environment(\.paramsWidth) private var w
    @ViewBuilder var content: Content
    var body: some View {
        if w < UI.paramsWidth - 1 {
            VStack(alignment: .leading, spacing: 14) { content }
        } else {
            HStack(alignment: .top, spacing: 16) { content }
        }
    }
}
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
