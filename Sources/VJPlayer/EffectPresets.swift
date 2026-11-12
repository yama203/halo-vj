import Foundation
import QuartzCore
import SwiftUI

// エフェクトのプリセット：値の組に名前を付けて覚えておき、あとで同じ種類のカードに入れる。
// プロジェクトではなくアプリ共通（どのプロジェクトでも使える）。
// 保存先は ~/Library/Application Support/Halo VJ/effect-presets.json。
// VJ_STATE_PATH があるときはその隣、開発用の書き出し・セルフテストではファイルに触れない（覚えるだけ）。

/// 1 つのプリセット
struct EffectPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// 覚えた中身（使うのは値・色・パレット・動き・サイコロの自動の設定だけ）
    var effect: Effect
}

final class EffectPresets: ObservableObject {
    static let shared = EffectPresets(url: defaultURL)

    /// 保存先（nil ならファイルに書かない）
    let url: URL?
    @Published private(set) var all: [EffectPreset] = []

    init(url: URL?) {
        self.url = url
        all = Self.read(url) ?? []
    }

    static var defaultURL: URL? {
        let env = ProcessInfo.processInfo.environment
        // 画面確認用の別の保存ファイルを使っているときは、その隣に（ふだんのプリセットに触れない）
        if let p = env["VJ_STATE_PATH"] {
            return URL(fileURLWithPath: p).deletingLastPathComponent().appendingPathComponent("effect-presets.json")
        }
        // 開発用の書き出し・セルフテストでは、利用者のファイルを読み書きしない
        if isDevRun { return nil }
        return AppInfo.supportDirectory.appendingPathComponent("effect-presets.json")
    }

    /// 開発用の書き出し・セルフテストの起動か（このときは利用者のファイル・設定を読み書きしない。お気に入りも同じ判定）
    static var isDevRun: Bool {
        let args = CommandLine.arguments.dropFirst()
        return args.contains { $0 == "--selftest" || $0 == "--od-bench" || $0 == "--kind-sheet" || $0.hasSuffix("-preview") }
    }

    /// ファイルを読む（無い・壊れているときは nil。壊れたファイルは、次に保存するまでそのまま）
    private static func read(_ url: URL?) -> [EffectPreset]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([EffectPreset].self, from: data)
    }

    private func write() {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// この種類のプリセット（名前の順）
    func list(for kind: EffectKind) -> [EffectPreset] {
        all.filter { $0.effect.kind == kind }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 今の値を名前を付けて覚える。同じ種類・同じ名前があれば上書き。名前が空なら「プリセット 1」のように番号を振る
    @discardableResult
    func save(name: String, effect: Effect) -> EffectPreset {
        // ほかの窓（別に開いたアプリ）で足したものを消さないように、読み直してから足す
        if let disk = Self.read(url) { all = disk }
        let kind = effect.kind
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let used = Set(list(for: kind).map(\.name))
            var n = 1
            while used.contains(L("プリセット \(n)")) { n += 1 }
            name = L("プリセット \(n)")
        }
        // 覚えるのは、別のカードに入れて同じ絵になるものだけ（オン/オフ・不透明度・画質・文字などはカードのもの）
        var e = Effect(kind: kind)
        e.values = effect.values
        e.color = effect.color
        e.palette = effect.palette
        e.anims = effect.anims.filter { $0.key != Effect.mixKey }
        // サイコロの自動の設定も（値の組と一緒に、動き方も呼び出せるように）
        e.autoDice = effect.autoDice
        if let i = all.firstIndex(where: { $0.effect.kind == kind && $0.name == name }) {
            all[i].effect = e
            write()
            return all[i]
        }
        let p = EffectPreset(name: name, effect: e)
        all.append(p)
        write()
        return p
    }

    func delete(_ id: UUID) {
        if let disk = Self.read(url) { all = disk }
        all.removeAll { $0.id == id }
        write()
    }

    /// プリセットを effect に入れたもの（id・オン/オフ・不透明度・画質・文字などはそのまま）。
    /// 値の数が合わないとき（あとで値が増えた・減った）は、足りない分は今の値のまま、多い分は捨てる
    func apply(_ preset: EffectPreset, to effect: Effect) -> Effect {
        Self.apply(preset, to: effect)
    }

    static func apply(_ preset: EffectPreset, to effect: Effect) -> Effect {
        var e = effect
        let src = preset.effect
        guard src.kind == e.kind else { return e }
        let n = e.kind.params.count
        while e.values.count < n { e.values.append(e.kind.params[e.values.count].defaultValue) }
        for i in 0..<min(n, src.values.count) { e.values[i] = src.values[i] }
        e.color = src.color
        e.palette = src.palette.isEmpty ? e.palette : src.palette
        // 動き：プリセットの割り当てに置き換える（不透明度の動きはカードのもの）
        let now = CACurrentMediaTime()
        var anims = e.anims.filter { $0.key == Effect.mixKey }
        for (k, a) in src.anims where k != Effect.mixKey {
            guard let i = Int(k), i >= 0, i < n else { continue }
            var a = a
            a.start = now
            anims[k] = a
        }
        e.anims = anims
        e.autoDice = src.autoDice
        e.diceGlide = DiceGlide()
        return e
    }
}

extension EffectKind {
    /// プリセットのメニューを出すか（外からの映像は、入力の選び方しか無いので出さない）
    var hasPresets: Bool { ![.camera, .syphonIn, .ndiIn].contains(self) && !isBlend && self != .transitionMask }
}

/// カードの見出しのプリセットのメニュー（選ぶと値が入る・今の値を保存・消す）
struct EffectPresetMenu: View {
    @Binding var effect: Effect
    @ObservedObject private var presets = EffectPresets.shared

    var body: some View {
        let list = presets.list(for: effect.kind)
        if effect.kind.hasPresets {
        Menu {
            if list.isEmpty {
                Text(L("まだプリセットはありません"))
            } else {
                ForEach(list) { p in
                    Button(p.name) { EffectCardStep.change(&effect) { presets.apply(p, to: $0) } }
                }
            }
            Divider()
            Button(L("今の値を保存…")) {
                if let name = askText(title: L("プリセットの名前（「\(effect.kind.label)」のプリセット。空なら番号）"), initial: "") {
                    presets.save(name: name, effect: effect)
                }
            }
            if !list.isEmpty {
                Menu(L("プリセットを消す")) {
                    ForEach(list) { p in
                        Button(p.name) { presets.delete(p.id) }
                    }
                }
            }
        } label: {
            Image(systemName: list.isEmpty ? "bookmark" : "bookmark.fill").frame(width: 18)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("プリセット（値の組を名前で保存・呼び出す）"))
        }
    }
}
