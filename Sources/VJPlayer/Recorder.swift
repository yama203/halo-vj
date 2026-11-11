import AVFoundation
import AppKit
import CoreVideo
import Metal
import QuartzCore
import simd
import SwiftUI

// コンポジションの録画。描画スレッドが合成した絵（コーナーピンの前・パッドのエフェクト込み）を、
// そのまま動画ファイルに書く。音はアプリの音声ミキサーの出口から取る（クリップの音）。
// 絵は決めたフレームレートのコマ番号で時刻を付ける（描画が遅れたコマは飛ぶだけで、時間はずれない）。

/// 録画の設定（アプリの設定として残す）
struct RecordSettings: Equatable {
    enum Codec: String, CaseIterable, Identifiable {
        case h264, hevc, prores422, prores422HQ
        var id: String { rawValue }
        var label: String {
            switch self {
            case .h264: L("H.264（どこでも再生できる）")
            case .hevc: L("HEVC / H.265（ファイルが小さい）")
            case .prores422: L("ProRes 422（編集向け・大きい）")
            case .prores422HQ: L("ProRes 422 HQ（いちばんきれい・とても大きい）")
            }
        }
        var short: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            case .prores422: "ProRes 422"
            case .prores422HQ: "ProRes HQ"
            }
        }
        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc: .hevc
            case .prores422: .proRes422
            case .prores422HQ: .proRes422HQ
            }
        }
        var fileType: AVFileType { self == .h264 || self == .hevc ? .mp4 : .mov }
        var ext: String { fileType == .mp4 ? "mp4" : "mov" }
        var isProRes: Bool { self == .prores422 || self == .prores422HQ }
    }

    enum Size: String, CaseIterable, Identifiable {
        case output, p720, p1080, p1440, p2160
        var id: String { rawValue }
        var label: String {
            switch self {
            case .output: L("出力と同じ")
            case .p720: L("720p（高さ 720）")
            case .p1080: L("1080p（高さ 1080）")
            case .p1440: L("1440p（高さ 1440）")
            case .p2160: L("4K（高さ 2160）")
            }
        }
        var height: Int? {
            switch self {
            case .output: nil
            case .p720: 720
            case .p1080: 1080
            case .p1440: 1440
            case .p2160: 2160
            }
        }
    }

    var codec: Codec = .h264
    var fps: Int = 60
    var size: Size = .output
    var audio = true
    /// 保存先（nil なら ムービー/Halo VJ 録画）
    var folder: URL?

    static let defaultFolder: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Halo VJ 録画", isDirectory: true)
    var folderURL: URL { folder ?? Self.defaultFolder }

    /// 出力の大きさ（w, h）と縦横比から、録画の大きさを決める（偶数にそろえる）
    func pixelSize(outputSize: (Int, Int)?, aspect: Double) -> (Int, Int) {
        let a = aspect > 0.05 ? aspect : 16.0 / 9
        var w: Int, h: Int
        if let hh = size.height {
            h = hh; w = Int((Double(hh) * a).rounded())
        } else if let o = outputSize {
            (w, h) = o
        } else {
            h = 1080; w = Int((1080 * a).rounded())
        }
        // H.264 は 4096 までなので、大きすぎる時は縮める
        let limit = codec == .h264 ? 4096 : 8192
        if max(w, h) > limit {
            let k = Double(limit) / Double(max(w, h))
            w = Int(Double(w) * k); h = Int(Double(h) * k)
        }
        return (max(w & ~1, 16), max(h & ~1, 16))
    }

    // 設定の読み書き（アプリの UserDefaults）
    private static let key = "recordSettings"
    static func load(_ d: UserDefaults = .standard) -> RecordSettings {
        var s = RecordSettings()
        guard let dict = d.dictionary(forKey: key) else { return s }
        if let c = (dict["codec"] as? String).flatMap(Codec.init) { s.codec = c }
        if let f = dict["fps"] as? Int, [24, 25, 30, 50, 60].contains(f) { s.fps = f }
        if let z = (dict["size"] as? String).flatMap(Size.init) { s.size = z }
        if let a = dict["audio"] as? Bool { s.audio = a }
        if let p = dict["folder"] as? String, !p.isEmpty { s.folder = URL(fileURLWithPath: p, isDirectory: true) }
        return s
    }
    func save(_ d: UserDefaults = .standard) {
        d.set(["codec": codec.rawValue, "fps": fps, "size": size.rawValue, "audio": audio,
               "folder": folder?.path ?? ""], forKey: Self.key)
    }
}

