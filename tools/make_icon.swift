// アプリアイコンを描いて書き出す。
//   swift tools/make_icon.swift [出力フォルダ]
// → <出力フォルダ>/AppIcon.iconset（各サイズの PNG）と icon_1024.png を作る。
// .icns にするのは tools/make_app.sh（iconutil）。
//
// デザイン：暗い紫の角丸の板に、光る輪 1 本・その上に 1 拍目の光・黄色い再生ボタン（立体）。
// 数値は 1024 x 1024 の画面での値（macOS のアイコンの決まりで、板は 824 x 824 を真ん中に置く）
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let k = size / 1024
    ctx.saveGState()
    // 左上を原点にする
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: k, y: -k)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // 板（角丸）
    let board = CGRect(x: 100, y: 100, width: 824, height: 824)
    let boardPath = CGPath(roundedRect: board, cornerWidth: 185, cornerHeight: 185, transform: nil)
    // 下の影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: rgb(0x000000, 0.45))
    ctx.addPath(boardPath)
    ctx.setFillColor(rgb(0x140A28))
    ctx.fillPath()
    ctx.restoreGState()
    // 上が少し明るい縦のグラデーション
    ctx.saveGState()
    ctx.addPath(boardPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x2A1650), rgb(0x150B2C), rgb(0x0C0619)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // 真ん中のほのかな紫の光
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0x6A3BE0, 0.35), rgb(0x6A3BE0, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 400, options: [])
    // 上側の光沢
    let gloss = CGMutablePath()
    gloss.move(to: CGPoint(x: 100, y: 360))
    gloss.addQuadCurve(to: CGPoint(x: 924, y: 360), control: CGPoint(x: 512, y: 190))
    gloss.addLine(to: CGPoint(x: 924, y: 100))
    gloss.addLine(to: CGPoint(x: 100, y: 100))
    gloss.closeSubpath()
    ctx.addPath(gloss)
    ctx.clip()
    let gl = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0.02)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(gl, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 360), options: [])
    ctx.restoreGState()
    // 板のふち（内側の細い光）
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: board.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    let c = CGPoint(x: 512, y: 512)
    let r: CGFloat = 252

    // 輪：ぼかした太い光 → 細い明るい線
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: rgb(0x7B4DFF, 0.9))
    ctx.setStrokeColor(rgb(0x7B4DFF, 0.32))
    ctx.setLineWidth(54)
    ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: rgb(0xB48CFF, 0.8))
    ctx.setStrokeColor(rgb(0xC9A6FF))
    ctx.setLineWidth(13)
    ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // 1 拍目の光（輪の上）
    let dot = CGPoint(x: 512, y: 512 - r)
    ctx.saveGState()
    let halo = CGGradient(colorsSpace: space, colors: [rgb(0xFFB067, 0.75), rgb(0xFF8A3D, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: dot, startRadius: 0, endCenter: dot, endRadius: 110, options: [])
    ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xFF8A3D, 1))
    ctx.setFillColor(rgb(0xFFC48A))
    ctx.fillEllipse(in: CGRect(x: dot.x - 40, y: dot.y - 40, width: 80, height: 80))
    ctx.restoreGState()
    ctx.setFillColor(rgb(0xFFF1DC, 0.9))
    ctx.fillEllipse(in: CGRect(x: dot.x - 16, y: dot.y - 22, width: 26, height: 22))

    // 再生ボタン（角を丸めた三角、上が明るい黄色）
    let p0 = CGPoint(x: 512 - 82, y: 512 - 146), p1 = CGPoint(x: 512 + 148, y: 512 + 4)
    let p2 = CGPoint(x: 512 - 82, y: 512 + 154)
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: (p0.x + p2.x) / 2, y: (p0.y + p2.y) / 2))
    tri.addArc(tangent1End: p0, tangent2End: p1, radius: 34)
    tri.addArc(tangent1End: p1, tangent2End: p2, radius: 34)
    tri.addArc(tangent1End: p2, tangent2End: p0, radius: 34)
    tri.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 30, color: rgb(0x000000, 0.5))
    ctx.addPath(tri)
    ctx.setFillColor(rgb(0xE0A800))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tri)
    ctx.clip()
    let ty = CGGradient(colorsSpace: space, colors: [rgb(0xFFE680), rgb(0xFFD23F), rgb(0xE8A400)] as CFArray,
                        locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(ty, start: CGPoint(x: 512, y: 512 - 145), end: CGPoint(x: 512, y: 512 + 155), options: [])
    // 上半分の照り
    let shine = CGMutablePath()
    shine.move(to: CGPoint(x: 512 - 90, y: 512 - 150))
    shine.addLine(to: CGPoint(x: 512 + 160, y: 512 + 2))
    shine.addLine(to: CGPoint(x: 512 - 90, y: 512 + 20))
    shine.closeSubpath()
    ctx.addPath(shine)
    ctx.setFillColor(rgb(0xFFFFFF, 0.16))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()
}

func png(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    g.cgContext.interpolationQuality = .high
    drawIcon(g.cgContext, size: CGFloat(px))
    g.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: outDir.appendingPathComponent("icon_1024.png"))
print("書き出しました: \(iconset.path)")
