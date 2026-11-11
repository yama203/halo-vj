import AppKit
import QuartzCore
import CoreText
import Metal

// テキストのジェネレーター。文字は CoreText で白く描いてテクスチャにし（中身が変わったときだけ描き直す）、
// 色・流れ・敷き詰め・波・グリッチはシェーダーで付ける。

/// テキストの見た目の選択肢
enum TextLook {
    static let defaultText = "HALO VJ"

    static let motions = [L("止める"), L("横に流れる"), L("縦に流れる"), L("敷き詰め"), L("1 文字ずつ"), L("拍で弾む")]
    /// 行の切り替えの間隔（拍。0 = 全部の行を一度に出す）
    static let switchBeats: [Double] = [0, 1, 2, 4, 8]

    struct Font {
        let label: String
        let make: (CGFloat) -> CTFont
    }

    private static func named(_ name: String, fallback: NSFont.Weight = .bold) -> (CGFloat) -> CTFont {
        { size in
            let f = CTFontCreateWithName(name as CFString, size, nil)
            // 見つからないと別の書体になる。そのときはシステムの書体にする
            if (CTFontCopyPostScriptName(f) as String) == name { return f }
            return NSFont.systemFont(ofSize: size, weight: fallback) as CTFont
        }
    }

    /// フォント（日本語の無い書体でも、日本語はシステムが自動で別の書体に回す）
    static let fonts: [Font] = [
        Font(label: L("ゴシック 極太"), make: named("HiraginoSans-W8", fallback: .black)),
        Font(label: L("ゴシック 細"), make: named("HiraginoSans-W2", fallback: .light)),
        Font(label: L("明朝"), make: named("HiraMinProN-W6")),
        Font(label: L("丸ゴシック"), make: named("HiraMaruProN-W4")),
        Font(label: L("SF 極太"), make: { NSFont.systemFont(ofSize: $0, weight: .black) as CTFont }),
        Font(label: L("コンデンス"), make: named("HelveticaNeue-CondensedBlack", fallback: .heavy)),
        Font(label: "Futura", make: named("Futura-Bold")),
        Font(label: "Didot", make: named("Didot-Bold")),
        Font(label: L("等幅"), make: { NSFont.monospacedSystemFont(ofSize: $0, weight: .bold) as CTFont }),
        Font(label: L("筆記体"), make: named("SnellRoundhand-Black")),
    ]

    static func font(_ i: Int, size: CGFloat) -> CTFont {
        fonts[min(max(i, 0), fonts.count - 1)].make(size)
    }

    /// 数字の幅をそろえた書体（時計の数字が変わっても横にぶれない）
    static func tabular(_ f: CTFont) -> CTFont {
        let feature: [CFString: Any] = [kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                                        kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]
        let d = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: [feature]] as CFDictionary)
        return CTFontCreateCopyWithAttributes(f, 0, nil, d)
    }

    /// 1 行の高さ（フォントの大きさに対する比）
    static let lineHeight: CGFloat = 1.25
    /// まわりの余白（1 行の高さに対する比。縁取り・筆記体のはみ出し用）
    static let pad: CGFloat = 0.3
}

/// ある時点のテキストの状態（どの行・何文字まで・弾み具合）
struct TextFrame: Equatable {
    var text: String
    /// 見せる文字数（nil なら全部）
    var visible: Int?
    /// 拍で弾む大きさ（1 = そのまま）
    var punch: Double

    static func at(_ e: Effect, t: Double, beat: BeatClock, origin: Double) -> TextFrame {
        if e.kind == .clock {
            // 時計：時刻（t の時点の壁の時計）と、トリガーしてからの秒から文字を決める
            let wall = Date(timeIntervalSinceNow: t - CACurrentMediaTime())
            let c = ClockText.at(e, wall: wall, elapsed: max(t - origin, 0))
            var f = TextFrame(text: c.text, visible: nil, punch: c.punch)
            if Int(e.value(0).rounded()) == 5 {
                let b = beat.beat(at: t)
                f.punch = max(f.punch, 1 + 0.3 * pow(1 - (b - floor(b)), 4))
            }
            return f
        }
        let lines = e.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let motion = Int(e.value(0).rounded())
        let si = min(max(Int(e.value(8).rounded()), 0), TextLook.switchBeats.count - 1)
        let every = TextLook.switchBeats[si]
        let b = beat.beat(at: t)
        var text = lines.joined(separator: "\n")
        // 切り替えの中のどこにいるか（0〜1）
        var phase: Double?
        if every > 0, !lines.isEmpty {
            let n = Int(floor(b / every))
            text = lines[((n % lines.count) + lines.count) % lines.count]
            phase = b / every - floor(b / every)
        }
        var visible: Int?
        if motion == 4 {
            let count = text.count
            if let phase {
                // 切り替えの前半で打ち終わって、後半は全部見せる
                visible = min(Int(ceil(phase / 0.6 * Double(count))), count)
            } else {
                // 1 秒に「速さ × 8」文字。打ち終わったら少し待って最初から
                let cps = max(abs(e.value(2, at: t, beat: beat, origin: origin)), 0.05) * 8
                let cycle = Double(count) + max(cps * 1.2, 4)
                let k = (max(t - origin, 0) * cps).truncatingRemainder(dividingBy: cycle)
                visible = min(Int(floor(k)) + 1, count)
            }
        }
        var punch = 1.0
        if motion == 5 {
            let f = b - floor(b)
            punch = 1 + 0.3 * pow(1 - f, 4)
        }
        return TextFrame(text: text, visible: visible, punch: punch)
    }
}

