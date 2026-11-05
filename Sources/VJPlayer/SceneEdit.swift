import AppKit
import Combine
import SwiftUI

/// 編集中のシーンの中身。出力とは別の、つながっていないレイヤーとコンポジションの設定を持つ。
/// 編集中は、上のグリッド・レイヤー欄・下のパネルがこれを表示して操作する（出力はそのまま）。
/// 変えるとすぐシーンに書き戻し、左下のプレビューに映る
final class SceneDraft: ObservableObject, EffectHolder, Animatable {
    let sceneID: UUID
    /// レイヤーごとの、再生するクリップの列（nil = なし）
    @Published var playing: [Int?] { didSet { onChanged?() } }
    /// レイヤーごとの、クリップのあるデッキの番号（playing を変える前に入れる）
    var layerDeck: [Int]
    /// 編集中に上のグリッドに出しているデッキ。シーンを呼び出したときに出すデッキになる
    @Published var shownDeck: Int { didSet { onChanged?() } }
    let layers: [Layer]
    let compTransform = TransformParams()
    @Published var masterOpacity: Double { didSet { onChanged?() } }
    /// コンポジションのエフェクト
    @Published var effects: [Effect] { didSet { onChanged?() } }
    /// コンポジション不透明度のアニメーション
    @Published var anims: [ParamKey: ParamAnim] { didSet { onChanged?() } }
    var animOrigin: Double { 0 }

    var onChanged: (() -> Void)? {
        didSet {
            compTransform.onChanged = onChanged
            for l in layers { l.onChanged = onChanged }
        }
    }

    init(scene: VJScene, layerCount n: Int, deck: Int, layerDeck: [Int]) {
        sceneID = scene.id
        playing = (0..<n).map { $0 < scene.playing.count ? scene.playing[$0] : nil }
        self.layerDeck = layerDeck
        shownDeck = deck
        layers = (0..<n).map { r in
            let l = Layer(index: r)
            if r < scene.layers.count { scene.layers[r].apply(to: l) }
            return l
        }
        masterOpacity = scene.masterOpacity
        effects = scene.compEffects
        anims = Engine.decodeAnims(scene.masterAnims)
        scene.compTransform.apply(to: compTransform)
    }
}

extension Engine.SavedLayer {
    init(_ l: Layer) {
        self.init(opacity: l.opacity, blend: l.blend.rawValue, volume: l.volume,
                  transform: Engine.SavedTransform(l.transform), fadeTime: l.fadeTime,
                  anims: Engine.encodeAnims(l.anims), effects: l.effects.isEmpty ? nil : l.effects,
                  muted: l.muted ? true : nil, audioMuted: l.audioMuted ? true : nil,
                  isAdjustment: l.isAdjustment ? true : nil,
                  blendFX: l.blend.isSpecial ? l.blendFX : nil)
    }

    func apply(to l: Layer) {
        l.opacity = min(max(opacity, 0), 1)
        l.blend = BlendMode(rawValue: blend) ?? .normal
        l.volume = min(max(volume, 0), 1)
        transform?.apply(to: l.transform)
        l.fadeTime = min(max(fadeTime ?? 0, 0), 10)
        l.anims = Engine.decodeAnims(anims)
        l.effects = effects ?? []
        l.muted = muted ?? false
        l.audioMuted = audioMuted ?? false
        l.isAdjustment = isAdjustment ?? false
        l.blendFX = blendFX ?? Effect(kind: .overdrive)
    }
}

extension Engine {
    /// 編集中のシーンの番号
    var editingSceneID: UUID? { sceneDraft?.sceneID }
    var editingScene: VJScene? { editingSceneID.flatMap { id in scenes.first { $0.id == id } } }

    // MARK: - 画面に出すもの（編集中ならシーン、そうでなければ出力中の状態）

    /// 上のグリッドに出しているデッキ
    var shownDeck: Int {
        guard let d = sceneDraft else { return currentDeck }
        return min(max(d.shownDeck, 0), decks.count - 1)
    }

