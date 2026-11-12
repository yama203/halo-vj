import Foundation

// セルフテスト：エフェクトを別の場所へ付け替える（移す・写す）。画面なしのエンジンだけで確かめる

extension SelfTest {
    static func testEffectMove(check: (Bool, String) -> Void) {
        /// 値・動かし方・不透明度・オン/オフ・サイコロの自動を変えたエフェクト
        func custom(_ k: EffectKind) -> Effect {
            var f = Effect(kind: k)
            f.values[0] = (f.kind.params[0].range.lowerBound + f.kind.params[0].range.upperBound) / 3
            f.mix = 0.4
            f.enabled = false
            var a = ParamAnim(range: f.kind.params[0].range)
            a.mode = .beat
            f.anims["0"] = a
            f.setMixAnim({ var m = ParamAnim(range: 0...1); m.mode = .beat; return m }())
            f.autoDice = AutoDice(every: 8)
            return f
        }
        /// id 以外が同じか
        func sameContent(_ a: Effect?, _ b: Effect) -> Bool {
            guard var a else { return false }
            a.id = b.id
            return a == b
        }

        let e = Engine(persistent: false)
        _ = e.placeGenerator(.stripes, at: 0)
        _ = e.placeGenerator(.solid, at: 1)
        guard let c0 = e.slots[0], let c1 = e.slots[1] else { check(false, "付け替え：テスト用のクリップを置けない"); return }
        let fx = custom(.kaleidoscope)
        c0.effects = [Effect(kind: .mirror), fx, Effect(kind: .invert)]

        // クリップ → レイヤー
        let ok1 = e.transferEffect(fx.id, to: .layer(1))
        check(ok1 && e.layers[1].effects.last == fx && !c0.effects.contains { $0.id == fx.id } && c0.effects.count == 2,
              "付け替え：クリップ → レイヤー（値・動かし方・不透明度・オン/オフ・id がそのまま、元から消える）")
        // レイヤー → コンポジション
        let ok2 = e.transferEffect(fx.id, to: .composition)
        check(ok2 && e.effects == [fx] && e.layers[1].effects.isEmpty, "付け替え：レイヤー → コンポジション")
        // コンポジション → クリップ（途中に入る）
        let ok3 = e.transferEffect(fx.id, to: .clip(c1.id), at: 0)
        c1.effects.append(Effect(kind: .vhs))
        check(ok3 && c1.effects.first == fx && e.effects.isEmpty, "付け替え：コンポジション → クリップ（at: 0 で先頭に入る）")
        // クリップ → 別のクリップ（途中の位置）
        let ok4 = e.transferEffect(fx.id, to: .clip(c0.id), at: 1)
        check(ok4 && c0.effects.map(\.id)[1] == fx.id && c0.effects[1] == fx && c1.effects.map(\.kind) == [.vhs],
              "付け替え：クリップ → 別のクリップ（at: 1 で 2 番目に入る）")
        let loc = e.effectLocation(fx.id)
        check(loc?.place == .clip(c0.id) && loc?.index == 1, "付け替え：effectLocation で今の場所と位置が分かる")

        // 写す：元に残り、先は id が違い、中身は同じ
        let before = c0.effects
        let ok5 = e.transferEffect(fx.id, to: .layer(0), copy: true)
        let copied = e.layers[0].effects.last
        check(ok5 && c0.effects == before && copied?.id != fx.id && sameContent(copied, fx),
              "付け替え（写す）：元はそのまま、先には id だけ違う同じもの")

        // 同じ並びの中：今の moveEffect(_:to:) と同じ結果
        do {
            let list = (0..<4).map { _ in Effect(kind: .invert) }
            e.layers[2].effects = list
            var same = true
            for (from, to) in [(0, 3), (3, 0), (1, 2), (2, 1)] {
                e.layers[2].effects = list
                let ref = ClipSlot(effects: list)
                ref.moveEffect(list[from].id, to: to)
                e.transferEffect(list[from].id, to: .layer(2), at: to)
                same = same && e.layers[2].effects.map(\.id) == ref.effects.map(\.id)
            }
            e.layers[2].effects = list
            let ref = ClipSlot(effects: list)
            ref.moveEffect(list[1].id, to: list.count - 1)
            e.transferEffect(list[1].id, to: .layer(2))
            let toEnd = e.layers[2].effects.map(\.id) == ref.effects.map(\.id)
            e.layers[2].effects = list
            let noMove = !e.transferEffect(list[2].id, to: .layer(2), at: 2) && e.layers[2].effects == list
            e.transferEffect(list[0].id, to: .layer(2), at: 2, copy: true)
            let dup = e.layers[2].effects.count == 5 && e.layers[2].effects[2].id != list[0].id
                && sameContent(e.layers[2].effects[2], list[0]) && e.layers[2].effects[0] == list[0]
            check(same && toEnd && noMove && dup,
                  "付け替え：同じ並びの中は今の並べ替えと同じ（nil で最後・同じ位置は何もしない・写すとその位置に複製）")
        }

        // 断る：受けられない種類・空の枠・無いレイヤー・無い id。何も変わらない
        do {
            var gen = Effect(kind: .stripes)
            gen.values[0] = 1
            let blend = Effect(kind: .overdrive)
            e.layers[3].effects = [gen, blend]
            let snapLayers = e.layers.map(\.effects), snapComp = e.effects, snapC0 = c0.effects, snapC1 = c1.effects
            let r1 = e.transferEffect(gen.id, to: .clip(c1.id))
            let r2 = e.transferEffect(blend.id, to: .composition)
            let r3 = e.transferEffect(fx.id, to: .clip(UUID()))
            let r4 = e.transferEffect(fx.id, to: .layer(99))
            let r5 = e.transferEffect(UUID(), to: .composition)
            let unchanged = e.layers.map(\.effects) == snapLayers && e.effects == snapComp
                && c0.effects == snapC0 && c1.effects == snapC1
            check(!r1 && !r2 && !r3 && !r4 && !r5 && unchanged
                  && !e.canHold(.stripes, at: .layer(0)) && !e.canHold(.overdrive, at: .layer(0))
                  && !e.canHold(.transitionMask, at: .composition) && !e.canHold(.mirror, at: .clip(UUID()))
                  && e.canHold(.mirror, at: .clip(c0.id)) && e.canHold(.mirror, at: .layer(0)),
                  "付け替え：ジェネレーター・重ね方の値・空の枠・無いレイヤー・無い id は断り、何も変えない")
            e.layers[3].effects = []
        }

        // 別のデッキのクリップも見つかる・付け替えられる
        do {
            let d = e.addDeck()
            let i = e.slotIndex(deck: d, layer: 0, column: 2)
            _ = e.placeGenerator(.solid, at: i)
            let other = custom(.vhs)
            e.slots[i]?.effects = [other]
            let found = e.effectLocation(other.id)
            let moved = e.transferEffect(other.id, to: .clip(c1.id))
            check(found?.place == e.slots[i].map { .clip($0.id) } && moved && c1.effects.last == other
                  && e.slots[i]?.effects.isEmpty == true,
                  "付け替え：別のデッキのクリップのエフェクトも見つかり、移せる")
            e.showDeck(0)
        }

        // 元に戻す：1 回で両方（元と先）が戻る
        do {
            let u = Engine(persistent: false)
            _ = u.placeGenerator(.stripes, at: 0)
            let f = custom(.kaleidoscope)
            u.slots[0]?.effects = [f]
            u.commitUndoStep()
            u.transferEffect(f.id, to: .layer(1))
            // 戻すと保存の形を通るので、id と値で比べる（動かし始めた時刻などは保存しない）
            func isF(_ l: [Effect]?) -> Bool {
                guard let l, l.count == 1 else { return false }
                return l[0].id == f.id && l[0].values == f.values && l[0].mix == f.mix && l[0].enabled == f.enabled
                    && l[0].anims["0"]?.mode == .beat && l[0].autoDice == f.autoDice
            }
            let movedOK = isF(u.layers[1].effects) && u.slots[0]?.effects.isEmpty == true
            u.undo()
            let back = isF(u.slots[0]?.effects) && u.layers[1].effects.isEmpty
            u.redo()
            let again = isF(u.layers[1].effects) && u.slots[0]?.effects.isEmpty == true
            check(movedOK && back && again, "付け替え：⌘Z 1 回で元にも先にも戻る（やり直しで再び移る）")
        }

        // エフェクトのクリップ（調整レイヤーの枠）
        do {
            let a = Engine(persistent: false)
            a.insertAdjustmentLayer(at: 0)
            let i = a.slotIndex(deck: 0, layer: 0, column: 1)
            _ = a.createEffectClip(at: i, with: .invert)
            guard let clip = a.slots[i], let fid = clip.effects.first?.id else { check(false, "付け替え：エフェクトのクリップを作れない"); return }
            let toLayer = a.transferEffect(fid, to: .layer(1))
            let back = a.transferEffect(fid, to: .clip(clip.id))
            check(toLayer && back && clip.effects.map(\.id) == [fid] && a.layers[1].effects.isEmpty,
                  "付け替え：エフェクトのクリップ（調整レイヤー）とレイヤーの間で移せる")
        }

        // シーンの編集中：コンポジション・レイヤーは、画面に出ているシーンのもの
        do {
            let s = Engine(persistent: false)
            _ = s.placeGenerator(.stripes, at: 0)
            let f = custom(.mirror)
            s.slots[0]?.effects = [f]
            let compBefore = Effect(kind: .invert)
            s.effects = [compBefore]
            let sc = s.captureScene(name: "A", fade: 0)
            s.scenes = [sc]
            s.editScene(sc.id)
            guard let d = s.sceneDraft else { check(false, "付け替え：シーンの編集を始められない"); return }
            let toComp = s.transferEffect(f.id, to: .composition)
            let inDraft = d.effects.last == f && s.effects == [compBefore] && s.slots[0]?.effects.isEmpty == true
            let written = s.scenes.first?.compEffects.last == f
            let toLayer = s.transferEffect(f.id, to: .layer(1))
            let inDraftLayer = d.layers[1].effects == [f] && s.layers[1].effects.isEmpty && !d.effects.contains(f)
            let toClip = s.transferEffect(f.id, to: .clip(s.slots[0]!.id))
            check(toComp && inDraft && written && toLayer && inDraftLayer && toClip && s.slots[0]?.effects == [f],
                  "付け替え：シーンの編集中は、シーンのコンポジション・レイヤーとクリップの間で移す（出力のほうは変えない）")
            s.closeSceneEditor()
        }

        // 画面から落としたとき：同じ場所・同じ位置は何もしない。写すと開いていたカードは写した先でも開く。ドラッグ中の印は消える
        do {
            let ui = EffectUIState.shared
            let id = c0.effects[0].id
            EffectDragState.shared.begin(id)
            let snap = c0.effects
            let same = !EffectTransfer.drop(id, to: .clip(c0.id), at: 0, copy: false, engine: e) && c0.effects == snap
            let cleared = !EffectDragState.shared.active && ui.dragging == nil
            ui.expanded.insert(id)
            let copied = EffectTransfer.drop(id, to: .layer(3), copy: true, engine: e)
            let newID = e.layers[3].effects.last?.id
            let opened = newID.map { ui.expanded.contains($0) } ?? false
            ui.expanded.remove(id)
            if let newID { ui.expanded.remove(newID) }
            e.layers[3].effects = []
            check(same && cleared && copied && newID != id && opened,
                  "付け替え（画面）：同じ位置へ落としても何もしない・写すと開いていたカードは先でも開く・ドラッグ中の印を消す")
        }

        // 右クリックの先：コンポジション・全部のレイヤー・選んでいるクリップ
        do {
            e.inspectedIndex = 1
            let places = e.effectMenuPlaces
            check(places.first == .composition && places.contains(.layer(e.layers.count - 1)) && places.contains(.clip(c1.id))
                  && e.effectPlaceName(.clip(c1.id)).contains(c1.name),
                  "付け替え：右クリックの先にコンポジション・全部のレイヤー・選んでいるクリップが出る")
        }
    }
}
