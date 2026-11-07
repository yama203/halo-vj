import Foundation
import QuartzCore

// パラメーターのアニメーション（Resolume の Timeline / BPM Sync のようなもの）。
// 値は「時刻」から毎回計算する（積み上げない）ので、描画スレッドでいつ計算しても同じ値になり、
// メインスレッドが忙しくても動きが止まったりカクついたりしない。

/// アニメーションできるパラメーター
enum ParamKey: String, Codable, CaseIterable {
    case posX, posY, scale, rotation, opacity

    /// アニメーションを付けたときの最初の範囲（画面の単位：位置は割合、角度は度、不透明度は 0〜1）
    var defaultRange: ClosedRange<Double> {
        switch self {
        case .posX, .posY: -0.5...0.5
        case .scale: 0.5...1.5
        case .rotation: 0...360
        case .opacity: 0...1
        }
    }
}

/// 何に合わせて動かすか
enum AnimMode: Int, Codable, CaseIterable, Identifiable {
    case off, time, beat, audio
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: "固定"
        case .time: "秒"
        case .beat: "BPM"
        case .audio: "音"
        }
    }
}

/// どう動かすか
enum AnimMotion: Int, Codable, CaseIterable, Identifiable {
    case forward, backward, pingpong, random
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .forward: "→ 順"
        case .backward: "← 逆"
        case .pingpong: "↔ 往復"
        case .random: "ランダム"
        }
    }
}

/// 1 つのパラメーターの動かし方
struct ParamAnim: Codable, Equatable {
    var mode = AnimMode.off
    var motion = AnimMotion.forward
    /// 1 周の長さ（秒モード）
    var seconds = 4.0
    /// 1 周の長さ（BPM モード、拍）
    var beats = 4.0
    /// 動かす範囲
    var lo: Double
    var hi: Double
    /// ランダムの並び（パラメーターごとに違う動きにする）
    var seed = UInt32.random(in: 0...UInt32.max)
    /// 秒モードで動き始めた時刻（保存しない）
    var start: Double = 0
    /// 音モード：音のどの部分で、どれだけの感度で動かすか（無ければ音量・感度 100%）
    var audio: AudioLink?

    enum CodingKeys: String, CodingKey { case mode, motion, seconds, beats, lo, hi, seed, audio }

    init(key: ParamKey) {
        lo = key.defaultRange.lowerBound
        hi = key.defaultRange.upperBound
    }

    /// 範囲を直接決めて作る（エフェクトの値など）
    init(range: ClosedRange<Double>) {
        lo = range.lowerBound
        hi = range.upperBound
    }

    var isOn: Bool { mode != .off }

    /// 周期の選択肢（拍）
    static let beatChoices: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32, 64]

    /// t の時点の値。動かしていなければ base。
    /// origin は秒モードの基準時刻（クリップならトリガーした時刻。トリガーし直すと頭から動く）
    func value(base: Double, at t: Double, beat: BeatClock, origin: Double = 0) -> Double {
        let phase: Double
        switch mode {
        case .off:
            return base
        case .time:
            phase = (t - max(start, origin)) / max(seconds, 0.01)
        case .beat:
            // 拍の頭に揃える（同じ周期のものは全部そろって動く）
            phase = beat.beat(at: t) / max(beats, 0.01)
        case .audio:
            // 音の大きさ（0〜1）× 感度で、から〜まで の間。逆なら大きいほど「から」へ
            let a = audio ?? AudioLink()
            var k = min(max(AudioReactive.shared.level(a.band, at: t) * a.gain, 0), 1)
            if motion == .backward { k = 1 - k }
            return lo + (hi - lo) * k
        }
        let cycle = floor(phase)
        let f = phase - cycle
        let k: Double
        switch motion {
        case .forward: k = f
        case .backward: k = 1 - f
        case .pingpong:
            // 1 周で行って、次の 1 周で戻る
            let g = phase.truncatingRemainder(dividingBy: 2)
            let g2 = g < 0 ? g + 2 : g
            k = g2 < 1 ? g2 : 2 - g2
        case .random:
            // 1 周ごとに範囲内のランダムな値へ飛ぶ
            k = Self.hash(Int64(cycle), seed)
        }
        return lo + (hi - lo) * k
    }

    /// 周期番号とシードから 0〜1 の値を決める（同じ入力なら必ず同じ値）
    static func hash(_ n: Int64, _ seed: UInt32) -> Double {
        var x = UInt64(bitPattern: n) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(seed) &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 31; x = x &* 0x94D0_49BB_1331_11EB; x ^= x >> 29
        return Double(x >> 11) / Double(1 << 53)
    }

    /// 欄に出す短い説明
    var summary: String {
        switch mode {
        case .off: return ""
        case .time: return String(format: "%@ %.1f秒", motion.label, seconds)
        case .beat: return "\(motion.label) \(Self.beatsLabel(beats))"
        case .audio: return "音：" + (audio ?? AudioLink()).band.label
        }
    }

    static func beatsLabel(_ b: Double) -> String {
        switch b {
        case 0.25: "1/4拍"
        case 0.5: "1/2拍"
        default: b == b.rounded() ? "\(Int(b))拍" : String(format: "%.2f拍", b)
        }
    }
}

