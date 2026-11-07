import AVFoundation
import AudioToolbox
import CoreAudio
import SwiftUI

// 音に反応させる：音（アプリの音＝クリップの音、またはマイク・ライン入力などの入力デバイス）を、
// 音量・低音・中音・高音・アタック（キックなどの立ち上がり）の 5 つの 0〜1 の値にする。
// どのパラメーターも、動かし方を「音」にすると、この値で「から」〜「まで」の間を動く。

/// 音のどの部分で動かすか
enum AudioBand: Int, Codable, CaseIterable, Identifiable {
    case level, low, mid, high, attack
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .level: "音量"
        case .low: "低音"
        case .mid: "中音"
        case .high: "高音"
        case .attack: "アタック"
        }
    }
    var help: String {
        switch self {
        case .level: "音全体の大きさ"
        case .low: "キック・ベースのあたり（〜150 Hz）"
        case .mid: "声・ギター・スネアのあたり（150〜2500 Hz）"
        case .high: "ハイハット・シンバルのあたり（2500 Hz〜）"
        case .attack: "低音が急に大きくなった瞬間（キックの頭）にぱっと 1 になって、すっと戻る"
        }
    }
}

/// パラメーターと音のつなぎ方（動かし方が「音」のとき）
struct AudioLink: Codable, Equatable {
    var band = AudioBand.level
    /// 感度（音の値に掛ける）
    var gain = 1.0
}

/// 音の解析（音声のスレッドで使う。ほかからは触らない）
struct AudioAnalyzer {
    private struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
        // RBJ のフィルター
        static func make(_ kind: Int, f: Double, q: Double, sr: Double) -> Biquad {
            let w = 2 * Double.pi * f / sr, cw = cos(w), al = sin(w) / (2 * q)
            var b = Biquad()
            let a0: Double
            switch kind {
            case 0:  // ローパス
                b.b0 = (1 - cw) / 2; b.b1 = 1 - cw; b.b2 = (1 - cw) / 2
            case 1:  // ハイパス
                b.b0 = (1 + cw) / 2; b.b1 = -(1 + cw); b.b2 = (1 + cw) / 2
            default: // バンドパス（山の高さ 0 dB）
                b.b0 = al; b.b1 = 0; b.b2 = -al
            }
            a0 = 1 + al
            b.a1 = -2 * cw / a0; b.a2 = (1 - al) / a0
            b.b0 /= a0; b.b1 /= a0; b.b2 /= a0
            return b
        }
    }

    private var sr = 0.0
    private var low = Biquad(), mid = Biquad(), high = Biquad()
    /// 0 音量, 1 低音, 2 中音, 3 高音 の、なめらかにした大きさと、自動で合わせるための最近の大きさの山
    private var env = [Double](repeating: 0, count: 4)
    private var peak = [Double](repeating: Self.floor, count: 4)
    /// これより小さい音は無音とみなす（約 -66 dBFS。内蔵マイクの小さな声でも動くように）
    static let floor = 0.0005
    private var lowAvg = 0.0
    var lastOnset = -10.0
    /// BPM の自動検出用：256 サンプルごとの立ち上がりの強さ（読んだら空にする）
    var onsets: [Double] = []
    private var subLow = 0.0, subAll = 0.0, subN = 0
    private var prevLowE = 1e-6, prevAllE = 1e-6
    static let onsetHop = 256

    /// samples（モノラル）を読んで、0〜1 の 4 つの値（音量・低音・中音・高音）を返す。アタックは lastOnset に入る
    mutating func process(_ samples: UnsafePointer<Float>, count n: Int, sampleRate: Double, time: Double,
                          release: Double, autoGain: Bool) -> [Double] {
        if sr != sampleRate {
            sr = sampleRate
            low = .make(0, f: 150, q: 0.707, sr: sr)
            high = .make(1, f: 2500, q: 0.707, sr: sr)
            mid = .make(2, f: 620, q: 0.6, sr: sr)
        }
        var s = [Double](repeating: 0, count: 4)
        for i in 0..<n {
            let x = Double(samples[i])
            let l = low.run(x), m = mid.run(x), h = high.run(x)
            s[0] += x * x; s[1] += l * l; s[2] += m * m; s[3] += h * h
            // 立ち上がりの強さ：低音と全体の大きさが、前のかたまりよりどれだけ上がったか（対数で）
            subLow += l * l; subAll += x * x; subN += 1
            if subN == Self.onsetHop {
                let le = subLow / Double(subN) + 1e-7, ae = subAll / Double(subN) + 1e-7
                onsets.append(max(log(le) - log(prevLowE), 0) + 0.5 * max(log(ae) - log(prevAllE), 0))
                prevLowE = le; prevAllE = ae
                subLow = 0; subAll = 0; subN = 0
            }
        }
        let dt = Double(n) / max(sampleRate, 1)
        let rms = s.map { ($0 / Double(max(n, 1))).squareRoot() }
        let fall = exp(-dt / max(release, 0.01))
        let peakFall = exp(-dt / 8)
        var out = [Double](repeating: 0, count: 4)
        for b in 0..<4 {
            env[b] = max(rms[b], env[b] * fall)
            peak[b] = max(env[b], peak[b] * peakFall, Self.floor)
            // 自動で合わせる：最近の山を 1 にする（静かすぎるときは 0 のまま）。合わせないときは決まった倍率
            let v = autoGain ? (peak[b] <= Self.floor * 1.2 ? 0 : env[b] / peak[b]) : env[b] * 4
            out[b] = min(max(v, 0), 1)
        }
        // アタック：低音が、最近の平均よりぐっと大きくなった瞬間
        let avgK = exp(-dt / 0.45)
        // （かたまりごとの細かなゆれで何度も反応しないように、最近の平均より、はっきり大きく上がったときだけ）
        if rms[1] - lowAvg > max(lowAvg * 0.8, Self.floor * 8) && time - lastOnset > 0.12 { lastOnset = time }
        lowAvg = lowAvg * avgK + rms[1] * (1 - avgK)
        return out
    }
}

