import AVFoundation

/// 動画を順にデコードして、数フレーム先まで溜めておくストリーム。
/// 専用スレッドでデコードし、描画側は「再生位置 p に表示すべきフレーム」を取り出す。
/// 逆再生用（reverse）は、後ろから数コマずつ区切って読み、逆順に並べて渡す。
final class FrameStream {
    struct Frame {
        let pts: Double
        let buffer: CVPixelBuffer
    }

    private let cond = NSCondition()
    private var frames: [Frame] = []
    private var cancelled = false
    private var finished = false
    /// 描画側が最後に要求した再生位置。デコーダーはこれより古いフレームを捨てて追いつく
    private var requestedPos = -Double.infinity
    private let capacity: Int
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    // 逆再生用
    let isReverse: Bool
    private var asset: AVAsset?
    private var track: AVAssetTrack?
    private var reverseStart = 0.0
    private var reverseLower = 0.0
    private var chunkLength = 0.1

    private static let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    /// start 秒から lower 秒へ向かって逆向きに読む。frameDuration はコマの長さ（区切りの大きさに使う）
    init(reverseAsset asset: AVAsset, track: AVAssetTrack, capacity: Int, start: Double, lower: Double,
         frameDuration: Double) {
        self.capacity = max(capacity, 2)
        isReverse = true
        self.asset = asset
        self.track = track
        reverseStart = start
        reverseLower = max(lower, 0)
        // 1 回に読むのは capacity - 2 コマ分（メモリを食いすぎないように）
        chunkLength = max(frameDuration, 1.0 / 120) * Double(max(self.capacity - 2, 2))
        requestedPos = .infinity
        let t = Thread { [self] in self.runReverse() }
        t.qualityOfService = .userInteractive
        t.name = "VJPlayer.decode.reverse"
        t.start()
    }

    /// start 秒の位置から読む（スクラブ用）。0 なら先頭から
    init(asset: AVAsset, track: AVAssetTrack, capacity: Int, start: Double = 0) throws {
        self.capacity = max(capacity, 2)
        isReverse = false
        let reader = try AVAssetReader(asset: asset)
        if start > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 6000),
                                           duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.outputSettings)
        output.alwaysCopiesSampleData = false
        self.reader = reader
        self.output = output
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VJPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "映像を読み込めません"])
        }
        let t = Thread { [self] in self.run() }
        t.qualityOfService = .userInteractive
        t.name = "VJPlayer.decode"
        t.start()
    }

    private func run() {
        guard let reader, let output else { return }
        while true {
            cond.lock()
            while !cancelled && frames.count >= capacity { cond.wait() }
            if cancelled { cond.unlock(); break }
            cond.unlock()

            guard let sb = output.copyNextSampleBuffer() else {
                cond.lock(); finished = true; cond.broadcast(); cond.unlock()
                break
            }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            cond.lock()
            if pts <= requestedPos {
                // 再生位置より古いフレームしか溜まっていない → 古いものを捨てて最新だけ残す（早送りで追いつく）
                frames.removeAll()
            }
            frames.append(Frame(pts: pts, buffer: pb))
            cond.broadcast()
            cond.unlock()
        }
        if cancelled { reader.cancelReading() }
        _ = output
    }

    /// 逆再生：[cs, ce) の区間を読んで、新しい順に並べて足していく
    private func runReverse() {
        guard let asset, let track else { return }
        var ce = reverseStart + 0.0005
        while ce > reverseLower + 0.0001 {
            cond.lock()
            while !cancelled && frames.count > 2 { cond.wait() }
            if cancelled { cond.unlock(); return }
            // 表示が先に進んでいたら（遅れていたら）そこまで飛ぶ
            if requestedPos.isFinite && requestedPos + 0.0005 < ce - chunkLength {
                ce = requestedPos + 0.0005
                frames.removeAll()
            }
            cond.unlock()

            let cs = max(reverseLower, ce - chunkLength)
            var chunk: [Frame] = []
            if let r = try? AVAssetReader(asset: asset) {
                r.timeRange = CMTimeRange(start: CMTime(seconds: cs, preferredTimescale: 6000),
                                          end: CMTime(seconds: ce, preferredTimescale: 6000))
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: Self.outputSettings)
                o.alwaysCopiesSampleData = false
                r.add(o)
                if r.startReading() {
                    while let sb = o.copyNextSampleBuffer() {
                        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                        // 区間の頭より前のコマ（区切りの都合で入ってくる）は次の区間で読む。ただし一番下は含める
                        if pts < ce - 0.00001 && (pts >= cs - 0.00001 || cs <= reverseLower) {
                            chunk.append(Frame(pts: pts, buffer: pb))
                        }
                        if cancelled { break }
                    }
                    r.cancelReading()
                }
            }
            cond.lock()
            if cancelled { cond.unlock(); return }
            frames.append(contentsOf: chunk.sorted { $0.pts > $1.pts })
            cond.broadcast()
            cond.unlock()
            if cs <= reverseLower { break }
            ce = cs
        }
        cond.lock(); finished = true; cond.broadcast(); cond.unlock()
    }

    func cancel() {
        cond.lock()
        cancelled = true
        frames.removeAll()
        cond.broadcast()
        cond.unlock()
    }

    /// 先頭の数フレームが準備できているか
    var isPrimed: Bool {
        cond.lock(); defer { cond.unlock() }
        return finished || frames.count >= min(2, capacity)
    }

    /// 準備できるまで待つ（最大 timeout 秒）
    @discardableResult
    func waitUntilPrimed(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while !(finished || frames.count >= min(2, capacity)) {
            if !cond.wait(until: deadline) { return false }
        }
        return true
    }

    /// 再生位置 p に表示すべきフレーム（p より前で最新のもの）。古いフレームは捨ててデコードを進める。
    func frame(at p: Double) -> Frame? {
        cond.lock(); defer { cond.unlock() }
        requestedPos = p
        var dropped = false
        if isReverse {
            // 新しい順に並んでいる。p より後のコマは用済み
            while frames.count >= 2 && frames[0].pts > p + 0.0005 {
                frames.removeFirst()
                dropped = true
            }
            if dropped { cond.broadcast() }
            return frames.first
        }
        while frames.count >= 2 && frames[1].pts <= p + 0.0005 {
            frames.removeFirst()
            dropped = true
        }
        if dropped { cond.broadcast() }
        return frames.first
    }
}
