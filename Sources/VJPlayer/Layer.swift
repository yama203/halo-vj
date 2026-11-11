import Foundation
import QuartzCore

/// レイヤーの重ね方
/// クリップの切り替え方（新しいクリップが、どう現れるか）
enum Transition: Int, CaseIterable, Codable, Identifiable {
    case crossfade, wipe, circle, noise, luma, glitch
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .crossfade: L("クロス")
        case .wipe: L("ワイプ")
        case .circle: L("円")
        case .noise: L("ノイズ")
        case .luma: L("明るさ")
        case .glitch: L("グリッチ")
        }
    }
    var help: String {
        switch self {
        case .crossfade: L("だんだん重ねて入れ替わる")
        case .wipe: L("左から右へ、ふちをぼかして拭き取るように")
        case .circle: L("真ん中から円が広がって")
        case .noise: L("ノイズの模様で、ところどころから溶けるように")
        case .luma: L("新しいクリップの明るい所から順に現れる")
        case .glitch: L("ブロックが乱れながら、ばらばらに入れ替わる")
        }
    }
}

enum BlendMode: Int, CaseIterable, Codable, Identifiable {
    case normal, add, screen, multiply
    /// 特殊合成：下の絵を読んで、シェーダーで混ぜる（設定はレイヤーの blendFX）
    case overdrive
    /// マスク：このレイヤーの明るさで、下に重ねた絵を見せる（白 = 見える、黒 = 隠す）／反転（白い所を隠す）
    case maskLuma, maskInvert
    /// 下の絵を読んで混ぜる、値の無い重ね方
    case difference, overlay, softLight, colorDodge, hueOnly, lumOnly
    /// 絡み合う重ね方（下の絵を読んで、このレイヤーで下の絵そのものを変える。値は blendFX）
    case refract, light, flowInto, interfere, borrowColor, dissolve

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .normal: L("通常")
        case .add: L("加算")
        case .screen: L("スクリーン")
        case .multiply: L("乗算")
        case .overdrive: L("オーバードライブ加算")
        case .maskLuma: L("マスク（白で見せる）")
        case .maskInvert: L("マスク（白で隠す）")
        case .difference: L("差分")
        case .overlay: L("オーバーレイ")
        case .softLight: L("ソフトライト")
        case .colorDodge: L("覆い焼き")
        case .hueOnly: L("色相だけ")
        case .lumOnly: L("明るさだけ")
        case .refract: L("屈折")
        case .light: L("光で照らす")
        case .flowInto: L("流し込む")
        case .interfere: L("干渉")
        case .borrowColor: L("色を借りる")
        case .dissolve: L("溶け込む")
        }
    }

    /// レイヤー欄のボタン用の短い名前
    var shortLabel: String {
        switch self {
        case .overdrive: L("OD加算")
        case .maskLuma: L("マスク")
        case .maskInvert: L("反転マスク")
        case .softLight: L("ソフト")
        case .colorDodge: L("覆い焼き")
        case .light: L("照らす")
        default: label
        }
    }

    /// マスクとして使う重ね方か（このレイヤー自体は見えず、下の絵を見せる・隠す）
    var isMask: Bool { self == .maskLuma || self == .maskInvert }

    /// 値のある特殊合成か（下の絵を読む。値は blendFX）
    var isSpecial: Bool { effectKind != nil }
    /// 下の絵を読んで、シェーダーで混ぜる重ね方か（特殊合成と、差分・オーバーレイなど）
    var readsBelow: Bool { isSpecial || Self.simpleBelow.contains(self) }
    static let simpleBelow: [BlendMode] = [.difference, .overlay, .softLight, .colorDodge, .hueOnly, .lumOnly]
    /// 絡み合う重ね方（オーバードライブ以外の特殊合成）
    static let entangle: [BlendMode] = [.refract, .light, .flowInto, .interfere, .borrowColor, .dissolve]
    /// 特殊合成の値の種類
    var effectKind: EffectKind? {
        switch self {
        case .overdrive: .overdrive
        case .refract: .blendRefract
        case .light: .blendLight
        case .flowInto: .blendFlow
        case .interfere: .blendInterfere
        case .borrowColor: .blendBorrow
        case .dissolve: .blendDissolve
        default: nil
        }
    }
}

/// 時間で 0〜1 の値をなめらかに動かす（フェード用）。描画スレッドからも読む値型。
struct Fade {
    var from: Float = 1
    var to: Float = 1
    var start: CFTimeInterval = 0
    var duration: Double = 0

    /// 現在値 `from` から `to` へ動かす（duration は 0→1 全体にかかる時間。途中からなら残りの分だけ）
    static func toward(_ to: Float, from current: Float, fullDuration: Double, now: CFTimeInterval) -> Fade {
        Fade(from: current, to: to, start: now, duration: fullDuration * Double(abs(to - current)))
    }

    func value(at t: CFTimeInterval) -> Float {
        guard duration > 0 else { return to }
        let p = Float(min(max((t - start) / duration, 0), 1))
        return from + (to - from) * p
    }

    func isDone(at t: CFTimeInterval) -> Bool { duration <= 0 || t >= start + duration }
}

