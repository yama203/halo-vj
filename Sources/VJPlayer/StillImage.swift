import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers

/// 静止画の読み込み（PNG・JPEG・HEIC・TIFF・GIF・WebP・PSD・PDF・AI・SVG など）。
/// PSD は重ねた結果の 1 枚、PDF・AI は 1 ページ目（AI は「PDF 互換ファイルを作成」で保存したもの）
enum StillImage {
    /// 長い辺の最大ピクセル数（大きすぎる画像は縮める）
    static let maxPixels = 4096

    /// PDF として読むもの
    static let pdfExtensions: Set<String> = ["pdf", "ai"]
    static let svgExtensions: Set<String> = ["svg"]

    /// 静止画として扱うファイルか
    static func isImage(_ u: URL) -> Bool {
        let ext = u.pathExtension.lowercased()
        if pdfExtensions.contains(ext) || svgExtensions.contains(ext) || ext == "psd" { return true }
        guard let t = UTType(filenameExtension: ext) else { return false }
        return t.conforms(to: .image)
    }

    /// ファイルを開くパネルで選べる種類
    static var openTypes: [UTType] {
        var t: [UTType] = [.image, .pdf, .svg]
        if let ai = UTType(filenameExtension: "ai") { t.append(ai) }
        if let psd = UTType(filenameExtension: "psd") { t.append(psd) }
        return t
    }

    /// 画像を読む（長い辺は maxPixels まで）。読めなければ nil
    static func load(_ u: URL, maxPixels: Int = StillImage.maxPixels) -> CGImage? {
        let ext = u.pathExtension.lowercased()
        if pdfExtensions.contains(ext) { return loadPDF(u, maxPixels: maxPixels) }
        if svgExtensions.contains(ext) { return loadSVG(u, maxPixels: maxPixels) }
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// アニメーション（GIF・APNG・WebP など）のコマと、それぞれの表示時間（秒）
    struct Animation {
        let frames: [CGImage]
        let delays: [Double]
        var duration: Double { delays.reduce(0, +) }
    }
    /// アニメーションのコマの数の上限と、全コマ合わせたメモリの目安
    static let maxAnimationFrames = 1000
    static let animationBudgetBytes = 384 * 1024 * 1024

    /// 2 コマ以上ある画像なら、全コマを読む（1 コマなら nil）。メモリに収まるよう大きさを縮める
    static func loadAnimation(_ u: URL, maxPixels: Int = 2048) -> Animation? {
        let ext = u.pathExtension.lowercased()
        guard !pdfExtensions.contains(ext), !svgExtensions.contains(ext),
              let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        let n = min(CGImageSourceGetCount(src), maxAnimationFrames)
        guard n > 1 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 512
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 512
        let long = Double(max(w, h, 1))
        let fit = sqrt(Double(animationBudgetBytes) / (Double(n) * Double(w * h * 4)))
        let px = max(Int(min(long, Double(maxPixels), long * fit)), 16)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: px,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [CGImage] = [], delays: [Double] = []
        for i in 0..<n {
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
            frames.append(img)
            delays.append(frameDelay(src, i))
        }
        return frames.count > 1 ? Animation(frames: frames, delays: delays) : nil
    }

    /// i コマ目の表示時間。とても短い値はブラウザと同じく 0.1 秒として扱う
    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dk, uk, ck) in dicts {
            guard let d = p[dk] as? [CFString: Any] else { continue }
            let v = (d[uk] as? Double) ?? (d[ck] as? Double) ?? 0
            return v < 0.011 ? 0.1 : v
        }
        return 0.1
    }

    /// PDF・AI の 1 ページ目を描く（透明な所は透明のまま）
    private static func loadPDF(_ u: URL, maxPixels: Int) -> CGImage? {
        guard let doc = CGPDFDocument(u as CFURL), let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        // ふつうの大きさなら 4 倍くらいで描いてくっきりさせる（上限 maxPixels）
        let k = min(Double(maxPixels) / Double(max(box.width, box.height)), 4)
        let w = max(Int(box.width * k), 1), h = max(Int(box.height * k), 1)
        guard let ctx = makeContext(w, h) else { return nil }
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// SVG を描く（macOS の SVG 表示を使う）
    private static func loadSVG(_ u: URL, maxPixels: Int) -> CGImage? {
        guard let img = NSImage(contentsOf: u), img.size.width > 0, img.size.height > 0 else { return nil }
        let k = min(Double(maxPixels) / Double(max(img.size.width, img.size.height)), 8)
        let w = max(Int(img.size.width * k), 1), h = max(Int(img.size.height * k), 1)
        guard let ctx = makeContext(w, h) else { return nil }
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func makeContext(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// 描画用のテクスチャ（BGRA・アルファ乗算済み。ジェネレーターの絵と同じ形）
    static func texture(_ img: CGImage) -> MTLTexture? {
        let w = img.width, h = img.height
        guard w > 0, h > 0, let ctx = makeContext(w, h) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.shaderRead]
        td.storageMode = .shared
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: td) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        return tex
    }
}
