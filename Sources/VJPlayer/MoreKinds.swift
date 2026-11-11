import Foundation

// 追加のエフェクト・ジェネレーターの名前・印・値・説明・分類（Effects.swift の switch から呼ぶ）

extension EffectKind {
    static let moreEffects: [EffectKind] = [.bloom, .kaleidoscope, .rgbSplit, .pixelate, .edgeNeon, .zoomBlur,
                                            .pixelSort, .datamosh, .ascii, .dither, .voronoiGlass]
    static let moreGenerators: [EffectKind] = [.reactionDiffusion, .laser, .synthwave, .logoParticles, .metaballs,
                                               .starfield, .fractal, .ripples, .lightning, .growth,
                                               .plasma, .aurora, .nebula, .truchet, .hexGrid, .codeRain, .wireframe, .moire]
    var isMore: Bool { Self.moreEffects.contains(self) || Self.moreGenerators.contains(self) }

    var moreLabel: String? {
        switch self {
        case .bloom: L("光のにじみ（ブルーム）")
        case .kaleidoscope: L("万華鏡")
        case .rgbSplit: L("色ずれ（RGB ずらし）")
        case .pixelate: L("モザイク・網点")
        case .edgeNeon: L("輪郭ネオン")
        case .zoomBlur: L("ズームぼかし")
        case .pixelSort: L("ピクセルソート")
        case .datamosh: L("データモッシュ風")
        case .ascii: L("文字モザイク（ASCII）")
        case .dither: L("ディザ（1 ビット・ゲーム機風）")
        case .voronoiGlass: L("ガラス片")
        case .reactionDiffusion: L("反応拡散（育つ模様）")
        case .laser: L("レーザーショー")
        case .synthwave: L("シンセウェイブの地形")
        case .logoParticles: L("ロゴを粒に")
        case .metaballs: L("メタボール（ラバランプ）")
        case .starfield: L("星空ワープ")
        case .fractal: L("フラクタル")
        case .ripples: L("水面の波紋")
        case .lightning: L("稲妻・放電")
        case .growth: L("育つ線（回路・枝）")
        case .plasma: L("プラズマ")
        case .aurora: L("オーロラ")
        case .nebula: L("星雲・煙")
        case .truchet: L("トルシェ模様（つながる曲線）")
        case .hexGrid: L("六角のタイル")
        case .codeRain: L("文字の雨")
        case .wireframe: L("回るワイヤーフレーム")
        case .moire: L("モアレ（干渉する輪）")
        default: nil
        }
    }

    var moreIcon: String? {
        switch self {
        case .bloom: "sun.max.fill"
        case .kaleidoscope: "hexagon"
        case .rgbSplit: "square.3.layers.3d.down.right"
        case .pixelate: "square.grid.4x3.fill"
        case .edgeNeon: "scribble.variable"
        case .zoomBlur: "scope"
        case .pixelSort: "arrow.down.right.and.arrow.up.left.rectangle"
        case .datamosh: "rectangle.dashed.and.paperclip"
        case .ascii: "character"
        case .dither: "circle.grid.cross"
        case .voronoiGlass: "seal"
        case .reactionDiffusion: "allergens"
        case .laser: "rays"
        case .synthwave: "mountain.2"
        case .logoParticles: "sparkles.rectangle.stack"
        case .metaballs: "drop.circle"
        case .starfield: "star.circle"
        case .fractal: "snowflake"
        case .ripples: "water.waves.and.arrow.down"
        case .lightning: "bolt.horizontal"
        case .growth: "point.3.connected.trianglepath.dotted"
        case .plasma: "waveform.circle"
        case .aurora: "wind"
        case .nebula: "cloud"
        case .truchet: "square.grid.3x3.topleft.filled"
        case .hexGrid: "hexagon.fill"
        case .codeRain: "text.line.first.and.arrowtriangle.forward"
        case .wireframe: "cube.transparent"
        case .moire: "circle.hexagongrid"
        default: nil
        }
    }

    var moreCategory: EffectCategory? {
        switch self {
        case .bloom, .edgeNeon, .zoomBlur: .light
        case .kaleidoscope, .voronoiGlass: .shape
        case .rgbSplit, .pixelate, .pixelSort, .datamosh, .ascii, .dither: .glitch
        case _ where Self.moreGenerators.contains(self): .generator
        default: nil
        }
    }

    var moreGeneratorCategory: GeneratorCategory? {
        switch self {
        case .reactionDiffusion, .fractal, .growth: .pattern
        case .metaballs: .shape
        case .laser, .synthwave, .starfield, .ripples, .lightning: .space
        case .logoParticles: .text
        case .plasma, .truchet, .hexGrid, .moire: .pattern
        case .aurora, .nebula: .space
        case .codeRain: .text
        case .wireframe: .shape
        default: nil
        }
    }

    /// 前のコマを覚える・自分で描くもの（描き方は drawLife）
    var isMoreDrawn: Bool { isMore }

