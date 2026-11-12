import Foundation
import QuartzCore

// サイコロを拍・音で自動に振る（サイコロ 第 2 弾。設計は docs/dice-2-design.md）。
// 設定は Effect.autoDice（保存する）。振るのはメインスレッドの見張り（AutoDiceDriver）で、
// 出ているもの（再生中のクリップ・レイヤー・コンポジション・押しているパッド）だけを振る。
// 自動で振った結果は元に戻す（⌘Z）に積まない。
// つなぎ（前の値から新しい値へなめらかに移る）は、描画側で Effect.value(_:at:…) が補間する（Effect.diceGlide）。

/// サイコロを自動で振る設定
struct AutoDice: Codable, Equatable {
    /// beats：拍ごと、attack：音のアタックで、off：しない（少しだけ・つなぎの設定だけを持っている）
    enum Mode: Int, Codable { case beats, attack, off }
    var mode = Mode.beats
    /// 何拍ごとに振るか（beats のとき）
    var every = 4.0
    /// 少しだけ（手で押すときも、⌥ と同じ「少しだけ」）
    var slight = false
    /// つなぎ（拍）。0 はすぐ
    var glide = 0.0
    /// 立ち上がりの強さ（0〜1）のしきい値（attack のとき）。低いほど小さな音でも振る（感度が高い）
    var threshold = 0.5
    static let thresholdRange = 0.05...0.95

    init(mode: Mode = .beats, every: Double = 4, slight: Bool = false, glide: Double = 0, threshold: Double = 0.5) {
        self.mode = mode; self.every = every; self.slight = slight; self.glide = glide
        self.threshold = min(max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    }

    /// 以前の感度（0 低い・1 ふつう・2 高い）を、しきい値に直す
    static func threshold(fromSensitivity s: Int) -> Double { [0.7, 0.5, 0.3][min(max(s, 0), 2)] }

    enum CodingKeys: String, CodingKey { case mode, every, slight, glide, threshold, sensitivity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .beats
        every = min(max((try? c.decodeIfPresent(Double.self, forKey: .every)) ?? 4, 0.25), 64)
        slight = (try? c.decodeIfPresent(Bool.self, forKey: .slight)) ?? false
        glide = min(max((try? c.decodeIfPresent(Double.self, forKey: .glide)) ?? 0, 0), 16)
        if let t = try? c.decodeIfPresent(Double.self, forKey: .threshold) {
            threshold = min(max(t, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        } else if let old = try? c.decodeIfPresent(Int.self, forKey: .sensitivity) {
            // 以前の保存（感度 3 段）
            threshold = Self.threshold(fromSensitivity: old)
        }
    }

    /// 書くのはしきい値だけ（以前の sensitivity は書かない）
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(every, forKey: .every)
        try c.encode(slight, forKey: .slight)
        try c.encode(glide, forKey: .glide)
        try c.encode(threshold, forKey: .threshold)
    }

    /// 自動で振っているか
    var isOn: Bool { mode != .off }
    /// しない・ほかも最初のまま（nil にしてよい）
    var isPlain: Bool { self == AutoDice(mode: .off) }

    static let everyChoices: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16]
    static let glideChoices: [Double] = [0, 0.25, 0.5, 1, 2]
    /// 音のアタックで振るときの、続けて振らない最短の間（秒）
    static let minGap = 0.12

    /// つなぎの長さ（秒）
    func glideSeconds(bpm: Double) -> Double { glide > 0 ? glide * 60 / max(bpm, 1) : 0 }

    static func glideLabel(_ g: Double) -> String { g <= 0 ? L("すぐ") : ParamAnim.beatsLabel(g) }

    /// 「自動：4 拍ごと・少しだけ」のような短い説明（しないときは空）
    var summary: String {
        guard isOn else { return "" }
        var parts: [String] = []
        switch mode {
        case .beats: parts.append(L("\(ParamAnim.beatsLabel(every))ごと"))
        case .attack: parts.append(L("音のアタックで（しきい値 \(Int((threshold * 100).rounded()))%）"))
        case .off: break
        }
        if slight { parts.append(L("少しだけ")) }
        if glide > 0 { parts.append(L("つなぎ \(Self.glideLabel(glide))")) }
        return L("自動：") + parts.joined(separator: L("・"))
    }
}

/// サイコロの「つなぎ」の途中の様子（保存しない。比べるときは無いものとして扱う）
struct DiceGlide: Equatable {
    /// 振る前の値（つないでいないときは nil）
    var from: [Double]?
    /// 振った時刻（Effect.value(_:at:…) と同じ時計）
    var at = 0.0
    /// つなぎの長さ（秒）
    var seconds = 0.0