/// 録画（アプリ全体で 1 つ）。start / stop はメインスレッドから。絵は描画スレッドから渡される
final class Recorder: ObservableObject {
    static let shared = Recorder()

    /// 画面に出す状態（メインスレッド）
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var lastFile: URL?
    @Published private(set) var lastError: String?
    @Published var settings: RecordSettings {
        didSet { if !forTests { settings.save() } }
    }
    /// セルフテスト中は設定を保存しない（使っているアプリの設定を書き換えないように）
    var forTests = false

    private let ctx = MetalContext.shared
    private let writeQueue = DispatchQueue(label: "VJPlayer.recorder")
    private let lock = NSLock()
    /// ここから下は lock の中で（描画スレッド・書き込みのキュー・音のスレッドから触る）
    private var session: Session?

    private final class Session {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audio: AVAssetWriterInput?
        let url: URL
        let width: Int, height: Int, fps: Int
        let start: Double
        var lastIndex: Int64 = -1
        var frames = 0
        var dropped = 0
        var stopping = false
        var audioFormat: CMAudioFormatDescription?
        var textureCache: CVMetalTextureCache?
        init(writer: AVAssetWriter, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
             audio: AVAssetWriterInput?, url: URL, width: Int, height: Int, fps: Int, start: Double) {
            self.writer = writer; self.video = video; self.adaptor = adaptor; self.audio = audio
            self.url = url; self.width = width; self.height = height; self.fps = fps; self.start = start
        }
    }

    private var timer: Timer?
    private var tapID: UUID?

    private init() {
        settings = RecordSettings.load()
    }