    var moreParams: [EffectParam]? {
        let pc = EffectParam.percent
        func px(_ v: Double) -> String { String(format: L("%.1f px（1080p）"), v) }
        func deg(_ v: Double) -> String { String(format: "%.0f°", v) }
        func degs(_ v: Double) -> String { String(format: L("%+.0f°/秒"), v) }
        switch self {
        // ===== エフェクト =====
        case .bloom:
            return [
                EffectParam(label: L("しきい値"), range: 0...1, defaultValue: 0.6, format: pc, animRange: 0.3...0.9),
                EffectParam(label: L("やわらかさ"), range: 0...0.5, defaultValue: 0.2, format: pc),
                EffectParam(label: L("強さ"), range: 0...4, defaultValue: 1.2, perPoint: 0.005, format: pc, animRange: 0.5...2.5),
                EffectParam(label: L("色み（下の色）"), range: 0...1, defaultValue: 0, format: pc),
                EffectParam(label: L("元の絵"), range: 0...1.5, defaultValue: 1, format: pc),
                EffectParam(label: L("広がり"), range: 0...1, defaultValue: 0.5, format: pc),
            ]
        case .kaleidoscope:
            return [
                EffectParam(label: L("枚数"), range: 2...16, defaultValue: 6, perPoint: 0.03, step: 1, format: { String(format: L("%.0f 枚"), $0) }),
                EffectParam(label: L("回る速さ"), range: -180...180, defaultValue: 12, perPoint: 0.5, format: degs, animRange: -45...45),
                EffectParam(label: L("角度"), range: 0...360, defaultValue: 0, perPoint: 0.5, format: deg),
                EffectParam(label: L("中心の左右"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("中心の上下"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("ズーム"), range: 0.2...4, defaultValue: 1, perPoint: 0.004, format: { String(format: "%.2fx", $0) }, animRange: 0.7...1.6),
                EffectParam(label: L("取る所のずれ"), range: -1...1, defaultValue: 0.15, perPoint: 0.003, format: { String(format: "%+.2f", $0) }),
                EffectParam(label: L("鏡にする（つなぎ目を消す）"), range: 0...1, defaultValue: 1, isToggle: true),
                EffectParam(label: L("取る所の角度"), range: 0...360, defaultValue: 0, perPoint: 0.5, format: deg),
                EffectParam(label: L("取る所が回る速さ"), range: -90...90, defaultValue: 0, perPoint: 0.3, format: degs),
            ]
        case .rgbSplit:
            return [
                EffectParam(label: L("ずれ"), range: 0...120, defaultValue: 14, perPoint: 0.1, format: px, animRange: 0...40),
                EffectParam(label: L("角度"), range: 0...360, defaultValue: 0, perPoint: 0.5, format: deg),
                EffectParam(label: L("形"), range: 0...2, defaultValue: 0, choices: [L("まっすぐ"), L("放射"), L("揺れる")]),
                EffectParam(label: L("揺れ"), range: 0...1, defaultValue: 0.3, format: pc),
                EffectParam(label: L("揺れる速さ"), range: 0...4, defaultValue: 1, perPoint: 0.005),
            ]
        case .pixelate:
            return [
                EffectParam(label: L("形"), range: 0...3, defaultValue: 0, choices: [L("四角"), L("丸い点"), L("網点"), L("横線")]),
                EffectParam(label: L("大きさ"), range: 2...160, defaultValue: 18, perPoint: 0.15, format: px, animRange: 6...60),
                EffectParam(label: L("角度"), range: 0...90, defaultValue: 0, perPoint: 0.3, format: deg),
                EffectParam(label: L("点の大きさ"), range: 0.1...1.5, defaultValue: 0.9, format: pc),
                EffectParam(label: L("すき間を透明に"), range: 0...1, defaultValue: 0, isToggle: true),
            ]
        case .edgeNeon:
            return [
                EffectParam(label: L("強さ"), range: 0...4, defaultValue: 1.5, perPoint: 0.005, format: pc, animRange: 0.5...3),
                EffectParam(label: L("太さ"), range: 0.5...8, defaultValue: 1.5, perPoint: 0.02, format: px),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 0, choices: [L("元の色"), L("1 色"), L("虹色")]),
                EffectParam(label: L("元の絵"), range: 0...1, defaultValue: 0.15, format: pc),
                EffectParam(label: L("光の広がり"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("しきい値"), range: 0...1, defaultValue: 0.1, format: pc),
            ]
        case .zoomBlur:
            return [
                EffectParam(label: L("強さ"), range: 0...1, defaultValue: 0.35, format: pc, animRange: 0...0.7),
                EffectParam(label: L("中心の左右"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("中心の上下"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("回るぼかし"), range: -1...1, defaultValue: 0, perPoint: 0.003, format: { String(format: "%+.2f", $0) }),
                EffectParam(label: L("なめらかさ"), range: 8...48, defaultValue: 24, perPoint: 0.1, step: 1, format: { String(format: "%.0f", $0) }),
            ]
        case .pixelSort:
            return [
                EffectParam(label: L("下のしきい値（明るさ）"), range: 0...1, defaultValue: 0.25, format: pc),
                EffectParam(label: L("上のしきい値（明るさ）"), range: 0...1, defaultValue: 0.85, format: pc),
                EffectParam(label: L("流れる長さ"), range: 4...800, defaultValue: 300, perPoint: 1, step: 1,
                            format: { String(format: L("%.0f px（1080p）"), $0) }, animRange: 60...600),
                EffectParam(label: L("向き"), range: 0...1, defaultValue: 1, choices: [L("横"), L("縦")]),
                EffectParam(label: L("逆（明るい方が先）"), range: 0...1, defaultValue: 0, isToggle: true),
                EffectParam(label: L("細かさ"), range: 0...2, defaultValue: 1, choices: [L("細かい"), L("ふつう"), L("粗い（軽い）")]),
            ]
        case .datamosh:
            return [
                EffectParam(label: L("かたまり"), range: 8...64, defaultValue: 16, perPoint: 0.1, step: 1, format: { String(format: "%.0f px", $0) }),
                EffectParam(label: L("動きの強さ"), range: 0...4, defaultValue: 1.5, perPoint: 0.005, format: pc),
                EffectParam(label: L("今の絵を混ぜる"), range: 0...1, defaultValue: 0.06, format: pc),
                EffectParam(label: L("色にじみ"), range: 0...1, defaultValue: 0.3, format: pc),
                EffectParam(label: L("拍で元に戻す"), range: 0...1, defaultValue: 1, isToggle: true),
                EffectParam(label: L("何拍ごと"), range: 1...32, defaultValue: 8, perPoint: 0.05, step: 1, format: { String(format: L("%.0f 拍"), $0) }),
            ]
        case .ascii:
            return [
                EffectParam(label: L("字の大きさ"), range: 6...60, defaultValue: 16, perPoint: 0.05, format: px, animRange: 10...30),
                EffectParam(label: L("字"), range: 0...3, defaultValue: 0, choices: [L("記号"), L("ブロック"), L("0 と 1"), L("カタカナ")]),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 0, choices: [L("元の色"), L("1 色"), L("緑の画面")]),
                EffectParam(label: L("コントラスト"), range: 0.2...3, defaultValue: 1.3, perPoint: 0.005, format: pc),
                EffectParam(label: L("背景"), range: 0...1, defaultValue: 0, format: pc),
            ]
        case .dither:
            return [
                EffectParam(label: L("色の数"), range: 2...8, defaultValue: 2, perPoint: 0.03, step: 1, format: { String(format: L("%.0f 色"), $0) }),
                EffectParam(label: L("色の組"), range: 0...4, defaultValue: 0, choices: [L("白黒"), L("ゲーム機の緑"), L("4 色の昔のパソコン"), L("元の色を減らす"), L("パレット")]),
                EffectParam(label: L("点の大きさ"), range: 1...12, defaultValue: 3, perPoint: 0.03, format: px),
                EffectParam(label: L("並び"), range: 0...1, defaultValue: 0, choices: [L("規則正しく"), L("ざらざら")]),
                EffectParam(label: L("コントラスト"), range: 0.3...3, defaultValue: 1.2, perPoint: 0.005, format: pc),
            ]
        case .voronoiGlass:
            return [
                EffectParam(label: L("片の数"), range: 4...400, defaultValue: 40, perPoint: 0.3, format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("ずれ"), range: 0...1, defaultValue: 0.35, format: pc, animRange: 0...0.8),
                EffectParam(label: L("動く速さ"), range: 0...3, defaultValue: 0.4, perPoint: 0.004),
                EffectParam(label: L("縁の線"), range: 0...1, defaultValue: 0.3, format: pc),
                EffectParam(label: L("屈折"), range: 0...1, defaultValue: 0.4, format: pc),
                EffectParam(label: L("色ずれ"), range: 0...1, defaultValue: 0.3, format: pc),
                EffectParam(label: L("縁の明るさ"), range: 0...1, defaultValue: 0.9, format: pc),
            ]
        // ===== ジェネレーター =====
        case .reactionDiffusion:
            return [
                EffectParam(label: L("模様"), range: 0...4, defaultValue: 0, choices: [L("珊瑚"), L("迷路"), L("斑点"), L("指紋"), L("分裂")]),
                EffectParam(label: L("育つ速さ"), range: 1...40, defaultValue: 12, perPoint: 0.1, step: 1, format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("模様の大きさ"), range: 1...6, defaultValue: 2.5, perPoint: 0.01, format: { String(format: "%.1f", $0) }),
                EffectParam(label: L("音で乱す（アタック・低音）"), range: 0...1, defaultValue: 0.6, format: pc),
                EffectParam(label: L("色の付け方"), range: 0...1, defaultValue: 1, choices: [L("1 色"), L("パレット")]),
                EffectParam(label: L("明るさ"), range: 0...2, defaultValue: 1, format: pc),
                EffectParam(label: L("種のまき方"), range: 0...2, defaultValue: 1, choices: [L("真ん中"), L("ばらばら"), L("帯")]),
                EffectParam(label: L("変わり続ける"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("音で光る"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("流れ（渦に乗って動く）"), range: 0...1, defaultValue: 0.5, format: pc, animRange: 0.2...0.9),
                EffectParam(label: L("枯れる（育っては死ぬ）"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("寿命"), range: 1...30, defaultValue: 6, perPoint: 0.05, format: { String(format: L("%.1f 秒"), $0) }),
                EffectParam(label: L("穴が開く速さ（変わり続ける）"), range: 0.3...10, defaultValue: 3, perPoint: 0.02, format: { String(format: L("%.1f 秒かけて"), $0) }),
            ]
        case .laser:
            return [
                EffectParam(label: L("本数"), range: 1...32, defaultValue: 8, perPoint: 0.05, step: 1, format: { String(format: L("%.0f 本"), $0) }),
                EffectParam(label: L("扇の広がり"), range: 0...180, defaultValue: 90, perPoint: 0.3, format: deg, animRange: 20...140),
                EffectParam(label: L("振れる速さ"), range: 0...4, defaultValue: 0.6, perPoint: 0.004),
                EffectParam(label: L("回る速さ"), range: -180...180, defaultValue: 0, perPoint: 0.5, format: degs),
                EffectParam(label: L("出る所"), range: 0...3, defaultValue: 0, choices: [L("下"), L("上"), L("真ん中"), L("左右")]),
                EffectParam(label: L("太さ"), range: 0.5...12, defaultValue: 2.5, perPoint: 0.02, format: px),
                EffectParam(label: L("もや"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("拍で点滅"), range: 0...1, defaultValue: 0, isToggle: true),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 0, choices: [L("1 色"), L("虹色"), L("パレット")]),
                EffectParam(label: L("明るさ"), range: 0...3, defaultValue: 1.2, perPoint: 0.005, format: pc),
                EffectParam(label: L("長さ"), range: 0.1...1.5, defaultValue: 1.2, perPoint: 0.003, format: pc),
            ]
        case .synthwave:
            return [
                EffectParam(label: L("速さ"), range: -4...4, defaultValue: 1, perPoint: 0.005, format: { String(format: "%+.2f", $0) }),
                EffectParam(label: L("山の高さ"), range: 0...1.5, defaultValue: 0.6, format: pc, animRange: 0.2...1),
                EffectParam(label: L("格子の細かさ"), range: 2...40, defaultValue: 12, perPoint: 0.05, format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("線の太さ"), range: 0.5...6, defaultValue: 1.5, perPoint: 0.02, format: px),
                EffectParam(label: L("太陽"), range: 0...1, defaultValue: 1, isToggle: true),
                EffectParam(label: L("視点の高さ"), range: 0.1...2, defaultValue: 0.6, perPoint: 0.003, format: pc),
                EffectParam(label: L("霧"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("うねり"), range: 0...1, defaultValue: 0.2, format: pc),
                EffectParam(label: L("色の付け方"), range: 0...1, defaultValue: 0, choices: [L("パレット"), L("1 色")]),
            ]
        case .logoParticles:
            return [
                EffectParam(label: L("粒の数"), range: 500...30000, defaultValue: 8000, perPoint: 20, step: 1, format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("粒の大きさ"), range: 0.5...10, defaultValue: 2.5, perPoint: 0.02, format: px),
                EffectParam(label: L("散らす"), range: 0...1, defaultValue: 0, format: pc, animRange: 0...0.8),
                EffectParam(label: L("戻る速さ"), range: 0...4, defaultValue: 1.5, perPoint: 0.005),
                EffectParam(label: L("ゆらぎ"), range: 0...1, defaultValue: 0.15, format: pc),
                EffectParam(label: L("大きさ"), range: 0.2...1.5, defaultValue: 1.0, format: pc),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 0, choices: [L("元の色"), L("1 色"), L("パレット")]),
                EffectParam(label: L("光"), range: 0...1, defaultValue: 0.4, format: pc),
                EffectParam(label: L("散り方"), range: 0...2, defaultValue: 0, choices: [L("爆発"), L("風"), L("渦")]),
            ]
        case .metaballs:
            return [
                EffectParam(label: L("数"), range: 2...16, defaultValue: 7, perPoint: 0.03, step: 1, format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("大きさ"), range: 0.05...0.5, defaultValue: 0.18, format: pc),
                EffectParam(label: L("速さ"), range: 0...3, defaultValue: 0.5, perPoint: 0.004),
                EffectParam(label: L("くっつき"), range: 0.2...3, defaultValue: 1, perPoint: 0.005, format: pc),
                EffectParam(label: L("縁の光"), range: 0...1, defaultValue: 0.6, format: pc),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 1, choices: [L("1 色"), L("パレット"), L("虹色")]),
                EffectParam(label: L("中の明るさ"), range: 0...1, defaultValue: 0.6, format: pc),
                EffectParam(label: L("ぼかし"), range: 0...1, defaultValue: 0.1, format: pc),
            ]
        case .starfield:
            return [
                EffectParam(label: L("星の数"), range: 0.2...4, defaultValue: 1, perPoint: 0.005, format: pc),
                EffectParam(label: L("速さ"), range: -4...8, defaultValue: 1.5, perPoint: 0.005, format: { String(format: "%+.2f", $0) }, animRange: 0.5...4),
                EffectParam(label: L("筋の長さ"), range: 0...1, defaultValue: 0.4, format: pc),
                EffectParam(label: L("中心の左右"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("中心の上下"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("回る速さ"), range: -90...90, defaultValue: 0, perPoint: 0.3, format: degs),
                EffectParam(label: L("色の付け方"), range: 0...3, defaultValue: 0, choices: [L("白"), L("虹色"), L("パレット"), L("1 色")]),
                EffectParam(label: L("星の大きさ"), range: 0.5...4, defaultValue: 1.2, perPoint: 0.005, format: pc),
                EffectParam(label: L("奥の暗さ"), range: 0...1, defaultValue: 0.5, format: pc),
            ]
        case .fractal:
            return [
                EffectParam(label: L("種類"), range: 0...2, defaultValue: 0, choices: [L("マンデルブロ"), L("ジュリア"), L("バーニングシップ")]),
                EffectParam(label: L("潜る速さ"), range: 0...1, defaultValue: 0.25, format: pc),
                EffectParam(label: L("回る速さ"), range: -45...45, defaultValue: 3, perPoint: 0.2, format: degs),
                EffectParam(label: L("細かさ"), range: 32...512, defaultValue: 160, perPoint: 0.5, step: 1, format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("色の回り"), range: 0...4, defaultValue: 1, perPoint: 0.005, format: pc),
                EffectParam(label: L("色の流れ"), range: -2...2, defaultValue: 0.2, perPoint: 0.005, format: { String(format: "%+.2f", $0) }),
                EffectParam(label: L("ジュリアの形"), range: 0...1, defaultValue: 0.35, format: pc),
                EffectParam(label: L("ジュリアが変わる速さ"), range: 0...1, defaultValue: 0.05, format: pc),
                EffectParam(label: L("色の付け方"), range: 0...1, defaultValue: 0, choices: [L("パレット"), L("虹色")]),
                EffectParam(label: L("潜る場所"), range: 0...2, defaultValue: 0, choices: [L("渦"), L("谷"), L("螺旋")]),
            ]
        case .ripples:
            return [
                EffectParam(label: L("落ちる数"), range: 0...8, defaultValue: 0.6, perPoint: 0.01, format: { String(format: L("%.1f /秒"), $0) }),
                EffectParam(label: L("拍で落とす"), range: 0...1, defaultValue: 1, isToggle: true),
                EffectParam(label: L("波の速さ"), range: 0.05...1, defaultValue: 0.25, format: pc),
                EffectParam(label: L("波の細かさ"), range: 4...80, defaultValue: 30, perPoint: 0.1, format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("消えていく速さ"), range: 0.2...4, defaultValue: 1.2, perPoint: 0.005),
                EffectParam(label: L("光"), range: 0...2, defaultValue: 1, format: pc),
                EffectParam(label: L("色の付け方"), range: 0...1, defaultValue: 0, choices: [L("1 色"), L("パレット")]),
                EffectParam(label: L("水の濃さ"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("音（アタック）で落とす"), range: 0...1, defaultValue: 0, format: pc),
            ]
        case .lightning:
            return [
                EffectParam(label: L("頻度"), range: 0...10, defaultValue: 1, perPoint: 0.01, format: { String(format: L("%.1f /秒"), $0) }),
                EffectParam(label: L("拍で走らせる"), range: 0...1, defaultValue: 1, isToggle: true),
                EffectParam(label: L("枝分かれ"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("ぎざぎざ"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("太さ"), range: 0.5...8, defaultValue: 2, perPoint: 0.02, format: px),
                EffectParam(label: L("光の広がり"), range: 0...1, defaultValue: 0.6, format: pc),
                EffectParam(label: L("向き"), range: 0...3, defaultValue: 0, choices: [L("上から下"), L("横"), L("真ん中から外"), L("どこでも")]),
                EffectParam(label: L("残る時間"), range: 0.05...1.5, defaultValue: 0.5, perPoint: 0.002, format: { String(format: L("%.2f 秒"), $0) }),
                EffectParam(label: L("色の付け方"), range: 0...1, defaultValue: 0, choices: [L("1 色"), L("パレット")]),
                EffectParam(label: L("音（アタック）で走らせる"), range: 0...1, defaultValue: 0, format: pc),
            ]
        case .growth:
            return [
                EffectParam(label: L("種類"), range: 0...2, defaultValue: 0, choices: [L("回路"), L("枝"), L("菌糸")]),
                EffectParam(label: L("数"), range: 1...60, defaultValue: 12, perPoint: 0.05, step: 1, format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("伸びる速さ"), range: 0.1...4, defaultValue: 1, perPoint: 0.004),
                EffectParam(label: L("枝分かれ"), range: 0...1, defaultValue: 0.3, format: pc),
                EffectParam(label: L("消えていく速さ"), range: 0...1, defaultValue: 0.15, format: pc),
                EffectParam(label: L("太さ"), range: 0.5...6, defaultValue: 1.5, perPoint: 0.02, format: px),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 1, choices: [L("1 色"), L("パレット"), L("虹色")]),
                EffectParam(label: L("光"), range: 0...1, defaultValue: 0.5, format: pc),
                EffectParam(label: L("曲がり"), range: 0...1, defaultValue: 0.5, format: pc),
            ]
        // ===== ジェネレーター（第 2 弾） =====
        case .plasma:
            return [
                EffectParam(label: L("大きさ"), range: 0.3...6, defaultValue: 1.5, perPoint: 0.01, format: { String(format: "%.2f", $0) }, animRange: 0.8...3),
                EffectParam(label: L("速さ"), range: 0...4, defaultValue: 1, perPoint: 0.005, animRange: 0.3...2),
                EffectParam(label: L("ゆがみ"), range: 0...1, defaultValue: 0.4, format: pc, animRange: 0...0.8),
                EffectParam(label: L("色の付け方"), range: 0...3, defaultValue: 0, choices: [L("虹色"), L("パレット"), L("パレットの帯"), L("白黒")]),
                EffectParam(label: L("色の回る速さ"), range: -2...2, defaultValue: 0.2, perPoint: 0.005, format: { String(format: "%+.2f", $0) }, animRange: -0.5...0.5),
                EffectParam(label: L("帯にする（段の数）"), range: 0...12, defaultValue: 0, perPoint: 0.05, step: 1,
                            format: { $0 < 0.5 ? L("なめらか") : String(format: L("%.0f 段"), $0) }, animRange: 0...8),
                EffectParam(label: L("コントラスト"), range: 0...1, defaultValue: 0.3, format: pc, animRange: 0...0.8),
            ]
        case .aurora:
            return [
                EffectParam(label: L("速さ"), range: 0...4, defaultValue: 0.6, perPoint: 0.005, animRange: 0.2...1.5),
                EffectParam(label: L("高さ（カーテンの長さ）"), range: 0.2...1, defaultValue: 0.6, format: pc, animRange: 0.3...0.9),
                EffectParam(label: L("うねり"), range: 0...1, defaultValue: 0.5, format: pc, animRange: 0.1...0.9),
                EffectParam(label: L("すじの細かさ"), range: 0...1, defaultValue: 0.5, format: pc, animRange: 0.2...0.8),
                EffectParam(label: L("カーテンの枚数"), range: 1...4, defaultValue: 3, perPoint: 0.03, step: 1, format: { String(format: L("%.0f 枚"), $0) }, animRange: 1...4),
                EffectParam(label: L("明るさ"), range: 0...3, defaultValue: 1.2, perPoint: 0.005, format: pc, animRange: 0.5...2),
                EffectParam(label: L("星を出す"), range: 0...1, defaultValue: 1, isToggle: true),
            ]
        case .nebula:
            return [
                EffectParam(label: L("大きさ"), range: 0.2...4, defaultValue: 1, perPoint: 0.005, format: { String(format: "%.2f", $0) }, animRange: 0.6...2),
                EffectParam(label: L("速さ"), range: 0...2, defaultValue: 0.3, perPoint: 0.003, animRange: 0.1...1),
                EffectParam(label: L("渦の強さ"), range: 0...2, defaultValue: 1, perPoint: 0.005, format: pc, animRange: 0.3...1.6),
                EffectParam(label: L("流れる向き"), range: 0...360, defaultValue: 90, perPoint: 0.5, format: deg, animRange: 0...360),
                EffectParam(label: L("流れる速さ"), range: 0...1, defaultValue: 0.08, format: pc, animRange: 0...0.4),
                EffectParam(label: L("濃さ（煙の量）"), range: 0...1, defaultValue: 0.45, format: pc, animRange: 0.3...0.8),
                EffectParam(label: L("コントラスト"), range: 0...1, defaultValue: 0.5, format: pc, animRange: 0.2...0.9),
                EffectParam(label: L("色の付け方"), range: 0...3, defaultValue: 0, choices: [L("パレット"), L("虹色"), L("炎"), L("氷")]),
                EffectParam(label: L("星を出す"), range: 0...1, defaultValue: 0, isToggle: true),
            ]
        case .truchet:
            return [
                EffectParam(label: L("マスの数（縦）"), range: 2...40, defaultValue: 10, perPoint: 0.05, step: 1, format: { String(format: "%.0f", $0) }, animRange: 4...20),
                EffectParam(label: L("形"), range: 0...2, defaultValue: 0, choices: [L("曲線"), L("斜め線"), L("三角")]),
                EffectParam(label: L("線の太さ"), range: 0.02...0.5, defaultValue: 0.12, format: pc, animRange: 0.04...0.3),
                EffectParam(label: L("向きを変える速さ"), range: 0...4, defaultValue: 0.3, perPoint: 0.005, animRange: 0...2),
                EffectParam(label: L("流れる向き"), range: 0...360, defaultValue: 0, perPoint: 0.5, format: deg, animRange: 0...360),
                EffectParam(label: L("流れる速さ"), range: 0...2, defaultValue: 0.1, perPoint: 0.003, format: { String(format: L("%.2f マス/秒"), $0) }, animRange: 0...0.8),
                EffectParam(label: L("光る"), range: 0...1, defaultValue: 0.4, format: pc, animRange: 0...1),
                EffectParam(label: L("塗り分ける"), range: 0...1, defaultValue: 0, isToggle: true),
            ]
        case .hexGrid:
            return [
                EffectParam(label: L("大きさ（縦に入る数）"), range: 3...60, defaultValue: 12, perPoint: 0.05, format: { String(format: "%.0f", $0) }, animRange: 6...24),
                EffectParam(label: L("すき間"), range: 0...0.5, defaultValue: 0.08, format: pc, animRange: 0.02...0.3),
                EffectParam(label: L("角の丸み"), range: 0...1, defaultValue: 0.15, format: pc, animRange: 0...1),
                EffectParam(label: L("光り方"), range: 0...3, defaultValue: 0, choices: [L("波"), L("ノイズ"), L("ランダム"), L("流れる")]),
                EffectParam(label: L("速さ"), range: 0...4, defaultValue: 1, perPoint: 0.005, animRange: 0.3...2.5),
                EffectParam(label: L("光る量"), range: 0...1, defaultValue: 0.5, format: pc, animRange: 0.2...0.9),
                EffectParam(label: L("ふち取りだけ"), range: 0...1, defaultValue: 0, isToggle: true),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 1, choices: [L("1 色"), L("パレット（明るさで混ぜる）"), L("虹色（マスごと）")]),
                EffectParam(label: L("回転"), range: 0...360, defaultValue: 0, perPoint: 0.5, format: deg, animRange: 0...60),
            ]
        case .codeRain:
            return [
                EffectParam(label: L("文字の大きさ（縦に入る行数）"), range: 10...120, defaultValue: 40, perPoint: 0.1, step: 1, format: { String(format: L("%.0f 行"), $0) }, animRange: 20...70),
                EffectParam(label: L("落ちる速さ"), range: 0...4, defaultValue: 1, perPoint: 0.005, animRange: 0.4...2.5),
                EffectParam(label: L("尾の長さ"), range: 0.05...1, defaultValue: 0.4, format: pc, animRange: 0.15...0.8),
                EffectParam(label: L("列の濃さ"), range: 0...1, defaultValue: 0.6, format: pc, animRange: 0.2...1),
                EffectParam(label: L("文字の変わる速さ"), range: 0...1, defaultValue: 0.3, format: pc, animRange: 0.1...0.8),
                EffectParam(label: L("先頭の白さ"), range: 0...1, defaultValue: 0.85, format: pc, animRange: 0.3...1),
                EffectParam(label: L("光る"), range: 0...1, defaultValue: 0.4, format: pc, animRange: 0...1),
                EffectParam(label: L("向き"), range: 0...3, defaultValue: 0, choices: [L("下へ流れる"), L("上へ流れる"), L("右へ流れる"), L("左へ流れる")]),
            ]
        case .wireframe:
            return [
                EffectParam(label: L("形"), range: 0...6, defaultValue: 0,
                            choices: [L("立方体"), L("正四面体"), L("正八面体"), L("正二十面体"), L("球"), L("トーラス"), L("ピラミッド")]),
                EffectParam(label: L("大きさ"), range: 0.1...1.5, defaultValue: 0.8, format: pc, animRange: 0.5...1.2),
                EffectParam(label: L("回る速さ X"), range: -180...180, defaultValue: 20, perPoint: 0.5, format: degs, animRange: -90...90),
                EffectParam(label: L("回る速さ Y"), range: -180...180, defaultValue: 35, perPoint: 0.5, format: degs, animRange: -90...90),
                EffectParam(label: L("回る速さ Z"), range: -180...180, defaultValue: 0, perPoint: 0.5, format: degs, animRange: -90...90),
                EffectParam(label: L("線の太さ"), range: 0.5...12, defaultValue: 2.5, perPoint: 0.02, format: px, animRange: 1...6),
                EffectParam(label: L("光る"), range: 0...1, defaultValue: 0.5, format: pc, animRange: 0...1),
                EffectParam(label: L("奥を暗く"), range: 0...1, defaultValue: 0.5, format: pc, animRange: 0...1),
                EffectParam(label: L("遠近"), range: 0...1, defaultValue: 0.5, format: pc, animRange: 0...1),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 0, choices: [L("1 色"), L("虹色（辺ごと）"), L("奥行きでパレット")]),
                EffectParam(label: L("数（入れ子）"), range: 1...5, defaultValue: 1, perPoint: 0.03, step: 1, format: { String(format: "%.0f", $0) }, animRange: 1...4),
            ]
        case .moire:
            return [
                EffectParam(label: L("形"), range: 0...3, defaultValue: 0, choices: [L("輪と輪"), L("線と線"), L("輪と線"), L("放射と放射")]),
                EffectParam(label: L("細かさ"), range: 5...200, defaultValue: 40, perPoint: 0.2, format: { String(format: "%.0f", $0) }, animRange: 30...120),
                EffectParam(label: L("中心の離れ"), range: 0...1, defaultValue: 0.3, format: pc, animRange: 0.05...0.6),
                EffectParam(label: L("回る速さ"), range: -90...90, defaultValue: 15, perPoint: 0.3, format: degs, animRange: -45...45),
                EffectParam(label: L("太さ（線と地の割合）"), range: 0.1...0.9, defaultValue: 0.5, format: pc, animRange: 0.2...0.8),
                EffectParam(label: L("組の数"), range: 2...3, defaultValue: 2, perPoint: 0.02, step: 1, format: { String(format: "%.0f", $0) }, animRange: 2...3),
                EffectParam(label: L("ふくらむ速さ"), range: -4...4, defaultValue: 0.5, perPoint: 0.005, format: { String(format: "%+.2f", $0) }, animRange: -2...2),
                EffectParam(label: L("重ね方"), range: 0...1, defaultValue: 0, choices: [L("重なりを消す（XOR）"), L("足す")]),
                EffectParam(label: L("やわらかさ"), range: 0...1, defaultValue: 0.2, format: pc, animRange: 0...0.8),
            ]
        default:
            return nil
        }
    }

    var moreHelp: String? {
        switch self {
        case .bloom: L("明るい所だけがふわっと光ってにじむ。しきい値より明るい所を取り出し、広くぼかして重ねる。色みを上げると、下の「色」の光になる")
        case .kaleidoscope: L("絵を扇形に切って、鏡のように並べて回す。枚数・回る速さ・ズーム・取る所のずれで模様が変わる")
        case .rgbSplit: L("赤・緑・青を少しずつずらす。まっすぐ・放射（真ん中から外へ）・揺れる（ときどき帯ごと大きくずれる）。拍や音で動かすと気持ちいい")
        case .pixelate: L("四角いモザイク、丸い点、印刷の網点（明るいほど大きな点）、横線（明るいほど太い線）")
        case .edgeNeon: L("絵の輪郭だけを取り出して、ネオン管のように光らせる。色は元の色・1 色・虹色")
        case .zoomBlur: L("中心から外へ流れるぼかし。スピード感。回るぼかしを足すと、渦を巻くように流れる")
        case .pixelSort: L("明るさがしきい値の間で続いている所（帯）ごとに、画素を明るさの順に並べ替えて、絵が縦や横に溶け流れる。流れる長さは、並べ替える帯のいちばん長いところ")
        case .datamosh: L("動画の圧縮が壊れたときのように、動いた向きに前の絵を引きずって、絵が崩れて混ざる。拍で元に戻すと、崩れてはパッと戻る")
        case .ascii: L("絵を文字に置き換える（明るい所ほど字が詰まる）。記号・ブロック・0 と 1・カタカナ")
        case .dither: L("色を 2〜8 色に減らして、点々で明るさを出す。白黒・昔のゲーム機の緑・4 色の昔のパソコン・元の色・パレット")
        case .voronoiGlass: L("細胞の形のガラス片に割れて、片ごとに少しずつずれる。縁の線を太くするとステンドグラス風")
        case .reactionDiffusion: L("2 つの薬が広がりながら反応して、珊瑚や迷路、斑点、指紋のような模様がじわじわ育つ。流れに乗って模様がずっと渦を巻いて動き、変わり続けるで場所ごとに育ち方が少しずつ変わって、ときどき消えてまた育つ。枯れるを上げると、育ってから寿命ほどたった所が暗くなって枯れ、空いた所へまたまわりから育って入ってくる（生まれては死ぬ波）。音のアタックで大きく乱れ、低音で速く育ち、音の大きさで光る（まわりは透明）")
        case .laser: L("ステージのレーザーのような光の線。扇形に振れたり回ったり。もやで光の筋が見える（まわりは透明）")
        case .synthwave: L("80 年代風。光る格子の地面とワイヤーフレームの山を飛んでいく。夕日付き。色はパレット")
        case .logoParticles: L("画像やロゴ（透明付きの PNG がおすすめ）か文字を、光の粒にする。散らすを上げると粒が散って、下げると元の形に戻る（音で動かすと、音で散る）")
        case .metaballs: L("溶けた球が、くっついたり離れたりしながら浮かぶ（ラバランプ）。まわりは透明")
        case .starfield: L("星が後ろへ流れていく宇宙の旅。速さを上げると筋になる（ハイパースペース）")
        case .fractal: L("マンデルブロ・ジュリア・バーニングシップ集合に、ゆっくり潜り続ける（深くなったら戻ってくり返す）")
        case .ripples: L("滴が落ちて、波紋が広がって重なる。拍で落とす・音で落とす・ときどき落とす")
        case .lightning: L("枝分かれする稲妻が走る。拍や音のアタックで走らせる。まわりは透明")
        case .growth: L("回路図・木の枝・菌糸のような線が、画面いっぱいに伸びていき、古い線はだんだん消える。まわりは透明")
        case .plasma: L("昔のデモのような、なめらかにうねる色の面。ゆがみで形が有機的になり、帯にすると色が段になる")
        case .aurora: L("夜空に垂れる光のカーテン。縦のすじが、ゆっくり横にうねる。色はパレット（下の色 → 上の色）。まわりは透明")
        case .nebula: L("ゆっくり湧いて渦を巻く煙・星雲。濃さで煙の量、渦の強さでうねり方が変わる。薄い所は透明")
        case .truchet: L("マスごとに向きの違う曲線がつながって、迷路のような模様になる。ときどきマスがくるっと回る。まわりは透明")
        case .hexGrid: L("蜂の巣のタイルが、波・ノイズ・ランダム・流れで 1 枚ずつ光る。消えているタイルは透明")
        case .codeRain: L("縦に流れ落ちる文字の列。先頭が明るく、尾が消えていく。まわりは透明")
        case .wireframe: L("立方体や二十面体などの辺だけを光る線で描いて、ゆっくり回す。入れ子にして重ねられる。まわりは透明")
        case .moire: L("少しずつずれた輪や線が重なって、干渉の模様（モアレ）が動く。まわりは透明")
        default: nil
        }
    }

    /// 「色」を出すか（値で決まる）
    func moreShowsColor(_ e: Effect) -> Bool {
        func c(_ i: Int) -> Int { Int(e.value(i).rounded()) }
        switch self {
        case .bloom: return e.value(3) > 0.001
        case .edgeNeon: return c(2) == 1
        case .ascii: return c(2) == 1
        case .reactionDiffusion: return c(4) == 0
        case .laser: return c(8) == 0
        case .synthwave: return c(8) == 1
        case .logoParticles: return c(6) == 1
        case .metaballs: return c(5) == 0
        case .starfield: return c(6) == 3
        case .ripples: return c(6) == 0
        case .lightning: return c(8) == 0
        case .growth: return c(6) == 0
        case .truchet: return true
        case .hexGrid: return c(7) == 0
        case .codeRain: return true
        case .wireframe: return c(9) == 0
        default: return false
        }
    }

    /// 「パレット」を出すか
    func moreShowsPalette(_ e: Effect) -> Bool {
        func c(_ i: Int) -> Int { Int(e.value(i).rounded()) }
        switch self {
        case .dither: return c(1) == 4
        case .reactionDiffusion: return c(4) == 1
        case .laser: return c(8) == 2
        case .synthwave: return c(8) == 0
        case .logoParticles: return c(6) == 2
        case .metaballs: return c(5) == 1
        case .starfield: return c(6) == 2
        case .fractal: return c(8) == 0
        case .ripples: return c(6) == 1
        case .lightning: return c(8) == 1
        case .growth: return c(6) == 1
        case .plasma: return c(3) == 1 || c(3) == 2
        case .aurora, .moire: return true
        case .nebula: return c(7) == 0
        case .truchet: return c(7) == 1
        case .hexGrid: return c(7) == 1
        case .wireframe: return c(9) == 2
        default: return false
        }
    }

    /// はじめの色・パレット
    var moreDefaultColor: RGB? {
        switch self {
        case .laser: RGB(r: 0.1, g: 1.0, b: 0.35)
        case .lightning: RGB(r: 0.75, g: 0.85, b: 1.0)
        case .ripples: RGB(r: 0.35, g: 0.75, b: 1.0)
        case .edgeNeon: RGB(r: 1.0, g: 0.2, b: 0.8)
        case .growth: RGB(r: 0.3, g: 1.0, b: 0.8)
        case .metaballs: RGB(r: 1.0, g: 0.45, b: 0.2)
        case .reactionDiffusion: RGB(r: 0.95, g: 0.95, b: 1.0)
        case .truchet: RGB(r: 0.25, g: 0.95, b: 1.0)
        case .hexGrid: RGB(r: 1.0, g: 0.7, b: 0.2)
        case .codeRain: RGB(r: 0.2, g: 1.0, b: 0.4)
        case .wireframe: RGB(r: 0.3, g: 0.9, b: 1.0)
        default: nil
        }
    }

    var moreDefaultPalette: [RGB]? {
        switch self {
        case .synthwave: [PalettePreset.hex(0xFF2BD6), PalettePreset.hex(0x7A2BFF), PalettePreset.hex(0x2BE3FF), PalettePreset.hex(0xFFB02B)]
        case .reactionDiffusion, .growth, .lightning: [PalettePreset.hex(0x0B3DFF), PalettePreset.hex(0x00F0FF), PalettePreset.hex(0xFFFFFF)]
        case .fractal: [PalettePreset.hex(0x0A0A2A), PalettePreset.hex(0x6A00FF), PalettePreset.hex(0xFF00C8), PalettePreset.hex(0xFFD400), PalettePreset.hex(0xFFFFFF)]
        case .metaballs: [PalettePreset.hex(0xFF3D00), PalettePreset.hex(0xFF00A8), PalettePreset.hex(0x7A00FF)]
        case .laser, .starfield, .ripples, .logoParticles, .dither:
            [PalettePreset.hex(0x00F0FF), PalettePreset.hex(0xFF00C8), PalettePreset.hex(0xFFE600)]
        case .plasma: [PalettePreset.hex(0x0B0033), PalettePreset.hex(0x6A00FF), PalettePreset.hex(0xFF00C8), PalettePreset.hex(0xFFD400)]
        case .aurora: [PalettePreset.hex(0x1CFF7A), PalettePreset.hex(0x9B30FF)]
        case .nebula: [PalettePreset.hex(0x1B1F8F), PalettePreset.hex(0xC2309A), PalettePreset.hex(0xFF7A9A), PalettePreset.hex(0x9FE8FF)]
        case .truchet: [PalettePreset.hex(0x3A0CA3), PalettePreset.hex(0xF72585)]
        case .hexGrid, .moire: [PalettePreset.hex(0x00F0FF), PalettePreset.hex(0xFF00C8)]
        case .wireframe: [PalettePreset.hex(0xFF00C8), PalettePreset.hex(0x00F0FF)]
        default: nil
        }
    }

    /// 「見た目」のひな形（押すと値をまとめてそろえる）
    var moreLooks: [GeneratorLook] {
        switch self {
        case .laser:
            return [
                GeneratorLook(name: L("クラブの緑"), help: L("下から緑の光が扇形にゆっくり振れる。もや多め"),
                              values: [0: 10, 1: 100, 2: 0.5, 3: 0, 4: 0, 5: 2, 6: 0.8, 7: 0, 8: 0], color: RGB(r: 0.1, g: 1, b: 0.35)),
                GeneratorLook(name: L("虹の扇"), help: L("たくさんの虹色の線が、速く振れる"),
                              values: [0: 24, 1: 150, 2: 1.5, 3: 0, 4: 0, 5: 1.5, 6: 0.4, 7: 0, 8: 1]),
                GeneratorLook(name: L("回る光"), help: L("真ん中から全方向に出て回る。拍で点滅"),
                              values: [0: 12, 2: 0.3, 3: 40, 4: 2, 5: 3, 6: 0.6, 7: 1, 8: 2]),
                GeneratorLook(name: L("左右から"), help: L("左右から交差する赤い光"),
                              values: [0: 6, 1: 60, 2: 0.8, 3: 0, 4: 3, 5: 2.5, 6: 0.5, 7: 0, 8: 0], color: RGB(r: 1, g: 0.1, b: 0.2)),
            ]
        case .synthwave:
            return [
                GeneratorLook(name: L("夕日"), help: L("大きな夕日と、ゆっくり進む格子"),
                              values: [0: 1, 1: 0.6, 2: 12, 4: 1, 5: 0.6, 6: 0.5, 7: 0.2]),
                GeneratorLook(name: L("高速"), help: L("低い所を速く飛ぶ。山は高め"),
                              values: [0: 3.5, 1: 1.0, 2: 16, 4: 1, 5: 0.25, 6: 0.35, 7: 0.4]),
                GeneratorLook(name: L("夜の平原"), help: L("太陽なし。平らな格子が遠くまで"),
                              values: [0: 0.6, 1: 0.15, 2: 8, 4: 0, 5: 0.9, 6: 0.7, 7: 0]),
            ]
        case .starfield:
            return [
                GeneratorLook(name: L("ゆっくり"), help: L("星がゆっくり流れる宇宙"),
                              values: [0: 1.2, 1: 0.4, 2: 0.05, 5: 2, 6: 0, 7: 1, 8: 0.6]),
                GeneratorLook(name: L("ハイパースペース"), help: L("長い光の筋になって飛ぶ"),
                              values: [0: 2, 1: 6, 2: 1, 5: 0, 6: 0, 7: 1.4, 8: 0.3]),
                GeneratorLook(name: L("虹のワープ"), help: L("虹色の星が回りながら流れる"),
                              values: [0: 1.5, 1: 2.5, 2: 0.5, 5: 20, 6: 1, 7: 1.5, 8: 0.4]),
            ]
        case .fractal:
            return [
                GeneratorLook(name: L("渦に潜る"), help: L("マンデルブロの渦にゆっくり潜る"),
                              values: [0: 0, 1: 0.25, 2: 3, 3: 200, 4: 1, 5: 0.2, 9: 0]),
                GeneratorLook(name: L("ジュリアの変形"), help: L("ジュリア集合が形を変え続ける"),
                              values: [0: 1, 1: 0.1, 2: 6, 3: 160, 4: 1.5, 5: 0.4, 6: 0.35, 7: 0.3]),
                GeneratorLook(name: L("燃える船"), help: L("バーニングシップ集合の、炎のような形"),
                              values: [0: 2, 1: 0.2, 2: 0, 3: 220, 4: 0.8, 5: 0.15]),
            ]
        case .metaballs:
            return [
                GeneratorLook(name: L("ラバランプ"), help: L("ゆっくり浮かぶ、橙から紫の溶けた球"),
                              values: [0: 6, 1: 0.2, 2: 0.3, 3: 1, 4: 0.5, 5: 1, 6: 0.7, 7: 0.15]),
                GeneratorLook(name: L("ネオンの縁"), help: L("中は暗く、縁だけが光る"),
                              values: [0: 9, 1: 0.15, 2: 0.6, 3: 1.2, 4: 1, 5: 2, 6: 0, 7: 0.05]),
            ]
        case .reactionDiffusion:
            return [
                GeneratorLook(name: L("珊瑚"), help: L("枝のように広がる珊瑚の模様"), values: [0: 0, 1: 12, 2: 2.5, 6: 0]),
                GeneratorLook(name: L("迷路"), help: L("細い迷路が画面を埋める"), values: [0: 1, 1: 20, 2: 2, 6: 1]),
                GeneratorLook(name: L("斑点"), help: L("動物の斑点のような丸"), values: [0: 2, 1: 16, 2: 3, 6: 1]),
            ]
        default:
            return []
        }
    }
}
