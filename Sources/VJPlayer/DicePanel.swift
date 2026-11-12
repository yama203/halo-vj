import Foundation
import AppKit
import SwiftUI

// サイコロの ▾ で開く小さなパネル（設計は docs/dice-2-design.md の 5 章）。
// 値の動かし方のパネル（AnimEditor）と同じ見た目：紫の枠・ChoiceButtons・拍のボタン。
// 今すぐ振る・自動で振る［オフ｜拍｜音］・拍の進み具合・立ち上がりの強さのグラフとしきい値の線・変え方・つなぎ・状態の丸。

/// 自動で振るの切り替え（パネルの大きなボタン）
enum DiceAutoChoice: Hashable { case off, beats, attack }

/// パネルに出すもの（純粋な計算。テストで中身を確かめる）
struct DicePanelModel: Equatable {
    var choice: DiceAutoChoice
    /// 拍のボタン・進み具合を出すか
    var showsBeats: Bool
    /// グラフ・しきい値を出すか
    var showsAudio: Bool
    /// 「音の入力がオフです」を出すか
    var audioWarning: Bool
    /// 状態の丸に色を付けるか（自動で振っている）
    var active: Bool
    /// 状態の文
    var stateText: String
    /// 拍の進み具合：点の数（0 なら細い棒）と、点いている数（1〜dots）。棒のときは progress
    var dots: Int
    var litDots: Int
    var progress: Double
    /// 振った直後の光り具合（1 → 0、0.35 秒）
    var flash: Double

    static func make(_ auto: AutoDice?, audioOn: Bool, beat: Double, now: Double, lastFire: Double?) -> DicePanelModel {
        let a = auto ?? AutoDice(mode: .off)
        let choice: DiceAutoChoice = a.mode == .beats ? .beats : a.mode == .attack ? .attack : .off
        let every = max(a.every, 0.01)
        var phase = (beat / every).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        let dots = every >= 1 && every <= 16 && every == every.rounded() ? Int(every) : 0
        let lit = dots > 0 ? min(Int(phase * Double(dots)) + 1, dots) : 0
        let flash = lastFire.map { max(0, 1 - (now - $0) / 0.35) } ?? 0
        let text: String
        var active = a.isOn
        switch choice {
        case .off:
            text = L("オフ（「今すぐ振る」か、見出しのサイコロを押したときだけ）")
        case .beats:
            text = L("\(ParamAnim.beatsLabel(a.every))ごとに振っています")
        case .attack:
            if audioOn {
                text = L("音のアタックで振っています（しきい値 \(Int((a.threshold * 100).rounded()))%）")
            } else {
                text = L("音の入力がオフなので、振っていません")
                active = false
            }
        }
        return DicePanelModel(choice: choice, showsBeats: choice == .beats, showsAudio: choice == .attack,
                              audioWarning: choice == .attack && !audioOn, active: active, stateText: text,
                              dots: dots, litDots: lit, progress: phase, flash: active ? min(max(flash, 0), 1) : 0)
    }
}

/// サイコロのパネル
struct DicePanel: View {
    @Binding var effect: Effect
    /// 書き出し用：時刻・拍の時計・音の入力のあり／なしを決め打ちにする（nil ならいつもどおり）
    var fixedNow: Double? = nil
    var clock: BeatClock? = nil
    var audioOn: Bool? = nil
    var engine: Engine? = nil

