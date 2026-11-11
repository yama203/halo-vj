import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

// 出力のスナップショット：今出ている絵（コンポジションの合成。マッピング・出力ごとの切り出しの前、
// マスターの明るさ・ブラックアウトの前）を 1 枚、PNG にして録画と同じフォルダに保存する。
// 「クリップにする」では、さらに空いているスロットに静止画のクリップとして置く。
// 絵は描画スレッドにしか無いので、Engine に「次のコマで 1 枚ほしい」と頼む。描画スレッドは、録画と同じ描き方で
// 別のテクスチャに写して、GPU が終わったら読み出す（描画スレッドは待たない）。PNG に書くのは別のキューで。

/// 次のコマの絵の頼み（描画スレッドへ渡す）
struct SnapshotRequest {
    let id = UUID()
    /// 書き出す場所
    let url: URL
    /// 書き終わった（メインスレッドで）。書けなければ false
    let done: (Bool) -> Void
}

enum Snapshot {
    private static let writeQueue = DispatchQueue(label: "VJPlayer.snapshot", qos: .userInitiated)
    /// 描画スレッドが絵を取りに来なかったときに、あきらめるまでの秒数
    static let timeout = 3.0

    /// 描画スレッドから：合成の絵（無ければ黒）を width × height の 8 ビットの絵にして PNG に書く
    static func capture(_ composite: MTLTexture?, width: Int, height: Int, request: SnapshotRequest) {
        let ctx = MetalContext.shared
        let w = max(width, 1), h = max(height, 1)
        let rowBytes = w * 4
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .private
        guard let tex = ctx.device.makeTexture(descriptor: td),
              let buf = ctx.device.makeBuffer(length: rowBytes * h, options: .storageModeShared),
              let cb = ctx.queue.makeCommandBuffer() else {
            DispatchQueue.main.async { request.done(false) }
            return
        }
        // 録画と同じ描き方（黒の上に置いて、色はそのまま 8 ビットへ。録画したコマと同じ色になる）。
        // マスターの明るさ・ブラックアウトはかけない
        RenderLoop.shared.drawComposite(composite, into: tex, master: 1, fit: matrix_identity_float3x3, cb: cb)
        guard let blit = cb.makeBlitCommandEncoder() else {
            DispatchQueue.main.async { request.done(false) }
            return
        }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * h)
        blit.endEncoding()
        cb.addCompletedHandler { cb in
            _ = tex
            guard cb.status == .completed else {
                DispatchQueue.main.async { request.done(false) }
                return
            }
            // 読み出しは GPU が終わったここで。PNG にするのは別のキューで
            let data = Data(bytes: buf.contents(), count: rowBytes * h)
            writeQueue.async {
                let ok = writePNG(data, width: w, height: h, rowBytes: rowBytes, to: request.url)
                DispatchQueue.main.async { request.done(ok) }
            }
        }
        cb.commit()
    }

    /// BGRA の 8 ビットの絵を、sRGB・アルファなしの PNG に書く
    static func writePNG(_ data: Data, width: Int, height: Int, rowBytes: Int, to url: URL) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                space: space,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                         | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}

/// スナップショットの結果
struct SnapshotResult {
    /// 保存した PNG（保存できなければ nil）
    var url: URL?
    /// クリップとして置いたスロット（置かなかった・空きが無ければ nil）
    var slot: Int?
}

extension Engine {
    /// 今の絵を PNG で保存する。asClip なら、空いているスロットに静止画のクリップとしても置く（再生はしない）。
    /// 取り始めたら true。取っている途中（2 回目）・保存先が作れないときは false。
    /// folder を渡すとそこに保存する（テスト用。ふだんは録画の保存先）。done は終わったら（メインスレッド）
    @discardableResult
    func takeSnapshot(asClip: Bool = false, folder: URL? = nil, done: ((SnapshotResult) -> Void)? = nil) -> Bool {
        guard !snapshotBusy else { return false }
        guard let url = Recorder.shared.newFileURL(ext: "png", in: folder) else { return false }
        snapshotBusy = true
        let req = SnapshotRequest(url: url) { [weak self] ok in
            self?.finishSnapshot(ok: ok, url: url, asClip: asClip, done: done)
        }
        guard requestSnapshot(req) else {
            snapshotBusy = false
            return false
        }
        // 描画が止まっていて、絵を取りに来なかったときはあきらめる
        DispatchQueue.main.asyncAfter(deadline: .now() + Snapshot.timeout) { [weak self] in
            guard let self, self.cancelSnapshotRequest(req.id) else { return }
            self.finishSnapshot(ok: false, url: url, asClip: asClip, done: done)
        }
        return true
    }

    private func finishSnapshot(ok: Bool, url: URL, asClip: Bool, done: ((SnapshotResult) -> Void)?) {
        snapshotBusy = false
        guard ok else {
            try? FileManager.default.removeItem(at: url)
            Recorder.shared.noteSaved(nil, error: L("今の絵を保存できませんでした"))
            done?(SnapshotResult())
            return
        }
        var slot: Int?
        if asClip {
            slot = placeSnapshotClip(url)
            Recorder.shared.noteSaved(url, error: slot == nil ? L("空いているスロットが無いので、静止画の保存だけしました") : nil)
        } else {
            Recorder.shared.noteSaved(url)
        }
        done?(SnapshotResult(url: url, slot: slot))
    }

    /// 選んでいるレイヤー（空きが無ければ、いちばん上の空きのあるレイヤー）の、いちばん左の空いているスロットに
    /// 静止画のクリップを置く。1 回の操作として元に戻せる。空きが無ければ nil
    private func placeSnapshotClip(_ url: URL) -> Int? {
        let deck = currentDeck
        func free(_ r: Int) -> Int? {
            guard layers.indices.contains(r), !layers[r].isAdjustment else { return nil }
            return (0..<columns).map { slotIndex(deck: deck, layer: r, column: $0) }
                .first { slots.indices.contains($0) && slots[$0] == nil }
        }
        guard let i = free(selectedLayer) ?? layers.indices.lazy.compactMap(free).first else { return nil }
        // それまでの変更とまとめないように、置く前と置いた後で区切る
        commitUndoStep()
        setSlot(i, ClipSlot(url: url))
        scheduleSave()
        commitUndoStep()
        return i
    }
}
