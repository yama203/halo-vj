import AppKit
import SwiftUI

/// キュー：本番で出すものを順に並べたもの。「次へ」で次々に出す
struct Cue: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        /// シーンを呼ぶ
        case scene(UUID)
        /// クリップを 1 つ出す（デッキ・段・列で指す）
        case clip(deck: UUID, layer: Int, column: Int)
        /// 全レイヤーを止める
        case stopAll
    }
    var id = UUID()
    var kind: Kind
    /// フェード秒数（nil = シーン・レイヤーの設定のまま）
    var fade: Double?
    /// きっかけなどのメモ
    var note = ""
    /// クリップのキュー：ほかのレイヤーはそのまま（nil / false = このクリップだけを出す）
    var keepOthers: Bool?
    var onlyThisClip: Bool { !(keepOthers ?? false) }
    /// クリップのキュー：「終わったら」をこのキューで決める（nil = クリップの設定のまま）。キューで出したときだけ効く
    var endAction: EndAction?

    static let fadeChoices: [Double?] = [nil, 0, 0.5, 1, 2, 3, 5, 8]
    static func fadeLabel(_ f: Double?) -> String {
        guard let f else { return "元の設定" }
        return seconds(f)
    }
    static func seconds(_ f: Double) -> String {
        f <= 0 ? "カット" : String(format: f < 1 ? "%.1f秒" : "%.0f秒", f)
    }
}

extension Engine {
    /// 「次へ」を受け付けない間（押し間違いの連打よけ）
    static let goGuard = 0.5

    /// 次に出すキューの番号
    var nextCue: Int? {
        let n = (currentCue ?? -1) + 1
        return cues.indices.contains(n) ? n : nil
    }

