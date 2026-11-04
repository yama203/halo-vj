import AVFoundation

/// 動画を先頭から順にデコードして、数フレーム先まで溜めておくストリーム。
/// 専用スレッドでデコードし、描画側は「再生位置 p に表示すべきフレーム」を取り出す。
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
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    /// start 秒の位置から読む（スクラブ用）。0 なら先頭から
    init(asset: AVAsset, track: AVAssetTrack, capacity: Int, start: Double = 0) throws {
        self.capacity = max(capacity, 2)
        reader = try AVAssetReader(asset: asset)
        if start > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 6000),
                                           duration: .positiveInfinity)
        }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
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
        while frames.count >= 2 && frames[1].pts <= p + 0.0005 {
            frames.removeFirst()
            dropped = true
        }
        if dropped { cond.broadcast() }
        return frames.first
    }
}
