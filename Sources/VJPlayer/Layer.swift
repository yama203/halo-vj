import Foundation
import QuartzCore

/// レイヤーの重ね方
enum BlendMode: Int, CaseIterable, Codable, Identifiable {
    case normal, add, screen, multiply

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .normal: "通常"
        case .add: "加算"
        case .screen: "スクリーン"
        case .multiply: "乗算"
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
    let id = UUID()
    /// 上から何段目か（0 = 一番上 = 一番手前）。レイヤーを足したり消したりすると変わる
    @Published var index: Int
    var name: String { "L\(index + 1)" }

    @Published var opacity: Double = 1 { didSet { onChanged?() } }
    @Published var blend: BlendMode = .normal { didSet { onChanged?() } }
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
    var audible: Bool { !muted && !audioMuted && !isAdjustment }
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

    let transform = TransformParams()
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

    init(index: Int) {
        self.index = index
    }
}