/// 音の入力と、今の値（アプリ全体で 1 つ）
final class AudioReactive: ObservableObject {
    static let shared = AudioReactive()

    enum Source: String, CaseIterable { case off, app, input }

    @Published var source: Source = .off { didSet { if oldValue != source { restart(); save() } } }
    /// 入力デバイスの UID（nil ならシステムの既定の入力）
    @Published var inputUID: String? { didSet { if oldValue != inputUID { restart(); save() } } }
    /// 最近の大きさに合わせて 0〜1 にする（入力の音量に関係なく動く）
    @Published var autoGain = true { didSet { save() } }
    /// 音が止んだとき、値が戻る速さ（秒）
    @Published var release = 0.15 { didSet { save() } }
    @Published private(set) var errorMessage: String?
    /// セルフテスト中は設定を保存しない
    var forTests = false

    private let lock = NSLock()
    private var levels = [Double](repeating: 0, count: 4)
    private var lastOnset = -10.0
    private var lastUpdate = -10.0
    /// 届いている音の様子（画面に出して、原因を見分ける）：いちばん大きい音（dBFS）・最後に 0 でない音が来た時刻・届いたかたまりの数
    private var rawPeak = 0.0
    private var lastNonZero = -10.0
    private var buffers = 0
    private var startedAt = -10.0
    @Published private(set) var deviceName = ""
    private var analyzer = AudioAnalyzer()
    /// 音の形（スペクトラム・波形）
    let scopeLock = NSLock()
    var scopeSpectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
    var scopeWave = [Float](repeating: 0, count: 512)
    private let spectrum = SpectrumAnalyzer()
    /// BPM の自動検出用：立ち上がりの強さの並び（最近 12 秒）と、1 秒の数・最後の時刻
    private var onsetRing: [Double] = []
    private var onsetRate = 48000.0 / Double(AudioAnalyzer.onsetHop)
    private var onsetEnd = 0.0
    private var mixerListener: UUID?
    private var inputEngine: AVAudioEngine?
    /// テスト用：値を決め打ちにする（音量・低音・中音・高音・アタック）
    private var override: [Double]?

    private init() {
        let d = UserDefaults.standard
        source = Source(rawValue: d.string(forKey: "audioReact.source") ?? "") ?? .off
        inputUID = d.string(forKey: "audioReact.input")
        if d.object(forKey: "audioReact.autoGain") != nil { autoGain = d.bool(forKey: "audioReact.autoGain") }
        if d.object(forKey: "audioReact.release") != nil { release = min(max(d.double(forKey: "audioReact.release"), 0.02), 2) }
    }

    /// 起動時に呼ぶ（保存してある入力を始める）
    func startIfNeeded() { restart() }

    private func save() {
        guard !forTests else { return }
        let d = UserDefaults.standard
        d.set(source.rawValue, forKey: "audioReact.source")
        d.set(inputUID, forKey: "audioReact.input")
        d.set(autoGain, forKey: "audioReact.autoGain")
        d.set(release, forKey: "audioReact.release")
    }

    /// 今の値（0〜1。どのスレッドからでも読める）
    func level(_ band: AudioBand, at t: Double = CACurrentMediaTime()) -> Double {
        lock.withLock {
            if let override { return override[band.rawValue] }
            // しばらく音が届いていなければ、だんだん 0 に
            let stale = max(t - lastUpdate - 0.1, 0)
            let fade = stale > 0 ? exp(-stale / max(release, 0.02)) : 1
            if band == .attack { return exp(-max(t - lastOnset, 0) / max(release * 0.8, 0.05)) }
            return levels[band.rawValue] * fade
        }
    }

