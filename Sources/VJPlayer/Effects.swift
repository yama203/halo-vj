import Foundation
import QuartzCore

// エフェクト。クリップ・レイヤー・コンポジションそれぞれに、上から順にかかる。
// 色や形を変えるもの（ミラー・カラーライズ・レベル・ポスタライズ）はシェーダーで 1 つずつ処理する。
// ポスタライズ時間はコマを間引くもので、そのエフェクトを持つ段（クリップ／レイヤー／コンポジション）の
// 出力を、指定したフレームレートでしか更新しない（並び順には関係なく、その段全体にかかる）。

enum EffectKind: String, Codable, CaseIterable, Identifiable {
    case mirror, colorize, levels, posterize, posterizeTime
    var id: String { rawValue }

    var label: String {
        switch self {
        case .mirror: "ミラー"
        case .colorize: "カラーライズ"
        case .levels: "レベル"
        case .posterize: "ポスタライズ"
        case .posterizeTime: "ポスタライズ時間"
        }
    }

    /// 一覧での分類（エフェクトを足すときはここに入れる）
    var category: EffectCategory {
        switch self {
        case .mirror: .shape
        case .colorize, .levels, .posterize: .color
        case .posterizeTime: .time
        }
    }

    var icon: String {
        switch self {
        case .mirror: "rectangle.split.2x1"
        case .colorize: "paintpalette"
        case .levels: "slider.horizontal.3"
        case .posterize: "square.grid.3x3.square"
        case .posterizeTime: "timer"
        }
    }

    /// ドラッグで運ぶときの文字列
    var dragString: String { "vjeffect:" + rawValue }
    static func fromDragString(_ s: String) -> EffectKind? {
        guard s.hasPrefix("vjeffect:") else { return nil }
        return EffectKind(rawValue: String(s.dropFirst("vjeffect:".count)))
    }

    /// シェーダーでの番号（ポスタライズ時間はシェーダーを使わない）
    var shaderIndex: Int32 {
        switch self {
        case .mirror: 0
        case .colorize: 1
        case .levels: 2
        case .posterize: 3
        case .posterizeTime: -1
        }
    }

    var params: [EffectParam] {
        switch self {
        case .mirror:
            return [
                EffectParam(label: "左右", range: 0...2, defaultValue: 1, choices: ["なし", "左を右へ", "右を左へ"]),
                EffectParam(label: "上下", range: 0...2, defaultValue: 0, choices: ["なし", "上を下へ", "下を上へ"]),
            ]
        case .colorize:
            // Resolume の Colorize と同じ考え方：色 1 つで染める（Color）か、明るさをパレットの色に置き換える（Palette）
            return [
                EffectParam(label: "モード", range: 0...1, defaultValue: 0, choices: ["カラー", "パレット"]),
                EffectParam(label: "明るさを保つ", range: 0...1, defaultValue: 1, isToggle: true),
                EffectParam(label: "かかり具合", range: 0...1, defaultValue: 1, format: EffectParam.percent),
                EffectParam(label: "色相をずらす", range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
            ]
        case .levels:
            return [
                EffectParam(label: "入力 黒", range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: "入力 白", range: 0...1, defaultValue: 1, format: EffectParam.percent),
                EffectParam(label: "ガンマ", range: 0.1...5, defaultValue: 1, perPoint: 0.005, format: { String(format: "%.2f", $0) }),
                EffectParam(label: "出力 黒", range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: "出力 白", range: 0...1, defaultValue: 1, format: EffectParam.percent),
            ]
        case .posterize:
            return [
                EffectParam(label: "色の段数", range: 2...32, defaultValue: 4, perPoint: 0.05, step: 1,
                            format: { String(format: "%.0f 段", $0) }),
                EffectParam(label: "ディザ", range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: "ドット", range: 1...32, defaultValue: 1, perPoint: 0.05, step: 1,
                            format: { $0 < 1.5 ? "なし" : String(format: "%.0f px", $0) }),
            ]
        case .posterizeTime:
            return [
                EffectParam(label: "フレームレート", range: 1...60, defaultValue: 8, perPoint: 0.05, step: 1,
                            format: { String(format: "%.0f fps", $0) }),
            ]
        }
    }

    var help: String {
        switch self {
        case .mirror: "画面の半分を反対側に折り返す"
        case .colorize: "明るさをもとに、1 色で染める（カラー）か、パレットの色に置き換える（パレット）"
        case .levels: "黒と白の位置・ガンマで明るさとコントラストを整える"
        case .posterize: "色の段数を減らす。ディザとドットを足すと GIF アニメのような見た目に"
        case .posterizeTime: "コマを間引いて、指定したフレームレートでしか動かないようにする（この段全体にかかる）"
        }
    }
}

/// エフェクト一覧の分類
enum EffectCategory: Int, CaseIterable, Identifiable {
    case color, shape, time
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .color: "色"
        case .shape: "形"
        case .time: "時間"
        }
    }
}