    static func == (_: DiceGlide, _: DiceGlide) -> Bool { true }
}

extension Effect {
    /// t の時点の、つなぎを込めた値（動きは込めない）。つないでいなければ value(i)
    func glidedValue(_ i: Int, at t: Double) -> Double {
        let v = value(i)
        guard let from = diceGlide.from, from.indices.contains(i), diceGlide.seconds > 0 else { return v }
        let dt = t - diceGlide.at
        // 振った時刻より前（見本・サムネイルを別の時刻で描くとき）は今の値。描画の時刻が少しだけ前のときは前の値
        guard dt > -0.1, dt < diceGlide.seconds else { return v }
        let a = from[i]
        let k = min(max(dt / diceGlide.seconds, 0), 1)
        let p = kind.params[i]
        // オン/オフ・選択肢は補間しない（半分で切り替える）
        if p.isToggle || p.choices != nil { return k < 0.5 ? a : v }
        let s = k * k * (3 - 2 * k)
        var d = v - a
        // 色相のように一周するものは、近い方を回る
        if p.range == 0...360 { if d > 180 { d -= 360 } else if d < -180 { d += 360 } }
        var r = a + d * s
        if p.range == 0...360 { r = r.truncatingRemainder(dividingBy: 360); if r < 0 { r += 360 } }
        r = min(max(r, p.range.lowerBound), p.range.upperBound)
        if p.step > 0 { r = (r / p.step).rounded() * p.step }
        return r
    }

    /// サイコロを振ったもの（つなぎ込み）。glideSeconds > 0 なら、今見えている値から新しい値へつなぐ
    func rolled<G: RandomNumberGenerator>(using rng: inout G, slight: Bool, glideSeconds: Double, at now: Double) -> Effect {
        var n = diced(using: &rng, slight: slight)
        if glideSeconds > 0 {
            n.diceGlide = DiceGlide(from: kind.params.indices.map { glidedValue($0, at: now) }, at: now, seconds: glideSeconds)
        } else {
            n.diceGlide = DiceGlide()
        }
        return n
    }

    /// サイコロのボタンの説明（自動で振っているときは今の設定も）
    var diceHelp: String {
        let base = L("値をランダムに変える（⌥ を押しながら：少しだけ）。右の ▾ で、拍や音に合わせて自動で振る")
        guard let a = autoDice, a.isOn else {
            return autoDice?.slight == true ? base + "\n" + L("（押すと少しだけ変わる）") : base
        }
        return base + "\n" + a.summary
    }
}

/// 1 つの Effect の、自動で振る時を決めるもの（純粋な計算。テストで列を与えて確かめる）
struct AutoDiceGate {
    /// 前に見たときの区切りの番号（拍 ÷ every の切り捨て）
    var lastSlot: Double?
    /// 前に見たときの立ち上がりの強さ
    var prevLevel = 0.0
    /// 最後に振った時刻
    var lastFire = -Double.infinity
    /// この見張りを作ったときの設定（設定が変わったら作り直す）
    var setting: AutoDice?

    /// 拍ごと：拍の位置 beat が every の区切りをまたいだら true（同じ区切りで 2 回は振らない。初めて見たときは振らない）
    mutating func beat(_ beat: Double, every: Double) -> Bool {
        let slot = floor(beat / max(every, 0.01) + 1e-9)
        defer { lastSlot = slot }
        guard let p = lastSlot else { return false }
        // 拍の時計を合わせ直して後ろへ戻ったときは振らない
        return slot > p
    }

