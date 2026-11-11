import Foundation

// セルフテスト：サイコロ（値をランダムに）とエフェクトのプリセット。
// プリセットは一時フォルダのファイルだけを使う（利用者のファイルには触れない）。

extension SelfTest {
    static func testDiceAndPresets(check: (Bool, String) -> Void) {
        testDice(check)
        testPresets(check)
    }

    private static func testDice(_ check: (Bool, String) -> Void) {
        let kinds = EffectKind.allCases.filter { $0.hasDice }
        var inRange = true, onStep = true, choicesOK = true, keptToggle = true, keptNoDice = true
        var changedSome = 0, keptAnim = true, sameSeed = true, slightOK = true, slightChoices = true
        var keptCard = true, colorOK = true
        for k in kinds {
            var base = Effect(kind: k)
            base.mix = 0.42
            let ps = k.params
            // 1 つ目の動かせる値に動きを付けておく（その値は変わらないこと）
            let animIdx = ps.indices.first { ps[$0].animatable && k.diceable($0) }
            if let i = animIdx { var a = base.anim(i); a.mode = .beat; base.setAnim(i, a) }
            for seed in 0..<6 as Range<UInt64> {
                var g = SeededRandom(seed: seed &* 7919 &+ UInt64(k.rawValue.count))
                let d = base.diced(using: &g)
                var g2 = SeededRandom(seed: seed &* 7919 &+ UInt64(k.rawValue.count))
                if d != base.diced(using: &g2) { sameSeed = false }
                if d.id != base.id || d.enabled != base.enabled || d.mix != base.mix || d.quality != base.quality
                    || d.text != base.text || d.points != base.points || d.anims != base.anims { keptCard = false }
                if d.values != base.values { changedSome += 1 }
                for i in ps.indices {
                    let p = ps[i], v = d.values[i]
                    if v < p.range.lowerBound - 1e-9 || v > p.range.upperBound + 1e-9 { inRange = false }
                    if p.step > 0, abs(v / p.step - (v / p.step).rounded()) > 1e-9 { onStep = false }
                    if let c = p.choices, abs(v - v.rounded()) > 1e-9 || v < 0 || Int(v) >= c.count { choicesOK = false }
                    if p.isToggle, v != base.values[i] { keptToggle = false }
                    if !k.diceable(i), v != base.values[i] { keptNoDice = false }
                    if i == animIdx, v != base.values[i] { keptAnim = false }
                }
                // 色：彩度・明るさはそのまま
                let (_, s0, b0) = base.color.hsb, (_, s1, b1) = d.color.hsb
                if abs(s0 - s1) > 1e-6 || abs(b0 - b1) > 1e-6 { colorOK = false }
                // 少しだけ：範囲の ±15% の中・選択肢は変えない
                var g3 = SeededRandom(seed: seed &+ 100)
                let sl = base.diced(using: &g3, slight: true)
                for i in ps.indices {
                    let p = ps[i]
                    if p.choices != nil || p.isToggle {
                        if sl.values[i] != base.values[i] { slightChoices = false }
                        continue
                    }
                    let r = p.animRange.map { $0.clamped(to: p.range) } ?? p.range
                    var diff = abs(sl.values[i] - base.value(i))
                    if p.range == 0...360 { diff = min(diff, 360 - diff) }
                    if diff > (r.upperBound - r.lowerBound) * 0.15 + max(p.step, 0) + 1e-6 { slightOK = false }
                }
            }
        }
        check(inRange && onStep && choicesOK, "サイコロ：値は範囲の中・段（step）に乗る・選択肢は範囲の整数（\(kinds.count) 種類）")
        check(keptToggle && keptNoDice && keptAnim, "サイコロ：オン/オフ・動きを付けた値・形を決める値（noDice）は変えない")
        check(keptCard && colorOK, "サイコロ：不透明度・画質・文字・動きの割り当ては変えない。色は彩度・明るさを保つ")
        check(sameSeed && changedSome > kinds.count * 4, "サイコロ：同じ種の乱数で同じ結果・ふつうは値が変わる")
        check(slightOK && slightChoices, "サイコロ（⌥ 少しだけ）：範囲の ±15% の中で動き、選択肢・オン/オフは変えない")
        // 白・黒（色みが無い）は変えない
        var w = Effect(kind: .solid); w.color = .white
        var g = SeededRandom(seed: 3)
        check(w.diced(using: &g).color == .white, "サイコロ：白い色はそのまま")
        // マスクの位置・大きさは変えない
        let m = Effect(kind: .shapeMask)
        var gm = SeededRandom(seed: 9)
        let md = m.diced(using: &gm)
        check(Array(md.values[2...6]) == Array(m.values[2...6]), "サイコロ：マスク（形）の位置・幅・高さ・角度は変えない")
        check(!EffectKind.camera.hasDice && !EffectKind.text.hasDice && !EffectKind.clock.hasDice
              && !EffectKind.syphonIn.hasDice && !EffectKind.ndiIn.hasDice && EffectKind.kaleidoscope.hasDice,
              "サイコロ：カメラ・Syphon・NDI・テキスト・時計にはボタンを出さない")

        // 元に戻す：サイコロは 1 回で 1 歩（前のドラッグとは別の歩）
        let e = Engine(persistent: false)
        _ = e.placeGenerator(.stripes, at: 0)
        e.slots[0]?.effects = [Effect(kind: .kaleidoscope)]
        e.commitUndoStep()
        e.slots[0]?.effects[0].values[0] = 9       // つまみを動かした（まだ落ち着いていない）
        var fx = e.slots[0]!.effects[0]
        var gu = SeededRandom(seed: 1)
        EffectCardStep.change(&fx, engine: e) { $0.diced(using: &gu) }
        e.slots[0]?.effects[0] = fx
        e.commitUndoStep()
        let diced = e.slots[0]?.effects[0].values
        e.undo()
        let afterOne = e.slots[0]?.effects[0].values
        e.undo()
        check(diced != afterOne && afterOne?[0] == 9 && e.slots[0]?.effects[0].values[0] == 6,
              "サイコロ：⌘Z 1 回でサイコロの前に戻る（その前のつまみの変更とは別の歩）")
    }

