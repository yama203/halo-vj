// アプリアイコンを描いて書き出す。
//   swift tools/make_icon.swift [出力フォルダ]
// → <出力フォルダ>/AppIcon.iconset・ProjectIcon.iconset（各サイズの PNG）と、確認用の 1024px の PNG を作る。
// .icns にするのは tools/make_app.sh（iconutil）。
//
// デザイン：黒に近い角丸の板に、ピンク・水色・黄の光の円が 3 つ重なる（光を足すと、重なった所が混ざって真ん中が白）。
// 数値は 1024 x 1024 の画面での値（macOS のアイコンの決まりで、板は 824 x 824 を真ん中に置く）
import AppKit
import CoreGraphics
import CoreText

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
    ctx.setFillColor(rgb(0x050508))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(boardPath)
    ctx.clip()
    // 上が少し明るい、黒に近い縦のグラデーション
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x15151F), rgb(0x0B0B12), rgb(0x050508)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // 3 色の光（ピンク・水色・黄）を足して重ねる：2 色の所は桃色・ラベンダー・薄緑、3 色の真ん中は白
    ctx.setBlendMode(.plusLighter)
    let colors: [UInt32] = [0xFF2D78, 0x26D9FF, 0xFFC42E]
    let r: CGFloat = 200, d: CGFloat = 112, alpha: CGFloat = 0.74
    for (i, col) in colors.enumerated() {
        let t = CGFloat(i) / 3 * 2 * .pi - .pi / 2
        let p = CGPoint(x: 512 + cos(t) * d, y: 532 + sin(t) * d)
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        // 左上が少し明るい（光の玉らしく）
        let g = CGGradient(colorsSpace: space, colors: [rgb(col, min(alpha * 1.15, 1)), rgb(col, alpha), rgb(col, alpha * 0.9)] as CFArray,
                           locations: [0, 0.7, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: p.x - r * 0.15, y: p.y - r * 0.2), startRadius: 0,
                               endCenter: p, endRadius: r, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
    ctx.setBlendMode(.normal)

    // 上側の光沢
    let gloss = CGMutablePath()
    gloss.move(to: CGPoint(x: 100, y: 330))
    gloss.addQuadCurve(to: CGPoint(x: 924, y: 330), control: CGPoint(x: 512, y: 180))
    gloss.addLine(to: CGPoint(x: 924, y: 100))
    gloss.addLine(to: CGPoint(x: 100, y: 100))
    gloss.closeSubpath()
    ctx.addPath(gloss)
    ctx.clip()
    let gl = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.08), rgb(0xFFFFFF, 0.01)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(gl, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 330), options: [])
    ctx.restoreGState()
    // 板のふち（内側の細い光）
    ctx.addPath(CGPath(roundedRect: board.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()

    ctx.restoreGState()
}

/// プロジェクトファイル（.halovj）のアイコン：角を折った紙に、アプリのアイコンと「HALO VJ」
func drawDocIcon(_ ctx: CGContext, size: CGFloat) {
    let k = size / 1024
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: k, y: -k)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // 紙（右上を折る）
    let l: CGFloat = 196, r: CGFloat = 828, t: CGFloat = 92, b: CGFloat = 932, fold: CGFloat = 170
    let page = CGMutablePath()
    page.move(to: CGPoint(x: l + 24, y: t))
    page.addLine(to: CGPoint(x: r - fold, y: t))
    page.addLine(to: CGPoint(x: r, y: t + fold))
    page.addLine(to: CGPoint(x: r, y: b - 24))
    page.addQuadCurve(to: CGPoint(x: r - 24, y: b), control: CGPoint(x: r, y: b))
    page.addLine(to: CGPoint(x: l + 24, y: b))
    page.addQuadCurve(to: CGPoint(x: l, y: b - 24), control: CGPoint(x: l, y: b))
    page.addLine(to: CGPoint(x: l, y: t + 24))
    page.addQuadCurve(to: CGPoint(x: l + 24, y: t), control: CGPoint(x: l, y: t))
    page.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(0x000000, 0.35))
    ctx.addPath(page)
    ctx.setFillColor(rgb(0xF4F4F7))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(page)
    ctx.clip()
    let paper = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xEBEBF1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 512, y: t), end: CGPoint(x: 512, y: b), options: [])
    ctx.restoreGState()
    // 折り返し
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: r - fold, y: t))
    flap.addLine(to: CGPoint(x: r - fold, y: t + fold - 18))
    flap.addQuadCurve(to: CGPoint(x: r - fold + 18, y: t + fold), control: CGPoint(x: r - fold, y: t + fold))
    flap.addLine(to: CGPoint(x: r, y: t + fold))
    flap.closeSubpath()
    ctx.addPath(flap)
    ctx.setFillColor(rgb(0xD5D5DE))
    ctx.fillPath()
    // アプリのアイコン（小さく）
    ctx.saveGState()
    let iconSize: CGFloat = 470
    ctx.translateBy(x: 512 - iconSize / 2, y: 470 + iconSize / 2)
    ctx.scaleBy(x: 1, y: -1)
    drawIcon(ctx, size: iconSize)
    ctx.restoreGState()
    // 文字
    let text = NSAttributedString(string: "HALO VJ", attributes: [
        .font: NSFont.systemFont(ofSize: 74, weight: .heavy),
        .foregroundColor: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.22, alpha: 1),
        .kern: 6,
    ])
    let line = CTLineCreateWithAttributedString(text)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.translateBy(x: 512 - CGFloat(w) / 2, y: 840)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    ctx.restoreGState()
}

func png(size px: Int, doc: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.cgContext.interpolationQuality = .high
    if doc { drawDocIcon(g.cgContext, size: CGFloat(px)) } else { drawIcon(g.cgContext, size: CGFloat(px)) }
    g.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

for (name, doc) in [("AppIcon", false), ("ProjectIcon", true)] {
    let iconset = outDir.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! png(size: base, doc: doc).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try! png(size: base * 2, doc: doc).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    print("書き出しました: \(iconset.path)")
}
try! png(size: 1024).write(to: outDir.appendingPathComponent("icon_1024.png"))
try! png(size: 1024, doc: true).write(to: outDir.appendingPathComponent("project_icon_1024.png"))
