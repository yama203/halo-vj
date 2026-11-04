import AVFoundation
import AppKit

/// 再生位置を計算する時計。速度を変えても位置は連続する（ここで飛ばないのでカクつかない）。
struct PlayheadClock {
    private(set) var anchorHost: Double = 0
    private(set) var anchorPos: Double = 0
    private(set) var rate: Double = 0

    func position(at host: Double) -> Double {
        anchorPos + max(host - anchorHost, 0) * rate
    }

    mutating func start(at host: Double, position: Double, rate: Double) {
        anchorHost = host
        anchorPos = position
        self.rate = rate
    }

    mutating func setRate(_ r: Double, at host: Double) {
        if host > anchorHost {
            anchorPos = position(at: host)
            anchorHost = host
        }
        rate = r
    }

    mutating func freeze(at position: Double) {
        anchorPos = position
        rate = 0
    }
}

/// クリップの配置（描画用）
struct ClipTransform {
    var x: Float = 0, y: Float = 0, scale: Float = 1, rotation: Float = 0, opacity: Float = 1
}

/// 1つのクリップ。
/// - 先頭からデコード済みの「待機ストリーム」を常に1本持っておき、トリガーで差し替えて即座に再生する
/// - 映像は自前の時計で表示、音声は AVAudioEngine + タイムストレッチで同じ時刻から鳴らす
final class ClipSlot: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL

    /// 速度・ループなど保存対象の設定が変わったときに呼ばれる
    var onSettingsChanged: (() -> Void)?
    /// 読み込みが終わって再生できるようになった
    var onReady: (() -> Void)?

    static let speedRange: ClosedRange<Double> = 0.25...2.0
    /// トリガーから動き出すまでの余裕。映像と音声を同じ時刻に揃えるため（音声の出力バッファより長く）
    static let startMargin = 0.025
    /// デコードして溜めておくフレーム数
    static let bufferFrames = 4
    static let debug = ProcessInfo.processInfo.environment["VJ_DEBUG"] != nil

    /// クリップ自体の速度（保存される）
    @Published var speed: Double {
        didSet {
            applyRate()
            onSettingsChanged?()
        }
    }
    /// コンポジション速度（Engine が入れる）。実際の速度 = speed × masterRate
    var masterRate = 1.0 {
        didSet { if oldValue != masterRate { applyRate() } }
    }
    var effectiveSpeed: Double { speed * masterRate }
    @Published var loop: Bool {
        didSet { onSettingsChanged?() }
    }

    // MARK: トランスフォーム（クリップごと）
    /// 位置。出力の幅・高さに対する割合で、0 = 中央。X は右、Y は上が +
    @Published var posX = 0.0 { didSet { onSettingsChanged?() } }
    @Published var posY = 0.0 { didSet { onSettingsChanged?() } }
    /// 大きさ（1 = 出力いっぱい）
    @Published var scale = 1.0 { didSet { onSettingsChanged?() } }
    /// 角度（度、時計回りが +）
    @Published var rotation = 0.0 { didSet { onSettingsChanged?() } }
    /// 不透明度（レイヤーの不透明度と掛け合わせる）
    @Published var opacity = 1.0 { didSet { onSettingsChanged?() } }
    /// 音量（レイヤーの音量と掛け合わせる）
    @Published var clipVolume = 1.0 {
        didSet {
            applyVolume()
            onSettingsChanged?()
        }
    }
    /// レイヤーの音量（Engine が入れる）
    var layerVolume: Float = 1 { didSet { applyVolume() } }

    var effectiveVolume: Float { layerVolume * Float(clipVolume) }

    var transform: ClipTransform {
        ClipTransform(x: Float(posX), y: Float(posY), scale: Float(scale),
                      rotation: Float(rotation * .pi / 180), opacity: Float(opacity))
    }

    var hasCustomTransform: Bool {
        posX != 0 || posY != 0 || scale != 1 || rotation != 0 || opacity != 1 || clipVolume != 1
    }

    func resetTransform() {
        posX = 0; posY = 0; scale = 1; rotation = 0; opacity = 1; clipVolume = 1
    }

    private func applyVolume() {
        let v = effectiveVolume
        audioDo { $0.node.volume = v }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var errorMessage: String?

    var name: String { url.deletingPathExtension().lastPathComponent }
    var progress: Double { duration > 0 ? min(max(currentTime / duration, 0), 1) : 0 }
    var hasAudio: Bool { audio != nil }

    private let asset: AVURLAsset
    private var videoTrack: AVAssetTrack?
    private(set) var audio: AudioClip?
    private var standby: FrameStream?

    // ここから下の 6 つは描画スレッドからも読むので、必ず lock の中で触る
    private let lock = NSLock()
    private var _active: FrameStream?
    private var _clock = PlayheadClock()
    private var _playing = false
    private var _dur = 0.0
    private var _lastShownPTS = -1.0
    private var endCheckPending = false

    var clock: PlayheadClock { lock.withLock { _clock } }
    var lastShownPTS: Double { lock.withLock { _lastShownPTS } }
    private var progressTimer: Timer?
    /// 再生を始めた（動き出した）時刻
    private var playStartHost = 0.0
    private var restartObserver: NSObjectProtocol?

    init(url: URL, speed: Double = 1.0, loop: Bool = false) {
        self.url = url
        self.speed = speed
        self.loop = loop
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        restartObserver = NotificationCenter.default.addObserver(
            forName: .audioEngineRestarted, object: nil, queue: .main
        ) { [weak self] _ in
            self?.audioEngineRestarted()
        }
        Task { [weak self] in await self?.prepare() }
    }

    deinit {
        _active?.cancel()
        standby?.cancel()
        progressTimer?.invalidate()
        if let restartObserver { NotificationCenter.default.removeObserver(restartObserver) }
    }

    // MARK: - 準備

    private func prepare() async {
        do {
            let d = try await asset.load(.duration).seconds
            guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(domain: "VJPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "映像トラックがありません"])
            }
            let audioFile = try await AudioCache.file(for: asset, url: url)
            await MainActor.run {
                self.duration = d.isFinite ? d : 0
                let dur = self.duration
                self.lock.withLock { self._dur = dur }
                self.videoTrack = vt
                if let audioFile {
                    let a = AudioClip(file: audioFile)
                    a.rate = self.effectiveSpeed
                    a.node.volume = self.effectiveVolume
                    self.audio = a
                    self.audioDo { $0.schedule(from: 0) }
                }
                self.standby = self.makeStream()
                self.isReady = self.standby != nil
                self.onReady?()
            }
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
            return
        }
        await loadThumbnail()
    }

    /// クリッププレビュー用の、先頭から読むストリーム
    func makePreviewStream() -> FrameStream? { makeStream() }

    /// 長さ（描画スレッドから読める）
    var durationForRender: Double { lock.withLock { _dur } }

    private func makeStream(at start: Double = 0) -> FrameStream? {
        guard let videoTrack else { return nil }
        do {
            return try FrameStream(asset: asset, track: videoTrack, capacity: Self.bufferFrames, start: start)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func loadThumbnail() async {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        let t = CMTime(seconds: min(1.0, duration * 0.1), preferredTimescale: 600)
        if let (cg, _) = try? await gen.image(at: t) {
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            await MainActor.run { self.thumbnail = img }
        }
    }

    // MARK: - 再生操作

    /// 頭から再生。待機ストリームに差し替えるだけなので、押した瞬間に先頭フレームが出る。
    func playFromStart() {
        guard isReady else { return }
        let t0 = CACurrentMediaTime()
        let startHost = t0 + Self.startMargin

        isScrubbing = false
        scrubWork?.cancel()
        let hadStandby = standby != nil
        let next = standby ?? makeStream()
        standby = nil
        let rate0 = effectiveSpeed
        let old: FrameStream? = lock.withLock {
            let o = _active
            _active = next
            _lastShownPTS = -1
            _clock.start(at: startHost, position: 0, rate: rate0)
            _playing = true
            return o
        }
        old?.cancel()
        playStartHost = startHost
        let t1 = CACurrentMediaTime()

        let rate = effectiveSpeed
        audioDo { audio in
            if !audio.isScheduledFromStart { audio.schedule(from: 0) }
            audio.rate = rate
            audio.play(atHostSeconds: startHost)
            let late = CACurrentMediaTime() - startHost
            if late > 0 { NSLog("VJPlayer: 音声の開始が %.1f ms 遅れました", late * 1000) }
        }
        if Self.debug {
            print(String(format: "   [play] video %.2fms (standby=%@)", (t1 - t0) * 1000, hadStandby ? "yes" : "no"))
        }
        isPlaying = true
        startProgressTimer()

        // 次のトリガーに備えて新しい待機ストリームを用意する
        DispatchQueue.main.async { [weak self] in
            guard let self, self.standby == nil else { return }
            self.standby = self.makeStream()
        }
    }

    /// 停止して、次のトリガーに備える
    func stopAndRearm() {
        isScrubbing = false
        scrubWork?.cancel()
        isPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
        let old: FrameStream? = lock.withLock {
            let o = _active
            _active = nil
            _clock.freeze(at: 0)
            _playing = false
            return o
        }
        old?.cancel()
        currentTime = 0
        audioDo { $0.schedule(from: 0) }
        if standby == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.standby == nil else { return }
                self.standby = self.makeStream()
            }
        }
    }

    // MARK: - スクラブ

    @Published private(set) var isScrubbing = false
    private var scrubTarget = 0.0
    private var lastScrubSeek = 0.0
    private var scrubWork: DispatchWorkItem?

    /// 再生位置を pos 秒へ動かす（ドラッグ中に何度も呼ばれる）。動かしている間は止めて、その位置の映像を出す。
    func scrub(to pos: Double) {
        guard isReady, duration > 0 else { return }
        let p = min(max(pos, 0), max(duration - 0.001, 0))
        if !isScrubbing {
            isScrubbing = true
            isPlaying = false
            progressTimer?.invalidate()
            progressTimer = nil
            audioDo { $0.stop() }
        }
        scrubTarget = p
        currentTime = p
        // 読み直しは 25ms に 1 回まで（最後の位置は必ず反映）
        let now = CACurrentMediaTime()
        scrubWork?.cancel()
        if now - lastScrubSeek >= 0.025 {
            seekStream(to: p)
        } else {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.isScrubbing else { return }
                self.seekStream(to: self.scrubTarget)
            }
            scrubWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: w)
        }
    }

    /// スクラブを終えて、その位置から再生を続ける
    func endScrub() {
        guard isScrubbing else { return }
        scrubWork?.cancel()
        scrubWork = nil
        isScrubbing = false
        let p = scrubTarget
        if abs(clock.anchorPos - p) > 0.0005 { seekStream(to: p) }

        let startHost = CACurrentMediaTime() + Self.startMargin
        let rate = effectiveSpeed
        lock.withLock {
            _clock.start(at: startHost, position: p, rate: rate)
            _playing = true
        }
        playStartHost = startHost - p
        isPlaying = true
        audioDo { audio in
            audio.rate = rate
            audio.schedule(from: p)
            audio.play(atHostSeconds: startHost)
        }
        startProgressTimer()
    }

    private func seekStream(to p: Double) {
        lastScrubSeek = CACurrentMediaTime()
        let next = makeStream(at: p)
        let old: FrameStream? = lock.withLock {
            let o = _active
            _active = next
            _clock.freeze(at: p)
            _playing = false
            _lastShownPTS = -1
            return o
        }
        old?.cancel()
    }

    private func applyRate() {
        guard isPlaying else { return }
        let r = effectiveSpeed
        lock.withLock { _clock.setRate(r, at: CACurrentMediaTime()) }
        let rate = effectiveSpeed
        audioDo { $0.rate = rate }
    }

    /// 最後まで行ったときの処理。描画ループとタイマーの両方から呼ばれる。
    private func checkEnd(at host: Double) {
        guard isPlaying, duration > 0, clock.position(at: host) >= duration else { return }
        if loop {
            playFromStart()
        } else {
            // 最終フレームを表示したまま止める
            isPlaying = false
            let d = duration
            lock.withLock {
                _clock.freeze(at: d)
                _playing = false
            }
            audioDo { $0.stop() }
            currentTime = duration
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    // MARK: - 描画側から呼ばれる

    /// host 時刻に表示すべきフレーム。前回から変わっていなければ nil。
    /// 描画スレッドから呼ばれる（メインスレッドが忙しくても映像が止まらないように）。
    func frameForDisplay(at host: Double) -> CVPixelBuffer? {
        let (stream, p, ended) = lock.withLock { () -> (FrameStream?, Double, Bool) in
            let p = _playing ? _clock.position(at: host) : _clock.anchorPos
            let ended = _playing && _dur > 0 && p >= _dur && !endCheckPending
            if ended { endCheckPending = true }
            return (_active, p, ended)
        }
        if ended {
            // 最後まで来た → ループ／停止の処理はメインスレッドで
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.endCheckPending = false }
                self.checkEnd(at: CACurrentMediaTime())
            }
        }
        guard let stream, let f = stream.frame(at: p) else { return nil }
        return lock.withLock {
            guard f.pts != _lastShownPTS else { return nil }
            _lastShownPTS = f.pts
            return f.buffer
        }
    }

    /// 今の再生位置（秒）。画面の更新ごとに時計から直接計算する（進行バーを滑らかにするため）
    func position(at host: Double) -> Double {
        isPlaying ? min(max(clock.position(at: host), 0), duration) : currentTime
    }

    /// 通常速度（1.0x）で再生していた場合との差（秒）。+ なら先行、- なら遅れ。
    func offsetFromNormal(at host: Double) -> Double? {
        guard isPlaying else { return nil }
        let t = max(host - playStartHost, 0)
        return clock.position(at: host) - t
    }

    /// 表示中のフレームを強制的に出し直させる（クリップ切り替え時）
    func invalidateShownFrame() {
        lock.withLock { _lastShownPTS = -1 }
    }

    // MARK: - その他

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.checkEnd(at: now)
        }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
    }

    private func audioEngineRestarted() {
        let rate = effectiveSpeed
        if isPlaying {
            // 映像の時計に合わせて、続きの位置から鳴らし直す
            let host = CACurrentMediaTime() + Self.startMargin
            let pos = clock.position(at: host)
            audioDo { audio in
                audio.connect()
                audio.rate = rate
                audio.schedule(from: pos)
                audio.play(atHostSeconds: host)
            }
        } else {
            audioDo { audio in
                audio.connect()
                audio.rate = rate
                audio.schedule(from: 0)
            }
        }
    }

    /// 音声の操作を音声キューで行う
    private func audioDo(_ work: @escaping (AudioClip) -> Void) {
        guard let audio else { return }
        AudioClip.queue.async { work(audio) }
    }
}
