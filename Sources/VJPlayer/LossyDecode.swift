import Foundation

// エフェクトの並びを「読めない要素だけ飛ばして」読む。
// 新しい版で足したエフェクト（知らない種類）が 1 つ混ざっていても、ほかのエフェクトや、
// 保存した中身の全体（クリップ・レイヤー・コンポジション・シーン・FX パッドなど）は読めるように。
// 書く形は今までと同じ（ただの [Effect]）。
// KeyedDecodingContainer に [Effect] 専用の decode を足すと、自動で作られる読み方（Codable）もこちらを使う。

/// 1 つ分の包み：読めなければ nil（並びを読む途中で止まらないように、ここでは投げない）
private struct LossyEffect: Decodable {
    let effect: Effect?
    init(from decoder: Decoder) throws {
        do {
            effect = try Effect(from: decoder)
        } catch {
            effect = nil
            NSLog("VJPlayer: 読めないエフェクトを飛ばしました \(error)")
        }
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: [Effect].Type, forKey key: Key) throws -> [Effect] {
        try decode([LossyEffect].self, forKey: key).compactMap(\.effect)
    }

    func decodeIfPresent(_ type: [Effect].Type, forKey key: Key) throws -> [Effect]? {
        try decodeIfPresent([LossyEffect].self, forKey: key)?.compactMap(\.effect)
    }
}