    func setOverrideForTest(_ v: [Double]?) { lock.withLock { override = v } }

    /// BPM の自動検出用：最近 seconds 秒の立ち上がりの強さと、1 秒の数・最後の時刻
    func onsetWindow(seconds: Double) -> ([Double], Double, Double) {
        lock.withLock {
            let n = min(onsetRing.count, Int(onsetRate * seconds))
            return (Array(onsetRing.suffix(n)), onsetRate, onsetEnd)
        }
    }

    /// 音の届き方（設定の画面に出す）
    enum Health: Equatable { case off, noBuffers, allZero, quiet(Double), ok(Double) }
    func health(at t: Double = CACurrentMediaTime()) -> Health {
        lock.withLock {
            guard source != .off else { return .off }
            if buffers == 0 || t - lastUpdate > 1 { return t - startedAt < 1 ? .ok(-120) : .noBuffers }
            if t - lastNonZero > 1.5 && t - startedAt > 1.5 { return .allZero }
            let db = 20 * log10(max(rawPeak, 1e-7))
            return db < -60 ? .quiet(db) : .ok(db)
        }
    }

    /// 音のかたまりを読む（音声のスレッド）
    func feed(_ buf: AVAudioPCMBuffer, time: Double) {
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength), chs = Int(buf.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<chs { for i in 0..<n { mono[i] += ch[c][i] } }
        if chs > 1 { let k = 1 / Float(chs); for i in 0..<n { mono[i] *= k } }
        let (rel, auto) = lock.withLock { (release, autoGain) }
        let out = mono.withUnsafeBufferPointer {
            analyzer.process($0.baseAddress!, count: n, sampleRate: buf.format.sampleRate, time: time, release: rel, autoGain: auto)
        }
        let sc = spectrum.process(mono, sampleRate: buf.format.sampleRate, autoGain: auto)
        scopeLock.withLock { scopeSpectrum = sc.spectrum; scopeWave = sc.wave }
        let onset = analyzer.lastOnset
        let newOnsets = analyzer.onsets
        analyzer.onsets.removeAll(keepingCapacity: true)
        let rate = buf.format.sampleRate / Double(AudioAnalyzer.onsetHop)
        var pk: Float = 0
        for i in 0..<n { pk = max(pk, abs(mono[i])) }
        lock.withLock {
            levels = out
            lastOnset = onset
            lastUpdate = time
            rawPeak = max(Double(pk), rawPeak * 0.9)
            if pk > 0 { lastNonZero = time }
            buffers += 1
            if abs(onsetRate - rate) > 0.01 { onsetRing.removeAll(); onsetRate = rate }
            onsetRing.append(contentsOf: newOnsets)
            let keep = Int(rate * 12)
            if onsetRing.count > keep { onsetRing.removeFirst(onsetRing.count - keep) }
            onsetEnd = time + Double(n) / buf.format.sampleRate
        }
    }

    private func restart() {
        stopAll()
        errorMessage = nil
        switch source {
        case .off:
            break
        case .app:
            mixerListener = AudioOutput.shared.addMixerListener { [weak self] buf, _ in
                self?.feed(buf, time: CACurrentMediaTime())
            }
        case .input:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                startInput()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        if ok { self.startInput() } else { self.errorMessage = "マイク（音の入力）の使用が許可されていません" }
                    }
                }
            default:
                errorMessage = "マイク（音の入力）の使用が許可されていません。システム設定 → プライバシーとセキュリティ → マイク で Halo VJ をオンにしてください"
            }
        }
    }

    private func stopAll() {
        if let id = mixerListener { AudioOutput.shared.removeMixerListener(id) }
        mixerListener = nil
        if let e = inputEngine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        inputEngine = nil
        lock.withLock { levels = [0, 0, 0, 0]; lastOnset = -10; buffers = 0; rawPeak = 0; lastNonZero = -10; startedAt = CACurrentMediaTime() }
        deviceName = ""
    }

    private func startInput() {
        guard source == .input else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        if let uid = inputUID, let dev = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            var d = dev
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let fmt = input.outputFormat(forBus: 0)
        deviceName = (inputUID.flatMap { uid in AudioDevices.inputDevices().first { $0.id == uid }?.name } ?? "システムの既定の入力")
            + String(format: "（%.0f kHz・%d ch）", fmt.sampleRate / 1000, Int(fmt.channelCount))
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            errorMessage = "入力デバイスから音を受け取れません"
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.feed(buf, time: CACurrentMediaTime())
        }
        do {
            e.prepare()
            try e.start()
            inputEngine = e
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "入力デバイスを開けません：\(error.localizedDescription)"
        }
    }
}

