import Foundation

// 画面の文言の翻訳。
//
// 文言は日本語のまま L("…") で包む。日本語がそのまま見出し（キー）になり、
// 英語の Mac では Resources/en.lproj/Localizable.strings の訳を出す（無ければ日本語のまま）。
//
//   L("ブラックアウト")                → "Blackout"
//   L("選んだ \(n) 個を削除…")         → キーは "選んだ %@ 個を削除…"。訳は "Delete %@ Selected…"
//                                        （順番を入れ替えるときは %1$@ %2$@）
//   String(format: L("クリップ %.3fx"), v) → 書式の文字列ごと訳す
//
// 訳が抜けている文言は tools/i18n_check.py で一覧にできる。
// `swift run`（.app の外）では訳の表が無いので、いつも日本語。

func L(_ key: LocalizedKey) -> String {
    let format = Bundle.main.localizedString(forKey: key.key, value: nil, table: nil)
    if key.args.isEmpty { return format }
    return String(format: format, arguments: key.args.map { $0 as CVarArg })
}

/// 同じ日本語でも場所によって訳を変えたいとき：L("出す", note: "動詞") は見出し "出す#動詞" の訳を出す。
/// その訳が無ければ（日本語の Mac も）、ふつうの L("出す") と同じ
func L(_ key: LocalizedKey, note: String) -> String {
    let missing = "\u{0}"
    let s = Bundle.main.localizedString(forKey: key.key + "#" + note, value: missing, table: nil)
    if s == missing { return L(key) }
    if key.args.isEmpty { return s }
    return String(format: s, arguments: key.args.map { $0 as CVarArg })
}

/// L("…") の中身。文字列の中の \(…) を %@ にしたものを見出しにして、値は後から差し込む
struct LocalizedKey: ExpressibleByStringInterpolation {
    let key: String
    let args: [String]

    init(stringLiteral value: String) {
        key = value
        args = []
    }

    init(stringInterpolation s: Interpolation) {
        // 値が入るときは String(format:) を通すので、文の中の % は %% にしておく
        key = s.args.isEmpty ? s.raw : s.escaped
        args = s.args
    }

    struct Interpolation: StringInterpolationProtocol {
        var raw = ""
        var escaped = ""
        var args: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {}

        mutating func appendLiteral(_ literal: String) {
            raw += literal
            escaped += literal.replacingOccurrences(of: "%", with: "%%")
        }

        mutating func appendInterpolation<T>(_ value: T) {
            raw += "%@"
            escaped += "%@"
            args.append(String(describing: value))
        }

        mutating func appendInterpolation(_ value: String) {
            raw += "%@"
            escaped += "%@"
            args.append(value)
        }

        /// SwiftUI の Text と同じ書き方：\(v, specifier: "%.1f")
        mutating func appendInterpolation<T: CVarArg>(_ value: T, specifier: String) {
            appendInterpolation(String(format: specifier, value))
        }
    }
}
