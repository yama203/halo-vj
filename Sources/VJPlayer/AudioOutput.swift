import AVFoundation
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
    private var deviceUID: String?

    private init() {
        _ = engine.mainMixerNode
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
    private(set) var isScheduledFromStart = false
    /// 予約した区間の開始位置（秒）。プレイヤーの時刻はここからの経過になる
    private(set) var scheduledStart = 0.0

    var sampleRate: Double { file.processingFormat.sampleRate }
    var duration: Double { Double(file.length) / sampleRate }

    init(file: AVAudioFile) {
        self.file = file
        connect()
    }

    deinit {
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
        isScheduledFromStart = start == 0
        scheduledStart = Double(start) / sampleRate
        guard start < file.length else { return }
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length - start), at: nil)
    }

    func play(atHostSeconds s: Double) {
        AudioOutput.shared.ensureRunning()
        isScheduledFromStart = false
        node.play(at: AudioOutput.audioTime(atHostSeconds: s))
    }

    func stop() {
        node.stop()
        isScheduledFromStart = false
    }

    /// 現在の音声の再生位置（秒）と、その位置が鳴る時刻。同期チェック用。
    func renderedPosition() -> (pos: Double, hostSeconds: Double)? {
        guard let nodeTime = node.lastRenderTime, nodeTime.isHostTimeValid,
              let pt = node.playerTime(forNodeTime: nodeTime) else { return nil }
        return (scheduledStart + Double(pt.sampleTime) / pt.sampleRate, AVAudioTime.seconds(forHostTime: nodeTime.hostTime))
    }
}

/// 動画の音声トラックを PCM の .caf に書き出してキャッシュする（~/Library/Caches/VJPlayer/audio）
enum AudioCache {
    static func file(for asset: AVURLAsset, url: URL) async throws -> AVAudioFile? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = SHA256.hash(data: Data("\(url.path)|\(size)|\(mtime)".utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VJPlayer/audio", isDirectory: true)
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
