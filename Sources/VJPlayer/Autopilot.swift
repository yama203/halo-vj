import Foundation
import QuartzCore

// 自動操縦：席を離れているあいだも、決めたルールでシーン・クリップを回し続ける。
// ルール 1 つ = 何を回すか（シーン／レイヤーのクリップ）・どれくらいごとに（小節・秒・分）・どれにするか（順に／ばらばら）・切り替えの長さ。
// ルールはプロジェクトに保存する。オン・オフは保存しない（開いたらいつもオフ）。
// 人がシーン・クリップを出したら、そのルールはしばらく休む（決めた秒数）。

struct AutoRule: Codable, Identifiable, Equatable {
    enum Target: Codable, Hashable {
        case scenes
        case layer(Int)
    }
    enum Unit: Int, Codable, CaseIterable, Identifiable {
        case bars, seconds, minutes
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .bars: "小節"
            case .seconds: "秒"
            case .minutes: "分"
            }
        }
    }
    enum Pick: Int, Codable, CaseIterable, Identifiable {
        case random, sequence
        var id: Int { rawValue }
        var label: String { self == .random ? "ばらばら" : "順に" }
    }

    var id = UUID()
    var on = true
    var target = Target.scenes
    var unit = Unit.minutes
    /// どれくらいごとに（単位は unit）
    var every = 3.0
    /// ゆらぎ（秒・分のとき。0〜0.5：間隔をこの割合だけ前後させて、機械的に見えないように）
    var jitter = 0.2
    var pick = Pick.random
    /// 切り替えの長さ（秒）。nil = シーンはシーンの設定、クリップはレイヤーの設定
    var fade: Double?
    /// シーン：使うシーン（nil = 全部）
    var sceneIDs: [UUID]?
    /// クリップ：使う列（0 から。nil = 全部）
    var columns: [Int]?

    var title: String {
        switch target {
        case .scenes: "シーン"
        case .layer(let r): "L\(r + 1) のクリップ"
        }
    }

    var intervalText: String {
        let v = every == every.rounded() ? String(format: "%.0f", every) : String(format: "%.1f", every)
        return v + " " + unit.label + "ごと"
    }
}

struct AutoPilot: Codable, Equatable {
    var rules: [AutoRule] = []
    /// 人が操作したら、そのルールを休む秒数（0 = 休まない）
    var pauseAfterManual = 60.0

    /// 放っておいても回る、おまかせのルール：シーンがあれば 3 分ごとにシーン、無ければ絵のあるレイヤーを 32 小節ごとに
    static func suggested(sceneCount: Int, layerCount: Int, adjustment: (Int) -> Bool) -> AutoPilot {
        var p = AutoPilot()
        if sceneCount >= 2 {
            p.rules = [AutoRule(target: .scenes, unit: .minutes, every: 3, jitter: 0.2, pick: .random)]
        } else {
            for r in 0..<layerCount where !adjustment(r) {
                p.rules.append(AutoRule(target: .layer(r), unit: .bars, every: 32, jitter: 0, pick: .random))
            }
        }
        return p
    }
}

/// 自動操縦を動かす（Engine に 1 つ。メインスレッドで）
final class AutopilotRunner: ObservableObject {
    unowned let engine: Engine
    /// オン・オフ（保存しない）
    @Published var isOn = false { didSet { if isOn != oldValue { reset() } } }
    /// 画面に出す、次の切り替え（ルールの番号・残り秒）
    @Published private(set) var nextInfo: (rule: UUID, seconds: Double, label: String)?

    private struct RuleState {
        /// 時間で決めるとき：次に切り替える時刻
        var nextTime: Double?
        /// 小節で決めるとき：次に切り替える小節の番号
        var nextBar: Int?
        /// 人が触ったので休む時刻まで
        var pausedUntil = 0.0
        /// 最近出したもの（同じものを続けない）
        var recent: [String] = []
        /// 順に回すときの位置
        var cursor = -1
        /// 次に出すもの（前もって決めておき、画面に出す）
        var planned: String?
        /// 決めたときに出ていたもの（順に回すとき、出ているものが変わったら決め直す）
        var plannedFrom: String?
        /// 画面用：次の切り替えまでの秒数と、1 間隔の秒数
        var left = 0.0
        var total = 1.0
        var paused = false
    }
    private var states: [UUID: RuleState] = [:]
    private var timer: Timer?
    /// 自分で出している最中（人の操作と見分ける）
    private(set) var acting = false
    /// テスト用：時刻を決め打ちにする
    var clock: () -> Double = { CACurrentMediaTime() }

