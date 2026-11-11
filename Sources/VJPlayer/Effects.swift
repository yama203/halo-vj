import Foundation
import QuartzCore

// エフェクト。クリップ・レイヤー・コンポジションそれぞれに、上から順にかかる。
// 色や形を変えるもの（ミラー・カラーライズ・レベル・ポスタライズ）はシェーダーで 1 つずつ処理する。
// ポスタライズ時間はコマを間引くもので、そのエフェクトを持つ段（クリップ／レイヤー／コンポジション）の
// 出力を、指定したフレームレートでしか更新しない（並び順には関係なく、その段全体にかかる）。

enum EffectKind: String, Codable, CaseIterable, Identifiable {
    case mirror, warp, fluid, colorize, levels, posterize, invert, posterizeTime, timeWarp, strobe, echo, shapeMask, polyMask
    /// 昔のアナログ映像機材をまねたもの
    case glitchBox, vhs, videoFeedback, rasterScan, crt
    /// 追加のエフェクト（MoreKinds.swift）
    case bloom, kaleidoscope, rgbSplit, pixelate, edgeNeon, zoomBlur, pixelSort, datamosh, ascii, dither, voronoiGlass
    /// ジェネレーター（動画の代わりにクリップとして置く絵）。エフェクト一覧には出さない
    case solid, gradient, stripes, grid, noise, shapes, text, clock, phyllotaxis, lines, dots, flow, school, tunnel, physarum, particleLife, fireflies, attractor, syphonIn, camera, audioScope, ndiIn
    /// 追加のジェネレーター（MoreKinds.swift）
    case reactionDiffusion, laser, synthwave, logoParticles, metaballs, starfield, fractal, ripples, lightning, growth
    /// 追加のジェネレーター 第 2 弾（MoreKinds.swift・MoreGenerators2.swift）
    case plasma, aurora, nebula, truchet, hexGrid, codeRain, wireframe, moire
    /// 特殊合成（レイヤーの重ね方）の値。エフェクト一覧には出さない
    /// 切り替えの形（レイヤーの切り替え方で、新しいクリップに内部でかける。一覧には出さない）
    case transitionMask
    case overdrive, blendRefract, blendLight, blendFlow, blendInterfere, blendBorrow, blendDissolve
    var id: String { rawValue }

    /// エフェクトの不透明度と同じ働きの値（以前の「かかり具合」）の番号。画面には出さない
    var amountIndex: Int? {
        switch self {
        case .colorize: 2
        case .invert: 1
        default: nil
        }
    }

    /// 重ね方の値か（エフェクトとしては並べない）
    var isBlend: Bool { [.overdrive, .blendRefract, .blendLight, .blendFlow, .blendInterfere, .blendBorrow, .blendDissolve].contains(self) }

    /// ジェネレーターか（クリップとして置く。エフェクトとしては並べない）
    var isGenerator: Bool { Self.generators.contains(self) }
    static let generators: [EffectKind] = [.solid, .gradient, .flow, .lines, .dots, .school, .tunnel, .physarum, .particleLife, .fireflies, .attractor, .audioScope, .reactionDiffusion, .metaballs, .fractal, .growth,
                                           .laser, .synthwave, .starfield, .ripples, .lightning, .logoParticles,
                                           .plasma, .aurora, .nebula, .truchet, .hexGrid, .codeRain, .wireframe, .moire,
                                           .syphonIn, .ndiIn, .camera, .stripes, .grid, .noise, .shapes, .phyllotaxis, .text, .clock]
    /// 文字を描くジェネレーター（テキスト・時計。描き方は同じ）
    var isText: Bool { self == .text || self == .clock }
    /// 色を 1 つ使うジェネレーター（「色」を出す）
    var usesColor: Bool { [.solid, .stripes, .grid, .noise, .shapes, .text, .clock, .phyllotaxis, .lines, .dots, .flow, .school, .tunnel, .physarum, .fireflies, .attractor, .rasterScan, .audioScope].contains(self) }
    /// 「速さ」の値の番号。シェーダーには速さ × 経過時間（動いた量）を渡す
    var speedIndex: Int? {
        switch self {
        case .gradient, .stripes, .grid, .lines: 3
        case .noise, .text, .clock: 2
        case .phyllotaxis: 6
        case .dots: 5
        case .flow, .tunnel: 0
        case .warp: 2
        default: nil
        }
    }

    var label: String {
        if let m = moreLabel { return m }
        return switch self {
        // 追加のもの（上で返している）
        case .bloom, .kaleidoscope, .rgbSplit, .pixelate, .edgeNeon, .zoomBlur, .pixelSort, .datamosh, .ascii, .dither, .voronoiGlass, .reactionDiffusion, .laser, .synthwave, .logoParticles, .metaballs, .starfield, .fractal, .ripples, .lightning, .growth: ""
        case .plasma, .aurora, .nebula, .truchet, .hexGrid, .codeRain, .wireframe, .moire: ""
        case .mirror: L("ミラー")
        case .colorize: L("カラーライズ")
        case .levels: L("レベル")
        case .posterize: L("ポスタライズ")
        case .invert: L("反転")
        case .posterizeTime: L("ポスタライズ時間")
        case .strobe: L("ストロボ")
        case .echo: L("エコー（残像）")
        case .shapeMask: L("マスク（形）")
        case .polyMask: L("マスク（自由な形）")
        case .solid: L("単色")
        case .gradient: L("グラデーション")
        case .stripes: L("ストライプ")
        case .grid: L("チェッカー・格子")
        case .noise: L("ノイズ")
        case .shapes: L("図形")
        case .text: L("テキスト")
        case .clock: L("時計・カウントダウン")
        case .phyllotaxis: L("フィロタキシス（ひまわり）")
        case .lines: L("ライン")
        case .dots: L("ドット（粒）")
        case .flow: L("光の流れ")
        case .school: L("群れ（魚・鳥）")
        case .tunnel: L("トンネル")
        case .syphonIn: L("Syphon から")
        case .camera: L("カメラから")
        case .ndiIn: L("NDI から")
        case .audioScope: L("音の形（スペクトラム・波形）")
        case .glitchBox: L("グリッチボックス")
        case .vhs: L("VHS テープ")
        case .videoFeedback: L("ビデオフィードバック")
        case .rasterScan: L("ラスタースキャン（Rutt/Etra 風）")
        case .crt: L("CRT モニター")
        case .physarum: L("粘菌（フィジャルム）")
        case .particleLife: L("パーティクル・ライフ")
        case .fireflies: L("ホタルの同期")
        case .attractor: L("ストレンジ・アトラクター")
        case .timeWarp: L("時間のずらし（スリットスキャン）")
        case .fluid: L("流体（絵の具を流す）")
        case .warp: L("うねり（有機的な歪み）")
        case .transitionMask: L("切り替えの形")
        case .overdrive: L("オーバードライブ加算")
        case .blendRefract: L("屈折（ガラス越し）")
        case .blendLight: L("光で照らす")
        case .blendFlow: L("流し込む")
        case .blendInterfere: L("干渉（モアレ）")
        case .blendBorrow: L("色を借りる")
        case .blendDissolve: L("明るさで溶け込む")
        }
    }

    /// 一覧での分類（エフェクトを足すときはここに入れる）
    var category: EffectCategory {
        if let m = moreCategory { return m }
        return switch self {
        // 追加のもの（上で返している）
        case .bloom, .kaleidoscope, .rgbSplit, .pixelate, .edgeNeon, .zoomBlur, .pixelSort, .datamosh, .ascii, .dither, .voronoiGlass, .reactionDiffusion, .laser, .synthwave, .logoParticles, .metaballs, .starfield, .fractal, .ripples, .lightning, .growth: .generator
        case .plasma, .aurora, .nebula, .truchet, .hexGrid, .codeRain, .wireframe, .moire: .generator
        case .mirror, .warp, .fluid: .shape
        case .colorize, .levels, .posterize, .invert: .color
        case .posterizeTime, .timeWarp, .strobe, .echo: .time
        case .glitchBox, .vhs, .videoFeedback, .rasterScan, .crt: .retro
        case .shapeMask, .polyMask: .mask
        case .solid, .gradient, .stripes, .grid, .noise, .shapes, .text, .clock, .phyllotaxis, .lines, .dots, .flow, .school, .tunnel, .physarum, .particleLife, .fireflies, .attractor, .syphonIn, .camera, .audioScope, .ndiIn: .generator
        case .overdrive, .blendRefract, .blendLight, .blendFlow, .blendInterfere, .blendBorrow, .blendDissolve, .transitionMask: .blend
        }
    }

