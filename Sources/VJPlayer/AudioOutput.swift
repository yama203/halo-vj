import AVFoundation
import ObjCSupport
import AudioToolbox
import CoreAudio
import CryptoKit

extension Notification.Name {
    /// 音声エンジンが再起動した（デバイス変更・抜き差し）。各クリップは音声を組み直す。
    static let audioEngineRestarted = Notification.Name("VJPlayer.audioEngineRestarted")
}

/// アプリ全体で1つの AVAudioEngine。起動時から動かし続けて、再生開始の遅れをなくす。
final class AudioOutput {
    static let shared = AudioOutput()

    let engine = AVAudioEngine()
    /// マスター音量（ミックスの後ろ）。録画・音に反応させるは、この手前（ミックスの出口）で聞くので、
    /// マスター音量を下げても・ミュートしても音は届く
    let masterMixer = AVAudioMixerNode()
    private var deviceUID: String?

    private init() {
        _ = engine.mainMixerNode
        let fmt = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.attach(masterMixer)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: masterMixer, format: fmt)
        engine.connect(masterMixer, to: engine.outputNode, format: fmt)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
        startEngine()
    }

    private func startEngine() {
        engine.prepare()
        do { try engine.start() } catch { NSLog("VJPlayer: 音声エンジンを開始できません \(error)") }
    }

    /// セルフテスト用：ミキサーの後ろに音量 0 のミキサーをはさんで、スピーカーから一切音を出さない。
    /// （テストはマスター音量を上げ下げして確かめるので、ミキサーの音量だけでは鳴ってしまう）
    private(set) var silenced = false
    func silenceForTests() {
        guard !silenced else { return }
        silenced = true
        engine.stop()
        let silencer = AVAudioMixerNode()
        engine.attach(silencer)
        let fmt = masterMixer.outputFormat(forBus: 0)
        engine.disconnectNodeOutput(masterMixer)
        engine.connect(masterMixer, to: silencer, format: fmt)
        engine.connect(silencer, to: engine.outputNode, format: fmt)
        silencer.outputVolume = 0
        startEngine()
    }

    // ミキサーの出口の音を聞く（録画・音に反応させる）。タップは 1 つにして、聞く人に配る
    private let listenLock = NSLock()
    private var listeners: [UUID: (AVAudioPCMBuffer, AVAudioTime) -> Void] = [:]
    private var tapOn = false

    func addMixerListener(_ f: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) -> UUID {
        let id = UUID()
        listenLock.withLock { listeners[id] = f }
        if !tapOn {
            let mixer = engine.mainMixerNode
            let fmt = mixer.outputFormat(forBus: 0)
            if fmt.sampleRate > 0 {
                mixer.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, when in
                    guard let self else { return }
                    let ls = self.listenLock.withLock { Array(self.listeners.values) }
                    for l in ls { l(buf, when) }
                }
                tapOn = true
            }
        }
        return id
    }

    func removeMixerListener(_ id: UUID) {
        let empty = listenLock.withLock { () -> Bool in
            listeners[id] = nil
            return listeners.isEmpty
        }
        if empty && tapOn {
            engine.mainMixerNode.removeTap(onBus: 0)
            tapOn = false
        }
    }

    func ensureRunning() {
        if !engine.isRunning { restart() }
    }

    private func restart() {
        engine.stop()
        applyDevice()
        startEngine()
        NotificationCenter.default.post(name: .audioEngineRestarted, object: nil)
    }

    /// 出力デバイスを変える（nil ならシステム既定）
    func setDevice(uid: String?) {
        guard uid != deviceUID else { return }
        deviceUID = uid
        restart()
    }

    private func applyDevice() {
        guard var id = deviceUID.flatMap(AudioDevices.deviceID(forUID:)) ?? AudioDevices.defaultOutputDeviceID(),
              let unit = engine.outputNode.audioUnit else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// 秒（CACurrentMediaTime と同じ時計）→ AVAudioTime
    static func audioTime(atHostSeconds s: Double) -> AVAudioTime {
        AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: s))
    }
}

