import Foundation
import QuartzCore
import AppKit
import SwiftUI

// サイコロ：エフェクト・ジェネレーターの値をランダムにする（カードの見出しのボタン）。
// 変えないもの：オン／オフの値・動き（アニメーション）を付けた値・形を決める値（noDice）・
// 不透明度・画質・文字・入力の選択。色は色相だけを変える（白・黒・灰はそのまま）。

extension EffectKind {
    /// サイコロのボタンを出すか（外からの映像・文字は、ランダムにしても意味がない）
    var hasDice: Bool { ![.camera, .syphonIn, .ndiIn, .text, .clock].contains(self) && !isBlend && self != .transitionMask }

    /// 名前で決める「サイコロで変えない値」。元の絵を混ぜる量（不透明度と同じ働き）と、真ん中・位置。
    /// （あとから足した種類にも効くように、番号ではなく名前で見る）
    static var noDiceLabels: Set<String> {
        [L("元の絵"), L("下に元の絵"), L("元の色を残す"), L("上の絵も見せる"),
         L("中心の左右"), L("中心の上下"), L("位置 X"), L("位置 Y"), L("フォント")]
    }

    /// i 番目の値をサイコロで変えてよいか（動きを付けているかは見ない）
    func diceable(_ i: Int) -> Bool {
        let ps = params
        guard ps.indices.contains(i) else { return false }
        let p = ps[i]
        if p.isToggle || p.noDice || i == amountIndex { return false }
        return !Self.noDiceLabels.contains(p.label)
    }

    /// サイコロで色を変えるか（色を使う種類だけ）
    var dicesColor: Bool { usesColor || isMore || self == .colorize || self == .strobe }
}

extension Effect {
    /// サイコロで変えてよい値の番号（動きを付けている値は除く）
    var diceIndices: [Int] {
        kind.params.indices.filter { kind.diceable($0) && !(anims[String($0)]?.isOn ?? false) }
    }

    /// サイコロを振ったもの（slight：今の値から少しだけ動かす）。乱数を渡せるのでテストで同じ結果を出せる
    func diced<G: RandomNumberGenerator>(using rng: inout G, slight: Bool = false) -> Effect {
        var e = self
        let ps = kind.params
        while e.values.count < ps.count { e.values.append(ps[e.values.count].defaultValue) }
        for i in diceIndices {
            let p = ps[i]
            if let choices = p.choices {
                // 選択肢は、少しだけのときは変えない
                guard !slight, !choices.isEmpty else { continue }
                let hi = min(choices.count - 1, Int(p.range.upperBound.rounded(.down)))
                let lo = max(0, Int(p.range.lowerBound.rounded(.up)))
                guard hi >= lo else { continue }
                e.values[i] = Double(Int.random(in: lo...hi, using: &rng))
                continue
            }
            let r = p.animRange.map { $0.clamped(to: p.range) } ?? p.range
            var v: Double
            if slight {
                let w = (r.upperBound - r.lowerBound) * 0.15
                v = value(i) + (w > 0 ? Double.random(in: -w...w, using: &rng) : 0)
                if p.range == 0...360 { v = v.truncatingRemainder(dividingBy: 360); if v < 0 { v += 360 } }
            } else {
                v = r.lowerBound < r.upperBound ? Double.random(in: r, using: &rng) : r.lowerBound
            }
            v = min(max(v, p.range.lowerBound), p.range.upperBound)
            if p.step > 0 {
                v = (v / p.step).rounded() * p.step
                // 丸めて範囲の外に出たら、内側の段へ
                if v > p.range.upperBound { v -= p.step }
                if v < p.range.lowerBound { v += p.step }
            }
            e.values[i] = v
        }
        if kind.dicesColor {
            let (h, s, b) = color.hsb
            // 白・黒・灰（色みが無い）はそのまま
            if s > 0.02 && b > 0.02 {
                let nh = slight ? h + Double.random(in: -0.15...0.15, using: &rng) : Double.random(in: 0..<1, using: &rng)
                e.color = RGB.hsb(nh - floor(nh), s, b)
            }
        }
        return e
    }

    /// サイコロを振ったもの（ふだんの乱数）
    func diced(slight: Bool = false) -> Effect {
        var g = SystemRandomNumberGenerator()
        return diced(using: &g, slight: slight)
    }
}

/// 種から決まる乱数（テストで同じ結果を出す用）
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// カードのサイコロのボタン。押すと 1 回振る（⌥ を押しながら・「少しだけ」の設定なら少しだけ）。
/// 横の ▾ で、自動で振る・変え方・つなぎのパネル（DicePanel）を開く
struct EffectDiceButton: View {
    @Binding var effect: Effect
    @State private var open = false

