import Foundation
import SwiftUI
import AppKit
import simd

/// 出力の解像度とフレームレート（Arena のコンポジションの大きさ・フレームレートと同じ考え方）。プロジェクトに保存する
struct OutputFormat: Codable, Equatable {
    /// 合成する大きさ（px）。0 なら出力先（ディスプレイ）の大きさに合わせる
    var width = 0
    var height = 0
    /// 描く回数（1 秒あたり）。0 ならディスプレイのリフレッシュレートに合わせる
    var fps = 0.0
    /// 縦横比が出力先と違うときの合わせ方
    var fit = Fit.fit

    enum Fit: Int, Codable, CaseIterable, Identifiable {
        /// 全体が入るように（余りは黒）
        case fit
        /// 画面いっぱいに（はみ出した所は切れる）
        case fill
        /// 縦横比を変えて画面いっぱいに
        case stretch
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .fit: "収める（黒帯）"
            case .fill: "いっぱいに（切れる）"
            case .stretch: "引き伸ばす"
            }
        }
    }

    /// 出力先に合わせるか
    var isAuto: Bool { width <= 0 || height <= 0 }
    var size: (Int, Int)? { isAuto ? nil : (width, height) }
    var aspect: Double? { isAuto ? nil : Double(width) / Double(height) }

    static let maxSide = 8192

    struct Preset: Identifiable {
        let label: String
        let width: Int
        let height: Int
        var id: String { "\(width)x\(height)" }
    }

    static let presets: [Preset] = [
        Preset(label: "HD", width: 1280, height: 720),
        Preset(label: "フル HD", width: 1920, height: 1080),
        Preset(label: "WUXGA", width: 1920, height: 1200),
        Preset(label: "2.5K", width: 2560, height: 1440),
        Preset(label: "4K", width: 3840, height: 2160),
        Preset(label: "縦（スマホ）", width: 1080, height: 1920),
        Preset(label: "正方形", width: 1080, height: 1080),
        Preset(label: "XGA（4:3）", width: 1024, height: 768),
    ]

    /// フレームレートの選択肢（0 = ディスプレイに合わせる）
    static let fpsChoices: [Double] = [0, 24, 25, 30, 50, 60]

    static func fpsLabel(_ f: Double) -> String {
        f <= 0 ? "ディスプレイに合わせる" : (f == f.rounded() ? String(format: "%.0f fps", f) : String(format: "%.2f fps", f))
    }

    /// 短い説明（上のバー用）
    var summary: String {
        (isAuto ? "出力先の大きさ" : "\(width)×\(height)") + " · " + (fps <= 0 ? "ディスプレイ" : String(format: "%g fps", fps))
    }

    /// 出力先（縦横比 screenAspect）の座標 0〜1 → 合成の絵が入る枠の中の座標 0〜1 への変換（コーナーピンの前にかける）
    func fitMatrix(screenAspect: Double) -> simd_float3x3 {
        guard let a = aspect, screenAspect > 0, fit != .stretch, abs(a - screenAspect) > 1e-4 else {
            return matrix_identity_float3x3
        }
        // 合成の絵が出力先の中で占める大きさ（1 = いっぱい）
        var sx = 1.0, sy = 1.0
        let wider = a > screenAspect
        if (fit == .fit) == wider { sy = screenAspect / a } else { sx = a / screenAspect }
        let ox = (1 - sx) / 2, oy = (1 - sy) / 2
        return simd_float3x3(columns: (SIMD3(Float(1 / sx), 0, 0), SIMD3(0, Float(1 / sy), 0),
                                       SIMD3(Float(-ox / sx), Float(-oy / sy), 1)))
    }
}

/// フレームレートを落とすときの、描くコマの選び方（ディスプレイの vsync ごとに呼ぶ）
struct FrameGate {
    private var nextDue = 0.0

    /// now に描くか。fps が 0 なら毎回描く。halfPeriod は vsync の間隔の半分（このくらい早くても描く）
    mutating func shouldRender(now: Double, fps: Double, halfPeriod: Double) -> Bool {
        guard fps > 0 else { nextDue = 0; return true }
        let period = 1 / fps
        if nextDue > 0 && now + halfPeriod < nextDue { return false }
        // 遅れすぎ（止まっていた・ディスプレイより速い fps）なら数え直す。そうでなければ等間隔に進める
        nextDue = (nextDue == 0 || now - nextDue > period) ? now + period : nextDue + period
        return true
    }
}