    /// 次へ：次のキューを出す
    @discardableResult
    func goCue() -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastGoHost >= Self.goGuard, let n = nextCue else { return false }
        lastGoHost = now
        fireCue(n)
        return true
    }

    /// 1 つ前のキューに戻る（そのキューを出し直す）
    @discardableResult
    func backCue() -> Bool {
        guard let c = currentCue, c > 0 else { return false }
        lastGoHost = CACurrentMediaTime()
        fireCue(c - 1)
        return true
    }

    /// i 番目のキューを出す（一覧のダブルクリックで飛ぶときも）
    func fireCue(_ i: Int) {
        guard cues.indices.contains(i) else { return }
        let c = cues[i]
        currentCue = i
        switch c.kind {
        case .scene(let id):
            recallScene(id, fade: c.fade)
        case .clip(let deck, let layer, let column):
            guard let idx = cueSlotIndex(deck: deck, layer: layer, column: column) else { NSSound.beep(); return }
            finishCueFade()
            trigger(idx, fadeTime: c.fade, select: false)
            // 「終わったら」の上書き（クリップの設定は変えない。普通に出し直すと外れる）
            slots[idx]?.endActionOverride = c.endAction
            if c.onlyThisClip {
                // このクリップだけ：ほかのレイヤーはフェードして止める
                let others = layers.indices.filter { $0 != layer && activeByLayer[$0] != nil }
                fadeOutAndStop(others, duration: c.fade ?? layers[layer].fadeTime)
            }
        case .stopAll:
            // フェードがあれば、だんだん暗くしてから止める
            finishCueFade()
            fadeOutAndStop(layers.indices.filter { activeByLayer[$0] != nil }, duration: c.fade ?? 0)
        }
    }

    /// キューのフェードの表示。時間を決めていなければ、元の設定（シーン・レイヤー）の実際の時間
    func cueFadeText(_ c: Cue) -> String {
        if let f = c.fade { return Cue.seconds(f) }
        switch c.kind {
        case .scene(let id):
            return "シーンの設定（" + Cue.seconds(scenes.first { $0.id == id }?.fade ?? 0) + "）"
        case .clip(_, let layer, _):
            return "レイヤーの設定（" + Cue.seconds(layers.indices.contains(layer) ? layers[layer].fadeTime : 0) + "）"
        case .stopAll:
            return "カット"
        }
    }

    /// フェードの選択肢の「元の設定」の名前
    func cueDefaultFadeName(_ c: Cue) -> String {
        switch c.kind {
        case .scene: "シーンに付けたフェード時間"
        case .clip: "レイヤーの切り替えフェード時間"
        case .stopAll: "カット（すぐ暗転）"
        }
    }

    /// キューを id のものを index 番目の前へ動かす（index = 個数なら最後へ）
    func moveCue(_ id: UUID, before index: Int) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        // 自分の前・自分の直後の前へは動かしても変わらない
        guard index != i && index != i + 1 else { return }
        moveCue(from: IndexSet(integer: i), to: min(max(index, 0), cues.count))
    }

    /// レイヤーを duration 秒で薄くしてから止める（止めたら不透明度は元に戻す）
    func fadeOutAndStop(_ rs: [Int], duration T: Double) {
        guard !rs.isEmpty else { return }
        guard T > 0 else { rs.forEach(stopLayer); return }
        for r in rs where cueFadeLayers[r] == nil { cueFadeLayers[r] = layers[r].opacity }
        let start = cueFadeLayers
        let t0 = CACurrentMediaTime()
        cueFadeTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = min((CACurrentMediaTime() - t0) / T, 1)
            if p >= 1 { self.finishCueFade(); return }
            let k = 1 - p * p * (3 - 2 * p)
            for (r, o) in start where self.cueFadeLayers[r] != nil && self.layers.indices.contains(r) {
                self.layers[r].opacity = o * k
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cueFadeTimer = timer
    }

    /// 消している途中のレイヤーを、すぐ止めて不透明度を元に戻す
    func finishCueFade() {
        cueFadeTimer?.invalidate()
        cueFadeTimer = nil
        let rs = cueFadeLayers
        cueFadeLayers = [:]
        for (r, o) in rs where layers.indices.contains(r) {
            stopLayer(r)
            layers[r].opacity = o
        }
    }

    /// そのレイヤーを消すのをやめる（出し直したとき）
    func cancelCueFade(layer r: Int) {
        guard let o = cueFadeLayers.removeValue(forKey: r) else { return }
        if layers.indices.contains(r) { layers[r].opacity = o }
        if cueFadeLayers.isEmpty { cueFadeTimer?.invalidate(); cueFadeTimer = nil }
    }

    /// キューのクリップの場所（見つからなければ nil）
    func cueSlotIndex(deck: UUID, layer: Int, column: Int) -> Int? {
        guard let d = deckIndex(deck), layers.indices.contains(layer), column >= 0, column < columns else { return nil }
        let i = slotIndex(deck: d, layer: layer, column: column)
        return slots[i] != nil ? i : nil
    }

    /// キューの表示名
    func cueTitle(_ c: Cue) -> String {
        switch c.kind {
        case .scene(let id):
            return scenes.first { $0.id == id }.map { "シーン：" + $0.name } ?? "（見つからないシーン）"
        case .clip(let deck, let layer, let column):
            guard let i = cueSlotIndex(deck: deck, layer: layer, column: column), let s = slots[i] else { return "（見つからないクリップ）" }
            _ = layer
            return s.name
        case .stopAll:
            return "全停止（暗転）"
        }
    }

    func cueIcon(_ c: Cue) -> String {
        switch c.kind {
        case .scene: "square.stack.3d.up"
        case .clip: "film"
        case .stopAll: "stop.fill"
        }
    }

    /// キューを足す（i の後ろ。nil なら最後）
    func addCue(_ kind: Cue.Kind, after i: Int? = nil) {
        let c = Cue(kind: kind)
        if let i, cues.indices.contains(i) { cues.insert(c, at: i + 1) } else { cues.append(c) }
    }

    /// キューを index 番目に入れる
    func insertCue(_ kind: Cue.Kind, at index: Int) {
        let i = min(max(index, 0), cues.count)
        cues.insert(Cue(kind: kind), at: i)
        if let c = currentCue, c >= i { currentCue = c + 1 }
    }

    /// クリップの場所をキューにする
    func addClipCue(_ index: Int) {
        guard slots.indices.contains(index), slots[index] != nil else { return }
        addCue(.clip(deck: decks[deckOf(index)].id, layer: layerOf(index), column: columnOf(index)))
    }

    func removeCue(_ id: UUID) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        cues.remove(at: i)
        if let c = currentCue { currentCue = c == i ? (i > 0 ? i - 1 : nil) : (c > i ? c - 1 : c) }
    }

    func moveCue(from: IndexSet, to: Int) {
        let curID = currentCue.map { cues[$0].id }
        cues.move(fromOffsets: from, toOffset: to)
        currentCue = curID.flatMap { id in cues.firstIndex { $0.id == id } }
    }

    func updateCue(_ id: UUID, _ f: (inout Cue) -> Void) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        f(&cues[i])
    }

    /// レイヤーを足す・消す・動かしたとき、クリップのキューも付いていく
    func remapCueLayers(_ map: (Int) -> Int?) {
        guard !cues.isEmpty else { return }
        cues = cues.map { c in
            guard case .clip(let d, let l, let col) = c.kind, let nl = map(l) else { return c }
            var c2 = c
            c2.kind = .clip(deck: d, layer: nl, column: col)
            return c2
        }
    }
}

