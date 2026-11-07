import AppKit
import SwiftUI

// 色を選ぶ所。Mac の標準の色パネルの代わりに、その場に出る小さな窓で選ぶ：
// 横が色相・縦が鮮やかさ（上が鮮やか、下が白）の四角、明るさのバー、16 進の欄、よく使う色

extension RGB {
    /// 色相（0〜1）・彩度・明るさ
    var hsb: (h: Double, s: Double, b: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 1e-9 {
            if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx > 1e-9 ? d / mx : 0, mx)
    }

    /// #RRGGBB
    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    init?(hex: String) {
        var t = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasPrefix("#") { t.removeFirst() }
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        self = PalettePreset.hex(v)
    }
}

/// 色の見本（押すと色を選ぶ窓が開く）
struct ColorWell: View {
    @Binding var color: RGB
    var width: CGFloat = 60
    var height: CGFloat = UI.rowHeight
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(rgb: color))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(open ? 0.9 : 0.35), lineWidth: open ? 2 : 1))
                .frame(width: width, height: height - 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("クリックで色を選ぶ（" + color.hex + "）")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ColorPad(color: $color)
                .padding(12)
        }
    }
}

/// 色を選ぶ窓の中身
struct ColorPad: View {
    @Binding var color: RGB
    var padWidth: CGFloat = 260
    var padHeight: CGFloat = 200

    /// 白・黒・灰色のときも色相を覚えておく（RGB だけだと消えてしまうので）
    @State private var hue = 0.0
    @State private var sat = 1.0
    @State private var bri = 1.0
    @State private var hexText = ""
    @State private var ready = false

    static let swatches: [RGB] = [.white, .black, .hsb(0, 1, 1), .hsb(0.08, 1, 1), .hsb(0.15, 1, 1), .hsb(0.33, 1, 1),
                                  .hsb(0.5, 1, 1), .hsb(0.6, 1, 1), .hsb(0.75, 1, 1), .hsb(0.85, 1, 1), .hsb(0.0, 0, 0.5)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            pad
            brightnessBar
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(Color(rgb: color))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5)))
                    .frame(width: 34, height: 24)
                TextField("#RRGGBB", text: $hexText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 84)
                    .onSubmit(applyHex)
                Text(String(format: "H %.0f°  S %.0f%%  B %.0f%%", hue * 360, sat * 100, bri * 100))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            // よく使う色
            HStack(spacing: 4) {
                ForEach(Self.swatches, id: \.self) { c in
                    Button { set(c) } label: {
                        RoundedRectangle(cornerRadius: 4).fill(Color(rgb: c))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5)))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(c.hex)
                }
            }
        }
        .frame(width: padWidth)
        .onAppear(perform: load)
        .onChange(of: color) { _, c in
            // 外（よく使う色・16 進）で変わったときだけ合わせる（つまみを動かしている間は自分の値のまま）
            if c != current { load() }
        }
    }

    /// 色相 × 鮮やかさの四角（明るさはいっぱいで見せる）
    private var pad: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom)
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .background(Circle().fill(Color(rgb: .hsb(hue, sat, 1))))
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.5).padding(-1))
                .frame(width: 18, height: 18)
                .offset(x: hue * padWidth - 9, y: (1 - sat) * padHeight - 9)
                .allowsHitTesting(false)
        }
        .frame(width: padWidth, height: padHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            hue = min(max(v.location.x / padWidth, 0), 1)
            sat = 1 - min(max(v.location.y / padHeight, 0), 1)
            // 真っ黒のまま色を選んだら、明るくする（選んだのが見えるように）
            if bri < 0.05 { bri = 1 }
            push()
        })
        .help("横で色相、縦で鮮やかさ（下ほど白に近い）")
    }

    /// 明るさのバー（左が黒、右がいっぱい）
    private var brightnessBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                LinearGradient(colors: [.black, Color(rgb: .hsb(hue, sat, 1))], startPoint: .leading, endPoint: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(rgb: current)))
                    .frame(width: 10, height: 22)
                    .offset(x: bri * (g.size.width - 10))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                bri = min(max((v.location.x - 5) / max(g.size.width - 10, 1), 0), 1)
                push()
            })
        }
        .frame(height: 22)
        .help("明るさ（左ほど黒）")
    }

    private var current: RGB { .hsb(hue, sat, bri) }

    private func push() {
        let c = current
        if c != color { color = c }
        hexText = c.hex
    }

    private func load() {
        let (h, s, b) = color.hsb
        // 色の無い色（白・黒・灰色）では、色相・鮮やかさは前のまま
        if s > 1e-4 && b > 1e-4 { hue = h }
        if b > 1e-4 { sat = s }
        bri = b
        hexText = color.hex
    }

    private func set(_ c: RGB) {
        color = c
        load()
    }

    private func applyHex() {
        if let c = RGB(hex: hexText) { set(c) } else { NSSound.beep(); hexText = color.hex }
    }
}

/// 開発用：色を選ぶ窓（決まった色で）
struct ColorPadPreview: View {
    @State var color: RGB
    var body: some View { ColorPad(color: $color).padding(12) }
}
