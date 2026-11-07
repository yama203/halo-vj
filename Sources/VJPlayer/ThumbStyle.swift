import AppKit
import SwiftUI

/// グリッドのサムネイルの見せ方（サムネイルの中身から自動で決める）
///  - 透明があるか（あれば角に市松のバッジ。マウスを乗せている間は、市松模様の上に出して透明の範囲を見せる）
///  - 暗い素材か（透明がある暗い絵は、黒地に溶けないように灰色の地に出す）
///  - 中身に寄せた絵（大きな透明の中に小さく描かれた素材は、描かれた範囲に合わせて大きく見せる）
struct ThumbStyle {
    var hasAlpha = false
    var dark = false
    /// 中身に寄せた絵（寄せないなら nil）
    var zoomed: NSImage?

    /// 地の色（黒＝出力と同じ。暗い素材は灰色）
    var background: Color { hasAlpha && dark ? Color(white: 0.55) : .black }

    static let none = ThumbStyle()

    /// 中身のうち、描かれている範囲がこれより小さければ寄せる（縦か横の割合）
    static let zoomBelow = 0.6

    static func make(_ image: NSImage?) -> ThumbStyle {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .none }
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return .none
        default: break
        }
        // 小さく縮めて数える（横 64）
        let w = 64, h = max(Int((Double(cg.height) / Double(max(cg.width, 1)) * 64).rounded()), 1)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .none }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var clear = 0
        var minX = w, minY = h, maxX = -1, maxY = -1
        var lumSum = 0.0, aSum = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let a = Int(px[i + 3])
                if a < 250 { clear += 1 }
                if a > 16 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    // 色は不透明度が掛かっているので、そのまま足して不透明度の合計で割ると平均の明るさ
                    lumSum += (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
                    aSum += Double(a) / 255
                }
            }
        }
        var s = ThumbStyle()
        // 2% 以上が透けていれば「透明あり」
        s.hasAlpha = clear * 50 > w * h
        guard s.hasAlpha else { return s }
        s.dark = aSum > 0.5 && lumSum / aSum < 0.28
        guard maxX >= 0 else { return s }
        // 描かれた範囲（数えた絵の 1 行目が上。CGImage の切り抜きも上から数える）
        let fx = Double(maxX - minX + 1) / Double(w), fy = Double(maxY - minY + 1) / Double(h)
        if fx < zoomBelow && fy < zoomBelow || fx * fy < zoomBelow * zoomBelow {
            let sx = Double(cg.width) / Double(w), sy = Double(cg.height) / Double(h)
            var r = CGRect(x: Double(minX) * sx, y: Double(minY) * sy,
                           width: Double(maxX - minX + 1) * sx, height: Double(maxY - minY + 1) * sy)
            // まわりに少しゆとり
            r = r.insetBy(dx: -r.width * 0.12 - sx, dy: -r.height * 0.12 - sy)
                .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)).integral
            if let c = cg.cropping(to: r) {
                s.zoomed = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
            }
        }
        return s
    }
}

/// 透明の範囲を見せる市松模様
struct CheckerBackground: View {
    var cell: CGFloat = 6
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.42)))
            let nx = Int(size.width / cell) + 1, ny = Int(size.height / cell) + 1
            var p = Path()
            for y in 0..<ny { for x in 0..<nx where (x + y) % 2 == 0 {
                p.addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell))
            } }
            ctx.fill(p, with: .color(Color(white: 0.62)))
        }
    }
}

/// 「透明あり」「中身に寄せて表示中」の小さな印
struct ThumbBadge: View {
    let style: ThumbStyle
    var body: some View {
        HStack(spacing: 3) {
            if style.hasAlpha {
                Image(systemName: "checkerboard.rectangle")
                    .help("透明な所がある素材（マウスを乗せると、市松模様の上で透明の範囲を見せる）")
            }
            if style.zoomed != nil {
                Image(systemName: "plus.magnifyingglass")
                    .help("描かれた範囲が小さいので、そこに寄せて表示している（マウスを乗せると全体）")
            }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 3).padding(.vertical, 2)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
    }
}
