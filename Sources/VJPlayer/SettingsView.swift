import SwiftUI

/// 設定ウィンドウ（⌘,）。ショーの前に決めておく値を置く。本番中に触る値はメイン画面に置く。
struct SettingsView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        Form {
            Section(L("出力の解像度・フレームレート")) {
                OutputFormatControls()
            }
            Section(L("ブラックアウト")) {
                SecondsSlider(label: L("暗くなるまで"), value: $engine.blackoutFadeOut)
                SecondsSlider(label: L("解除して戻るまで"), value: $engine.blackoutFadeIn)
                Text(L("映像と音の両方にかかります。フェード中にもう一度押すと、その位置から引き返します。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("画面")) {
                LanguageSetting()
                FlashSetting()
            }
            Section(L("アップデート")) {
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

/// 画面の言語。このアプリだけの AppleLanguages を書き換える（開き直すと切り替わる）
private struct LanguageSetting: View {
    @State private var choice = LanguageSetting.saved
    @State private var changed = false

    /// 選んでいる言語（"" = Mac の設定に合わせる）
    static var saved: String {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        return (domain?["AppleLanguages"] as? [String])?.first ?? ""
    }

    var body: some View {
        Picker(L("言語"), selection: $choice) {
            Text(L("Mac の設定に合わせる")).tag("")
            // 言語の名前は、その言語で書く（どちらの言語のときも読めるように）
            Text(verbatim: "日本語").tag("ja")
            Text(verbatim: "English").tag("en")
        }
        .onChange(of: choice) { _, v in
            if v.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([v], forKey: "AppleLanguages")
            }
            changed = true
        }
        if changed {
            HStack {
                Text(L("次に開いたときから切り替わります"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("今すぐ開き直す")) { AppRelaunch.now() }
            }
        }
    }
}

/// アプリを閉じて開き直す（言語の切り替えなど）
enum AppRelaunch {
    static var requested = false

    /// ふつうに終了する（未保存なら保存するか聞く）。やめたら何もしない
    static func now() {
        requested = true
        NSApp.terminate(nil)
        // ここまで来たら終了をやめた（保存の確認でキャンセル）
        requested = false
    }

    /// 終了の直前に呼ぶ：このプロセスが終わるのを待ってから、もう一度開く
    static func openAfterExit() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
    }
}

/// クリップ・レイヤーを選んでパラメーターのパネルが切り替わったとき、縁を光らせるか
private struct FlashSetting: View {
    @AppStorage("flashOnSelect") private var flashOnSelect = true
    @AppStorage("flashOnOutput") private var flashOnOutput = true
    var body: some View {
        Toggle(L("パラメーターのパネルが切り替わったら、縁を一瞬光らせる"), isOn: $flashOnSelect)
        Text(L("コンポジションはオレンジ・レイヤーは青・クリップは緑で光り、何に切り替わったかが右上に出る"))
            .font(.caption).foregroundStyle(.secondary)
        Toggle(L("出力が切り替わったら、出力モニターを一瞬光らせる"), isOn: $flashOnOutput)
        Text(L("クリップは緑・シーンは紫・止めたときは灰色で光り、何に変わったかが左上に出る（自動操縦が変えたときは飛行機の印）"))
            .font(.caption).foregroundStyle(.secondary)
    }
}
