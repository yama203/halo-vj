import Foundation
import AppKit
import Metal
import QuartzCore
import SwiftUI

// セルフテスト：サイコロ 第 2 弾（ジェネレーターにも・自動で振る・つなぎ）。設計は docs/dice-2-design.md。
// VJ_DICE_SWEEP_DIR=フォルダ を付けると、全部のジェネレーターを振った絵を一覧の PNG に書き出す（目で見る用）。

extension SelfTest {
    static func testDice2(check: (Bool, String) -> Void) {
        testAutoDiceSave(check)
        testAutoDiceBeats(check)
        testAutoDiceAttack(check)
        testAutoDiceEngine(check)
        testDiceGlide(check)
        testDiceMenu(check)
        testDiceGenerators(check)
    }

    // MARK: 保存

    private static func testAutoDiceSave(_ check: (Bool, String) -> Void) {
        var e = Effect(kind: .plasma)
        e.autoDice = AutoDice(mode: .attack, every: 2, slight: true, glide: 0.5, threshold: 0.27)
        let enc = JSONEncoder()
        let back = (try? enc.encode(e)).flatMap { try? JSONDecoder().decode(Effect.self, from: $0) }
        check(back == e && back?.autoDice == e.autoDice, "自動のサイコロ：設定を保存して読み直すと同じ")
        // 古い保存（項目なし）は nil、nil のときは書き出しに項目が出ない
        let plain = Effect(kind: .plasma)
        let plainJSON = (try? enc.encode(plain)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let old = try? JSONDecoder().decode(Effect.self, from: Data(#"{"kind":"plasma","values":[1,2]}"#.utf8))
        check(old != nil && old?.autoDice == nil && !plainJSON.contains("autoDice"),
              "自動のサイコロ：古い保存（項目なし）も読めて「しない」。しないときは保存に項目を書かない")
        // 壊れた・範囲外の値は丸める
        let odd = try? JSONDecoder().decode(AutoDice.self, from: Data(#"{"mode":9,"every":-3,"threshold":7}"#.utf8))
        check(odd?.mode == .beats && odd?.every == 0.25 && odd?.threshold == 0.95, "自動のサイコロ：知らない値・範囲の外は丸めて読む")
        // 以前の保存（感度 3 段）はしきい値に直る。書くのはしきい値だけ
        let olds = [0, 1, 2].map { try? JSONDecoder().decode(AutoDice.self, from: Data(#"{"mode":1,"sensitivity":\#($0)}"#.utf8)) }
        let autoJSON = (try? JSONEncoder().encode(AutoDice(mode: .attack, threshold: 0.33))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let back2 = try? JSONDecoder().decode(AutoDice.self, from: Data(autoJSON.utf8))
        check(olds.map { $0?.threshold } == [0.7, 0.5, 0.3] && olds.allSatisfy { $0?.mode == .attack }
              && autoJSON.contains("threshold") && !autoJSON.contains("sensitivity") && back2?.threshold == 0.33,
              "自動のサイコロ：以前の感度（低い・ふつう・高い）は しきい値 70%・50%・30% に直る。しきい値を保存して読み直せる")

        // プリセットに入る
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vj-dice2-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let store = EffectPresets(url: dir.appendingPathComponent("effect-presets.json"))
        let p = store.save(name: "自動", effect: e)
        let applied = EffectPresets.apply(p, to: Effect(kind: .plasma))
        var none = e; none.autoDice = nil
        let p2 = store.save(name: "なし", effect: none)
        let cleared = EffectPresets.apply(p2, to: e)
        check(applied.autoDice == e.autoDice && cleared.autoDice == nil, "自動のサイコロ：プリセットに入り、呼び出すと動き方も戻る")
    }

    // MARK: 拍ごと

    private static func testAutoDiceBeats(_ check: (Bool, String) -> Void) {
        let clock = BeatClock(bpm: 120, anchorHost: 100, anchorBeat: 0)
        var g = AutoDiceGate()
        var fireTimes: [Double] = []
        // 1/60 秒ごと + ちょうど区切りの時刻を 2 回
        var times = stride(from: 100.0, through: 105.0, by: 1.0 / 60).map { $0 }
        times += [102.0, 102.0, 104.0]
        times.sort()
        for t in times where g.beat(clock.beat(at: t), every: 4) { fireTimes.append(t) }
        check(fireTimes.count == 2 && abs(fireTimes[0] - 102) < 1e-9 && abs(fireTimes[1] - 104) < 1e-9,
              "自動のサイコロ（拍ごと）：BPM 120・4 拍ごとで、区切り（2 秒・4 秒）をまたいだ所で 1 回ずつ（\(fireTimes)）")
        // 拍の時計を合わせ直して戻ったときは振らない。1/4 拍ごとは 1 拍に 4 回
        var g2 = AutoDiceGate()
        _ = g2.beat(10.1, every: 4)
        let back = g2.beat(3.0, every: 4)
        var g3 = AutoDiceGate()
        let quarter = stride(from: 0.0, through: 1.0, by: 0.01).filter { g3.beat($0, every: 0.25) }.count
        check(!back && quarter == 4, "自動のサイコロ（拍ごと）：拍が戻っても振らない・1/4 拍ごとは 1 拍に 4 回")
    }

    // MARK: 音のアタック

    private static func testAutoDiceAttack(_ check: (Bool, String) -> Void) {
        // 立ち上がりの強さの列（60 回/秒）。0.5 を下から上へまたいだ所だけ・0.12 秒あける
        let lv: [Double] = [0, 0.2, 0.9, 0.7, 0.4, 0.3, 0.8, 0.2, 0.1, 0.1, 0.6, 0.6, 0.2, 0.1, 0.1, 0.1, 0.1, 0.1, 0.55, 0.3]
        let s = lv.enumerated().map { (t: Double($0.offset) / 60, level: $0.element) }
        let fires = AutoDiceGate.attackFires(s, threshold: 0.5)
        // 2：またぐ、6：0.067 秒しかあいていない（振らない）、10：0.133 秒（振る）、11：上のまま（振らない）、18：振る
        check(fires == [2, 10, 18], "自動のサイコロ（アタック）：しきい値をまたいだ瞬間だけ・最短 0.12 秒あけて振る（\(fires)）")
        let high = AutoDiceGate.attackFires(s, threshold: AutoDice(mode: .attack, threshold: 0.3).threshold)
        let low = AutoDiceGate.attackFires(s, threshold: AutoDice(mode: .attack, threshold: 0.7).threshold)
        let mid = AutoDiceGate.attackFires(s, threshold: 0.58)
        check(high.count >= fires.count && low.count < fires.count && mid == [2, 10],
              "自動のサイコロ（アタック）：しきい値を変えると、同じ列で振る所が変わる（低いほど小さな音でも。0.58 で \(mid)）")
    }

    // MARK: エンジン：出ているものだけ・元に戻す

    private static func testAutoDiceEngine(_ check: (Bool, String) -> Void) {
        let e = Engine(persistent: false)
        let d = e.autoDice
        d.manual = true
        d.rng = SeededRandom(seed: 77)
        _ = e.placeGenerator(.plasma, at: 0)
        _ = e.placeGenerator(.aurora, at: 1)       // 同じ段のとなり（出ていない）
        let auto = AutoDice(mode: .beats, every: 4, slight: false, glide: 1)
        e.slots[0]?.generator?.autoDice = auto
        e.slots[1]?.generator?.autoDice = auto
        e.slots[0]?.effects = [{ var k = Effect(kind: .kaleidoscope); k.autoDice = auto; return k }()]
        e.effects = [{ var k = Effect(kind: .rgbSplit); k.autoDice = AutoDice(mode: .attack); return k }()]
        e.trigger(0)
        let T = CACurrentMediaTime() + 1000
        e.setBeatClockQuietly(BeatClock(bpm: 120, anchorHost: T, anchorBeat: 0))
        e.resetUndo()
        let gen0 = e.slots[0]!.generator!, gen1 = e.slots[1]!.generator!, fx0 = e.slots[0]!.effects[0]
        let comp0 = e.effects[0]
        var levels: [Double?] = [0, 0.9]
        d.attackLevel = { _ in levels.isEmpty ? 0 : levels.removeFirst() }
        let n0 = d.tick(now: T + 1.9)          // 初めて見た：振らない（コンポジションの音は 0）
        let n1 = d.tick(now: T + 1.99)         // 音の立ち上がり → コンポジションだけ振る
        let n2 = d.tick(now: T + 2.0)          // 区切り → クリップのジェネレーターとエフェクト
        let n3 = d.tick(now: T + 2.0)
        let n4 = d.tick(now: T + 3.9)
        check(n0 == 0 && n1 == 1 && n2 == 2 && n3 == 0 && n4 == 0,
              "自動のサイコロ：出ているもの（再生中のクリップのジェネレーター・エフェクト・コンポジション）を時が来たら 1 回ずつ振る（\([n0, n1, n2, n3, n4])）")
        check(e.slots[0]!.generator!.values != gen0.values && e.slots[0]!.effects[0].values != fx0.values
              && e.effects[0].values != comp0.values,
              "自動のサイコロ：振ると値が変わる")
        check(e.slots[1]!.generator!.values == gen1.values, "自動のサイコロ：出ていないクリップのジェネレーターは振らない")
        check(e.slots[0]!.generator!.diceGlide.from != nil && e.slots[0]!.generator!.diceGlide.seconds == 0.5,
              "自動のサイコロ：つなぎ 1 拍（BPM 120）なら 0.5 秒かけて移る")
        check(!e.undoHistory.canUndo, "自動のサイコロ：自動で振った結果は元に戻すに積まない")

        // レイヤーを止めると、そのクリップは振らない
        e.stopLayer(0)
        let stopped = e.slots[0]!.generator!.values
        _ = d.tick(now: T + 4.01)
        _ = d.tick(now: T + 6.01)
        check(e.slots[0]!.generator!.values == stopped, "自動のサイコロ：止めたクリップは振らない")
        e.trigger(0)
        _ = d.tick(now: T + 6.5)                // また出たときは、すぐには振らない（初めて見た扱い）
        let shown = e.slots[0]!.generator!.values
        check(shown == stopped, "自動のサイコロ：また出したときは、次の区切りまで振らない")

        // 手で押すのは 1 歩、設定を変えるのも 1 歩
        e.resetUndo()
        let slot = e.slots[0]!
        let beforeManual = slot.generator!
        var fx = beforeManual
        EffectCardStep.roll(&fx, slight: false, engine: e)
        slot.generator = fx
        e.commitUndoStep()
        let one = e.undoHistory.canUndo
        e.undo()
        check(one && slot.generator!.values == beforeManual.values && !e.undoHistory.canUndo,
              "サイコロ：手で押すのは元に戻すの 1 歩（⌘Z で振る前に戻る）")
        let binding = Binding<Effect>(get: { slot.generator! }, set: { slot.generator = $0 })
        EffectDiceButton.setAuto(binding, engine: e) { $0.mode = .off }
        e.commitUndoStep()
        let offOK = slot.generator!.autoDice?.isOn == false
        e.undo()
        check(offOK && slot.generator!.autoDice == auto, "自動のサイコロ：設定を変えるのも 1 歩（しない → ⌘Z で元の設定）")

        // 自動で振っている途中に、手で動かしていた変更（まだ落ち着いていない）は、その歩に入る
        e.resetUndo()
        slot.generator!.values[1] = 0.33         // 手でつまみを動かした
        _ = d.tick(now: T + 8.01)
        e.commitUndoStep()
        check(e.undoHistory.canUndo, "自動のサイコロ：手で動かしていた変更は、自動で振っても消えずに 1 歩になる")

        // 見張り：自動の設定があるものが出ていれば動き、無くなれば止まる
        let e2 = Engine(persistent: false)
        _ = e2.placeGenerator(.plasma, at: 0)
        e2.trigger(0)
        let idle = e2.autoDice.isRunning
        e2.slots[0]?.generator?.autoDice = AutoDice(mode: .beats, every: 1)
        let running = e2.autoDice.isRunning
        e2.stopLayer(0)
        check(!idle && running && !e2.autoDice.isRunning, "自動のサイコロ：見張りは自動の設定が出ている間だけ動く")
    }

    // MARK: つなぎ

    private static func testDiceGlide(_ check: (Bool, String) -> Void) {
        let base = Effect(kind: .plasma)
        let ps = base.kind.params
        var g = SeededRandom(seed: 5)
        var n = base.rolled(using: &g, slight: false, glideSeconds: 1, at: 100)
        // 確かめやすいように、続いた値（0 番）と選択肢を必ず変える
        let ci = ps.indices.first { ps[$0].choices != nil && base.kind.diceable($0) }!
        let fi = ps.indices.first { ps[$0].choices == nil && !ps[$0].isToggle && base.kind.diceable($0) && ps[$0].step == 0 }!
        n.values[ci] = base.value(ci) == 0 ? 1 : 0
        n.values[fi] = base.value(fi) == ps[fi].range.upperBound ? ps[fi].range.lowerBound : ps[fi].range.upperBound
        let beat = BeatClock()
        func v(_ i: Int, _ t: Double) -> Double { n.value(i, at: t, beat: beat, origin: 0) }
        let a = base.value(fi), b = n.value(fi)
        let mid = v(fi, 100.5)
        check(abs(v(fi, 100) - a) < 1e-9 && abs(v(fi, 101.01) - b) < 1e-9 && mid > min(a, b) + 1e-6 && mid < max(a, b) - 1e-6,
              "つなぎ：振った直後は前の値、つなぎの後は新しい値、途中は間の値")
        check(v(ci, 100.4) == base.value(ci) && v(ci, 100.6) == n.value(ci), "つなぎ：選択肢は補間しない（半分で切り替える）")
        check(v(fi, 50) == b, "つなぎ：振る前の時刻（見本・サムネイル）は新しい値のまま")
        var same = n; same.diceGlide = DiceGlide()
        let json = (try? JSONEncoder().encode(n)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(same == n && !json.contains("diceGlide") && !json.contains("from"), "つなぎ：途中の様子は比べない・保存しない")
        var gq = SeededRandom(seed: 5)
        let quick = base.rolled(using: &gq, slight: false, glideSeconds: 0, at: 100)
        check(quick.diceGlide.from == nil && quick.value(fi, at: 100, beat: beat, origin: 0) == quick.value(fi), "つなぎ「すぐ」：すぐ新しい値")
        // 色相（0〜360）は近い方を回る
        var hue = Effect(kind: .plasma)
        if let hi = ps.indices.first(where: { ps[$0].range == 0...360 }) {
            hue.values[hi] = 350
            var h2 = hue; h2.values[hi] = 10
            h2.diceGlide = DiceGlide(from: hue.kind.params.indices.map { hue.value($0) }, at: 0, seconds: 1)
            let m = h2.value(hi, at: 0.5, beat: beat, origin: 0)
            check(m > 355 || m < 5, "つなぎ：角度は近い方を回る（350° → 10° の途中が \(Int(m))°）")
        }
    }

    // MARK: パネル・説明

    private static func testDiceMenu(_ check: (Bool, String) -> Void) {
        // パネルに出すもの：オフ・拍・音・音の入力オフ
        let off = DicePanelModel.make(nil, audioOn: true, beat: 0, now: 10, lastFire: nil)
        check(off.choice == .off && !off.showsBeats && !off.showsAudio && !off.active && off.flash == 0,
              "サイコロのパネル：オフのときは拍・音の欄を出さず、状態の丸は色なし")
        let beats = DicePanelModel.make(AutoDice(mode: .beats, every: 4), audioOn: true, beat: 6.5, now: 10, lastFire: 9.9)
        check(beats.choice == .beats && beats.showsBeats && !beats.showsAudio && beats.active
              && beats.dots == 4 && beats.litDots == 3 && abs(beats.progress - 0.625) < 1e-9 && beats.flash > 0.6
              && beats.stateText.contains(ParamAnim.beatsLabel(4)),
              "サイコロのパネル（拍）：4 拍ごとで 6.5 拍目なら 4 つの点の 3 つ目まで点く・振った直後は丸が光る（\(beats.stateText)）")
        let quarter = DicePanelModel.make(AutoDice(mode: .beats, every: 0.25), audioOn: true, beat: 0.1, now: 10, lastFire: 8)
        check(quarter.dots == 0 && abs(quarter.progress - 0.4) < 1e-9 && quarter.flash == 0,
              "サイコロのパネル（拍）：1 拍より短いときは細い棒で進み具合・時間がたつと光らない")
        let atk = DicePanelModel.make(AutoDice(mode: .attack, threshold: 0.4), audioOn: true, beat: 0, now: 10, lastFire: nil)
        let atkOff = DicePanelModel.make(AutoDice(mode: .attack), audioOn: false, beat: 0, now: 10, lastFire: 9.95)
        check(atk.showsAudio && atk.active && !atk.audioWarning && atk.stateText.contains("40%")
              && atkOff.showsAudio && atkOff.audioWarning && !atkOff.active && atkOff.flash == 0,
              "サイコロのパネル（音）：グラフとしきい値を出す。音の入力がオフなら知らせて、状態の丸は色なし")
        // 設定の変え方：しない・ほかも最初のままなら nil にする（保存を汚さない）
        var e = Effect(kind: .plasma)
        e = EffectDiceButton.settingAuto(e) { $0.mode = .beats }
        let on = e.autoDice?.isOn == true
        e = EffectDiceButton.settingAuto(e) { $0.mode = .off }
        let cleared = e.autoDice == nil
        e = EffectDiceButton.settingAuto(e) { $0.slight = true }
        check(on && cleared && e.autoDice?.slight == true && e.autoDice?.isOn == false,
              "サイコロ：オフに戻すと設定は消える（変え方・つなぎを変えていれば、オフのまま覚える）")
        // 説明：自動のことが分かる・自動の間は今の設定も
        var h = Effect(kind: .plasma)
        let plain = h.diceHelp
        h.autoDice = AutoDice(mode: .beats, every: 4, slight: true, glide: 1)
        let auto = h.diceHelp
        check(plain.contains("▾") && auto.contains(AutoDice(mode: .beats, every: 4, slight: true, glide: 1).summary)
              && auto.contains(L("自動：")) && auto.contains(L("少しだけ")),
              "サイコロの説明：自動で振れることが分かる・自動の間は「自動：4拍ごと・少しだけ…」も出る（\(auto.split(separator: "\n").last ?? "")）")
        // 振った知らせ：見張りが振ると、パネルが読む所に時刻が残る
        let mon = AutoDiceMonitor.shared
        let id = UUID()
        mon.fired(id, at: 5); mon.record(0.3, at: 5); mon.record(0.4, at: 5.001)
        check(mon.lastFire(id) == 5 && mon.levels.last?.level == 0.3, "サイコロ：振った時刻と立ち上がりの強さが、パネル用に残る（細かすぎる分は間引く）")
    }

    // MARK: 全部のジェネレーターを振る

    private static func testDiceGenerators(_ check: (Bool, String) -> Void) {
        let kinds = EffectKind.generators.filter { $0.hasDice }
        let ctx = MetalContext.shared
        let W = 320, H = 180
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead]
        let blank = ctx.device.makeTexture(descriptor: td)!
        let sweepDir = ProcessInfo.processInfo.environment["VJ_DICE_SWEEP_DIR"]
        func stats(_ a: [UInt8]) -> (lit: Int, white: Int) {
            var lit = 0, white = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                let s = Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])
                if s > 30 { lit += 1 }
                if s > 735 { white += 1 }
            }
            return (lit, white)
        }
        /// 描く。状態を持つものは、初めの値で 0 秒から 1/60 秒ずつ 1 秒進めてから（使っている途中で振るのと同じ）、
        /// 振った値でさらに 1.25 秒進める。絵と、最後の数コマの重さ（ms、いちばん速いもの）と、振ったあとのいちばん明るいコマの明るい所の数
        func draw(_ e: Effect) -> ([UInt8], Double, Int) {
            let fxp = EffectProcessor(); fxp.storageMode = .shared
            let warm = e.kind.isStateful ? 60 : 0
            let frames = warm + 75
            let first = Effect(kind: e.kind)
            var out = blank
            var ms = Double.infinity
            var maxLit = 0
            var q = [UInt8](repeating: 0, count: W * H * 4)
            for f in 0..<frames {
                // 状態を持たないものは、とびとびの時刻（3 秒から 0.1 秒ずつ）
                if !e.kind.isStateful && f % 15 != 14 && f < frames - 3 { continue }
                let t0 = CACurrentMediaTime()
                let cb = ctx.queue.makeCommandBuffer()!
                out = fxp.apply(EffectStack(effects: [f < warm ? first : e]), to: blank, key: "dice2", cb: cb,
                                now: e.kind.isStateful ? Double(f) / 60 : 3 + Double(f) / 10)
                cb.commit(); cb.waitUntilCompleted()
                if f >= frames - 3 { ms = min(ms, (CACurrentMediaTime() - t0) * 1000) }
                // 暗いかどうかは、振ったあとの何コマかのいちばん明るいもの（花火のように、間があくものがある）
                if f >= warm && (f - warm) % 15 == 14 {
                    out.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                    maxLit = max(maxLit, stats(q).lit)
                }
            }
            out.getBytes(&q, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            return (q, ms, max(maxLit, stats(q).lit))
        }
        var bad: [String] = []
        var nanBad: [String] = []
        var sheet: [(EffectKind, [[UInt8]])] = []
        let n = W * H
        for k in kinds {
            let base = Effect(kind: k)
            let (b0, ms0, lit0) = draw(base)
            var s0 = stats(b0)
            s0.lit = lit0
            var tiles = [b0]
            var why: [String] = []
            for seed in 1...5 as ClosedRange<UInt64> {
                var g = SeededRandom(seed: seed &* 104_729 &+ UInt64(k.rawValue.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }))
                let d = base.diced(using: &g)
                if d.values.contains(where: { !$0.isFinite }) { nanBad.append(k.rawValue) }
                let (img, ms, lit) = draw(d)
                tiles.append(img)
                var s = stats(img)
                s.lit = lit
                // 真っ黒：初めの絵には出ていたのに、ほとんど何も出ない
                if s0.lit >= n / 50 && s.lit < n / 200 { why.append("\(seed):暗い") }
                // 真っ白：ほとんど白（白黒の縞のような絵は、白が半分あってもよい）
                if s.white > n * 85 / 100 && s.white > s0.white * 2 { why.append("\(seed):真っ白") }
                // 重さ：初めの 3 倍を超える（短い時間はぶれるので 2 ms 以上のときだけ）
                if ms > 2 && ms > ms0 * 3 {
                    // ぶれかもしれないので、もう一度測る
                    let (_, again, _) = draw(d)
                    let (_, base2, _) = draw(base)
                    if again > 2 && again > min(ms0, base2) * 3 {
                        why.append(String(format: "%llu:重い %.1f→%.1fms", seed, min(ms0, base2), again))
                    }
                }
            }
            if !why.isEmpty { bad.append("\(k.rawValue)（\(why.joined(separator: " "))）") }
            if sweepDir != nil { sheet.append((k, tiles)) }
        }
        check(nanBad.isEmpty, "サイコロ（ジェネレーター）：振った値に NaN・無限大が出ない" + (nanBad.isEmpty ? "" : "（\(nanBad)）"))
        check(bad.isEmpty, "サイコロ（全部のジェネレーター \(kinds.count) 種類を 5 回ずつ）：真っ黒・真っ白にならない・重さは初めの 3 倍まで"
              + (bad.isEmpty ? "" : "（だめ：\(bad.joined(separator: "、"))）"))
        if let dir = sweepDir { writeDiceSheets(sheet, W: W, H: H, dir: dir) }
    }

    /// 振った絵の一覧（1 枚に 10 種類 × 初め + 5 回）
    private static func writeDiceSheets(_ sheet: [(EffectKind, [[UInt8]])], W: Int, H: Int, dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tw = W / 2, th = H / 2, label = 70, per = 10
        for (page, start) in stride(from: 0, to: sheet.count, by: per).enumerated() {
            let rows = Array(sheet[start..<min(start + per, sheet.count)])
            let SW = label + tw * 6, SH = th * rows.count
            var px = [UInt8](repeating: 30, count: SW * SH * 4)
            for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
            for (r, (_, tiles)) in rows.enumerated() {
                for (c, img) in tiles.enumerated() {
                    for y in 0..<th { for x in 0..<tw {
                        let si = ((y * 2) * W + x * 2) * 4
                        let di = ((r * th + y) * SW + label + c * tw + x) * 4
                        let a = Double(img[si + 3]) / 255
                        // 透明な所は暗い灰色の上に（BGRA → RGBA）
                        px[di] = UInt8(min(Double(img[si + 2]) + 20 * (1 - a), 255))
                        px[di + 1] = UInt8(min(Double(img[si + 1]) + 20 * (1 - a), 255))
                        px[di + 2] = UInt8(min(Double(img[si]) + 20 * (1 - a), 255))
                        px[di + 3] = 255
                    } }
                }
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: SW, pixelsHigh: SH, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: SW * 4, bitsPerPixel: 32)!
            px.withUnsafeBufferPointer { _ = memcpy(rep.bitmapData!, $0.baseAddress!, px.count) }
            // 名前を左に
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for (r, (k, _)) in rows.enumerated() {
                (k.rawValue as NSString).draw(at: NSPoint(x: 3, y: SH - r * th - th / 2 - 6),
                                              withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white])
            }
            NSGraphicsContext.restoreGraphicsState()
            let path = (dir as NSString).appendingPathComponent(String(format: "dice-generators-%02d.png", page + 1))
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
