import AVFoundation
import CoreVideo
import Metal

// HAP コーデック（VJ でよく使う、GPU でそのまま読める軽い動画）。AVFoundation では読み解けないので、
// 動画のファイルからは圧縮されたままの中身を取り出し、ここで Snappy をほどいて、BC（DXT）のテクスチャとして GPU に渡し、
// GPU で BGRA の絵（CVPixelBuffer）にする。あとは今までの動画と同じ流れ（再生・スクラブ・速度・範囲）で使える。
// 種類：Hap（DXT1）・Hap Alpha（DXT5）・Hap Q（YCoCg DXT5）・Hap Q Alpha（YCoCg DXT5 ＋ アルファ BC4）・Hap R（BC7）

enum Hap {
    static let codecs: Set<FourCharCode> = ["Hap1", "Hap5", "HapY", "HapM", "HapA", "Hap7"].map(fourCC).reduce(into: []) { $0.insert($1) }

    static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// 動画の映像が HAP か
    static func isHap(_ track: AVAssetTrack) -> Bool {
        guard let fd = (track.formatDescriptions as? [CMFormatDescription])?.first else { return false }
        return codecs.contains(CMFormatDescriptionGetMediaSubType(fd))
    }

    /// テクスチャの形式
    enum Format: UInt8 {
        case dxt1 = 0x0B, dxt5 = 0x0E, ycocg = 0x0F, alphaBC4 = 0x01, bc7 = 0x0C
        var pixelFormat: MTLPixelFormat {
            switch self {
            case .dxt1: .bc1_rgba
            case .dxt5, .ycocg: .bc3_rgba
            case .alphaBC4: .bc4_rUnorm
            case .bc7: .bc7_rgbaUnorm
            }
        }
        /// 4×4 の 1 ブロックのバイト数
        var blockBytes: Int { self == .dxt1 || self == .alphaBC4 ? 8 : 16 }
    }

    struct Texture {
        var format: Format
        var data: [UInt8]
    }

    enum DecodeError: Error { case bad }

    // MARK: 中身を読む

    /// 1 コマの中身から、テクスチャ（Hap Q Alpha は 2 つ）を取り出す
    static func decodeFrame(_ b: [UInt8]) throws -> [Texture] {
        let (type, start, size) = try header(b, 0)
        guard start + size <= b.count else { throw DecodeError.bad }
        if type == 0x0D {
            // いくつかの絵（Hap Q Alpha）：中に、それぞれの区切りが並ぶ
            var out: [Texture] = []
            var i = start
            while i < start + size {
                let (t, s, n) = try header(b, i)
                guard s + n <= b.count else { throw DecodeError.bad }
                out.append(try texture(type: t, Array(b[s..<s + n])))
                i = s + n
            }
            return out
        }
        return [try texture(type: type, Array(b[start..<start + size]))]
    }

    /// 区切りの頭：大きさ（3 バイト、0 なら続く 4 バイト）と種類（1 バイト）
    static func header(_ b: [UInt8], _ i: Int) throws -> (type: UInt8, start: Int, size: Int) {
        guard i + 4 <= b.count else { throw DecodeError.bad }
        var size = Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16
        let type = b[i + 3]
        var start = i + 4
        if size == 0 {
            guard i + 8 <= b.count else { throw DecodeError.bad }
            size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
            start = i + 8
        }
        return (type, start, size)
    }

    private static func texture(type: UInt8, _ payload: [UInt8]) throws -> Texture {
        guard let fmt = Format(rawValue: type & 0x0F) else { throw DecodeError.bad }
        let data: [UInt8]
        switch type >> 4 {
        case 0xA: data = payload
        case 0xB: data = try snappy(payload)
        case 0xC: data = try chunked(payload)
        default: throw DecodeError.bad
        }
        return Texture(format: fmt, data: data)
    }

