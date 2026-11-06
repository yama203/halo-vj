import SwiftUI

/// アニメーションを付けられる数値欄。右のボタンで「動かし方」の設定を開く。
/// 動かしている間は欄に今の値が出続ける（手では動かせない）
struct AnimValueField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let perPoint: Double
    let defaultValue: Double
    var showsBar = false
    let format: (Double) -> String
    @Binding var anim: ParamAnim
    /// 秒モードの基準時刻
    var origin: Double = 0
    /// アニメーションの範囲を戻すときの値
    let animDefault: ClosedRange<Double>
    @EnvironmentObject var engine: Engine
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ValueDrag(label: label, value: $value, range: range, perPoint: perPoint, defaultValue: defaultValue,
                          showsBar: showsBar, format: format, live: anim.isOn ? liveValue() : nil,
                          badge: anim.summary)
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(anim.isOn ? Color.purple : (expanded ? Color.primary : Color.secondary))
                        .frame(width: 30, height: UI.rowHeight)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(expanded ? Color.white.opacity(0.12) : Color.white.opacity(0.04)))
                }
                .buttonStyle(.plain)
                .help("動かし方（固定／秒／BPM）")
            }
            .frame(height: UI.rowHeight)
            if expanded {
                AnimEditor(anim: $anim, defaultRange: animDefault, format: format, range: range, perPoint: perPoint)
            }
        }
    }

    /// 今の値（描画と同じ計算。欄の表示用）
    private func liveValue() -> () -> Double {
        let a = anim, base = value, beat = engine.beatClock, origin = origin, r = range
        return { min(max(a.value(base: base, at: CACurrentMediaTime(), beat: beat, origin: origin), r.lowerBound), r.upperBound) }
    }
}

/// パラメーター（位置・不透明度など）用。クリップ・レイヤー・コンポジションの anims に入れる
struct AnimField<Target: ObservableObject & Animatable>: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let perPoint: Double
    let defaultValue: Double
    var showsBar = false
    let format: (Double) -> String
    let key: ParamKey
    @ObservedObject var target: Target

    var body: some View {
        AnimValueField(label: label, value: $value, range: range, perPoint: perPoint, defaultValue: defaultValue,
                       showsBar: showsBar, format: format,
                       anim: Binding(get: { target.anim(key) }, set: { target.setAnim(key, $0) }),
                       origin: target.animOrigin, animDefault: key.defaultRange)
    }
}

/// 動かし方の設定（モード・動き方・周期・範囲）
/// 選択肢を並べたボタン（セレクトボックスの代わり。1 クリックで切り替わる）。
/// columns を選択肢の数より少なくすると折り返して何段かになる
struct ChoiceButtons<T: Hashable>: View {
    @Binding var selection: T
    let items: [(T, String)]
    var columns: Int? = nil
    var height: CGFloat = 28
    var fontSize: CGFloat = 12
    /// 1 つずつの説明（マウスを乗せたとき）
    var help: ((T) -> String)? = nil

