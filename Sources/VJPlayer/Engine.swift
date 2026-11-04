import AVFoundation
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
    let pixelBuffer: CVPixelBuffer
    let cvTexture: CVMetalTexture
    let texture: MTLTexture
    init(pixelBuffer: CVPixelBuffer, cvTexture: CVMetalTexture, texture: MTLTexture) {
        self.pixelBuffer = pixelBuffer
        self.cvTexture = cvTexture
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
    var slotCount: Int { layers.count * columns }
    /// スロット番号 → レイヤー（段）
    func layerOf(_ slotIndex: Int) -> Int { slotIndex / columns }

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
            var clipMuted = false
            var outgoingMuted = false
            var clipEffects = EffectStack()
            var outgoingEffects = EffectStack()
            var layerEffects = EffectStack()
            /// 新しいクリップの見え具合（0→1）。消えていく方は 1 - これ
            var crossfade = Fade()
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
        var previewTransform = AnimTransform()
        var masterOpacity: Float = 1
        var masterOpacityAnim: ParamAnim?
        var blackoutFade = Fade()
        var compTransform = AnimTransform()
        var beat = BeatClock()
        var compEffects = EffectStack()
        var previewEffects = EffectStack()
        var compMuted = false
        var selectedLayer = 0
    }
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

    /// r 段目の位置に新しいレイヤーを入れる（r = layerCount なら一番下＝一番奥）
    func insertLayer(at r: Int) {
        guard layers.count < Self.maxLayers else { return }
        let r = min(max(r, 0), layers.count)
        let layer = Layer(index: r)
        wire(layer)
        var newLayers = layers
        newLayers.insert(layer, at: r)
        restructure(layers: newLayers, columns: columns,
                    layerMap: { $0 >= r ? $0 + 1 : $0 })
    }

    /// r 段目のレイヤーを消す（中のクリップも外れる）。最後の 1 段は消せない
    func removeLayer(_ r: Int) {
        guard layers.count > 1, layers.indices.contains(r) else { return }
        var newLayers = layers
        newLayers.remove(at: r)
        restructure(layers: newLayers, columns: columns,
                    layerMap: { $0 == r ? nil : ($0 > r ? $0 - 1 : $0) })
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
    func layerHasClips(_ r: Int) -> Bool { (0..<columns).contains { slots[r * columns + $0] != nil } }
    func columnHasClips(_ c: Int) -> Bool { layers.indices.contains { slots[$0 * columns + c] != nil } }

    /// グリッドの形を変える。layerMap / columnMap は「前の段・列 → 新しい段・列（nil = 消える）」
    private func restructure(layers newLayers: [Layer], columns newColumns: Int,
                             layerMap: (Int) -> Int?, columnMap: (Int) -> Int? = { $0 }) {
        for r in layers.indices { finishCrossfade(r) }
        let oldColumns = columns
        func map(_ i: Int) -> Int? {
            guard let r = layerMap(i / oldColumns), let c = columnMap(i % oldColumns) else { return nil }
            return r * newColumns + c
        }

        // 消えるクリップは止めて外す
        var newSlots: [ClipSlot?] = Array(repeating: nil, count: newLayers.count * newColumns)
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
            let nr = n / newColumns
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
        slots = newSlots
        activeByLayer = newActive
        for (i, slot) in slots.enumerated() {
            slot?.layerVolume = layers[i / columns].audible ? Float(layers[i / columns].volume) : 0
            slot?.fadeGain = 1
        }
        inspectedIndex = newInspected
        selectedLayer = min(max(newSelected, 0), layers.count - 1)
        syncRenderState()
        scheduleSave()
    }

    // MARK: - 再生操作

    /// スロットを頭から再生する。同じレイヤーで再生中だったクリップは止まる（他のレイヤーはそのまま）。
    func trigger(_ index: Int) {
        guard index >= 0, index < slots.count, let slot = slots[index] else { return }
        let r = layerOf(index)
        // 消えかけのクリップをもう一度押した → それは頭から出し直す（クロスフェードの相手ではなくなる）
        if outgoing[r] == index { dropOutgoing(r, stop: false) }
        let fadeTime = layers[r].fadeTime
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
        selectedLayer = r
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
        let copy = ClipSlot(url: url, speed: src.speed, endAction: src.endAction,
                            inPoint: src.inPoint, outPoint: src.outPoint)
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
        case .composition: addEffect(k)
        case .layer: layers[selectedLayer].addEffect(k)
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

    /// 複数のクリップを index から右へ順番に入れる（その段の右端まで）
    func load(urls: [URL], startingAt index: Int) {
        let rowEnd = (layerOf(index) + 1) * columns
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
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
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
        for c in 0..<columns {
            slots[r * columns + c]?.layerVolume = v
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
                                              clipMuted: slot?.muted ?? false,
                                              outgoingMuted: out?.muted ?? false,
                                              clipEffects: EffectStack(effects: slot?.effects ?? [], beat: beatClock,
                                                                       origin: slot?.animOrigin ?? 0),
                                              outgoingEffects: EffectStack(effects: out?.effects ?? [], beat: beatClock,
                                                                           origin: out?.animOrigin ?? 0),
                                              layerEffects: EffectStack(effects: l.effects, beat: beatClock),
                                              crossfade: crossfades[l.index])
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
        state.previewEffects = EffectStack(effects: inspectedIndex.flatMap { slots[$0]?.effects } ?? [], beat: beatClock,
                                           origin: inspectedIndex.flatMap { slots[$0]?.animOrigin } ?? 0)
        state.selectedLayer = selectedLayer
        renderLock.withLock { renderState = state }
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
                if let pb = out.frameForDisplay(at: now), let holder = makeHolder(pb) {
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

    /// 1 レイヤー分（クロスフェード中は消えていく方 → 新しい方の順）。renderLock の中で呼ぶ
    private func layerGroupLocked(_ r: Int, now: CFTimeInterval, blend: BlendMode, comp: ClipTransform) -> LayerGroup? {
        let l = renderState.layers[r]
        guard !l.muted else { return nil }
        let beat = renderState.beat
        let opacity = Float(l.opacityAnim.map { min(max($0.value(base: Double(l.opacity), at: now, beat: beat), 0), 1) }
                            ?? Double(l.opacity))
        guard opacity > 0.001 else { return nil }
        let layerT = l.layerTransform.at(now, beat: beat)
        let clipT = l.transform.at(now, beat: beat)
        var draws: [LayerDraw] = []
        let x = l.outgoing == nil ? 1 : l.crossfade.value(at: now)
        if l.outgoing != nil, !l.outgoingMuted, let f = outgoingFrames[r] {
            // 通常の重ね方なら下の絵はそのまま残し、上に新しい絵を x で重ねる（途中で暗くならない）
            let k: Float = blend == .normal && frames[r] != nil ? 1 : 1 - x
            if k > 0.001 {
                draws.append(LayerDraw(texture: f.texture, opacity: k, blend: blend,
                                       transform: l.outgoingTransform.at(now, beat: beat), layerTransform: layerT,
                                       compTransform: comp, holder: f, effects: l.outgoingEffects, effectKey: r * 2 + 1))
            }
        }
        if l.slot != nil, !l.clipMuted, let f = frames[r], x > 0.001, clipT.opacity > 0.001 {
            draws.append(LayerDraw(texture: f.texture, opacity: x, blend: blend, transform: clipT,
                                   layerTransform: layerT, compTransform: comp, holder: f,
                                   effects: l.clipEffects, effectKey: r * 2))
        }
        guard !draws.isEmpty else { return nil }
        return LayerGroup(draws: draws, opacity: opacity, blend: blend, effects: l.layerEffects, key: r)
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
        renderLock.withLock {
            let r = renderState.selectedLayer
            guard renderState.layers.indices.contains(r) else { return [] }
            return layerGroupLocked(r, now: CACurrentMediaTime(), blend: .normal, comp: ClipTransform()).map { [$0] } ?? []
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
    }

    /// [ParamKey: ParamAnim] ⇔ 保存用の [String: ParamAnim]
    private static func encodeAnims(_ a: [ParamKey: ParamAnim]) -> [String: ParamAnim]? {
        a.isEmpty ? nil : Dictionary(uniqueKeysWithValues: a.map { ($0.key.rawValue, $0.value) })
    }
    private static func decodeAnims(_ a: [String: ParamAnim]?) -> [ParamKey: ParamAnim] {
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
        if !isDirty { isDirty = true }
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
                SavedSlot(path: $0.url.path, relPath: rel($0.url), speed: $0.speed, loop: $0.loop,
                          endAction: $0.endAction.rawValue, inPoint: $0.inPoint, outPoint: $0.outPoint,
                          x: $0.posX, y: $0.posY, scale: $0.scale, rotation: $0.rotation,
                          opacity: $0.opacity, volume: $0.clipVolume, anims: Self.encodeAnims($0.anims),
                          syncMode: $0.syncMode.rawValue, syncBeats: $0.syncBeats, jumpBeats: $0.jumpBeats,
                          effects: $0.effects.isEmpty ? nil : $0.effects, muted: $0.muted ? true : nil,
                          audioMuted: $0.audioMuted ? true : nil)
            } },
            layers: layers.map {
                SavedLayer(opacity: $0.opacity, blend: $0.blend.rawValue, volume: $0.volume,
                           transform: SavedTransform($0.transform), fadeTime: $0.fadeTime,
                           anims: Self.encodeAnims($0.anims), effects: $0.effects.isEmpty ? nil : $0.effects,
                           muted: $0.muted ? true : nil, audioMuted: $0.audioMuted ? true : nil)
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
            masterAudioMuted: masterAudioMuted ? true : nil)
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
        restructure(layers: newLayers, columns: savedColumns, layerMap: { _ in nil })
        selectedLayer = 0

        masterOpacity = min(max(state.masterOpacity ?? 1, 0), 1)
        masterVolume = min(max(state.masterVolume ?? 1, 0), 1)
        compTransform.reset()
        state.compTransform?.apply(to: compTransform)
        anims = Self.decodeAnims(state.masterAnims)
        effects = state.compEffects ?? []
        compMuted = state.compMuted ?? false
        masterAudioMuted = state.masterAudioMuted ?? false
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
        }
        for (i, saved) in state.slots.enumerated() {
            let r = i / savedColumns, c = i % savedColumns
            guard r < layers.count, c < columns, let saved else { continue }
            // プロジェクトのフォルダからの場所 → 元の場所の順に探す。どちらにも無ければ「見つからない」クリップとして置く
            var url = URL(fileURLWithPath: saved.path)
            if let baseDir, let rel = saved.relPath {
                let u = baseDir.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: u.path) { url = u }
            }
            let end = saved.endAction.flatMap(EndAction.init(rawValue:)) ?? (saved.loop ? .loop : .hold)
            let slot = ClipSlot(url: url, speed: saved.speed, endAction: end,
                                inPoint: saved.inPoint ?? 0, outPoint: saved.outPoint)
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
            setSlot(r * columns + c, slot)
        }
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