    var icon: String {
        if let m = moreIcon { return m }
        return switch self {
        // 追加のもの（上で返している）
        case .bloom, .kaleidoscope, .rgbSplit, .pixelate, .edgeNeon, .zoomBlur, .pixelSort, .datamosh, .ascii, .dither, .voronoiGlass, .reactionDiffusion, .laser, .synthwave, .logoParticles, .metaballs, .starfield, .fractal, .ripples, .lightning, .growth: ""
        case .plasma, .aurora, .nebula, .truchet, .hexGrid, .codeRain, .wireframe, .moire: ""
        case .mirror: "rectangle.split.2x1"
        case .colorize: "paintpalette"
        case .levels: "slider.horizontal.3"
        case .posterize: "square.grid.3x3.square"
        case .invert: "circle.lefthalf.filled"
        case .posterizeTime: "timer"
        case .strobe: "bolt.fill"
        case .echo: "square.stack.3d.forward.dottedline"
        case .shapeMask: "circle.dashed.inset.filled"
        case .polyMask: "skew"
        case .solid: "square.fill"
        case .gradient: "square.bottomhalf.filled"
        case .stripes: "line.3.horizontal"
        case .grid: "checkerboard.rectangle"
        case .noise: "aqi.medium"
        case .shapes: "circle.circle"
        case .text: "textformat"
        case .clock: "clock"
        case .phyllotaxis: "sun.max.circle"
        case .lines: "line.3.horizontal.decrease"
        case .dots: "circle.grid.3x3.fill"
        case .flow: "wand.and.rays"
        case .school: "fish"
        case .tunnel: "circle.circle.fill"
        case .syphonIn: "rectangle.connected.to.line.below"
        case .camera: "video.fill"
        case .ndiIn: "network"
        case .audioScope: "waveform"
        case .glitchBox: "waveform.path.ecg"
        case .vhs: "recordingtape"
        case .videoFeedback: "rectangle.on.rectangle.angled"
        case .rasterScan: "water.waves"
        case .crt: "tv"
        case .physarum: "point.3.filled.connected.trianglepath.dotted"
        case .particleLife: "atom"
        case .fireflies: "sparkles"
        case .attractor: "tornado"
        case .timeWarp: "clock.arrow.2.circlepath"
        case .fluid: "drop.fill"
        case .warp: "water.waves"
        case .overdrive: "sun.max"
        case .transitionMask: "rectangle.righthalf.inset.filled"
        case .blendRefract: "drop.circle"
        case .blendLight: "flashlight.on.fill"
        case .blendFlow: "wind"
        case .blendInterfere: "water.waves.and.arrow.trianglehead.up"
        case .blendBorrow: "eyedropper"
        case .blendDissolve: "flame"
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
        if isMore { return -1 }
        return switch self {
        // 追加のもの（上で返している）
        case .bloom, .kaleidoscope, .rgbSplit, .pixelate, .edgeNeon, .zoomBlur, .pixelSort, .datamosh, .ascii, .dither, .voronoiGlass, .reactionDiffusion, .laser, .synthwave, .logoParticles, .metaballs, .starfield, .fractal, .ripples, .lightning, .growth: -1
        case .plasma, .aurora, .nebula, .truchet, .hexGrid, .codeRain, .wireframe, .moire: -1
        case .mirror: 0
        case .colorize: 1
        case .levels: 2
        case .posterize: 3
        case .strobe: 4
        case .echo: 5
        case .shapeMask: 6
        case .polyMask: 7
        case .solid: 8
        case .gradient: 9
        case .stripes: 10
        case .grid: 11
        case .noise: 12
        case .shapes: 13
        case .invert: 14
        case .text, .clock: 15
        case .phyllotaxis: 16
        case .lines: 17
        case .dots: 18
        case .flow: 19
        case .tunnel: 20
        case .warp: 21
        case .glitchBox, .vhs, .videoFeedback, .rasterScan, .crt, .syphonIn, .camera, .audioScope, .ndiIn: -1
        case .transitionMask: 22
        case .posterizeTime, .overdrive, .blendRefract, .blendLight, .blendFlow, .blendInterfere, .blendBorrow, .blendDissolve, .school, .physarum, .particleLife, .fireflies, .attractor, .timeWarp, .fluid: -1
        }
    }

    var params: [EffectParam] {
        if let m = moreParams { return m }
        switch self {
        // 追加のもの（上で返している）
        case .bloom, .kaleidoscope, .rgbSplit, .pixelate, .edgeNeon, .zoomBlur, .pixelSort, .datamosh, .ascii, .dither, .voronoiGlass, .reactionDiffusion, .laser, .synthwave, .logoParticles, .metaballs, .starfield, .fractal, .ripples, .lightning, .growth: return []
        case .plasma, .aurora, .nebula, .truchet, .hexGrid, .codeRain, .wireframe, .moire: return []
        case .mirror:
            return [
                EffectParam(label: L("左右"), range: 0...2, defaultValue: 1, choices: [L("なし"), L("左を右へ"), L("右を左へ")]),
                EffectParam(label: L("上下"), range: 0...2, defaultValue: 0, choices: [L("なし"), L("上を下へ"), L("下を上へ")]),
            ]
        case .colorize:
            // Resolume の Colorize と同じ考え方：色 1 つで染める（Color）か、明るさをパレットの色に置き換える（Palette）
            return [
                EffectParam(label: L("モード"), range: 0...1, defaultValue: 0, choices: [L("カラー"), L("パレット")]),
                EffectParam(label: L("明るさを保つ"), range: 0...1, defaultValue: 1, isToggle: true),
                EffectParam(label: L("かかり具合"), range: 0...1, defaultValue: 1, format: EffectParam.percent),
                EffectParam(label: L("色相をずらす"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
            ]
        case .levels:
            return [
                EffectParam(label: L("入力 黒"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: L("入力 白"), range: 0...1, defaultValue: 1, format: EffectParam.percent),
                EffectParam(label: L("ガンマ"), range: 0.1...5, defaultValue: 1, perPoint: 0.005, format: { String(format: "%.2f", $0) }),
                EffectParam(label: L("出力 黒"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: L("出力 白"), range: 0...1, defaultValue: 1, format: EffectParam.percent),
            ]
        case .invert:
            return [
                EffectParam(label: L("反転するもの"), range: 0...2, defaultValue: 0, choices: [L("色と明るさ"), L("明るさだけ"), L("色だけ")]),
                EffectParam(label: L("かかり具合"), range: 0...1, defaultValue: 1, format: EffectParam.percent),
            ]
        case .posterize:
            return [
                EffectParam(label: L("色の段数"), range: 2...32, defaultValue: 4, perPoint: 0.05, step: 1,
                            format: { String(format: L("%.0f 段"), $0) }),
                EffectParam(label: L("ディザ"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: L("ドット"), range: 1...32, defaultValue: 1, perPoint: 0.05, step: 1,
                            format: { $0 < 1.5 ? L("なし") : String(format: L("%.0f px（1080p）"), $0) }),
            ]
        case .blendRefract:
            return [
                EffectParam(label: L("曲げる強さ"), range: 0...300, defaultValue: 60, perPoint: 0.3,
                            format: { String(format: L("%.0f px（1080p）"), $0) }, animRange: 20...150),
                EffectParam(label: L("なめらかさ"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("色のずれ"), range: 0...1, defaultValue: 0.2, format: EffectParam.percent),
                EffectParam(label: L("ふちの光"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("上の絵も見せる"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
            ]
        case .blendLight:
            return [
                EffectParam(label: L("照らされない所の暗さ"), range: 0...1, defaultValue: 0.85, format: EffectParam.percent),
                EffectParam(label: L("光の広がり"), range: 0...400, defaultValue: 80, perPoint: 0.5,
                            format: { String(format: L("%.0f px（1080p）"), $0) }, animRange: 20...200),
                EffectParam(label: L("光の強さ"), range: 0...4, defaultValue: 1.5, perPoint: 0.005, format: EffectParam.percent,
                            animRange: 0.5...2.5),
                EffectParam(label: L("光の色を付ける"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("光そのものを見せる"), range: 0...1, defaultValue: 0.2, format: EffectParam.percent),
            ]
        case .blendFlow:
            return [
                EffectParam(label: L("かき混ぜる強さ"), range: 0...3, defaultValue: 1, perPoint: 0.005, format: EffectParam.percent),
                EffectParam(label: L("押し方"), range: 0...1, defaultValue: 0, choices: [L("動いた所"), L("明るい所のまわり")]),
                EffectParam(label: L("元に戻る速さ"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("渦"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("ねばり"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("上の絵も見せる"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
            ]
        case .blendInterfere:
            return [
                EffectParam(label: L("縞の細かさ"), range: 1...200, defaultValue: 30, perPoint: 0.2,
                            format: { String(format: "%.0f", $0) }, animRange: 10...80),
                EffectParam(label: L("流れる速さ"), range: -4...4, defaultValue: 0.5, perPoint: 0.005,
                            format: { String(format: L("%+.2f /秒"), $0) }),
                EffectParam(label: L("縞の濃さ"), range: 0...1, defaultValue: 0.8, format: EffectParam.percent),
                EffectParam(label: L("鋭さ"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("色"), range: 0...2, defaultValue: 0, choices: [L("下の色"), L("上の色"), L("虹色")]),
            ]
        case .blendBorrow:
            return [
                EffectParam(label: L("借り方"), range: 0...1, defaultValue: 0, choices: [L("同じ場所の色"), L("上の絵をパレットに")]),
                EffectParam(label: L("明るさのコントラスト"), range: 0...3, defaultValue: 1.2, perPoint: 0.005,
                            format: { String(format: "%.2f", $0) }),
                EffectParam(label: L("明るさでずらす"), range: 0...0.5, defaultValue: 0, perPoint: 0.001, format: EffectParam.percent,
                            animRange: 0...0.2),
                EffectParam(label: L("パレットにする行"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("元の色を残す"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
            ]
        case .blendDissolve:
            return [
                EffectParam(label: L("溶ける量"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("溶け方"), range: 0...3, defaultValue: 0, choices: [L("暗い所から"), L("明るい所から"), L("ノイズ"), L("上の明るさで")]),
                EffectParam(label: L("ふちのやわらかさ"), range: 0...0.5, defaultValue: 0.06, perPoint: 0.0005, format: EffectParam.percent),
                EffectParam(label: L("ふちの光"), range: 0...3, defaultValue: 1, perPoint: 0.005, format: EffectParam.percent),
                EffectParam(label: L("ふちの色相"), range: 0...360, defaultValue: 25, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("ノイズを混ぜる"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
            ]
        case .transitionMask:
            return [
                EffectParam(label: L("形"), range: 0...5, defaultValue: 0),
                EffectParam(label: L("進み具合"), range: 0...1, defaultValue: 0),
                EffectParam(label: L("ぼかし"), range: 0...0.5, defaultValue: 0.08),
                EffectParam(label: L("種"), range: 0...1000, defaultValue: 0),
            ]
        case .overdrive:
            // 加算して 100% を超えた分（あふれ）をどう見せるか
            return [
                EffectParam(label: L("にじみ"), range: 0...3, defaultValue: 1, perPoint: 0.005, format: EffectParam.percent),
                EffectParam(label: L("にじみの広がり"), range: 2...120, defaultValue: 28, perPoint: 0.2,
                            format: { String(format: L("%.0f px（1080p）"), $0) }),
                EffectParam(label: L("色相ずれ"), range: 0...360, defaultValue: 60, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("波紋"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("波紋の細かさ"), range: 1...80, defaultValue: 24, perPoint: 0.1,
                            format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("白飛びの抑え"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("波紋の速さ"), range: 0...8, defaultValue: 1.5, perPoint: 0.01,
                            format: { String(format: L("%.2f /秒"), $0) }),
                EffectParam(label: L("波紋の広がり"), range: 40...800, defaultValue: 300, perPoint: 1,
                            format: { String(format: L("%.0f px（1080p）"), $0) }),
            ]
        case .solid:
            return [EffectParam(label: L("明るさ"), range: 0...1, defaultValue: 1, format: EffectParam.percent)]
        case .gradient:
            // 色はパレット（左 → 右へ、端で折り返してつながる）
            return [
                EffectParam(label: L("形"), range: 0...2, defaultValue: 0, choices: [L("直線"), L("円"), L("回転")]),
                EffectParam(label: L("角度"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("繰り返し"), range: 0.25...8, defaultValue: 1, perPoint: 0.005,
                            format: { String(format: "%.2f", $0) }, animRange: 0.5...3),
                EffectParam(label: L("速さ"), range: -4...4, defaultValue: 0.2, perPoint: 0.005,
                            format: { String(format: L("%+.2f /秒"), $0) }, animRange: -1...1),
            ]
        case .stripes:
            return [
                EffectParam(label: L("本数"), range: 1...64, defaultValue: 8, perPoint: 0.05,
                            format: { String(format: "%.1f", $0) }, animRange: 4...16),
                EffectParam(label: L("太さ"), range: 0.02...0.98, defaultValue: 0.5, format: EffectParam.percent, animRange: 0.1...0.9),
                EffectParam(label: L("角度"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("速さ"), range: -4...4, defaultValue: 0.5, perPoint: 0.005,
                            format: { String(format: L("%+.2f /秒"), $0) }, animRange: -1...1),
                EffectParam(label: L("ぼかし"), range: 0...1, defaultValue: 0.03, format: EffectParam.percent),
            ]
        case .grid:
            return [
                EffectParam(label: L("模様"), range: 0...2, defaultValue: 0, choices: [L("チェッカー"), L("格子"), L("ドット")]),
                EffectParam(label: L("マスの数"), range: 1...64, defaultValue: 8, perPoint: 0.05,
                            format: { String(format: "%.1f", $0) }, animRange: 4...16),
                EffectParam(label: L("太さ"), range: 0.02...0.98, defaultValue: 0.15, format: EffectParam.percent, animRange: 0.1...0.9),
                EffectParam(label: L("速さ"), range: -4...4, defaultValue: 0, perPoint: 0.005,
                            format: { String(format: L("%+.2f /秒"), $0) }, animRange: -1...1),
            ]
        case .noise:
            return [
                EffectParam(label: L("種類"), range: 0...1, defaultValue: 0, choices: [L("なめらか"), L("砂嵐")]),
                EffectParam(label: L("細かさ"), range: 1...64, defaultValue: 6, perPoint: 0.05,
                            format: { String(format: "%.1f", $0) }, animRange: 2...16),
                EffectParam(label: L("速さ"), range: 0...10, defaultValue: 1, perPoint: 0.01,
                            format: { String(format: L("%.2f /秒"), $0) }, animRange: 0...4),
                EffectParam(label: L("コントラスト"), range: 0...4, defaultValue: 1.2, perPoint: 0.005,
                            format: { String(format: "%.2f", $0) }),
            ]
        case .shapes:
            return [
                EffectParam(label: L("形"), range: 0...4, defaultValue: 0, choices: [L("円"), L("リング"), L("四角"), L("枠"), L("三角")]),
                EffectParam(label: L("大きさ"), range: 0...2, defaultValue: 0.6, perPoint: 0.002, format: EffectParam.percent,
                            animRange: 0.2...1),
                EffectParam(label: L("線の太さ"), range: 0.005...0.5, defaultValue: 0.06, perPoint: 0.0005,
                            format: EffectParam.percent, animRange: 0.02...0.2),
                EffectParam(label: L("数（縦に並ぶ数）"), range: 1...12, defaultValue: 1, perPoint: 0.02, step: 1,
                            format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("角度"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("ぼかし"), range: 0...0.3, defaultValue: 0.005, perPoint: 0.0005,
                            format: EffectParam.percent),
            ]
        case .flow:
            // アブストラクトな光：やわらかい光の帯がゆったりうねり、ふちが虹色ににじむ。粒子感（フィルムのざらつき）付き
            return [
                EffectParam(label: L("速さ"), range: 0...3, defaultValue: 0.15, perPoint: 0.002,
                            format: { String(format: "%.2f", $0) }, animRange: 0.05...0.5),
                EffectParam(label: L("ぼけ"), range: 0...1, defaultValue: 0.55, format: EffectParam.percent, animRange: 0.2...0.9),
                EffectParam(label: L("帯の数"), range: 1...4, defaultValue: 2, perPoint: 0.02, step: 1,
                            format: { String(format: L("%.0f 本"), $0) }),
                EffectParam(label: L("帯の太さ"), range: 0.02...0.6, defaultValue: 0.22, perPoint: 0.0005,
                            format: EffectParam.percent, animRange: 0.08...0.3),
                EffectParam(label: L("うねり"), range: 0...2, defaultValue: 0.8, perPoint: 0.003,
                            format: EffectParam.percent, animRange: 0.3...1.5),
                EffectParam(label: L("色のにじみ"), range: 0...1, defaultValue: 0.6, format: EffectParam.percent, animRange: 0.2...1),
                EffectParam(label: L("虹色"), range: 0...1, defaultValue: 0.75, format: EffectParam.percent, animRange: 0.3...1),
                EffectParam(label: L("粒子感"), range: 0...0.4, defaultValue: 0.07, perPoint: 0.0005, format: EffectParam.percent),
                EffectParam(label: L("角度"), range: 0...360, defaultValue: 325, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("明るさ"), range: 0...3, defaultValue: 1, perPoint: 0.003,
                            format: EffectParam.percent, animRange: 0.5...1.5),
                EffectParam(label: L("色相ずらし"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("まわりの光"), range: 0...1, defaultValue: 0.35, format: EffectParam.percent, animRange: 0.2...0.8),
                EffectParam(label: L("大きさ"), range: 0.2...4, defaultValue: 1, perPoint: 0.003,
                            format: { String(format: "%.2fx", $0) }, animRange: 0.7...1.5),
                // 光の中の分光（波長ごとのずれ・薄い膜の干渉色・光の筋）
                EffectParam(label: L("スペクトルの複雑さ"), range: 0...1, defaultValue: 0.6, format: EffectParam.percent,
                            animRange: 0.2...1),
                EffectParam(label: L("スペクトルの細かさ"), range: 0.2...5, defaultValue: 1.5, perPoint: 0.005,
                            format: { String(format: "%.2f", $0) }, animRange: 0.8...3),
            ]
        case .physarum:
            // 粘菌：点 1 つずつが前・左・右のにおいをかいで、濃い方へ曲がる
            return [
                EffectParam(label: L("数"), range: 1000...1_000_000, defaultValue: 500_000, perPoint: 1000, step: 1000,
                            format: { String(format: L("%.0f 万"), $0 / 10000) }, animRange: 100_000...600_000),
                EffectParam(label: L("速さ"), range: 0...3, defaultValue: 0.8, perPoint: 0.005, format: { String(format: "%.2f", $0) }),
                EffectParam(label: L("においをかぐ角度"), range: 5...120, defaultValue: 40, perPoint: 0.3,
                            format: { String(format: "%.0f°", $0) }, animRange: 15...60),
                EffectParam(label: L("においをかぐ距離"), range: 2...80, defaultValue: 20, perPoint: 0.1,
                            format: { String(format: L("%.0f px（1080p）"), $0) }, animRange: 8...40),
                EffectParam(label: L("曲がる角度"), range: 5...120, defaultValue: 20, perPoint: 0.3,
                            format: { String(format: "%.0f°", $0) }, animRange: 10...50),
                EffectParam(label: L("跡の残る長さ"), range: 0...1, defaultValue: 0.6, format: EffectParam.percent),
                EffectParam(label: L("にじみ"), range: 0...1, defaultValue: 0.2, format: EffectParam.percent),
                EffectParam(label: L("明るさ"), range: 0...4, defaultValue: 0.6, perPoint: 0.005, format: EffectParam.percent, animRange: 0.3...1.5),
                EffectParam(label: L("色の付け方"), range: 0...1, defaultValue: 0, choices: [L("1 色"), L("パレット")]),
                EffectParam(label: L("えさ"), range: 0...2, defaultValue: 0, choices: [L("なし"), L("動く点"), L("輪")]),
                EffectParam(label: L("えさの強さ"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("ゆらぎ"), range: 0...1, defaultValue: 0.1, format: EffectParam.percent),
                EffectParam(label: L("始まりの形"), range: 0...2, defaultValue: 0, choices: [L("ばらばら"), L("円"), L("真ん中から")]),
            ]
        case .particleLife:
            // パーティクル・ライフ：種類どうしの好き嫌い（たねで決まる表）だけで動く
            return [
                EffectParam(label: L("数"), range: 2...6000, defaultValue: 2000, perPoint: 2, step: 1,
                            format: { String(format: L("%.0f 粒"), $0) }),
                EffectParam(label: L("種類の数"), range: 1...8, defaultValue: 6, perPoint: 0.03, step: 1,
                            format: { String(format: L("%.0f 色"), $0) }),
                EffectParam(label: L("たね（性格）"), range: 0...999, defaultValue: 1, perPoint: 0.1, step: 1,
                            format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("力の届く広さ"), range: 0.02...0.3, defaultValue: 0.09, perPoint: 0.0003,
                            format: EffectParam.percent, animRange: 0.05...0.15),
                EffectParam(label: L("力の強さ"), range: 0...3, defaultValue: 1, perPoint: 0.005, format: EffectParam.percent),
                EffectParam(label: L("ブレーキ"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("速さ"), range: 0...3, defaultValue: 1, perPoint: 0.005, format: { String(format: "%.2f", $0) }),
                EffectParam(label: L("粒の大きさ"), range: 1...40, defaultValue: 6, perPoint: 0.05,
                            format: { String(format: L("%.0f px（1080p）"), $0) }),
                EffectParam(label: L("光のにじみ"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("色の付け方"), range: 0...1, defaultValue: 0, choices: [L("虹色"), L("パレット")]),
                EffectParam(label: L("性格を入れ替える（拍）"), range: 0...6, defaultValue: 0,
                            choices: [L("しない"), "1", "2", "4", "8", "16", "32"]),
                EffectParam(label: L("明るさ"), range: 0...3, defaultValue: 1, perPoint: 0.003, format: EffectParam.percent),
                EffectParam(label: L("残像"), range: 0...0.98, defaultValue: 0, format: EffectParam.percent),
            ]
        case .fireflies:
            // ホタルの同期：1 匹ずつが自分の速さで光り、まわりの光に位相を少し合わせる
            return [
                EffectParam(label: L("数"), range: 10...4000, defaultValue: 600, perPoint: 2, step: 1,
                            format: { String(format: L("%.0f 匹"), $0) }),
                EffectParam(label: L("そろう強さ"), range: 0...3, defaultValue: 0.8, perPoint: 0.005,
                            format: EffectParam.percent, animRange: 0...1.5),
                EffectParam(label: L("見える広さ"), range: 0.02...1, defaultValue: 0.25, perPoint: 0.002,
                            format: { $0 >= 0.999 ? L("画面全体") : String(format: "%.0f%%", $0 * 100) }),
                EffectParam(label: L("光る速さ"), range: 0.1...4, defaultValue: 0.8, perPoint: 0.005,
                            format: { String(format: L("%.2f 回/秒"), $0) }),
                EffectParam(label: L("速さのばらつき"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("光の長さ"), range: 0.02...1, defaultValue: 0.25, format: EffectParam.percent),
                EffectParam(label: L("大きさ"), range: 1...40, defaultValue: 7, perPoint: 0.05,
                            format: { String(format: L("%.0f px（1080p）"), $0) }),
                EffectParam(label: L("光のにじみ"), range: 0...1, defaultValue: 0.6, format: EffectParam.percent),
                EffectParam(label: L("ふらふら"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("拍に合わせる"), range: 0...4, defaultValue: 0, choices: [L("しない"), L("½ 拍"), L("1 拍"), L("2 拍"), L("4 拍")]),
                EffectParam(label: L("拍への引き"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("明るさ"), range: 0...3, defaultValue: 1, perPoint: 0.003, format: EffectParam.percent),
                EffectParam(label: L("色のばらつき"), range: 0...1, defaultValue: 0.15, format: EffectParam.percent),
            ]
        case .attractor:
            // ストレンジ・アトラクター：点を式で動かし続け、通った所の濃さを描く
            return [
                EffectParam(label: L("種類"), range: 0...3, defaultValue: 0, choices: [L("クリフォード"), L("デ・ヨング"), L("トーマス"), L("アイザワ")]),
                EffectParam(label: L("係数 a"), range: -3...3, defaultValue: -1.4, perPoint: 0.002, format: { String(format: "%+.3f", $0) }),
                EffectParam(label: L("係数 b"), range: -3...3, defaultValue: 1.6, perPoint: 0.002, format: { String(format: "%+.3f", $0) }),
                EffectParam(label: L("係数 c"), range: -3...3, defaultValue: 1.0, perPoint: 0.002, format: { String(format: "%+.3f", $0) }),
                EffectParam(label: L("係数 d"), range: -3...3, defaultValue: 0.7, perPoint: 0.002, format: { String(format: "%+.3f", $0) }),
                EffectParam(label: L("変身の速さ"), range: 0...2, defaultValue: 0.2, perPoint: 0.002, format: { String(format: "%.2f", $0) }),
                EffectParam(label: L("変身の大きさ"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("濃さ"), range: 0...4, defaultValue: 1, perPoint: 0.005, format: EffectParam.percent, animRange: 0.5...2),
                EffectParam(label: L("残り方"), range: 0...0.99, defaultValue: 0.9, format: EffectParam.percent),
                EffectParam(label: L("大きさ"), range: 0.2...3, defaultValue: 1, perPoint: 0.003, format: { String(format: "%.2fx", $0) }),
                EffectParam(label: L("回る速さ"), range: -60...60, defaultValue: 4, perPoint: 0.2,
                            format: { String(format: L("%+.0f°/秒"), $0) }),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 1, choices: [L("1 色"), L("パレット"), L("動きの向き")]),
                EffectParam(label: L("点の数"), range: 0.1...4, defaultValue: 1, perPoint: 0.005,
                            format: { String(format: L("%.1f 百万/コマ"), $0) }),
            ]
        case .timeWarp:
            // 時間のずらし：場所ごとに何コマ前を見せるか
            return [
                EffectParam(label: L("ずらす時間"), range: 0.05...4, defaultValue: 1, perPoint: 0.005,
                            format: { String(format: L("%.2f 秒"), $0) }, animRange: 0.3...2),
                EffectParam(label: L("ずらし方"), range: 0...4, defaultValue: 0, choices: [L("縦"), L("横"), L("円"), L("ノイズ"), L("明るさ")]),
                EffectParam(label: L("反対にする"), range: 0...1, defaultValue: 0, isToggle: true),
                EffectParam(label: L("段々にする"), range: 0...32, defaultValue: 0, perPoint: 0.05, step: 1,
                            format: { $0 < 1.5 ? L("なめらか") : String(format: L("%.0f 段"), $0) }),
                EffectParam(label: L("ノイズの細かさ"), range: 0.2...8, defaultValue: 2, perPoint: 0.01, format: { String(format: "%.2f", $0) }),
                EffectParam(label: L("ノイズの速さ"), range: 0...2, defaultValue: 0.3, perPoint: 0.003, format: { String(format: "%.2f", $0) }),
            ]
        case .fluid:
            // 流体：動きで押して、絵の具を流す
            return [
                EffectParam(label: L("動きで押す"), range: 0...3, defaultValue: 1, perPoint: 0.005, format: EffectParam.percent),
                EffectParam(label: L("絵の具を足す量"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("足し方"), range: 0...2, defaultValue: 0, choices: [L("動いた所"), L("明るい所"), L("全体")]),
                EffectParam(label: L("絵の具の残る長さ"), range: 0...1, defaultValue: 0.7, format: EffectParam.percent),
                EffectParam(label: L("渦"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("風"), range: 0...1, defaultValue: 0.25, format: EffectParam.percent, animRange: 0...0.6),
                EffectParam(label: L("ねばり"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("元の絵"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("細かさ"), range: 0...2, defaultValue: 1, choices: [L("粗い"), L("ふつう"), L("細かい")]),
            ]
        case .glitchBox:
            return [
                EffectParam(label: L("同期くずし"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent, animRange: 0...0.8),
                EffectParam(label: L("縦に流れる"), range: -2...2, defaultValue: 0, perPoint: 0.005, format: { String(format: "%+.2f", $0) }),
                EffectParam(label: L("ガクッとずれる"), range: 0...1, defaultValue: 0.2, format: EffectParam.percent),
                EffectParam(label: L("色にじみ"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("色ずれ"), range: 0...60, defaultValue: 8, perPoint: 0.1,
                            format: { String(format: L("%.0f px（1080p）"), $0) }, animRange: 0...30),
                EffectParam(label: L("ゲイン"), range: 0.5...4, defaultValue: 1.2, perPoint: 0.005, format: EffectParam.percent,
                            animRange: 1...2.5),
                EffectParam(label: L("折り返し（反転）"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: L("エンハンサー"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("色の発振"), range: 0...1, defaultValue: 0.15, format: EffectParam.percent),
                EffectParam(label: L("ノイズ"), range: 0...1, defaultValue: 0.15, format: EffectParam.percent),
                EffectParam(label: L("走査線"), range: 0...1, defaultValue: 0.2, format: EffectParam.percent),
                EffectParam(label: L("乱れる速さ"), range: 0...4, defaultValue: 1, perPoint: 0.005, format: { String(format: "%.2f", $0) }),
            ]
        case .vhs:
            return [
                EffectParam(label: L("トラッキングのずれ"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("下のノイズ"), range: 0...1, defaultValue: 0.6, format: EffectParam.percent),
                EffectParam(label: L("揺れ"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("色のにじみ"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("色あせ"), range: 0...1, defaultValue: 0.35, format: EffectParam.percent),
                EffectParam(label: L("ドロップアウト"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("ノイズ"), range: 0...1, defaultValue: 0.25, format: EffectParam.percent),
                EffectParam(label: L("画質"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
            ]
        case .videoFeedback:
            return [
                EffectParam(label: L("ズーム"), range: 0.5...2, defaultValue: 1.25, perPoint: 0.002,
                            format: { String(format: L("%.2fx /秒"), $0) }, animRange: 0.8...1.6),
                EffectParam(label: L("回転"), range: -180...180, defaultValue: 20, perPoint: 0.5,
                            format: { String(format: L("%+.0f°/秒"), $0) }, animRange: -60...60),
                EffectParam(label: L("ずれ X"), range: -0.5...0.5, defaultValue: 0, perPoint: 0.001,
                            format: { String(format: L("%+.0f%%/秒"), $0 * 100) }),
                EffectParam(label: L("ずれ Y"), range: -0.5...0.5, defaultValue: 0, perPoint: 0.001,
                            format: { String(format: L("%+.0f%%/秒"), $0 * 100) }),
                EffectParam(label: L("色相のずれ"), range: -360...360, defaultValue: 60, perPoint: 1,
                            format: { String(format: L("%+.0f°/秒"), $0) }),
                EffectParam(label: L("残る強さ"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("切り抜く明るさ"), range: 0...1, defaultValue: 0.15, format: EffectParam.percent),
                EffectParam(label: L("重ね方"), range: 0...2, defaultValue: 0, choices: [L("上に重ねる"), L("加算"), L("明るい方")]),
                EffectParam(label: L("コントラスト"), range: 0.5...2, defaultValue: 1.05, perPoint: 0.003,
                            format: { String(format: "%.2f", $0) }),
                EffectParam(label: L("ぼかし"), range: 0...1, defaultValue: 0.1, format: EffectParam.percent),
            ]
        case .rasterScan:
            return [
                EffectParam(label: L("線の数"), range: 4...400, defaultValue: 100, perPoint: 0.3, step: 1,
                            format: { String(format: L("%.0f 本"), $0) }, animRange: 40...160),
                EffectParam(label: L("持ち上げる高さ"), range: 0...1, defaultValue: 0.25, format: EffectParam.percent, animRange: 0.1...0.5),
                EffectParam(label: L("線の太さ"), range: 0.5...8, defaultValue: 2, perPoint: 0.01,
                            format: { String(format: L("%.1f px（1080p）"), $0) }),
                EffectParam(label: L("奥への傾き"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("色"), range: 0...2, defaultValue: 0, choices: [L("元の色"), L("1 色"), L("白黒")]),
                EffectParam(label: L("明るさ"), range: 0...3, defaultValue: 1.3, perPoint: 0.003, format: EffectParam.percent),
                EffectParam(label: L("波"), range: 0...1, defaultValue: 0, format: EffectParam.percent, animRange: 0...0.6),
                EffectParam(label: L("下に元の絵"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: L("後ろの線を隠す"), range: 0...1, defaultValue: 1, isToggle: true),
            ]
        case .crt:
            return [
                EffectParam(label: L("走査線"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("蛍光体の粒"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("粒の大きさ"), range: 1...8, defaultValue: 3, perPoint: 0.01,
                            format: { String(format: L("%.1f px（1080p）"), $0) }),
                EffectParam(label: L("画面のふくらみ"), range: 0...1, defaultValue: 0.25, format: EffectParam.percent),
                EffectParam(label: L("にじむ光"), range: 0...1, defaultValue: 0.35, format: EffectParam.percent),
                EffectParam(label: L("残光"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent),
                EffectParam(label: L("まわりを暗く"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent),
                EffectParam(label: L("明るさ"), range: 0.5...3, defaultValue: 1.35, perPoint: 0.003, format: EffectParam.percent),
                EffectParam(label: L("ちらつき"), range: 0...1, defaultValue: 0.05, format: EffectParam.percent),
            ]
        case .audioScope:
            return [
                EffectParam(label: L("形"), range: 0...4, defaultValue: 0, choices: [L("棒"), L("線"), L("波形"), L("円（棒）"), L("円（波形）")]),
                EffectParam(label: L("帯の数"), range: 4...128, defaultValue: 48, perPoint: 0.1, step: 1,
                            format: { String(format: L("%.0f 本"), $0) }),
                EffectParam(label: L("高さ"), range: 0...2, defaultValue: 1, perPoint: 0.003, format: EffectParam.percent),
                EffectParam(label: L("太さ"), range: 0...1, defaultValue: 0.6, format: EffectParam.percent),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 1, choices: [L("1 色"), L("虹色"), L("パレット")]),
                EffectParam(label: L("上下対称"), range: 0...1, defaultValue: 0, isToggle: true),
                EffectParam(label: L("なめらかさ"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("明るさ"), range: 0...3, defaultValue: 1, perPoint: 0.003, format: EffectParam.percent),
                EffectParam(label: L("円の大きさ"), range: 0.05...0.45, defaultValue: 0.22, perPoint: 0.001, format: EffectParam.percent),
            ]
        case .camera:
            return [
                EffectParam(label: L("合わせ方"), range: 0...2, defaultValue: 1, choices: [L("収める"), L("いっぱいに"), L("引き伸ばす")]),
                EffectParam(label: L("左右反転（鏡）"), range: 0...1, defaultValue: 0, isToggle: true),
                EffectParam(label: L("濃さ"), range: 0...1, defaultValue: 1, format: EffectParam.percent),
            ]
        case .syphonIn, .ndiIn:
            return [
                EffectParam(label: L("合わせ方"), range: 0...2, defaultValue: 0, choices: [L("収める"), L("いっぱいに"), L("引き伸ばす")]),
                EffectParam(label: L("濃さ"), range: 0...1, defaultValue: 1, format: EffectParam.percent),
            ]
        case .tunnel:
            // トンネル：奥へ進む筒の内側。速さは進んだ量にして渡す
            return [
                EffectParam(label: L("速さ"), range: -4...4, defaultValue: 0.8, perPoint: 0.005,
                            format: { String(format: "%+.2f", $0) }, animRange: 0.3...2),
                EffectParam(label: L("形"), range: 0...3, defaultValue: 0, choices: [L("円"), L("四角"), L("六角"), L("三角")]),
                EffectParam(label: L("模様"), range: 0...4, defaultValue: 0, choices: [L("輪"), L("格子"), L("チェッカー"), L("光の筋"), L("もや")]),
                EffectParam(label: L("輪の数"), range: 0.5...24, defaultValue: 4, perPoint: 0.02,
                            format: { String(format: "%.1f", $0) }, animRange: 2...8),
                EffectParam(label: L("線の太さ"), range: 0.02...1, defaultValue: 0.18, format: EffectParam.percent,
                            animRange: 0.08...0.5),
                EffectParam(label: L("回る速さ"), range: -180...180, defaultValue: 12, perPoint: 0.5,
                            format: { String(format: L("%+.0f°/秒"), $0) }, animRange: -45...45),
                EffectParam(label: L("ねじれ"), range: -2...2, defaultValue: 0, perPoint: 0.005,
                            format: { String(format: "%+.2f", $0) }, animRange: -1...1),
                EffectParam(label: L("奥の暗さ"), range: 0...2, defaultValue: 0.5, perPoint: 0.003, format: EffectParam.percent),
                EffectParam(label: L("うねり（曲がる）"), range: 0...2, defaultValue: 0.4, perPoint: 0.003,
                            format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("うねりの速さ"), range: 0...3, defaultValue: 0.3, perPoint: 0.003,
                            format: { String(format: "%.2f", $0) }),
                EffectParam(label: L("中心の位置 X"), range: -0.5...0.5, defaultValue: 0, perPoint: 0.001,
                            format: EffectParam.percent, animRange: -0.2...0.2, noDice: true),
                EffectParam(label: L("中心の位置 Y"), range: -0.5...0.5, defaultValue: 0, perPoint: 0.001,
                            format: EffectParam.percent, animRange: -0.2...0.2, noDice: true),
                EffectParam(label: L("まわりの区切り"), range: 2...48, defaultValue: 12, perPoint: 0.05, step: 1,
                            format: { String(format: "%.0f", $0) }),
                EffectParam(label: L("色の付け方"), range: 0...2, defaultValue: 0, choices: [L("1 色"), L("パレット"), L("虹色")]),
                EffectParam(label: L("明るさ"), range: 0...3, defaultValue: 1, perPoint: 0.003,
                            format: EffectParam.percent, animRange: 0.5...1.5),
                EffectParam(label: L("光のにじみ"), range: 0...1, defaultValue: 0.3, format: EffectParam.percent, animRange: 0...0.8),
            ]
        case .warp:
            // うねり：ノイズで絵の場所をずらす（強さは 1080p での px）
            return [
                EffectParam(label: L("強さ"), range: 0...300, defaultValue: 45, perPoint: 0.3,
                            format: { String(format: L("%.0f px（1080p）"), $0) }, animRange: 0...120),
                EffectParam(label: L("うねりの大きさ"), range: 0.03...2, defaultValue: 0.4, perPoint: 0.002,
                            format: { String(format: "%.2f", $0) }, animRange: 0.15...1),
                EffectParam(label: L("速さ"), range: 0...4, defaultValue: 0.4, perPoint: 0.003,
                            format: { String(format: "%.2f", $0) }, animRange: 0.1...1.5),
                EffectParam(label: L("種類"), range: 0...3, defaultValue: 0, choices: [L("液体"), L("熱気"), L("渦"), L("波紋")]),
                EffectParam(label: L("細かさ"), range: 0...1, defaultValue: 0.45, format: EffectParam.percent),
                EffectParam(label: L("ねばり"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("色のずれ"), range: 0...1, defaultValue: 0, format: EffectParam.percent, animRange: 0...0.6),
                EffectParam(label: L("画面の端"), range: 0...2, defaultValue: 1, choices: [L("のばす"), L("折り返す"), L("透明")]),
            ]
        case .school:
            // 群れ（ボイド）。GPU の上で 1 匹ずつ動かす（シェーダーの a・b は使わない）
            return [
                EffectParam(label: L("数"), range: 50...4000, defaultValue: 900, perPoint: 2, step: 1,
                            format: { String(format: L("%.0f 匹"), $0) }, animRange: 300...2000),
                EffectParam(label: L("大きさ"), range: 2...80, defaultValue: 14, perPoint: 0.05,
                            format: { String(format: L("%.1f px（1080p）"), $0) }, animRange: 8...24),
                EffectParam(label: L("形"), range: 0...3, defaultValue: 0, choices: [L("魚"), L("鳥"), L("粒"), L("線")]),
                EffectParam(label: L("速さ"), range: 0...3, defaultValue: 1, perPoint: 0.003,
                            format: { String(format: "%.2fx", $0) }, animRange: 0.5...1.5),
                EffectParam(label: L("まとまる"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("向きをそろえる"), range: 0...1, defaultValue: 0.6, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("間をあける"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("まわりを見る広さ"), range: 0.02...0.3, defaultValue: 0.08, perPoint: 0.0005,
                            format: { String(format: L("%.1f%%（高さ）"), $0 * 100) }, animRange: 0.04...0.15),
                EffectParam(label: L("動き回る"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("天敵から逃げる"), range: 0...1, defaultValue: 0, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("ゆらぎ"), range: 0...1, defaultValue: 0.2, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("きらめき"), range: 0...1, defaultValue: 0.6, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("奥行き"), range: 0...1, defaultValue: 0.4, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("画面の端"), range: 0...1, defaultValue: 0, choices: [L("戻ってくる"), L("反対側へ抜ける")]),
                // 3D：厚みがあれば箱の中を立体に泳ぎ、回るカメラから遠近をつけて描く（0 なら平ら）
                EffectParam(label: L("厚み（3D）"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("渦を巻く"), range: 0...1, defaultValue: 0, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("カメラの回る速さ"), range: -45...45, defaultValue: 5, perPoint: 0.05,
                            format: { String(format: L("%+.1f°/秒"), $0) }, animRange: -10...10),
                EffectParam(label: L("カメラの向き"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("視点の高さ"), range: -80...80, defaultValue: 15, perPoint: 0.2,
                            format: { String(format: "%+.0f°", $0) }, animRange: -40...40),
                EffectParam(label: L("カメラの距離"), range: 0.3...3, defaultValue: 1.2, perPoint: 0.003,
                            format: { String(format: "%.2fx", $0) }, animRange: 0.8...1.6),
                EffectParam(label: L("画角"), range: 15...120, defaultValue: 50, perPoint: 0.1,
                            format: { String(format: "%.0f°", $0) }, animRange: 30...80),
            ]
        case .dots:
            // ラインの粒版。並べた粒を、ばらつき・明滅・波（大きさが波打つ）・奥への傾き・波の高さ（3D の点の雲）で動かす。
            // 0〜7 はシェーダーの a・b、8 からは pts で渡す
            return [
                EffectParam(label: L("数"), range: 1...150, defaultValue: 14, perPoint: 0.05,
                            format: { String(format: L("%.1f 個"), $0) }, animRange: 6...30),
                EffectParam(label: L("粒の大きさ"), range: 0.5...300, defaultValue: 16, perPoint: 0.1,
                            format: { String(format: L("%.1f px（1080p）"), $0) }, animRange: 6...40),
                EffectParam(label: L("形"), range: 0...3, defaultValue: 0, choices: [L("円"), L("四角"), L("ひし形"), L("十字")]),
                EffectParam(label: L("並び"), range: 0...2, defaultValue: 0, choices: [L("格子"), L("互い違い"), L("ばらばら")]),
                EffectParam(label: L("角度"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("速さ"), range: -8...8, defaultValue: 0, perPoint: 0.005,
                            format: { String(format: L("%+.2f 個/秒"), $0) }, animRange: -2...2),
                EffectParam(label: L("位置のばらつき"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: L("大きさのばらつき"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: L("明滅"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                // 波：粒の大きさが波打つ（横・中心から・ノイズ）。波の高さ（3D）の形にも使う
                EffectParam(label: L("波の大きさ"), range: 0...1, defaultValue: 0.6, format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("波の細かさ"), range: 0.1...20, defaultValue: 2.5, perPoint: 0.01,
                            format: { String(format: L("%.2f 山"), $0) }, animRange: 0.5...4),
                EffectParam(label: L("波の速さ"), range: -8...8, defaultValue: 0.5, perPoint: 0.005,
                            format: { String(format: L("%+.2f /秒"), $0) }, animRange: -2...2),
                EffectParam(label: L("波の形"), range: 0...2, defaultValue: 1, choices: [L("横"), L("中心から"), L("ノイズ")]),
                EffectParam(label: L("奥への傾き（縦）"), range: -85...85, defaultValue: 0, perPoint: 0.2,
                            format: { String(format: "%+.0f°", $0) }, animRange: -60...60),
                EffectParam(label: L("奥への傾き（横）"), range: -85...85, defaultValue: 0, perPoint: 0.2,
                            format: { String(format: "%+.0f°", $0) }, animRange: -60...60),
                EffectParam(label: L("遠くを暗く"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("波の高さ（3D）"), range: 0...0.6, defaultValue: 0, perPoint: 0.0005,
                            format: EffectParam.percent, animRange: 0.05...0.3),
                EffectParam(label: L("ぼかし"), range: 0...100, defaultValue: 0, perPoint: 0.05,
                            format: { String(format: "%.1f px", $0) }, animRange: 0...20),
                // ふらふら：粒が 1 つずつ別々の道すじで、ゆっくり自由に飛び回る（ほたるのように）。平らのときだけ
                EffectParam(label: L("ふらふら（自由に飛ぶ）"), range: 0...1, defaultValue: 0, format: EffectParam.percent,
                            animRange: 0...1),
                EffectParam(label: L("ふらふらの速さ"), range: 0...4, defaultValue: 0.5, perPoint: 0.003,
                            format: { String(format: "%.2fx", $0) }, animRange: 0.2...1.5),
                // 光のにじみ：粒のまわりにぼんやり光の輪（重なると明るくなる）
                EffectParam(label: L("光のにじみ"), range: 0...1, defaultValue: 0, format: EffectParam.percent,
                            animRange: 0...1),
            ]
        case .lines:
            // Arena の Lines と同じ考え方：本数は画面の高さに入る数、0° で縦の線。太さは px（1080p での大きさ）なので細い線は細いまま
            return [
                EffectParam(label: L("本数"), range: 1...200, defaultValue: 10, perPoint: 0.05,
                            format: { String(format: L("%.1f 本"), $0) }, animRange: 4...30),
                EffectParam(label: L("線の太さ"), range: 0.25...200, defaultValue: 4, perPoint: 0.05,
                            format: { String(format: L("%.1f px（1080p）"), $0) }, animRange: 2...20),
                EffectParam(label: L("角度"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360),
                EffectParam(label: L("速さ"), range: -8...8, defaultValue: 0.5, perPoint: 0.005,
                            format: { String(format: L("%+.2f 本/秒"), $0) }, animRange: -2...2),
                EffectParam(label: L("ぼかし"), range: 0...100, defaultValue: 0, perPoint: 0.05,
                            format: { String(format: "%.1f px", $0) }, animRange: 0...20),
                // 波：線が波形のようにうねる（大きさは画面の高さに対する割合、細かさは高さあたりの山の数）
                EffectParam(label: L("波の大きさ"), range: 0...0.5, defaultValue: 0, perPoint: 0.0005,
                            format: EffectParam.percent, animRange: 0...0.1),
                EffectParam(label: L("波の細かさ"), range: 0.1...20, defaultValue: 2, perPoint: 0.01,
                            format: { String(format: L("%.2f 山"), $0) }, animRange: 1...4),
                EffectParam(label: L("波の速さ"), range: -8...8, defaultValue: 1, perPoint: 0.005,
                            format: { String(format: L("%+.2f /秒"), $0) }, animRange: -2...2),
                EffectParam(label: L("線ごとの波のずれ"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                // 3D：線を描いた板を奥へ傾ける（遠近あり）
                EffectParam(label: L("奥への傾き（縦）"), range: -85...85, defaultValue: 0, perPoint: 0.2,
                            format: { String(format: "%+.0f°", $0) }, animRange: -60...60),
                EffectParam(label: L("奥への傾き（横）"), range: -85...85, defaultValue: 0, perPoint: 0.2,
                            format: { String(format: "%+.0f°", $0) }, animRange: -60...60),
                EffectParam(label: L("遠くを暗く"), range: 0...1, defaultValue: 0.5, format: EffectParam.percent),
                // 波の高さ：線を上下に持ち上げて、地形のような 3D にする（手前の山が奥の線を隠す）
                EffectParam(label: L("波の高さ（3D）"), range: 0...0.6, defaultValue: 0, perPoint: 0.0005,
                            format: EffectParam.percent, animRange: 0.05...0.3),
                EffectParam(label: L("山の形"), range: 0...2, defaultValue: 1, choices: [L("波"), L("なめらかな山"), L("とがった山")]),
                EffectParam(label: L("真ん中を平ら／山に"), range: -1...1, defaultValue: 0, perPoint: 0.002,
                            format: { $0 == 0 ? L("なし") : String(format: $0 > 0 ? L("平ら %.0f%%") : L("山 %.0f%%"), abs($0) * 100) },
                            animRange: -1...1),
                EffectParam(label: L("山の下を黒く塗る"), range: 0...1, defaultValue: 0, isToggle: true),
            ]
        case .phyllotaxis:
            // Resolume 用に作った FFGL のジェネレーター（Phyllotaxis）と同じ値。粒は黄金角ずつ回りながら中心から生まれて外へ広がる
            return [
                EffectParam(label: L("生まれる速さ"), range: 2...80, defaultValue: 20, perPoint: 0.05,
                            format: { String(format: L("%.1f 個/秒"), $0) }, animRange: 10...40),
                EffectParam(label: L("広がる速さ"), range: 0.05...1.5, defaultValue: 0.2, perPoint: 0.001,
                            format: { String(format: "%.3f", $0) }, animRange: 0.1...0.4),
                EffectParam(label: L("粒の大きさ"), range: 0.003...0.05, defaultValue: 0.012, perPoint: 0.0001,
                            format: { String(format: "%.1f%%", $0 * 100) }, animRange: 0.006...0.02),
                EffectParam(label: L("育つ時間"), range: 0...3, defaultValue: 0.3, perPoint: 0.005,
                            format: { String(format: L("%.2f 秒"), $0) }),
                EffectParam(label: L("外ほど大きく"), range: 0...3, defaultValue: 1, perPoint: 0.005,
                            format: { String(format: "%.2f", $0) }, animRange: 0...2),
                EffectParam(label: L("光のにじみ"), range: 0...2, defaultValue: 0.5, perPoint: 0.003,
                            format: EffectParam.percent, animRange: 0...1),
                EffectParam(label: L("回転"), range: -1...1, defaultValue: 0, perPoint: 0.002,
                            format: { String(format: L("%+.3f 回/秒"), $0) }, animRange: -0.2...0.2),
                EffectParam(label: L("線の長さ"), range: 0...0.3, defaultValue: 0, perPoint: 0.0005,
                            format: EffectParam.percent, animRange: 0...0.15),
                EffectParam(label: L("色のばらつき"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
            ]
        case .clock:
            // 0〜11 はテキストと同じ（描き方は共通）。12 から時計の設定。終わったときの文字は Effect.text
            func n(_ label: String, _ r: ClosedRange<Double>, _ d: Double, _ unit: String) -> EffectParam {
                EffectParam(label: label, range: r, defaultValue: d, perPoint: 0.05, step: 1,
                            format: { String(format: "%.0f ", $0) + unit })
            }
            return EffectKind.text.params + [
                EffectParam(label: L("モード"), range: 0...Double(ClockText.modes.count - 1), defaultValue: 1,
                            choices: ClockText.modes),
                EffectParam(label: L("表示"), range: 0...Double(ClockText.formats.count - 1), defaultValue: 0,
                            choices: ClockText.formats),
                EffectParam(label: L("秒より細かく"), range: 0...2, defaultValue: 0, choices: [L("なし"), "1/10", "1/100"]),
                n(L("目標の時"), 0...23, 0, L("時")), n(L("目標の分"), 0...59, 0, L("分")), n(L("目標の秒"), 0...59, 0, L("秒")),
                n(L("タイマーの分"), 0...999, 10, L("分")), n(L("タイマーの秒"), 0...59, 0, L("秒")),
                EffectParam(label: L("最後の 10 秒を弾ませる"), range: 0...1, defaultValue: 1, isToggle: true),
            ]
        case .text:
            // 文字は Effect.text。0〜5 はシェーダーで、6 以降は文字を描くとき（CPU）に使う
            return [
                EffectParam(label: L("動き"), range: 0...5, defaultValue: 0, choices: TextLook.motions),
                EffectParam(label: L("大きさ"), range: 0.02...1.5, defaultValue: 0.22, perPoint: 0.002,
                            format: EffectParam.percent, animRange: 0.1...0.4),
                EffectParam(label: L("速さ"), range: -4...4, defaultValue: 0.4, perPoint: 0.005,
                            format: { String(format: L("%+.2f /秒"), $0) }, animRange: -1...1),
                EffectParam(label: L("波"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: L("グリッチ"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
                EffectParam(label: L("塗り"), range: 0...1, defaultValue: 0, choices: [L("色"), L("パレット")]),
                EffectParam(label: L("フォント"), range: 0...Double(TextLook.fonts.count - 1), defaultValue: 0,
                            choices: TextLook.fonts.map(\.label)),
                EffectParam(label: L("字間"), range: -0.2...1, defaultValue: 0.04, perPoint: 0.002,
                            format: { String(format: "%.0f%%", $0 * 100) }),
                EffectParam(label: L("行の切り替え"), range: 0...4, defaultValue: 0,
                            choices: TextLook.switchBeats.map { $0 == 0 ? L("全部の行") : ParamAnim.beatsLabel($0) }),
                EffectParam(label: L("縁取りだけ"), range: 0...1, defaultValue: 0, isToggle: true),
                // 流す・敷き詰めるときの、となりの文字とのすき間（1 行の高さが 1）
                EffectParam(label: L("横の間隔"), range: -0.5...6, defaultValue: 1, perPoint: 0.005,
                            format: { String(format: L("%.2f 行"), $0) }, animRange: 0.2...2),
                EffectParam(label: L("縦の間隔"), range: -0.5...6, defaultValue: 0.5, perPoint: 0.005,
                            format: { String(format: L("%.2f 行"), $0) }, animRange: 0...1.5),
            ]
        case .shapeMask:
            // 四角・丸で切り抜く。位置・大きさは絵の幅・高さに対する割合
            return [
                EffectParam(label: L("形"), range: 0...1, defaultValue: 0, choices: [L("四角"), L("丸")]),
                EffectParam(label: L("反転（中を隠す）"), range: 0...1, defaultValue: 0, isToggle: true),
                EffectParam(label: L("位置 X"), range: -1...1, defaultValue: 0, perPoint: 0.002,
                            format: { String(format: "%+.1f%%", $0 * 100) }, animRange: -0.3...0.3, noDice: true),
                EffectParam(label: L("位置 Y"), range: -1...1, defaultValue: 0, perPoint: 0.002,
                            format: { String(format: "%+.1f%%", $0 * 100) }, animRange: -0.3...0.3, noDice: true),
                EffectParam(label: L("幅"), range: 0...2, defaultValue: 0.6, perPoint: 0.002, format: EffectParam.percent,
                            animRange: 0.2...0.8, noDice: true),
                EffectParam(label: L("高さ"), range: 0...2, defaultValue: 0.6, perPoint: 0.002, format: EffectParam.percent,
                            animRange: 0.2...0.8, noDice: true),
                EffectParam(label: L("角度"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: "%.0f°", $0) }, animRange: 0...360, noDice: true),
                EffectParam(label: L("ぼかし"), range: 0...0.5, defaultValue: 0.02, perPoint: 0.0005,
                            format: { String(format: "%.1f%%", $0 * 100) }),
            ]
        case .polyMask:
            // 点を結んだ形で切り抜く。点はプレビューの上で編集する（Effect.points）
            return [
                EffectParam(label: L("ぼかし"), range: 0...0.3, defaultValue: 0.005, perPoint: 0.0005,
                            format: { String(format: "%.1f%%", $0 * 100) }),
                EffectParam(label: L("反転（中を隠す）"), range: 0...1, defaultValue: 0, isToggle: true),
            ]
        case .echo:
            // 前の絵を少しずつ薄めながら残して、今の絵と重ねる（フィードバック）
            return [
                EffectParam(label: L("重ね方"), range: 0...2, defaultValue: 0, choices: [L("明るい方"), L("加算"), L("混ぜる")]),
                EffectParam(label: L("残る長さ"), range: 0.05...10, defaultValue: 1, perPoint: 0.01,
                            format: { String(format: L("%.2f 秒"), $0) }, animRange: 0.2...3),
                EffectParam(label: L("広がり"), range: -1...1, defaultValue: 0, perPoint: 0.002,
                            format: { $0 == 0 ? L("なし") : String(format: "%+.0f%%", $0 * 100) }, animRange: -0.3...0.3),
                EffectParam(label: L("色相ずれ"), range: 0...360, defaultValue: 0, perPoint: 1,
                            format: { String(format: L("%.0f°/秒"), $0) }, animRange: 0...360),
                EffectParam(label: L("残像の濃さ"), range: 0...1, defaultValue: 1, format: EffectParam.percent),
            ]
        case .strobe:
            // 光る／消える を BPM（拍）か 1 秒あたりの回数で繰り返す。光る色は下の「色」で選ぶ
            return [
                EffectParam(label: L("光り方"), range: 0...2, defaultValue: 0, choices: [L("色で光る"), L("消える"), L("反転")]),
                EffectParam(label: L("合わせるもの"), range: 0...1, defaultValue: 0, choices: ["BPM", L("秒", note: "選択")]),
                EffectParam(label: L("間隔"), range: 0...6, defaultValue: 3,
                            choices: Self.strobeBeats.map { ParamAnim.beatsLabel($0) }),
                EffectParam(label: L("1 秒の回数"), range: 0.5...30, defaultValue: 8, perPoint: 0.05,
                            format: { String(format: L("%.1f 回"), $0) }, animRange: 2...16),
                EffectParam(label: L("光る長さ"), range: 0.05...0.95, defaultValue: 0.5, format: EffectParam.percent),
                EffectParam(label: L("強さ"), range: 0...1, defaultValue: 1, format: EffectParam.percent),
                EffectParam(label: L("残光（すっと消える）"), range: 0...1, defaultValue: 0, format: EffectParam.percent),
            ]
        case .posterizeTime:
            return [
                EffectParam(label: L("フレームレート"), range: 1...60, defaultValue: 8, perPoint: 0.05, step: 1,
                            format: { String(format: "%.0f fps", $0) }),
            ]
        }
    }

    var help: String {
        if let m = moreHelp { return m }
        return switch self {
        // 追加のもの（上で返している）
        case .bloom, .kaleidoscope, .rgbSplit, .pixelate, .edgeNeon, .zoomBlur, .pixelSort, .datamosh, .ascii, .dither, .voronoiGlass, .reactionDiffusion, .laser, .synthwave, .logoParticles, .metaballs, .starfield, .fractal, .ripples, .lightning, .growth: ""
        case .plasma, .aurora, .nebula, .truchet, .hexGrid, .codeRain, .wireframe, .moire: ""
        case .mirror: L("画面の半分を反対側に折り返す")
        case .colorize: L("明るさをもとに、1 色で染める（カラー）か、パレットの色に置き換える（パレット）")
        case .levels: L("黒と白の位置・ガンマで明るさとコントラストを整える")
        case .invert: L("ネガのように色を反転する。明るさだけ（色はそのまま）・色だけ（明るさはそのまま）も選べる。不透明度を動かすと元の絵と行き来する")
        case .posterize: L("色の段数を減らす。ディザとドットを足すと GIF アニメのような見た目に")
        case .solid: L("1 色で塗りつぶす。マスク用の白や、色を重ねるのに")
        case .gradient: L("パレットの色でグラデーション（直線・円・回転）。速さで流れる")
        case .stripes: L("しま模様。角度・太さ・速さで動かせる（すき間は透明）")
        case .grid: L("チェッカー・格子・ドット（すき間は透明）")
        case .noise: L("なめらかに動くノイズか、砂嵐")
        case .shapes: L("円・リング・四角・枠・三角。数を増やすと並ぶ（まわりは透明）")
        case .flow: L("やわらかい光の帯がゆったりうねって流れる。ふちが虹色ににじみ、まわりにぼんやりした光とフィルムのざらつき（まわりは透明）")
        case .physarum: L("粘菌の動き方をまねた、何十万もの点。自分や仲間の通った跡のにおいを追って進むだけで、葉脈・神経・川の地図のような網を自分で作っては組み替える。えさを置くと、えさどうしを網でつなぐ（まわりは透明）")
        case .particleLife: L("色ごとに「あの色に寄る・あの色から逃げる」を決めただけの粒から、細胞のように集まる・追いかける・回る「生き物」が生まれる。たねで性格が変わり、拍ごとに入れ替えられる（まわりは透明）")
        case .fireflies: L("ばらばらに光るホタルが、見えるまわりの光に少しずつ合わせて、やがて全体がそろって光る（蔵本モデル）。そろう強さを動かすと、ばらばら ↔ 一斉を行き来する。拍に合わせることもできる（まわりは透明）")
        case .attractor: L("簡単な式をくり返すだけで点が描く、煙や絹のような形（クリフォード・デ・ヨング。トーマス・アイザワは 3D で回る）。係数をゆっくり揺らして形を変え続け、点の重なりを光の濃さで描く（まわりは透明）")
        case .timeWarp: L("場所ごとに少し前のコマを見せる。上ほど過去にすると、動く人が飴のように伸びる・ねじれる（スリットスキャン）。円・ノイズ・明るさでずらし方を変えられる")
        case .fluid: L("絵の動き（明るさが変わった所）が、本物の流体の計算で絵の具を押し流す。煙やインクのように渦を巻いて混ざり、残る。風で、止まった絵でも流れる")
        case .glitchBox: L("サーキットベンドしたアナログ映像機材のように絵を乱す。同期が外れて横に裂ける・縦に流れる・帯ごと跳ねる、色が遅れてにじむ、ゲインの入れすぎで明るい所が飽和して反転する、輪郭が二重に光る、色が虹色にうなる、砂嵐。FX パッドに入れて押している間だけ乱すのも合う")
        case .vhs: L("古いビデオテープの再生のように。トラッキングのノイズの帯が流れ、画面の下がずれてざらつき、絵がゆらゆら揺れ、色がにじんで色あせ、白い線（ドロップアウト）が走る")
        case .videoFeedback: L("カメラで、それを映しているモニターを撮ったように、前のコマを拡大・回転・色相ずれさせて重ね続ける。画面の中に画面が無限に続き、渦やトンネルが生まれる。暗い所を切り抜くと、そこから前の絵が見える")
        case .rasterScan: L("70 年代の映像シンセ（Rutt/Etra）のように、絵を横の走査線に分けて、明るい所ほど線を持ち上げる。映像が波打つ線の地形になる（まわりは透明）")
        case .crt: L("昔のブラウン管モニターに映したように。走査線・蛍光体の RGB の粒・画面のふくらみ・にじむ光・明るいものが尾を引く残光・まわりの暗さ。ほかのエフェクトの最後にかけると全体がモニターに映る")
        case .audioScope: L("音（上部の「音の入力」）の、周波数ごとの大きさ（スペクトラム）と波形を、そのまま絵にする。棒・線・波形・円（棒）・円（波形）（まわりは透明）")
        case .ndiIn: L("同じネットワークの別の Mac・PC（TouchDesigner・Resolume・OBS など）が NDI で出している映像を、クリップとして置く。映像の選び方はこの欄の下。NDI ランタイム（NDI Tools）が要る")
        case .camera: L("Web カメラ・HDMI キャプチャ・iPhone（連係カメラ）の映像を、クリップとして置く。カメラの選び方はこの欄の下")
        case .syphonIn: L("ほかのアプリ（TouchDesigner など）が Syphon で出している映像を、クリップとして置く。映像の選び方はこの欄の下（透明はそのまま）")
        case .tunnel: L("奥へ奥へと進んでいくトンネル。輪・格子・チェッカー・光の筋・もやの模様で、形は円・四角・六角・三角。回す・ねじる・うねって曲がる。奥は暗くなって透ける（まわりは透明）")
        case .warp: L("水の中・熱気・渦のように、絵をぬるぬるとゆがませる。ねばりを上げると、ゆがみがゆがみを呼んで生き物のような模様に。色のずれでふちが虹色ににじむ")
        case .school: L("イワシやムクドリのような群れ。1 匹ずつが、まわりに寄る・向きをそろえる・ぶつからないように間をあける、だけで動き、群れ全体がうねって形を変える。天敵から逃げると群れが割れてまた集まる。厚みで 3D になり、回るカメラから見る（まわりは透明）")
        case .dots: L("並べた粒（ラインの粒版）。形・並び・ばらつき・明滅、波で大きさが波打ち、奥への傾き・波の高さで 3D の点の雲になる。ふらふらで粒が自由に飛び回り、光のにじみで光る（ほたるのように。すき間は透明）")
        case .lines: L("等間隔の線（Arena の Lines のように）。本数は画面の高さに入る数、0° で縦の線。波で波形のようにうねり、奥への傾きで 3D の床・壁のようになる（すき間は透明）")
        case .phyllotaxis: L("ひまわりの種のように、粒が黄金角（137.5°）ずつ回りながら中心から生まれて外へ広がる。線の長さで棒に、色のばらつきでカラフルに（まわりは透明）")
        case .clock: L("今の時刻・決めた時刻までのカウントダウン・タイマー・ストップウォッチを出す。0 になったら好きな文字を出せる（まわりは透明）")
        case .text: L("文字を出す。流す・敷き詰める・1 文字ずつ・拍で弾む。行ごとに拍で切り替えも（まわりは透明）")
        case .shapeMask: L("四角・丸の形で切り抜く（外は透明）。位置や大きさを動かせる。反転すると中を隠す")
        case .polyMask: L("プレビューの上で点を置いて描いた形で切り抜く。建物や物に合わせるのに")
        case .echo: L("動いた跡が残像になって残る。レイヤーかコンポジションにかけると、位置や回転の動きも跡になる")
        case .strobe: L("BPM か秒に合わせて点滅させる（色で光る・消える・反転）。残光を上げると光ったあとすっと消える")
        case .posterizeTime: L("コマを間引いて、指定したフレームレートでしか動かないようにする（この段全体にかかる）")
        case .blendRefract: L("このレイヤーを透明なガラスにして、明るさの坂で下の絵を曲げて見せる。文字や図形が、映像の上を透明なまま流れる")
        case .blendLight: L("このレイヤーを光にして、下の絵を照らす。照らされていない所は暗く沈み、光はぼんやり広がる")
        case .blendFlow: L("このレイヤーの動き（または明るさ）で、下の絵を絵の具のように押し流してかき混ぜる。だんだん元の絵に戻る")
        case .blendInterfere: L("2 つの絵の明るさを波として重ね、ずれた所に動く縞（モアレ）を出す")
        case .blendBorrow: L("下の絵の明るさ（形）に、このレイヤーの色を借りて塗る。このレイヤーをパレットとして使うこともできる")
        case .blendDissolve: L("下の絵の暗い所（または明るい所・ノイズ）から順に、このレイヤーへ溶けていく。ふちは燃えるように光る")
        case .transitionMask: L("（内部用）")
        case .overdrive: L("下のレイヤーに加算して 100% を超えた分を、にじみ（ハレーション）・色相ずれ・波紋に変える")
        }
    }
}

/// ジェネレーター一覧の分類
enum GeneratorCategory: Int, CaseIterable, Identifiable {
    case color, pattern, shape, space, text, external
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .color: L("色・グラデーション")
        case .pattern: L("線・模様")
        case .shape: L("図形・粒")
        case .space: L("光・空間")
        case .text: L("文字・ロゴ・時計")
        case .external: L("ほかのアプリ・カメラから")
        }
    }
    /// この分類のジェネレーター（一覧に出す順）
    var kinds: [EffectKind] { EffectKind.generators.filter { $0.generatorCategory == self } }
}

extension EffectKind {
    /// ジェネレーターの分類（ジェネレーターでなければ nil）
    var generatorCategory: GeneratorCategory? {
        if let m = moreGeneratorCategory { return m }
        return switch self {
        case .solid, .gradient: .color
        case .lines, .dots, .stripes, .grid, .noise: .pattern
        case .shapes, .phyllotaxis, .flow, .school, .tunnel, .particleLife, .fireflies: .shape
        case .physarum, .attractor, .audioScope: .pattern
        case .text, .clock: .text
        case .syphonIn, .camera, .ndiIn: .external
        default: nil
        }
    }
}

/// エフェクト一覧の分類
enum EffectCategory: Int, CaseIterable, Identifiable {
    case color, light, shape, glitch, mask, time, retro, blend, generator
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .generator: L("ジェネレーター")
        case .color: L("色")
        case .light: L("光・ぼかし")
        case .shape: L("形")
        case .glitch: L("グリッチ・デジタル")
        case .mask: L("マスク")
        case .time: L("時間")
        case .retro: L("アナログ機材")
        case .blend: L("合成")
        }
    }
}

/// エフェクトの 1 つの値
extension EffectKind {
    /// ジェネレーターの見た目のひな形（押すと値をまとめてそろえる）
    struct GeneratorLook {
        let name: String
        let help: String
        let values: [Int: Double]
        var color: RGB? = nil
    }

    static let dotsLooks: [GeneratorLook] = [
        GeneratorLook(name: L("ほたる"), help: L("ばらばらの小さな光が、ふらふら自由に飛び回り、ゆっくり明滅する（黄緑の光）"),
                 values: [0: 5, 1: 8, 2: 0, 3: 2, 4: 0, 5: 0, 6: 1, 7: 0.6, 8: 0.9, 9: 0, 16: 0, 17: 1.5,
                          18: 0.9, 19: 0.35, 20: 0.8],
                 color: RGB(r: 0.78, g: 1.0, b: 0.35)),
        GeneratorLook(name: L("舞う粒"), help: L("細かい粒が少し上へ流れながら、ふわふわ漂う（ほこり・雪のように）"),
                 values: [0: 16, 1: 4, 2: 0, 3: 2, 4: 90, 5: 0.25, 6: 1, 7: 0.7, 8: 0.4, 9: 0, 16: 0, 17: 1,
                          18: 0.5, 19: 0.6, 20: 0.35]),
        GeneratorLook(name: L("格子"), help: L("まっすぐ並んだ粒（はじめの見た目）。波・3D はそのまま"),
                 values: [3: 0, 6: 0, 7: 0, 8: 0, 18: 0, 20: 0]),
    ]

    static let schoolLooks: [GeneratorLook] = [
        GeneratorLook(name: L("イワシ"), help: L("銀色の小魚の大きな群れ。向きを変えるとまとめてきらっと光り、天敵が来ると割れてまた集まる"),
                      values: [0: 1400, 1: 13, 2: 0, 3: 1, 4: 0.6, 5: 0.75, 6: 0.45, 7: 0.07, 8: 0.45, 9: 0.6, 10: 0.15,
                               11: 0.85, 12: 0.5, 13: 0, 14: 0.6, 15: 0],
                      color: RGB(r: 0.82, g: 0.9, b: 1.0)),
        GeneratorLook(name: L("ムクドリ"), help: L("小さな鳥の群れが空でうねる（羽ばたく。夕焼けの空の映像に重ねると合う）"),
                      values: [0: 2600, 1: 7, 2: 1, 3: 1.3, 4: 0.45, 5: 0.9, 6: 0.35, 7: 0.1, 8: 0.6, 9: 0.35, 10: 0.1,
                               11: 0, 12: 0.6, 13: 0, 14: 0.8, 15: 0]),
        GeneratorLook(name: L("ばらばら"), help: L("まとまらずに、思い思いに泳ぐ魚"),
                      values: [0: 300, 1: 22, 2: 0, 3: 0.6, 4: 0.1, 5: 0.15, 6: 0.6, 7: 0.06, 8: 0, 9: 0, 10: 0.7,
                               11: 0.3, 12: 0.5, 13: 1, 14: 0, 15: 0]),
        GeneratorLook(name: L("トルネード"), help: L("銀色の魚が、竜巻のように渦を巻いて回る（3D。下から見上げる）"),
                      values: [0: 2200, 1: 12, 2: 0, 3: 1, 4: 0.55, 5: 0.8, 6: 0.45, 7: 0.07, 8: 0.5, 9: 0, 10: 0.1,
                               11: 0.9, 12: 0.6, 13: 0, 14: 0.8, 15: 0.85, 16: 4, 18: -25, 19: 1.1, 20: 55],
                      color: RGB(r: 0.82, g: 0.9, b: 1.0)),
    ]

    static let tunnelLooks: [GeneratorLook] = [
        GeneratorLook(name: L("ワープ"), help: L("光の筋が奥から飛んでくる（宇宙をワープするように）"),
                      values: [0: 2.2, 1: 0, 2: 3, 3: 1.5, 4: 0.12, 5: 6, 6: 0, 7: 0.7, 8: 0.15, 12: 40, 13: 2, 14: 1.3, 15: 0.6]),
        GeneratorLook(name: L("ネオン"), help: L("パレットの色の輪が光りながら流れる、ゆるく曲がったトンネル"),
                      values: [0: 0.8, 1: 0, 2: 0, 3: 3, 4: 0.12, 5: 0, 6: 0, 7: 0.6, 8: 0.6, 9: 0.3, 13: 1, 14: 1.4, 15: 0.7]),
        GeneratorLook(name: L("格子の筒"), help: L("四角い格子の通路をまっすぐ進む（ワイヤーフレームのように）"),
                      values: [0: 1, 1: 1, 2: 1, 3: 3, 4: 0.06, 5: 0, 6: 0, 7: 0.8, 8: 0, 12: 8, 13: 0, 14: 1, 15: 0.4]),
        GeneratorLook(name: L("渦"), help: L("チェッカーがねじれながら回り、吸い込まれていく"),
                      values: [0: 1, 1: 0, 2: 2, 3: 2, 5: 40, 6: 0.8, 7: 0.5, 8: 0.3, 12: 16, 13: 2, 14: 1, 15: 0]),
        GeneratorLook(name: L("もやの洞窟"), help: L("やわらかいもやが流れる、六角の洞窟"),
                      values: [0: 0.6, 1: 2, 2: 4, 3: 2.5, 4: 0.5, 5: 8, 6: 0.2, 7: 0.4, 8: 0.8, 9: 0.25, 12: 10, 13: 1, 14: 1.2, 15: 0.2]),
    ]

    static let physarumLooks: [GeneratorLook] = [
        GeneratorLook(name: L("葉脈"), help: L("葉脈のような網の目が、ゆっくり組み替わる（はじめの見た目）"),
                      values: [0: 500_000, 1: 0.8, 2: 40, 3: 20, 4: 20, 5: 0.6, 6: 0.2, 7: 0.6, 9: 0, 11: 0.1]),
        GeneratorLook(name: L("細かい網"), help: L("とても細かい網がびっしり（レースや神経のように）"),
                      values: [0: 1_000_000, 1: 0.5, 2: 22.5, 3: 6, 4: 45, 5: 0.4, 6: 0.05, 7: 0.5, 9: 0, 11: 0.1]),
        GeneratorLook(name: L("細胞"), help: L("小さな丸い部屋がぎっしり並んで、泡や細胞のように"),
                      values: [0: 800_000, 1: 0.6, 2: 60, 3: 10, 4: 60, 5: 0.6, 6: 0.2, 7: 0.6, 9: 0, 11: 0.1]),
        GeneratorLook(name: L("太い川"), help: L("太い流れがうねって、川の地図のように"),
                      values: [0: 600_000, 1: 1, 2: 30, 3: 18, 4: 25, 5: 0.85, 6: 0.7, 7: 0.7, 9: 0, 11: 0.05]),
        GeneratorLook(name: L("えさをつなぐ"), help: L("動くえさの間を、網がつないでいく"),
                      values: [0: 500_000, 1: 0.8, 2: 40, 3: 20, 4: 20, 5: 0.7, 6: 0.2, 7: 0.6, 9: 1, 10: 0.8, 11: 0.1]),
    ]

    static let particleLifeLooks: [GeneratorLook] = [
        GeneratorLook(name: L("生き物"), help: L("細胞のようなかたまりが生まれて、追いかけ合う（はじめの見た目）"),
                      values: [0: 2000, 1: 6, 2: 1, 3: 0.09, 4: 1, 5: 0.5, 8: 0.3, 12: 0]),
        GeneratorLook(name: L("光の跡"), help: L("残像で、粒の通った道が光の線になる"),
                      values: [0: 1500, 1: 5, 2: 7, 3: 0.1, 4: 1.2, 5: 0.35, 7: 4, 8: 0.5, 12: 0.85]),
        GeneratorLook(name: L("拍で変身"), help: L("4 拍ごとに性格が入れ替わり、群れの形ががらっと変わる"),
                      values: [0: 2500, 1: 6, 3: 0.08, 4: 1, 5: 0.5, 10: 3, 12: 0.4]),
        GeneratorLook(name: L("大きな細胞"), help: L("粒を増やして、広く力の届く大きな構造に"),
                      values: [0: 5000, 1: 4, 2: 23, 3: 0.14, 4: 0.8, 5: 0.65, 7: 3, 8: 0.2, 12: 0]),
    ]

    static let fireflyLooks: [GeneratorLook] = [
        GeneratorLook(name: L("ばらばら"), help: L("そろわずに、それぞれが勝手に光る"),
                      values: [1: 0, 2: 0.25, 9: 0]),
        GeneratorLook(name: L("だんだんそろう"), help: L("近くどうしから合っていき、光の波が広がってやがて一斉に（はじめの見た目）"),
                      values: [1: 0.8, 2: 0.25, 4: 0.3, 9: 0]),
        GeneratorLook(name: L("一斉"), help: L("画面全体がすぐにそろって、ぱっ、ぱっと光る"),
                      values: [1: 2.5, 2: 1, 4: 0.15, 9: 0]),
        GeneratorLook(name: L("拍で光る"), help: L("BPM の拍の頭に向かってそろっていく"),
                      values: [1: 0.6, 2: 0.25, 9: 2, 10: 0.5]),
    ]

    static let attractorLooks: [GeneratorLook] = [
        GeneratorLook(name: L("絹"), help: L("クリフォード。薄い布が重なったような形（はじめの見た目）"),
                      values: [0: 0, 1: -1.4, 2: 1.6, 3: 1.0, 4: 0.7, 7: 1, 11: 1]),
        GeneratorLook(name: L("煙"), help: L("デ・ヨング。煙が巻いたような形"),
                      values: [0: 1, 1: -2.0, 2: -2.0, 3: -1.2, 4: 2.0, 7: 1.2, 11: 1]),
        GeneratorLook(name: L("迷路の糸"), help: L("トーマス（3D）。糸がからまった迷路が回る"),
                      values: [0: 2, 1: 0, 7: 1.4, 9: 1, 10: 10, 11: 2]),
        GeneratorLook(name: L("リンゴの芯"), help: L("アイザワ（3D）。リンゴの芯のような立体が回る"),
                      values: [0: 3, 1: 0, 2: 0, 3: 0, 4: 0, 7: 1.4, 9: 1, 10: 12, 11: 2]),
    ]

    /// この種類の見た目のひな形（無ければ空）
    var looks: [GeneratorLook] {
        switch self {
        case .dots: Self.dotsLooks
        case .school: Self.schoolLooks
        case .tunnel: Self.tunnelLooks
        case .physarum: Self.physarumLooks
        case .particleLife: Self.particleLifeLooks
        case .fireflies: Self.fireflyLooks
        case .attractor: Self.attractorLooks
        default: moreLooks
        }
    }
}

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
    /// サイコロ（値をランダムに）で変えない値（位置・大きさなどの形を決める値。保存しない）
    var noDice = false

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
        PalettePreset(name: L("白黒"), colors: [.black, .white]),
        PalettePreset(name: L("熱（サーモ）"), colors: [hex(0x000000), hex(0x3B0F70), hex(0xB5367A), hex(0xFB8761), hex(0xFCFDBF)]),
        PalettePreset(name: L("夕焼け"), colors: [hex(0x1A0533), hex(0x7B1E5A), hex(0xE2563B), hex(0xF7B538), hex(0xFFF1C1)]),
        PalettePreset(name: L("ネオン"), colors: [hex(0x0B0033), hex(0x6A00FF), hex(0xFF00C8), hex(0x00F0FF)]),
        PalettePreset(name: L("海"), colors: [hex(0x001021), hex(0x00487C), hex(0x0496FF), hex(0xA9F0FF)]),
        PalettePreset(name: L("セピア"), colors: [hex(0x1E1208), hex(0x704A2B), hex(0xC9A27A), hex(0xF6E7D2)]),
        PalettePreset(name: L("2 色（赤・青）"), colors: [hex(0x0A1AFF), hex(0xFF1A3C)]),
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
    /// テキストのジェネレーターの文字（改行で行を分ける）
    var text = TextLook.defaultText
    static let maxPalette = 8
    /// 値のアニメーション（キーは値の番号。不透明度は "mix"）
    var anims: [String: ParamAnim] = [:]
    /// エフェクトの不透明度（かかり具合）。0 = 元の絵のまま、1 = いっぱいにかかる
    var mix: Double = 1
    /// ジェネレーターの画質（0 = そのまま、1 = 3/4、2 = 半分の大きさで描いて引き伸ばす。GPU の負担を減らす）
    var quality = 0
    static let qualityLabels = [L("高（そのまま）"), L("中（3/4）"), L("低（半分）")]
    /// 描く大きさの倍率
    var qualityScale: Double { quality == 1 ? 0.75 : quality == 2 ? 0.5 : 1 }
    /// 画質を選べるか（ジェネレーターだけ。外の映像の取り込みは元の大きさのまま）
    var hasQuality: Bool { kind.isGenerator && ![.syphonIn, .camera, .ndiIn].contains(kind) }
    static let mixKey = "mix"
    /// 不透明度を出すエフェクトか（コマの間引き・重ね方の値には無い）
    var hasMix: Bool { kind != .posterizeTime && !kind.isBlend && !kind.isGenerator }

    var mixAnim: ParamAnim { anims[Self.mixKey] ?? ParamAnim(range: 0...1) }

    mutating func setMixAnim(_ a: ParamAnim) {
        var a = a
        if a.isOn && !(anims[Self.mixKey]?.isOn ?? false) { a.start = CACurrentMediaTime() }
        anims[Self.mixKey] = a
    }

    /// t の時点の不透明度（アニメーション込み）
    func mix(at t: Double, beat: BeatClock, origin: Double) -> Double {
        guard hasMix else { return 1 }
        let base = min(max(mix, 0), 1)
        guard let a = anims[Self.mixKey], a.isOn else { return base }
        return min(max(a.value(base: base, at: t, beat: beat, origin: origin), 0), 1)
    }

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
        // 新しく置くジェネレーターは画質「低」から（GPU の負担を減らす）。文字・時計はぼやけると読みにくいので「高」
        if hasQuality && !kind.isText && kind != .clock { quality = 2 }
        if kind == .strobe || kind.usesColor { color = .white }
        if kind == .gradient { palette = PalettePreset.all[3].colors }
        // 文字は暗い色だと沈むので、明るい色だけのパレット
        if kind == .phyllotaxis { color = RGB.hsb(0.11, 0.55, 1) }
        if kind == .clock { text = ClockText.defaultFinish; values[1] = 0.3; values[6] = 4 }
        if kind == .syphonIn || kind == .camera || kind == .ndiIn { text = "" }
        if kind == .fireflies { color = RGB(r: 0.78, g: 1.0, b: 0.35) }
        if kind == .physarum { color = RGB(r: 1.0, g: 0.85, b: 0.45) }
        if kind == .attractor || kind == .physarum || kind == .audioScope { palette = PalettePreset.all[1].colors }
        if kind.isText || kind == .tunnel || kind == .particleLife { palette = [PalettePreset.hex(0x6A00FF), PalettePreset.hex(0xFF00C8), PalettePreset.hex(0x00F0FF)] }
        if let c = kind.moreDefaultColor { color = c }
        if let p = kind.moreDefaultPalette { palette = p }
        if kind == .logoParticles { text = "HALO" }
    }

    /// 設定を最初の状態に戻したもの（オン／オフ・文字・自由な形の点はそのまま。描いた形や打った文字は中身なので残す）
    var reset: Effect {
        var e = Effect(kind: kind)
        e.id = id
        e.enabled = enabled
        e.text = text
        e.points = points
        return e
    }

    /// 最初の状態のままか（リセットしても変わらない）
    var isDefault: Bool { reset == self }

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

    enum CodingKeys: String, CodingKey { case id, kind, enabled, values, color, palette, anims, points, mix, text, quality }

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
        mix = try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? TextLook.defaultText
        quality = min(max(try c.decodeIfPresent(Int.self, forKey: .quality) ?? 0, 0), 2)
        // 値が足りない（あとから値が増えた）ときは初期値で埋める
        while values.count < kind.params.count { values.append(kind.params[values.count].defaultValue) }
        // 以前の「かかり具合」（反転・カラーライズ）は、エフェクトの不透明度に引き継ぐ（同じ働きなので 1 つにまとめた）
        if !c.contains(.mix), let k = kind.amountIndex, values.indices.contains(k) {
            mix = min(max(values[k], 0), 1)
            values[k] = 1
            if let a = anims[String(k)] { anims[Self.mixKey] = a; anims[String(k)] = nil }
        }
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
        // ジェネレーターの「速さ」は、動いた量（速さ × 経過時間）にして渡す
        if let si = kind.speedIndex, si < 8 {
            let moved = value(si, at: t, beat: beat, origin: origin) * max(t - origin, 0)
            v[si] = Float(moved.truncatingRemainder(dividingBy: 10000))
        }
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

    /// マスクを最後に回した並び（調整レイヤー用：マスクは「どこにかけるか」なので、並び順に関係なく全部のあとで切り抜く）
    var masksLast: EffectStack {
        var s = self
        let isMask: (Effect) -> Bool = { $0.kind == .shapeMask || $0.kind == .polyMask }
        s.effects = effects.filter { !isMask($0) } + effects.filter(isMask)
        return s
    }

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
