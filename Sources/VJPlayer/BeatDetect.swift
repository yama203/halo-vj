import Foundation
import QuartzCore
import SwiftUI

// BPM の自動検出：音（音の入力）の「立ち上がりの強さ」を 1 秒に約 190 回取り、
// 最近 8 秒の並びから、何秒ごとにくり返しているか（自己相関）と、拍の頭がどこか（位相）を求める。
// 何回か続けて同じくらいの BPM が出たら、BPM と拍の頭を合わせる（細かくゆれないように、少しの違いは無視する）。

enum BeatEstimator {
    struct Result: Equatable {
        var bpm: Double
        /// 最後の拍の頭が、並びの終わりから何秒前か
        var lastBeatAgo: Double
        /// どれくらい確か（0〜1）
        var confidence: Double
    }

    /// onsets：立ち上がりの強さ（等間隔、rate 回/秒）。BPM は 78〜160 の間で探す（倍・半分はこの範囲に寄せる）
    static func estimate(_ onsets: [Double], rate: Double, minBPM: Double = 78, maxBPM: Double = 160) -> Result? {
        let n = onsets.count
        guard n > Int(rate * 3) else { return nil }
        // 平均を引いて、正の所だけ（立ち上がり）
        let mean = onsets.reduce(0, +) / Double(n)
        let x = onsets.map { max($0 - mean, 0) }
        let energy = x.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else { return nil }
        func ac(_ lag: Int) -> Double {
            guard lag > 0, lag < n else { return 0 }
            var s = 0.0
            for i in lag..<n { s += x[i] * x[i - lag] }
            return s / Double(n - lag)
        }
        let minLag = Int((60 / maxBPM * rate).rounded(.down)), maxLag = Int((60 / minBPM * rate).rounded(.up))
        guard maxLag * 2 < n else { return nil }
        var acv = [Double](repeating: 0, count: maxLag * 2 + 2)
        for l in max(minLag / 2, 1)...(maxLag * 2 + 1) { acv[l] = ac(l) }
        // 拍の長さの候補：その長さと 2 倍の長さ（小節の中のくり返し）と半分を合わせた点数。120 BPM のあたりを少し好む
        var best = -1.0, bestLag = 0
        for l in minLag...maxLag {
            let bpm = 60 * rate / Double(l)
            let prior = exp(-pow(log2(bpm / 120), 2) / (2 * 0.6 * 0.6))
            let s = (acv[l] + 0.5 * acv[min(l * 2, acv.count - 1)] + 0.25 * acv[max(l / 2, 1)]) * (0.75 + 0.25 * prior)
            if s > best { best = s; bestLag = l }
        }
        guard bestLag > 0 else { return nil }
        // 山の形から、間のずれ（1 未満）も求める
        let y0 = acv[bestLag - 1], y1 = acv[bestLag], y2 = acv[bestLag + 1]
        let den = y0 - 2 * y1 + y2
        let frac = abs(den) > 1e-12 ? min(max(0.5 * (y0 - y2) / den, -0.5), 0.5) : 0
        let period = Double(bestLag) + frac
        let bpm = 60 * rate / period
        // 確かさ：その長さの重なりが、ずらさないとき（0）に比べてどれくらいか
        let conf = min(max(acv[bestLag] / max(energy / Double(n), 1e-12), 0), 1)
        // 拍の頭：その長さごとに足したとき、いちばん強くなる位置
        let p = Int(period.rounded())
        var bestPhase = 0, bestSum = -1.0
        for ph in 0..<p {
            var s = 0.0, k = Double(n - 1 - ph)
            while k >= 0 {
                let i = Int(k.rounded())
                // 立ち上がりは少し幅を持つので、前後も少し入れる
                s += x[i] + 0.5 * (i > 0 ? x[i - 1] : 0) + 0.5 * (i + 1 < n ? x[i + 1] : 0)
                k -= period
            }
            if s > bestSum { bestSum = s; bestPhase = ph }
        }
        return Result(bpm: bpm, lastBeatAgo: Double(bestPhase) / rate, confidence: conf)
    }
}

