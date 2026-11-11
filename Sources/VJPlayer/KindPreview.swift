import AppKit
import Metal
import QuartzCore
import SwiftUI

/// エフェクト・ジェネレーターの「見本」。カーソルを合わせた間だけ、小さく動かして見せる。
/// 描くのは描画スレッド（RenderLoop の毎コマ）。作業テクスチャなどを本番の描画と取り合わないように、同じスレッドで順に描く。
/// エフェクトは、見本の絵（夕焼け・動く玉・文字・バー）にかけて見せる
final class KindPreview: ObservableObject {
    static let shared = KindPreview()

    /// いま見せている絵（メインスレッドで更新）
    @Published private(set) var image: CGImage?
    /// いま見せているもの
    @Published private(set) var kind: EffectKind?

    /// 見本の大きさ（ピクセル）
    static let width = 512, height = 288
    /// 見本のコマの速さ
    private static let fps = 30.0

    // メインと描画スレッドの両方が触るもの（lock で守る）
    private let lock = NSLock()
    private var request: (kind: EffectKind, serial: Int)?
    private var serial = 0
    private var inFlight = false
    /// 最後に描けた絵（開発用の書き出しで使う）
    private var lastFrame: CGImage?

    // 描画スレッドだけが触るもの
    private var current: (kind: EffectKind, serial: Int)?
    private var processor: EffectProcessor?
    private var effect: Effect?
    private var start = 0.0
    private var last = 0.0
    private var source: MTLTexture?
    private var blank: MTLTexture?
    private var sourceBytes = [UInt8]()

    /// 外の映像を取り込むもの（見本では動かさない。カメラが勝手に点くので）
    static func isLive(_ k: EffectKind) -> Bool { [.syphonIn, .camera, .ndiIn].contains(k) }

    /// k を見せ始める（nil で止める）。メインスレッドから
    func show(_ k: EffectKind?) {
        guard k != kind else { return }
        kind = k
        image = nil
        lock.withLock {
            serial += 1
            request = k.map { ($0, serial) }
        }
    }

    // MARK: - 描画スレッド

