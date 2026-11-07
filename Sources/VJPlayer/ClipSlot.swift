import AVFoundation
import AppKit
import Metal

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

/// 再生速度の決め方
enum SyncMode: Int, CaseIterable, Codable, Identifiable {
    /// クリップ速度 × コンポジション速度
    case free
    /// 再生範囲（イン点〜アウト点）を決めた拍数で 1 周する速さ（BPM に付いていく）
    case bpm
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .free: "手動"
        case .bpm: "BPM 同期"
        }
    }
}

/// 再生がアウト点まで来たときの動き
enum EndAction: Int, CaseIterable, Codable, Identifiable {
    // 保存データの番号を変えないよう、値は明示する（並びは画面の表示順）
    case loop = 0, pingpong = 3, hold = 1, blackout = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .loop: "ループ"
        case .pingpong: "往復"
        case .hold: "最後で停止"
        case .blackout: "ブラックアウト"
        }
    }
    var icon: String {
        switch self {
        case .loop: "repeat"
        case .pingpong: "arrow.left.arrow.right"
        case .hold: "arrow.right.to.line"
        case .blackout: "arrow.right.to.line"
        }
    }
}


/// 1つのクリップ。
/// - 先頭からデコード済みの「待機ストリーム」を常に1本持っておき、トリガーで差し替えて即座に再生する
/// - 映像は自前の時計で表示、音声は AVAudioEngine + タイムストレッチで同じ時刻から鳴らす
final class ClipSlot: ObservableObject, Identifiable, Animatable, EffectHolder {
    /// クリップの目印（保存される。キューはこれでクリップを探す。場所を動かしても変わらない）
    var id = UUID()
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
    /// 速度の決め方（手動 / BPM 同期）
    @Published var syncMode = SyncMode.free {
        didSet { if oldValue != syncMode { applyRate(); onSettingsChanged?() } }
    }
    /// BPM 同期のとき、再生範囲を何拍で 1 周するか
    @Published var syncBeats = 8.0 {
        didSet { if oldValue != syncBeats { applyRate(); onSettingsChanged?() } }
    }
    /// 今の BPM（Engine が入れる）
    var engineBPM = 120.0 {
        didSet { if oldValue != engineBPM { applyRate() } }
    }
    /// BPM の時計（Engine が入れる）。ランダムジャンプの拍の頭を決める
    var beatClock = BeatClock() {
        didSet {
            guard oldValue != beatClock else { return }
            engineBPM = beatClock.bpm
            if jumpBeats > 0 { armJump() }
        }
    }

    // MARK: ランダムジャンプ（BPM に合わせて再生位置をランダムに飛ばす）
    /// 何拍ごとに飛ぶか（0 = 飛ばない）
    @Published var jumpBeats = 0.0 {
        didSet {
            guard oldValue != jumpBeats else { return }
            if jumpBeats > 0 { armJump() } else { cancelJump() }
            onSettingsChanged?()
        }
    }
    static let jumpChoices: [Double] = [0, 0.25, 0.5, 1, 2, 4, 8, 16]
    /// 飛び先の並び（クリップごとに違う）
    private let jumpSeed = UInt32.random(in: 0...UInt32.max)

    /// 次に飛ぶ予定（描画スレッドが時刻になったら切り替える。lock の中で触る）
    private struct PendingJump {
        let stream: FrameStream
        let host: Double
        let pos: Double
        var rate: Double
    }
    private var _pendingJump: PendingJump?
    /// 取り消した回数（音声キューから確かめる。lock の中で触る）。予定の音声はこれが変わっていなければ鳴らす
    private var _jumpGeneration = 0
    /// 映像がもう切り替わった予定の時刻（lock の中で触る）。映像が先に飛んだら、取り消されても音声は必ず追いかける
    private var _appliedJumpHost = -1.0
    /// 音声がもう飛んだ（飛ぶ予約を済ませた）予定の時刻（lock の中で触る）。
    /// 映像が飛ぶ前にその予定を取り消したら、音声を映像の位置に戻すのに使う
    private var _audioJumpHost = -1.0
    /// 予定を出し直したら増やす（古い予定の音声処理を無効にする）
    private var jumpToken = 0