/// 音から BPM を合わせ続ける（アプリ全体で 1 つ）
final class BeatDetector: ObservableObject {
    static let shared = BeatDetector()

    @Published var enabled = false { didSet { if oldValue != enabled { save(); restart() } } }
    /// 今見えている BPM（画面に出す。合わせる前でも）
    @Published private(set) var detected: Double?
    @Published private(set) var confidence = 0.0
    @Published private(set) var locked = false
    var forTests = false

    private var timer: Timer?
    private var history: [Double] = []

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "bpm.auto")
    }

    private func save() { if !forTests { UserDefaults.standard.set(enabled, forKey: "bpm.auto") } }

    func startIfNeeded() { restart() }

    private func restart() {
        timer?.invalidate(); timer = nil
        history = []
        locked = false
        guard enabled else { detected = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
    }

    private func step() {
        let (onsets, rate, end) = AudioReactive.shared.onsetWindow(seconds: 8)
        guard let r = BeatEstimator.estimate(onsets, rate: rate) else { detected = nil; confidence = 0; locked = false; return }
        detected = r.bpm
        confidence = r.confidence
        apply(r, endTime: end)
    }

    /// 見えた BPM を、何回か続けて同じくらいなら合わせる（テストからも）
    func apply(_ r: BeatEstimator.Result, endTime: Double, engine: Engine? = nil) {
        let e = engine ?? Engine.shared
        guard r.confidence > 0.12 else { locked = false; return }
        history.append(r.bpm)
        if history.count > 4 { history.removeFirst(history.count - 4) }
        guard history.count >= 3 else { return }
        let recent = history.suffix(3)
        let avg = recent.reduce(0, +) / Double(recent.count)
        // 3 回続けて 2% 以内なら確か
        guard recent.allSatisfy({ abs($0 - avg) / avg < 0.02 }) else { locked = false; return }
        locked = true
        let beatTime = endTime - r.lastBeatAgo
        e.setDetectedTempo(avg, beatAt: beatTime)
    }
}

extension Engine {
    /// BPM の自動検出から：BPM と拍の頭を合わせる（少しの違いは無視。保存・元に戻すには数えない）
    func setDetectedTempo(_ b: Double, beatAt t: Double) {
        var clock = beatClockForEditing()
        let now = CACurrentMediaTime()
        let bpmChanged = abs(clock.bpm - b) > 0.4
        if bpmChanged { clock.setBPM((b * 10).rounded() / 10, at: now) }
        // 拍の頭のずれ（拍の長さに対する割合。-0.5〜0.5）
        let beat = clock.beat(at: t)
        let off = beat - beat.rounded()
        let spb = 60 / clock.bpm
        // 30 ms 以上ずれていたら合わせる（何拍目かは保つ）
        if abs(off) * spb > 0.03 || bpmChanged {
            clock.anchorHost = t
            clock.anchorBeat = beat.rounded()
        }
        setBeatClockQuietly(clock)
    }
}

/// BPM の欄の「自動」ボタン
struct BPMAutoButton: View {
    @ObservedObject private var det = BeatDetector.shared
    @ObservedObject private var ar = AudioReactive.shared
    var body: some View {
        Toggle(isOn: $det.enabled) {
            VStack(spacing: 0) {
                Text("自動").font(.system(size: 12, weight: .bold))
                if det.enabled {
                    Text(det.detected.map { String(format: "%.1f", $0) } ?? "…")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(det.locked ? Color.green : Color.secondary)
                }
            }
            .frame(width: 44, height: 26)
        }
        .toggleStyle(.button)
        .controlSize(.large)
        .help(ar.source == .off
              ? "音から BPM を合わせる（先に上のバーの「音の入力」で音を選ぶ）"
              : "音から BPM と拍の頭を合わせ続ける（緑 = 合っている。78〜160 BPM の間で探す）")
    }
}
