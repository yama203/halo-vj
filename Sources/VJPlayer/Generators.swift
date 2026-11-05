import AppKit
import Metal

/// ジェネレーターのサムネイル（グリッドに出す小さな絵）。メインスレッドで、その場で描いて読み出す
enum GeneratorThumbnail {
    private static let fx: EffectProcessor = { let p = EffectProcessor(); p.storageMode = .shared; return p }()
    private static var blank: MTLTexture?
    static let size = (w: 192, h: 108)

    static func image(_ g: Effect) -> NSImage? {
        let ctx = MetalContext.shared
        if blank == nil {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.w, height: size.h,
                                                              mipmapped: false)
            td.usage = [.shaderRead]
            blank = ctx.device.makeTexture(descriptor: td)
        }
        guard let blank, let cb = ctx.queue.makeCommandBuffer() else { return nil }
        var e = g
        e.enabled = true
        // 止まった絵で見せる（動きは 1 秒ぶん進めた所）
        let out = fx.apply(EffectStack(effects: [e]), to: blank, key: "thumb", cb: cb, now: 1)
        cb.commit()
        cb.waitUntilCompleted()
        guard out !== blank else { return nil }
        var px = [UInt8](repeating: 0, count: size.w * size.h * 4)
        out.getBytes(&px, bytesPerRow: size.w * 4, from: MTLRegionMake2D(0, 0, size.w, size.h), mipmapLevel: 0)
        // 透明な所は市松模様にして、透明だと分かるように
        for y in 0..<size.h {
            for x in 0..<size.w {
                let i = (y * size.w + x) * 4
                let a = Double(px[i + 3]) / 255
                let bg: Double = ((x / 8 + y / 8) % 2 == 0) ? 40 : 60
                for c in 0..<3 { px[i + c] = UInt8(min(Double(px[i + c]) + bg * (1 - a), 255)) }
                px[i + 3] = 255
                px.swapAt(i, i + 2)   // BGRA → RGBA
            }
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size.w, pixelsHigh: size.h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: size.w * 4, bitsPerPixel: 32) else { return nil }
        px.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, px.count) }
        let img = NSImage(size: NSSize(width: size.w, height: size.h))
        img.addRepresentation(rep)
        return img
    }
}
