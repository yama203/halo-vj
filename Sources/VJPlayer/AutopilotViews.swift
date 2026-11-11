import SwiftUI

/// 上のバーの「オート」：押すと自動操縦のオン・オフ、右の ▾ で設定。オンのあいだは次の切り替えまでの時間が出る
struct AutopilotButton: View {
    @EnvironmentObject var engine: Engine
    /// 画面確認用：VJ_AUTOPILOT_OPEN を付けると、はじめから設定を開く
    @State private var open = ProcessInfo.processInfo.environment["VJ_AUTOPILOT_OPEN"] != nil

    var body: some View {
        AutopilotButtonBody(runner: engine.autoRunner, open: $open)
    }
}

private struct AutopilotButtonBody: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var runner: AutopilotRunner
    @Binding var open: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button {
                engine.setAutopilot(!runner.isOn)
                // 初めてオンにしたら、作ったルールを見せる
                if runner.isOn && engine.autopilot.rules.count > 0 && !UserDefaults.standard.bool(forKey: "autopilot.seen") {
                    UserDefaults.standard.set(true, forKey: "autopilot.seen")
                    open = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: runner.isOn ? "airplane.circle.fill" : "airplane.circle")
                        .foregroundStyle(runner.isOn ? Color.green : Color.primary)
                    if runner.isOn, let n = runner.nextInfo {
                        Text(L("オート \(AutopilotButtonBody.clock(n.seconds))"))
                            .monospacedDigit()
                            .foregroundStyle(Color.green)
                    } else {
                        Text(L("オート"))
                    }
                }
            }
            .help(runner.isOn ? L("自動操縦を止める（次の切り替えまでの時間）") : L("自動操縦：決めたルールでシーン・クリップを回し続ける（席を離れるときに）"))
            Button { open.toggle() } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                .help(L("自動操縦のルール"))
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    AutopilotSettings(runner: runner).padding(16).frame(width: 600)
                }
        }
        .contextMenu {
            ControlMenuItems(address: "/halo/auto", verb: L("切り替え"), title: L("自動操縦のオン・オフ"))
        }
    }

    static func clock(_ s: Double) -> String {
        let t = max(Int(s.rounded(.up)), 0)
        return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : L("\(t)秒")
    }
}