    /// 次の拍の頭への飛び先を決めて、映像を先読みし、音声をその時刻に鳴らす予約をする
    /// cancelPrevious: false は「前の予定どおり飛んだあと、次を予約する」とき（前の予定の音声は取り消さない）
    private func armJump(cancelPrevious: Bool = true) {
        if cancelPrevious { cancelJump() }
        guard jumpBeats > 0, isPlaying, !isScrubbing, isReady, duration > 0 else { return }
        let now = CACurrentMediaTime()
        let clock = beatClock
        let spb = 60 / max(clock.bpm, 1)
        // 次の「jumpBeats の倍数の拍」。近すぎるとき（準備が間に合わない）はその次
        var n = floor(clock.beat(at: now) / jumpBeats) + 1
        var host = clock.anchorHost + (n * jumpBeats - clock.anchorBeat) * spb
        if host - now < 0.06 { n += 1; host += jumpBeats * spb }
        // 飛び先：次に飛ぶまでにアウト点を越えない範囲で、拍の番号から決める（毎回違うが再現できる）
        let rate = effectiveSpeed
        let need = jumpBeats * spb * rate
        let hi = max(outTime - need - 0.01, inPoint)
        let pos = inPoint + (hi - inPoint) * ParamAnim.hash(Int64(n), jumpSeed)
        guard let stream = makeStream(at: pos) else { return }
        jumpToken += 1
        let token = jumpToken
        let generation = lock.withLock { () -> Int in
            _pendingJump?.stream.cancel()
            _pendingJump = PendingJump(stream: stream, host: host, pos: pos, rate: rate)
            return _jumpGeneration
        }

        // 音声：直前に止めて、拍の頭から鳴らす（音声キューで時刻を待つ）
        if let audio {
            let at = DispatchTime.now() + max(host - CACurrentMediaTime() - 0.04, 0)
            AudioClip.queue.asyncAfter(deadline: at) { [weak self] in
                guard let self else { return }
                // 取り消されていなければ鳴らす（映像の切り替えが先に済んでいても鳴らす）
                let (valid, r) = self.lock.withLock { () -> (Bool, Double) in
                    // 止めた・スクラブした後は鳴らさない
                    let ok = self._playing && (self._jumpGeneration == generation || self._appliedJumpHost == host)
                    // 「音声は飛んだ」と記録する（この後で取り消されたら cancelJump が音声を戻す）
                    if ok { self._audioJumpHost = host }
                    return (ok, self._pendingJump?.host == host ? self._pendingJump!.rate : self._clock.rate)
                }
                guard valid else { return }
                // 音声キューが遅れて拍の頭を過ぎていたら、その分先の位置から鳴らして映像に合わせる
                let start = max(host, CACurrentMediaTime() + 0.01)
                audio.rate = r
                audio.schedule(from: pos + (start - host) * r)
                audio.play(atHostSeconds: start)
            }
        }
        // 描画スレッドが止まっていても切り替わるように、時刻が来たらメインでも確かめる。続けて次を予約
        DispatchQueue.main.asyncAfter(deadline: .now() + max(host - CACurrentMediaTime(), 0) + 0.01) { [weak self] in
            guard let self, self.jumpToken == token else { return }
            self.applyPendingJump(at: CACurrentMediaTime())
            if self.isReversing { self.isReversing = false }
            self.armJump(cancelPrevious: false)
        }
    }

    private func cancelJump() {
        jumpToken += 1
        let (old, audioJumped) = lock.withLock { () -> (FrameStream?, Bool) in
            let s = _pendingJump?.stream
            // 音声はもう飛んだのに、映像はまだ飛んでいない（拍の頭の直前に取り消した）
            let jumped = _pendingJump.map { $0.host == _audioJumpHost } ?? false
            _pendingJump = nil
            _jumpGeneration += 1
            return (s, jumped)
        }
        old?.cancel()
        // 映像は今の位置のまま進むので、先に飛んでしまった音声を映像の位置に戻す
        if audioJumped { resyncAudioToVideo() }
    }

    /// 時刻が来ていれば、予約していた位置に切り替える（描画スレッドとメインの両方から呼ばれる）
    private func applyPendingJump(at host: Double) {
        let old: FrameStream? = lock.withLock {
            guard let pj = _pendingJump, host >= pj.host else { return nil }
            let o = _active
            _active = pj.stream
            _clock.start(at: pj.host, position: pj.pos, rate: pj.rate)
            _dir = 1
            _playing = true
            _lastShownPTS = -1
            _appliedJumpHost = pj.host
            _pendingJump = nil
            return o
        }
        old?.cancel()
    }
    /// BPM 同期の拍数の選択肢
    static let syncBeatChoices: [Double] = [1, 2, 4, 8, 16, 32, 64, 128]
    /// BPM 同期で出せる速さの範囲（これを超える組み合わせは端で止める）
    static let syncRateRange: ClosedRange<Double> = 0.05...8

