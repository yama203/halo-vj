import Foundation

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

/// レイヤー・コンポジション用のトランスフォーム（位置・スケール・角度）。
/// 出力の中心を基準に、中身全体を動かす。
final class TransformParams: ObservableObject {
    /// 位置。出力の幅・高さに対する割合で、0 = 中央。X は右、Y は上が +
    @Published var posX = 0.0 { didSet { onChanged?() } }
    @Published var posY = 0.0 { didSet { onChanged?() } }
    @Published var scale = 1.0 { didSet { onChanged?() } }
    /// 角度（度、時計回りが +）
    @Published var rotation = 0.0 { didSet { onChanged?() } }

    var onChanged: (() -> Void)?

    var value: ClipTransform {
        ClipTransform(x: Float(posX), y: Float(posY), scale: Float(scale), rotation: Float(rotation * .pi / 180))
    }

    var isDefault: Bool { posX == 0 && posY == 0 && scale == 1 && rotation == 0 }

    func reset() {
        posX = 0; posY = 0; scale = 1; rotation = 0
    }

    func set(x: Double?, y: Double?, scale s: Double?, rotation r: Double?) {
        posX = x ?? 0; posY = y ?? 0; scale = s ?? 1; rotation = r ?? 0
    }
}

/// 1つのレイヤー（クリップグリッドの1段）。
/// 段ごとに1クリップずつ同時に再生でき、上の段ほど手前に重なる。
final class Layer: ObservableObject, Identifiable {
    let index: Int
    var id: Int { index }
    var name: String { "L\(index + 1)" }

    @Published var opacity: Double = 1 { didSet { onChanged?() } }
    @Published var blend: BlendMode = .normal { didSet { onChanged?() } }
    @Published var volume: Double = 1 {
        didSet {
            onVolumeChanged?()
            onChanged?()
        }
    }

    let transform = TransformParams()

    /// 保存対象の設定が変わった
    var onChanged: (() -> Void)? {
        didSet { transform.onChanged = onChanged }
    }
    var onVolumeChanged: (() -> Void)?

    init(index: Int) {
        self.index = index
    }
}