    /// 録画の大きさ（描画スレッドが合成の大きさを決めるのに使う。録画していなければ nil）
    func activeSize() -> (Int, Int)? {
        lock.withLock { session.flatMap { $0.stopping ? nil : ($0.width, $0.height) } }
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    /// 録画を始める。大きさは今の出力の設定から
    @discardableResult
    func start(outputSize: (Int, Int)? = nil, aspect: Double? = nil, to fileURL: URL? = nil) -> Bool {
        guard !isRecording else { return true }
        let eng = Engine.shared
        let fmt = eng.outputFormat
        let s = settings
        let (w, h) = s.pixelSize(outputSize: outputSize ?? fmt.size, aspect: aspect ?? eng.outputAspect)
        let url: URL
        if let fileURL {
            url = fileURL
        } else {
            guard let u = newFileURL(ext: s.codec.ext) else { return false }
            url = u
        }
        try? FileManager.default.removeItem(at: url)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: s.codec.fileType)
            var vs: [String: Any] = [
                AVVideoCodecKey: s.codec.avCodec,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]
            if !s.codec.isProRes {
                // 動きの多い VJ の絵でも崩れにくいように、やや多めの量
                let bpp = s.codec == .hevc ? 0.11 : 0.16
                vs[AVVideoCompressionPropertiesKey] = [
                    AVVideoAverageBitRateKey: Int(Double(w * h * s.fps) * bpp),
                    AVVideoExpectedSourceFrameRateKey: s.fps,
                    AVVideoMaxKeyFrameIntervalKey: s.fps * 2,
                    AVVideoAllowFrameReorderingKey: false,
                ]
            }
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
            video.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ])
            guard writer.canAdd(video) else { throw RecordError.cannotAdd }
            writer.add(video)
            var audio: AVAssetWriterInput?
            if s.audio {
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: s.codec.isProRes ? [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ] : [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256_000,
                ])
                a.expectsMediaDataInRealTime = true
                if writer.canAdd(a) { writer.add(a); audio = a }
            }
            guard writer.startWriting() else { throw writer.error ?? RecordError.cannotAdd }
            writer.startSession(atSourceTime: .zero)
            let sess = Session(writer: writer, video: video, adaptor: adaptor, audio: audio, url: url,
                               width: w, height: h, fps: s.fps, start: CACurrentMediaTime())
            CVMetalTextureCacheCreate(nil, nil, ctx.device, nil, &sess.textureCache)
            lock.withLock { session = sess }
        } catch {
            lastError = L("録画を始められません：\(error.localizedDescription)")
            return false
        }
        if s.audio { installTap() }
        lastError = nil
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let st = self.lock.withLock { self.session?.start }
            if let st { self.elapsed = CACurrentMediaTime() - st }
        }
        return true
    }

    private enum RecordError: Error { case cannotAdd }

    /// 保存先のフォルダに、日時の名前の新しいファイルの場所を作る（フォルダが無ければ作る）。
    /// 静止画の保存（スナップショット）も同じ決め方を使う。folder を渡すとそこに（テスト用）。
    /// 作れなければ lastError に書いて nil
    func newFileURL(ext: String, in folder: URL? = nil) -> URL? {
        let dir = folder ?? settings.folderURL
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            lastError = L("保存先のフォルダを作れません：\(dir.path)")
            return nil
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(AppInfo.name) \(df.string(from: Date()))"
        var url = dir.appendingPathComponent("\(base).\(ext)")
        // 同じ秒に 2 つ作ったときは、番号を付けて上書きしない
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// 録画以外で保存したもの（静止画）を、録画と同じ所（録画の設定の下）で知らせる
    func noteSaved(_ url: URL?, error: String? = nil) {
        if let url { lastFile = url }
        lastError = error
    }

    /// 録画を止めて、ファイルを閉じる。done は書き終わったら（メインスレッドで）
    func stop(done: ((URL?) -> Void)? = nil) {
        timer?.invalidate(); timer = nil
        removeTap()
        guard let sess = lock.withLock({ () -> Session? in
            session?.stopping = true
            return session
        }) else { isRecording = false; done?(nil); return }
        isRecording = false
        // 書きかけのコマを待ってから閉じる
        writeQueue.async { [weak self] in
            sess.video.markAsFinished()
            sess.audio?.markAsFinished()
            let end = CMTime(value: max(sess.lastIndex + 1, 1), timescale: CMTimeScale(sess.fps))
            sess.writer.endSession(atSourceTime: end)
            sess.writer.finishWriting {
                let ok = sess.writer.status == .completed && sess.frames > 0
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lock.withLock { if self.session === sess { self.session = nil } }
                    if ok {
                        self.lastFile = sess.url
                    } else {
                        self.lastError = L("録画を保存できませんでした") + (sess.writer.error.map { L("：\($0.localizedDescription)") } ?? "")
                        if sess.frames == 0 { try? FileManager.default.removeItem(at: sess.url) }
                    }
                    done?(ok ? sess.url : nil)
                }
            }
        }
    }

    /// 今の録画で書いたコマ数・落としたコマ数（テスト・表示用）
    func counts() -> (frames: Int, dropped: Int) {
        lock.withLock { (session?.frames ?? 0, session?.dropped ?? 0) }
    }

    // MARK: 絵（描画スレッドから）

    /// 合成の絵を 1 コマ分渡す。now は描画した時刻。コマ番号が進んでいなければ何もしない
    func capture(_ texture: MTLTexture?, master: Float, fit: simd_float3x3 = matrix_identity_float3x3,
                 now: Double = CACurrentMediaTime()) {
        guard let sess = lock.withLock({ session }), !sess.stopping else { return }
        let idx = Int64(((now - sess.start) * Double(sess.fps)).rounded(.down))
        guard idx > sess.lastIndex else { return }
        guard sess.video.isReadyForMoreMediaData, let pool = sess.adaptor.pixelBufferPool, let cache = sess.textureCache else {
            lock.withLock { sess.dropped += 1 }
            return
        }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { lock.withLock { sess.dropped += 1 }; return }
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, sess.width, sess.height, 0, &cvTex)
        guard let cvTex, let dst = CVMetalTextureGetTexture(cvTex), let cb = ctx.queue.makeCommandBuffer() else {
            lock.withLock { sess.dropped += 1 }; return
        }
        lock.withLock { sess.lastIndex = idx }
        RenderLoop.shared.drawComposite(texture, into: dst, master: master, fit: fit, cb: cb)
        cb.addCompletedHandler { [weak self] _ in
            _ = cvTex
            self?.writeQueue.async {
                // 止めたあとに描き終わったコマは入れない（閉じた入れ口に入れると落ちる）
                guard let self, !self.lock.withLock({ sess.stopping }), sess.writer.status == .writing else { return }
                if sess.video.isReadyForMoreMediaData,
                   sess.adaptor.append(pb, withPresentationTime: CMTime(value: idx, timescale: CMTimeScale(sess.fps))) {
                    self.lock.withLock { sess.frames += 1 }
                } else {
                    self.lock.withLock { sess.dropped += 1 }
                }
            }
        }
        cb.commit()
    }

    // MARK: 音（音声エンジンのスレッドから）

    private func installTap() {
        guard tapID == nil else { return }
        tapID = AudioOutput.shared.addMixerListener { [weak self] buf, when in
            self?.appendAudio(buf, when: when)
        }
    }

    private func removeTap() {
        guard let id = tapID else { return }
        AudioOutput.shared.removeMixerListener(id)
        tapID = nil
    }

    private func appendAudio(_ buf: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let sess = lock.withLock({ session }), !sess.stopping, let input = sess.audio else { return }
        let t = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : CACurrentMediaTime()
        let rel = t - sess.start
        guard rel >= 0, buf.frameLength > 0 else { return }
        var fmtDesc = sess.audioFormat
        if fmtDesc == nil {
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: buf.format.streamDescription, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmtDesc)
            lock.withLock { sess.audioFormat = fmtDesc }
        }
        guard let fmtDesc else { return }
        let sr = buf.format.sampleRate
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sr)),
                                        presentationTimeStamp: CMTime(seconds: rel, preferredTimescale: CMTimeScale(sr)),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: fmtDesc, sampleCount: CMItemCount(buf.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &sb) == noErr, let sb else { return }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: buf.audioBufferList) == noErr else { return }
        writeQueue.async { [weak self] in
            guard let self, !self.lock.withLock({ sess.stopping }), sess.writer.status == .writing,
                  input.isReadyForMoreMediaData else { return }
            input.append(sb)
        }
    }
}