/// 自動操縦の設定：ルールの一覧と、人が操作したら休む時間
struct AutopilotSettings: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var runner: AutopilotRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 大きなオン・オフ
            HStack(spacing: 12) {
                Button { engine.setAutopilot(!runner.isOn) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: runner.isOn ? "airplane.circle.fill" : "airplane.circle")
                            .font(.system(size: 26))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(runner.isOn ? L("自動操縦中") : L("自動操縦はオフ")).font(.system(size: 15, weight: .bold))
                            Text(runner.isOn ? L("押すと止める") : L("押すと始める")).font(.system(size: 10)).opacity(0.8)
                        }
                    }
                    .foregroundStyle(runner.isOn ? Color.black : Color.primary)
                    .padding(.horizontal, 14).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 10).fill(runner.isOn ? Color.green : Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                Spacer()
                if runner.isOn, let n = runner.nextInfo {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L("次の切り替え")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(AutopilotButtonBody.clock(n.seconds)).font(.system(size: 20, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.green)
                        Text(n.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Text(L("席を離れているあいだも、下のルールでシーン・クリップを回し続けます。開き直したときはいつもオフ。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if engine.autopilot.rules.isEmpty {
                Text(L("ルールがありません。下のボタンで足すか、「おまかせ」で作ってください。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(engine.autopilot.rules.indices, id: \.self) { i in
                            if i < engine.autopilot.rules.count {
                                AutoRuleCard(rule: $engine.autopilot.rules[i], runner: runner) {
                                    engine.autopilot.rules.remove(at: i)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 560)
            }

            HStack(spacing: 6) {
                Button { engine.autopilot.rules.append(AutoRule(target: .scenes)) } label: {
                    Label(L("シーンを回すルール"), systemImage: "rectangle.stack.badge.plus")
                }
                .help(L("シーンを、決めた間隔で切り替えるルールを足す"))
                Menu {
                    ForEach(engine.layers.indices, id: \.self) { r in
                        Button("L\(r + 1)" + (engine.layers[r].title.isEmpty ? "" : L("（\(engine.layers[r].title)）"))) {
                            engine.autopilot.rules.append(AutoRule(target: .layer(r), unit: .bars, every: 16, jitter: 0))
                        }
                    }
                } label: {
                    Label(L("クリップを回すルール"), systemImage: "square.3.layers.3d")
                }
                .fixedSize()
                .help(L("選んだレイヤーのクリップを、決めた間隔で切り替えるルールを足す"))
                Spacer()
                Button {
                    let p = AutoPilot.suggested(sceneCount: engine.scenes.count, layerCount: engine.layers.count) {
                        engine.layers[$0].isAdjustment
                    }
                    engine.autopilot.rules = p.rules
                } label: {
                    Label(L("おまかせで作る"), systemImage: "wand.and.stars")
                }
                .help(L("シーンが 2 つ以上あれば 3 分ごとにシーンを、無ければ絵のあるレイヤーを 32 小節ごとに、ばらばらに回すルールにする"))
            }
            Divider()
            HStack {
                Label(L("人が操作したら休む"), systemImage: "hand.raised.fill").font(.system(size: 12))
                Picker("", selection: $engine.autopilot.pauseAfterManual) {
                    Text(L("休まない")).tag(0.0)
                    Text(L("30 秒")).tag(30.0)
                    Text(L("1 分")).tag(60.0)
                    Text(L("3 分")).tag(180.0)
                    Text(L("5 分")).tag(300.0)
                }
                .labelsHidden().frame(width: 110)
                Text(L("シーンやクリップを手で出すと、そのルールはこのあいだ止まる"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// ルールで回すもの（シーン・クリップ）の、絵と名前
private enum AutoItem {
    static var cache: [String: NSImage] = [:]

    static func info(_ key: String?, rule: AutoRule, engine: Engine) -> (image: NSImage?, name: String)? {
        guard let key else { return nil }
        switch rule.target {
        case .scenes:
            guard let sc = engine.scenes.first(where: { $0.id.uuidString == key }) else { return nil }
            var img: NSImage?
            if let d = sc.thumbnail {
                let ck = key + "-\(d.count)"
                if let c = cache[ck] { img = c } else if let n = NSImage(data: d) { cache[ck] = n; img = n }
            }
            return (img, sc.name)
        case .layer:
            guard let slot = engine.slots.compactMap({ $0 }).first(where: { $0.id.uuidString == key }) else { return nil }
            return (slot.thumbnail, slot.name)
        }
    }
}

/// 16:9 の小さな絵（無ければ印）と、その下の名前
private struct AutoThumb: View {
    let image: NSImage?
    let name: String?
    var caption: String? = nil
    var width: CGFloat = 132
    var dim = false
    var placeholder = "questionmark"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: placeholder).font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .topLeading) {
                if let caption {
                    Text(caption).font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .padding(4)
                }
            }
            .opacity(dim ? 0.35 : 1)
            Text(name ?? "—").font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
                .frame(width: width, alignment: .leading)
                .foregroundStyle(name == nil ? Color.secondary : Color.primary)
        }
    }
}

/// ルール 1 つ
private struct AutoRuleCard: View {
    @EnvironmentObject var engine: Engine
    @Binding var rule: AutoRule
    @ObservedObject var runner: AutopilotRunner
    let onDelete: () -> Void

    private var targetIcon: String {
        if case .scenes = rule.target { return "rectangle.stack.fill" }
        return "square.3.layers.3d"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // いちばん上：何を回すか・使う・今すぐ次へ・消す
            HStack(spacing: 8) {
                Image(systemName: targetIcon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(rule.on ? Color.accentColor : Color.secondary)
                Picker("", selection: $rule.target) {
                    Label(L("シーンを回す"), systemImage: "rectangle.stack").tag(AutoRule.Target.scenes)
                    ForEach(engine.layers.indices, id: \.self) { r in
                        Text(L("L\(r + 1) のクリップを回す")).tag(AutoRule.Target.layer(r))
                    }
                }
                .labelsHidden().frame(width: 190)
                Spacer()
                Toggle(L("使う"), isOn: $rule.on).toggleStyle(.switch).controlSize(.small)
                    .help(L("このルールを使う・休ませる"))
                Button { runner.skip(rule.id) } label: { Label(L("今すぐ次へ"), systemImage: "forward.end.fill") }
                    .help(L("待たずに、このルールで 1 回切り替える"))
                    .disabled(!rule.on)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help(L("このルールを消す"))
            }
            // いま → つぎ（残り時間）
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in flow }
            // 間隔・選び方・切り替え
            settings
            // 使うもの
            pool
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(rule.on ? 0.06 : 0.025)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(runner.isOn && rule.on ? Color.green.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 1))
        .opacity(rule.on ? 1 : 0.6)
    }

    /// 今出ているもの → 次に出すもの、そのあいだに残り時間
    @ViewBuilder private var flow: some View {
        let st = runner.status(rule.id)
        let curKey: String? = {
            switch rule.target {
            case .scenes: return engine.activeSceneID?.uuidString
            case .layer(let r):
                guard engine.activeByLayer.indices.contains(r), let a = engine.activeByLayer[r] else { return nil }
                return engine.slots[a]?.id.uuidString
            }
        }()
        let cur = AutoItem.info(curKey, rule: rule, engine: engine)
        let next = AutoItem.info(st?.planned, rule: rule, engine: engine)
        HStack(alignment: .center, spacing: 10) {
            AutoThumb(image: cur?.image, name: cur?.name ?? L("なし"), caption: L("いま"), placeholder: "minus")
            VStack(spacing: 6) {
                if let st, runner.isOn, rule.on {
                    let p = 1 - min(max(st.left / st.total, 0), 1)
                    Image(systemName: st.paused ? "hand.raised.fill" : "arrow.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(st.paused ? Color.orange : Color.green)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(st.paused ? Color.orange : Color.green).frame(width: g.size.width * p)
                        }
                    }
                    .frame(height: 6)
                    Text(st.paused ? L("休み中 \(AutopilotButtonBody.clock(st.left))") : L("あと \(AutopilotButtonBody.clock(st.left))"))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(st.paused ? Color.orange : Color.green)
                } else {
                    Image(systemName: "arrow.right").font(.system(size: 18, weight: .bold)).foregroundStyle(.secondary)
                    Text(rule.intervalText).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(runner.isOn ? L("このルールは休み") : L("オンにすると始まる")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            AutoThumb(image: next?.image, name: next?.name ?? (runner.isOn ? L("（選べるものなし）") : L("オンで決まる")),
                      caption: L("つぎ"), dim: !(runner.isOn && rule.on), placeholder: rule.pick == .random ? "shuffle" : "arrow.right.to.line")
        }
    }

    @ViewBuilder private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(.secondary).frame(width: 18)
                ValueDrag(label: L("間隔"), value: $rule.every, range: rule.unit == .bars ? 1...256 : (rule.unit == .seconds ? 2...600 : 0.5...120),
                          perPoint: rule.unit == .bars ? 0.1 : 0.05, defaultValue: rule.unit == .bars ? 16 : 3,
                          format: { v in L("\(v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)) \(rule.unit.label)ごと") })
                    .frame(height: 26)
                Picker("", selection: Binding(get: { rule.unit }, set: { u in
                    // 単位を変えたら、ちょうどよい間隔にする
                    if u != rule.unit { rule.every = u == .bars ? 16 : (u == .seconds ? 30 : 3) }
                    rule.unit = u
                })) {
                    ForEach(AutoRule.Unit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            if rule.unit != .bars {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path").foregroundStyle(.secondary).frame(width: 18)
                    ValueDrag(label: L("ゆらぎ"), value: $rule.jitter, range: 0...0.5, perPoint: 0.002, defaultValue: 0.2,
                              format: { String(format: "±%.0f%%", $0 * 100) })
                        .frame(width: 180, height: 24)
                    Text(L("間隔を少しずつ変えて、機械的に見えないように")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: rule.pick == .random ? "shuffle" : "arrow.right.to.line").foregroundStyle(.secondary).frame(width: 18)
                Picker("", selection: $rule.pick) {
                    Label(L("ばらばら"), systemImage: "shuffle").tag(AutoRule.Pick.random)
                    Label(L("順に"), systemImage: "arrow.right.to.line").tag(AutoRule.Pick.sequence)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                .help(L("ばらばら：今のもの・最近出したものを避けて選ぶ／順に：並びの次へ"))
                Spacer()
                Image(systemName: "rectangle.2.swap").foregroundStyle(.secondary)
                Picker("", selection: $rule.fade) {
                    Text(rule.target == .scenes ? L("シーンの設定") : L("レイヤーの設定")).tag(Double?.none)
                    Text(L("すぐ")).tag(Double?.some(0))
                    ForEach([0.5, 1, 2, 4, 8], id: \.self) { s in Text(String(format: s < 1 ? L("%.1f 秒") : L("%.0f 秒"), s)).tag(Double?.some(s)) }
                }
                .labelsHidden().frame(width: 140)
                .help(L("切り替えにかける時間"))
            }
        }
    }

    /// どれから選ぶか（シーン・クリップの絵）。押すと外す・入れる。何も外さなければ全部
    @ViewBuilder private var pool: some View {
        switch rule.target {
        case .scenes:
            if engine.scenes.isEmpty {
                Label(L("シーンがありません（「シーン」パネルで作る）"), systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                PoolTiles(title: L("使うシーン"), items: engine.scenes.map { ($0.id.uuidString, AutoItem.info($0.id.uuidString, rule: rule, engine: engine)) },
                          selected: Binding(get: { Set((rule.sceneIDs ?? engine.scenes.map(\.id)).map(\.uuidString)) },
                                            set: { s in
                                                let ids = engine.scenes.map(\.id).filter { s.contains($0.uuidString) }
                                                rule.sceneIDs = ids.count == engine.scenes.count ? nil : ids
                                            }))
            }
        case .layer(let r):
            let filled = (0..<engine.columns).filter { c in
                let i = engine.slotIndex(deck: engine.currentDeck, layer: r, column: c)
                return engine.slots.indices.contains(i) && engine.slots[i] != nil
            }
            if filled.isEmpty {
                Label(L("このレイヤーには、今のデッキにクリップがありません"), systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                PoolTiles(title: L("使うクリップ"), items: filled.map { c in
                    let i = engine.slotIndex(deck: engine.currentDeck, layer: r, column: c)
                    let slot = engine.slots[i]
                    return ("\(c)", slot.map { (image: $0.thumbnail, name: "\(c + 1)  " + $0.name) })
                }, selected: Binding(get: { Set((rule.columns ?? filled).map { "\($0)" }) },
                                     set: { s in
                                         let cols = filled.filter { s.contains("\($0)") }
                                         rule.columns = cols.count == filled.count ? nil : cols
                                     }))
            }
        }
    }
}

/// 使うものの絵を並べる（押すと外す・入れる。最後の 1 つは外せない）
private struct PoolTiles: View {
    let title: String
    let items: [(id: String, info: (image: NSImage?, name: String)?)]
    @Binding var selected: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(selected.count) / \(items.count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Text(L("押すと外す・入れる")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(items, id: \.id) { it in
                    let on = selected.contains(it.id)
                    Button {
                        var s = selected
                        if on { if s.count > 1 { s.remove(it.id) } } else { s.insert(it.id) }
                        selected = s
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            AutoThumb(image: it.info?.image, name: it.info?.name, width: 84, dim: !on, placeholder: "photo")
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(on ? Color.green : Color.white.opacity(0.7))
                                .background(Circle().fill(Color.black.opacity(0.6)))
                                .padding(3)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