    /// 音のアタック：強さ level がしきい値を下から上へまたいだ瞬間に true（最短 minGap 秒あける）
    mutating func attack(_ level: Double, at t: Double, threshold: Double, minGap: Double = AutoDice.minGap) -> Bool {
        defer { prevLevel = level }
        guard prevLevel < threshold, level >= threshold, t - lastFire >= minGap else { return false }
        lastFire = t
        return true
    }

    /// 立ち上がりの強さの列（時刻と強さ）のうち、振る所の番号（テスト用）
    static func attackFires(_ samples: [(t: Double, level: Double)], threshold: Double,
                            minGap: Double = AutoDice.minGap) -> [Int] {
        var g = AutoDiceGate()
        return samples.indices.filter { g.attack(samples[$0].level, at: samples[$0].t, threshold: threshold, minGap: minGap) }
    }
}

/// サイコロを自動で振る見張り（メインスレッド。エンジンに 1 つ）。
/// 出ているものに自動の設定が 1 つも無いときは止まっている（syncRenderState のたびに wake で確かめる）
final class AutoDiceDriver {
    private unowned let engine: Engine
    private var timer: Timer?
    private var gates: [UUID: AutoDiceGate] = [:]
    /// 乱数（テストでは種を決めたものに替える）
    var rng = SeededRandom(seed: UInt64.random(in: 0...UInt64.max))
    /// テスト用：見張りの Timer を動かさない（tick を直接呼ぶ）
    var manual = false
    /// 立ち上がりの強さ（0〜1）。音が入っていないときは nil（振らない）
    var attackLevel: (Double) -> Double? = { t in
        let ar = AudioReactive.shared
        guard ar.source != .off else { return nil }
        // アタック（キックの頭で 1 になってすっと戻る）× 低音の大きさ。弱い音ではしきい値に届かない
        return ar.level(.attack, at: t) * ar.level(.low, at: t)
    }

    init(engine: Engine) { self.engine = engine }
    deinit { timer?.invalidate() }

    var isRunning: Bool { timer != nil }

    /// 自動で振るもの 1 つ分：今の Effect と、書き換える先
    struct Target {
        let effect: Effect
        let set: (Effect) -> Void
    }

    /// 出ているもののうち、自動で振る設定のある Effect
    func targets() -> [Target] {
        let e = engine
        var out: [Target] = []
        func on(_ fx: Effect?) -> Bool { fx?.autoDice?.isOn == true && fx?.kind.hasDice == true }
        // コンポジション
        for fx in e.effects where on(fx) {
            out.append(Target(effect: fx) { [weak e] n in
                guard let e, let j = e.effects.firstIndex(where: { $0.id == n.id }) else { return }
                e.effects[j] = n
            })
        }
        for (r, l) in e.layers.enumerated() where !(l.muted || l.soloHidden) {
            let slot = e.activeByLayer.indices.contains(r) ? e.activeByLayer[r].flatMap { e.slots.indices.contains($0) ? e.slots[$0] : nil } : nil
            // レイヤー：クリップを出している（調整レイヤーはクリップが無くても効く）
            if slot != nil || l.isAdjustment {
                for fx in l.effects where on(fx) {
                    out.append(Target(effect: fx) { [weak l] n in
                        guard let l, let j = l.effects.firstIndex(where: { $0.id == n.id }) else { return }
                        l.effects[j] = n
                    })
                }
            }
            // 再生中のクリップ：エフェクトとジェネレーター
            if let slot {
                for fx in slot.effects where on(fx) {
                    out.append(Target(effect: fx) { [weak slot] n in
                        guard let slot, let j = slot.effects.firstIndex(where: { $0.id == n.id }) else { return }
                        slot.effects[j] = n
                    })
                }
                if let g = slot.generator, on(g) {
                    out.append(Target(effect: g) { [weak slot] n in
                        guard let slot, slot.generator?.id == n.id else { return }
                        slot.generator = n
                    })
                }
            }
        }
        // 押しているパッド（離して消えている途中も）
        for p in e.pads where e.heldPads[p.id] != nil || e.releasingPads[p.id] != nil {
            for fx in p.effects where on(fx) {
                out.append(Target(effect: fx) { [weak p] n in
                    guard let p, let j = p.effects.firstIndex(where: { $0.id == n.id }) else { return }
                    p.effects[j] = n
                })
            }
        }
        return out
    }