    /// BPM 同期のときの速さ（範囲に収める前の値）
    var bpmRate: Double {
        let len = outTime - inPoint
        let beatsSeconds = syncBeats * 60 / max(engineBPM, 1)
        guard len > 0, beatsSeconds > 0 else { return 1 }
        return len / beatsSeconds
    }

    /// 実際の再生速度
    var effectiveSpeed: Double {
        switch syncMode {
        case .free: return speed * masterRate
        case .bpm: return min(max(bpmRate, Self.syncRateRange.lowerBound), Self.syncRateRange.upperBound)
        }
    }
    /// アウト点まで来たときの動き（ループ／最後のコマで停止／ブラックアウト＝そのレイヤーを消す）
    @Published var endAction: EndAction {
        didSet {
            guard oldValue != endAction else { return }
            if currentEndAction == .pingpong { prepareReverse() } else { dropReverse() }
            onSettingsChanged?()
        }
    }
    /// キューで一時的に決めた「終わったら」（nil = 自分の設定）。保存しない。普通に出し直すと外れる
    @Published var endActionOverride: EndAction? {
        didSet {
            guard oldValue != endActionOverride else { return }
            if currentEndAction == .pingpong { prepareReverse() } else { dropReverse() }
        }
    }
    /// 今効いている「終わったら」
    var currentEndAction: EndAction { endActionOverride ?? endAction }
    /// 往復モードで逆向きに再生中
    @Published private(set) var isReversing = false
    var loop: Bool { endAction == .loop }
    /// .blackout で最後まで来た（Engine がレイヤーを止める）
    var onBlackoutEnd: (() -> Void)?

    // MARK: イン点・アウト点（秒）
    /// 再生を始める位置
    @Published private(set) var inPoint = 0.0
    /// 再生を終える位置（nil = 最後まで）
    @Published private(set) var outPoint: Double?
    /// アウト点（未設定なら長さ）
    var outTime: Double { min(outPoint ?? duration, duration) }
    var hasInOut: Bool { inPoint > 0 || outPoint != nil }
    /// イン点とアウト点の最小の間隔
    static let minRange = 0.1

    /// イン点・アウト点を設定する（長さの中に収め、イン < アウトに保つ）
    /// notify: false は読み込み時に保存されていた値を長さに収めるとき（変更として扱わない）
    func setInOut(in newIn: Double? = nil, out newOut: Double?? = .none, notify: Bool = true) {
        let d = duration
        var i = newIn ?? inPoint
        var o: Double? = outPoint
        if case .some(let v) = newOut { o = v }
        if d > 0 {
            if let ov = o { o = ov >= d - 0.0005 ? nil : min(max(ov, Self.minRange), d) }
            let oEnd = o ?? d
            i = min(max(i, 0), max(oEnd - Self.minRange, 0))
            if let ov = o, ov < i + Self.minRange { o = i + Self.minRange }
        }
        guard i != inPoint || o != outPoint else { return }
        let inChanged = i != inPoint
        inPoint = i
        outPoint = o
        let oT = outTime
        lock.withLock { _out = oT; _in = i }
        rebuildStandby(forward: inChanged)
        if syncMode == .bpm { applyRate() }
        if jumpBeats > 0 && isPlaying { armJump() }
        if notify { onSettingsChanged?() }
    }

    func resetInOut() { setInOut(in: 0, out: .some(nil)) }

    /// 1 コマの長さ（秒。動画のフレームレートから）
    var frameLength: Double { frameDuration }

    /// イン点を n コマ動かす（コマの区切りにそろえる）
    func stepIn(_ n: Int) {
        let f = frameDuration
        setInOut(in: max((inPoint / f).rounded() + Double(n), 0) * f)
    }

    /// アウト点を n コマ動かす（コマの区切りにそろえる。最後まで行ったら「最後まで」）
    func stepOut(_ n: Int) {
        let f = frameDuration
        let t = ((outTime / f).rounded() + Double(n)) * f
        setInOut(out: .some(t >= duration - f / 2 ? nil : t))
    }

