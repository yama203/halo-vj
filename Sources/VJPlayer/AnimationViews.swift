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
                HStack(spacing: 6) {
                    Picker("", selection: $anim.motion) {
                        ForEach(AnimMotion.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(width: 112)
                    if anim.mode == .time {
                        ValueDrag(label: "周期", value: $anim.seconds, range: 0.1...120, perPoint: 0.02, defaultValue: 4,
                                  format: { String(format: "%.1f秒", $0) })
                    } else {
                        Picker("", selection: $anim.beats) {
                            ForEach(ParamAnim.beatChoices, id: \.self) { Text(ParamAnim.beatsLabel($0)).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.large)
                    }
                }
                .frame(height: UI.rowHeight)
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
struct EffectsSection<H: ObservableObject & EffectHolder>: View {
    @ObservedObject var holder: H

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("エフェクト")
            // 右下の「エフェクト」一覧からここへドラッグ
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.rectangle").foregroundStyle(.purple)
                Text(holder.effects.isEmpty
                     ? "右下の「エフェクト」からドラッグして追加（上から順にかかります）"
                     : "右下の「エフェクト」からドラッグして追加")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.purple.opacity(0.5)))
            .effectDropTarget { holder.addEffect($0) }
            ForEach(holder.effects) { e in
                EffectCard(effect: binding(e.id), origin: (holder as? Animatable)?.animOrigin ?? 0, isFirst: holder.effects.first?.id == e.id,
                           isLast: holder.effects.last?.id == e.id,
                           move: { holder.moveEffect(e.id, by: $0) }, remove: { holder.removeEffect(e.id) })
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

    var body: some View {
        let params = effect.kind.params
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: $effect.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("オン／オフ")
                Text(effect.kind.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(effect.enabled ? Color.primary : Color.secondary)
                    .help(effect.kind.help)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up").frame(width: 18) }
                    .disabled(isFirst).help("上へ（先にかける）")
                Button { move(1) } label: { Image(systemName: "chevron.down").frame(width: 18) }
                    .disabled(isLast).help("下へ（あとにかける）")
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash").frame(width: 18) }
                    .help("このエフェクトを外す")
            }
            .controlSize(.regular)
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
                        Picker(p.label, selection: valueBinding(i)) {
                            ForEach(choices.indices, id: \.self) { c in Text(choices[c]).tag(Double(c)) }
                        }
                        .controlSize(.large)
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
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
    }

    /// その値を出すか（カラーライズのパレットモードでは「明るさを保つ」は使わない）
    private func shows(_ i: Int) -> Bool {
        !(effect.kind == .colorize && i == 1 && effect.value(0) > 0.5)
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
