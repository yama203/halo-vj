import AVFoundation

/// クリッププレビュー用の再生。出力にも音声にも出さずに、クリップをイン点〜アウト点でループ再生する。
/// （出力で再生中のクリップは、出力と同じフレームをプレビューに出すのでこれは使わない）
final class PreviewPlayer {
    let slot: ClipSlot

    // 描画スレッドからも触るので lock の中で
    private let lock = NSLock()
    private var stream: FrameStream?
    private var clock = PlayheadClock()
    private var lastPTS = -1.0
    private var restartPending = false
    private var cancelled = false

    init?(slot: ClipSlot) {
        guard let s = slot.makePreviewStream() else { return nil }
        self.slot = slot
        stream = s
        clock.start(at: CACurrentMediaTime(), position: slot.inPoint, rate: slot.effectiveSpeed)
    }

    deinit {
        stream?.cancel()
    }

    /// イン点が変わったらそこから出し直す
    func restartFromIn() {
        lock.withLock { restartPending = true }
        restart()
    }

    func setRate(_ r: Double) {
        lock.withLock { clock.setRate(r, at: CACurrentMediaTime()) }
    }

    func cancel() {
        let s: FrameStream? = lock.withLock {
            cancelled = true
            let s = stream
            stream = nil
            return s
        }
        s?.cancel()
    }

    /// host 時刻に表示すべきフレーム。前回から変わっていなければ nil。描画スレッドから呼ばれる。
    func frame(at host: Double) -> CVPixelBuffer? {
        let duration = slot.durationForRender
        let out = slot.outForRender
        let (s, p, ended) = lock.withLock { () -> (FrameStream?, Double, Bool) in
            let p = clock.position(at: host)
            let ended = duration > 0 && p >= out && !restartPending && !cancelled
            if ended { restartPending = true }
            return (stream, p, ended)
        }
        if ended {
            // アウト点まで来たらイン点から（新しいストリームはメインスレッドで作る）
            DispatchQueue.main.async { [weak self] in self?.restart() }
        }
        guard let s, let f = s.frame(at: p) else { return nil }
        return lock.withLock {
            guard f.pts != lastPTS else { return nil }
            lastPTS = f.pts
            return f.buffer
        }
    }

    private func restart() {
        let next = slot.makePreviewStream()
        let rate = slot.effectiveSpeed
        let start = slot.inPoint
        let old: FrameStream? = lock.withLock {
            restartPending = false
            guard !cancelled else { return next }
            let o = stream
            stream = next
            clock.start(at: CACurrentMediaTime(), position: start, rate: rate)
            lastPTS = -1
            return o
        }
        old?.cancel()
    }
}