    /// 時刻 t のコマの絵（ぴったりそのコマ。再生範囲の端の確認用）
    func exactFrame(at t: Double, maxSize: CGSize = CGSize(width: 480, height: 270)) async -> CGImage? {
        guard !isStill else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maxSize
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try? await gen.image(at: CMTime(seconds: max(t, 0), preferredTimescale: 600)).image
    }

    /// 再生範囲のバーの後ろに並べる、クリップのコマ（少しずつ間引いたもの）。作ったら覚えておく
    @Published private(set) var filmstrip: [CGImage] = []
    private var filmstripLoading = false

    func loadFilmstrip(count: Int = 24) {
        guard !isStill, filmstrip.isEmpty, !filmstripLoading, duration > 0 else { return }
        filmstripLoading = true
        let a = asset, d = duration
        let done: ([CGImage]) -> Void = { [weak self] frames in
            self?.filmstrip = frames
            self?.filmstripLoading = false
        }
        Task.detached(priority: .utility) {
            let gen = AVAssetImageGenerator(asset: a)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 96, height: 54)
            let tol = CMTime(seconds: d / Double(count) / 2, preferredTimescale: 600)
            gen.requestedTimeToleranceBefore = tol
            gen.requestedTimeToleranceAfter = tol
            var out: [CGImage] = []
            for k in 0..<count {
                let t = d * (Double(k) + 0.5) / Double(count)
                if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { out.append(img) }
            }
            let frames = out
            await MainActor.run { done(frames) }
        }
    }

    /// イン点が変わったら待機ストリームを作り直す（ドラッグ中に作りすぎないよう少し待つ）
    private var standbyWork: DispatchWorkItem?
    private func rebuildStandby(forward: Bool) {
        let forwardPending = forward || (standbyWork.map { !$0.isCancelled } ?? false)
        standbyWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.standbyWork = nil
            if forwardPending {
                self.standby?.cancel()
                self.standby = self.makeStream(at: self.inPoint)
                if !self.isPlaying && !self.isScrubbing {
                    let p = self.inPoint
                    self.audioDo { $0.schedule(from: p) }
                }
            }
            if self.currentEndAction == .pingpong { self.prepareReverse() }
        }
        standbyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    // MARK: 往復（逆再生）
    /// アウト点から逆向きに読む待機ストリーム（往復モードのときだけ）
    private var reverseStandby: FrameStream?
    /// 1 コマの長さ（秒）
    private var frameDuration = 1.0 / 30

    /// 逆再生の準備（映像の待機ストリームと、逆順の音声）
    private func prepareReverse() {
        guard isReady || videoTrack != nil, duration > 0 else { return }
        reverseStandby?.cancel()
        reverseStandby = makeReverseStream()
        let (lo, hi) = (inPoint, outTime)
        audioDo { $0.prepareReversed(lower: lo, upper: hi) }
    }

    private func dropReverse() {
        reverseStandby?.cancel()
        reverseStandby = nil
        audioDo { $0.dropReversed() }
    }

    private func makeReverseStream() -> FrameStream? {
        guard let videoTrack else { return nil }
        return FrameStream(reverseAsset: asset, track: videoTrack, capacity: Self.bufferFrames + 6,
                           start: outTime - 0.002, lower: inPoint, frameDuration: frameDuration)
    }

    /// アウト点から逆向きに再生を始める
    private func startReverse() {
        let startHost = CACurrentMediaTime() + Self.startMargin
        let from = outTime - 0.002
        let next = reverseStandby ?? makeReverseStream()
        reverseStandby = nil
        let rate = effectiveSpeed
        let old: FrameStream? = lock.withLock {
            let o = _active
            _active = next
            _lastShownPTS = -1
            _dir = -1
            _clock.start(at: startHost, position: from, rate: -rate)
            _playing = true
            return o
        }
        old?.cancel()
        isReversing = true
        audioDo { audio in
            audio.rate = rate
            if audio.scheduleReversed(from: from) { audio.play(atHostSeconds: startHost) }
        }
        // 次の折り返しに備える
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentEndAction == .pingpong, self.reverseStandby == nil else { return }
            self.reverseStandby = self.makeReverseStream()
        }
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

    /// クロスフェード中の音量（0〜1、メインスレッドから設定）
    var fadeGain: Float = 1 { didSet { if fadeGain != oldValue { applyVolume() } } }
    /// ミュート：再生は続けたまま、映像と音を出さない
    @Published var muted = false {
        didSet { if oldValue != muted { applyVolume(); onSettingsChanged?() } }
    }
    /// 音だけのミュート（映像は出る）
    @Published var audioMuted = false {
        didSet { if oldValue != audioMuted { applyVolume(); onSettingsChanged?() } }
    }
    var effectiveVolume: Float { muted || audioMuted ? 0 : layerVolume * Float(clipVolume) * fadeGain }

    /// クリップのエフェクト（トランスフォームの前、元の映像にかかる）
    @Published var effects: [Effect] = [] { didSet { onSettingsChanged?() } }

    /// パラメーターのアニメーション（位置・スケール・角度・不透明度）
    @Published var anims: [ParamKey: ParamAnim] = [:] { didSet { onSettingsChanged?() } }
    /// 秒モードのアニメーションの基準（トリガーした時刻。トリガーし直すと頭から動く）
    private(set) var animOrigin = 0.0

    /// 描画用（アニメーション込み）
    var animTransform: AnimTransform {
        AnimTransform(x: posX, y: posY, scale: scale, rotation: rotation, opacity: opacity,
                      anims: anims, origin: animOrigin)
    }

    /// アニメーションを止めたときの値（テスト用）
    var transform: ClipTransform { animTransform.at(0, beat: BeatClock()) }

    var hasCustomTransform: Bool {
        posX != 0 || posY != 0 || scale != 1 || rotation != 0 || opacity != 1 || clipVolume != 1
            || anims.values.contains { $0.isOn }
    }

    func resetTransform() {
        posX = 0; posY = 0; scale = 1; rotation = 0; opacity = 1; clipVolume = 1
        anims = [:]
    }

    private func applyVolume() {
        let v = effectiveVolume
        audioDo { $0.node.volume = v }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var thumbnail: NSImage? {
        didSet { thumbStyle = ThumbStyle.make(thumbnail) }
    }
    /// グリッドでの見せ方（透明・暗さ・中身に寄せた絵。サムネイルから自動で決める）
    @Published private(set) var thumbStyle = ThumbStyle.none
    @Published private(set) var errorMessage: String?

    /// 見かけの名前（付けた名前があればそれ、無ければ元の名前）
    var name: String { title.isEmpty ? autoName : title }

    /// 元の名前（ファイル名・ジェネレーターの種類・エフェクト名）
    var autoName: String {
        if isEffectClip {
            return effects.isEmpty ? "エフェクト（空）" : effects.map(\.kind.label).joined(separator: "＋")
        }
        if let g = generator, g.kind == .text {
            // テキストは最初の行を名前に
            let first = g.text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return first.isEmpty ? g.kind.label : "「" + first + "」"
        }
        if let g = generator, g.kind == .clock {
            let i = min(max(Int(g.value(12).rounded()), 0), ClockText.modes.count - 1)
            return ClockText.modes[i].components(separatedBy: "（").first ?? g.kind.label
        }
        return generator?.kind.label ?? url.deletingPathExtension().lastPathComponent
    }

    /// エフェクトのクリップ（調整レイヤーの枠に置く、エフェクトのセット。絵は持たない）
    private(set) var isEffectClip = false
    /// クリップに付けた見かけの名前（空なら元の名前。ファイル名・ジェネレーターの種類・エフェクト名）
    @Published var title = "" { didSet { if oldValue != title { onSettingsChanged?() } } }

    /// エフェクトのクリップを作る。読み込みは要らないので、すぐ使える
    init(effects: [Effect], title: String = "") {
        url = URL(string: "halovj-effects:")!
        speed = 1
        endAction = .loop
        inPoint = 0
        outPoint = nil
        asset = AVURLAsset(url: url)
        isEffectClip = true
        isReady = true
        self.effects = effects
        self.title = title
    }

    /// ジェネレーター（動画の代わりに描く絵）。nil なら動画のクリップ
    @Published var generator: Effect? {
        didSet {
            guard generator != oldValue else { return }
            onSettingsChanged?()
            scheduleGeneratorThumbnail()
        }
    }
    var isGenerator: Bool { generator != nil }
    private var thumbnailWork: DispatchWorkItem?

    /// 静止画のクリップ（PNG・JPEG・PSD・AI・PDF・SVG など）。動画の代わりにこの絵を出す
    private(set) var isImage = false
    private let stillLock = NSLock()
    /// 静止画のコマ（ふつうは 1 枚。GIF などのアニメーションなら全コマ）と、各コマの終わる時刻
    private var _stillFrames: [MTLTexture] = []
    private var _frameEnds: [Double] = []
    /// 静止画の絵（1 コマ目。読み込めたら入る。描画スレッドからも読む）
    var stillTexture: MTLTexture? { stillLock.withLock { _stillFrames.first } }
    /// GIF などの動く画像か
    var isAnimatedImage: Bool { stillLock.withLock { _stillFrames.count > 1 } }
    /// 動く画像の 1 周の長さ（秒）
    var animationDuration: Double { stillLock.withLock { _frameEnds.last ?? 0 } }
    /// 読み込んだ時刻（出力していないプレビューで、ここから動かす）
    private var imageLoadedHost = 0.0

    /// 静止画の、host 時刻に出すコマ（描画スレッドから）。動く画像は再生位置（速度込み）でくり返す
    func imageTexture(at host: Double) -> MTLTexture? {
        let (frames, ends, base) = stillLock.withLock { (_stillFrames, _frameEnds, imageLoadedHost) }
        guard frames.count > 1, let total = ends.last, total > 0 else { return frames.first }
        let pos: Double = lock.withLock { _playing ? _clock.position(at: host) : host - base }
        var t = pos.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }
        // 二分探索：t より後に終わる最初のコマ
        var lo = 0, hi = ends.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] > t { hi = mid } else { lo = mid + 1 }
        }
        return frames[min(lo, frames.count - 1)]
    }
    /// 動画ではない（ジェネレーター・静止画）。速度・再生範囲などは使わない
    var isStill: Bool { isGenerator || isImage || isEffectClip }

    private func loadImage() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            isMissing = true
            errorMessage = "見つかりません：" + url.lastPathComponent
            return
        }
        let u = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // GIF などのアニメーションなら全コマ、そうでなければ 1 枚
            let anim = StillImage.loadAnimation(u)
            let img = anim?.frames.first ?? StillImage.load(u)
            var texs: [MTLTexture] = [], ends: [Double] = []
            if let anim {
                var acc = 0.0
                for (f, d) in zip(anim.frames, anim.delays) {
                    guard let t = StillImage.texture(f) else { continue }
                    texs.append(t)
                    acc += d
                    ends.append(acc)
                }
            } else if let img, let t = StillImage.texture(img) {
                texs = [t]
            }
            let tex = texs.first
            DispatchQueue.main.async {
                guard let self else { return }
                guard let img, tex != nil else {
                    let ext = u.pathExtension.lowercased()
                    self.errorMessage = "読み込めません：" + u.lastPathComponent
                        + (ext == "ai" ? "（Illustrator で「PDF 互換ファイルを作成」にして保存したものが読めます）" : "")
                    return
                }
                let now = CACurrentMediaTime()
                self.stillLock.withLock {
                    self._stillFrames = texs
                    self._frameEnds = ends
                    self.imageLoadedHost = now
                }
                self.thumbnail = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                self.isReady = true
                self.onReady?()
            }
        }
    }

    /// ジェネレーターのクリップを作る。読み込みは要らないので、すぐ再生できる
    init(generator g: Effect) {
        url = URL(string: "halovj-generator:" + g.kind.rawValue)!
        speed = 1
        endAction = .loop
        inPoint = 0
        outPoint = nil
        asset = AVURLAsset(url: url)
        generator = g
        isReady = true
        thumbnail = GeneratorThumbnail.image(g)
    }

    private func scheduleGeneratorThumbnail() {
        thumbnailWork?.cancel()
        guard let g = generator else { return }
        let w = DispatchWorkItem { [weak self] in self?.thumbnail = GeneratorThumbnail.image(g) }
        thumbnailWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }
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
    /// アウト点（描画スレッドが終わりの判定に使う）
    private var _out = 0.0
    /// イン点（逆再生の終わりの判定に使う）
    private var _in = 0.0
    /// 再生の向き（1 = 順、-1 = 逆）
    private var _dir = 1.0
    private var _lastShownPTS = -1.0
    private var endCheckPending = false

    var clock: PlayheadClock { lock.withLock { _clock } }
    var lastShownPTS: Double { lock.withLock { _lastShownPTS } }
    private var progressTimer: Timer?
    /// 再生を始めた（動き出した）時刻
    private var playStartHost = 0.0
    private var restartObserver: NSObjectProtocol?

    init(url: URL, speed: Double = 1.0, endAction: EndAction = .loop, inPoint: Double = 0, outPoint: Double? = nil) {
        self.url = url
        self.speed = speed
        self.endAction = endAction
        self.inPoint = max(inPoint, 0)
        self.outPoint = outPoint
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        if StillImage.isImage(url) {
            isImage = true
            loadImage()
            return
        }

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

    /// 動画ファイルが見つからない（プロジェクトを別の場所で開いたときなど）
    @Published private(set) var isMissing = false

    private func prepare() async {
        guard FileManager.default.fileExists(atPath: url.path) else {
            await MainActor.run {
                self.isMissing = true
                self.errorMessage = "見つかりません：" + self.url.lastPathComponent
            }
            return
        }
        do {
            let d = try await asset.load(.duration).seconds
            guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(domain: "VJPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "映像トラックがありません"])
            }
            let fps = (try? await vt.load(.nominalFrameRate)) ?? 30
            let audioFile = try await AudioCache.file(for: asset, url: url)
            await MainActor.run {
                self.duration = d.isFinite ? d : 0
                let dur = self.duration
                self.lock.withLock { self._dur = dur; self._out = dur }
                // 保存されていたイン点・アウト点を長さに収める
                let (i0, o0) = (self.inPoint, self.outPoint)
                self.inPoint = 0; self.outPoint = nil
                self.setInOut(in: i0, out: .some(o0), notify: false)
                self.standbyWork?.cancel()
                let iP = self.inPoint
                self.videoTrack = vt
                if fps > 0 { self.frameDuration = 1 / Double(fps) }
                if let audioFile {
                    let a = AudioClip(file: audioFile)
                    a.rate = self.effectiveSpeed
                    a.node.volume = self.effectiveVolume
                    self.audio = a
                    self.audioDo { $0.schedule(from: iP) }
                }
                self.standby = self.makeStream(at: iP)
                self.isReady = self.standby != nil
                if self.currentEndAction == .pingpong { self.prepareReverse() }
                self.onReady?()
            }
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
            return
        }
        await loadThumbnail()
    }

    /// クリッププレビュー用の、イン点から読むストリーム
    func makePreviewStream() -> FrameStream? { makeStream(at: inPoint) }

    /// 長さ（描画スレッドから読める）
    var durationForRender: Double { lock.withLock { _dur } }
    /// アウト点（描画スレッドから読める）
    var outForRender: Double { lock.withLock { _out } }

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
        // イン点を動かした直後で待機ストリームがまだ古いときは、その場で作る
        if let w = standbyWork, !w.isCancelled {
            w.cancel()
            standby?.cancel()
            standby = nil
        }
        standbyWork = nil
        let start = inPoint
        let hadStandby = standby != nil
        let next = standby ?? makeStream(at: start)
        standby = nil
        let rate0 = effectiveSpeed
        let old: FrameStream? = lock.withLock {
            let o = _active
            _active = next
            _lastShownPTS = -1
            _dir = 1
            _clock.start(at: startHost, position: start, rate: rate0)
            _playing = true
            return o
        }
        old?.cancel()
        playStartHost = startHost - start
        animOrigin = startHost
        let t1 = CACurrentMediaTime()

        let rate = effectiveSpeed
        audioDo { audio in
            if let p = audio.pendingStart, abs(p - start) < 0.001 {} else { audio.schedule(from: start) }
            audio.rate = rate
            audio.play(atHostSeconds: startHost)
            let late = CACurrentMediaTime() - startHost
            if late > 0 { NSLog("VJPlayer: 音声の開始が %.1f ms 遅れました", late * 1000) }
        }
        if Self.debug {
            print(String(format: "   [play] video %.2fms (standby=%@)", (t1 - t0) * 1000, hadStandby ? "yes" : "no"))
        }
        isPlaying = true
        isReversing = false
        startProgressTimer()
        if jumpBeats > 0 { armJump() }

        // 次のトリガーに備えて新しい待機ストリームを用意する
        DispatchQueue.main.async { [weak self] in
            guard let self, self.standby == nil else { return }
            self.standby = self.makeStream(at: self.inPoint)
        }
    }

    /// 停止して、次のトリガーに備える
    func stopAndRearm() {
        cancelJump()
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
            _dir = 1
            return o
        }
        old?.cancel()
        isReversing = false
        currentTime = inPoint
        let p = inPoint
        audioDo { $0.schedule(from: p) }
        if standby == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.standby == nil else { return }
                self.standby = self.makeStream(at: self.inPoint)
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
        let p = min(max(pos, inPoint), max(outTime - 0.001, inPoint))
        if !isScrubbing {
            cancelJump()
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
            _dir = 1
            _clock.start(at: startHost, position: p, rate: rate)
            _playing = true
        }
        isReversing = false
        playStartHost = startHost - p
        isPlaying = true
        audioDo { audio in
            audio.rate = rate
            audio.schedule(from: p)
            audio.play(atHostSeconds: startHost)
        }
        startProgressTimer()
        if jumpBeats > 0 { armJump() }
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
        lock.withLock {
            _clock.setRate(r * _dir, at: CACurrentMediaTime())
            _pendingJump?.rate = r
        }
        let rate = effectiveSpeed
        audioDo { $0.rate = rate }
    }

    /// 最後まで行ったときの処理。描画ループとタイマーの両方から呼ばれる。
    private func checkEnd(at host: Double) {
        guard isPlaying, duration > 0 else { return }
        let pos = clock.position(at: host)
        if isReversing {
            // 逆向きにイン点まで来た → 順向きに戻す（往復以外に切り替えられていたら、その動きに従う）
            guard pos <= inPoint else { return }
            switch currentEndAction {
            case .pingpong, .loop: playFromStart()
            case .blackout: stopAndRearm(); onBlackoutEnd?()
            case .hold: holdAt(inPoint)
            }
            return
        }
        guard pos >= outTime else { return }
        switch currentEndAction {
        case .loop:
            playFromStart()
        case .pingpong:
            startReverse()
        case .blackout:
            stopAndRearm()
            onBlackoutEnd?()
        case .hold:
            // アウト点のフレームを表示したまま止める
            holdAt(max(outTime - 0.0005, inPoint))
        }
    }

    /// その位置のコマを表示したまま止める
    private func holdAt(_ d: Double) {
        cancelJump()
        isPlaying = false
        lock.withLock {
            _clock.freeze(at: d)
            _playing = false
        }
        audioDo { $0.stop() }
        currentTime = d
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - 描画側から呼ばれる

    /// host 時刻に表示すべきフレーム。前回から変わっていなければ nil。
    /// 描画スレッドから呼ばれる（メインスレッドが忙しくても映像が止まらないように）。
    func frameForDisplay(at host: Double) -> CVPixelBuffer? {
        applyPendingJump(at: host)
        let (stream, p, ended) = lock.withLock { () -> (FrameStream?, Double, Bool) in
            let p = _playing ? _clock.position(at: host) : _clock.anchorPos
            let ended = _playing && _dur > 0 && !endCheckPending && (_dir > 0 ? p >= _out : p <= _in)
            if ended { endCheckPending = true }
            // アウト点のコマ自体は出さない（アウト点の直前のコマまで）
            let shown = _dir < 0 ? max(p, _in) : (_out > 0 ? min(p, max(_out - 0.002, 0)) : p)
            return (_active, shown, ended)
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
            audioDo { $0.connect() }
            resyncAudioToVideo()
        } else {
            audioDo { audio in
                audio.connect()
                audio.rate = rate
                audio.schedule(from: self.inPoint)
            }
        }
    }

    /// 映像の時計に合わせて、音声を続きの位置から鳴らし直す（再生中のとき）
    private func resyncAudioToVideo() {
        guard isPlaying else { return }
        let rate = effectiveSpeed
        let host = CACurrentMediaTime() + Self.startMargin
        let pos = clock.position(at: host)
        let reverse = isReversing
        audioDo { audio in
            audio.rate = rate
            if reverse {
                if audio.scheduleReversed(from: pos) { audio.play(atHostSeconds: host) }
            } else {
                audio.schedule(from: pos)
                audio.play(atHostSeconds: host)
            }
        }
    }

    /// 音声の操作を音声キューで行う
    private func audioDo(_ work: @escaping (AudioClip) -> Void) {
        guard let audio else { return }
        AudioClip.queue.async { work(audio) }
    }
}