    init(engine: Engine) { self.engine = engine }

    private func reset() {
        states = [:]
        timer?.invalidate(); timer = nil
        nextInfo = nil
        guard isOn else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// ルールが変わった（足した・消した・間隔を変えた）：次の切り替えを決め直す
    func rulesChanged() {
        let ids = Set(engine.autopilot.rules.map(\.id))
        states = states.filter { ids.contains($0.key) }
        for k in states.keys { states[k]?.nextTime = nil; states[k]?.nextBar = nil }
        if isOn { tick() }
    }

    /// 人がシーン・クリップを出した（自動で出したものは数えない）。layer = nil はシーン（全部のルールを休む）
    func noteManual(layer: Int?) {
        guard isOn, !acting, engine.autopilot.pauseAfterManual > 0 else { return }
        let until = clock() + engine.autopilot.pauseAfterManual
        for r in engine.autopilot.rules {
            let hit: Bool
            switch r.target {
            case .scenes: hit = true
            case .layer(let l): hit = layer == nil || layer == l
            }
            if hit {
                var s = states[r.id] ?? RuleState()
                s.pausedUntil = until
                // 休みが明けてから、また 1 間隔待つ
                s.nextTime = nil; s.nextBar = nil
                states[r.id] = s
            }
        }
    }

    /// 今の小節の番号（4 拍で 1 小節）
    private func currentBar(_ now: Double) -> (bar: Int, secondsPerBar: Double, frac: Double) {
        let clock = engine.beatClockForOSC()
        let b = clock.beat(at: now) / 4
        return (Int(floor(b)), 240 / max(clock.bpm, 1), b - floor(b))
    }

    /// 画面用：ルールの今の様子（残り秒・1 間隔の秒・休み中か・今出ているもの・次に出すもの）
    func status(_ id: UUID) -> (left: Double, total: Double, paused: Bool, current: String?, planned: String?)? {
        guard isOn, let s = states[id], let rule = engine.autopilot.rules.first(where: { $0.id == id }) else { return nil }
        return (s.left, max(s.total, 0.001), s.paused, current(rule), s.planned)
    }

    /// 次に出すものを決めておく（無い・もう選べない・今出ているものなら決め直す）
    private func plan(_ rule: AutoRule, _ s: inout RuleState) {
        let keys = candidates(rule).map(\.key)
        let cur = current(rule)
        if let p = s.planned, keys.contains(p), p != cur, rule.pick == .random || s.plannedFrom == cur { return }
        s.planned = choose(rule, keys: keys, current: cur, state: &s)
        s.plannedFrom = cur
    }

    /// 0.1 秒ごと：時間の来たルールを実行する
    func tick() {
        guard isOn else { return }
        let now = clock()
        var soonest: (UUID, Double, String)?
        for rule in engine.autopilot.rules where rule.on {
            var s = states[rule.id] ?? RuleState()
            let (bar, spb, frac) = currentBar(now)
            plan(rule, &s)
            // 休み中
            if now < s.pausedUntil {
                s.paused = true
                s.left = s.pausedUntil - now
                s.total = max(engine.autopilot.pauseAfterManual, 0.001)
                states[rule.id] = s
                if soonest == nil || s.left < soonest!.1 { soonest = (rule.id, s.left, rule.title + "（操作したので休み中）") }
                continue
            }
            s.paused = false
            var due = false
            switch rule.unit {
            case .bars:
                let n = max(Int(rule.every.rounded()), 1)
                // 区切りのよい所（n 小節の倍数）で切り替える
                if s.nextBar == nil { s.nextBar = (bar / n + 1) * n }
                if bar >= s.nextBar! { due = true; s.nextBar = (bar / n + 1) * n }
                s.left = (Double(s.nextBar! - bar) - frac) * spb
                s.total = Double(n) * spb
            case .seconds, .minutes:
                let base = rule.every * (rule.unit == .minutes ? 60 : 1)
                func interval() -> Double {
                    let j = min(max(rule.jitter, 0), 0.5)
                    return max(base * (1 + Double.random(in: -j...j)), 0.5)
                }
                if s.nextTime == nil { let v = interval(); s.nextTime = now + v; s.total = v }
                if now >= s.nextTime! { due = true; let v = interval(); s.nextTime = now + v; s.total = v }
                s.left = s.nextTime! - now
            }
            if due { fire(rule, state: &s) }
            states[rule.id] = s
            if soonest == nil || s.left < soonest!.1 { soonest = (rule.id, s.left, rule.title) }
        }
        let info = soonest.map { (rule: $0.0, seconds: $0.1, label: $0.2) }
        if info?.rule != nextInfo?.rule || info?.label != nextInfo?.label
            || abs((info?.seconds ?? -1) - (nextInfo?.seconds ?? -1)) >= 0.5 {
            nextInfo = info
        }
    }

    /// 今すぐ次へ（画面のボタン・テスト）
    func skip(_ id: UUID) {
        guard let rule = engine.autopilot.rules.first(where: { $0.id == id }) else { return }
        var s = states[id] ?? RuleState()
        s.pausedUntil = 0
        fire(rule, state: &s)
        s.nextTime = nil; s.nextBar = nil
        states[id] = s
        if isOn { tick() }
    }

    /// 選べるもの（目印の文字列と、出し方）
    private func candidates(_ rule: AutoRule) -> [(key: String, run: () -> Void)] {
        let e = engine
        switch rule.target {
        case .scenes:
            let allowed = rule.sceneIDs.map(Set.init)
            return e.scenes.filter { allowed?.contains($0.id) ?? true }.map { sc in
                (sc.id.uuidString, { e.recallScene(sc.id, fade: rule.fade) })
            }
        case .layer(let r):
            guard r >= 0, r < e.layers.count else { return [] }
            let deck = e.currentDeck
            let cols = rule.columns ?? Array(0..<e.columns)
            return cols.filter { $0 >= 0 && $0 < e.columns }.compactMap { c in
                let i = e.slotIndex(deck: deck, layer: r, column: c)
                guard e.slots.indices.contains(i), let slot = e.slots[i] else { return nil }
                return (slot.id.uuidString, { e.trigger(i, fadeTime: rule.fade, select: false) })
            }
        }
    }

    /// 今出ているもの（同じものは選ばない）
    private func current(_ rule: AutoRule) -> String? {
        switch rule.target {
        case .scenes: return engine.activeSceneID?.uuidString
        case .layer(let r):
            guard r >= 0, r < engine.activeByLayer.count, let a = engine.activeByLayer[r] else { return nil }
            return engine.slots[a]?.id.uuidString
        }
    }

    /// 次に出すものを選ぶ（順に：今のものの次／ばらばら：今のもの・最近出したものを避ける）
    private func choose(_ rule: AutoRule, keys: [String], current cur: String?, state s: inout RuleState) -> String? {
        guard !keys.isEmpty else { return nil }
        switch rule.pick {
        case .sequence:
            let from = keys.firstIndex { $0 == cur } ?? s.cursor
            let i = (from + 1) % keys.count
            s.cursor = i
            return keys[i]
        case .random:
            let keep = max(keys.count / 2, 1)
            var pool = keys.filter { $0 != cur && !s.recent.suffix(keep).contains($0) }
            if pool.isEmpty { pool = keys.filter { $0 != cur } }
            if pool.isEmpty { pool = keys }
            return pool.randomElement()
        }
    }

    private func fire(_ rule: AutoRule, state s: inout RuleState) {
        let all = candidates(rule)
        guard !all.isEmpty else { return }
        let cur = current(rule)
        // 前もって決めていたものを出す（もう選べなければ選び直す）
        var key = s.planned
        if key == nil || key == cur || !all.contains(where: { $0.key == key }) {
            key = choose(rule, keys: all.map(\.key), current: cur, state: &s)
        }
        guard let key, key != cur, let chosen = all.first(where: { $0.key == key }) else { return }
        s.recent.append(key)
        if s.recent.count > 64 { s.recent.removeFirst(s.recent.count - 64) }
        acting = true
        chosen.run()
        acting = false
        // 次を決めておく
        s.planned = nil
        plan(rule, &s)
    }
}

extension Engine {
    /// 自動操縦のオン・オフ。ルールが 1 つも無ければ、おまかせのルールを作ってから始める
    func setAutopilot(_ on: Bool) {
        if on && autopilot.rules.isEmpty {
            autopilot = AutoPilot.suggested(sceneCount: scenes.count, layerCount: layers.count) { self.layers[$0].isAdjustment }
        }
        autoRunner.isOn = on
    }
}
