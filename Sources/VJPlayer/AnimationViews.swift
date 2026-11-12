import SwiftUI

/// アニメーションを付けられる数値欄。左のボタンで「動かし方」の設定を開く。
/// 動かしている間は欄に今の値が出続ける（手では動かせない）
struct AnimValueField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let perPoint: Double
    let defaultValue: Double
    var showsBar = false
    let format: (Double) -> String
    var style = ValueStyle.plain
    @Binding var anim: ParamAnim
    /// 秒モードの基準時刻
    var origin: Double = 0
    /// アニメーションの範囲を戻すときの値
    let animDefault: ClosedRange<Double>
    /// 動かし方のボタンの右に並べるもの（不透明度の「映像を出さない」など）。開いた設定は、これも含めた幅いっぱいに出す
    var trailing: AnyView? = nil
    @EnvironmentObject var engine: Engine
    /// 画面確認用：VJ_ANIM_EXPANDED を付けると、はじめから開いて描く
    @State private var expanded = ProcessInfo.processInfo.environment["VJ_ANIM_EXPANDED"] != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 並び：動かし方のボタン（アイコン）→ 名前と値の欄
            HStack(spacing: 4) {
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
                .help(L("動かし方（固定／秒／BPM）"))
                ValueDrag(label: label, value: $value, range: range, perPoint: perPoint, defaultValue: defaultValue,
                          showsBar: showsBar, format: format, live: anim.isOn ? liveValue() : nil,
                          badge: anim.summary, style: style)
                if let trailing { trailing }
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
    var style = ValueStyle.plain
    let key: ParamKey
    @ObservedObject var target: Target
    var trailing: AnyView? = nil

    var body: some View {
        AnimValueField(label: label, value: $value, range: range, perPoint: perPoint, defaultValue: defaultValue,
                       showsBar: showsBar, format: format, style: style,
                       anim: Binding(get: { target.anim(key) }, set: { target.setAnim(key, $0) }),
                       origin: target.animOrigin, animDefault: key.defaultRange, trailing: trailing)
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
            .help(list.map { $0.enabled ? $0.kind.label : L("（オフ）") + $0.kind.label }.joined(separator: " → "))
        }
    }
}