    var body: some View {
        let n = max(columns ?? items.count, 1)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: n), spacing: 3) {
            ForEach(items.indices, id: \.self) { i in
                let (v, label) = items[i]
                let on = v == selection
                Button {
                    selection = v
                } label: {
                    Text(label)
                        .font(.system(size: fontSize, weight: on ? .bold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(on ? Color.accentColor : Color.white.opacity(0.07)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help?(v) ?? "")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// かかっているエフェクトの小さなアイコン（グリッド・出力モニターに出す）。オフのものは薄く
struct EffectIcons: View {
    let effects: [Effect]
    var size: CGFloat = 10
    var max = 4

    var body: some View {
        let list = effects.filter { !$0.kind.isBlend }
        if !list.isEmpty {
            HStack(spacing: 2) {
                ForEach(list.prefix(max)) { e in
                    Image(systemName: e.kind.icon)
                        .font(.system(size: size, weight: .semibold))
                        .opacity(e.enabled ? 1 : 0.35)
                }
                if list.count > max {
                    Text("+\(list.count - max)").font(.system(size: size, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Color.purple.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            .help(list.map { $0.enabled ? $0.kind.label : "（オフ）" + $0.kind.label }.joined(separator: " → "))
        }
    }
}

/// レイヤーの重ね方のボタン（ふつうの 4 つを 1 段に、特殊合成をその下に）
struct BlendChoice: View {
    @Binding var blend: BlendMode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("重ね方").font(.system(size: 11)).foregroundStyle(.secondary)
            ChoiceButtons(selection: $blend, items: BlendMode.allCases.filter { !$0.isSpecial && !$0.isMask }.map { ($0, $0.label) })
            ChoiceButtons(selection: $blend, items: BlendMode.allCases.filter(\.isMask).map { ($0, $0.label) })
                .help("このレイヤーを見せずに、明るさを使って下のレイヤー全部を切り抜く（白黒の動画や、マスクのエフェクトを付けた白い絵など）。不透明度でかかり具合")
            ChoiceButtons(selection: $blend, items: BlendMode.allCases.filter(\.isSpecial).map { ($0, $0.label) })
                .help("特殊合成：下のレイヤーの明るさを読んで、100% を超えた分をにじみ・色相ずれ・波紋に変える")
        }
    }
}

/// 拍数の短い書き方（ボタン用）
func beatShort(_ b: Double) -> String {
    switch b {
    case 0.0625: "1/16"
    case 0.125: "1/8"
    case 0.25: "1/4"
    case 0.5: "1/2"
    default: b == b.rounded() ? "\(Int(b))" : String(format: "%.2f", b)
    }
}

struct AnimEditor: View {
    @Binding var anim: ParamAnim
    let defaultRange: ClosedRange<Double>
    let format: (Double) -> String
    let range: ClosedRange<Double>
    let perPoint: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $anim.mode) {
                ForEach(AnimMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            if anim.isOn {
                ChoiceButtons(selection: $anim.motion, items: AnimMotion.allCases.map { ($0, $0.label) })
                if anim.mode == .time {
                    ValueDrag(label: "周期", value: $anim.seconds, range: 0.1...120, perPoint: 0.02, defaultValue: 4,
                              format: { String(format: "%.1f秒", $0) })
                        .frame(height: UI.rowHeight)
                } else {
                    HStack(spacing: 4) {
                        ChoiceButtons(selection: $anim.beats, items: ParamAnim.beatChoices.map { ($0, beatShort($0)) },
                                      columns: 5, fontSize: 11)
                        Text("拍").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .help("何拍で 1 周するか")
                }
                HStack(spacing: 6) {
                    ValueDrag(label: "から", value: $anim.lo, range: range, perPoint: perPoint,
                              defaultValue: defaultRange.lowerBound, format: format)
                    ValueDrag(label: "まで", value: $anim.hi, range: range, perPoint: perPoint,
                              defaultValue: defaultRange.upperBound, format: format)
                }
                .frame(height: UI.rowHeight)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(0.35)))
    }
}

/// BPM・タップテンポ・拍の表示（右下のパネル）
struct BPMControl: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack(spacing: 8) {
            ValueDrag(label: "BPM", value: Binding(get: { engine.bpm }, set: { engine.bpm = $0 }),
                      range: 20...300, perPoint: 0.05, defaultValue: 120, format: { String(format: "%.1f", $0) })
                .frame(width: 150, height: 40)
                .help("左右ドラッグで BPM / Shift で微調整 / ダブルクリックで 120")
            Button {
                engine.tapTempo()
            } label: {
                Text("TAP").font(.system(size: 14, weight: .bold)).frame(width: 64, height: 26)
            }
            .controlSize(.large)
            .help("拍に合わせて何回か押すと BPM が決まる（押した瞬間が拍の頭になる）")
            Button {
                engine.resyncBeat()
            } label: {
                Text("頭").font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 26)
            }
            .controlSize(.large)
            .help("今を 1 拍目（小節の頭）にする")
            BeatLights()
                .frame(height: 40)
        }
    }
}

/// 4 つの点で今何拍目かを出す
struct BeatLights: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            let b = engine.beatClock.beat(at: CACurrentMediaTime())
            let n = Int(floor(b)) % 4
            let idx = n < 0 ? n + 4 : n
            let f = b - floor(b)
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i == idx ? (i == 0 ? Color.orange : Color.green) : Color.white.opacity(0.12))
                        .opacity(i == idx ? 1 - f * 0.7 : 1)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - エフェクト

/// エフェクトの並び（追加・オン/オフ・並べ替え・削除・値）。上から順にかかる
/// エフェクト欄の見た目の状態（開いているカード・ドラッグ中のエフェクト）。保存はしない
final class EffectUIState: ObservableObject {
    static let shared = EffectUIState()
    @Published var expanded: Set<UUID> = []
    /// 並べ替えでドラッグしているエフェクト
    var dragging: UUID?
    /// プレビューの上で点を編集している「自由な形のマスク」
    @Published var editingPoly: UUID?
    static let movePrefix = "vjeffectmove:"
}

/// カードの上にドロップ：並べ替え（ドラッグしてきたエフェクト）か、一覧からの追加（その位置に入れる）
struct EffectReorderDrop<H: ObservableObject & EffectHolder>: ViewModifier {
    let index: Int
    let id: UUID
    let holder: H
    @State private var targeted = false

    /// 下から上へ動かすときはカードの上に、上から下へはカードの下に入る
    private var below: Bool {
        guard let d = EffectUIState.shared.dragging, let from = holder.effects.firstIndex(where: { $0.id == d }) else { return false }
        return from < index
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: below ? .bottom : .top) {
                RoundedRectangle(cornerRadius: 2).fill(Color.purple)
                    .frame(height: 4)
                    .offset(y: below ? 6 : -6)
                    .opacity(targeted && EffectUIState.shared.dragging != id ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onDrop(of: EffectDrop.types, isTargeted: $targeted) { providers in
                guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    DispatchQueue.main.async {
                        EffectUIState.shared.dragging = nil
                        if s.hasPrefix(EffectUIState.movePrefix),
                           let mid = UUID(uuidString: String(s.dropFirst(EffectUIState.movePrefix.count))) {
                            holder.moveEffect(mid, to: index)
                        } else if let k = EffectKind.fromDragString(s), !k.isGenerator {
                            let e = holder.insertEffect(k, at: index)
                            EffectUIState.shared.expanded.insert(e.id)
                        }
                    }
                }
                return true
            }
    }
}

struct EffectsSection<H: ObservableObject & EffectHolder>: View {
    @ObservedObject var holder: H
    @ObservedObject private var ui = EffectUIState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("エフェクト")
            // 右下の「エフェクト」一覧からここへドラッグ
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.rectangle").foregroundStyle(.purple)
                Text(holder.effects.isEmpty
                     ? "「エフェクト」パネルからドラッグして追加（上から順にかかります）"
                     : "「エフェクト」パネルからドラッグして追加")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.purple.opacity(0.5)))
            .effectDropTarget { k in
                let e = holder.insertEffect(k, at: holder.effects.count)
                ui.expanded.insert(e.id)
            }
            ForEach(Array(holder.effects.enumerated()), id: \.element.id) { i, e in
                EffectCard(effect: binding(e.id), origin: (holder as? Animatable)?.animOrigin ?? 0, isFirst: i == 0,
                           isLast: i == holder.effects.count - 1,
                           move: { holder.moveEffect(e.id, by: $0) }, remove: { holder.removeEffect(e.id) })
                    .modifier(EffectReorderDrop(index: i, id: e.id, holder: holder))
            }
            if holder.effects.count > 1 {
                Text("名前の行をドラッグして並べ替え（上から順にかかる）。▸ で開く／閉じる")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(width: UI.paramsWidth, alignment: .leading)
    }

    private func binding(_ id: UUID) -> Binding<Effect> {
        Binding(get: { holder.effects.first { $0.id == id } ?? Effect(kind: .mirror) },
                set: { v in
                    if let i = holder.effects.firstIndex(where: { $0.id == id }) { holder.effects[i] = v }
                })
    }
}

/// 1 つのエフェクト
struct EffectCard: View {
    @Binding var effect: Effect
    /// 秒モードの基準時刻（クリップならトリガーした時刻）
    var origin: Double = 0
    let isFirst: Bool
    let isLast: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    /// 重ね方（特殊合成）の設定として出す：オン/オフ・並べ替え・削除は出さない
    var isBlendSettings = false

    var body: some View {
        let params = effect.kind.params
        VStack(alignment: .leading, spacing: 8) {
            if !isBlendSettings {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .help("ドラッグして並べ替え")
                Toggle("", isOn: $effect.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("オン／オフ")
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: effect.kind.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(effect.enabled ? Color.purple : Color.secondary)
                        .frame(width: 18)
                    Text(effect.kind.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(effect.enabled ? Color.primary : Color.secondary)
                    if effect.anims.values.contains(where: \.isOn) {
                        Image(systemName: "waveform.path").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.purple)
                            .help("動かしている値がある")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleOpen() }
                .help(effect.kind.help + "（クリックで開く／閉じる）")
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash").frame(width: 18) }
                    .help("このエフェクトを外す")
            }
            .controlSize(.regular)
            .frame(height: 26)
            .onDrag {
                EffectUIState.shared.dragging = effect.id
                return NSItemProvider(object: (EffectUIState.movePrefix + effect.id.uuidString) as NSString)
            }
            } else {
                Text(effect.kind.help).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if open || isBlendSettings {
            if effect.kind == .strobe { strobeSwitches }
            LazyVGrid(columns: [GridItem(.fixed(UI.paramColumnWidth), spacing: 16),
                                GridItem(.fixed(UI.paramColumnWidth), alignment: .top)], alignment: .leading, spacing: 8) {
                ForEach(params.indices.filter { shows($0) }, id: \.self) { i in
                    let p = params[i]
                    if p.isToggle {
                        Toggle(p.label, isOn: Binding(get: { effect.value(i) > 0.5 }, set: { valueBinding(i).wrappedValue = $0 ? 1 : 0 }))
                            .toggleStyle(.switch)
                            .frame(height: UI.rowHeight)
                            .help(effect.kind == .colorize
                                  ? "オン：元の明るさのまま色だけ変える／オフ：黒は黒、白はその色そのものになる" : "")
                    } else if let choices = p.choices {
                        HStack(spacing: 8) {
                            Text(p.label).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize()
                            ChoiceButtons(selection: valueBinding(i),
                                          items: choices.indices.map { (Double($0), choices[$0]) })
                        }
                        .frame(height: UI.rowHeight)
                    } else {
                        AnimValueField(label: p.label, value: valueBinding(i), range: p.range, perPoint: p.perPoint,
                                       defaultValue: p.defaultValue, showsBar: p.range == 0...1, format: p.format,
                                       anim: Binding(get: { effect.anim(i) }, set: { var e = effect; e.setAnim(i, $0); effect = e }),
                                       origin: origin, animDefault: p.animRange ?? p.range)
                    }
                }
            }
            .opacity(effect.enabled ? 1 : 0.5)
            if effect.kind == .colorize {
                if effect.value(0) < 0.5 {
                    HStack(spacing: 10) {
                        Text("色").font(.system(size: 12)).foregroundStyle(.secondary)
                        ColorPicker("", selection: colorBinding(\.color), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 60, height: UI.rowHeight)
                        Text("（クリックで色のパネル：ホイール・RGB/HSB・スポイト・保存した色）")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    PaletteEditor(palette: $effect.palette)
                }
            }
            if effect.kind == .polyMask { PolyMaskControls(effect: $effect) }
            if effect.kind.usesColor {
                HStack(spacing: 10) {
                    Text("色").font(.system(size: 12)).foregroundStyle(.secondary)
                    ColorPicker("", selection: colorBinding(\.color), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 60, height: UI.rowHeight)
                    ForEach([RGB.white, RGB.black, .hsb(0, 0.85, 1), .hsb(0.33, 0.85, 1), .hsb(0.6, 0.85, 1),
                             .hsb(0.83, 0.85, 1), .hsb(0.13, 0.85, 1)], id: \.self) { c in
                        Button { var e = effect; e.color = c; effect = e } label: {
                            RoundedRectangle(cornerRadius: 4).fill(Color(rgb: c))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5)))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if effect.kind == .gradient { PaletteEditor(palette: $effect.palette) }
            if effect.kind == .strobe && effect.value(0) < 0.5 {
                HStack(spacing: 10) {
                    Text("光る色").font(.system(size: 12)).foregroundStyle(.secondary)
                    ColorPicker("", selection: colorBinding(\.color), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 60, height: UI.rowHeight)
                }
            }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
    }

    @ObservedObject private var ui = EffectUIState.shared
    private var open: Bool { ui.expanded.contains(effect.id) }
    private func toggleOpen() {
        if open { ui.expanded.remove(effect.id) } else { ui.expanded.insert(effect.id) }
    }

    /// その値を出すか（カラーライズのパレットモードでは「明るさを保つ」は使わない）
    private func shows(_ i: Int) -> Bool {
        if effect.kind == .strobe {
            // 光り方・合わせるもの・間隔は上のスイッチで。秒のときだけ「1 秒の回数」を出す
            if i <= 2 { return false }
            if i == 3 { return effect.value(1) >= 0.5 }
        }
        return !(effect.kind == .colorize && i == 1 && effect.value(0) > 0.5)
    }

    /// ストロボの切り替え（1 クリックで切り替わるスイッチ）
    private var strobeSwitches: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                segmented(0, ["色で光る", "消える", "反転"], width: UI.paramColumnWidth)
                segmented(1, ["BPM", "秒"], width: 120)
            }
            if effect.value(1) < 0.5 {
                HStack(spacing: 8) {
                    Text("間隔").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    segmented(2, ["1/16", "1/8", "1/4", "1/2", "1", "2", "4"], width: UI.paramsWidth - 72)
                    Text("拍").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .help("何拍ごとに光るか（BPM に合わせる）")
            }
        }
        .opacity(effect.enabled ? 1 : 0.5)
    }

    private func segmented(_ i: Int, _ labels: [String], width: CGFloat) -> some View {
        ChoiceButtons(selection: valueBinding(i), items: labels.indices.map { (Double($0), labels[$0]) })
            .frame(width: width)
    }

    private func colorBinding(_ key: WritableKeyPath<Effect, RGB>) -> Binding<Color> {
        Binding(get: { Color(rgb: effect[keyPath: key]) },
                set: { var e = effect; e[keyPath: key] = RGB(color: $0); effect = e })
    }

    private func valueBinding(_ i: Int) -> Binding<Double> {
        Binding(get: { effect.value(i) },
                set: { v in
                    var e = effect
                    while e.values.count <= i { e.values.append(e.kind.params[e.values.count].defaultValue) }
                    let p = e.kind.params[i]
                    e.values[i] = p.step > 0 ? (v / p.step).rounded() * p.step : v
                    effect = e
                })
    }
}


/// パレット（暗い所 → 明るい所の色）。色をクリックで変える、右クリックで外す、＋で足す、ひな形から選ぶ
struct PaletteEditor: View {
    @Binding var palette: [RGB]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("パレット").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Menu("ひな形") {
                    ForEach(PalettePreset.all) { p in
                        Button(p.name) { palette = p.colors }
                    }
                }
                .controlSize(.large)
                .fixedSize()
                Button {
                    palette.reverse()
                } label: { Image(systemName: "arrow.left.arrow.right") }
                    .controlSize(.large)
                    .help("並びを逆にする（明暗を入れ替える）")
            }
            // 暗い → 明るいのグラデーション
            LinearGradient(colors: palette.map { Color(rgb: $0) }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack(spacing: 6) {
                ForEach(palette.indices, id: \.self) { i in
                    ColorPicker("", selection: Binding(get: { Color(rgb: palette[min(i, palette.count - 1)]) },
                                                       set: { if palette.indices.contains(i) { palette[i] = RGB(color: $0) } }),
                                supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 44, height: UI.rowHeight)
                        .contextMenu {
                            Button("この色を外す") { if palette.count > 2 { palette.remove(at: i) } }
                                .disabled(palette.count <= 2)
                        }
                }
                if palette.count < Effect.maxPalette {
                    Button {
                        palette.append(palette.last ?? .white)
                    } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                        .controlSize(.large)
                        .help("色を足す（\(Effect.maxPalette) 色まで）")
                }
                Spacer(minLength: 0)
            }
            Text("左が暗い所、右が明るい所の色。色をクリックで変更、右クリックで外す")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

extension Color {
    init(rgb c: RGB) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1) }
}

extension RGB {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}