    /// 出ているものが変わったかもしれない：見張りを動かす・止める
    func wake() {
        let need = !targets().isEmpty
        if need {
            guard timer == nil, !manual else { return }
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            gates.removeAll()
        }
    }

    /// 1 回見る：時が来たものを振る。振った数を返す
    @discardableResult
    func tick(now: Double = CACurrentMediaTime()) -> Int {
        let list = targets()
        guard !list.isEmpty else {
            gates.removeAll()
            if !manual { timer?.invalidate(); timer = nil }
            return 0
        }
        let clock = engine.beatClockForEditing()
        let beat = clock.beat(at: now)
        var levelRead = false
        var level: Double?
        var fires: [(Target, AutoDice)] = []
        var seen = Set<UUID>()
        for t in list {
            guard let a = t.effect.autoDice else { continue }
            let id = t.effect.id
            seen.insert(id)
            var g = gates[id] ?? AutoDiceGate()
            if g.setting != a { g = AutoDiceGate(); g.setting = a }
            var fire = false
            switch a.mode {
            case .beats:
                fire = g.beat(beat, every: a.every)
            case .attack:
                if !levelRead {
                    level = attackLevel(now); levelRead = true
                    if let v = level { AutoDiceMonitor.shared.record(v, at: now) }
                }
                if let v = level { fire = g.attack(v, at: now, threshold: a.threshold) } else { g.prevLevel = 0 }
            case .off:
                break
            }
            gates[id] = g
            if fire { fires.append((t, a)) }
        }
        // 見えなくなったものは忘れる（また出たときに、すぐ振らないように）
        gates = gates.filter { seen.contains($0.key) }
        guard !fires.isEmpty else { return 0 }
        for (t, _) in fires { AutoDiceMonitor.shared.fired(t.effect.id, at: now) }
        engine.changeWithoutUndo {
            for (t, a) in fires {
                t.set(t.effect.rolled(using: &rng, slight: a.slight, glideSeconds: a.glideSeconds(bpm: clock.bpm), at: now))
            }
        }
        return fires.count
    }
}

/// 自動で振った知らせと、立ち上がりの強さの最近の列（サイコロのパネルが TimelineView で読む。@Published にしない：
/// 振るたびにグリッド全体が描き直されないように）。メインスレッドだけで触る
final class AutoDiceMonitor {
    static let shared = AutoDiceMonitor()
    static let capacity = 150
    /// 最近の立ち上がりの強さ（古い → 新しい）と、その時刻
    private(set) var levels: [(t: Double, level: Double)] = []
    /// Effect ごとの、最近振った時刻（新しいものが後ろ。8 個まで）
    private(set) var fires: [UUID: [Double]] = [:]

    /// 立ち上がりの強さを残す（見張りとパネルの両方から呼ぶ。1/90 秒より細かくは残さない）
    func record(_ level: Double, at t: Double) {
        if let last = levels.last {
            if t >= last.t && t - last.t < 1.0 / 90 { return }
            // 時刻が戻った（テスト・書き出しの決め打ちの時刻）ときは、前の列を捨てる
            if t < last.t { levels.removeAll() }
        }
        levels.append((t, level))
        if levels.count > Self.capacity { levels.removeFirst(levels.count - Self.capacity) }
    }

    func fired(_ id: UUID, at t: Double) {
        var f = fires[id] ?? []
        f.append(t)
        if f.count > 8 { f.removeFirst(f.count - 8) }
        fires[id] = f
    }

    func lastFire(_ id: UUID) -> Double? { fires[id]?.last }

    /// テスト・書き出し用：中身を入れ替える
    func reset(levels: [(t: Double, level: Double)] = [], fires: [UUID: [Double]] = [:]) {
        self.levels = levels
        self.fires = fires
    }
}