    /// 分けて圧縮したもの：はじめに「ほどき方」の区切り（中に、かたまりごとの圧縮のしかた・大きさ・場所の表）、そのあとに中身
    private static func chunked(_ b: [UInt8]) throws -> [UInt8] {
        let (t, s, n) = try header(b, 0)
        guard t == 0x01, s + n <= b.count else { throw DecodeError.bad }
        var comps: [UInt8] = [], sizes: [Int] = [], offsets: [Int]? = nil
        var i = s
        while i < s + n {
            let (tt, ss, nn) = try header(b, i)
            guard ss + nn <= b.count else { throw DecodeError.bad }
            switch tt {
            case 0x02: comps = Array(b[ss..<ss + nn])
            // 表は 4 バイトずつ（半端な残りは読まない）
            case 0x03: sizes = stride(from: ss, through: ss + nn - 4, by: 4).map { le32(b, $0) }
            case 0x04: offsets = stride(from: ss, through: ss + nn - 4, by: 4).map { le32(b, $0) }
            default: break
            }
            i = ss + nn
        }
        guard comps.count == sizes.count, offsets.map({ $0.count >= sizes.count }) ?? true else { throw DecodeError.bad }
        let base = s + n
        var out: [UInt8] = []
        var pos = base
        for k in 0..<sizes.count {
            let o = offsets.map { base + $0[k] } ?? pos
            guard o >= 0, sizes[k] >= 0, o + sizes[k] <= b.count else { throw DecodeError.bad }
            let piece = Array(b[o..<o + sizes[k]])
            out += comps[k] == 0x0B ? try snappy(piece) : piece
            pos = o + sizes[k]
        }
        return out
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    /// Snappy をほどく
    static func snappy(_ b: [UInt8]) throws -> [UInt8] {
        var i = 0
        var len = 0, shift = 0
        while true {
            guard i < b.count else { throw DecodeError.bad }
            let c = b[i]; i += 1
            len |= Int(c & 0x7F) << shift
            if c & 0x80 == 0 { break }
            shift += 7
            guard shift < 35 else { throw DecodeError.bad }
        }
        // ほどいた大きさ：1 コマとしてありえない大きさ（壊れたファイル）は読まない
        guard len <= 256 << 20 else { throw DecodeError.bad }
        var out = [UInt8](); out.reserveCapacity(len)
        while i < b.count {
            let tag = b[i]; i += 1
            switch tag & 3 {
            case 0:
                var n = Int(tag >> 2)
                if n >= 60 {
                    let extra = n - 59
                    guard i + extra <= b.count else { throw DecodeError.bad }
                    n = 0
                    for k in 0..<extra { n |= Int(b[i + k]) << (8 * k) }
                    i += extra
                }
                n += 1
                guard i + n <= b.count else { throw DecodeError.bad }
                out.append(contentsOf: b[i..<i + n]); i += n
            default:
                let n: Int, off: Int
                if tag & 3 == 1 {
                    guard i < b.count else { throw DecodeError.bad }
                    n = 4 + Int((tag >> 2) & 7); off = Int(tag >> 5) << 8 | Int(b[i]); i += 1
                } else if tag & 3 == 2 {
                    guard i + 2 <= b.count else { throw DecodeError.bad }
                    n = Int(tag >> 2) + 1; off = Int(b[i]) | Int(b[i + 1]) << 8; i += 2
                } else {
                    guard i + 4 <= b.count else { throw DecodeError.bad }
                    n = Int(tag >> 2) + 1; off = le32(b, i); i += 4
                }
                guard off > 0, off <= out.count else { throw DecodeError.bad }
                // 重なっていてもよいので 1 バイトずつ
                let s = out.count - off
                for k in 0..<n { out.append(out[s + k]) }
            }
        }
        guard out.count == len else { throw DecodeError.bad }
        return out
    }
}

private let hapShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VO { float4 pos [[position]]; float2 uv; };
vertex VO hap_v(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o; o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0); o.uv = c; return o;
}
// a = 種類（0 そのまま / 1 YCoCg / 2 YCoCg ＋ アルファ）, 使う範囲（幅・高さの割合。4 の倍数に足した分を切る）
fragment float4 hap_f(VO in [[stage_in]], constant float4& a [[buffer(0)]], texture2d<float> t [[texture(0)]],
                      texture2d<float> al [[texture(1)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float2 uv = in.uv * a.yz;
    float4 c = t.sample(s, uv);
    int m = int(a.x + 0.5);
    if (m >= 1) {
        // Hap Q：色の差を、ブロックごとの倍率（青）で戻す
        float scale = c.b * (255.0 / 8.0) + 1.0;
        float co = (c.r - 0.5 * 256.0 / 255.0) / scale;
        float cg = (c.g - 0.5 * 256.0 / 255.0) / scale;
        float y = c.a;
        c = float4(saturate(float3(y + co - cg, y + cg, y - co - cg)), 1.0);
        if (m == 2) c.a = al.sample(s, uv).r;
    }
    return c;
}
"""

/// HAP の 1 コマを、BGRA の CVPixelBuffer にする（デコードのスレッドで使う）
final class HapDecoder {
    let width: Int, height: Int
    private let device = MetalContext.shared.device
    private let queue: MTLCommandQueue
    private let pipe: MTLRenderPipelineState
    private var pool: CVPixelBufferPool?
    private var cache: CVMetalTextureCache?
    private var textures: [MTLPixelFormat: MTLTexture] = [:]

    /// キューとパイプラインは全部のデコーダーで 1 つ（シェーダーの組み立ては重いので 1 回だけ。
    /// static let は初めて使うときに 1 回だけ作られ、いくつかのスレッドから同時に来ても安全）
    private static let shared: (queue: MTLCommandQueue, pipe: MTLRenderPipelineState)? = {
        let device = MetalContext.shared.device
        guard let q = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: hapShaderSource, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "hap_v")
        d.fragmentFunction = lib.makeFunction(name: "hap_f")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        return (q, p)
    }()

    init?(width: Int, height: Int) {
        guard width > 0, height > 0, let shared = Self.shared else { return nil }
        self.width = width; self.height = height
        queue = shared.queue
        pipe = shared.pipe
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// 動画のサンプル（圧縮されたままの HAP）から
    func decode(_ sb: CMSampleBuffer) -> CVPixelBuffer? {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let n = CMBlockBufferGetDataLength(bb)
        var bytes = [UInt8](repeating: 0, count: n)
        guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: &bytes) == noErr else { return nil }
        return decode(bytes)
    }

    func decode(_ bytes: [UInt8]) -> CVPixelBuffer? {
        guard let texs = try? Hap.decodeFrame(bytes), let first = texs.first,
              let pool, let cache else { return nil }
        let bw = (width + 3) / 4, bh = (height + 3) / 4
        func upload(_ t: Hap.Texture) -> MTLTexture? {
            let need = bw * bh * t.format.blockBytes
            guard t.data.count >= need else { return nil }
            let pf = t.format.pixelFormat
            if textures[pf] == nil {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: bw * 4, height: bh * 4, mipmapped: false)
                td.usage = [.shaderRead]
                td.storageMode = .shared
                textures[pf] = device.makeTexture(descriptor: td)
            }
            guard let tex = textures[pf] else { return nil }
            t.data.withUnsafeBytes {
                tex.replace(region: MTLRegionMake2D(0, 0, bw * 4, bh * 4), mipmapLevel: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: bw * t.format.blockBytes)
            }
            return tex
        }
        guard let main = upload(first) else { return nil }
        let alpha = texs.count > 1 ? upload(texs[1]) : nil
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { return nil }
        var cvt: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, width, height, 0, &cvt)
        guard let cvt, let dst = CVMetalTextureGetTexture(cvt), let cb = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        var a = SIMD4<Float>(first.format == .ycocg ? (alpha != nil ? 2 : 1) : 0,
                             Float(width) / Float(bw * 4), Float(height) / Float(bh * 4), 0)
        enc.setRenderPipelineState(pipe)
        enc.setFragmentBytes(&a, length: 16, index: 0)
        enc.setFragmentTexture(main, index: 0)
        enc.setFragmentTexture(alpha ?? main, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        // 次のコマでテクスチャを書き換えるので、ここで待つ（デコードのスレッドなので画面は止まらない）
        cb.waitUntilCompleted()
        _ = cvt
        return pb
    }
}
