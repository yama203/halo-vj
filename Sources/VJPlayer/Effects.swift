import Foundation
import QuartzCore

// エフェクト。クリップ・レイヤー・コンポジションそれぞれに、上から順にかかる。
// 色や形を変えるもの（ミラー・カラーライズ・レベル・ポスタライズ）はシェーダーで 1 つずつ処理する。
// ポスタライズ時間はコマを間引くもので、そのエフェクトを持つ段（クリップ／レイヤー／コンポジション）の
// 出力を、指定したフレームレートでしか更新しない（並び順には関係なく、その段全体にかかる）。

enum EffectKind: String, Codable, CaseIterable, Identifiable {
    case mirror, colorize, levels, posterize, posterizeTime, strobe, echo, shapeMask, polyMask
    /// 特殊合成（レイヤーの重ね方）の値。エフェクト一覧には出さない
    case overdrive
    var id: String { rawValue }

    /// 重ね方の値か（エフェクトとしては並べない）
    var isBlend: Bool { self == .overdrive }

    var label: String {
        switch self {
        case .mirror: "ミラー"
        case .colorize: "カラーライズ"
        case .levels: "レベル"
        case .posterize: "ポスタライズ"
        case .posterizeTime: "ポスタライズ時間"
        case .strobe: "ストロボ"
        case .echo: "エコー（残像）"
        case .shapeMask: "マスク（形）"
        case .polyMask: "マスク（自由な形）"
        case .overdrive: "オーバードライブ加算"
        }
    }

    /// 一覧での分類（エフェクトを足すときはここに入れる）
    var category: EffectCategory {
        switch self {
        case .mirror: .shape
        case .colorize, .levels, .posterize: .color
        case .posterizeTime, .strobe, .echo: .time
        case .shapeMask, .polyMask: .mask
        case .overdrive: .blend
        }
    }

    var icon: String {
        switch self {
        case .mirror: "rectangle.split.2x1"
        case .colorize: "paintpalette"
        case .levels: "slider.horizontal.3"
        case .posterize: "square.grid.3x3.square"
        case .posterizeTime: "timer"
        case .strobe: "bolt.fill"
        case .echo: "square.stack.3d.forward.dottedline"
        case .shapeMask: "circle.dashed.inset.filled"
        case .polyMask: "skew"
        case .overdrive: "sun.max"
        }
    }

    /// ストロボの「間隔」の選択肢（拍）
    static let strobeBeats: [Double] = [0.0625, 0.125, 0.25, 0.5, 1, 2, 4]

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
        case .strobe: 4
        case .echo: 5
        case .shapeMask: 6
        case .polyMask: 7
        case .posterizeTime, .overdrive: -1
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
                            format: { $0 < 1.5 ? "なし" : String(format: "%.0f px（1080p）", $0) }),
            ]
        case .overdrive:
            // 加算して 100% を超えた分（あふれ）をどう見せるか
            return [
                EffectParam(label: "にじみ", range: 0...3, defaultValue: 1, perPoint: 0.005, format: EffectParam.percent),
                EffectParam(label: "にじみの広がり", range: 2...120, defaultValue: 28, perPoint: 0.2,
                            format: { String(format: "%.0f px（1080p）", $0) }),
                EffectParam(label: "色相ずれ", range: 0...360, defaultValue: 60, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: "波紋", range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: "波紋の細かさ", range: 1...80, defaultValue: 24, perPoint: 0.1,
                            format: { String(format: "%.0f", $0) }),
                EffectParam(label: "白飛びの抑え", range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: "波紋の速さ", range: 0...8, defaultValue: 1.5, perPoint: 0.01,
                            format: { String(format: "%.2f /秒", $0) }),
                EffectParam(label: "波紋の広がり", range: 40...800, defaultValue: 300, perPoint: 1,
                            format: { String(format: "%.0f px（1080p）", $0) }),
            ]
        case .shapeMask:
            // 四角・丸で切り抜く。位置・大きさは絵の幅・高さに対する割合
            return [
                EffectParam(label: "形", range: 0...1, defaultValue: 0, choices: ["四角", "丸"]),
                EffectParam(label: "反転（中を隠す）", range: 0...1, defaultValue: 0, isToggle: true),
                EffectParam(label: "位置 X", range: -1...1, defaultValue: 0, perPoint: 0.002,
                            format: { String(format: "%+.1f%%", $0 * 100) }, animRange: -0.3...0.3),
                EffectParam(label: "位置 Y", range: -1...1, defaultValue: 0, perPoint: 0.002,
                            format: { String(format: "%+.1f%%", $0 * 100) }, animRange: -0.3...0.3),
                EffectParam(label: "幅", range: 0...2, defaultValue: 0.6, perPoint: 0.002, format: EffectParam.percent,
                            animRange: 0.2...0.8),
                EffectParam(label: "高さ", range: 0...2, defaultValue: 0.6, perPoint: 0.002, format: EffectParam.percent,
                            animRange: 0.2...0.8),
                EffectParam(label: "角度", range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: "ぼかし", range: 0...0.5, defaultValue: 0.02, perPoint: 0.0005,
                            format: { String(format: "%.1f%%", $0 * 100) }),
            ]
        case .polyMask:
            // 点を結んだ形で切り抜く。点はプレビューの上で編集する（Effect.points）
            return [
                EffectParam(label: "ぼかし", range: 0...0.3, defaultValue: 0.005, perPoint: 0.0005,
                            format: { String(format: "%.1f%%", $0 * 100) }),
                EffectParam(label: "反転（中を隠す）", range: 0...1, defaultValue: 0, isToggle: true),
            ]
        case .echo:
            // 前の絵を少しずつ薄めながら残して、今の絵と重ねる（フィードバック）
            return [
                EffectParam(label: "重ね方", range: 0...2, defaultValue: 0, choices: ["明るい方", "加算", "混ぜる"]),
                EffectParam(label: "残る長さ", range: 0.05...10, defaultValue: 1, perPoint: 0.01,
                            format: { String(format: "%.2f 秒", $0) }, animRange: 0.2...3),
                EffectParam(label: "広がり", range: -1...1, defaultValue: 0, perPoint: 0.002,
                            format: { $0 == 0 ? "なし" : String(format: "%+.0f%%", $0 * 100) }, animRange: -0.3...0.3),
                EffectParam(label: "色相ずれ", range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°/秒", $0) }, animRange: 0...360),
                EffectParam(label: "残像の濃さ", range: 0...1, defaultValue: 1, format: EffectParam.percent),
            ]
        case .strobe:
            // 光る／消える を BPM（拍）か 1 秒あたりの回数で繰り返す。光る色は下の「色」で選ぶ
            return [
                EffectParam(label: "光り方", range: 0...2, defaultValue: 0, choices: ["色で光る", "消える", "反転"]),
                EffectParam(label: "合わせるもの", range: 0...1, defaultValue: 0, choices: ["BPM", "秒"]),
                EffectParam(label: "間隔", range: 0...6, defaultValue: 3,
                            choices: Self.strobeBeats.map { ParamAnim.beatsLabel($0) }),
                EffectParam(label: "1 秒の回数", range: 0.5...30, defaultValue: 8, perPoint: 0.05,
                            format: { String(format: "%.1f 回", $0) }, animRange: 2...16),
                EffectParam(label: "光る長さ", range: 0.05...0.95, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: "強さ", range: 0...1, defaultValue: 1, format: EffectParam.percent),
                EffectParam(label: "残光（すっと消える）", range: 0...1, defaultValue: 0, format: EffectParam.percent),
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
        case .shapeMask: "四角・丸の形で切り抜く（外は透明）。位置や大きさを動かせる。反転すると中を隠す"
        case .polyMask: "プレビューの上で点を置いて描いた形で切り抜く。建物や物に合わせるのに"
        case .echo: "動いた跡が残像になって残る。レイヤーかコンポジションにかけると、位置や回転の動きも跡になる"
        case .strobe: "BPM か秒に合わせて点滅させる（色で光る・消える・反転）。残光を上げると光ったあとすっと消える"
        case .posterizeTime: "コマを間引いて、指定したフレームレートでしか動かないようにする（この段全体にかかる）"
        case .overdrive: "下のレイヤーに加算して 100% を超えた分を、にじみ（ハレーション）・色相ずれ・波紋に変える"
        }
    }
}