    /// デッキのタブを押した
    func showDeck(_ d: Int) {
        guard decks.indices.contains(d) else { return }
        if shownDeck != d { multiSelection = [] }
        if let s = sceneDraft { s.shownDeck = d } else { currentDeck = d }
    }

    /// レイヤー欄・下のパネルに出すレイヤー
    func viewLayer(_ r: Int) -> Layer {
        if let d = sceneDraft, d.layers.indices.contains(r) { return d.layers[r] }
        return layers[min(max(r, 0), layers.count - 1)]
    }

    /// そのレイヤーで再生中（編集中ならシーンで再生する）のスロット
    func viewPlaying(_ r: Int) -> Int? {
        if let d = sceneDraft { return scenePlayingIndex(d, r) }
        return activeByLayer.indices.contains(r) ? activeByLayer[r] : nil
    }

    /// グリッドのクリップを押した：ふだんは再生、シーンの編集中はそのシーンで流すクリップにする
    func pressSlot(_ i: Int) {
        if sceneDraft != nil { setScenePlaying(i) } else { trigger(i) }
    }

    /// レイヤーの停止ボタン：編集中はシーンのそのレイヤーを「なし」にする
    func viewStop(_ r: Int) {
        if let d = sceneDraft {
            if d.playing.indices.contains(r) { d.playing[r] = nil }
        } else {
            stopLayer(r)
        }
    }

    /// シーンのそのレイヤーで流すスロット
    func scenePlayingIndex(_ d: SceneDraft, _ r: Int) -> Int? {
        guard d.playing.indices.contains(r), r < layers.count, let c = d.playing[r], c >= 0, c < columns else { return nil }
        let deck = d.layerDeck.indices.contains(r) ? min(max(d.layerDeck[r], 0), decks.count - 1) : 0
        let i = slotIndex(deck: deck, layer: r, column: c)
        return slots.indices.contains(i) && slots[i] != nil ? i : nil
    }

    /// 編集中のシーンで、i のクリップを流す（そのレイヤーの前のクリップの代わりに）
    func setScenePlaying(_ i: Int) {
        guard let d = sceneDraft, slots.indices.contains(i), slots[i] != nil else { return }
        let r = layerOf(i)
        guard d.playing.indices.contains(r) else { return }
        if d.layerDeck.indices.contains(r) { d.layerDeck[r] = deckOf(i) }
        d.playing[r] = columnOf(i)
    }

    // MARK: - 編集の始め・終わり

    /// シーンを編集する（出力はそのまま。グリッド・レイヤー欄・下のパネルがそのシーンになる）
    func editScene(_ id: UUID) {
        guard scenes.contains(where: { $0.id == id }) else { return }
        if sceneDraft?.sceneID != id { reloadSceneDraft(id) }
        if inspectorTab == .clip { inspectorTab = .composition }
        syncScenePreview()
    }

    /// 編集中のシーンを読み直す（上書きされたとき・レイヤーの数が変わったときなど）
    func reloadSceneDraft(_ id: UUID? = nil) {
        guard let id = id ?? sceneDraft?.sceneID, let sc = scenes.first(where: { $0.id == id }) else {
            closeSceneEditor()
            return
        }
        let base = deckIndex(sc.deck) ?? 0
        let ld = layers.indices.map { r in
            sc.layerDecks.flatMap { $0.indices.contains(r) ? deckIndex($0[r]) : nil } ?? base
        }
        let d = SceneDraft(scene: sc, layerCount: layers.count, deck: base, layerDeck: ld)
        d.onChanged = { [weak self, weak d] in
            guard let self, let d else { return }
            self.sceneDraftChanged(d)
        }
        sceneDraftSink = d.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        sceneDraft = d
        syncScenePreview()
    }

    func closeSceneEditor() {
        sceneThumbWork?.cancel()
        sceneThumbWork = nil
        sceneDraftSink = nil
        sceneDraft = nil
        syncScenePreview()
    }