// MARK: - 画面

/// キューの一覧の場所（グリッドの名前の帯からドラッグしてきたクリップを受けるため。ウィンドウの中の位置）
final class CueDropTarget: ObservableObject {
    static let shared = CueDropTarget()
    var frame: CGRect = .zero
    @Published var hovering = false
    func track(_ p: CGPoint) {
        let h = frame.width > 0 && frame.contains(p)
        if h != hovering { hovering = h }
    }
}

/// キューリストのパネル：今・次、次へ・戻る、一覧
struct CuePanel: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var dropTarget = CueDropTarget.shared
    @State private var sceneDropTargeted = false

    var body: some View {
        content
            .background(GeometryReader { g in
                Color.clear.onAppear { dropTarget.frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in dropTarget.frame = f }
            })
            // グリッドの名前の帯・シーンからドラッグしてきたら、緑の枠
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green, lineWidth: 3)
                .opacity(dropTarget.hovering || sceneDropTargeted ? 1 : 0).allowsHitTesting(false))
            .onDrop(of: [.plainText], isTargeted: $sceneDropTargeted) { providers in
                guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String, s.hasPrefix("halovj-scene:"),
                          let id = UUID(uuidString: String(s.dropFirst("halovj-scene:".count))) else { return }
                    DispatchQueue.main.async { engine.addCue(.scene(id)) }
                }
                return true
            }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 今・次
            HStack(spacing: 8) {
                nowNext("今", engine.currentCue, tint: .green)
                nowNext("次", engine.nextCue, tint: .orange)
            }
            HStack(spacing: 8) {
                Button {
                    engine.backCue()
                } label: {
                    Label("戻る", systemImage: "backward.end.fill").frame(maxWidth: 80)
                }
                .controlSize(.large)
                .disabled((engine.currentCue ?? 0) <= 0)
                .help("1 つ前のキューを出し直す（⇧スペース）")
                Button {
                    engine.goCue()
                } label: {
                    Label("次へ", systemImage: "play.fill")
                        .font(.system(size: 16, weight: .heavy))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(engine.nextCue == nil)
                .help("次のキューを出す（スペース）。押し間違いの連打は \(String(format: "%.1f", Engine.goGuard)) 秒受け付けない")
            }
            HStack(spacing: 6) {
                Menu {
                    if engine.scenes.isEmpty {
                        Text("シーンがありません")
                    }
                    ForEach(engine.scenes) { s in
                        Button("シーン：" + s.name) { engine.addCue(.scene(s.id)) }
                    }
                    Divider()
                    Button("選んでいるクリップ（それだけを出す）") { if let i = engine.inspectedIndex { engine.addClipCue(i) } }
                        .disabled(engine.inspectedIndex.flatMap { engine.slots[$0] } == nil)
                    Button("全停止（暗転）") { engine.addCue(.stopAll) }
                } label: {
                    Label("キューを足す", systemImage: "plus")
                }
                .fixedSize()
                Spacer(minLength: 0)
                Text("スペースで次へ・⇧スペースで戻る・ダブルクリックで飛ぶ")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if engine.cues.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.number").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("出すものを順に並べておくと、「次へ」（スペース）で次々に出せます。\nシーンや、グリッドのクリップの名前の帯をここへドラッグ。「キューを足す」や右クリックからも足せます")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(Array(engine.cues.enumerated()), id: \.element.id) { i, c in
                            CueRow(index: i, cue: c)
                        }
                        // いちばん下：ここへ落とすと最後へ
                        CueEndDrop(count: engine.cues.count)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func nowNext(_ label: String, _ i: Int?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            if let i, engine.cues.indices.contains(i) {
                let c = engine.cues[i]
                Text("\(i + 1). " + engine.cueTitle(c))
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                Text(c.note.isEmpty ? " " : c.note)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(label == "次" ? "（終わり）" : "—").font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
                Text(" ").font(.system(size: 10))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.5)))
    }
}