/// レイヤーの重ね方のボタン（ふつうの 4 つを 1 段に、特殊合成をその下に）
struct BlendChoice: View {
    @Binding var blend: BlendMode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("重ね方")).font(.system(size: 11)).foregroundStyle(.secondary)
            ChoiceButtons(selection: $blend, items: [BlendMode.normal, .add, .screen, .multiply].map { ($0, $0.label) })
            ChoiceButtons(selection: $blend, items: BlendMode.simpleBelow.prefix(3).map { ($0, $0.label) })
                .help(L("差分：重なった所が反転したような色に（同じ色は黒）。オーバーレイ・ソフトライト：明るい所はより明るく、暗い所はより暗く"))
            ChoiceButtons(selection: $blend, items: BlendMode.simpleBelow.suffix(3).map { ($0, $0.label) })
                .help(L("覆い焼き：明るい所が焼けたように光る。色相だけ：下の絵の明るさのまま、このレイヤーの色に。明るさだけ：下の絵の色のまま、このレイヤーの明るさに"))
            ChoiceButtons(selection: $blend, items: BlendMode.allCases.filter(\.isMask).map { ($0, $0.label) })
                .help(L("このレイヤーを見せずに、明るさを使って下のレイヤー全部を切り抜く（白黒の動画や、マスクのエフェクトを付けた白い絵など）。不透明度でかかり具合"))
            Text(L("絡み合う重ね方（下の絵そのものを変える）")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            ChoiceButtons(selection: $blend, items: BlendMode.entangle.prefix(3).map { ($0, $0.label) })
                .help(L("屈折：このレイヤーを透明なガラスにして、下の絵を曲げる。光で照らす：このレイヤーの光で下の絵を照らす（ほかは暗く）。流し込む：このレイヤーの動きで下の絵をかき混ぜる"))
            ChoiceButtons(selection: $blend, items: BlendMode.entangle.suffix(3).map { ($0, $0.label) })
                .help(L("干渉：2 つの明るさを波にして縞（モアレ）を出す。色を借りる：下の絵の形に、このレイヤーの色を塗る。溶け込む：下の暗い所から順にこのレイヤーへ溶ける"))
            ChoiceButtons(selection: $blend, items: [(BlendMode.overdrive, BlendMode.overdrive.label)])
                .help(L("特殊合成：下のレイヤーの明るさを読んで、100% を超えた分をにじみ・色相ずれ・波紋に変える"))
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
            if anim.mode == .audio {
                AudioAnimControls(anim: $anim)
            } else if anim.mode == .osc {
                OSCAnimControls(anim: $anim)
            } else if anim.isOn {
                ChoiceButtons(selection: $anim.motion, items: AnimMotion.allCases.map { ($0, $0.label) })
                if anim.mode == .time {
                    ValueDrag(label: L("周期"), value: $anim.seconds, range: 0.1...120, perPoint: 0.02, defaultValue: 4,
                              format: { String(format: L("%.1f秒"), $0) })
                        .frame(height: UI.rowHeight)
                } else {
                    HStack(spacing: 4) {
                        ChoiceButtons(selection: $anim.beats, items: ParamAnim.beatChoices.map { ($0, beatShort($0)) },
                                      columns: 5, fontSize: 11)
                        Text(L("拍")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .help(L("何拍で 1 周するか"))
                }
            }
            if anim.isOn {
                HStack(spacing: 6) {
                    ValueDrag(label: L("から"), value: $anim.lo, range: range, perPoint: perPoint,
                              defaultValue: defaultRange.lowerBound, format: format)
                    ValueDrag(label: L("まで"), value: $anim.hi, range: range, perPoint: perPoint,
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

/// 動かし方が「音」のとき：音のどの部分か・感度・今の値
struct AudioAnimControls: View {
    @Binding var anim: ParamAnim
    @ObservedObject private var ar = AudioReactive.shared

    private var link: AudioLink { anim.audio ?? AudioLink() }
    private var band: Binding<AudioBand> {
        Binding(get: { link.band }, set: { var a = link; a.band = $0; anim.audio = a })
    }
    private var gain: Binding<Double> {
        Binding(get: { link.gain }, set: { var a = link; a.gain = $0; anim.audio = a })
    }
    private var reverse: Binding<Bool> {
        Binding(get: { anim.motion == .backward }, set: { anim.motion = $0 ? .backward : .forward })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChoiceButtons(selection: band, items: AudioBand.allCases.map { ($0, $0.label) })
                .help(link.band.help)
            HStack(spacing: 8) {
                ValueDrag(label: L("感度"), value: gain, range: 0...6, perPoint: 0.005, defaultValue: 1, format: EffectParam.percent)
                    .frame(height: UI.rowHeight)
                Toggle(L("逆"), isOn: reverse).toggleStyle(.button).controlSize(.small)
                    .help(L("音が大きいほど「から」の方へ"))
            }
            AudioMeter(band: link.band, gain: link.gain)
            if ar.source == .off {
                Text(L("音の入力がオフ（上のバーの「音の入力」で、アプリの音かマイク・ライン入力を選ぶ）"))
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
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
                .help(L("左右ドラッグで BPM / Shift で微調整 / ダブルクリックで 120"))
            Button {
                engine.tapTempo()
            } label: {
                Text("TAP").font(.system(size: 14, weight: .bold)).frame(width: 64, height: 26)
            }
            .controlSize(.large)
            .help(L("拍に合わせて何回か押すと BPM が決まる（押した瞬間が拍の頭になる）"))
            Button {
                engine.resyncBeat()
            } label: {
                Text(L("頭")).font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 26)
            }
            .controlSize(.large)
            .help(L("今を 1 拍目（小節の頭）にする"))
            BPMAutoButton()
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

/// カードの上にドロップ：並べ替え（ドラッグしてきたエフェクト）・ほかの並びからの付け替え・一覧からの追加（その位置に入れる）
struct EffectReorderDrop<H: ObservableObject & EffectHolder>: ViewModifier {
    let index: Int
    let id: UUID
    let holder: H
    /// この並びの置き場所（FX パッドなど、無ければこの並びの中の並べ替えだけ）
    var place: EffectPlace?
    @State private var targeted = false

    /// 下から上へ動かすときはカードの上に、上から下へはカードの下に入る（ほかの並びから来たときは上）
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
            .onDrop(of: EffectDrop.types, delegate: EffectDropDelegate(targeted: $targeted) { providers, copy in
                let below = self.below
                return EffectDrop.loadString(providers) { s in
                    if let mid = EffectTransfer.moveID(s) {
                        // 同じ並びで写すときは、線の出ている側に入れる
                        let at = copy && below ? index + 1 : index
                        EffectTransfer.receive(mid, into: holder, place: place, at: at, copy: copy)
                    } else if let k = EffectKind.fromDragString(s), !k.isGenerator {
                        EffectFavorites.shared.note(k)
                        let e = holder.insertEffect(k, at: index)
                        EffectUIState.shared.expanded.insert(e.id)
                    }
                }
            })
    }
}

struct EffectsSection<H: ObservableObject & EffectHolder>: View {
    @ObservedObject var holder: H
    /// この並びの置き場所（ほかの場所との付け替え用。FX パッドなどは nil で、並びの中だけ）
    var place: EffectPlace? = nil
    @ObservedObject private var ui = EffectUIState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FoldTitle(key: "effects", holder.effects.isEmpty ? L("エフェクト") : L("エフェクト") + "（\(holder.effects.count)）",
                      icon: "camera.filters", tint: UI.effectTint)
            FoldBody(key: "effects") { list }
        }
        .paramsFrame(alignment: .leading)
    }

    /// 足すボタンと、カードの並び
    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ＋ボタンのメニューから選ぶか、右下の「エフェクト」一覧からここへドラッグ
            HStack(spacing: 8) {
                AddEffectMenu { k in holder.addEffectOpened(k) }
                    .tint(.purple)
                Text(holder.effects.isEmpty
                     ? L("またはパネルからドラッグ（上から順にかかる）")
                     : L("またはパネルからドラッグ"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(UI.effectTint.opacity(0.5)))
            .effectDropTarget(move: { id, copy in
                EffectTransfer.receive(id, into: holder, place: place, at: nil, copy: copy)
            }) { k in
                let e = holder.insertEffect(k, at: holder.effects.count)
                ui.expanded.insert(e.id)
            }
            ForEach(Array(holder.effects.enumerated()), id: \.element.id) { i, e in
                EffectCard(effect: binding(e.id), origin: (holder as? Animatable)?.animOrigin ?? 0, isFirst: i == 0,
                           isLast: i == holder.effects.count - 1,
                           move: { holder.moveEffect(e.id, by: $0) }, remove: { holder.removeEffect(e.id) },
                           transferMenu: place != nil)
                    .overlay(EffectFlashMark(id: e.id))
                    .modifier(EffectReorderDrop(index: i, id: e.id, holder: holder, place: place))
            }
            if !holder.effects.isEmpty && (holder.effects.count > 1 || place != nil) {
                Text(place != nil
                     ? L("名前の行をドラッグして並べ替え・ほかの場所へ移す（⌥ で写す）。上から順にかかる。▸ で開く／閉じる")
                     : L("名前の行をドラッグして並べ替え（上から順にかかる）。▸ で開く／閉じる"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
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
    /// 見出しの無い形（isBlendSettings）でも、説明文の行に 元に戻す・サイコロ・プリセット を出す（クリップのジェネレーター）
    var showsCardButtons = false
    /// 名前の行の右クリックに「移す／写す」を出す（置き場所の分かる並びだけ）
    var transferMenu = false
    /// パラメーター欄の幅（狭いと 1 列に並べる）
    @Environment(\.paramsWidth) private var paramsWidth
    private var narrow: Bool { paramsWidth < UI.paramsWidth - 1 }

    var body: some View {
        let params = effect.kind.params
        VStack(alignment: .leading, spacing: 8) {
            if !isBlendSettings {
            HStack(spacing: narrow ? 5 : 8) {
            // 並べ替えのドラッグは、右のボタンを除いた所で受ける（.onDrag の中に入れたボタンは、ホバーの説明（.help）が出ないことがあるため）
            HStack(spacing: narrow ? 5 : 8) {
                // 細いときは名前を優先してつまみの印を省く（ボタン以外の行のどこをドラッグしても並べ替えられる）
                if !narrow {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .help(transferMenu ? L("ドラッグして並べ替え。ほかの場所へ落とすと移す（⌥ で写す）") : L("ドラッグして並べ替え"))
                }
                Toggle("", isOn: $effect.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(L("オン／オフ"))
                HStack(spacing: narrow ? 4 : 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: effect.kind.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(effect.enabled ? tint : Color.secondary)
                        .frame(width: 18)
                    Text(effect.kind.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(effect.enabled ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if effect.hasMix && (effect.mix < 0.995 || effect.mixAnim.isOn) {
                        // 不透明度を下げている（動かしている）ことが閉じていても分かるように
                        Text(effect.mixAnim.isOn ? L("不透明度〜") : String(format: "%.0f%%", effect.mix * 100))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .help(L("このエフェクトの不透明度"))
                    }
                    if effect.anims.values.contains(where: \.isOn) {
                        Image(systemName: "waveform.path").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.purple)
                            .help(L("動かしている値がある"))
                    }
                    autoDiceMark
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleOpen() }
                .help(effect.kind.help + L("（クリックで開く／閉じる）"))
            }
            .contentShape(Rectangle())
            .onDrag {
                EffectDragState.shared.begin(effect.id)
                return NSItemProvider(object: (EffectUIState.movePrefix + effect.id.uuidString) as NSString)
            }
            .modifier(EffectTransferMenuModifier(enabled: transferMenu, id: effect.id, kind: effect.kind))
                // 細いときはボタンを小さくして、名前の場所を空ける
                HStack(spacing: narrow ? 4 : 8) {
                    resetButton
                    if effect.kind.hasDice { EffectDiceButton(effect: $effect) }
                    EffectPresetMenu(effect: $effect)
                    Button(role: .destructive) { remove() } label: { Image(systemName: "trash").frame(width: 18) }
                        .help(L("このエフェクトを外す"))
                }
                .controlSize(narrow ? .small : .regular)
            }
            .controlSize(.regular)
            .frame(height: 26)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Text(effect.kind.help).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if showsCardButtons {
                        // クリップのジェネレーター：見出しが無いので、ここに 元に戻す・サイコロ・プリセット
                        HStack(spacing: narrow ? 4 : 8) {
                            resetButton
                            if effect.kind.hasDice { EffectDiceButton(effect: $effect) }
                            EffectPresetMenu(effect: $effect)
                        }
                        .controlSize(narrow ? .small : .regular)
                    } else {
                        resetButton
                    }
                }
            }
            if open || isBlendSettings {
            if effect.hasMix && !isBlendSettings {
                // エフェクトの不透明度（かかり具合）：元の絵とエフェクトをかけた絵を混ぜる
                AnimValueField(label: L("不透明度"), value: mixBinding, range: 0...1, perPoint: 0.003, defaultValue: 1,
                               showsBar: true, format: EffectParam.percent,
                               anim: Binding(get: { effect.mixAnim }, set: { var e = effect; e.setMixAnim($0); effect = e }),
                               origin: origin, animDefault: 0...1)
                    .frame(maxWidth: narrow ? .infinity : UI.paramColumnWidth, alignment: .leading)
                    .help(L("このエフェクトの不透明度（かかり具合）。0% で元の絵のまま、100% でいっぱいにかかる"))
            }
            if effect.kind == .strobe { strobeSwitches }
            if effect.kind.isText { textControls }
            if !effect.kind.looks.isEmpty { looksRow }
            LazyVGrid(columns: narrow ? [GridItem(.flexible(), alignment: .top)]
                      : [GridItem(.fixed(UI.paramColumnWidth), spacing: 16), GridItem(.fixed(UI.paramColumnWidth), alignment: .top)],
                      alignment: .leading, spacing: 8) {
                ForEach(params.indices.filter { shows($0) }, id: \.self) { i in
                    let p = params[i]
                    if p.isToggle {
                        Toggle(p.label, isOn: Binding(get: { effect.value(i) > 0.5 }, set: { valueBinding(i).wrappedValue = $0 ? 1 : 0 }))
                            .toggleStyle(.switch)
                            // 名前の位置を、動かし方のボタンの右にある数値欄の名前にそろえる
                            .padding(.leading, UI.paramLabelInset)
                            .frame(maxWidth: .infinity, minHeight: UI.rowHeight, maxHeight: UI.rowHeight, alignment: .leading)
                            .help(effect.kind == .colorize
                                  ? L("オン：元の明るさのまま色だけ変える／オフ：黒は黒、白はその色そのものになる") : "")
                    } else if let choices = p.choices {
                        HStack(spacing: 8) {
                            Text(p.label).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize()
                            ChoiceButtons(selection: valueBinding(i),
                                          items: choices.indices.map { (Double($0), choices[$0]) })
                        }
                        .padding(.leading, UI.paramLabelInset)
                        .frame(height: UI.rowHeight)
                    } else {
                        AnimValueField(label: p.label, value: valueBinding(i), range: p.range, perPoint: p.perPoint,
                                       defaultValue: p.defaultValue, showsBar: p.range != 0...360, format: p.format,
                                       style: p.range == 0...360 ? .angle : .plain,
                                       anim: Binding(get: { effect.anim(i) }, set: { var e = effect; e.setAnim(i, $0); effect = e }),
                                       origin: origin, animDefault: p.animRange ?? p.range)
                    }
                }
            }
            .opacity(effect.enabled ? 1 : 0.5)
            if effect.kind == .colorize {
                if effect.value(0) < 0.5 {
                    HStack(spacing: 10) {
                        Text(L("色")).font(.system(size: 12)).foregroundStyle(.secondary)
                        ColorWell(color: $effect.color)
                        Text(L("（クリックで色を選ぶ）"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    PaletteEditor(palette: $effect.palette)
                }
            }
            if effect.hasQuality {
                HStack(spacing: 8) {
                    Text(L("画質")).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    ChoiceButtons(selection: $effect.quality,
                                  items: Effect.qualityLabels.indices.map { ($0, Effect.qualityLabels[$0]) })
                        .frame(maxWidth: 320)
                }
                .padding(.leading, UI.paramLabelInset)
                .frame(height: UI.rowHeight)
                .help(L("小さく描いて引き伸ばす。GPU の負担が減る（半分なら約 1/4）。線や細かい模様は少しぼやける"))
            }
            if effect.kind == .polyMask { PolyMaskControls(effect: $effect) }
            if effect.kind == .syphonIn { SyphonSourcePicker(effect: $effect) }
            if effect.kind == .camera { CameraSourcePicker(effect: $effect) }
            if effect.kind == .ndiIn { NDISourcePicker(effect: $effect) }
            if effect.kind == .logoParticles { LogoSourcePicker(effect: $effect) }
            if effect.kind.moreShowsColor(effect) || effect.kind.usesColor && !(effect.kind.isText && effect.value(5) > 0.5)
                && !(effect.kind == .tunnel && effect.value(13) > 0.5)
                && !(effect.kind == .physarum && effect.value(8) > 0.5)
                && !(effect.kind == .attractor && effect.value(11) > 0.5)
                && !(effect.kind == .rasterScan && abs(effect.value(4) - 1) > 0.5)
                && !(effect.kind == .audioScope && effect.value(4) > 0.5) {
                HStack(spacing: 10) {
                    Text(L("色")).font(.system(size: 12)).foregroundStyle(.secondary)
                    ColorWell(color: $effect.color)
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
            if effect.kind.moreShowsPalette(effect) || effect.kind == .gradient || (effect.kind.isText && effect.value(5) > 0.5)
                || (effect.kind == .tunnel && effect.value(13) > 0.5 && effect.value(13) < 1.5)
                || (effect.kind == .physarum && effect.value(8) > 0.5)
                || (effect.kind == .particleLife && effect.value(9) > 0.5)
                || (effect.kind == .attractor && effect.value(11) > 0.5 && effect.value(11) < 1.5)
                || (effect.kind == .audioScope && effect.value(4) > 1.5) {
                PaletteEditor(palette: $effect.palette)
            }
            if effect.kind == .strobe && effect.value(0) < 0.5 {
                HStack(spacing: 10) {
                    Text(L("光る色")).font(.system(size: 12)).foregroundStyle(.secondary)
                    ColorWell(color: $effect.color)
                }
            }
            }
        }
        .padding(10)
        .padding(.leading, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(isGen ? 0.09 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(isGen ? 0.55 : 0.35)))
        // 左端の色の帯（ジェネレーター：青緑、エフェクト：紫）
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6)
                .fill(tint.opacity(effect.enabled || isBlendSettings ? 0.9 : 0.35))
                .frame(width: 4)
        }
    }

    private var isGen: Bool { effect.kind.isGenerator }
    private var tint: Color { isGen ? UI.generatorTint : UI.effectTint }

    @ObservedObject private var ui = EffectUIState.shared
    private var open: Bool { ui.expanded.contains(effect.id) }
    private func toggleOpen() {
        if open { ui.expanded.remove(effect.id) } else { ui.expanded.insert(effect.id) }
    }

    /// ドット・群れ：よく使う見た目に一度でそろえる（そろえたあと、ふつうに値を直せる）
    private var looksRow: some View {
        HStack(spacing: 6) {
            Text(L("見た目")).font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(effect.kind.looks, id: \.name) { look in
                Button(look.name) {
                    var e = effect
                    for (i, v) in look.values { e.values[i] = v }
                    if let c = look.color { e.color = c }
                    effect = e
                }
                .controlSize(.small)
                .help(look.help)
            }
            Spacer(minLength: 0)
        }
    }

    /// その値を出すか（カラーライズのパレットモードでは「明るさを保つ」は使わない）
    private func shows(_ i: Int) -> Bool {
        // 以前の「かかり具合」は、上の「不透明度」にまとめた
        if i == effect.kind.amountIndex { return false }
        if effect.kind == .dots && [4, 18, 19, 20].contains(i) {
            // 波の高さ（3D の点の雲）のときは角度・ふらふら・光のにじみを使わない（平らのときだけ）
            return effect.value(16) <= 0
        }
        if effect.kind == .school && (16...20).contains(i) {
            // カメラは 3D（厚みがある）のときだけ
            return effect.value(14) > 0
        }
        if effect.kind == .lines {
            // 波の高さ（3D の地形）のときは、横の線だけを描く（角度・横のうねり・線ごとのずれは使わない）。
            // 山の形・真ん中・黒く塗るは、波の高さがあるときだけ
            let terrain = effect.value(12) > 0
            if [2, 5, 8].contains(i) { return !terrain }
            if (13...15).contains(i) { return terrain }
        }
        if effect.kind == .clock {
            // モード・表示・細かさは上の欄で。目標の時刻はカウントダウン、長さはタイマー、弾みは数えるときだけ
            let mode = Int(effect.value(12).rounded())
            if [12, 13, 14].contains(i) { return false }
            if (15...19).contains(i) { return false }
            if i == 20 { return mode == 1 || mode == 2 }
        }
        if effect.kind.isText {
            // 動き・フォント・行の切り替えは上の欄で。速さは動くときだけ
            if [0, 6, 8].contains(i) { return false }
            let m = Int(effect.value(0).rounded())
            if i == 2 { return [1, 2, 3, 4].contains(m) }
            // 間隔は流す・敷き詰めるときだけ（横に流れる → 横、縦に流れる → 縦、敷き詰め → 両方）
            if i == 10 { return m == 1 || m == 3 }
            if i == 11 { return m == 2 || m == 3 }
        }
        if effect.kind == .strobe {
            // 光り方・合わせるもの・間隔は上のスイッチで。秒のときだけ「1 秒の回数」を出す
            if i <= 2 { return false }
            if i == 3 { return effect.value(1) >= 0.5 }
        }
        return !(effect.kind == .colorize && i == 1 && effect.value(0) > 0.5)
    }

    /// 自動でサイコロを振っている印（カードを閉じていても分かるように）
    @ViewBuilder private var autoDiceMark: some View {
        if let a = effect.autoDice, a.isOn, effect.kind.hasDice {
            Image(systemName: "dice.fill").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .help(a.summary)
        }
    }

    /// 値・動き・不透明度・色を最初の状態に戻す
    private var resetButton: some View {
        Button { effect = effect.reset } label: {
            Image(systemName: "arrow.counterclockwise").frame(width: 18)
        }
        .disabled(effect.isDefault)
        .help(effect.kind.isGenerator
              ? L("設定を最初の状態に戻す（値・動き・色。文字はそのまま）")
              : effect.kind == .polyMask ? L("設定を最初の状態に戻す（値・動き・不透明度。描いた形はそのまま）")
              : L("設定を最初の状態に戻す（値・動き・不透明度・色）"))
    }

    /// テキストの文字・動き・フォント・行の切り替え
    private var textControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if effect.kind == .clock { clockControls }
            let mode = Int(effect.value(12).rounded())
            if effect.kind == .text || mode == 1 || mode == 2 {
                if effect.kind == .clock {
                    Text(L("0 になったら出す文字（空なら 0 のまま）")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                TextEditor(text: Binding(get: { effect.text }, set: { var e = effect; e.text = $0; effect = e }))
                    .font(.system(size: 14, weight: .semibold))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: effect.kind == .clock ? 44 : 64)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.4)))
                    .help(effect.kind == .clock ? L("カウントダウン・タイマーが 0 になったときに出す文字。改行もできる")
                          : L("出す文字。改行で行を分ける（「行の切り替え」で 1 行ずつ拍に合わせて切り替えられる）"))
            }
            labeled(L("動き")) {
                ChoiceButtons(selection: valueBinding(0),
                              items: TextLook.motions.indices.map { (Double($0), TextLook.motions[$0]) },
                              columns: narrow ? 2 : 3)
            }
            labeled(L("フォント")) {
                let n = narrow ? 2 : 5
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: n), spacing: 3) {
                    ForEach(TextLook.fonts.indices, id: \.self) { i in
                        let on = Int(effect.value(6).rounded()) == i
                        Button { valueBinding(6).wrappedValue = Double(i) } label: {
                            Text(TextLook.fonts[i].label)
                                .font(Font(TextLook.font(i, size: 13)))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(on ? Color.accentColor : Color.white.opacity(0.07)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if effect.kind == .text {
            labeled(L("行の切り替え")) {
                ChoiceButtons(selection: valueBinding(8),
                              items: TextLook.switchBeats.indices.map {
                                  (Double($0), $0 == 0 ? L("全部の行") : ParamAnim.beatsLabel(TextLook.switchBeats[$0]))
                              })
                    .help(L("改行で分けた行を、拍に合わせて 1 行ずつ出す"))
            }
            }
        }
        .opacity(effect.enabled ? 1 : 0.5)
    }

    /// 時計のモード・表示・秒より細かく
    private var clockControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled(L("モード")) {
                ChoiceButtons(selection: valueBinding(12),
                              items: ClockText.modes.indices.map { (Double($0), ClockText.modes[$0]) },
                              columns: 2, help: { v in
                                  [L("パソコンの時計の今の時刻"), L("決めた時刻まで（過ぎた日は次の日のその時刻まで。0 のあと 1 時間は終わった表示）"),
                                   L("決めた長さを、クリップを出した時から数える"), L("クリップを出した時から数える")][Int(v)]
                              })
            }
            let mode = Int(effect.value(12).rounded())
            if mode == 1 {
                labeled(L("目標の時刻")) { timeFields([(15, L("時")), (16, L("分")), (17, L("秒"))]) }
            } else if mode == 2 {
                labeled(L("長さ")) { timeFields([(18, L("分")), (19, L("秒"))]) }
            }
            labeled(L("表示")) {
                ChoiceButtons(selection: valueBinding(13),
                              items: ClockText.formats.indices.map { (Double($0), ClockText.formats[$0]) })
                    .help(L("自動：1 時間以上は 時:分:秒、それより短いと 分:秒。カウントダウン・タイマーの最後の 10 秒は数字だけ"))
            }
            labeled(L("秒より細かく")) {
                ChoiceButtons(selection: valueBinding(14), items: [(0.0, L("なし")), (1.0, "1/10"), (2.0, "1/100")])
            }
        }
    }

    /// 時刻・長さの数字（ドラッグ・ダブルクリックで入力）
    private func timeFields(_ items: [(Int, String)]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { i, unit in
                let p = effect.kind.params[i]
                ValueDrag(label: unit, value: valueBinding(i), range: p.range, perPoint: p.perPoint,
                          defaultValue: p.defaultValue, format: { String(format: "%02.0f", $0) })
                    .frame(height: UI.rowHeight)
            }
        }
    }

    /// 左に名前を付けた行（狭いときは名前を上に）
    @ViewBuilder
    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        let row = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        row {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: narrow ? nil : 76, alignment: .leading)
                .padding(.top, narrow ? 0 : 6)
            content()
        }
    }

    /// ストロボの切り替え（1 クリックで切り替わるスイッチ）
    private var strobeSwitches: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 狭いときは縦に
            let row = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 16))
            row {
                segmented(0, [L("色で光る"), L("消える"), L("反転")], width: narrow ? paramsWidth - 24 : UI.paramColumnWidth)
                segmented(1, ["BPM", L("秒", note: "選択")], width: 120)
            }
            if effect.value(1) < 0.5 {
                HStack(spacing: 8) {
                    Text(L("間隔")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    segmented(2, ["1/16", "1/8", "1/4", "1/2", "1", "2", "4"], width: max(paramsWidth - 96, 120))
                    Text(L("拍")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .help(L("何拍ごとに光るか（BPM に合わせる）"))
            }
        }
        .opacity(effect.enabled ? 1 : 0.5)
    }

    private func segmented(_ i: Int, _ labels: [String], width: CGFloat) -> some View {
        ChoiceButtons(selection: valueBinding(i), items: labels.indices.map { (Double($0), labels[$0]) })
            .frame(width: width)
    }

    private var mixBinding: Binding<Double> {
        Binding(get: { effect.mix }, set: { v in var e = effect; e.mix = min(max(v, 0), 1); effect = e })
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
                Text(L("パレット")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Menu(L("ひな形")) {
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
                    .help(L("並びを逆にする（明暗を入れ替える）"))
            }
            // 暗い → 明るいのグラデーション
            LinearGradient(colors: palette.map { Color(rgb: $0) }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack(spacing: 6) {
                ForEach(palette.indices, id: \.self) { i in
                    ColorWell(color: Binding(get: { palette[min(i, palette.count - 1)] },
                                             set: { if palette.indices.contains(i) { palette[i] = $0 } }),
                              width: 44)
                        .contextMenu {
                            Button(L("この色を外す")) { if palette.count > 2 { palette.remove(at: i) } }
                                .disabled(palette.count <= 2)
                        }
                }
                if palette.count < Effect.maxPalette {
                    Button {
                        palette.append(palette.last ?? .white)
                    } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                        .controlSize(.large)
                        .help(L("色を足す（\(Effect.maxPalette) 色まで）"))
                }
                Spacer(minLength: 0)
            }
            Text(L("左が暗い所、右が明るい所の色。色をクリックで変更、右クリックで外す"))
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