/// エフェクトの 1 つの値
struct EffectParam {
    let label: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    var perPoint = 0.003
    /// 整数だけにする（段数など）
    var step: Double = 0
    /// 選択肢（ミラーの向きなど）。あれば数値ではなく選択肢で選ぶ
    var choices: [String]? = nil
    /// オン／オフ（0 / 1）
    var isToggle = false
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    /// アニメーションを付けたときの最初の範囲（無ければ値の範囲全体）
    var animRange: ClosedRange<Double>? = nil

    /// 動かせるか（選択肢・オン/オフは動かさない）
    var animatable: Bool { choices == nil && !isToggle }

    static let percent: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
}

/// 色（sRGB、0〜1）
struct RGB: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double

    var simd: SIMD4<Float> { SIMD4(Float(r), Float(g), Float(b), 1) }

    /// 色相（0〜1）・彩度・明るさから
    static func hsb(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        let i = floor(h * 6), f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)
}

/// パレットのひな形
struct PalettePreset: Identifiable {
    let name: String
    let colors: [RGB]
    var id: String { name }

    static func hex(_ v: UInt32) -> RGB {
        RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    static let all: [PalettePreset] = [
        PalettePreset(name: "白黒", colors: [.black, .white]),
        PalettePreset(name: "熱（サーモ）", colors: [hex(0x000000), hex(0x3B0F70), hex(0xB5367A), hex(0xFB8761), hex(0xFCFDBF)]),
        PalettePreset(name: "夕焼け", colors: [hex(0x1A0533), hex(0x7B1E5A), hex(0xE2563B), hex(0xF7B538), hex(0xFFF1C1)]),
        PalettePreset(name: "ネオン", colors: [hex(0x0B0033), hex(0x6A00FF), hex(0xFF00C8), hex(0x00F0FF)]),
        PalettePreset(name: "海", colors: [hex(0x001021), hex(0x00487C), hex(0x0496FF), hex(0xA9F0FF)]),
        PalettePreset(name: "セピア", colors: [hex(0x1E1208), hex(0x704A2B), hex(0xC9A27A), hex(0xF6E7D2)]),
        PalettePreset(name: "2 色（赤・青）", colors: [hex(0x0A1AFF), hex(0xFF1A3C)]),
    ]
}

/// 1 つのエフェクト
struct Effect: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: EffectKind
    var enabled = true
    var values: [Double]
    /// 色（カラーライズのカラーモードなど）
    var color = RGB.hsb(200.0 / 360, 0.7, 1)
    /// パレット（カラーライズのパレットモード。暗い所 → 明るい所の順）
    var palette: [RGB] = PalettePreset.all[1].colors
    static let maxPalette = 8
    /// 値のアニメーション（キーは値の番号）
    var anims: [String: ParamAnim] = [:]

    func anim(_ i: Int) -> ParamAnim {
        anims[String(i)] ?? ParamAnim(range: kind.params[i].animRange ?? kind.params[i].range)
    }

    mutating func setAnim(_ i: Int, _ a: ParamAnim) {
        var a = a
        if a.isOn && !(anims[String(i)]?.isOn ?? false) { a.start = CACurrentMediaTime() }
        anims[String(i)] = a
    }