/// 文字を描いたテクスチャの使い回し（EffectProcessor ごとに 1 つ。同じスレッドからだけ使う）
final class TextRasterCache {
    struct Spec: Hashable {
        var text: String
        var visible: Int?
        var font: Int
        var tracking: Double
        var outline: Bool
        /// 数字の幅をそろえる（時計）
        var tabular = false
        /// フォントの大きさ（px）
        var px: Int
    }

    struct Raster {
        let texture: MTLTexture
        /// テクスチャの横 / 縦
        let aspect: Float
        /// テクスチャの高さが何行ぶんか（余白込み）
        let lines: Float
    }

    private var entries: [Spec: Raster] = [:]
    private var order: [Spec] = []
    /// 持っておく量の上限（バイト）。1 文字ずつ出すときは文字数ぶんのテクスチャを持つ
    private let budget = 160 << 20
    private var bytes = 0

    /// e の t の時点の文字（outHeight は出す絵の高さ）。ミップマップを作る処理は cb に積む
    func raster(_ e: Effect, frame: TextFrame, outHeight: Int, cb: MTLCommandBuffer) -> Raster? {
        guard !frame.text.isEmpty else { return nil }
        // 1 行の高さ（px）から決める。少し大きめに描いて、小さく見せる所はミップマップで縮める
        let maxScale = Int(e.value(0).rounded()) == 5 ? 1.3 : 1.0
        let linePx = e.value(1) * Double(outHeight) * maxScale
        let raw = linePx / Double(TextLook.lineHeight)
        // 大きさを動かしても毎回描き直さないように、とびとびの大きさにする
        var px = max(32, min(Int((raw / 32).rounded(.up)) * 32, 384))
        let spec0 = Spec(text: frame.text, visible: frame.visible, font: Int(e.value(6).rounded()),
                         tracking: (e.value(7) * 100).rounded() / 100, outline: e.value(9) > 0.5, tabular: e.kind == .clock, px: px)
        if let r = entries[spec0] { touch(spec0); return r }
        // 長すぎて横幅が大きくなりすぎるときは小さく描く
        var spec = spec0
        for _ in 0..<4 {
            let w = Self.measure(spec).width
            if w <= 8000 || px <= 16 { break }
            px = max(16, Int(Double(px) * 8000 / Double(w)))
            spec.px = px
        }
        guard let r = Self.draw(spec, cb: cb) else { return nil }
        entries[spec0] = r
        order.append(spec0)
        bytes += Self.size(r)
        while bytes > budget, order.count > 1 {
            if let old = entries.removeValue(forKey: order.removeFirst()) { bytes -= Self.size(old) }
        }
        return r
    }

    private static func size(_ r: Raster) -> Int { r.texture.width * r.texture.height * 4 * 4 / 3 }

    private func touch(_ s: Spec) {
        if let i = order.firstIndex(of: s) { order.remove(at: i); order.append(s) }
    }

    private static func attributed(_ s: Spec) -> NSAttributedString {
        let size = CGFloat(s.px)
        var font = TextLook.font(s.font, size: size)
        if s.tabular { font = TextLook.tabular(font) }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.minimumLineHeight = size * TextLook.lineHeight
        para.maximumLineHeight = size * TextLook.lineHeight
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
            .kern: s.tracking * Double(size),
        ]
        if s.outline {
            attrs[.strokeWidth] = 4.0   // フォントの大きさの 4%（プラスで線だけ）
            attrs[.strokeColor] = NSColor.white
        }
        let str = NSMutableAttributedString(string: s.text, attributes: attrs)
        if let v = s.visible, v < s.text.count {
            // まだ出していない文字は透明にする（並びは全部出したときと同じ所に）
            let start = s.text.index(s.text.startIndex, offsetBy: max(v, 0))
            let r = NSRange(start..<s.text.endIndex, in: s.text)
            str.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
            if s.outline { str.addAttribute(.strokeColor, value: NSColor.clear, range: r) }
        }
        return str
    }

    /// 描く大きさ（余白込み、px）と行数
    private static func measure(_ s: Spec) -> (width: Int, height: Int, lines: Int) {
        let lines = max(s.text.components(separatedBy: "\n").count, 1)
        let fs = CTFramesetterCreateWithAttributedString(attributed(s))
        let sz = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: 100_000, height: 100_000), nil)
        let lh = CGFloat(s.px) * TextLook.lineHeight
        let pad = lh * TextLook.pad
        return (Int(ceil(sz.width + pad * 2)), Int(ceil(lh * CGFloat(lines) + pad * 2)), lines)
    }

    private static func draw(_ s: Spec, cb: MTLCommandBuffer) -> Raster? {
        let (w, h, _) = measure(s)
        guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        let lh = CGFloat(s.px) * TextLook.lineHeight
        let pad = lh * TextLook.pad
        let bpr = w * 4
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        cg.clear(CGRect(x: 0, y: 0, width: w, height: h))
        cg.setShouldAntialias(true)
        cg.setShouldSmoothFonts(false)
        let fs = CTFramesetterCreateWithAttributedString(attributed(s))
        // 上の余白から下へ並べる（下は余白まで使えるようにして、最後の行が入りきらないことが無いように）
        let path = CGPath(rect: CGRect(x: pad, y: 0, width: CGFloat(w) - pad * 2, height: CGFloat(h) - pad), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, cg)
        guard let data = cg.data else { return nil }
        let levels = Int(floor(log2(Double(max(w, h))))) + 1
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
        td.usage = [.shaderRead]
        td.mipmapLevelCount = levels
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: td) else { return nil }
        // ビットマップのメモリは上の行から並んでいる（テクスチャと同じ向き）
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bpr)
        if levels > 1, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
        }
        return Raster(texture: tex, aspect: Float(w) / Float(h), lines: Float(CGFloat(h) / lh))
    }
}