/// BPM の時計。拍の位置を時刻から計算する
struct BeatClock: Equatable {
    var bpm = 120.0
    /// anchorHost の時点で anchorBeat 拍目
    var anchorHost = 0.0
    var anchorBeat = 0.0

    func beat(at t: Double) -> Double {
        anchorBeat + (t - anchorHost) * bpm / 60
    }

    /// テンポを変える（今の拍の位置は変えない）
    mutating func setBPM(_ b: Double, at t: Double) {
        anchorBeat = beat(at: t)
        anchorHost = t
        bpm = b
    }

    /// t を拍の頭（beat 0 = 小節の頭）にする
    mutating func resync(at t: Double) {
        anchorHost = t
        anchorBeat = 0
    }
}

/// タップテンポ。拍に合わせて何回か押すと BPM が決まる
struct TapTempo {
    private var taps: [Double] = []

    /// タップした時刻を入れる。BPM が決まれば返す（2 回目から）
    mutating func tap(at t: Double) -> Double? {
        // 2 秒あいたら数え直し
        if let last = taps.last, t - last > 2.0 { taps.removeAll() }
        taps.append(t)
        if taps.count > 8 { taps.removeFirst(taps.count - 8) }
        guard taps.count >= 2 else { return nil }
        let interval = (taps.last! - taps.first!) / Double(taps.count - 1)
        guard interval > 0 else { return nil }
        return min(max(60 / interval, 20), 300)
    }

    var count: Int { taps.count }
}

/// 位置・スケール・角度・不透明度と、そのアニメーション（描画スレッドに渡す）
struct AnimTransform {
    var x = 0.0, y = 0.0, scale = 1.0, rotation = 0.0, opacity = 1.0
    var anims: [ParamKey: ParamAnim] = [:]
    /// 秒モードの基準時刻
    var origin = 0.0

    func value(_ key: ParamKey, base: Double, at t: Double, beat: BeatClock) -> Double {
        guard let a = anims[key], a.isOn else { return base }
        return a.value(base: base, at: t, beat: beat, origin: origin)
    }

    func at(_ t: Double, beat: BeatClock) -> ClipTransform {
        ClipTransform(x: Float(value(.posX, base: x, at: t, beat: beat)),
                      y: Float(value(.posY, base: y, at: t, beat: beat)),
                      scale: Float(value(.scale, base: scale, at: t, beat: beat)),
                      rotation: Float(value(.rotation, base: rotation, at: t, beat: beat) * .pi / 180),
                      opacity: Float(min(max(value(.opacity, base: opacity, at: t, beat: beat), 0), 1)))
    }

    var isAnimated: Bool { anims.values.contains { $0.isOn } }
}

/// アニメーションを持てるもの（クリップ・レイヤー・コンポジション）
protocol Animatable: AnyObject {
    var anims: [ParamKey: ParamAnim] { get set }
    /// 秒モードの基準時刻
    var animOrigin: Double { get }
}

extension Animatable {
    /// 欄から使う：そのパラメーターの動かし方（無ければ既定値）
    func anim(_ key: ParamKey) -> ParamAnim { anims[key] ?? ParamAnim(key: key) }

    func setAnim(_ key: ParamKey, _ a: ParamAnim) {
        var a = a
        // 止まっていたものを動かし始めたら、秒モードはそこから数える
        if a.isOn && !(anims[key]?.isOn ?? false) { a.start = CACurrentMediaTime() }
        anims[key] = a
    }
}