    private var auto: AutoDice { effect.autoDice ?? AutoDice(mode: .off) }
    private var eng: Engine { engine ?? .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dice").font(.system(size: 12, weight: .semibold))
                Text(L("サイコロ")).font(.system(size: 12, weight: .semibold))
                Text(effect.kind.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Button {
                EffectCardStep.roll(&effect, slight: NSEvent.modifierFlags.contains(.option) || auto.slight, engine: eng)
                AutoDiceMonitor.shared.fired(effect.id, at: CACurrentMediaTime())
            } label: {
                Label(L("今すぐ振る"), systemImage: "dice.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("その場で 1 回振る（下の「変え方」で。⌥ を押しながらだと少しだけ）"))

            labeled(L("自動で振る")) {
                ChoiceButtons(selection: choiceBinding,
                              items: [(.off, L("オフ")), (.beats, "♩ " + L("拍")), (.attack, "〰 " + L("音"))], height: 30,
                              fontSize: 13,
                              help: { c in
                                  switch c {
                                  case .off: L("自動では振らない")
                                  case .beats: L("決めた拍ごとに振る")
                                  case .attack: L("キックのような、音の立ち上がりで振る")
                                  }
                              })
            }
            if auto.isOn {
                live { m in
                    VStack(alignment: .leading, spacing: 10) {
                        if m.showsBeats { beatsSection(m) }
                        if m.showsAudio { audioSection(m) }
                    }
                }
            }
            labeled(L("変え方")) {
                ChoiceButtons(selection: slightBinding, items: [(false, L("大きく")), (true, L("少しだけ"))],
                              help: { $0 ? L("今の値の近くで少しだけ動かす（形・色の選択肢は変えない）") : L("値の範囲の中で、大きく変える") })
            }
            labeled(L("つなぎ")) {
                HStack(spacing: 4) {
                    ChoiceButtons(selection: glideBinding,
                                  items: AutoDice.glideChoices.map { ($0, $0 <= 0 ? L("すぐ") : beatShort($0)) }, fontSize: 11)
                    Text(L("拍")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .help(L("振ったとき、何拍かけて前の値から新しい値へなめらかに移るか"))
            }
            Divider().opacity(0.5)
            live { m in stateRow(m) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(0.35)))
    }

    // MARK: 動く部分（開いている間だけ動く）

    @ViewBuilder
    private func live<V: View>(@ViewBuilder _ content: @escaping (DicePanelModel) -> V) -> some View {
        if let fixedNow {
            content(model(at: fixedNow))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let _ = ctx.date
                content(model(at: CACurrentMediaTime()))
            }
        }
    }

    private var isAudioOn: Bool { audioOn ?? (AudioReactive.shared.source != .off) }

    private func model(at now: Double) -> DicePanelModel {
        let c = clock ?? eng.beatClockForEditing()
        // グラフ用：見張りが動いていない（このパネルだけ開いている）ときも、立ち上がりの強さを残す
        if fixedNow == nil, auto.mode == .attack, isAudioOn, let v = eng.autoDice.attackLevel(now) {
            AutoDiceMonitor.shared.record(v, at: now)
        }
        return DicePanelModel.make(effect.autoDice, audioOn: isAudioOn, beat: c.beat(at: now), now: now,
                                   lastFire: AutoDiceMonitor.shared.lastFire(effect.id))
    }

    private func beatsSection(_ m: DicePanelModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ChoiceButtons(selection: everyBinding, items: AutoDice.everyChoices.map { ($0, beatShort($0)) }, fontSize: 11)
                Text(L("拍ごと")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
            // 次に振るまでの進み具合（点いている点が区切りまで進むと振る）
            HStack(spacing: 4) {
                if m.dots > 0 {
                    ForEach(0..<m.dots, id: \.self) { i in
                        Circle()
                            .fill(i < m.litDots ? Color.orange.opacity(0.55 + 0.45 * m.flash) : Color.white.opacity(0.10))
                            .frame(width: 9, height: 9)
                    }
                } else {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule().fill(Color.orange.opacity(0.7)).frame(width: g.size.width * m.progress)
                        }
                    }
                    .frame(height: 6)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 10)
            .help(L("次に振るまでの進み具合（BPM の拍に合わせて進む）"))
        }
    }

    private func audioSection(_ m: DicePanelModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if m.audioWarning {
                Text(L("音の入力がオフです（上のバーの「音の入力」でオンに）"))
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            AttackGraph(threshold: thresholdBinding, id: effect.id, now: fixedNow, dimmed: m.audioWarning)
                .frame(height: 64)
            ValueDrag(label: L("しきい値"), value: thresholdBinding, range: AutoDice.thresholdRange, perPoint: 0.003,
                      defaultValue: 0.5, showsBar: true, format: EffectParam.percent)
                .frame(height: UI.rowHeight)
                .help(L("立ち上がりの強さがこの線を超えた瞬間に振る。下げるほど小さな音でも振る（グラフの線を上下にドラッグしても変わる）"))
        }
    }

    private func stateRow(_ m: DicePanelModel) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if m.active {
                    Circle().fill(Color.orange.opacity(0.35 * m.flash)).frame(width: 20, height: 20)
                    Circle().fill(Color.orange.opacity(0.75 + 0.25 * m.flash)).frame(width: 11, height: 11)
                } else {
                    Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 11, height: 11)
                }
            }
            .frame(width: 20, height: 20)
            Text(m.stateText).font(.system(size: 12, weight: m.active ? .semibold : .regular))
                .foregroundStyle(m.active ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            content()
        }
    }

    // MARK: 設定の変更（ボタンは元に戻すの 1 歩。しきい値のドラッグは、落ち着いたら 1 歩）

    private var binding: Binding<Effect> { $effect }

    private var choiceBinding: Binding<DiceAutoChoice> {
        Binding(get: { DicePanelModel.make(effect.autoDice, audioOn: true, beat: 0, now: 0, lastFire: nil).choice },
                set: { c in
                    EffectDiceButton.setAuto(binding, engine: eng) {
                        $0.mode = c == .beats ? .beats : c == .attack ? .attack : .off
                    }
                })
    }
    private var everyBinding: Binding<Double> {
        Binding(get: { auto.every }, set: { v in EffectDiceButton.setAuto(binding, engine: eng) { $0.mode = .beats; $0.every = v } })
    }
    private var slightBinding: Binding<Bool> {
        Binding(get: { auto.slight }, set: { v in EffectDiceButton.setAuto(binding, engine: eng) { $0.slight = v } })
    }
    private var glideBinding: Binding<Double> {
        Binding(get: { auto.glide }, set: { v in EffectDiceButton.setAuto(binding, engine: eng) { $0.glide = v } })
    }
    private var thresholdBinding: Binding<Double> {
        Binding(get: { auto.threshold },
                set: { v in
                    let e = EffectDiceButton.settingAuto(effect) {
                        $0.threshold = min(max(v, AutoDice.thresholdRange.lowerBound), AutoDice.thresholdRange.upperBound)
                    }
                    if e != effect { effect = e }
                })
    }
}