/// 時計の文字（今の時刻・カウントダウン・タイマー・ストップウォッチ）
enum ClockText {
    static let modes = [L("今の時刻"), L("カウントダウン（時刻まで）"), L("タイマー"), L("ストップウォッチ")]
    static let formats = [L("自動"), L("時:分:秒"), L("時:分"), L("分:秒"), L("秒")]
    static let defaultFinish = "HAPPY NEW YEAR"

    /// 文字と、弾み（最後の 10 秒で 1 秒ごとに大きく）
    static func at(_ e: Effect, wall: Date, elapsed: Double) -> (text: String, punch: Double, remaining: Double?) {
        let mode = Int(e.value(12).rounded())
        let format = Int(e.value(13).rounded())
        let frac = Int(e.value(14).rounded())
        let v: Double
        var remaining: Double?
        switch mode {
        case 0:
            let cal = Calendar.current
            let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: wall)
            v = Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)) + Double(c.nanosecond ?? 0) / 1e9
        case 1:
            remaining = countdown(e, wall: wall)
            v = remaining!
        case 2:
            remaining = e.value(18) * 60 + e.value(19) - elapsed
            v = remaining!
        default:
            v = elapsed
        }
        if let r = remaining, r <= 0 {
            // 終わった：文字があればそれ、無ければ 0 のまま
            let fin = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (fin.isEmpty ? string(0, mode: mode, format: format, frac: frac) : e.text, 1, r)
        }
        var punch = 1.0
        if let r = remaining, r <= 10, e.value(20) > 0.5 {
            // 数字が変わった瞬間に大きく、すっと戻る
            // 表示は切り上げなので、数字が変わるのは r が整数を下回った時。そこからの経過で戻す
            let since = ceil(r) - r
            punch = 1 + 0.35 * pow(1 - since, 6)
        }
        return (string(v, mode: mode, format: format, frac: frac), punch, remaining)
    }

    /// 目標の時刻までの秒。過ぎてから 1 時間までは「終わった」（マイナス）、それより前に過ぎたなら次の日のその時刻まで
    static func countdown(_ e: Effect, wall: Date) -> Double {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: wall)
        c.hour = Int(e.value(15)); c.minute = Int(e.value(16)); c.second = Int(e.value(17))
        guard let target = cal.date(from: c) else { return 0 }
        var d = target.timeIntervalSince(wall)
        while d <= -3600 { d += 86400 }
        while d > 86400 - 3600 { d -= 86400 }
        return d
    }

    static func string(_ v: Double, mode: Int, format: Int, frac: Int) -> String {
        let counting = mode == 1 || mode == 2
        // 数えるときは切り上げ（「10」が 10〜9 秒のあいだ出る）。細かく出すときはそのまま
        let scale = frac == 2 ? 100.0 : frac == 1 ? 10.0 : 1.0
        var t = max(v, 0)
        t = counting ? ceil(t * scale - 1e-9) / scale : floor(t * scale + 1e-9) / scale
        let whole = Int(floor(t + 1e-9))
        let h = whole / 3600, m = (whole / 60) % 60, s = whole % 60
        let fracPart = frac == 0 ? "" : String(format: frac == 2 ? ".%02d" : ".%01d",
                                               Int(((t - Double(whole)) * scale).rounded()) % Int(scale))
        var f = format
        if f == 0 {
            if mode == 0 { f = 1 } else if counting && t <= 10 && frac == 0 { f = 4 } else { f = whole >= 3600 ? 1 : 3 }
        }
        switch f {
        case 1: return String(format: "%02d:%02d:%02d", mode == 0 ? h % 24 : h, m, s) + fracPart
        case 2: return String(format: "%02d:%02d", mode == 0 ? h % 24 : h, m)
        case 3: return String(format: "%02d:%02d", h * 60 + m, s) + fracPart
        default: return String(whole) + fracPart
        }
    }
}