/// キュー 1 行：番号・種類・名前・フェード・メモ
private struct CueRow: View {
    @EnvironmentObject var engine: Engine
    let index: Int
    let cue: Cue
    @State private var dropTargeted = false

    var body: some View {
        let now = engine.currentCue == index
        let next = engine.nextCue == index
        HStack(spacing: 8) {
            // つまみ：ドラッグで並べ替え（行のどこをつかんでもよい）
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .frame(width: 22, alignment: .trailing)
            CueThumb(cue: cue)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    CueModeIcons(cue: cue)
                    Text(engine.cueTitle(cue)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                if !cue.note.isEmpty {
                    Text(cue.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(engine.cueFadeText(cue))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(cue.fade == nil ? Color.secondary : Color.teal)
                .help(cue.fade == nil ? "フェード：" + engine.cueDefaultFadeName(cue) + "を使う（右クリックで変えられる）" : "フェード（右クリックで変えられる）")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(now ? Color.green.opacity(0.25) : (next ? Color.orange.opacity(0.15) : Color.clear)))
        .overlay(alignment: .leading) {
            if now { Rectangle().fill(Color.green).frame(width: 3) }
        }
        // 上に落とすと、この行の前に入る（青い線）
        .overlay(alignment: .top) {
            Rectangle().fill(Color.accentColor).frame(height: 3).offset(y: -2)
                .opacity(dropTargeted ? 1 : 0).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { engine.fireCue(index) }
        .onDrag { NSItemProvider(object: ("halovj-cue:" + cue.id.uuidString) as NSString) }
        .onDrop(of: [.plainText], isTargeted: $dropTargeted) { CueDrop.handle($0, engine: engine, at: index) }
        .contextMenu {
            Button("このキューを出す") { engine.fireCue(index) }
            Menu("フェード（\(engine.cueFadeText(cue))）") {
                ForEach(Cue.fadeChoices, id: \.self) { f in
                    let name = f == nil ? engine.cueDefaultFadeName(cue) + "に合わせる" : Cue.fadeLabel(f)
                    Button((cue.fade == f ? "✓ " : "") + name) { engine.updateCue(cue.id) { $0.fade = f } }
                }
            }
            Button("上へ") { engine.moveCue(cue.id, before: index - 1) }
                .disabled(index == 0)
            Button("下へ") { engine.moveCue(cue.id, before: index + 2) }
                .disabled(index >= engine.cues.count - 1)
            if case .clip = cue.kind {
                Toggle("ほかのレイヤーはそのまま（このレイヤーだけ差し替え）", isOn: Binding(
                    get: { cue.keepOthers ?? false },
                    set: { v in engine.updateCue(cue.id) { $0.keepOthers = v ? true : nil } }))
                CueEndActionMenu(cue: cue)
            }
            Button("メモを書く…") {
                if let n = askText(title: "キュー \(index + 1) のメモ（きっかけなど）", initial: cue.note) {
                    engine.updateCue(cue.id) { $0.note = n }
                }
            }
            Divider()
            Button("削除", role: .destructive) { engine.removeCue(cue.id) }
        }
        .help("ダブルクリックでこのキューを出す。ドラッグで並べ替え。右クリックでフェード・メモ・削除")
    }
}

/// キューの小さなサムネイル（シーン = 保存したときの絵、クリップ = クリップの絵、暗転 = 黒）。左下に種類の印
private struct CueThumb: View {
    @EnvironmentObject var engine: Engine
    let cue: Cue

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let slot = clipSlot {
                // クリップの絵は読み込みが後から終わるので、クリップを見張る
                CueClipThumb(slot: slot)
            } else if let img = sceneImage {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else if cue.kind != .stopAll {
                // 絵が無い（サムネイルの無いシーン・見つからないもの）→ 種類の印を大きく
                Image(systemName: missing ? "questionmark" : engine.cueIcon(cue))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Image(systemName: engine.cueIcon(cue))
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .padding(2)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
                .padding(1)
        }
        .frame(width: 48, height: 27)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.35)))
    }

    private var sceneImage: NSImage? {
        guard case .scene(let id) = cue.kind else { return nil }
        return engine.scenes.first { $0.id == id }?.thumbnail.flatMap { NSImage(data: $0) }
    }

    private var clipSlot: ClipSlot? {
        guard case .clip(let deck, let layer, let column) = cue.kind,
              let i = engine.cueSlotIndex(deck: deck, layer: layer, column: column) else { return nil }
        return engine.slots[i]
    }

    /// 指しているシーン・クリップが見つからない
    private var missing: Bool {
        switch cue.kind {
        case .scene(let id): !engine.scenes.contains { $0.id == id }
        case .clip: clipSlot == nil
        case .stopAll: false
        }
    }
}

private struct CueClipThumb: View {
    @ObservedObject var slot: ClipSlot
    var body: some View {
        if let img = slot.thumbnail {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "film").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// クリップのキューの印：出し方（このクリップだけ／そのレイヤーだけ差し替え）と、「終わったら」の上書き
private struct CueModeIcons: View {
    @EnvironmentObject var engine: Engine
    let cue: Cue

    var body: some View {
        if case .clip(_, let layer, _) = cue.kind {
            HStack(spacing: 3) {
                if cue.onlyThisClip {
                    Image(systemName: "square.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                        .help("このクリップだけを出す（ほかのレイヤーはフェードして止まる）")
                } else {
                    HStack(spacing: 1) {
                        Image(systemName: "square.3.layers.3d").font(.system(size: 10))
                        Text("L\(layer + 1)").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.orange)
                    .help("L\(layer + 1) だけ差し替える（ほかのレイヤーはそのまま）")
                }
                if let ea = cue.endAction {
                    Image(systemName: ea.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.teal)
                        .help("終わったら：" + ea.label + "（このキューで出したときだけ）")
                }
            }
        }
    }
}

/// クリップのキューの右クリック：「終わったら」を上書きする
private struct CueEndActionMenu: View {
    @EnvironmentObject var engine: Engine
    let cue: Cue

    var body: some View {
        let own = clipEndAction
        Menu("終わったら（" + (cue.endAction?.label ?? "クリップの設定") + "）") {
            Button((cue.endAction == nil ? "✓ " : "") + "クリップの設定のまま" + (own.map { "（" + $0.label + "）" } ?? "")) {
                engine.updateCue(cue.id) { $0.endAction = nil }
            }
            Divider()
            ForEach(EndAction.allCases) { ea in
                Button((cue.endAction == ea ? "✓ " : "") + ea.label) { engine.updateCue(cue.id) { $0.endAction = ea } }
            }
        }
    }

    private var clipEndAction: EndAction? {
        guard case .clip(let d, let l, let c) = cue.kind, let i = engine.cueSlotIndex(deck: d, layer: l, column: c) else { return nil }
        return engine.slots[i]?.endAction
    }
}

/// 一覧のいちばん下：ここへ落とすと最後へ
private struct CueEndDrop: View {
    @EnvironmentObject var engine: Engine
    let count: Int
    @State private var targeted = false
    var body: some View {
        Rectangle().fill(Color.clear)
            .frame(height: 36)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.accentColor).frame(height: 3).opacity(targeted ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onDrop(of: [.plainText], isTargeted: $targeted) { CueDrop.handle($0, engine: engine, at: count) }
    }
}

/// 一覧の行へのドロップ：キュー（並べ替え）かシーン（その位置に足す）
enum CueDrop {
    static func handle(_ providers: [NSItemProvider], engine: Engine, at index: Int) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String else { return }
            DispatchQueue.main.async {
                if s.hasPrefix("halovj-cue:"), let id = UUID(uuidString: String(s.dropFirst("halovj-cue:".count))) {
                    engine.moveCue(id, before: index)
                } else if s.hasPrefix("halovj-scene:"), let id = UUID(uuidString: String(s.dropFirst("halovj-scene:".count))) {
                    engine.insertCue(.scene(id), at: index)
                }
            }
        }
        return true
    }
}

/// 文字を入れてもらう（空でもよい。キャンセルなら nil）
func askText(title: String, initial: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "キャンセル")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespaces)
}