/// 1クリップぶんの音声。プレイヤー → タイムストレッチ（速度変更しても音程維持）→ ミキサー
final class AudioClip {
    /// 音声の操作（数ms かかることがある）はメインスレッドを止めないようにこのキューで順番に行う
    static let queue = DispatchQueue(label: "VJPlayer.audio", qos: .userInteractive)

    let file: AVAudioFile
    let node = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    /// 予約済みでまだ鳴らしていない区間の開始位置（鳴らした・止めたら nil）
    private(set) var pendingStart: Double?
    /// 予約した区間の開始位置（秒）。プレイヤーの時刻はここからの経過になる
    private(set) var scheduledStart = 0.0
    /// 逆再生の区間を予約しているか（位置は scheduledStart から戻っていく）
    private(set) var scheduledReverse = false

    /// 逆再生用：lower〜upper 秒の区間を逆順に書き出したファイル（往復モードのときだけ作る）
    private var reversed: (file: AVAudioFile, lower: Double, upper: Double)?
    private lazy var reversedURL: URL = AudioCache.directory
        .appendingPathComponent("reverse-\(UUID().uuidString).caf")

    /// lower〜upper 秒を逆順にした音声ファイルを用意する（音声キューで呼ぶ）。
    /// 順再生と同じく「ファイルの区間を予約」で鳴らすため、メモリに全部は持たない
    func prepareReversed(lower: Double, upper: Double) {
        if let r = reversed, abs(r.lower - lower) < 0.0005, abs(r.upper - upper) < 0.0005 { return }
        let sr = sampleRate
        let f0 = AVAudioFramePosition(max(lower, 0) * sr)
        let f1 = min(AVAudioFramePosition(upper * sr), file.length)
        guard f1 > f0 else { reversed = nil; return }
        let fmt = file.processingFormat
        let tmp = reversedURL.deletingPathExtension().appendingPathExtension("tmp.caf")
        do {
            // 再生中のプレイヤーが使っているファイルの読み位置を動かさないよう、別に開いて読む
            let src = try AVAudioFile(forReading: file.url, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            try? FileManager.default.removeItem(at: tmp)
            let dst = try AVAudioFile(forWriting: tmp, settings: src.fileFormat.settings,
                                      commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            let chunk = AVAudioFrameCount(sr)   // 1 秒ずつ後ろから
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk),
                  let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return }
            var end = f1
            while end > f0 {
                let start = max(f0, end - AVAudioFramePosition(chunk))
                let n = AVAudioFrameCount(end - start)
                src.framePosition = start
                try src.read(into: buf, frameCount: n)
                guard let ch = buf.floatChannelData, let o = out.floatChannelData else { return }
                let len = Int(buf.frameLength), st = buf.stride
                for c in 0..<Int(fmt.channelCount) {
                    for i in 0..<len { o[c][i * st] = ch[c][(len - 1 - i) * st] }
                }
                out.frameLength = buf.frameLength
                try dst.write(from: out)
                end = start
            }
        } catch {
            NSLog("VJPlayer: 逆再生用の音声を作れません \(error)")
            reversed = nil
            return
        }
        do {
            try? FileManager.default.removeItem(at: reversedURL)
            try FileManager.default.moveItem(at: tmp, to: reversedURL)
            let f = try AVAudioFile(forReading: reversedURL, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            reversed = (f, Double(f0) / sr, Double(f0) / sr + Double(f.length) / sr)
        } catch {
            NSLog("VJPlayer: 逆再生用の音声を開けません \(error)")
            reversed = nil
        }
    }

    func dropReversed() {
        reversed = nil
        try? FileManager.default.removeItem(at: reversedURL)
    }

    /// pos 秒から逆向きに鳴らせるように予約する。用意が無ければ false（その間は無音）
    @discardableResult
    func scheduleReversed(from pos: Double) -> Bool {
        node.stop()
        pendingStart = nil
        guard let r = reversed, pos > r.lower else { return false }
        let sr = sampleRate
        let skip = AVAudioFramePosition(max(min((r.upper - pos) * sr, Double(r.file.length)), 0))
        guard skip < r.file.length else { return false }
        scheduledStart = r.upper - Double(skip) / sr
        scheduledReverse = true
        node.scheduleSegment(r.file, startingFrame: skip, frameCount: AVAudioFrameCount(r.file.length - skip), at: nil)
        return true
    }

    var sampleRate: Double { file.processingFormat.sampleRate }
    var duration: Double { Double(file.length) / sampleRate }

    init(file: AVAudioFile) {
        self.file = file
        connect()
    }

    deinit {
        try? FileManager.default.removeItem(at: reversedURL)
        node.stop()
        let engine = AudioOutput.shared.engine
        engine.detach(node)
        engine.detach(timePitch)
    }

    /// エンジン再起動後に接続し直す
    func connect() {
        let engine = AudioOutput.shared.engine
        if node.engine == nil { engine.attach(node) }
        if timePitch.engine == nil { engine.attach(timePitch) }
        engine.connect(node, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
    }

    var rate: Double {
        get { Double(timePitch.rate) }
        set { timePitch.rate = Float(newValue) }
    }

    /// pos 秒の位置から再生できるように予約しておく（まだ鳴らさない）
    func schedule(from pos: Double) {
        node.stop()
        let start = AVAudioFramePosition(max(pos, 0) * sampleRate)
        scheduledStart = Double(start) / sampleRate
        scheduledReverse = false
        pendingStart = scheduledStart
        guard start < file.length else { return }
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length - start), at: nil)
    }