/// レイヤー・コンポジション用のトランスフォーム（位置・スケール・角度）。
/// 出力の中心を基準に、中身全体を動かす。
final class TransformParams: ObservableObject, Animatable {
    /// 位置。出力の幅・高さに対する割合で、0 = 中央。X は右、Y は上が +
    @Published var posX = 0.0 { didSet { onChanged?() } }
    @Published var posY = 0.0 { didSet { onChanged?() } }
    @Published var scale = 1.0 { didSet { onChanged?() } }
    /// 角度（度、時計回りが +）
    @Published var rotation = 0.0 { didSet { onChanged?() } }

    /// アニメーション（位置・スケール・角度）
    @Published var anims: [ParamKey: ParamAnim] = [:] { didSet { onChanged?() } }
    var animOrigin: Double { 0 }

    var onChanged: (() -> Void)?

    /// 描画用（アニメーション込み）
    var animValue: AnimTransform {
        AnimTransform(x: posX, y: posY, scale: scale, rotation: rotation, anims: anims)
    }

    var isDefault: Bool { posX == 0 && posY == 0 && scale == 1 && rotation == 0 && !anims.values.contains { $0.isOn } }

    func reset() {
        posX = 0; posY = 0; scale = 1; rotation = 0
        anims = [:]
    }

    func set(x: Double?, y: Double?, scale s: Double?, rotation r: Double?) {
        posX = x ?? 0; posY = y ?? 0; scale = s ?? 1; rotation = r ?? 0
    }
}

/// 1つのレイヤー（クリップグリッドの1段）。段数は自由に増減できる。
/// 段ごとに1クリップずつ同時に再生でき、上の段ほど手前に重なる。
final class Layer: ObservableObject, Identifiable, Animatable, EffectHolder {
    let id: UUID
    /// 上から何段目か（0 = 一番上 = 一番手前）。レイヤーを足したり消したりすると変わる
    @Published var index: Int
    var name: String { "L\(index + 1)" }
    /// 付けた名前（「背景」など。空なら無し）。番号 L1 などはそのまま目印として使う
    @Published var title = "" { didSet { if oldValue != title { onChanged?() } } }
    /// 表示用：「L1 背景」（名前が無ければ「L1」）
    var displayName: String { title.isEmpty ? name : name + " " + title }

    @Published var opacity: Double = 1 { didSet { onChanged?() } }
    @Published var blend: BlendMode = .normal {
        didSet {
            // 特殊合成を変えたら、値もその種類のものにする（前の値は種類が違うので使えない）
            if let k = blend.effectKind, blendFX.kind != k { blendFX = Effect(kind: k) }
            onChanged?()
        }
    }
    @Published var volume: Double = 1 {
        didSet {
            onVolumeChanged?()
            onChanged?()
        }
    }
    /// 音だけのミュート（映像は出る）
    @Published var audioMuted = false {
        didSet {
            guard oldValue != audioMuted else { return }
            onVolumeChanged?()
            onChanged?()
        }
    }
    /// 調整レイヤー：このレイヤーのエフェクトを、下のレイヤーを重ねた絵全体にかける（クリップは使わない）
    @Published var isAdjustment = false {
        didSet {
            guard oldValue != isAdjustment else { return }
            onVolumeChanged?()
            onChanged?()
        }
    }
    /// 音を出すか（ミュート・音だけのミュート・調整レイヤーでは出さない）
    var audible: Bool { !muted && !audioMuted && !isAdjustment && !soloHidden }

    /// ソロ：ソロのレイヤーだけを出す（確認用。保存しない）
    @Published var solo = false { didSet { if oldValue != solo { onSoloChanged?() } } }
    /// ほかのレイヤーがソロなので、一時的に隠れている（Engine が入れる）
    @Published var soloHidden = false
    var onSoloChanged: (() -> Void)?
    /// ミュート：再生は続けたまま、このレイヤーの映像と音を出さない
    @Published var muted = false {
        didSet {
            guard oldValue != muted else { return }
            onVolumeChanged?()
            onChanged?()
        }
    }

    /// クリップを切り替えるときのクロスフェード時間（秒）。0 ならカット
    @Published var fadeTime: Double = 0 { didSet { onChanged?() } }
    /// クリップを切り替えるときの切り替え方（クロスフェード・ワイプ など）
    @Published var transition: Transition = .crossfade { didSet { onChanged?() } }

    let transform = TransformParams()
    /// 特殊合成（オーバードライブ加算など）の値。重ね方が特殊合成のときに使う
    @Published var blendFX = Effect(kind: .overdrive) { didSet { onChanged?() } }
    /// レイヤーのエフェクト（このレイヤーのクリップを重ねた絵にかかる）
    @Published var effects: [Effect] = [] { didSet { onChanged?() } }
    /// 不透明度のアニメーション
    @Published var anims: [ParamKey: ParamAnim] = [:] { didSet { onChanged?() } }
    var animOrigin: Double { 0 }

    /// 保存対象の設定が変わった
    var onChanged: (() -> Void)? {
        didSet { transform.onChanged = onChanged }
    }
    var onVolumeChanged: (() -> Void)?

    init(index: Int, id: UUID = UUID()) {
        self.index = index
        self.id = id
    }
}
