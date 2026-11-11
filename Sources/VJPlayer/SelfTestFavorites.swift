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
    }
}