    /// 編集の中身をシーンに書き込む（名前・フェード時間・サムネイルはそのまま）
    private func writeDraft(_ d: SceneDraft, to s: inout VJScene) {
        let deck = min(max(d.shownDeck, 0), decks.count - 1)
        s.playing = d.playing
        s.deck = decks[deck].id
        let ld: [UUID?] = d.playing.indices.map { r in
            guard d.playing[r] != nil, d.layerDeck.indices.contains(r), d.layerDeck[r] != deck,
                  decks.indices.contains(d.layerDeck[r]) else { return nil }
            return decks[d.layerDeck[r]].id
        }
        s.layerDecks = ld.contains { $0 != nil } ? ld : nil
        s.layers = d.layers.map(SavedLayer.init)
        s.masterOpacity = d.masterOpacity
        s.compTransform = SavedTransform(d.compTransform)
        s.masterAnims = Self.encodeAnims(d.anims)
        s.compEffects = d.effects
    }

    /// 編集の中身が変わった：シーンに書き戻して、プレビューを作り直し、少し後にサムネイルも撮り直す
    private func sceneDraftChanged(_ d: SceneDraft) {
        guard d === sceneDraft else { return }
        guard scenes.contains(where: { $0.id == d.sceneID }) else { closeSceneEditor(); return }
        updateScene(d.sceneID) { writeDraft(d, to: &$0) }
        syncScenePreview()
        sceneThumbWork?.cancel()
        let id = d.sceneID
        let work = DispatchWorkItem { [weak self] in
            // プレビューはクリップのタブ以外で描いている
            guard let self, self.sceneDraft?.sceneID == id, self.inspectorTab != .clip,
                  let png = RenderLoop.shared.snapshotPNG(from: RenderLoop.shared.lastScenePreview()) else { return }
            self.updateScene(id) { $0.thumbnail = png }
        }
        sceneThumbWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// 編集中のシーンのレイヤー数が今のレイヤー数と違えば読み直す（描画状態を作り直すたびに確かめる）
    func checkSceneDraftLayers() {
        guard let d = sceneDraft, d.layers.count != layers.count else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let d2 = self.sceneDraft, d2 === d, d2.layers.count != self.layers.count else { return }
            self.reloadSceneDraft()
        }
    }
}

// MARK: - 画面

/// グリッドの上の「シーンを編集中」の帯
struct SceneEditBanner: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        if let sc = engine.editingScene {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .bold))
                Text("シーン「\(sc.name)」を編集中")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Text("出力はそのまま。クリップを押すとこのシーンに入る")
                    .font(.system(size: 11))
                    .opacity(0.85)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    engine.recallScene(sc.id)
                } label: {
                    Label("出力に切り替え", systemImage: "play.fill")
                }
                .help("このシーンを出力に出す（\(VJScene.fadeLabel(sc.fade))）")
                Button {
                    engine.closeSceneEditor()
                } label: {
                    Label("編集を終える", systemImage: "xmark")
                }
            }
            .controlSize(.small)
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange))
        }
    }
}

/// このシーンのコンポジション（全体）の設定
struct SceneCompParams: View {
    @ObservedObject var draft: SceneDraft

    var body: some View {
        SideBySide {
            HStack(alignment: .top, spacing: 16) {
                ParamColumn(title: "トランスフォーム") {
                    MiniButton(icon: "arrow.counterclockwise", label: "リセット", disabled: draft.compTransform.isDefault,
                               help: "位置・スケール・角度を初期値に戻す") { draft.compTransform.reset() }
                } content: {
                    TransformFields(t: draft.compTransform)
                }
                ParamColumn(title: "マスター") {
                    AnimField(label: "不透明度", value: $draft.masterOpacity, range: 0...1, perPoint: 0.003,
                              defaultValue: 1, showsBar: true, format: { String(format: "%.0f%%", $0 * 100) },
                              key: .opacity, target: draft)
                        .frame(height: UI.rowHeight)
                }
            }
            .frame(width: UI.paramsWidth, alignment: .topLeading)
        } second: {
            EffectsSection(holder: draft)
        }
    }
}