/// エフェクト一覧の分類
enum EffectCategory: Int, CaseIterable, Identifiable {
    case color, shape, mask, time, blend
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .color: "色"
        case .shape: "形"
        case .mask: "マスク"
        case .time: "時間"
        case .blend: "合成"
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

/// マスクの点（絵の左上が 0,0、右下が 1,1）
struct MaskPoint: Codable, Equatable, Hashable {
    var x: Double, y: Double
    /// 最初の形：真ん中の四角
    static let defaultShape = [MaskPoint(x: 0.25, y: 0.25), MaskPoint(x: 0.75, y: 0.25),
                               MaskPoint(x: 0.75, y: 0.75), MaskPoint(x: 0.25, y: 0.75)]
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
    /// 自由な形のマスクの点（絵の左上が 0,0、右下が 1,1）
    var points: [MaskPoint] = MaskPoint.defaultShape
    static let maxPoints = 32
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
        if kind == .strobe { color = .white }
    }

    /// ストロボの t の時点の光り具合（0 = 元の絵、1 = いっぱいに光る／消える）
    func strobeLevel(at t: Double, beat: BeatClock, origin: Double) -> Double {
        let phase: Double
        if value(1) < 0.5 {
            let i = min(max(Int(value(2)), 0), EffectKind.strobeBeats.count - 1)
            phase = beat.beat(at: t) / EffectKind.strobeBeats[i]
        } else {
            phase = (t - origin) * value(3, at: t, beat: beat, origin: origin)
        }
        let f = phase - floor(phase)
        let duty = value(4, at: t, beat: beat, origin: origin)
        guard f < duty else { return 0 }
        let decay = value(6, at: t, beat: beat, origin: origin)
        return value(5, at: t, beat: beat, origin: origin) * (1 - decay * f / duty)
    }

    enum CodingKeys: String, CodingKey { case id, kind, enabled, values, color, palette, anims, points }

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
        points = try c.decodeIfPresent([MaskPoint].self, forKey: .points) ?? MaskPoint.defaultShape
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
        // ストロボは光り具合を CPU で決めて渡す（a.x = 光り方、a.y = 光り具合）
        if kind == .strobe { v[1] = Float(strobeLevel(at: t, beat: beat, origin: origin)) }
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
    var spatial: [Effect] { effects.filter { $0.enabled && $0.kind != .posterizeTime && !$0.kind.isBlend } }
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
    /// 並べ替え：id のエフェクトを、今 index 番目にあるものの位置へ動かす
    func moveEffect(_ id: UUID, to index: Int) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(index, 0), effects.count - 1)
        guard i != j else { return }
        let e = effects.remove(at: i)
        effects.insert(e, at: j)
    }

    /// index 番目に新しいエフェクトを入れる（作ったものを返す）
    @discardableResult
    func insertEffect(_ kind: EffectKind, at index: Int) -> Effect {
        let e = Effect(kind: kind)
        effects.insert(e, at: min(max(index, 0), effects.count))
        return e
    }

    func moveEffect(_ id: UUID, by d: Int) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard effects.indices.contains(j) else { return }
        effects.swapAt(i, j)
    }
}
