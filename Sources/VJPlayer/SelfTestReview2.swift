import Foundation

/// 2026-11 の点検で直した所の確かめ（OSC の番号・四隅・プリセットの読み方・形が変わる「元に戻す」）
extension SelfTest {
    static func testReview2(check: (Bool, String) -> Void) {
        // 1. OSC：番号が 0 以下・とても小さい数でも落ちない（何もしない）。ふつうの番号は効く
        do {
            let e = Engine(persistent: false)
            e.setSlot(0, ClipSlot(generator: Effect(kind: .solid)))
            for a in ["/halo/layer/-9223372036854775808/clip/1", "/halo/layer/0/clip/1", "/halo/cue/-9223372036854775808",
                      "/halo/scene/0", "/halo/deck/-1", "/halo/pad/-9223372036854775808"] {
                OSCCommands.run(OSCMessage(address: a, args: [.float(1)]), engine: e)
            }
            let before = e.activeByLayer[0]
            OSCCommands.run(OSCMessage(address: "/halo/layer/1/clip/1", args: [.float(1)]), engine: e)
            check(before == nil && e.activeByLayer[0] == 0, "OSC：0 以下・あふれる番号は捨てる（落ちない）。1 からの番号は効く")
            e.stopAll()
        }

        // 2. 四隅：形のおかしい保存（点が足りない・数でない）は初期の四隅に
        do {
            let ok: [[Float]] = [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]]
            check(Engine.decodeCorners(ok).count == 4 && Engine.decodeCorners(ok)[0].x == 0.1
                  && Engine.decodeCorners([[0], [1, 1], [1, 0], [0, 0]]) == Engine.defaultCorners
                  && Engine.decodeCorners([[.nan, 0], [1, 1], [1, 0], [0, 0]]) == Engine.defaultCorners
                  && Engine.decodeCorners([]) == Engine.defaultCorners,
                  "四隅：点の中身が足りない・数でない保存でも落ちず、初期の四隅になる")
        }

        // 3. プリセット：読めない項目が混ざっていても、ほかは読める。保存しても読めない項目は消えない
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-presets-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("effect-presets.json")
            let good = EffectPreset(name: "前からある", effect: Effect(kind: .blur))
            var items = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode([good])) as? [Any]) ?? []
            items.append(["id": UUID().uuidString, "name": "未来の種類", "effect": ["kind": "kindFromTheFuture"]] as [String: Any])
            try? JSONSerialization.data(withJSONObject: items).write(to: url)
            let p = EffectPresets(url: url)
            let read = p.all.map(\.name) == ["前からある"]
            p.save(name: "足した", effect: Effect(kind: .blur))
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let again = EffectPresets(url: url)
            check(read && Set(again.all.map(\.name)) == ["前からある", "足した"] && text.contains("kindFromTheFuture"),
                  "プリセット：読めない項目が 1 つあっても、ほかは読める。保存しても全部残る（\(again.all.map(\.name))）")

            // 全体が壊れたファイルは、上書きせずに横へよける
            try? Data("{ こわれた".utf8).write(to: url)
            let q = EffectPresets(url: url)
            q.save(name: "新しい", effect: Effect(kind: .blur))
            let side = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.contains("broken-") } ?? []
            check(side.count == 1 && EffectPresets(url: url).all.map(\.name) == ["新しい"],
                  "プリセット：全体が壊れたファイルは、消さずに横へよけてから書く（\(side)）")
        }

        // 4. 形が変わる「元に戻す」：再生中のクリップは止まらず、同じクリップのまま
        do {
            let e = Engine(persistent: false)
            let clip = ClipSlot(generator: Effect(kind: .solid))
            e.setSlot(1, clip)               // 1 段目・2 列目
            e.trigger(1)
            e.commitUndoStep()
            let (l0, c0, d0) = (e.layers.count, e.columns, e.decks.count)
            func alive(_ what: String) -> Bool {
                guard let a = e.activeByLayer.compactMap({ $0 }).first else { return false }
                return e.slots[a] === clip && clip.isPlaying && e.layers.count == l0 && e.columns == c0 && e.decks.count == d0
                    && e.layerOf(a) == 0 && e.columnOf(a) == 1
            }
            e.insertLayer(at: 0); e.commitUndoStep(); e.undo()
            let a1 = alive("段")
            e.insertColumn(at: 0); e.commitUndoStep(); e.undo()
            let a2 = alive("列")
            e.addDeck(); e.commitUndoStep(); e.undo()
            let a3 = alive("デッキ")
            e.removeColumn(0); e.commitUndoStep(); e.undo()
            let a4 = alive("列を消した")
            e.redo(); e.undo()
            let a5 = alive("やり直して戻す")
            check(a1 && a2 && a3 && a4 && a5,
                  "元に戻す：段・列・デッキを足した／列を消したのを戻しても、再生中のクリップは止まらず同じ場所に戻る（\(a1) \(a2) \(a3) \(a4) \(a5)）")
            e.stopAll()
        }
    }
}
