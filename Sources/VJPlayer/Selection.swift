import AppKit

/// グリッドのクリップの複数選択（⇧クリック）と、まとめての削除・移動
extension Engine {
    /// ⇧クリック：選択に足す／外す（クリップのある枠だけ。別のデッキの選択は外す）
    func toggleMultiSelect(_ i: Int) {
        guard slots.indices.contains(i), slots[i] != nil else { return }
        if multiSelection.contains(where: { deckOf($0) != deckOf(i) }) { multiSelection = [] }
        if multiSelection.contains(i) { multiSelection.remove(i) } else { multiSelection.insert(i) }
    }

    func clearMultiSelection() {
        if !multiSelection.isEmpty { multiSelection = [] }
    }

    /// 選んだクリップをまとめてグリッドから外す（再生中なら止まる）
    func deleteSelection() {
        let sel = multiSelection.filter { slots.indices.contains($0) && slots[$0] != nil }
        multiSelection = []
        for i in sel.sorted() { clear(i) }
    }

    /// 選んだクリップを、anchor が to に来るようにまとめて動かす（並びはそのまま）。
    /// はみ出す・行き先に選んでいないクリップがあるときは動かさずに false
    @discardableResult
    func moveSelection(anchor: Int, to target: Int) -> Bool {
        guard multiSelection.contains(anchor), slots.indices.contains(target) else { return false }
        let dd = deckOf(target) - deckOf(anchor)
        let dr = layerOf(target) - layerOf(anchor), dc = columnOf(target) - columnOf(anchor)
        return moveSelection { i in
            let d = deckOf(i) + dd, r = layerOf(i) + dr, c = columnOf(i) + dc
            guard decks.indices.contains(d), layers.indices.contains(r), c >= 0, c < columns else { return nil }
            return slotIndex(deck: d, layer: r, column: c)
        }
    }

    /// 選んだクリップを、別のデッキの同じ場所へ動かす
    @discardableResult
    func moveSelection(toDeck d: Int) -> Bool {
        guard decks.indices.contains(d) else { return false }
        return moveSelection { i in slotIndex(deck: d, layer: layerOf(i), column: columnOf(i)) }
    }

    private func moveSelection(_ map: (Int) -> Int?) -> Bool {
        let sel = multiSelection.filter { slots.indices.contains($0) && slots[$0] != nil }
        guard !sel.isEmpty else { return false }
        var plan: [Int: Int] = [:]
        for i in sel {
            guard let t = map(i), slots.indices.contains(t) else { return false }
            // 行き先は空き、または一緒に動くクリップの場所だけ
            if slots[t] != nil && !sel.contains(t) { return false }
            plan[i] = t
        }
        guard Set(plan.values).count == plan.count else { return false }
        if plan.allSatisfy({ $0.key == $0.value }) { return true }
        // 行き先が空いているものから順に動かす（ずらすだけなので必ず順番が見つかる）
        var left = plan
        while !left.isEmpty {
            guard let (from, to) = left.first(where: { slots[$0.value] == nil }) else { return false }
            moveSlot(from, to: to)
            left.removeValue(forKey: from)
        }
        multiSelection = Set(plan.values)
        return true
    }
}
