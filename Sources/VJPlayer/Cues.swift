import AppKit
import SwiftUI

/// キュー：本番で出すものを順に並べたもの。GO で次へ進む
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

    static let fadeChoices: [Double?] = [nil, 0, 0.5, 1, 2, 3, 5, 8]
    static func fadeLabel(_ f: Double?) -> String {
        guard let f else { return "設定どおり" }
        return f <= 0 ? "カット" : String(format: f < 1 ? "%.1f秒" : "%.0f秒", f)
    }
}

extension Engine {
    /// GO を受け付けない間（押し間違いの連打よけ）
    static let goGuard = 0.5

    /// 次に出すキューの番号
    var nextCue: Int? {
        let n = (currentCue ?? -1) + 1
        return cues.indices.contains(n) ? n : nil
    }

    /// GO：次のキューを出す
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
            if c.onlyThisClip {
                // このクリップだけ：ほかのレイヤーはフェードして止める
                let others = layers.indices.filter { $0 != layer && activeByLayer[$0] != nil }
                fadeOutAndStop(others, duration: c.fade ?? layers[layer].fadeTime)
            }
        case .stopAll:
            finishCueFade()
            stopAll()
        }
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
            return (c.onlyThisClip ? "クリップだけ：" : "L\(layer + 1) を差し替え：") + s.name
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

/// キューリストのパネル：今・次、GO・戻る、一覧
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
                    Label("GO", systemImage: "play.fill")
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
                Text("スペースで GO・⇧スペースで戻る・ダブルクリックで飛ぶ")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if engine.cues.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.number").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("出すものを順に並べておくと、GO（スペース）で次々に出せます。\nシーンや、グリッドのクリップの名前の帯をここへドラッグ。「キューを足す」や右クリックからも足せます")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(engine.cues.enumerated()), id: \.element.id) { i, c in
                        CueRow(index: i, cue: c)
                    }
                    .onMove { engine.moveCue(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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

    var body: some View {
        let now = engine.currentCue == index
        let next = engine.nextCue == index
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .frame(width: 24, alignment: .trailing)
            Image(systemName: engine.cueIcon(cue)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.cueTitle(cue)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !cue.note.isEmpty {
                    Text(cue.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(Cue.fadeLabel(cue.fade))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(cue.fade == nil ? Color.secondary : Color.teal)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(now ? Color.green.opacity(0.25) : (next ? Color.orange.opacity(0.15) : Color.clear)))
        .overlay(alignment: .leading) {
            if now { Rectangle().fill(Color.green).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { engine.fireCue(index) }
        .contextMenu {
            Button("このキューを出す") { engine.fireCue(index) }
            Menu("フェード（\(Cue.fadeLabel(cue.fade))）") {
                ForEach(Cue.fadeChoices, id: \.self) { f in
                    Button((cue.fade == f ? "✓ " : "") + Cue.fadeLabel(f)) { engine.updateCue(cue.id) { $0.fade = f } }
                }
            }
            if case .clip = cue.kind {
                Toggle("ほかのレイヤーはそのまま（このレイヤーだけ差し替え）", isOn: Binding(
                    get: { cue.keepOthers ?? false },
                    set: { v in engine.updateCue(cue.id) { $0.keepOthers = v ? true : nil } }))
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