    /// RenderLoop が毎コマ呼ぶ。見せているものがあれば 1 コマ描く
    func renderIfNeeded(now: Double) {
        let (req, busy) = lock.withLock { (request, inFlight) }
        guard let req, !Self.isLive(req.kind) else {
            if current != nil { current = nil; processor = nil; effect = nil }
            return
        }
        if current?.serial != req.serial {
            current = req
            processor = { let p = EffectProcessor(); p.storageMode = .shared; return p }()
            effect = Effect(kind: req.kind)
            start = now
            last = 0
        }
        guard !busy, now - last >= 1 / Self.fps - 0.004, let processor, let effect else { return }
        last = now
        let ctx = MetalContext.shared
        guard let cb = ctx.queue.makeCommandBuffer(), let blank = blank ?? makeTexture(), let src = source ?? makeTexture() else { return }
        self.blank = blank
        self.source = src
        let t = now - start
        var input = blank
        if !req.kind.isGenerator {
            // ポスタライズ時間は描く側では効かないので、見本の絵の方をその速さで止める
            var st = t
            if req.kind == .posterizeTime {
                let f = max(effect.value(0, at: now, beat: BeatClock(), origin: start), 1)
                st = (t * f).rounded(.down) / f
            }
            drawSample(into: src, t: st)
            input = src
        }
        let out = processor.apply(EffectStack(effects: [effect], origin: start), to: input, key: "kindPreview", cb: cb, now: now)
        lock.withLock { inFlight = true }
        let serial = req.serial
        let shows = req.kind.isGenerator
        cb.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let img = out.storageMode == .private ? nil : Self.cgImage(out, overBlack: shows)
            self.lock.withLock { self.inFlight = false; self.lastFrame = img }
            DispatchQueue.main.async {
                guard self.lock.withLock({ self.request?.serial == serial }) else { return }
                self.image = img
            }
        }
        cb.commit()
    }

    /// 開発用：k を secs 秒ぶん描いて、最後のコマを返す（描画ループを使わずに、ここで進める）
    func renderForSheet(_ k: EffectKind, secs: Double) -> CGImage? {
        lock.withLock { serial += 1; request = (k, serial); lastFrame = nil }
        let t0 = CACurrentMediaTime()
        var t = t0
        while t - t0 < secs {
            renderIfNeeded(now: t)
            while lock.withLock({ inFlight }) { usleep(500) }
            t += 1 / Self.fps
        }
        return lock.withLock { lastFrame }
    }

    /// 開発用：描いた絵を、今見せている絵にする（メインスレッドで）
    func adoptForSheet(_ k: EffectKind, _ img: CGImage?) {
        kind = k
        image = img
    }

    private func makeTexture() -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.width, height: Self.height,
                                                          mipmapped: false)
        td.usage = [.shaderRead]
        td.storageMode = .shared
        let t = MetalContext.shared.device.makeTexture(descriptor: td)
        if let t {
            let z = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
            t.replace(region: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0, withBytes: z,
                      bytesPerRow: Self.width * 4)
        }
        return t
    }

    /// テクスチャを CGImage に（ジェネレーターは透明な所を黒に）
    private static func cgImage(_ tex: MTLTexture, overBlack: Bool) -> CGImage? {
        let w = tex.width, h = tex.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        if overBlack { for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 } }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// エフェクトをかける見本の絵（夕焼けの空・太陽・動く 3 つの玉・文字・音のバー）
    private func drawSample(into tex: MTLTexture, t: Double) {
        let w = Self.width, h = Self.height
        if sourceBytes.count != w * h * 4 { sourceBytes = [UInt8](repeating: 0, count: w * h * 4) }
        sourceBytes.withUnsafeMutableBytes { buf in
            guard let g = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            let W = CGFloat(w), H = CGFloat(h)
            // CGContext は下が 0。上下を返して、上を 0 にして描く
            g.translateBy(x: 0, y: H)
            g.scaleBy(x: 1, y: -1)
            let space = CGColorSpaceCreateDeviceRGB()
            func c(_ r: CGFloat, _ gg: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: gg, blue: b, alpha: a) }
            // 空
            if let sky = CGGradient(colorsSpace: space, colors: [c(0.08, 0.07, 0.25), c(0.42, 0.17, 0.55), c(0.95, 0.52, 0.30)] as CFArray,
                                    locations: [0, 0.55, 1]) {
                g.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: H * 0.72), options: [.drawsAfterEndLocation])
            }
            // 太陽
            let sun = CGPoint(x: W * 0.5, y: H * 0.62)
            if let sg = CGGradient(colorsSpace: space, colors: [c(1, 0.93, 0.45), c(1, 0.45, 0.35)] as CFArray, locations: [0, 1]) {
                g.saveGState()
                g.addEllipse(in: CGRect(x: sun.x - H * 0.26, y: sun.y - H * 0.26, width: H * 0.52, height: H * 0.52))
                g.clip()
                g.drawLinearGradient(sg, start: CGPoint(x: 0, y: sun.y - H * 0.26), end: CGPoint(x: 0, y: sun.y + H * 0.1), options: [])
                g.restoreGState()
            }
            // 地面
            g.setFillColor(c(0.06, 0.03, 0.12))
            g.fill(CGRect(x: 0, y: H * 0.72, width: W, height: H * 0.28))
            // 音のバー（地面の上で上下する）
            let bars = 16
            let bw = W / CGFloat(bars)
            for i in 0..<bars {
                let d = Double(i)
                let v = 0.5 + 0.5 * sin(t * 3.1 + d * 0.7) * cos(t * 1.3 + d * 0.31)
                let bh = H * 0.05 + H * 0.2 * CGFloat(v)
                g.setFillColor(c(0.2 + 0.05 * CGFloat(i % 4), 0.9 - 0.04 * CGFloat(i), 1, 0.95))
                g.fill(CGRect(x: CGFloat(i) * bw + 2, y: H - bh, width: bw - 4, height: bh))
            }
            // 動く玉
            let balls: [(CGColor, Double, Double, Double)] = [(c(0.2, 1, 0.95), 0.9, 1.3, 0), (c(1, 0.25, 0.75), 1.2, 0.8, 2),
                                                              (c(0.65, 1, 0.25), 0.7, 1.1, 4)]
            for (col, fx, fy, ph) in balls {
                let x = W * (0.5 + 0.38 * CGFloat(sin(t * fx + ph)))
                let y = H * (0.42 + 0.26 * CGFloat(sin(t * fy + ph * 1.7)))
                let r = H * 0.075
                g.setFillColor(col)
                g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            // 文字
            let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, H * 0.2, nil)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c(1, 1, 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "HALO", attributes: attrs))
            let bounds = CTLineGetImageBounds(line, g)
            g.saveGState()
            // 文字は上下が逆になるので、もう一度返す
            g.textMatrix = .identity
            g.translateBy(x: W * 0.5 - bounds.width / 2 - bounds.minX, y: H * 0.3)
            g.scaleBy(x: 1, y: -1)
            g.textPosition = .zero
            CTLineDraw(line, g)
            g.restoreGState()
        }
        sourceBytes.withUnsafeBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: w * 4)
        }
    }
}

// MARK: - 見せ方