    /// t の時点の値（アニメーション込み）
    func value(_ i: Int, at t: Double, beat: BeatClock, origin: Double) -> Double {
        let base = value(i)
        guard let a = anims[String(i)], a.isOn, kind.params.indices.contains(i) else { return base }
        let p = kind.params[i]
        var v = a.value(base: base, at: t, beat: beat, origin: origin)
        // 色相のように一周するものは範囲の外を回り込ませる
        if p.range == 0...360 { v = v.truncatingRemainder(dividingBy: 360); if v < 0 { v += 360 } }
        v = min(max(v, p.range.lowerBound), p.range.upperBound)
        if p.step > 0 { v = (v / p.step).rounded() * p.step }
        return v
    }

    init(kind: EffectKind) {
        self.kind = kind
        values = kind.params.map(\.defaultValue)
    }

    enum CodingKeys: String, CodingKey { case id, kind, enabled, values, color, palette, anims }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(EffectKind.self, forKey: .kind)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        values = try c.decodeIfPresent([Double].self, forKey: .values) ?? kind.params.map(\.defaultValue)
        if let col = try c.decodeIfPresent(RGB.self, forKey: .color) {
            color = col
        } else if kind == .colorize, values.count >= 3 {
            // 以前のカラーライズ（色相・彩度・かかり具合）を、色 1 つのカラーモードに直す
            color = RGB.hsb(values[0] / 360, values[1], 1)
            values = [0, 1, values[2]]
        }
        palette = try c.decodeIfPresent([RGB].self, forKey: .palette) ?? PalettePreset.all[1].colors
        anims = try c.decodeIfPresent([String: ParamAnim].self, forKey: .anims) ?? [:]
        // 値が足りない（あとから値が増えた）ときは初期値で埋める
        while values.count < kind.params.count { values.append(kind.params[values.count].defaultValue) }
    }

    func value(_ i: Int) -> Double {
        let ps = kind.params
        guard ps.indices.contains(i) else { return 0 }
        var v = values.indices.contains(i) ? values[i] : ps[i].defaultValue
        v = min(max(v, ps[i].range.lowerBound), ps[i].range.upperBound)
        if ps[i].step > 0 { v = (v / ps[i].step).rounded() * ps[i].step }
        return v
    }

    /// シェーダーに渡す 8 つの値（t の時点、アニメーション込み）
    func shaderValues(at t: Double, beat: BeatClock, origin: Double) -> (SIMD4<Float>, SIMD4<Float>) {
        var v = [Float](repeating: 0, count: 8)
        for i in kind.params.indices where i < 8 { v[i] = Float(value(i, at: t, beat: beat, origin: origin)) }
        return (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]))
    }
}

/// 1 つの段（クリップ／レイヤー／コンポジション）のエフェクトの並び（描画スレッドに渡す）
struct EffectStack {
    var effects: [Effect] = []
    /// アニメーション用：BPM の時計と、秒モードの基準時刻（クリップならトリガーした時刻）
    var beat = BeatClock()
    var origin = 0.0

    /// シェーダーで処理するもの（有効なものだけ、上から順）
    var spatial: [Effect] { effects.filter { $0.enabled && $0.kind != .posterizeTime } }
    /// ポスタライズ時間のフレームレート（無ければ nil。複数あれば一番低いもの）
    var posterizeFPS: Double? { posterizeFPS(at: CACurrentMediaTime()) }
    func posterizeFPS(at t: Double) -> Double? {
        effects.filter { $0.enabled && $0.kind == .posterizeTime }
            .map { $0.value(0, at: t, beat: beat, origin: origin) }.min()
    }
    var isEmpty: Bool { spatial.isEmpty && posterizeFPS == nil }

    /// ポスタライズ時間の「今のコマ番号」。同じ番号の間は前の絵を使い回す
    func tick(at t: Double) -> Int64? {
        posterizeFPS(at: t).map { Int64(floor(t * $0)) }
    }
}

/// エフェクトを持てるもの（クリップ・レイヤー・コンポジション）
protocol EffectHolder: AnyObject {
    var effects: [Effect] { get set }
}

extension EffectHolder {
    func addEffect(_ kind: EffectKind) { effects.append(Effect(kind: kind)) }
    func removeEffect(_ id: UUID) { effects.removeAll { $0.id == id } }
    func moveEffect(_ id: UUID, by d: Int) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard effects.indices.contains(j) else { return }
        effects.swapAt(i, j)
    }
}
