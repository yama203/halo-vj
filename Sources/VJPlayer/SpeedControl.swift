import AppKit
import SwiftUI

/// 再生速度のコントロール。
/// - 左右ドラッグで相対的に変化（クリックした位置にジャンプしない）
/// - Shift + ドラッグで微調整
/// - 右クリック or ダブルクリックで 1.000x に戻る
final class SpeedControlNSView: NSView {
    var value: Double = 1.0 { didSet { if oldValue != value { needsDisplay = true } } }
    var onChange: ((Double) -> Void)?
    var defaultValue = 1.0
    var range: ClosedRange<Double> = ClipSlot.speedRange
    /// バー表示の振れ幅（1.0 ± visualSpan で端まで届く）
    var visualSpan = 0.25
    /// true なら、ドラッグを離した瞬間に既定値（1.0x）へ戻る
    var springBack = false { didSet { if oldValue != springBack { needsDisplay = true } } }

    private var dragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { set(defaultValue); return }
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let fine = event.modifierFlags.contains(.shift)
        let perPoint = fine ? 0.0001 : 0.001
        set(value + Double(event.deltaX) * perPoint)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        needsDisplay = true
        if springBack { set(defaultValue) }
    }

    override func rightMouseDown(with event: NSEvent) {
        set(defaultValue)
    }

    private func set(_ v: Double) {
        let c = min(max((v * 10000).rounded() / 10000, range.lowerBound), range.upperBound)
        guard c != value else { return }
        value = c
        onChange?(c)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let bg = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor(white: dragging ? 0.22 : 0.16, alpha: 1).setFill()
        bg.fill()

        if springBack {
            NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
            bg.lineWidth = 1.5
            bg.stroke()
        }

        let deviated = abs(value - defaultValue) > 0.00005
        let accent = deviated ? NSColor.systemOrange : NSColor.systemGreen

        // 中央（1.0）からのずれをバーで表示
        let mid = r.midX
        let t = max(-1, min(1, (value - defaultValue) / visualSpan))
        let x = mid + CGFloat(t) * (r.width / 2 - 4)
        let bar = NSRect(x: min(mid, x), y: r.maxY - 8, width: abs(x - mid), height: 4)
        accent.withAlphaComponent(0.9).setFill()
        NSBezierPath(rect: bar).fill()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: mid - 0.5, y: r.maxY - 12, width: 1, height: 12)).fill()

        let pct = (value - defaultValue) * 100
        let text = String(format: "%.3fx", value)
        let sub = deviated ? String(format: "%+.2f%%", pct) : "通常速度"
        let main: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: deviated ? NSColor.systemOrange : NSColor.white,
        ]
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.7, alpha: 1),
        ]
        let ms = (text as NSString).size(withAttributes: main)
        let ss = (sub as NSString).size(withAttributes: small)
        let total = ms.width + 10 + ss.width
        let y = r.midY - ms.height / 2 - 3
        (text as NSString).draw(at: NSPoint(x: r.midX - total / 2, y: y), withAttributes: main)
        (sub as NSString).draw(at: NSPoint(x: r.midX - total / 2 + ms.width + 10, y: y + ms.height - ss.height - 3),
                               withAttributes: small)
    }
}

struct SpeedControl: NSViewRepresentable {
    @Binding var value: Double
    var springBack = false

    func makeNSView(context: Context) -> SpeedControlNSView {
        let v = SpeedControlNSView()
        v.value = value
        v.springBack = springBack
        v.onChange = { newValue in
            context.coordinator.parent.value = newValue
        }
        return v
    }

    func updateNSView(_ nsView: SpeedControlNSView, context: Context) {
        context.coordinator.parent = self
        if nsView.value != value { nsView.value = value }
        nsView.springBack = springBack
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: SpeedControl
        init(parent: SpeedControl) { self.parent = parent }
    }
}