/// 上のバーの録画ボタン（押すと録画を始める・止める。右の ▾ で設定）
struct RecordButton: View {
    @ObservedObject private var rec = Recorder.shared
    @State private var open = false
    @State private var blink = false

    var body: some View {
        HStack(spacing: 2) {
            Button { rec.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: rec.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(rec.isRecording ? Color.red : Color.primary)
                        .opacity(rec.isRecording && blink ? 0.45 : 1)
                    Text(rec.isRecording ? Self.timeText(rec.elapsed) : L("録画"))
                        .monospacedDigit()
                        .foregroundStyle(rec.isRecording ? Color.red : Color.primary)
                }
            }
            .help(rec.isRecording ? L("録画を止めて保存する（⌘R）") : L("コンポジションを録画する（⌘R）"))
            Button { open.toggle() } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                .help(L("録画の設定"))
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    RecordSettingsView().padding(16).frame(width: 400)
                }
        }
        .onChange(of: rec.isRecording) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { blink = true }
            } else {
                withAnimation(.default) { blink = false }
            }
        }
    }

    static func timeText(_ t: Double) -> String {
        let s = Int(max(t, 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct RecordSettingsView: View {
    @ObservedObject private var rec = Recorder.shared
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("コンポジションの録画")).font(.headline)
            Text(L("合成した絵（四隅の調整の前・パッドのエフェクト込み）と、クリップの音を録ります。録画中は設定を変えられません。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker(L("形式"), selection: $rec.settings.codec) {
                    ForEach(RecordSettings.Codec.allCases) { Text($0.label).tag($0) }
                }
                Picker(L("大きさ"), selection: $rec.settings.size) {
                    ForEach(RecordSettings.Size.allCases) { Text($0.label).tag($0) }
                }
                Picker(L("フレームレート"), selection: $rec.settings.fps) {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Toggle(L("音も録る"), isOn: $rec.settings.audio)
            }
            .disabled(rec.isRecording)
            let (w, h) = rec.settings.pixelSize(outputSize: engine.outputFormat.size, aspect: engine.outputAspect)
            Text(L("録画の大きさ：\(w) × \(h)、\(rec.settings.fps) fps")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text(L("保存先")).font(.system(size: 12))
                Text(rec.settings.folderURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("変える…")) { chooseFolder() }.disabled(rec.isRecording)
                Button(L("開く")) {
                    try? FileManager.default.createDirectory(at: rec.settings.folderURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(rec.settings.folderURL)
                }
            }
            if let f = rec.lastFile {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("保存しました：\(f.lastPathComponent)")).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Finder で表示")) { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                }
            }
            if let e = rec.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = L("ここに保存")
        p.directoryURL = rec.settings.folderURL
        if p.runModal() == .OK, let u = p.url { rec.settings.folder = u }
    }
}