/// 出力の解像度・合わせ方・フレームレートの設定（設定ウィンドウと上のバーのポップオーバーで使う）
struct OutputFormatControls: View {
    @EnvironmentObject var engine: Engine
    @State private var customW = ""
    @State private var customH = ""
    @State private var custom = false

    private var format: OutputFormat { engine.outputFormat }

    /// 選んでいる解像度（"auto"・プリセットの id・"custom"）
    private var sizeTag: Binding<String> {
        Binding(get: {
            if custom { return "custom" }
            if format.isAuto { return "auto" }
            return OutputFormat.presets.first { $0.width == format.width && $0.height == format.height }?.id ?? "custom"
        }, set: { tag in
            var f = format
            switch tag {
            case "auto":
                custom = false
                f.width = 0; f.height = 0
            case "custom":
                custom = true
                let (w, h) = engine.compositionSize
                customW = String(w); customH = String(h)
                f.width = w; f.height = h
            default:
                custom = false
                if let p = OutputFormat.presets.first(where: { $0.id == tag }) { f.width = p.width; f.height = p.height }
            }
            engine.outputFormat = f
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("解像度", selection: sizeTag) {
                Text("出力先に合わせる").tag("auto")
                Divider()
                ForEach(OutputFormat.presets) { p in
                    Text("\(p.width) × \(p.height)（\(p.label)）").tag(p.id)
                }
                Divider()
                Text("指定する…").tag("custom")
            }
            if sizeTag.wrappedValue == "custom" {
                HStack(spacing: 6) {
                    TextField("幅", text: $customW).frame(width: 70).onSubmit(applyCustom)
                    Text("×")
                    TextField("高さ", text: $customH).frame(width: 70).onSubmit(applyCustom)
                    Text("px").foregroundStyle(.secondary)
                    Button("決定", action: applyCustom)
                }
                .padding(.leading, 70)
            }
            if !format.isAuto {
                Picker("出力先との合わせ方", selection: Binding(get: { format.fit },
                                                         set: { var f = format; f.fit = $0; engine.outputFormat = f })) {
                    ForEach(OutputFormat.Fit.allCases) { Text($0.label).tag($0) }
                }
                .help("出力先（ディスプレイ）と縦横比が違うとき")
            }
            Picker("フレームレート", selection: Binding(get: { format.fps },
                                                 set: { var f = format; f.fps = $0; engine.outputFormat = f })) {
                ForEach(OutputFormat.fpsChoices, id: \.self) { Text(OutputFormat.fpsLabel($0)).tag($0) }
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if !format.isAuto && !OutputFormat.presets.contains(where: { $0.width == format.width && $0.height == format.height }) {
                custom = true
            }
            customW = String(engine.compositionSize.0); customH = String(engine.compositionSize.1)
        }
    }

    private var explanation: String {
        let (w, h) = engine.compositionSize
        let size = format.isAuto
            ? "今は \(w) × \(h) で合成（出力先の縦横比・高さ 1080）。"
            : "\(w) × \(h) で合成して、出力先の大きさに拡大・縮小して出す。"
        let fps = format.fps <= 0 ? "ディスプレイの vsync ごとに描く。" : String(format: "1 秒に %g 回だけ描く（あいだは前の絵のまま。操作画面のプレビューも同じ）。", format.fps)
        return size + fps + "プロジェクトに保存される。"
    }

    private func applyCustom() {
        guard let w = Int(customW.trimmingCharacters(in: .whitespaces)), let h = Int(customH.trimmingCharacters(in: .whitespaces)),
              w >= 16, h >= 16 else { NSSound.beep(); return }
        var f = format
        f.width = min(w, OutputFormat.maxSide); f.height = min(h, OutputFormat.maxSide)
        customW = String(f.width); customH = String(f.height)
        engine.outputFormat = f
    }
}

/// 上のバーの「解像度・fps」ボタン（押すと設定のポップオーバー）
struct OutputFormatButton: View {
    @EnvironmentObject var engine: Engine
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label(engine.outputFormat.isAuto && engine.outputFormat.fps <= 0
                  ? "解像度・fps" : engine.outputFormat.summary, systemImage: "aspectratio")
                .lineLimit(1)
        }
        .help("出力の解像度とフレームレート：" + engine.outputFormat.summary)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            OutputFormatControls()
                .padding(16)
                .frame(width: 420)
        }
    }
}
