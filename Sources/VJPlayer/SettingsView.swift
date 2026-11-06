import SwiftUI

/// 設定ウィンドウ（⌘,）。ショーの前に決めておく値を置く。本番中に触る値はメイン画面に置く。
struct SettingsView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        Form {
            Section("出力の解像度・フレームレート") {
                OutputFormatControls()
            }
            Section("ブラックアウト") {
                SecondsSlider(label: "暗くなるまで", value: $engine.blackoutFadeOut)
                SecondsSlider(label: "解除して戻るまで", value: $engine.blackoutFadeIn)
                Text("映像と音の両方にかかります。フェード中にもう一度押すと、その位置から引き返します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 0〜5 秒のスライダー＋数値
private struct SecondsSlider: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                Slider(value: $value, in: 0...5, step: 0.05)
                    .frame(width: 180)
                Text(fadeSeconds(value))
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }
}
