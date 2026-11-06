import AVFoundation
import Combine
import AppKit
import Metal
import simd

struct RenderParams {
    var homographyInverse: simd_float3x3
    var testPattern: Bool
    /// 出力に掛ける明るさ（マスター不透明度。ブラックアウト中は 0）
    var master: Float
    /// コンポジションプレビューに掛ける明るさ（ブラックアウトの影響を受けない）
    var compMaster: Float = 1
}

/// 表示中の映像フレーム。GPU が描画し終わるまで参照を持ち続けるための入れ物。
final class FrameHolder {
    let pixelBuffer: CVPixelBuffer?
    let cvTexture: CVMetalTexture?
    let texture: MTLTexture
    init(pixelBuffer: CVPixelBuffer, cvTexture: CVMetalTexture, texture: MTLTexture) {
        self.pixelBuffer = pixelBuffer
        self.cvTexture = cvTexture
        self.texture = texture
    }
    /// ジェネレーターが描いた絵
    init(texture: MTLTexture) {
        pixelBuffer = nil
        cvTexture = nil
        self.texture = texture
    }
}

final class Engine: ObservableObject, Animatable, EffectHolder {
    static let shared = Engine(persistent: true)

    /// 最初のグリッドの大きさ（段数 = レイヤー数、上の段ほど手前）
    static let defaultLayers = 4
    static let defaultColumns = 8
    /// 増やせる上限
    static let maxLayers = 16
    static let maxColumns = 64
    static let defaultCorners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]

    /// 1 段のクリップ数（列数）
    @Published private(set) var columns = Engine.defaultColumns
    var layerCount: Int { layers.count }
    /// 1 枚のグリッド（デッキ）のスロット数
    var gridSize: Int { layers.count * columns }
    /// 全デッキのスロット数
    var slotCount: Int { decks.count * gridSize }
    /// スロット番号 → レイヤー（段）
    func layerOf(_ slotIndex: Int) -> Int { (slotIndex % max(gridSize, 1)) / columns }
    /// スロット番号 → デッキ
    func deckOf(_ slotIndex: Int) -> Int { slotIndex / max(gridSize, 1) }
    /// スロット番号 → 列
    func columnOf(_ slotIndex: Int) -> Int { slotIndex % columns }
    /// デッキ・段・列 → スロット番号
    func slotIndex(deck d: Int, layer r: Int, column c: Int) -> Int { d * gridSize + r * columns + c }

    /// デッキ：グリッド 1 枚ぶん。何枚でも持てて、上のタブで切り替える。
    /// スロット番号は「デッキ × (段数 × 列数) + 段 × 列数 + 列」
    struct Deck: Identifiable, Equatable {
        var id = UUID()
        var name: String
    }
    @Published private(set) var decks: [Deck] = [Deck(name: "デッキ 1")]
    /// 上のグリッドに出しているデッキ
    @Published var currentDeck = 0 {
        didSet {
            if !decks.indices.contains(currentDeck) { currentDeck = max(min(currentDeck, decks.count - 1), 0) }
            if oldValue != currentDeck && sceneDraft == nil { multiSelection = [] }
        }
    }
    /// ⇧クリックで選んだ複数のクリップ（スロット番号）。まとめて削除・移動する
    @Published var multiSelection: Set<Int> = []

    /// スロット。番号は「段 × 列数 + 列」
    @Published private(set) var slots: [ClipSlot?] = Array(repeating: nil, count: Engine.defaultLayers * Engine.defaultColumns)
    @Published private(set) var layers: [Layer] = (0..<Engine.defaultLayers).map { Layer(index: $0) }
    /// 各レイヤーで再生中のスロット番号
    @Published private(set) var activeByLayer: [Int?] = Array(repeating: nil, count: Engine.defaultLayers)
    /// 選択中のレイヤー（最後にトリガー or レイヤー欄をクリック）。速度パネルとレイヤータブの対象
    @Published var selectedLayer = 0 {
        didSet { if oldValue != selectedLayer { syncRenderState() } }
    }
    /// 下のパラメーターパネルのタブ
    enum InspectorTab: String { case composition, layer, clip }
    @Published var inspectorTab = InspectorTab.clip

    // MARK: コンポジション（全体）
    /// コンポジション速度。再生中の全クリップの速度に掛かる（ライブ操作用なので保存しない）
    @Published var masterSpeed = 1.0 {
        didSet {
            guard oldValue != masterSpeed else { return }
            for slot in slots { slot?.masterRate = masterSpeed }
            syncRenderState()
        }
    }
    /// コンポジションのトランスフォーム（全レイヤーにかかる）
    let compTransform = TransformParams()
    /// コンポジションのエフェクト（全レイヤーを重ねた絵にかかる）
    @Published var effects: [Effect] = [] { didSet { syncRenderState(); scheduleSave() } }
    /// マスター不透明度のアニメーション
    @Published var anims: [ParamKey: ParamAnim] = [:] { didSet { syncRenderState(); scheduleSave() } }
    var animOrigin: Double { 0 }

    // MARK: BPM
    /// BPM の時計（アニメーションの BPM モードが使う）
    @Published private(set) var beatClock = BeatClock()
    private var tapTempo = TapTempo()

    var bpm: Double {
        get { beatClock.bpm }
        set {
            let b = min(max(newValue, 20), 300)
            guard b != beatClock.bpm else { return }
            beatClock.setBPM(b, at: CACurrentMediaTime())
            bpmChanged()
            scheduleSave()
        }
    }

    /// タップテンポ。押した瞬間を拍の頭にそろえる
    func tapTempo(at t: Double = CACurrentMediaTime()) {
        if let b = tapTempo.tap(at: t) {
            beatClock.setBPM(b, at: t)
            bpmChanged()
            scheduleSave()
        }
        // 押した瞬間がちょうど拍の頭になるようにずらす（何拍目かは保つ）
        let nearest = beatClock.beat(at: t).rounded()
        beatClock.anchorHost = t
        beatClock.anchorBeat = nearest
        bpmChanged()
    }

    /// BPM 同期のクリップに新しい BPM を伝える
    private func bpmChanged() {
        for slot in slots { slot?.beatClock = beatClock }
        syncRenderState()
    }

    /// 今を 1 拍目（小節の頭）にする
    func resyncBeat() {
        beatClock.resync(at: CACurrentMediaTime())
        bpmChanged()
    }
    /// マスター不透明度（出力全体をフェード）
    // MARK: シーン
    /// お気に入りの組み合わせ（保存される）
    @Published var scenes: [VJScene] = [] { didSet { scheduleSave() } }
    /// 最後に呼び出した（保存した）シーン
    @Published var activeSceneID: UUID?
    /// シーンを切り替えている途中なら 0〜1
    @Published var sceneProgress: Double?
    /// キューリスト（GO で上から順に出す）
    @Published var cues: [Cue] = [] { didSet { scheduleSave() } }
    /// 今出しているキュー（nil = まだ何も出していない）
    @Published var currentCue: Int?
    /// GO の連打よけ：最後に GO した時刻
    var lastGoHost = 0.0
    /// 押している間だけ効くエフェクトのパッド（グリッドの下）
    @Published var pads: [FXPad] = []
    /// 押しているパッドと、押した時刻
    @Published var heldPads: [UUID: Double] = [:]
    /// 離して消えている途中のパッド
    @Published var releasingPads: [UUID: PadRelease] = [:]
    /// パッドのエフェクトの時間の基準（押した時刻。消えている途中に押し直しても変えない）
    var padOrigins: [UUID: Double] = [:]
    /// 編集中のシーン（出力には出さず、左下のプレビューで見ながら直す）
    @Published var sceneDraft: SceneDraft?
    var sceneThumbWork: DispatchWorkItem?
    /// 編集中のシーンが変わったら画面（グリッドなど）も描き直す
    var sceneDraftSink: AnyCancellable?
    var sceneTween: Timer?
    /// キュー（クリップだけ）でほかのレイヤーを消している途中：消す段と、元の不透明度
    var cueFadeTimer: Timer?
    var cueFadeLayers: [Int: Double] = [:]
    /// キューで空のレイヤーにクリップを出したとき、だんだん出している途中：段と、戻す不透明度
    var cueFadeInTimer: Timer?
    var cueFadeInLayers: [Int: Double] = [:]

    @Published var masterOpacity = 1.0 {
        didSet { syncRenderState(); scheduleSave() }
    }
    /// マスター音量
    @Published var masterVolume = 1.0 {
        didSet {
            applyMasterVolume()
            scheduleSave()
        }
    }
    /// ブラックアウト中か。クリップは裏で再生し続け、出力の映像と音だけを消す（保存しない）
    @Published var isBlackout = false {
        didSet {
            guard oldValue != isBlackout else { return }
            let now = CACurrentMediaTime()
            let target: Float = isBlackout ? 0 : 1
            blackoutFade = .toward(target, from: blackoutFade.value(at: now),
                                   fullDuration: isBlackout ? blackoutFadeOut : blackoutFadeIn, now: now)
            syncRenderState()
            updateAudioFades()
        }
    }
    /// ブラックアウトにかける時間・解除にかける時間（秒。設定ウィンドウで変える）
    @Published var blackoutFadeOut = 0.5 {
        didSet { if persistent { UserDefaults.standard.set(blackoutFadeOut, forKey: "blackoutFadeOut") } }
    }
    @Published var blackoutFadeIn = 0.5 {
        didSet { if persistent { UserDefaults.standard.set(blackoutFadeIn, forKey: "blackoutFadeIn") } }
    }
    /// 出力の見え具合（1 = 通常、0 = ブラックアウト）
    private var blackoutFade = Fade()

    func toggleBlackout() { isBlackout.toggle() }

    /// コンポジションのミュート：再生は続けたまま、出力の映像と音をすぐ消す（フェードなし。保存する）
    @Published var compMuted = false {
        didSet {
            guard oldValue != compMuted else { return }
            applyMasterVolume()
            syncRenderState()
            scheduleSave()
        }
    }

    /// マスターの音だけのミュート（映像は出る。保存する）
    @Published var masterAudioMuted = false {
        didSet {
            guard oldValue != masterAudioMuted else { return }
            applyMasterVolume()
            scheduleSave()
        }
    }

    private func applyMasterVolume() {
        let v = blackoutFade.value(at: CACurrentMediaTime())
        AudioOutput.shared.engine.mainMixerNode.outputVolume = compMuted || masterAudioMuted ? 0 : Float(masterVolume) * v
    }

    // MARK: 音のフェード
    /// フェード中だけ動く音量更新タイマー（メインスレッド、約 10ms ごと）
    private var audioFadeTimer: Timer?

    /// ブラックアウト・クロスフェードの音量を今の時刻に合わせる。フェードが続いていればタイマーを回す
    private func updateAudioFades() {
        let now = CACurrentMediaTime()
        applyMasterVolume()
        var active = !blackoutFade.isDone(at: now)
        for r in layers.indices {
            // 音は等パワー（sin/cos）で入れ替えて、途中で音量が落ち込まないようにする
            let x = crossfades[r].value(at: now) * .pi / 2
            if let a = activeByLayer[r] { slots[a]?.fadeGain = sin(x) }
            if let o = outgoing[r] { slots[o]?.fadeGain = cos(x) }
            if !crossfades[r].isDone(at: now) { active = true }
        }
        if active, audioFadeTimer == nil {
            let t = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.updateAudioFades() }
            RunLoop.main.add(t, forMode: .common)
            audioFadeTimer = t
        } else if !active {
            audioFadeTimer?.invalidate()
            audioFadeTimer = nil
        }
    }
    /// 選択中のクリップ（クリッププレビューとトランスフォームパネルの対象）。
    /// サムネイル下の名前の帯をクリック、またはトリガーで選ばれる。
    @Published var inspectedIndex: Int? {
        didSet { if oldValue != inspectedIndex { syncRenderState() } }
    }

    @Published var corners: [SIMD2<Float>] = Engine.defaultCorners {
        didSet { updateHomography(); scheduleSave() }
    }
    @Published var testPattern = false {
        didSet { syncRenderState() }
    }
    @Published var audioDeviceUID: String? {
        didSet {
            AudioOutput.shared.setDevice(uid: audioDeviceUID)
            scheduleSave()
        }
    }
    /// 出力先の縦横比（プレビューの形に使う）
    @Published var outputAspect: CGFloat = 16.0 / 9.0

    private(set) var homographyInverse = matrix_identity_float3x3

    /// 描画スレッドに渡す状態。メインスレッドで変更があるたびに作り直す（renderLock の中で触る）
    struct RenderState {
        struct LayerState {
            var slot: ClipSlot?
            var opacity: Float
            var blend: BlendMode
            var transform = AnimTransform()
            var layerTransform = AnimTransform()
            /// クロスフェードで消えていくクリップ（フェードが終われば nil）
            var outgoing: ClipSlot?
            var outgoingTransform = AnimTransform()
            /// レイヤー不透明度のアニメーション
            var opacityAnim: ParamAnim?
            var muted = false
            var isAdjustment = false
            var blendFX = Effect(kind: .overdrive)
            var clipMuted = false
            var outgoingMuted = false
            var clipEffects = EffectStack()
            var outgoingEffects = EffectStack()
            /// ジェネレーターのクリップなら、その設定（動画のフレームの代わりに描く）
            var generator: Effect?
            var outgoingGenerator: Effect?
            var layerEffects = EffectStack()
            /// 新しいクリップの見え具合（0→1）。消えていく方は 1 - これ
            var crossfade = Fade()
            /// 静止画のクリップなら、その絵
            var still: MTLTexture?
            var outgoingStill: MTLTexture?
        }
        enum Preview {
            case none
            /// 出力で再生中 → そのレイヤーのフレームをそのまま見せる
            case live(layer: Int)
            /// 出力していない → プレビュー専用に再生
            case player(PreviewPlayer)
            /// 出力していないジェネレーター → プレビュー用に描く
            case generator(Effect, origin: Double)
            /// 出力していない静止画（GIF などはコマを進める）
            case image(ClipSlot)
        }
        var layers: [LayerState] = []
        var homographyInverse = matrix_identity_float3x3
        var testPattern = false
        var preview = Preview.none
        var previewTransform = AnimTransform()
        var masterOpacity: Float = 1
        var masterOpacityAnim: ParamAnim?
        var blackoutFade = Fade()
        var compTransform = AnimTransform()
        var beat = BeatClock()
        var compEffects = EffectStack()
        var previewEffects = EffectStack()
        var compMuted = false
        /// ジェネレーターを描く大きさ（出力の縦横比で、高さ 1080）
        var generatorSize = (1920, 1080)
        var selectedLayer = 0
        /// 押しているパッドのエフェクト（出力のいちばん最後に、この順でかける）
        var padStacks: [PadRender] = []
    }
    /// シーン編集のプレビューで描くもの（renderLock の中で触る）
    struct ScenePreviewState {
        enum Source {
            /// 出力で同じクリップを再生中 → そのレイヤーのフレームを使う
            case live(Int)
            case player(PreviewPlayer)
            case generator(Effect, origin: Double)
            case image(ClipSlot)
        }
        var layers: [RenderState.LayerState] = []
        var sources: [Source?] = []
        var compTransform = AnimTransform()
        var compEffects = EffectStack()
        var master: Float = 1
        var masterAnim: ParamAnim?
    }
    private var scenePreview: ScenePreviewState?
    /// シーン編集のプレビューで、レイヤーごとに表示中のフレーム（renderLock の中で触る）
    private var sceneFrames: [Int: FrameHolder] = [:]
    /// シーン編集のプレビュー専用の再生（メインスレッド）
    private var scenePlayers: [Int: PreviewPlayer] = [:]

    /// クリッププレビュー用の再生（メインスレッドで管理）
    private var previewPlayer: PreviewPlayer?
    private var previewIn = 0.0
    /// クリッププレビューで表示中のフレーム（renderLock の中で触る）
    private var previewFrame: FrameHolder?
    private let renderLock = NSLock()
    private var renderState = RenderState()
    /// ポスタライズ時間（クリップ）の、最後にフレームを取ったコマ番号（描画スレッドだけが触る）
    private var clipTicks: [ObjectIdentifier: Int64] = [:]
    /// 各レイヤーで表示中のフレーム（renderLock の中で触る）
    private var frames: [FrameHolder?] = Array(repeating: nil, count: Engine.defaultLayers)
    /// 各レイヤーでクロスフェード中に消えていくクリップのフレーム（renderLock の中で触る）
    private var outgoingFrames: [FrameHolder?] = Array(repeating: nil, count: Engine.defaultLayers)
    /// 各レイヤーでクロスフェード中に消えていくスロット番号と、フェードの進み具合（メインスレッド）
    private var outgoing: [Int?] = Array(repeating: nil, count: Engine.defaultLayers)
    private var crossfades: [Fade] = Array(repeating: Fade(), count: Engine.defaultLayers)
    private var crossfadeEnd: [DispatchWorkItem?] = Array(repeating: nil, count: Engine.defaultLayers)

    /// false ならディスクに保存も復元もしない（セルフテスト用）
    private let persistent: Bool
    private var saveWork: DispatchWorkItem?
    private var isRestoring = false

    /// 選択中レイヤーで再生中のクリップ
    var selectedSlot: ClipSlot? { activeByLayer[selectedLayer].flatMap { slots[$0] } }

    init(persistent: Bool) {
        self.persistent = persistent
        for layer in layers { wire(layer) }
        compTransform.onChanged = { [weak self] in
            self?.syncRenderState()
            self?.scheduleSave()
        }
        pads = makePads(nil)
        // 描画用の状態を先に作っておく（復元の途中で止めたりするので）
        syncRenderState()
        if persistent {
            let d = UserDefaults.standard
            if d.object(forKey: "blackoutFadeOut") != nil { blackoutFadeOut = d.double(forKey: "blackoutFadeOut") }
            if d.object(forKey: "blackoutFadeIn") != nil { blackoutFadeIn = d.double(forKey: "blackoutFadeIn") }
            restore()
        }
        updateHomography()
        syncRenderState()
    }

    private func wire(_ layer: Layer) {
        layer.onChanged = { [weak self] in
            self?.syncRenderState()
            self?.scheduleSave()
        }
        layer.onVolumeChanged = { [weak self, weak layer] in
            guard let self, let layer else { return }
            self.applyVolume(layer: layer.index)
        }
    }

    // MARK: - レイヤー・列の増減

    /// 一番上に調整レイヤーを足す（エフェクトが下のレイヤー全体にかかる）
    func insertAdjustmentLayer(at r: Int = 0) {
        guard layers.count < Self.maxLayers else { return }
        insertLayer(at: r)
        layers[r].isAdjustment = true
        selectedLayer = r
        inspectorTab = .layer
    }

    /// r 段目の位置に新しいレイヤーを入れる（r = layerCount なら一番下＝一番奥）
    func insertLayer(at r: Int) {
        guard layers.count < Self.maxLayers else { return }
        let r = min(max(r, 0), layers.count)
        let layer = Layer(index: r)
        wire(layer)
        var newLayers = layers
        newLayers.insert(layer, at: r)
        let old = layers.count
        restructure(layers: newLayers, columns: columns,
                    layerMap: { $0 >= r ? $0 + 1 : $0 })
        remapSceneLayers(oldCount: old, newCount: layers.count) { $0 >= r ? $0 + 1 : $0 }
    }

    /// r 段目のレイヤーを to 段目へ動かす（クリップ・再生中のもの・設定ごと。シーンも付いてくる）
    func moveLayer(_ r: Int, to t: Int) {
        guard layers.indices.contains(r) else { return }
        let t = min(max(t, 0), layers.count - 1)
        guard r != t else { return }
        var newLayers = layers
        let l = newLayers.remove(at: r)
        newLayers.insert(l, at: t)
        let old = layers
        func map(_ i: Int) -> Int? { newLayers.firstIndex { $0 === old[i] } }
        restructure(layers: newLayers, columns: columns, layerMap: map)
        remapSceneLayers(oldCount: old.count, newCount: layers.count, map)
    }

    /// レイヤーを足す・消す・動かしたときに、シーンのレイヤーごとの中身も同じように並べ直す
    private func remapSceneLayers(oldCount: Int, newCount: Int, _ map: (Int) -> Int?) {
        remapCueLayers(map)
        guard !scenes.isEmpty else { return }
        var out = scenes
        for k in out.indices {
            var s = out[k]
            // 全レイヤーぶん持っているシーンだけ数を合わせる（少ないものは、持っている所だけ並べ直す）
            let n = s.playing.count == oldCount ? newCount : s.playing.count
            var p = [Int?](repeating: nil, count: n)
            var ls = (0..<n).map { _ in SavedLayer(opacity: 1, blend: 0, volume: 1) }
            var ld = [UUID?](repeating: nil, count: n)
            for i in s.playing.indices {
                guard let j = map(i), j < n else { continue }
                p[j] = s.playing[i]
                if i < s.layers.count { ls[j] = s.layers[i] }
                if let o = s.layerDecks, i < o.count { ld[j] = o[i] }
            }
            s.playing = p
            s.layers = ls
            s.layerDecks = ld.contains { $0 != nil } ? ld : nil
            out[k] = s
        }
        scenes = out
        if sceneDraft != nil { reloadSceneDraft() }
    }

    /// r 段目のレイヤーを消す（中のクリップも外れる）。最後の 1 段は消せない
    func removeLayer(_ r: Int) {
        guard layers.count > 1, layers.indices.contains(r) else { return }
        var newLayers = layers
        newLayers.remove(at: r)
        let old = layers.count
        restructure(layers: newLayers, columns: columns,
                    layerMap: { $0 == r ? nil : ($0 > r ? $0 - 1 : $0) })
        remapSceneLayers(oldCount: old, newCount: layers.count) { $0 == r ? nil : ($0 > r ? $0 - 1 : $0) }
    }

    /// c 列目の位置に空の列を入れる（c = columns なら右端）
    func insertColumn(at c: Int) {
        guard columns < Self.maxColumns else { return }
        let c = min(max(c, 0), columns)
        restructure(layers: layers, columns: columns + 1, layerMap: { $0 },
                    columnMap: { $0 >= c ? $0 + 1 : $0 })
    }

    /// c 列目を消す（その列のクリップも外れる）。最後の 1 列は消せない
    func removeColumn(_ c: Int) {
        guard columns > 1, c >= 0, c < columns else { return }
        restructure(layers: layers, columns: columns - 1, layerMap: { $0 },
                    columnMap: { $0 == c ? nil : ($0 > c ? $0 - 1 : $0) })
    }

    /// その段・列にクリップが入っているか（消す前の確認用）
    func layerHasClips(_ r: Int) -> Bool {
        decks.indices.contains { d in (0..<columns).contains { slots[slotIndex(deck: d, layer: r, column: $0)] != nil } }
    }
    func columnHasClips(_ c: Int) -> Bool {
        decks.indices.contains { d in layers.indices.contains { slots[slotIndex(deck: d, layer: $0, column: c)] != nil } }
    }
    func deckHasClips(_ d: Int) -> Bool {
        decks.indices.contains(d) && slots[(d * gridSize)..<((d + 1) * gridSize)].contains { $0 != nil }
    }

    // MARK: - デッキ

    /// 新しいデッキを足して、それを表示する。duplicate なら、そのデッキのクリップを複製して入れる
    @discardableResult
    func addDeck(duplicating src: Int? = nil) -> Int {
        var n = decks.count + 1
        while decks.contains(where: { $0.name == "デッキ \(n)" }) { n += 1 }
        let name = src.flatMap { decks.indices.contains($0) ? decks[$0].name + " のコピー" : nil } ?? "デッキ \(n)"
        restructure(layers: layers, columns: columns, layerMap: { $0 }, decks: decks + [Deck(name: name)])
        let d = decks.count - 1
        if let src, decks.indices.contains(src) {
            for r in layers.indices {
                for c in 0..<columns {
                    if let s = slots[slotIndex(deck: src, layer: r, column: c)] {
                        setSlot(slotIndex(deck: d, layer: r, column: c), Self.copy(of: s, url: s.url))
                    }
                }
            }
        }
        showDeck(d)
        scheduleSave()
        return d
    }

    /// デッキを消す（中のクリップも外れる。再生中なら止まる）。最後の 1 枚は消せない。
    /// そのデッキを使っていたシーンは、1 枚目のデッキを使う
    func removeDeck(_ d: Int) {
        guard decks.count > 1, decks.indices.contains(d) else { return }
        let id = decks[d].id
        var nd = decks
        nd.remove(at: d)
        let keep = currentDeck
        restructure(layers: layers, columns: columns, layerMap: { $0 }, decks: nd,
                    deckMap: { $0 == d ? nil : ($0 > d ? $0 - 1 : $0) })
        currentDeck = keep == d ? max(d - 1, 0) : (keep > d ? keep - 1 : keep)
        for i in scenes.indices {
            if scenes[i].deck == id { scenes[i].deck = nil }
            if let ld = scenes[i].layerDecks, ld.contains(id) { scenes[i].layerDecks = ld.map { $0 == id ? nil : $0 } }
        }
        if sceneDraft != nil { reloadSceneDraft() }
        scheduleSave()
    }

    func renameDeck(_ d: Int, to name: String) {
        guard decks.indices.contains(d), !name.isEmpty else { return }
        decks[d].name = name
        scheduleSave()
    }

    /// デッキの番号（見つからなければ nil）
    func deckIndex(_ id: UUID?) -> Int? { id.flatMap { id in decks.firstIndex { $0.id == id } } }

    /// グリッドの形を変える。layerMap / columnMap / deckMap は「前の段・列・デッキ → 新しい段・列・デッキ（nil = 消える）」
    private func restructure(layers newLayers: [Layer], columns newColumns: Int,
                             layerMap: (Int) -> Int?, columnMap: (Int) -> Int? = { $0 },
                             decks newDecks: [Deck]? = nil, deckMap: (Int) -> Int? = { $0 }) {
        for r in layers.indices { finishCrossfade(r) }
        multiSelection = []
        let oldColumns = columns
        let oldGrid = max(gridSize, 1)
        let newDecks = newDecks ?? decks
        let newGrid = newLayers.count * newColumns
        func map(_ i: Int) -> Int? {
            let rest = i % oldGrid
            guard let d = deckMap(i / oldGrid), let r = layerMap(rest / oldColumns), let c = columnMap(rest % oldColumns)
            else { return nil }
            return d * newGrid + r * newColumns + c
        }

        // 消えるクリップは止めて外す
        var newSlots: [ClipSlot?] = Array(repeating: nil, count: newDecks.count * newGrid)
        for (i, slot) in slots.enumerated() {
            guard let slot else { continue }
            if let n = map(i) {
                newSlots[n] = slot
            } else {
                if slot.isPlaying || activeByLayer.contains(i) { slot.stopAndRearm() }
            }
        }
        var newActive: [Int?] = Array(repeating: nil, count: newLayers.count)
        var newFrames: [FrameHolder?] = Array(repeating: nil, count: newLayers.count)
        let oldFrames = renderLock.withLock { frames }
        for (r, a) in activeByLayer.enumerated() {
            guard let a, let n = map(a) else { continue }
            let nr = (n % newGrid) / newColumns
            newActive[nr] = n
            newFrames[nr] = oldFrames[r]
        }
        let newInspected = inspectedIndex.flatMap(map)
        let newSelected = layerMap(selectedLayer) ?? min(selectedLayer, newLayers.count - 1)

        for (r, l) in newLayers.enumerated() { l.index = r }
        renderLock.withLock {
            frames = newFrames
            outgoingFrames = Array(repeating: nil, count: newLayers.count)
            // 描画スレッドが古い段数のまま読まないよう、ここで形を合わせておく
            renderState.layers = newLayers.indices.map { r in
                var st = RenderState.LayerState(slot: nil, opacity: 0, blend: .normal)
                if let a = newActive[r] { st.slot = newSlots[a] }
                return st
            }
        }
        outgoing = Array(repeating: nil, count: newLayers.count)
        crossfades = Array(repeating: Fade(), count: newLayers.count)
        crossfadeEnd = Array(repeating: nil, count: newLayers.count)

        layers = newLayers
        columns = newColumns
        decks = newDecks
        currentDeck = deckMap(currentDeck) ?? min(currentDeck, newDecks.count - 1)
        slots = newSlots
        activeByLayer = newActive
        for (i, slot) in slots.enumerated() {
            slot?.layerVolume = layers[layerOf(i)].audible ? Float(layers[layerOf(i)].volume) : 0
            slot?.fadeGain = 1
        }
        inspectedIndex = newInspected
        selectedLayer = min(max(newSelected, 0), layers.count - 1)
        syncRenderState()
        scheduleSave()
    }

    // MARK: - 再生操作

    /// スロットを頭から再生する。同じレイヤーで再生中だったクリップは止まる（他のレイヤーはそのまま）。
    /// fadeTime を渡すと、レイヤーの切り替えフェードの代わりにその秒数でクロスフェードする（シーン）。
    /// select = false ならレイヤーの選択を変えない
    func trigger(_ index: Int, fadeTime fadeOverride: Double? = nil, select: Bool = true) {
        guard index >= 0, index < slots.count, let slot = slots[index] else { return }
        let r = layerOf(index)
        // キューで消している途中のレイヤーを出し直したら、消すのをやめる
        cancelCueFade(layer: r)
        // キューで一時的に決めた「終わったら」は、出し直すと外れる（キューから出すときは、この後でまた入れる）
        slot.endActionOverride = nil
        // 消えかけのクリップをもう一度押した → それは頭から出し直す（クロスフェードの相手ではなくなる）
        if outgoing[r] == index { dropOutgoing(r, stop: false) }
        let fadeTime = fadeOverride ?? layers[r].fadeTime
        if let a = activeByLayer[r], a != index {
            if fadeTime > 0, slots[a]?.isPlaying == true {
                // 前のクリップは止めずに残して、フェードが終わったら止める
                finishCrossfade(r)
                startCrossfade(r, from: a, duration: fadeTime)
            } else {
                finishCrossfade(r)
                slots[a]?.stopAndRearm()
            }
        } else {
            finishCrossfade(r)
            crossfades[r] = Fade()
        }
        activeByLayer[r] = index
        if select { selectedLayer = r }
        slot.fadeGain = sin(crossfades[r].value(at: CACurrentMediaTime()) * .pi / 2)
        slot.playFromStart()
        slot.invalidateShownFrame()
        syncRenderState()
        updateAudioFades()
    }

    // MARK: クロスフェード

    private func startCrossfade(_ r: Int, from a: Int, duration: Double) {
        outgoing[r] = a
        crossfades[r] = Fade(from: 0, to: 1, start: CACurrentMediaTime(), duration: duration)
        // 今出ている絵を「消えていく方」に回す
        renderLock.withLock {
            outgoingFrames[r] = frames[r]
            frames[r] = nil
        }
        let work = DispatchWorkItem { [weak self] in self?.finishCrossfade(r) }
        crossfadeEnd[r] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// クロスフェードを終わらせる（消えていくクリップを止める）
    private func finishCrossfade(_ r: Int) {
        guard outgoing[r] != nil else { return }
        dropOutgoing(r, stop: true)
        crossfades[r] = Fade()
        if let a = activeByLayer[r] { slots[a]?.fadeGain = 1 }
        syncRenderState()
    }

    private func dropOutgoing(_ r: Int, stop: Bool) {
        crossfadeEnd[r]?.cancel()
        crossfadeEnd[r] = nil
        if let o = outgoing[r] {
            if stop { slots[o]?.stopAndRearm() }
            slots[o]?.fadeGain = 1
        }
        outgoing[r] = nil
        renderLock.withLock {
            if renderState.layers.indices.contains(r) { renderState.layers[r].outgoing = nil }
            if outgoingFrames.indices.contains(r) { outgoingFrames[r] = nil }
        }
    }

    /// 1つのレイヤーを止めて消す
    func stopLayer(_ r: Int) {
        guard r >= 0, r < layers.count else { return }
        finishCrossfade(r)
        crossfades[r] = Fade()
        if let a = activeByLayer[r] { slots[a]?.stopAndRearm(); slots[a]?.fadeGain = 1 }
        activeByLayer[r] = nil
        renderLock.withLock {
            if renderState.layers.indices.contains(r) { renderState.layers[r].slot = nil }
            if frames.indices.contains(r) { frames[r] = nil }
        }
        syncRenderState()
    }

    /// 全レイヤーを止める
    func stopAll() {
        for r in layers.indices { stopLayer(r) }
    }

    /// クリップを別の場所に複製する（同じファイル・同じ設定の別クリップとして）。
    /// 複製先にクリップがあれば置き換える。ただし複製先が再生中なら何もしない（本番中に消さないため）
    @discardableResult
    func duplicateSlot(_ from: Int, to: Int) -> Bool {
        guard from != to, slots.indices.contains(from), slots.indices.contains(to),
              let src = slots[from], activeByLayer[layerOf(to)] != to else { return false }
        setSlot(to, Self.copy(of: src, url: src.url))
        scheduleSave()
        return true
    }

    /// 同じ設定のクリップを、url の動画で作る（複製・ファイルの付け直し）
    private static func copy(of src: ClipSlot, url: URL) -> ClipSlot {
        let copy: ClipSlot
        if src.isEffectClip {
            copy = ClipSlot(effects: [], title: src.title)
        } else if let g = src.generator {
            var g2 = g; g2.id = UUID()
            copy = ClipSlot(generator: g2)
        } else {
            copy = ClipSlot(url: url, speed: src.speed, endAction: src.endAction,
                            inPoint: src.inPoint, outPoint: src.outPoint)
        }
        copy.posX = src.posX; copy.posY = src.posY
        copy.scale = src.scale; copy.rotation = src.rotation
        copy.opacity = src.opacity; copy.clipVolume = src.clipVolume
        copy.anims = src.anims
        copy.syncMode = src.syncMode; copy.syncBeats = src.syncBeats
        copy.jumpBeats = src.jumpBeats
        copy.muted = src.muted
        copy.audioMuted = src.audioMuted
        copy.effects = src.effects.map { var e = $0; e.id = UUID(); return e }
        return copy
    }

    /// 見つからない（または別の）動画ファイルに付け直す。設定はそのまま
    func relinkSlot(_ index: Int, to url: URL) {
        guard slots.indices.contains(index), let src = slots[index] else { return }
        let r = layerOf(index)
        if activeByLayer[r] == index { stopLayer(r) }
        setSlot(index, Self.copy(of: src, url: url))
        scheduleSave()
    }

    /// 見つからない動画を、選んだフォルダの中から同じ名前で探して付け直す。付け直せた数を返す
    @discardableResult
    func relinkMissing(searchingIn dir: URL) -> Int {
        var byName: [String: URL] = [:]
        if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where byName[u.lastPathComponent] == nil { byName[u.lastPathComponent] = u }
        }
        var n = 0
        for (i, s) in slots.enumerated() {
            guard let s, s.isMissing, let found = byName[s.url.lastPathComponent] else { continue }
            relinkSlot(i, to: found)
            n += 1
        }
        return n
    }

    /// 複製先として使えるか（空き、または再生中でないクリップ）
    func canDuplicate(to i: Int) -> Bool {
        slots.indices.contains(i) && activeByLayer[layerOf(i)] != i
    }

    /// 今開いているタブ（コンポジション・レイヤー・クリップ）にエフェクトを足す。クリップ未選択なら false
    @discardableResult
    func addEffectToCurrentTab(_ k: EffectKind) -> Bool {
        switch inspectorTab {
        case .composition: if let d = sceneDraft { d.addEffect(k) } else { addEffect(k) }
        case .layer: viewLayer(selectedLayer).addEffect(k)
        case .clip:
            guard let i = inspectedIndex, let s = slots[i] else { return false }
            s.addEffect(k)
        }
        return true
    }

    /// クリップを選択する（出力はしない）。クリッププレビューとパラメーターの対象になる
    func selectClip(_ index: Int) {
        guard slots.indices.contains(index), slots[index] != nil else { return }
        inspectedIndex = index
        inspectorTab = .clip
    }

    // MARK: - クリップの読み込み

    /// エフェクトのクリップを index に作る（調整レイヤーの枠用。空き枠だけ）。作ったら選ぶ
    @discardableResult
    func createEffectClip(at index: Int, with kind: EffectKind? = nil) -> Bool {
        guard slots.indices.contains(index), slots[index] == nil else { return false }
        if let kind, kind.isGenerator || kind.isBlend { return false }
        setSlot(index, ClipSlot(effects: kind.map { [Effect(kind: $0)] } ?? []))
        selectClip(index)
        scheduleSave()
        return true
    }

    /// ジェネレーターを index に置く（あれば置き換える。再生中なら何もしない）
    @discardableResult
    func placeGenerator(_ kind: EffectKind, at index: Int) -> Bool {
        guard kind.isGenerator, slots.indices.contains(index), activeByLayer[layerOf(index)] != index else { return false }
        setSlot(index, ClipSlot(generator: Effect(kind: kind)))
        scheduleSave()
        return true
    }

    /// 選択中のレイヤーの空いているいちばん左にジェネレーターを置いて、選ぶ。空きが無ければ false
    @discardableResult
    func placeGeneratorInSelectedLayer(_ kind: EffectKind) -> Bool {
        let r = selectedLayer
        guard let i = (0..<columns).map({ slotIndex(deck: currentDeck, layer: r, column: $0) }).first(where: { slots[$0] == nil }),
              placeGenerator(kind, at: i) else { return false }
        selectClip(i)
        return true
    }

    /// 複数のクリップを index から右へ順番に入れる（その段の右端まで）
    func load(urls: [URL], startingAt index: Int) {
        let rowEnd = index - columnOf(index) + columns
        var i = index
        for url in urls where i < rowEnd {
            setSlot(i, ClipSlot(url: url))
            i += 1
        }
        scheduleSave()
    }

    /// スロットを移動する（移動先にクリップがあれば入れ替え）。レイヤーをまたいでもよい。
    /// 再生中のクリップは止めずに移動先のレイヤーで再生を続ける。移動先のレイヤーで別のクリップが
    /// 再生中だった場合は、そちらを止める（1レイヤー1クリップ）。
    func moveSlot(_ from: Int, to: Int) {
        guard from != to, slots.indices.contains(from), slots.indices.contains(to), slots[from] != nil else { return }
        // 移動するときはクロスフェードを打ち切る
        for r in layers.indices { finishCrossfade(r) }

        // 再生中のクリップと、移動後の位置
        func newIndex(_ i: Int) -> Int { i == from ? to : (i == to ? from : i) }
        let playing: [(old: Int, new: Int)] = activeByLayer.compactMap { $0 }.map { ($0, newIndex($0)) }
        let selectedOld = activeByLayer[selectedLayer]

        slots.swapAt(from, to)
        for i in [from, to] {
            slots[i]?.layerVolume = layers[layerOf(i)].audible ? Float(layers[layerOf(i)].volume) : 0
        }

        var newActive: [Int?] = Array(repeating: nil, count: layerCount)
        // 移動したクリップを優先して、各レイヤーに1つだけ残す
        for p in playing.sorted(by: { a, _ in a.old == from || a.old == to }) {
            let r = layerOf(p.new)
            if newActive[r] == nil {
                newActive[r] = p.new
            } else {
                slots[p.new]?.stopAndRearm()
            }
        }
        let changed = layers.indices.filter { newActive[$0] != activeByLayer[$0] }
        activeByLayer = newActive
        renderLock.withLock {
            for r in changed { frames[r] = nil }
        }
        for r in changed {
            if let i = newActive[r] { slots[i]?.invalidateShownFrame() }
        }
        syncRenderState()
        // 選択中のクリップを移動したら、選択も移動先のレイヤーへ
        if let s = selectedOld, s == from || s == to {
            selectedLayer = layerOf(newIndex(s))
        }
        if let i = inspectedIndex, i == from || i == to {
            inspectedIndex = newIndex(i)
        }
        scheduleSave()
    }

    func clear(_ index: Int) {
        setSlot(index, nil)
        scheduleSave()
    }

    func openPanel(for index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie] + StillImage.openTypes
        panel.allowsMultipleSelection = true
        panel.message = "クリップを選択（複数選ぶと右隣のスロットに順番に入ります。この段の右端まで）"
        if panel.runModal() == .OK {
            load(urls: panel.urls, startingAt: index)
        }
    }

    private func setSlot(_ index: Int, _ slot: ClipSlot?) {
        let r = layerOf(index)
        if activeByLayer[r] == index { stopLayer(r) }
        if outgoing[r] == index { finishCrossfade(r) }
        slot?.onReady = { [weak self] in self?.syncRenderState() }
        slot?.onBlackoutEnd = { [weak self, weak slot] in
            guard let self, let slot, let i = self.slots.firstIndex(where: { $0 === slot }) else { return }
            let r = layerOf(i)
            if self.activeByLayer[r] == i { self.stopLayer(r) } else if self.outgoing[r] == i { self.finishCrossfade(r) }
        }
        slot?.onSettingsChanged = { [weak self] in
            self?.syncRenderState()
            self?.scheduleSave()
        }
        if slot == nil && inspectedIndex == index { inspectedIndex = nil }
        slot?.layerVolume = layers[r].audible ? Float(layers[r].volume) : 0
        slot?.masterRate = masterSpeed
        slot?.beatClock = beatClock
        slots[index] = slot
        syncRenderState()
    }

    private func applyVolume(layer r: Int) {
        let v = layers[r].audible ? Float(layers[r].volume) : 0
        for d in decks.indices {
            for c in 0..<columns { slots[slotIndex(deck: d, layer: r, column: c)]?.layerVolume = v }
        }
    }

    // MARK: - 描画スレッドとのやりとり

    /// 描画スレッド用の状態を作り直す（メインスレッドで、状態が変わるたびに呼ぶ）
    func syncRenderState() {
        let st = RenderState(
            layers: layers.map { l in
                let slot = activeByLayer[l.index].flatMap { slots[$0] }
                let out = outgoing[l.index].flatMap { slots[$0] }
                return RenderState.LayerState(slot: slot, opacity: Float(l.opacity), blend: l.blend,
                                              transform: slot?.animTransform ?? AnimTransform(),
                                              layerTransform: l.transform.animValue,
                                              outgoing: out,
                                              outgoingTransform: out?.animTransform ?? AnimTransform(),
                                              opacityAnim: l.anims[.opacity].flatMap { $0.isOn ? $0 : nil },
                                              muted: l.muted,
                                              isAdjustment: l.isAdjustment,
                                              blendFX: l.blendFX,
                                              clipMuted: slot?.muted ?? false,
                                              outgoingMuted: out?.muted ?? false,
                                              clipEffects: EffectStack(effects: slot?.effects ?? [], beat: beatClock,
                                                                       origin: slot?.animOrigin ?? 0),
                                              outgoingEffects: EffectStack(effects: out?.effects ?? [], beat: beatClock,
                                                                           origin: out?.animOrigin ?? 0),
                                              generator: slot?.generator,
                                              outgoingGenerator: out?.generator,
                                              layerEffects: EffectStack(effects: l.effects, beat: beatClock),
                                              crossfade: crossfades[l.index],
                                              still: slot?.stillTexture,
                                              outgoingStill: out?.stillTexture)
            },
            homographyInverse: homographyInverse,
            testPattern: testPattern)
        var state = st
        (state.preview, state.previewTransform) = syncPreview()
        state.masterOpacity = Float(masterOpacity)
        state.blackoutFade = blackoutFade
        state.compTransform = compTransform.animValue
        state.masterOpacityAnim = anims[.opacity].flatMap { $0.isOn ? $0 : nil }
        state.beat = beatClock
        state.compEffects = EffectStack(effects: effects, beat: beatClock)
        state.compMuted = compMuted
        state.generatorSize = (max(Int((1080 * outputAspect).rounded()), 1), 1080)
        state.previewEffects = EffectStack(effects: inspectedIndex.flatMap { slots[$0]?.effects } ?? [], beat: beatClock,
                                           origin: inspectedIndex.flatMap { slots[$0]?.animOrigin } ?? 0)
        state.selectedLayer = selectedLayer
        state.padStacks = heldPadStacks()
        renderLock.withLock { renderState = state }
        syncScenePreview()
    }

    /// シーン編集のプレビューの中身を作り直す（シーンを編集中で、下のパネルがシーンのタブのときだけ再生する）
    func syncScenePreview() {
        checkSceneDraftLayers()
        guard let d = sceneDraft else {
            for p in scenePlayers.values { p.cancel() }
            scenePlayers = [:]
            renderLock.withLock { scenePreview = nil; sceneFrames = [:] }
            return
        }
        var st = ScenePreviewState()
        for (r, l) in d.layers.enumerated() {
            let i = r < layers.count ? scenePlayingIndex(d, r) : nil
            let slot = i.flatMap { slots[$0] }
            st.layers.append(RenderState.LayerState(
                slot: slot, opacity: Float(l.opacity), blend: l.blend,
                transform: slot?.animTransform ?? AnimTransform(),
                layerTransform: l.transform.animValue,
                opacityAnim: l.anims[.opacity].flatMap { $0.isOn ? $0 : nil },
                muted: l.muted, isAdjustment: l.isAdjustment, blendFX: l.blendFX,
                clipMuted: slot?.muted ?? false,
                clipEffects: EffectStack(effects: slot?.effects ?? [], beat: beatClock, origin: slot?.animOrigin ?? 0),
                generator: slot?.generator,
                layerEffects: EffectStack(effects: l.effects, beat: beatClock),
                still: slot?.stillTexture))
            var src: ScenePreviewState.Source?
            if let i, let slot, !l.isAdjustment {
                if activeByLayer[r] == i {
                    src = .live(r)
                } else if slot.isImage {
                    src = .image(slot)
                } else if let g = slot.generator {
                    src = .generator(g, origin: generatorPreviewOrigin(slot))
                } else if slot.isReady {
                    if scenePlayers[r]?.slot !== slot {
                        scenePlayers[r]?.cancel()
                        scenePlayers[r] = PreviewPlayer(slot: slot)
                    }
                    scenePlayers[r]?.setRate(slot.effectiveSpeed)
                    src = scenePlayers[r].map { .player($0) }
                }
            }
            if case .player = src {} else if let p = scenePlayers.removeValue(forKey: r) { p.cancel() }
            st.sources.append(src)
        }
        for r in scenePlayers.keys where r >= d.layers.count { scenePlayers.removeValue(forKey: r)?.cancel() }
        st.compTransform = d.compTransform.animValue
        st.compEffects = EffectStack(effects: d.effects, beat: beatClock)
        st.master = Float(d.masterOpacity)
        st.masterAnim = d.anims[.opacity].flatMap { $0.isOn ? $0 : nil }
        renderLock.withLock {
            // 出所が変わったレイヤーの古いフレームは捨てる
            if let old = scenePreview {
                for r in sceneFrames.keys where r >= st.layers.count || old.layers.indices.contains(r) == false
                    || old.layers[r].slot !== st.layers[r].slot { sceneFrames.removeValue(forKey: r) }
            }
            scenePreview = st
        }
    }

    /// シーンの編集中のレイヤープレビュー：シーンのそのレイヤーだけ（調整レイヤーなら下も）。編集中でなければ nil
    private func sceneLayerPreviewGroups() -> [LayerGroup]? {
        let now = CACurrentMediaTime()
        return renderLock.withLock {
            guard let sp = scenePreview else { return nil }
            let r = renderState.selectedLayer
            guard sp.layers.indices.contains(r) else { return [] }
            let beat = renderState.beat
            let rows = sp.layers[r].isAdjustment ? Array(sp.layers.indices.reversed().filter { $0 >= r }) : [r]
            return rows.compactMap { i in
                makeGroupLocked(sp.layers[i], frame: sceneFrameLocked(sp, i), outgoingFrame: nil, key: i, now: now,
                                blend: i == r ? .normal : sp.layers[i].blend, comp: ClipTransform(), beat: beat)
            }
        }
    }

    /// シーン編集のプレビューで、レイヤー r に描くフレーム。renderLock の中で呼ぶ
    private func sceneFrameLocked(_ sp: ScenePreviewState, _ r: Int) -> FrameHolder? {
        switch sp.sources[r] {
        case .live(let lr)?: return frames.indices.contains(lr) ? frames[lr] : nil
        case .player?, .generator?: return sceneFrames[r]
        case .image(let s)?: return s.imageTexture(at: CACurrentMediaTime()).map { FrameHolder(texture: $0) }
        case nil: return nil
        }
    }

    /// シーン編集のプレビューの合成に使うもの（描画スレッドから）
    func scenePreviewGroups() -> (groups: [LayerGroup], effects: EffectStack, master: Float)? {
        let now = CACurrentMediaTime()
        return renderLock.withLock {
            guard let sp = scenePreview else { return nil }
            let beat = renderState.beat
            let comp = sp.compTransform.at(now, beat: beat)
            let groups: [LayerGroup] = sp.layers.indices.reversed().compactMap { r in
                makeGroupLocked(sp.layers[r], frame: sceneFrameLocked(sp, r), outgoingFrame: nil, key: r, now: now,
                                       blend: sp.layers[r].blend, comp: comp, beat: beat)
            }
            let m = Float(sp.masterAnim.map { min(max($0.value(base: Double(sp.master), at: now, beat: beat), 0), 1) }
                          ?? Double(sp.master))
            return (groups, sp.compEffects, m)
        }
    }

    /// 選択中のクリップのプレビューをどこから出すか決める
    private func syncPreview() -> (RenderState.Preview, AnimTransform) {
        guard let i = inspectedIndex, let slot = slots[i] else {
            previewPlayer?.cancel()
            previewPlayer = nil
            return (.none, AnimTransform())
        }
        let r = layerOf(i)
        if activeByLayer[r] == i {
            previewPlayer?.cancel()
            previewPlayer = nil
            return (.live(layer: r), slot.animTransform)
        }
        if let g = slot.generator {
            previewPlayer?.cancel()
            previewPlayer = nil
            return (.generator(g, origin: generatorPreviewOrigin(slot)), slot.animTransform)
        }
        if slot.isImage {
            previewPlayer?.cancel()
            previewPlayer = nil
            return (slot.stillTexture != nil ? .image(slot) : .none, slot.animTransform)
        }
        guard slot.isReady else { return (.none, slot.animTransform) }
        if previewPlayer?.slot !== slot {
            previewPlayer?.cancel()
            previewPlayer = PreviewPlayer(slot: slot)
            previewIn = slot.inPoint
        }
        previewPlayer?.setRate(slot.effectiveSpeed)
        if let p = previewPlayer, previewIn != slot.inPoint {
            previewIn = slot.inPoint
            p.restartFromIn()
        }
        return (previewPlayer.map { .player($0) } ?? .none, slot.animTransform)
    }

    /// 各レイヤーの新しいフレームを取り込む。描画スレッドから 1 vsync に 1 回呼ばれる。
    /// 新しいフレームが来たレイヤーの数を返す。
    @discardableResult
    func updateFrame() -> Int {
        let layerStates = renderLock.withLock { renderState.layers }
        let now = CACurrentMediaTime()
        var updated = 0
        for (r, l) in layerStates.enumerated() {
            if let out = l.outgoing {
                if l.outgoingStill != nil, let t = out.imageTexture(at: now) {
                    renderLock.withLock {
                        if renderState.layers.indices.contains(r), outgoingFrames.indices.contains(r),
                           renderState.layers[r].outgoing === out, outgoingFrames[r]?.texture !== t {
                            outgoingFrames[r] = FrameHolder(texture: t)
                        }
                    }
                } else if let g = l.outgoingGenerator {
                    if let holder = renderGenerator(g, origin: l.outgoingEffects.origin, key: "go\(r)", now: now) {
                        renderLock.withLock {
                            if renderState.layers.indices.contains(r), outgoingFrames.indices.contains(r),
                               renderState.layers[r].outgoing === out { outgoingFrames[r] = holder }
                        }
                    }
                } else if let pb = out.frameForDisplay(at: now), let holder = makeHolder(pb) {
                    renderLock.withLock {
                        // 取り込んでいる間にレイヤーが増減していたら捨てる
                        if renderState.layers.indices.contains(r), outgoingFrames.indices.contains(r),
                           renderState.layers[r].outgoing === out { outgoingFrames[r] = holder }
                    }
                }
            } else {
                renderLock.withLock { if outgoingFrames.indices.contains(r) { outgoingFrames[r] = nil } }
            }
            guard let slot = l.slot else {
                renderLock.withLock { if frames.indices.contains(r) { frames[r] = nil } }
                continue
            }
            // ポスタライズ時間（クリップ）：同じコマの間は新しいフレームを取らない
            if let tick = l.clipEffects.tick(at: now) {
                let id = ObjectIdentifier(slot)
                if clipTicks[id] == tick && renderLock.withLock({ frames.indices.contains(r) && frames[r] != nil }) { continue }
                clipTicks[id] = tick
            }
            if l.still != nil, let t = slot.imageTexture(at: now) {
                let changed: Bool = renderLock.withLock {
                    guard renderState.layers.indices.contains(r), frames.indices.contains(r),
                          renderState.layers[r].slot === slot, frames[r]?.texture !== t else { return false }
                    frames[r] = FrameHolder(texture: t)
                    return true
                }
                if changed { updated += 1 }
                continue
            }
            if let g = l.generator {
                guard let holder = renderGenerator(g, origin: l.clipEffects.origin, key: "g\(r)", now: now) else { continue }
                renderLock.withLock {
                    if renderState.layers.indices.contains(r), frames.indices.contains(r),
                       renderState.layers[r].slot === slot { frames[r] = holder }
                }
                updated += 1
                continue
            }
            guard let pb = slot.frameForDisplay(at: now) else { continue }

            let ctx = MetalContext.shared
            var cv: CVMetalTexture?
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let status = CVMetalTextureCacheCreateTextureFromImage(nil, ctx.textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cv)
            guard status == kCVReturnSuccess, let cv, let tex = CVMetalTextureGetTexture(cv) else { continue }
            let holder = FrameHolder(pixelBuffer: pb, cvTexture: cv, texture: tex)
            renderLock.withLock {
                // 取り込んでいる間にレイヤーが止められていたら捨てる
                if renderState.layers.indices.contains(r), frames.indices.contains(r),
                   renderState.layers[r].slot === slot { frames[r] = holder }
            }
            updated += 1
        }

        // クリッププレビュー
        let preview = renderLock.withLock { renderState.preview }
        if case .player(let p) = preview {
            if let pb = p.frame(at: now), let holder = makeHolder(pb) {
                renderLock.withLock {
                    if case .player(let cur) = renderState.preview, cur === p { previewFrame = holder }
                }
            }
        } else if case .generator(let g, let origin) = preview {
            if let holder = renderGenerator(g, origin: origin, key: "gp", now: now) {
                renderLock.withLock { previewFrame = holder }
            }
        } else {
            renderLock.withLock { previewFrame = nil }
        }

        // シーン編集のプレビュー
        if let sources = renderLock.withLock({ scenePreview?.sources }) {
            for (r, src) in sources.enumerated() {
                switch src {
                case .player(let p)?:
                    if let pb = p.frame(at: now), let holder = makeHolder(pb) {
                        renderLock.withLock {
                            if let sp = scenePreview, sp.sources.indices.contains(r), case .player(let cur)? = sp.sources[r], cur === p {
                                sceneFrames[r] = holder
                            }
                        }
                    }
                case .generator(let g, let origin)?:
                    if let holder = renderGenerator(g, origin: origin, key: "gs\(r)", now: now) {
                        renderLock.withLock { if scenePreview != nil { sceneFrames[r] = holder } }
                    }
                default: break
                }
            }
        }
        return updated
    }

    // MARK: ジェネレーター（描画スレッド）

    private let generatorFX = EffectProcessor()
    private var generatorBlank: MTLTexture?
    /// 出力していないジェネレーターのプレビューで、秒の動きを数え始める時刻
    private var generatorPreviewStart: [ObjectIdentifier: Double] = [:]

    private func generatorPreviewOrigin(_ slot: ClipSlot) -> Double {
        let id = ObjectIdentifier(slot)
        if let t = generatorPreviewStart[id] { return t }
        let t = CACurrentMediaTime()
        generatorPreviewStart = [id: t]
        return t
    }

    /// ジェネレーターの今の絵を描く（描画スレッドから）。同じ番号の絵は前のコマの描画が終わってから描き直される
    private func renderGenerator(_ g: Effect, origin: Double, key: String, now: Double) -> FrameHolder? {
        let (size, beat) = renderLock.withLock { (renderState.generatorSize, renderState.beat) }
        let ctx = MetalContext.shared
        if generatorBlank?.width != size.0 || generatorBlank?.height != size.1 {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.0, height: size.1,
                                                              mipmapped: false)
            td.usage = [.shaderRead]
            td.storageMode = .private
            generatorBlank = ctx.device.makeTexture(descriptor: td)
        }
        guard let blank = generatorBlank, let cb = ctx.queue.makeCommandBuffer() else { return nil }
        var e = g
        e.enabled = true
        let out = generatorFX.apply(EffectStack(effects: [e], beat: beat, origin: origin), to: blank, key: key, cb: cb, now: now)
        cb.commit()
        return out === blank ? nil : FrameHolder(texture: out)
    }

    private func makeHolder(_ pb: CVPixelBuffer) -> FrameHolder? {
        var cv: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, MetalContext.shared.textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cv)
        guard status == kCVReturnSuccess, let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return FrameHolder(pixelBuffer: pb, cvTexture: cv, texture: tex)
    }

    /// クリッププレビューに描くもの（選択中のクリップ 1 つ、トランスフォーム付き）
    func previewDraws() -> [LayerDraw] {
        renderLock.withLock {
            let f: FrameHolder?
            switch renderState.preview {
            case .none: f = nil
            case .live(let r): f = frames[r]
            case .player, .generator: f = previewFrame
            case .image(let s): f = s.imageTexture(at: CACurrentMediaTime()).map { FrameHolder(texture: $0) }
            }
            guard let f else { return [] }
            return [LayerDraw(texture: f.texture, opacity: 1, blend: .normal,
                              transform: renderState.previewTransform.at(CACurrentMediaTime(), beat: renderState.beat),
                              holder: f, effects: renderState.previewEffects, effectKey: 1000)]
        }
    }

    /// 描画するレイヤー（奥 → 手前の順）。レイヤーの不透明度を掛けて 1 枚ずつに並べたもの（テスト用。エフェクトは見ない）
    func layerDraws() -> [LayerDraw] {
        layerGroups().flatMap { g in
            g.draws.map { d in
                LayerDraw(texture: d.texture, opacity: d.opacity * g.opacity, blend: g.blend, transform: d.transform,
                          layerTransform: d.layerTransform, compTransform: d.compTransform, holder: d.holder,
                          effects: d.effects, effectKey: d.effectKey)
            }
        }
    }

    /// 描画するレイヤー（奥 → 手前の順）。エフェクト込み
    func layerGroups() -> [LayerGroup] {
        let now = CACurrentMediaTime()
        return renderLock.withLock {
            renderState.layers.indices.reversed().compactMap { r in
                layerGroupLocked(r, now: now, blend: renderState.layers[r].blend,
                                 comp: renderState.compTransform.at(now, beat: renderState.beat))
            }
        }
    }

    /// コンポジションのエフェクト（描画スレッド用）
    func compEffects() -> EffectStack {
        renderLock.withLock { renderState.compEffects }
    }

    /// 押しているパッドのエフェクト（描画スレッド用）
    func padEffects() -> [PadRender] {
        renderLock.withLock { renderState.padStacks }
    }

    /// 1 レイヤー分（クロスフェード中は消えていく方 → 新しい方の順）。renderLock の中で呼ぶ
    private func layerGroupLocked(_ r: Int, now: CFTimeInterval, blend: BlendMode, comp: ClipTransform) -> LayerGroup? {
        makeGroupLocked(renderState.layers[r], frame: frames[r], outgoingFrame: outgoingFrames[r], key: r, now: now,
                        blend: blend, comp: comp, beat: renderState.beat)
    }

    /// 1 レイヤーの状態とフレームから、描くものを作る。renderLock の中で呼ぶ
    private func makeGroupLocked(_ l: RenderState.LayerState, frame: FrameHolder?, outgoingFrame: FrameHolder?, key r: Int,
                                 now: CFTimeInterval, blend: BlendMode, comp: ClipTransform, beat: BeatClock) -> LayerGroup? {
        guard !l.muted else { return nil }
        if l.isAdjustment {
            // 調整レイヤー：クリップは描かず、エフェクトを下の絵全体にかける（不透明度＝かかり具合）
            // レイヤーのエフェクト（いつもかかる）＋ 出しているエフェクトのクリップのエフェクト
            var fx = l.layerEffects
            if l.slot?.isEffectClip == true, !l.clipEffects.effects.isEmpty {
                fx = EffectStack(effects: l.layerEffects.effects + l.clipEffects.effects, beat: beat, origin: l.clipEffects.origin)
            }
            guard !fx.isEmpty else { return nil }
            let op = Float(l.opacityAnim.map { min(max($0.value(base: Double(l.opacity), at: now, beat: beat), 0), 1) }
                           ?? Double(l.opacity))
            guard op > 0.001 else { return nil }
            return LayerGroup(draws: [], opacity: op, blend: .normal, effects: fx, key: r, isAdjustment: true)
        }
        let opacity = Float(l.opacityAnim.map { min(max($0.value(base: Double(l.opacity), at: now, beat: beat), 0), 1) }
                            ?? Double(l.opacity))
        guard opacity > 0.001 else { return nil }
        let layerT = l.layerTransform.at(now, beat: beat)
        let clipT = l.transform.at(now, beat: beat)
        var draws: [LayerDraw] = []
        let x = l.outgoing == nil ? 1 : l.crossfade.value(at: now)
        if l.outgoing != nil, !l.outgoingMuted, let f = outgoingFrame {
            // 通常の重ね方なら下の絵はそのまま残し、上に新しい絵を x で重ねる（途中で暗くならない）
            let k: Float = blend == .normal && frame != nil ? 1 : 1 - x
            if k > 0.001 {
                draws.append(LayerDraw(texture: f.texture, opacity: k, blend: blend,
                                       transform: l.outgoingTransform.at(now, beat: beat), layerTransform: layerT,
                                       compTransform: comp, holder: f, effects: l.outgoingEffects, effectKey: r * 2 + 1))
            }
        }
        if l.slot != nil, !l.clipMuted, let f = frame, x > 0.001, clipT.opacity > 0.001 {
            draws.append(LayerDraw(texture: f.texture, opacity: x, blend: blend, transform: clipT,
                                   layerTransform: layerT, compTransform: comp, holder: f,
                                   effects: l.clipEffects, effectKey: r * 2))
        }
        guard !draws.isEmpty else { return nil }
        return LayerGroup(draws: draws, opacity: opacity, blend: blend, effects: l.layerEffects, key: r,
                          blendFX: EffectStack(effects: [l.blendFX], beat: beat))
    }

    /// コーナーピン・テストパターン・マスター不透明度・ブラックアウト（描画スレッド用）
    func renderParams() -> RenderParams {
        let now = CACurrentMediaTime()
        return renderLock.withLock {
            let m = Float(renderState.masterOpacityAnim.map {
                min(max($0.value(base: Double(renderState.masterOpacity), at: now, beat: renderState.beat), 0), 1)
            } ?? Double(renderState.masterOpacity))
            let mm: Float = renderState.compMuted ? 0 : m
            return RenderParams(homographyInverse: renderState.homographyInverse,
                                testPattern: renderState.testPattern,
                                master: mm * renderState.blackoutFade.value(at: now),
                                compMaster: mm)
        }
    }

    /// レイヤープレビュー（1 枚ずつに並べたもの。テスト用）
    func layerPreviewDraws() -> [LayerDraw] {
        layerPreviewGroups().flatMap { g in
            g.draws.map { d in
                LayerDraw(texture: d.texture, opacity: d.opacity * g.opacity, blend: .normal, transform: d.transform,
                          layerTransform: d.layerTransform, holder: d.holder)
            }
        }
    }

    /// レイヤープレビュー：選択中レイヤーだけを黒の上に（レイヤーの不透明度・エフェクト込み）
    func layerPreviewGroups() -> [LayerGroup] {
        if let g = sceneLayerPreviewGroups() { return g }
        return renderLock.withLock {
            let r = renderState.selectedLayer
            guard renderState.layers.indices.contains(r) else { return [] }
            let now = CACurrentMediaTime()
            if renderState.layers[r].isAdjustment {
                // 調整レイヤーは、下のレイヤーを重ねた絵にかかった結果を見せる
                return renderState.layers.indices.reversed().filter { $0 >= r }.compactMap { i in
                    layerGroupLocked(i, now: now, blend: i == r ? .normal : renderState.layers[i].blend, comp: ClipTransform())
                }
            }
            return layerGroupLocked(r, now: now, blend: .normal, comp: ClipTransform()).map { [$0] } ?? []
        }
    }

    /// レイヤー r で表示中のフレーム
    func frame(layer r: Int) -> FrameHolder? {
        renderLock.withLock { frames[r] }
    }

    // MARK: - コーナーピン

    func resetCorners() {
        corners = Engine.defaultCorners
    }

    private func updateHomography() {
        homographyInverse = Homography.squareToQuad(corners).inverse
        syncRenderState()
    }

    // MARK: - 保存と復元（~/Library/Application Support/Halo VJ/state.json）

    struct SavedSlot: Codable {
        var path: String
        /// プロジェクトファイルのフォルダからの場所（その中にある動画だけ）
        var relPath: String?
        var speed: Double
        var loop: Bool
        /// 終わったときの動き（古い保存データには無い → loop から決める）
        var endAction: Int?
        var inPoint: Double?
        var outPoint: Double?
        // トランスフォーム（古い保存データには無い）
        var x: Double?
        var y: Double?
        var scale: Double?
        var rotation: Double?
        var opacity: Double?
        var volume: Double?
        var anims: [String: ParamAnim]?
        var syncMode: Int?
        var syncBeats: Double?
        var jumpBeats: Double?
        var effects: [Effect]?
        var muted: Bool?
        var audioMuted: Bool?
        /// ジェネレーター（動画ではない）。あれば path は使わない
        var generator: Effect?
        /// エフェクトのクリップ（調整レイヤーの枠。絵は持たず、effects がかかる）
        var effectClip: Bool?
        /// エフェクトのクリップの名前
        var title: String?
    }

    /// [ParamKey: ParamAnim] ⇔ 保存用の [String: ParamAnim]
    static func encodeAnims(_ a: [ParamKey: ParamAnim]) -> [String: ParamAnim]? {
        a.isEmpty ? nil : Dictionary(uniqueKeysWithValues: a.map { ($0.key.rawValue, $0.value) })
    }
    static func decodeAnims(_ a: [String: ParamAnim]?) -> [ParamKey: ParamAnim] {
        var out: [ParamKey: ParamAnim] = [:]
        for (k, v) in a ?? [:] { if let key = ParamKey(rawValue: k) { out[key] = v } }
        return out
    }

    struct SavedTransform: Codable {
        var x: Double, y: Double, scale: Double, rotation: Double
        var anims: [String: ParamAnim]?
        init(_ t: TransformParams) {
            x = t.posX; y = t.posY; scale = t.scale; rotation = t.rotation
            anims = Engine.encodeAnims(t.anims)
        }
        func apply(to t: TransformParams) {
            t.set(x: x, y: y, scale: scale, rotation: rotation)
            t.anims = Engine.decodeAnims(anims)
        }
    }

    struct SavedLayer: Codable {
        var opacity: Double
        var blend: Int
        var volume: Double
        var transform: SavedTransform?
        var fadeTime: Double?
        var anims: [String: ParamAnim]?
        var effects: [Effect]?
        var muted: Bool?
        var audioMuted: Bool?
        var isAdjustment: Bool?
        var blendFX: Effect?
        /// レイヤーに付けた名前（シーンには入れない）
        var title: String?
    }

    struct SavedDeck: Codable {
        var id: UUID
        var name: String
    }

    struct SavedState: Codable {
        /// プロジェクトファイルの印
        var format: String?
        /// 保存時のグリッドの列数（古い保存データには無い = 4 列）
        var columns: Int?
        var slots: [SavedSlot?]
        var layers: [SavedLayer]?
        var corners: [[Float]]
        var audioDeviceUID: String?
        var masterOpacity: Double?
        var masterVolume: Double?
        var compTransform: SavedTransform?
        var masterAnims: [String: ParamAnim]?
        var bpm: Double?
        var compEffects: [Effect]?
        var compMuted: Bool?
        var masterAudioMuted: Bool?
        var scenes: [VJScene]?
        /// デッキ（無ければ 1 枚）。スロットはデッキごとに続けて slots に入っている
        var decks: [SavedDeck]?
        var currentDeck: Int?
        /// 押している間だけ効くエフェクトのパッド
        var pads: [SavedPad]?
        /// キューリスト
        var cues: [Cue]?
        /// 自動保存だけ：開いていたプロジェクトと、未保存の変更があったか
        var projectPath: String?
        var projectDirty: Bool?
    }


    private static var stateURL: URL {
        // 画面確認用：VJ_STATE_PATH で別の保存ファイルを使う（ふだんの設定に触れない）
        if let p = ProcessInfo.processInfo.environment["VJ_STATE_PATH"] { return URL(fileURLWithPath: p) }
        return AppInfo.supportDirectory.appendingPathComponent("state.json")
    }

    func scheduleSave() {
        guard !isRestoring else { return }
        if !isDirty {
            isDirty = true
            if ProcessInfo.processInfo.environment["VJ_DEBUG_DIRTY"] != nil {
                Thread.callStackSymbols.prefix(12).forEach { NSLog("DIRTY %@", $0) }
            }
        }
        guard persistent else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        guard persistent else { return }
        var state = makeState(relativeTo: nil)
        state.audioDeviceUID = audioDeviceUID
        state.projectPath = projectURL?.path
        state.projectDirty = isDirty
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: Engine.stateURL, options: .atomic)
        } catch {
            NSLog("VJPlayer: 保存に失敗 \(error)")
        }
    }

    /// 今の中身（グリッド・クリップ・レイヤー・コンポジション・BPM・四隅）。
    /// dir を渡すと、その中にある動画はそこからの場所でも書く
    func makeState(relativeTo dir: URL?) -> SavedState {
        let base = dir?.standardizedFileURL.path
        func rel(_ u: URL) -> String? {
            guard let base else { return nil }
            let p = u.standardizedFileURL.path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : nil
        }
        return SavedState(
            format: dir == nil ? nil : "vjplayer-project-1",
            columns: columns,
            slots: slots.map { $0.map {
                SavedSlot(path: $0.generator == nil && !$0.isEffectClip ? $0.url.path : "",
                          relPath: $0.generator == nil && !$0.isEffectClip ? rel($0.url) : nil,
                          speed: $0.speed, loop: $0.loop,
                          endAction: $0.endAction.rawValue, inPoint: $0.inPoint, outPoint: $0.outPoint,
                          x: $0.posX, y: $0.posY, scale: $0.scale, rotation: $0.rotation,
                          opacity: $0.opacity, volume: $0.clipVolume, anims: Self.encodeAnims($0.anims),
                          syncMode: $0.syncMode.rawValue, syncBeats: $0.syncBeats, jumpBeats: $0.jumpBeats,
                          effects: $0.effects.isEmpty ? nil : $0.effects, muted: $0.muted ? true : nil,
                          audioMuted: $0.audioMuted ? true : nil, generator: $0.generator,
                          effectClip: $0.isEffectClip ? true : nil, title: $0.title.isEmpty ? nil : $0.title)
            } },
            layers: layers.map {
                SavedLayer(opacity: $0.opacity, blend: $0.blend.rawValue, volume: $0.volume,
                           transform: SavedTransform($0.transform), fadeTime: $0.fadeTime,
                           anims: Self.encodeAnims($0.anims), effects: $0.effects.isEmpty ? nil : $0.effects,
                           muted: $0.muted ? true : nil, audioMuted: $0.audioMuted ? true : nil,
                           isAdjustment: $0.isAdjustment ? true : nil,
                           blendFX: $0.blend.isSpecial ? $0.blendFX : nil,
                           title: $0.title.isEmpty ? nil : $0.title)
            },
            corners: corners.map { [$0.x, $0.y] },
            audioDeviceUID: nil,
            masterOpacity: masterOpacity,
            masterVolume: masterVolume,
            compTransform: SavedTransform(compTransform),
            masterAnims: Self.encodeAnims(anims),
            bpm: bpm,
            compEffects: effects.isEmpty ? nil : effects,
            compMuted: compMuted ? true : nil,
            masterAudioMuted: masterAudioMuted ? true : nil,
            scenes: scenes.isEmpty ? nil : scenes,
            decks: decks.map { SavedDeck(id: $0.id, name: $0.name) },
            currentDeck: currentDeck,
            pads: savedPads,
            cues: cues.isEmpty ? nil : cues)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Engine.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        audioDeviceUID = state.audioDeviceUID
        apply(state, baseDir: state.projectPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
        projectURL = state.projectPath.map { URL(fileURLWithPath: $0) }
        isDirty = state.projectDirty ?? false
    }

    /// 保存した中身で、今の中身をまるごと置き換える（再生中のものは止まる）。
    /// baseDir はプロジェクトファイルのフォルダ（動画の場所をそこから探す）
    func apply(_ state: SavedState, baseDir: URL?) {
        isRestoring = true
        defer { isRestoring = false }

        stopAll()
        isBlackout = false
        inspectedIndex = nil
        // グリッドを作り直す（古い保存データは 4 列。段数は保存されたレイヤーの数）
        let savedColumns = min(max(state.columns ?? 4, 1), Self.maxColumns)
        let savedLayers = min(max(state.layers?.count ?? Self.defaultLayers, 1), Self.maxLayers)
        let newLayers = (0..<savedLayers).map { Layer(index: $0) }
        newLayers.forEach(wire)
        let savedDecks = (state.decks?.isEmpty == false ? state.decks! : [SavedDeck(id: UUID(), name: "デッキ 1")])
            .map { Deck(id: $0.id, name: $0.name) }
        restructure(layers: newLayers, columns: savedColumns, layerMap: { _ in nil },
                    decks: savedDecks, deckMap: { _ in nil })
        // 保存したときの 1 デッキのスロット数（段数はクランプ前の数）
        let savedGrid = max((state.layers?.count ?? Self.defaultLayers) * savedColumns, 1)
        selectedLayer = 0

        masterOpacity = min(max(state.masterOpacity ?? 1, 0), 1)
        masterVolume = min(max(state.masterVolume ?? 1, 0), 1)
        compTransform.reset()
        state.compTransform?.apply(to: compTransform)
        anims = Self.decodeAnims(state.masterAnims)
        effects = state.compEffects ?? []
        compMuted = state.compMuted ?? false
        masterAudioMuted = state.masterAudioMuted ?? false
        sceneTween?.invalidate()
        sceneTween = nil
        sceneProgress = nil
        scenes = state.scenes ?? []
        heldPads = [:]
        releasingPads = [:]
        pads = makePads(state.pads)
        cues = state.cues ?? []
        currentCue = nil
        activeSceneID = nil
        closeSceneEditor()
        bpm = state.bpm ?? 120
        masterSpeed = 1
        corners = state.corners.count == 4 ? state.corners.map { SIMD2($0[0], $0[1]) } : Engine.defaultCorners
        for (layer, saved) in zip(layers, state.layers ?? []) {
            layer.opacity = min(max(saved.opacity, 0), 1)
            layer.blend = BlendMode(rawValue: saved.blend) ?? .normal
            layer.volume = min(max(saved.volume, 0), 1)
            saved.transform?.apply(to: layer.transform)
            layer.fadeTime = min(max(saved.fadeTime ?? 0, 0), 10)
            layer.anims = Self.decodeAnims(saved.anims)
            layer.effects = saved.effects ?? []
            layer.muted = saved.muted ?? false
            layer.audioMuted = saved.audioMuted ?? false
            layer.isAdjustment = saved.isAdjustment ?? false
            layer.blendFX = saved.blendFX ?? Effect(kind: .overdrive)
            layer.title = saved.title ?? ""
        }
        for (i, saved) in state.slots.enumerated() {
            let d = i / savedGrid, r = (i % savedGrid) / savedColumns, c = i % savedColumns
            guard d < decks.count, r < layers.count, c < columns, let saved else { continue }
            // プロジェクトのフォルダからの場所 → 元の場所の順に探す。どちらにも無ければ「見つからない」クリップとして置く
            var url = URL(fileURLWithPath: saved.path)
            if let baseDir, let rel = saved.relPath {
                let u = baseDir.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: u.path) { url = u }
            }
            let end = saved.endAction.flatMap(EndAction.init(rawValue:)) ?? (saved.loop ? .loop : .hold)
            let slot = saved.effectClip == true ? ClipSlot(effects: [], title: saved.title ?? "")
                : saved.generator.map { ClipSlot(generator: $0) }
                ?? ClipSlot(url: url, speed: saved.speed, endAction: end, inPoint: saved.inPoint ?? 0, outPoint: saved.outPoint)
            slot.posX = saved.x ?? 0
            slot.posY = saved.y ?? 0
            slot.scale = saved.scale ?? 1
            slot.rotation = saved.rotation ?? 0
            slot.opacity = saved.opacity ?? 1
            slot.clipVolume = saved.volume ?? 1
            slot.anims = Self.decodeAnims(saved.anims)
            slot.syncMode = saved.syncMode.flatMap(SyncMode.init(rawValue:)) ?? .free
            slot.syncBeats = saved.syncBeats ?? 8
            slot.jumpBeats = saved.jumpBeats ?? 0
            slot.effects = saved.effects ?? []
            slot.muted = saved.muted ?? false
            slot.audioMuted = saved.audioMuted ?? false
            setSlot(slotIndex(deck: d, layer: r, column: c), slot)
        }
        currentDeck = min(max(state.currentDeck ?? 0, 0), decks.count - 1)
        syncRenderState()
    }

    // MARK: - プロジェクトファイル（.halovj。名前を変える前の .vjproj も開ける）

    /// 開いているプロジェクトファイル（まだ保存していなければ nil）
    @Published private(set) var projectURL: URL?
    /// 最後に開いた／保存したときから変更があるか
    @Published private(set) var isDirty = false

    static let projectExtension = "halovj"

    /// 何もない状態から始める
    func newProject() {
        apply(SavedState(columns: Self.defaultColumns, slots: [],
                         layers: (0..<Self.defaultLayers).map { _ in
                             SavedLayer(opacity: 1, blend: 0, volume: 1)
                         }, corners: []), baseDir: nil)
        projectURL = nil
        isDirty = false
        saveNow()
    }

    /// プロジェクトファイルを開く
    func openProject(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(SavedState.self, from: data)
        apply(state, baseDir: url.deletingLastPathComponent())
        projectURL = url
        isDirty = false
        noteRecent(url)
        saveNow()
    }

    /// プロジェクトファイルに保存する
    func saveProject(to url: URL) throws {
        let state = makeState(relativeTo: url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(state).write(to: url, options: .atomic)
        projectURL = url
        isDirty = false
        noteRecent(url)
        saveNow()
    }

    /// 見つからない動画の数
    var missingCount: Int { slots.compactMap { $0 }.filter(\.isMissing).count }

    // 最近使ったプロジェクト
    static let recentKey = "recentProjects"
    var recentProjects: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func noteRecent(_ url: URL) {
        guard persistent else { return }
        var list = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: Self.recentKey)
        objectWillChange.send()
    }

    func clearRecent() {
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
        objectWillChange.send()
    }
}