    var body: some View {
        let on = effect.autoDice?.isOn == true
        HStack(spacing: 0) {
            Button {
                let slight = NSEvent.modifierFlags.contains(.option) || effect.autoDice?.slight == true
                EffectCardStep.roll(&effect, slight: slight)
            } label: {
                Image(systemName: on ? "dice.fill" : "dice")
                    .foregroundStyle(on ? Color.orange : Color.primary)
                    .frame(width: 18)
            }
            // メニューの形のボタン・見出しの .onDrag の中では .help の説明が出ないことがあるので、自前の小さな説明を出す
            .hoverTip(effect.diceHelp)
            .accessibilityLabel(L("サイコロ"))
            Button { open.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(open ? Color.primary : Color.secondary)
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("自動で振る（拍・音）・変え方・つなぎ"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                DicePanel(effect: $effect)
                    .frame(width: 320)
                    .padding(10)
            }
        }
        .fixedSize()
    }

    /// 自動の設定を変える（元に戻すの 1 歩）。しない・ほかも最初のままなら nil にする
    static func setAuto(_ effect: Binding<Effect>, engine: Engine = .shared, _ f: @escaping (inout AutoDice) -> Void) {
        var e = effect.wrappedValue
        EffectCardStep.change(&e, engine: engine) { Self.settingAuto($0, f) }
        if e != effect.wrappedValue { effect.wrappedValue = e }
    }

    /// 自動の設定を変えたもの（純粋な計算。テスト用にも）
    static func settingAuto(_ e: Effect, _ f: (inout AutoDice) -> Void) -> Effect {
        var e = e
        var a = e.autoDice ?? AutoDice(mode: .off)
        f(&a)
        e.autoDice = a.isPlain ? nil : a
        return e
    }
}

/// カードの見出しのボタンでの変更を、元に戻す（⌘Z）の 1 歩にする
enum EffectCardStep {
    static func change(_ effect: inout Effect, engine: Engine = .shared, _ f: (Effect) -> Effect) {
        // 前の変更（つまみのドラッグなど）と混ざらないように、待っている変更を先に 1 歩にする
        engine.commitUndoStep()
        let e = f(effect)
        if e != effect { effect = e }
    }

    /// 手でサイコロを 1 回振る（元に戻すの 1 歩。つなぎの設定があれば、今の BPM でつなぐ）
    static func roll(_ effect: inout Effect, slight: Bool, engine: Engine = .shared) {
        let g = effect.autoDice?.glideSeconds(bpm: engine.bpm) ?? 0
        let now = CACurrentMediaTime()
        change(&effect, engine: engine) { e in
            var rng = SystemRandomNumberGenerator()
            return e.rolled(using: &rng, slight: slight, glideSeconds: g, at: now)
        }
    }
}

/// カーソルを合わせて少し待つと、そばに小さな説明を出す（KindPreviewPanel と同じ出し方）。
/// SwiftUI の .help は、メニュー（Menu）のボタンなど AppKit の部品では出ないことがあるので、その代わり
final class HoverTipPanel {
    static let shared = HoverTipPanel()
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var showingID: UUID?
    private var clickMonitor: Any?
    /// 今出している（出そうとしている）説明。テストで中身を確かめる
    private(set) var text: String?

    func hover(_ id: UUID, _ text: String) {
        pending?.cancel()
        self.text = text
        let w = DispatchWorkItem { [weak self] in self?.present(id, text) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    func leave(_ id: UUID) {
        pending?.cancel()
        guard showingID == id || showingID == nil else { return }
        hide()
    }

    func hide() {
        pending?.cancel()
        showingID = nil
        text = nil
        panel?.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    private func present(_ id: UUID, _ text: String) {
        showingID = id
        let view = Text(text).font(.system(size: 11)).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.18))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.15))))
            .environment(\.colorScheme, .dark)
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.ignoresMouseEvents = true
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = true
            p.backgroundColor = .clear
            p.isOpaque = false
            return p
        }()
        let host = NSHostingView(rootView: AnyView(view))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        p.contentView = host
        // カーソルの下に。画面からはみ出すなら内側へ
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(m) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var o = NSPoint(x: m.x - size.width / 2, y: m.y - 22 - size.height)
        if o.y < screen.minY { o.y = m.y + 18 }
        o.x = max(screen.minX, min(o.x, screen.maxX - size.width))
        p.setFrame(NSRect(origin: o, size: size), display: true)
        panel = p
        p.orderFrontRegardless()
        // 押したら（メニューを開いたら）消す
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
                self?.hide()
                return e
            }
        }
    }
}

extension View {
    /// カーソルを合わせて少し待つと、そばに小さな説明を出す（.help が出ない部品の代わり）
    func hoverTip(_ text: String) -> some View {
        modifier(HoverTipModifier(text: text))
    }
}

private struct HoverTipModifier: ViewModifier {
    let text: String
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { HoverTipPanel.shared.hover(id, text) } else { HoverTipPanel.shared.leave(id) }
            }
            .onDisappear { HoverTipPanel.shared.leave(id) }
            .accessibilityHint(text)
    }
}