extension AudioDevices {
    /// 入力チャンネルを持つオーディオデバイスの一覧
    static func inputDevices() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0 else { return nil }
            guard let uid = name(id, kAudioDevicePropertyDeviceUID), let n = name(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: uid, name: n)
        }
    }

    private static func name(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard st == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}

// MARK: - 画面

/// 今の音の値の棒（音の設定・パラメーターの動かし方の欄）
struct AudioMeter: View {
    let band: AudioBand
    var gain = 1.0
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let v = min(AudioReactive.shared.level(band, at: CACurrentMediaTime()) * gain, 1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3).fill(band == .attack ? Color.orange : Color.green.opacity(0.85))
                        .frame(width: g.size.width * v)
                }
            }
            .id(ctx.date)
        }
        .frame(height: 8)
    }
}

/// 上のバーの「音の入力」ボタン（押すと設定）
struct AudioInputButton: View {
    @ObservedObject private var ar = AudioReactive.shared
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: ar.source == .off ? "waveform.slash" : "waveform")
                    .foregroundStyle(ar.errorMessage != nil ? Color.orange : (ar.source == .off ? Color.secondary : Color.green))
                Text("音の入力")
                if ar.source != .off { AudioMeter(band: .level).frame(width: 34) }
            }
        }
        .help("音に反応させる音（アプリの音・マイクやライン入力）を選ぶ。パラメーターの動かし方を「音」にすると、この音で動く")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            AudioInputSettings().padding(16).frame(width: 380)
        }
    }
}

struct AudioInputSettings: View {
    @ObservedObject private var ar = AudioReactive.shared
    @State private var devices: [AudioDevice] = AudioDevices.inputDevices()

    private enum Choice: Hashable { case off, app, input(String?) }
    private var choice: Binding<Choice> {
        Binding(get: {
            switch ar.source {
            case .off: .off
            case .app: .app
            case .input: .input(ar.inputUID)
            }
        }, set: { c in
            switch c {
            case .off: ar.source = .off
            case .app: ar.source = .app
            case .input(let uid): ar.inputUID = uid; ar.source = .input
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音に反応させる").font(.headline)
            Text("パラメーターの波形ボタンで動かし方を「音」にすると、ここで選んだ音の大きさで「から」〜「まで」の間を動く。外の音（DJ ミキサー・ほかのアプリ）は、ライン入力や BlackHole などの仮想デバイスで入れる")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("音", selection: choice) {
                    Text("オフ").tag(Choice.off)
                    Text("アプリの音（クリップの音）").tag(Choice.app)
                    Divider()
                    Text("入力：システムの既定").tag(Choice.input(nil))
                    ForEach(devices) { d in Text("入力：" + d.name).tag(Choice.input(d.id)) }
                }
                Button { devices = AudioDevices.inputDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("入力デバイスの一覧を更新")
            }
            Toggle("自動で合わせる（最近いちばん大きかった音を 100% に）", isOn: $ar.autoGain)
            ValueDrag(label: "音が止んだときに戻る速さ", value: $ar.release, range: 0.02...2, perPoint: 0.002, defaultValue: 0.15,
                      format: { String(format: "%.2f 秒", $0) })
                .frame(height: UI.rowHeight)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(AudioBand.allCases) { b in
                    HStack(spacing: 8) {
                        Text(b.label).font(.system(size: 11)).frame(width: 56, alignment: .leading)
                        AudioMeter(band: b)
                    }
                    .help(b.help)
                }
            }
            AudioHealthView()
            if let e = ar.errorMessage {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 音がちゃんと届いているか（届いていない・0 のまま・小さすぎる、を見分ける）
struct AudioHealthView: View {
    @ObservedObject private var ar = AudioReactive.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let h = ar.health()
            VStack(alignment: .leading, spacing: 4) {
                if !ar.deviceName.isEmpty {
                    Text(ar.deviceName).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                switch h {
                case .off:
                    EmptyView()
                case .ok(let db):
                    Label(db <= -119 ? "聞き始めています…" : String(format: "音が届いています（いちばん大きい所 %.0f dB）", db),
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .quiet(let db):
                    Label(String(format: "音がとても小さい（%.0f dB）。入力の音量（システム設定 → サウンド → 入力）を上げてください", db),
                          systemImage: "speaker.wave.1").foregroundStyle(.orange)
                case .noBuffers:
                    Label("音が届いていません（入力デバイスを開けていない）", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .allZero:
                    VStack(alignment: .leading, spacing: 4) {
                        Label("音が 0 のまま届いています。マイクの使用が許可されていない可能性があります",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("システム設定のマイクを開く") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                    }
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