    func play(atHostSeconds s: Double) {
        AudioOutput.shared.ensureRunning()
        pendingStart = nil
        // AVAudioPlayerNode は条件によって時刻指定の再生を例外（player did not see an IO cycle）で
        // 断ることがある。落ちないようにつかまえて、少し待ってやり直し、だめなら時刻指定なしで鳴らす
        let when = AudioOutput.audioTime(atHostSeconds: s)
        if VJTryCatch({ node.play(at: when) }) == nil { return }
        usleep(5_000)
        if let e = VJTryCatch({ node.play(at: when) }) {
            NSLog("VJPlayer: 時刻指定の再生に失敗（%@）。時刻指定なしで鳴らします", e.reason ?? e.name.rawValue)
            _ = VJTryCatch { node.play() }
        }
    }

    func stop() {
        node.stop()
        pendingStart = nil
    }

    /// 現在の音声の再生位置（秒）と、その位置が鳴る時刻。同期チェック用。
    func renderedPosition() -> (pos: Double, hostSeconds: Double)? {
        guard let nodeTime = node.lastRenderTime, nodeTime.isHostTimeValid,
              let pt = node.playerTime(forNodeTime: nodeTime) else { return nil }
        let t = Double(pt.sampleTime) / pt.sampleRate
        return (scheduledReverse ? scheduledStart - t : scheduledStart + t,
                AVAudioTime.seconds(forHostTime: nodeTime.hostTime))
    }
}

/// 動画の音声トラックを PCM の .caf に書き出してキャッシュする（~/Library/Caches/Halo VJ/audio）
enum AudioCache {
    /// ~/Library/Caches/Halo VJ/audio
    static var directory: URL {
        let dir = AppInfo.cacheDirectory.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func file(for asset: AVURLAsset, url: URL) async throws -> AVAudioFile? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = SHA256.hash(data: Data("\(url.path)|\(size)|\(mtime)".utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        let dir = AppInfo.cacheDirectory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(key).caf")

        if FileManager.default.fileExists(atPath: dest.path), let f = try? AVAudioFile(forReading: dest) {
            return f
        }

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let tmp = dir.appendingPathComponent("\(key).tmp.caf")
        try? FileManager.default.removeItem(at: tmp)
        var writer: AVAudioFile?
        while let sb = out.copyNextSampleBuffer() {
            guard let fd = CMSampleBufferGetFormatDescription(sb) else { continue }
            let fmt = AVAudioFormat(cmAudioFormatDescription: fd)
            let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { continue }
            buf.frameLength = n
            let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
            guard st == noErr else { continue }
            if writer == nil {
                writer = try AVAudioFile(forWriting: tmp, settings: fmt.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
            }
            try writer?.write(from: buf)
        }
        guard reader.status == .completed, writer != nil else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        writer = nil // 閉じる
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return try AVAudioFile(forReading: dest)
    }
}
