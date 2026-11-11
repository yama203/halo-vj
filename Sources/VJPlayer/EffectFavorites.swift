import Foundation

// エフェクト・ジェネレーターの「お気に入り」と「最近使った」。
// プロジェクトではなくアプリ共通（UserDefaults の effectFavorites・effectRecents に、種類の名前の配列で）。
// テスト・書き出しの起動や、VJ_STATE_PATH があるときは UserDefaults に触れない（メモリの中だけ）。

final class EffectFavorites: ObservableObject {
    static let shared = EffectFavorites.makeShared()

    static let favoritesKey = "effectFavorites"
    static let recentsKey = "effectRecents"
    /// 最近使ったを覚えておく数
    static let recentLimit = 8

    /// 保存先（nil なら保存しない＝メモリの中だけ）
    let defaults: UserDefaults?
    /// 入れた順
    @Published private(set) var favorites: [EffectKind] = []
    /// 新しい順
    @Published private(set) var recents: [EffectKind] = []

    // 保存する名前の並び。知らない名前（古い版・新しい版の種類）もここには残す
    private var favoriteNames: [String]
    private var recentNames: [String]

    /// defaults が nil のときは、favorites・recents（名前）を初めの中身にする（開発用の書き出し・テスト）
    init(defaults: UserDefaults?, favorites: [String] = [], recents: [String] = []) {
        self.defaults = defaults
        favoriteNames = defaults?.stringArray(forKey: Self.favoritesKey) ?? favorites
        recentNames = Array((defaults?.stringArray(forKey: Self.recentsKey) ?? recents).prefix(Self.recentLimit))
        refresh()
    }

    /// アプリで使うもの。開発用に VJ_FAVORITES・VJ_RECENTS（カンマ区切りの名前）で中身を入れられる（そのときも保存しない）
    private static func makeShared() -> EffectFavorites {
        let env = ProcessInfo.processInfo.environment
        let fav = env["VJ_FAVORITES"].map(names) ?? []
        let rec = env["VJ_RECENTS"].map(names) ?? []
        let keepOff = EffectPresets.isDevRun || env["VJ_STATE_PATH"] != nil
            || env["VJ_FAVORITES"] != nil || env["VJ_RECENTS"] != nil
        return EffectFavorites(defaults: keepOff ? nil : .standard, favorites: fav, recents: rec)
    }

    private static func names(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func isFavorite(_ k: EffectKind) -> Bool { favoriteNames.contains(k.rawValue) }

    /// お気に入りに入れる（入っていれば外す）
    func toggle(_ k: EffectKind) {
        if let i = favoriteNames.firstIndex(of: k.rawValue) {
            favoriteNames.remove(at: i)
        } else {
            favoriteNames.append(k.rawValue)
        }
        refresh()
        defaults?.set(favoriteNames, forKey: Self.favoritesKey)
    }

    /// 人が選んで置いたときに呼ぶ（先頭へ。多い分は古いものから捨てる）
    func note(_ k: EffectKind) {
        recentNames.removeAll { $0 == k.rawValue }
        recentNames.insert(k.rawValue, at: 0)
        if recentNames.count > Self.recentLimit { recentNames.removeLast(recentNames.count - Self.recentLimit) }
        refresh()
        defaults?.set(recentNames, forKey: Self.recentsKey)
    }

    /// 保存する名前の並び（テスト用。知らない名前も入っている）
    var storedNames: (favorites: [String], recents: [String]) { (favoriteNames, recentNames) }

    private func refresh() {
        // 知らない名前は黙って飛ばす（同じ名前が 2 つあっても 1 つに）
        func kinds(_ names: [String]) -> [EffectKind] {
            var out: [EffectKind] = []
            for n in names { if let k = EffectKind(rawValue: n), !out.contains(k) { out.append(k) } }
            return out
        }
        let f = kinds(favoriteNames), r = kinds(recentNames)
        if f != favorites { favorites = f }
        if r != recents { recents = r }
    }
}

extension EffectKind {
    /// 「エフェクト」パネル・ピッカーのエフェクトの一覧に出るもの（重ね方・切り替えのマスク・ジェネレーターは出さない）
    var inEffectList: Bool { !isBlend && !isGenerator && self != .transitionMask }
}