/// 立ち上がりの強さの流れるグラフ（最近 2.5 秒）と、ドラッグできるしきい値の線。振った所に光る点
struct AttackGraph: View {
    @Binding var threshold: Double
    let id: UUID
    /// 書き出し用の決め打ちの時刻（nil なら今）
    var now: Double? = nil
    var dimmed = false
    static let window = 2.5

    var body: some View {
        GeometryReader { g in
            let t = now ?? CACurrentMediaTime()
            let mon = AutoDiceMonitor.shared
            let w = g.size.width, h = g.size.height
            Canvas { ctx, _ in
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 5),
                         with: .color(Color.black.opacity(0.25)))
                let th = threshold
                let barW = max(w / CGFloat(Self.window * 60) - 0.5, 1)
                for s in mon.levels where s.t > t - Self.window && s.t <= t {
                    let x = CGFloat((s.t - (t - Self.window)) / Self.window) * w
                    let v = min(max(s.level, 0), 1)
                    let bh = CGFloat(v) * (h - 4)
                    let over = v >= th
                    ctx.fill(Path(CGRect(x: x - barW, y: h - 2 - bh, width: barW, height: bh)),
                             with: .color(over ? Color.orange.opacity(0.9) : Color.white.opacity(0.35)))
                }
                // しきい値の線
                let y = h - 2 - CGFloat(th) * (h - 4)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(line, with: .color(Color.orange), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                // 振った所の印
                for f in mon.fires[id] ?? [] where f > t - Self.window && f <= t {
                    let x = CGFloat((f - (t - Self.window)) / Self.window) * w
                    let fresh = max(0, 1 - (t - f) / 0.35)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 2, width: 8, height: 8)),
                             with: .color(Color.orange.opacity(0.7 + 0.3 * fresh)))
                }
            }
            .opacity(dimmed ? 0.4 : 1)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let k = 1 - Double((v.location.y - 2) / max(h - 4, 1))
                threshold = min(max(k, AutoDice.thresholdRange.lowerBound), AutoDice.thresholdRange.upperBound)
            })
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        }
        .help(L("立ち上がりの強さ（最近 2.5 秒）。オレンジの線を上下にドラッグして、しきい値を変える"))
    }
}

extension CardPreview {
    /// 開発用：サイコロのパネルを PNG に  VJPlayer --dice-panel-preview off|beats|attack|audiooff out.png
    static func writeDicePanel(state: String, path: String) {
        var e = Effect(kind: .plasma)
        let now = 1000.0
        switch state {
        case "beats": e.autoDice = AutoDice(mode: .beats, every: 4, slight: true, glide: 0.5)
        case "attack", "audiooff": e.autoDice = AutoDice(mode: .attack, threshold: 0.45)
        default: e.autoDice = nil
        }
        // グラフの見本：キックのような立ち上がり（0.5 秒ごと）と、小さな音
        var levels: [(t: Double, level: Double)] = []
        var fires: [Double] = []
        var g = SeededRandom(seed: 3)
        for i in 0..<150 {
            let t = now - 2.5 + Double(i) / 60
            let ph = (t * 2).truncatingRemainder(dividingBy: 1)
            var v = exp(-ph * 6) * (i % 60 < 30 ? 0.95 : 0.7) + Double.random(in: 0...0.12, using: &g)
            if (t * 4).truncatingRemainder(dividingBy: 1) < 0.08 { v = max(v, 0.32) }
            levels.append((t, min(v, 1)))
        }
        let thr = e.autoDice?.threshold ?? 0.5
        fires = AutoDiceGate.attackFires(levels, threshold: thr).map { levels[$0].t }
        AutoDiceMonitor.shared.reset(levels: state == "audiooff" ? [] : levels,
                                     fires: state == "audiooff" ? [:] : [e.id: state == "beats" ? [now - 0.05] : fires])
        let clock = BeatClock(bpm: 120, anchorHost: now - 1.3, anchorBeat: 0)
        let v = DicePanelPreviewHost(effect: e, now: now, clock: clock, audioOn: state != "audiooff", engine: Engine(persistent: false))
            .frame(width: 320).padding(12)
        writeView(AnyView(v), path: path)
    }
}

private struct DicePanelPreviewHost: View {
    @State var effect: Effect
    let now: Double
    let clock: BeatClock
    let audioOn: Bool
    let engine: Engine
    var body: some View {
        DicePanel(effect: $effect, fixedNow: now, clock: clock, audioOn: audioOn, engine: engine)
    }
}
