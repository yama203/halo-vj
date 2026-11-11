import Foundation
import AppKit
import SwiftUI

// サイコロ：エフェクト・ジェネレーターの値をランダムにする（カードの見出しのボタン）。
// 変えないもの：オン／オフの値・動き（アニメーション）を付けた値・形を決める値（noDice）・
// 不透明度・画質・文字・入力の選択。色は色相だけを変える（白・黒・灰はそのまま）。

extension EffectKind {
    /// サイコロのボタンを出すか（外からの映像・文字は、ランダムにしても意味がない）
    var hasDice: Bool { ![.camera, .syphonIn, .ndiIn, .text, .clock].contains(self) && !isBlend && self != .transitionMask }

    /// 名前で決める「サイコロで変えない値」。元の絵を混ぜる量（不透明度と同じ働き）と、真ん中・位置。
    /// （あとから足した種類にも効くように、番号ではなく名前で見る）
    static var noDiceLabels: Set<String> {
        [L("元の絵"), L("下に元の絵"), L("元の色を残す"), L("上の絵も見せる"),
         L("中心の左右"), L("中心の上下"), L("位置 X"), L("位置 Y"), L("フォント")]
    }

    /// i 番目の値をサイコロで変えてよいか（動きを付けているかは見ない）
    func diceable(_ i: Int) -> Bool {
        let ps = params
        guard ps.indices.contains(i) else { return false }
        let p = ps[i]
        if p.isToggle || p.noDice || i == amountIndex { return false }
        return !Self.noDiceLabels.contains(p.label)
    }

    /// サイコロで色を変えるか（色を使う種類だけ）
    var dicesColor: Bool { usesColor || isMore || self == .colorize || self == .strobe }
}

extension Effect {
    /// サイコロで変えてよい値の番号（動きを付けている値は除く）
    var diceIndices: [Int] {
        kind.params.indices.filter { kind.diceable($0) && !(anims[String($0)]?.isOn ?? false) }
    }

    /// サイコロを振ったもの（slight：今の値から少しだけ動かす）。乱数を渡せるのでテストで同じ結果を出せる
    func diced<G: RandomNumberGenerator>(using rng: inout G, slight: Bool = false) -> Effect {
        var e = self
        let ps = kind.params
        while e.values.count < ps.count { e.values.append(ps[e.values.count].defaultValue) }
        for i in diceIndices {
            let p = ps[i]
            if let choices = p.choices {
                // 選択肢は、少しだけのときは変えない
                guard !slight, !choices.isEmpty else { continue }
                let hi = min(choices.count - 1, Int(p.range.upperBound.rounded(.down)))
                let lo = max(0, Int(p.range.lowerBound.rounded(.up)))
                guard hi >= lo else { continue }
                e.values[i] = Double(Int.random(in: lo...hi, using: &rng))
                continue
            }
            let r = p.animRange.map { $0.clamped(to: p.range) } ?? p.range
            var v: Double
            if slight {
                let w = (r.upperBound - r.lowerBound) * 0.15
                v = value(i) + (w > 0 ? Double.random(in: -w...w, using: &rng) : 0)
                if p.range == 0...360 { v = v.truncatingRemainder(dividingBy: 360); if v < 0 { v += 360 } }
            } else {
                v = r.lowerBound < r.upperBound ? Double.random(in: r, using: &rng) : r.lowerBound
            }
            v = min(max(v, p.range.lowerBound), p.range.upperBound)
            if p.step > 0 {
                v = (v / p.step).rounded() * p.step
                // 丸めて範囲の外に出たら、内側の段へ
                if v > p.range.upperBound { v -= p.step }
                if v < p.range.lowerBound { v += p.step }
            }
            e.values[i] = v
        }
        if kind.dicesColor {
            let (h, s, b) = color.hsb
            // 白・黒・灰（色みが無い）はそのまま
            if s > 0.02 && b > 0.02 {
                let nh = slight ? h + Double.random(in: -0.15...0.15, using: &rng) : Double.random(in: 0..<1, using: &rng)
                e.color = RGB.hsb(nh - floor(nh), s, b)
            }
        }
        return e
    }

    /// サイコロを振ったもの（ふだんの乱数）
    func diced(slight: Bool = false) -> Effect {
        var g = SystemRandomNumberGenerator()
        return diced(using: &g, slight: slight)
    }
}

/// 種から決まる乱数（テストで同じ結果を出す用）
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// カードの見出しのサイコロのボタン。⌥ を押しながらだと「少しだけ」
struct EffectDiceButton: View {
    @Binding var effect: Effect

    var body: some View {
        Button {
            let slight = NSEvent.modifierFlags.contains(.option)
            EffectCardStep.change(&effect) { $0.diced(slight: slight) }
        } label: {
            Image(systemName: "dice").frame(width: 18)
        }
        .help(L("値をランダムに（⌥：少しだけ）"))
    }
}

/// カードの見出しのボタンでの変更を、元に戻す（⌘Z）の 1 歩にする
enum EffectCardStep {
    static func change(_ effect: inout Effect, engine: Engine = .shared, _ f: (Effect) -> Effect) {
        // 前の変更（つまみのドラッグなど）と混ざらないように、待っている変更を先に 1 歩にする
        engine.commitUndoStep()
        let e = f(effect)
        if e != effect { effect = e }
    }
}