    private static func testPresets(_ check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vj-presets-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("effect-presets.json")

        // セルフテスト中の本番の保存先は「書かない」
        check(ProcessInfo.processInfo.environment["VJ_STATE_PATH"] != nil || EffectPresets.defaultURL == nil,
              "プリセット：セルフテスト中は利用者のファイルを読み書きしない")

        let store = EffectPresets(url: url)
        var src = Effect(kind: .kaleidoscope)
        var g = SeededRandom(seed: 42)
        src = src.diced(using: &g)
        src.color = RGB.hsb(0.3, 0.8, 0.9)
        src.palette = [.black, .white, RGB.hsb(0.5, 1, 1)]
        var a = src.anim(1); a.mode = .beat; src.setAnim(1, a)
        src.mix = 0.3; src.enabled = false; src.text = "ひみつ"
        let saved = store.save(name: "  ゆっくり  ", effect: src)

        // 読み直して当てる
        let again = EffectPresets(url: url)
        let list = again.list(for: .kaleidoscope)
        var target = Effect(kind: .kaleidoscope)
        target.mix = 0.8
        let applied = list.first.map { again.apply($0, to: target) }
        check(list.count == 1 && list[0].name == "ゆっくり" && list[0].id == saved.id,
              "プリセット：保存して読み直すと、名前（前後の空白は除く）と一緒に出る")
        check(applied?.values == src.values && applied?.color == src.color && applied?.palette == src.palette
              && applied?.anims["1"]?.mode == .beat,
              "プリセット：当てると値・色・パレット・動きの割り当てが同じになる")
        check(applied?.id == target.id && applied?.mix == 0.8 && applied?.enabled == true && applied?.text == target.text,
              "プリセット：カードのもの（目印・オン/オフ・不透明度・文字）はそのまま")
        let bl = Effect(kind: .bloom)
        check(again.list(for: .bloom).isEmpty && EffectPresets.apply(list[0], to: bl) == bl,
              "プリセット：別の種類には出ない・当たらない")

        // 上書き・番号
        var src2 = src; src2.values[0] = 12
        store.save(name: "ゆっくり", effect: src2)
        let p1 = store.save(name: "", effect: src)
        let p2 = store.save(name: " ", effect: src)
        let l2 = EffectPresets(url: url).list(for: .kaleidoscope)
        check(l2.count == 3 && l2.first { $0.name == "ゆっくり" }?.effect.values[0] == 12,
              "プリセット：同じ名前で保存すると上書き")
        check(p1.name == L("プリセット \(1)") && p2.name == L("プリセット \(2)"), "プリセット：名前が空なら番号を振る")

        // 削除
        store.delete(p1.id)
        let l3 = EffectPresets(url: url).list(for: .kaleidoscope)
        check(l3.count == 2 && !l3.contains { $0.id == p1.id }, "プリセット：消すと一覧から無くなる")

        // 値の数が違うプリセット（あとで値が増えた・減った）
        var short = EffectPreset(name: "短い", effect: Effect(kind: .kaleidoscope))
        short.effect.values = [3, 50]
        short.effect.anims = ["99": ParamAnim(range: 0...1)]
        var long = EffectPreset(name: "長い", effect: Effect(kind: .kaleidoscope))
        long.effect.values = Array(repeating: 2, count: 40)
        let base = Effect(kind: .kaleidoscope)
        let s1 = EffectPresets.apply(short, to: base)
        let s2 = EffectPresets.apply(long, to: base)
        check(s1.values.count == base.values.count && s1.values[0] == 3 && Array(s1.values[2...]) == Array(base.values[2...])
              && s1.anims["99"] == nil && s2.values.count == base.values.count,
              "プリセット：値の数が違っても落ちない（足りない分は今の値・多い分は捨てる）")

        // 壊れたファイル：空から始め、保存するまでは上書きしない
        let broken = dir.appendingPathComponent("broken.json")
        try? Data("{ これは壊れている".utf8).write(to: broken)
        let b = EffectPresets(url: broken)
        let untouched = (try? String(contentsOf: broken, encoding: .utf8)) == "{ これは壊れている"
        b.save(name: "新しい", effect: Effect(kind: .bloom))
        check(b.all.count == 1 && untouched && EffectPresets(url: broken).list(for: .bloom).count == 1,
              "プリセット：壊れたファイルは無視して空から（次に保存したときだけ書き直す）")

        // 今までの保存データ（noDice は保存しない項目）：エフェクトの書き出しに増えた項目が無い
        let json = (try? JSONEncoder().encode(Effect(kind: .shapeMask))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(!json.contains("noDice") && !json.contains("dice"), "プリセット：エフェクトの保存の形は今までどおり")
    }
}
