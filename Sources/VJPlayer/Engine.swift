import AVFoundation
import AppKit
import Metal
import simd

struct RenderParams {
    var homographyInverse: simd_float3x3
    var testPattern: Bool
    var master: Float
}

/// 表示中の映像フレーム。GPU が描画し終わるまで参照を持ち続けるための入れ物。
final class FrameHolder {
    let pixelBuffer: CVPixelBuffer
    let cvTexture: CVMetalTexture
    let texture: MTLTexture
    init(pixelBuffer: CVPixelBuffer, cvTexture: CVMetalTexture, texture: MTLTexture) {
        self.pixelBuffer = pixelBuffer
        self.cvTexture = cvTexture
        self.texture = texture
    }
}

final class Engine: ObservableObject {
    static let shared = Engine(persistent: true)

    /// グリッドの段数 = レイヤー数（上の段ほど手前）
    static let layerCount = 4
    static let columns = 8
    static let slotCount = layerCount * columns
    /// キーボードの並びと同じ 4 段 x 8 列
    static let keyRows = ["12345678", "QWERTYUI", "ASDFGHJK", "ZXCVBNM,"]
    static let keyLabels: [String] = keyRows.flatMap { $0.map(String.init) }
    static let defaultCorners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]

    static func layerOf(_ slotIndex: Int) -> Int { slotIndex / columns }

    @Published private(set) var slots: [ClipSlot?] = Array(repeating: nil, count: Engine.slotCount)
    let layers: [Layer] = (0..<Engine.layerCount).map { Layer(index: $0) }
    /// 各レイヤーで再生中のスロット番号
    @Published private(set) var activeByLayer: [Int?] = Array(repeating: nil, count: Engine.layerCount)
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
    /// マスター不透明度（出力全体をフェード）
    @Published var masterOpacity = 1.0 {
        didSet { syncRenderState(); scheduleSave() }
    }
    /// マスター音量
    @Published var masterVolume = 1.0 {
        didSet {
            AudioOutput.shared.engine.mainMixerNode.outputVolume = Float(masterVolume)
            scheduleSave()
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
            var transform = ClipTransform()
            var layerTransform = ClipTransform()
        }
        enum Preview {
            case none
            /// 出力で再生中 → そのレイヤーのフレームをそのまま見せる
            case live(layer: Int)
            /// 出力していない → プレビュー専用に再生
            case player(PreviewPlayer)
        }
        var layers: [LayerState] = []
        var homographyInverse = matrix_identity_float3x3
        var testPattern = false
        var preview = Preview.none
        var previewTransform = ClipTransform()
        var masterOpacity: Float = 1
        var compTransform = ClipTransform()
        var selectedLayer = 0
    }
    /// クリッププレビュー用の再生（メインスレッドで管理）
    private var previewPlayer: PreviewPlayer?
    /// クリッププレビューで表示中のフレーム（renderLock の中で触る）
    private var previewFrame: FrameHolder?
    private let renderLock = NSLock()
    private var renderState = RenderState()
    /// 各レイヤーで表示中のフレーム（renderLock の中で触る）
    private var frames: [FrameHolder?] = Array(repeating: nil, count: Engine.layerCount)

    /// false ならディスクに保存も復元もしない（セルフテスト用）
    private let persistent: Bool
    private var saveWork: DispatchWorkItem?
    private var isRestoring = false

    /// 選択中レイヤーで再生中のクリップ
    var selectedSlot: ClipSlot? { activeByLayer[selectedLayer].flatMap { slots[$0] } }

    init(persistent: Bool) {
        self.persistent = persistent
        for layer in layers {
            let r = layer.index
            layer.onChanged = { [weak self] in
                self?.syncRenderState()
                self?.scheduleSave()
            }
            layer.onVolumeChanged = { [weak self] in self?.applyVolume(layer: r) }
        }
        compTransform.onChanged = { [weak self] in
            self?.syncRenderState()
            self?.scheduleSave()
        }
        if persistent { restore() }
        updateHomography()
        syncRenderState()
    }

    // MARK: - 再生操作

    /// スロットを頭から再生する。同じレイヤーで再生中だったクリップは止まる（他のレイヤーはそのまま）。
    func trigger(_ index: Int) {
        guard index >= 0, index < slots.count, let slot = slots[index] else { return }
        let r = Self.layerOf(index)
        if let a = activeByLayer[r], a != index { slots[a]?.stopAndRearm() }
        activeByLayer[r] = index
        selectedLayer = r
        slot.playFromStart()
        slot.invalidateShownFrame()
        syncRenderState()
    }

    /// 1つのレイヤーを止めて消す
    func stopLayer(_ r: Int) {
        guard r >= 0, r < layers.count else { return }
        if let a = activeByLayer[r] { slots[a]?.stopAndRearm() }
        activeByLayer[r] = nil
        renderLock.withLock {
            renderState.layers[r].slot = nil
            frames[r] = nil
        }
        syncRenderState()
    }

    /// 全レイヤーを止めて黒にする
    func blackout() {
        for r in layers.indices { stopLayer(r) }
    }

    /// クリップを選択する（出力はしない）。クリッププレビューとパラメーターの対象になる
    func selectClip(_ index: Int) {
        guard slots.indices.contains(index), slots[index] != nil else { return }
        inspectedIndex = index
        inspectorTab = .clip
    }

    // MARK: - クリップの読み込み

    /// 複数のクリップを index から右へ順番に入れる（その段の右端まで）
    func load(urls: [URL], startingAt index: Int) {
        let rowEnd = (Self.layerOf(index) + 1) * Self.columns
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

        // 再生中のクリップと、移動後の位置
        func newIndex(_ i: Int) -> Int { i == from ? to : (i == to ? from : i) }
        let playing: [(old: Int, new: Int)] = activeByLayer.compactMap { $0 }.map { ($0, newIndex($0)) }
        let selectedOld = activeByLayer[selectedLayer]

        slots.swapAt(from, to)
        for i in [from, to] {
            slots[i]?.layerVolume = Float(layers[Self.layerOf(i)].volume)
        }

        var newActive: [Int?] = Array(repeating: nil, count: Self.layerCount)
        // 移動したクリップを優先して、各レイヤーに1つだけ残す
        for p in playing.sorted(by: { a, _ in a.old == from || a.old == to }) {
            let r = Self.layerOf(p.new)
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
            selectedLayer = Self.layerOf(newIndex(s))
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
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.message = "クリップを選択（複数選ぶと右隣のスロットに順番に入ります。この段の右端まで）"
        if panel.runModal() == .OK {
            load(urls: panel.urls, startingAt: index)
        }
    }

    private func setSlot(_ index: Int, _ slot: ClipSlot?) {
        let r = Self.layerOf(index)
        if activeByLayer[r] == index { stopLayer(r) }
        slot?.onReady = { [weak self] in self?.syncRenderState() }
        slot?.onSettingsChanged = { [weak self] in
            self?.syncRenderState()
            self?.scheduleSave()
        }
        if slot == nil && inspectedIndex == index { inspectedIndex = nil }
        slot?.layerVolume = Float(layers[r].volume)
        slot?.masterRate = masterSpeed
        slots[index] = slot
        syncRenderState()
    }

    private func applyVolume(layer r: Int) {
        let v = Float(layers[r].volume)
        for c in 0..<Self.columns {
            slots[r * Self.columns + c]?.layerVolume = v
        }
    }

    // MARK: - 描画スレッドとのやりとり

    /// 描画スレッド用の状態を作り直す（メインスレッドで、状態が変わるたびに呼ぶ）
    func syncRenderState() {
        let st = RenderState(
            layers: layers.map { l in
                let slot = activeByLayer[l.index].flatMap { slots[$0] }
                return RenderState.LayerState(slot: slot, opacity: Float(l.opacity), blend: l.blend,
                                              transform: slot?.transform ?? ClipTransform(),
                                              layerTransform: l.transform.value)
            },
            homographyInverse: homographyInverse,
            testPattern: testPattern)
        var state = st
        (state.preview, state.previewTransform) = syncPreview()
        state.masterOpacity = Float(masterOpacity)
        state.compTransform = compTransform.value
        state.selectedLayer = selectedLayer
        renderLock.withLock { renderState = state }
    }

    /// 選択中のクリップのプレビューをどこから出すか決める
    private func syncPreview() -> (RenderState.Preview, ClipTransform) {
        guard let i = inspectedIndex, let slot = slots[i] else {
            previewPlayer?.cancel()
            previewPlayer = nil
            return (.none, ClipTransform())
        }
        let r = Self.layerOf(i)
        if activeByLayer[r] == i {
            previewPlayer?.cancel()
            previewPlayer = nil
            return (.live(layer: r), slot.transform)
        }
        guard slot.isReady else { return (.none, slot.transform) }
        if previewPlayer?.slot !== slot {
            previewPlayer?.cancel()
            previewPlayer = PreviewPlayer(slot: slot)
        }
        previewPlayer?.setRate(slot.effectiveSpeed)
        return (previewPlayer.map { .player($0) } ?? .none, slot.transform)
    }

    /// 各レイヤーの新しいフレームを取り込む。描画スレッドから 1 vsync に 1 回呼ばれる。
    /// 新しいフレームが来たレイヤーの数を返す。
    @discardableResult
    func updateFrame() -> Int {
        let layerStates = renderLock.withLock { renderState.layers }
        let now = CACurrentMediaTime()
        var updated = 0
        for (r, l) in layerStates.enumerated() {
            guard let slot = l.slot else {
                renderLock.withLock { frames[r] = nil }
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
                if renderState.layers[r].slot === slot { frames[r] = holder }
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
        } else {
            renderLock.withLock { previewFrame = nil }
        }
        return updated
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
            case .player: f = previewFrame
            }
            guard let f else { return [] }
            return [LayerDraw(texture: f.texture, opacity: 1, blend: .normal,
                              transform: renderState.previewTransform, holder: f)]
        }
    }

    /// 描画するレイヤー（奥 → 手前の順）
    func layerDraws() -> [LayerDraw] {
        renderLock.withLock {
            renderState.layers.indices.reversed().compactMap { r in
                let l = renderState.layers[r]
                guard l.slot != nil, let f = frames[r], l.opacity * l.transform.opacity > 0.001 else { return nil }
                return LayerDraw(texture: f.texture, opacity: l.opacity, blend: l.blend, transform: l.transform,
                                 layerTransform: l.layerTransform, compTransform: renderState.compTransform, holder: f)
            }
        }
    }

    /// コーナーピン・テストパターン・マスター不透明度（描画スレッド用）
    func renderParams() -> RenderParams {
        renderLock.withLock {
            RenderParams(homographyInverse: renderState.homographyInverse,
                         testPattern: renderState.testPattern, master: renderState.masterOpacity)
        }
    }

    /// レイヤープレビュー：選択中レイヤーだけを黒の上に（レイヤーの不透明度込み）
    func layerPreviewDraws() -> [LayerDraw] {
        renderLock.withLock {
            let r = renderState.selectedLayer
            guard renderState.layers.indices.contains(r) else { return [] }
            let l = renderState.layers[r]
            guard l.slot != nil, let f = frames[r] else { return [] }
            return [LayerDraw(texture: f.texture, opacity: l.opacity, blend: .normal, transform: l.transform,
                              layerTransform: l.layerTransform, holder: f)]
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

    // MARK: - 保存と復元（~/Library/Application Support/VJPlayer/state.json）

    private struct SavedSlot: Codable {
        var path: String
        var speed: Double
        var loop: Bool
        // トランスフォーム（古い保存データには無い）
        var x: Double?
        var y: Double?
        var scale: Double?
        var rotation: Double?
        var opacity: Double?
        var volume: Double?
    }

    private struct SavedTransform: Codable {
        var x: Double, y: Double, scale: Double, rotation: Double
        init(_ t: TransformParams) { x = t.posX; y = t.posY; scale = t.scale; rotation = t.rotation }
        func apply(to t: TransformParams) { t.set(x: x, y: y, scale: scale, rotation: rotation) }
    }

    private struct SavedLayer: Codable {
        var opacity: Double
        var blend: Int
        var volume: Double
        var transform: SavedTransform?
    }

    private struct SavedState: Codable {
        /// 保存時のグリッドの列数（古い保存データには無い = 4 列）
        var columns: Int?
        var slots: [SavedSlot?]
        var layers: [SavedLayer]?
        var corners: [[Float]]
        var audioDeviceUID: String?
        var masterOpacity: Double?
        var masterVolume: Double?
        var compTransform: SavedTransform?
    }

    private static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VJPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    func scheduleSave() {
        guard persistent, !isRestoring else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        guard persistent else { return }
        let state = SavedState(
            columns: Self.columns,
            slots: slots.map { $0.map {
                SavedSlot(path: $0.url.path, speed: $0.speed, loop: $0.loop,
                          x: $0.posX, y: $0.posY, scale: $0.scale, rotation: $0.rotation,
                          opacity: $0.opacity, volume: $0.clipVolume)
            } },
            layers: layers.map {
                SavedLayer(opacity: $0.opacity, blend: $0.blend.rawValue, volume: $0.volume,
                           transform: SavedTransform($0.transform))
            },
            corners: corners.map { [$0.x, $0.y] },
            audioDeviceUID: audioDeviceUID,
            masterOpacity: masterOpacity,
            masterVolume: masterVolume,
            compTransform: SavedTransform(compTransform))
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: Engine.stateURL, options: .atomic)
        } catch {
            NSLog("VJPlayer: 保存に失敗 \(error)")
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Engine.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        isRestoring = true
        defer { isRestoring = false }

        audioDeviceUID = state.audioDeviceUID
        masterOpacity = min(max(state.masterOpacity ?? 1, 0), 1)
        masterVolume = min(max(state.masterVolume ?? 1, 0), 1)
        state.compTransform?.apply(to: compTransform)
        if state.corners.count == 4 {
            corners = state.corners.map { SIMD2($0[0], $0[1]) }
        }
        for (layer, saved) in zip(layers, state.layers ?? []) {
            layer.opacity = min(max(saved.opacity, 0), 1)
            layer.blend = BlendMode(rawValue: saved.blend) ?? .normal
            layer.volume = min(max(saved.volume, 0), 1)
            saved.transform?.apply(to: layer.transform)
        }
        // 列数が違っても「何段目の何列目」を保つ
        let savedColumns = max(state.columns ?? 4, 1)
        for (i, saved) in state.slots.enumerated() {
            let r = i / savedColumns, c = i % savedColumns
            guard r < Self.layerCount, c < Self.columns,
                  let saved, FileManager.default.fileExists(atPath: saved.path) else { continue }
            let slot = ClipSlot(url: URL(fileURLWithPath: saved.path), speed: saved.speed, loop: saved.loop)
            slot.posX = saved.x ?? 0
            slot.posY = saved.y ?? 0
            slot.scale = saved.scale ?? 1
            slot.rotation = saved.rotation ?? 0
            slot.opacity = saved.opacity ?? 1
            slot.clipVolume = saved.volume ?? 1
            setSlot(r * Self.columns + c, slot)
        }
    }
}