/// 見本の中身（絵・名前・説明）
struct KindPreviewCard: View {
    @ObservedObject var model = KindPreview.shared
    let kind: EffectKind
    var width: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if KindPreview.isLive(kind) {
                    VStack(spacing: 6) {
                        Image(systemName: kind.icon).font(.system(size: 28)).foregroundStyle(.teal)
                        Text(L("ほかのアプリ・機器の映像を取り込みます")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else if let img = model.kind == kind ? model.image : nil {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
            HStack(spacing: 6) {
                Image(systemName: kind.icon).foregroundStyle(kind.isGenerator ? Color.teal : Color.purple)
                Text(kind.label).font(.system(size: 13, weight: .semibold))
            }
            Text(kind.help).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if kind == .audioScope {
                Text(L("音が鳴っていると動きます")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if !kind.isGenerator && !KindPreview.isLive(kind) {
                Text(L("見本の絵にかけたところ（初めの値）")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// カーソルを合わせたときに、そばに浮かべる見本の窓（クリックは素通り）
final class KindPreviewPanel {
    static let shared = KindPreviewPanel()
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var showing: EffectKind?
    /// 画面確認用：アプリが前に無くても消さない
    var keepWhenInactive = false

    /// 少し待ってから出す（もう出ていれば、すぐ差し替える）
    func hover(_ k: EffectKind) {
        pending?.cancel()
        if showing != nil {
            present(k)
            return
        }
        let w = DispatchWorkItem { [weak self] in self?.present(k) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// カーソルが外れた（ほかのものに乗ったら、そちらが hover を呼ぶので、少し待ってから消す）
    func leave(_ k: EffectKind) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.showing == k else { return }
            self.hide()
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    func hide() {
        pending?.cancel()
        showing = nil
        panel?.orderOut(nil)
        KindPreview.shared.show(nil)
    }

    private func present(_ k: EffectKind) {
        showing = k
        KindPreview.shared.show(k)
        let view = KindPreviewCard(kind: k).padding(10).environment(\.colorScheme, .dark)
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 308, height: 260),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.ignoresMouseEvents = true
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = true
            p.backgroundColor = .clear
            p.isOpaque = false
            return p
        }()
        let host = NSHostingView(rootView: AnyView(view.background(
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)).overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1))))))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        p.contentView = host
        // カーソルの右下に。画面からはみ出すなら反対側へ
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(m) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var o = NSPoint(x: m.x + 18, y: m.y - 18 - size.height)
        if o.x + size.width > screen.maxX { o.x = m.x - 18 - size.width }
        if o.y < screen.minY { o.y = m.y + 18 }
        o.x = max(screen.minX, min(o.x, screen.maxX - size.width))
        o.y = max(screen.minY, min(o.y, screen.maxY - size.height))
        p.hidesOnDeactivate = !keepWhenInactive
        p.setFrame(NSRect(origin: o, size: size), display: true)
        panel = p
        p.orderFrontRegardless()
    }
}

extension View {
    /// カーソルを合わせると、そばに見本を出す
    func kindPreviewOnHover(_ k: EffectKind) -> some View {
        onHover { inside in
            if inside { KindPreviewPanel.shared.hover(k) } else { KindPreviewPanel.shared.leave(k) }
        }
        .onDisappear { KindPreviewPanel.shared.leave(k) }
    }
}

extension SelfTest {
    /// 開発用：見本を全部 1 枚に並べて書き出す  VJPlayer --kind-sheet out.png [秒] [effects|generators|名前,名前]
    static func kindSheet(path: String, secs: Double, which: String) {
        let all = AddEffectMenuItems.groups.flatMap(\.1) + GeneratorCategory.allCases.flatMap(\.kinds)
        let kinds: [EffectKind] = switch which {
        case "effects": all.filter { !$0.isGenerator }
        case "generators": all.filter(\.isGenerator)
        case "all": all
        default: which.split(separator: ",").compactMap { EffectKind(rawValue: String($0)) }
        }
        let list = kinds.filter { !KindPreview.isLive($0) }
        let cw = 256, ch = 144, lh = 18, cols = 6
        let rows = (list.count + cols - 1) / cols
        let W = cw * cols, H = (ch + lh) * rows
        guard let g = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        g.setFillColor(CGColor(gray: 0.12, alpha: 1)); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, k) in list.enumerated() {
            let x = (i % cols) * cw, y = H - (i / cols + 1) * (ch + lh)
            if let img = KindPreview.shared.renderForSheet(k, secs: secs) {
                g.draw(img, in: CGRect(x: x, y: y + lh, width: cw, height: ch))
            }
            let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, 11, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: k.label, attributes:
                [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 1)]))
            g.textPosition = CGPoint(x: x + 4, y: y + 4)
            CTLineDraw(line, g)
        }
        if let img = g.makeImage() {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("書き出しました: \(path)（\(list.count) 個）")
        }
    }
}
