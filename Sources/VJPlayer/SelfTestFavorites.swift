import Foundation

// セルフテスト：エフェクト・ジェネレーターの「お気に入り」と「最近使った」。
// 保存は一時の UserDefaults(suiteName:) だけを使い、終わったら消す（利用者の設定には触れない）。

extension SelfTest {
    static func testFavorites(check: (Bool, String) -> Void) {
        // アプリで使うものは、テストの起動では保存しない
        check(EffectPresets.isDevRun && EffectFavorites.shared.defaults == nil,
              "お気に入り：テストの起動では UserDefaults に読み書きしない（メモリの中だけ）")

        // 入れる・外す・順番（保存先なしでも落ちない）
        do {
            let f = EffectFavorites(defaults: nil)
            f.toggle(.strobe)
            f.toggle(.mirror)
            f.toggle(.tunnel)
            let order1 = f.favorites
            f.toggle(.mirror)
            let order2 = f.favorites
            f.toggle(.mirror)
            check(order1 == [.strobe, .mirror, .tunnel] && order2 == [.strobe, .tunnel]
                  && f.favorites == [.strobe, .tunnel, .mirror] && f.isFavorite(.mirror) && !f.isFavorite(.echo),
                  "お気に入り：入れた順に並び、もう一度で外れる（入れ直すと後ろへ）")
        }

        // 最近使った：8 個まで・同じものは先頭へ
        do {
            let f = EffectFavorites(defaults: nil)
            let kinds: [EffectKind] = [.strobe, .mirror, .echo, .vhs, .crt, .warp, .fluid, .levels, .posterize, .invert]
            for k in kinds { f.note(k) }
            let after10 = f.recents
            f.note(.crt)
            check(after10 == Array(kinds.reversed().prefix(8)) && f.recents.first == .crt && f.recents.count == 8
                  && f.recents.filter { $0 == .crt }.count == 1,
                  "最近使った：新しい順に 8 個まで、同じものは先頭へ（\(f.recents.count) 個）")
        }

        // 知らない名前は飛ばすが、書き戻しても残す。一時の UserDefaults で保存と読み直し
        let suite = "vjplayer-selftest-favorites-\(UUID().uuidString)"
        if let d = UserDefaults(suiteName: suite) {
            d.set(["strobe", "futureKind", "mirror"], forKey: EffectFavorites.favoritesKey)
            d.set(["oldKind", "echo"], forKey: EffectFavorites.recentsKey)
            let f = EffectFavorites(defaults: d)
            let read = f.favorites == [.strobe, .mirror] && f.recents == [.echo]
            f.toggle(.tunnel)
            f.toggle(.strobe)
            f.note(.vhs)
            let savedFav = d.stringArray(forKey: EffectFavorites.favoritesKey) ?? []
            let savedRec = d.stringArray(forKey: EffectFavorites.recentsKey) ?? []
            check(read && savedFav == ["futureKind", "mirror", "tunnel"] && savedRec == ["vhs", "oldKind", "echo"],
                  "お気に入り：知らない名前は読むとき飛ばし、書き戻しても残る（\(savedFav.joined(separator: ","))）")
            let again = EffectFavorites(defaults: d)
            check(again.favorites == [.mirror, .tunnel] && again.recents == [.vhs, .echo],
                  "お気に入り・最近使った：保存して読み直すと同じ")
            d.removePersistentDomain(forName: suite)
            // 空になった一時のファイルも消す（この名前のものだけ）
            d.synchronize()
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: file)
        } else {
            check(false, "お気に入り：一時の UserDefaults が作れない")
        }

        // ピッカー：何も打っていないときは上にお気に入り・最近使った。検索中はお気に入りが同じ当たり方の中で先
        do {
            let base = EffectPicker.results("", includeGenerators: false)
            let empty = EffectPicker.results("", includeGenerators: false, favorites: [.echo, .tunnel], recents: [.vhs, .metaballs])
            let secs = EffectPicker.emptySections(includeGenerators: false, favorites: [.echo, .tunnel], recents: [.vhs, .metaballs])
            let q0 = EffectPicker.results("みらー", includeGenerators: false)
            let qf = EffectPicker.results("e", includeGenerators: true, favorites: [.tunnel, .echo])
            let qn = EffectPicker.results("e", includeGenerators: true)
            let heads = secs.prefix(2).map(\.1)
            check(Array(empty.prefix(2)) == [.echo, .vhs] && Array(empty.dropFirst(2)) == base
                  && heads == [[.echo], [.vhs]]
                  && EffectPicker.results("みらー", includeGenerators: false, favorites: [.echo]) == q0
                  && Set(qf.prefix(2)) == [.tunnel, .echo] && Set(qf) == Set(qn) && qf.count == qn.count,
                  "ピッカー：空のときは上にお気に入り・最近使った（ジェネレーターは出さない窓では飛ばす）、検索中はお気に入りが先")
        }

        // ピッカー：星を押して並びが変わっても、選んでいる種類は変わらない（すぐ Enter で隣の種類が足されない）
        do {
            func rows(_ q: String, _ f: [EffectKind]) -> [(String, [EffectKind])] {
                EffectPicker.rows(q, includeGenerators: true, favorites: f, recents: [.vhs])
            }
            func at(_ r: [(String, [EffectKind])], _ i: Int?) -> EffectKind? {
                guard let i else { return nil }
                let all = r.flatMap(\.1)
                return all.indices.contains(i) ? all[i] : nil
            }
            func sec(_ r: [(String, [EffectKind])], _ i: Int) -> String? {
                var i = i
                for s in r { if i < s.1.count { return s.0 }; i -= s.1.count }
                return nil
            }
            var bad: [String] = []
            // 空のとき：下の分類の行で星を入れる（上のお気に入りの行が増える）・外す（減る）
            for (fBefore, fAfter, k) in [([EffectKind.echo], [EffectKind.echo, .mirror], EffectKind.mirror),
                                         ([.echo, .mirror], [.echo], .mirror), ([], [.tunnel], .tunnel)] {
                let b = rows("", fBefore), a = rows("", fAfter)
                let all = b.flatMap(\.1)
                guard let i = all.lastIndex(of: k) else { bad.append("\(k.rawValue) が無い"); continue }
                let j = EffectPicker.reselect(i, before: b, after: a)
                if at(a, j) != k || j.flatMap({ sec(a, $0) }) != sec(b, i) { bad.append("空・\(k.rawValue)") }
            }
            // お気に入りの行で星を外す：その区分は消えるので、同じ種類の最初の行へ
            do {
                let b = rows("", [.echo, .mirror]), a = rows("", [.echo])
                let j = EffectPicker.reselect(1, before: b, after: a)
                if at(b, 1) != .mirror || at(a, j) != .mirror { bad.append("お気に入りの行で外す") }
            }
            // 検索中：星を入れると先頭へ動く
            do {
                let b = rows("e", []), a = rows("e", [.tunnel])
                let i = b.flatMap(\.1).firstIndex(of: .tunnel) ?? -1
                let j = EffectPicker.reselect(i, before: b, after: a)
                if i <= 0 || at(a, j) != .tunnel || j == i { bad.append("検索中") }
            }
            check(bad.isEmpty, "ピッカー：星を押して並びが変わっても、選んでいる種類（同じ区分の行）のまま" + (bad.isEmpty ? "" : "（だめ：\(bad.joined(separator: "、"))）"))
        }
    }
}
