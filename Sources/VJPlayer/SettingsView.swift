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
            Section("画面") {
                FlashSetting()
            }
            Section("アップデート") {
                UpdateSettingsSection()
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

/// クリップ・レイヤーを選んでパラメーターのパネルが切り替わったとき、縁を光らせるか
private struct FlashSetting: View {
    @AppStorage("flashOnSelect") private var flashOnSelect = true
    @AppStorage("flashOnOutput") private var flashOnOutput = true
    var body: some View {
        Toggle("パラメーターのパネルが切り替わったら、縁を一瞬光らせる", isOn: $flashOnSelect)
        Text("コンポジションはオレンジ・レイヤーは青・クリップは緑で光り、何に切り替わったかが右上に出る")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("出力が切り替わったら、出力モニターを一瞬光らせる", isOn: $flashOnOutput)
        Text("クリップは緑・シーンは紫・止めたときは灰色で光り、何に変わったかが左上に出る（自動操縦が変えたときは飛行機の印）")
            .font(.caption).foregroundStyle(.secondary)
    }
}
