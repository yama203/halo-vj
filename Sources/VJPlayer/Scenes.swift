import AppKit
import QuartzCore
import simd

/// シーン：お気に入りの組み合わせ。グリッドはそのままで、
/// 「どのクリップを再生中か」と、レイヤー・コンポジションの設定（不透明度・重ね方・トランスフォーム・エフェクトなど）を丸ごと持つ。
/// 呼び出すと、その状態にフェード時間をかけて（0 ならすぐ）切り替わる
struct VJScene: Codable, Identifiable {
    var id = UUID()
    var name: String
    /// 切り替えにかける秒数（0 = すぐ）
    var fade = 1.0
    /// レイヤーごとの、再生するクリップの列（nil = 止める）
    var playing: [Int?]
    /// 使うデッキ（グリッド）。nil = 1 枚目。呼び出すと上のグリッドもこのデッキになる
    var deck: UUID?
    /// レイヤーごとに別のデッキのクリップを流すときだけ、そのデッキ（nil = deck と同じ）
    var layerDecks: [UUID?]?
    /// レイヤーごとの、流すクリップの目印（nil の所 = 止める）。あればこちらで探すので、クリップを動かしても同じクリップが出る
    /// （無い = 前に作ったシーン。playing の列で探す）
    var playingIDs: [UUID?]?
    var layers: [Engine.SavedLayer]
    var masterOpacity: Double
    var compTransform: Engine.SavedTransform
    var masterAnims: [String: ParamAnim]?
    var compEffects: [Effect]
    /// 保存したときの出力の小さな絵（PNG）
    var thumbnail: Data?

    static let fadeChoices: [Double] = [0, 0.5, 1, 2, 4, 8]
    static func fadeLabel(_ s: Double) -> String { s <= 0 ? "すぐ" : String(format: s < 1 ? "%.1f秒" : "%.0f秒", s) }
}

extension Engine {
    // MARK: - シーン：保存

    /// 今の状態をシーンにする
    func captureScene(name: String, fade: Double = 1) -> VJScene {
        let state = makeState(relativeTo: nil)
        let deckID = decks[currentDeck].id
        let ld: [UUID?] = layers.indices.map { r in
            activeByLayer[r].flatMap { a in deckOf(a) == currentDeck ? nil : decks[deckOf(a)].id }
        }
        return VJScene(name: name, fade: fade,
                       playing: layers.indices.map { r in activeByLayer[r].map { columnOf($0) } },
                       deck: deckID,
                       layerDecks: ld.contains { $0 != nil } ? ld : nil,
                       playingIDs: layers.indices.map { r in activeByLayer[r].flatMap { slots[$0]?.id } },
                       layers: state.layers ?? [],
                       masterOpacity: masterOpacity,
                       compTransform: SavedTransform(compTransform),
                       masterAnims: Self.encodeAnims(anims),
                       compEffects: effects,
                       thumbnail: RenderLoop.shared.snapshotPNG())
    }

    /// 今の状態を新しいシーンとして足す
    @discardableResult
    func addScene() -> VJScene {
        var n = scenes.count + 1
        while scenes.contains(where: { $0.name == "シーン \(n)" }) { n += 1 }
        let s = captureScene(name: "シーン \(n)", fade: scenes.last?.fade ?? 1)
        scenes.append(s)
        activeSceneID = s.id
        return s
    }

    /// 何も流さない空のシーンを足して、そのまま編集を始める（出力はそのまま）
    @discardableResult
    func addEmptyScene() -> VJScene {
        var n = scenes.count + 1
        while scenes.contains(where: { $0.name == "シーン \(n)" }) { n += 1 }
        let s = VJScene(name: "シーン \(n)", fade: scenes.last?.fade ?? 1,
                        playing: layers.map { _ in nil },
                        deck: decks[shownDeck].id,
                        playingIDs: layers.map { _ in nil },
                        layers: layers.map { l in
                            // 調整レイヤーはそのまま（エフェクトは空）
                            SavedLayer(opacity: 1, blend: 0, volume: 1, isAdjustment: l.isAdjustment ? true : nil)
                        },
                        masterOpacity: 1,
                        compTransform: SavedTransform(TransformParams()),
                        compEffects: [])
        scenes.append(s)
        editScene(s.id)
        return s
    }

    /// シーンを今の状態で上書きする（名前・フェード時間はそのまま）
    func overwriteScene(_ id: UUID) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        var s = captureScene(name: scenes[i].name, fade: scenes[i].fade)
        s.id = id
        scenes[i] = s
        activeSceneID = id
        if sceneDraft?.sceneID == id { reloadSceneDraft(id) }
    }

    func deleteScene(_ id: UUID) {
        scenes.removeAll { $0.id == id }
        if activeSceneID == id { activeSceneID = nil }
        if sceneDraft?.sceneID == id { closeSceneEditor() }
    }

    func updateScene(_ id: UUID, _ f: (inout VJScene) -> Void) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        f(&scenes[i])
    }

    // MARK: - シーン：呼び出し

    /// シーンに切り替える。フェード時間があれば、クリップはクロスフェード、値はなめらかに動かす
    func recallScene(_ id: UUID, fade fadeOverride: Double? = nil) {
        guard let sc = scenes.first(where: { $0.id == id }) else { return }
        sceneTween?.invalidate()
        sceneTween = nil
        finishCueFade()
        activeSceneID = id
        let T = max(fadeOverride ?? sc.fade, 0)
        let n = min(layers.count, sc.layers.count, sc.playing.count)

        // 始まりの値
        struct LayerStart { var opacity: Double; var t: (Double, Double, Double, Double); var effects: [Effect]; var blendFX: Effect }
        let startLayers = layers.map {
            LayerStart(opacity: $0.opacity, t: ($0.transform.posX, $0.transform.posY, $0.transform.scale, $0.transform.rotation),
                       effects: $0.effects, blendFX: $0.blendFX)
        }
        let startMaster = masterOpacity
        let startComp = (compTransform.posX, compTransform.posY, compTransform.scale, compTransform.rotation)
        let startCompFX = effects

        // 上のグリッドをシーンのデッキにする
        let sceneDeck = deckIndex(sc.deck) ?? 0
        currentDeck = sceneDeck

        // クリップを切り替える（同じクリップはそのまま続ける）。クリップは目印で探す（動かしていても同じクリップ）
        let targets = sceneTargets(sc)
        var fadeIn = Set<Int>(), fadeOutStop = Set<Int>()
        for r in 0..<n {
            let want = targets[r]
            guard want != activeByLayer[r] else { continue }
            if let w = want {
                let wasEmpty = activeByLayer[r] == nil
                trigger(w, fadeTime: T, select: false)
                if wasEmpty && T > 0 { fadeIn.insert(r) }
            } else if T > 0 {
                fadeOutStop.insert(r)
            } else {
                stopLayer(r)
            }
        }

        // 混ぜられない設定（重ね方・ミュートなど）を入れる
        var discreteDone = false
        func applyDiscrete() {
            discreteDone = true
            for r in 0..<n {
                let s = sc.layers[r], l = layers[r]
                l.blend = BlendMode(rawValue: s.blend) ?? .normal
                l.volume = s.volume
                l.fadeTime = s.fadeTime ?? l.fadeTime
                l.muted = s.muted ?? false
                l.audioMuted = s.audioMuted ?? false
                l.anims = Self.decodeAnims(s.anims)
                l.transform.anims = Self.decodeAnims(s.transform?.anims)
            }
            anims = Self.decodeAnims(sc.masterAnims)
            compTransform.anims = Self.decodeAnims(sc.compTransform.anims)
        }

        // p（0〜1）の時点の値を入れる
        func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }
        func step(_ p: Double) {
            let k = p * p * (3 - 2 * p)
            for r in 0..<n {
                let s = sc.layers[r], l = layers[r], st = startLayers[r]
                let from = fadeIn.contains(r) ? 0 : st.opacity
                let to = fadeOutStop.contains(r) ? 0 : s.opacity
                l.opacity = lerp(from, to, k)
                let tt = s.transform
                l.transform.set(x: lerp(st.t.0, tt?.x ?? 0, k), y: lerp(st.t.1, tt?.y ?? 0, k),
                                scale: lerp(st.t.2, tt?.scale ?? 1, k), rotation: lerp(st.t.3, tt?.rotation ?? 0, k))
                l.effects = Self.mixEffects(st.effects, s.effects ?? [], k: k, p: p)
                if let bfx = s.blendFX { l.blendFX = Self.mixEffects([st.blendFX], [bfx], k: k, p: p).first ?? bfx }
            }
            masterOpacity = lerp(startMaster, sc.masterOpacity, k)
            let ct = sc.compTransform
            compTransform.set(x: lerp(startComp.0, ct.x, k), y: lerp(startComp.1, ct.y, k),
                              scale: lerp(startComp.2, ct.scale, k), rotation: lerp(startComp.3, ct.rotation, k))
            effects = Self.mixEffects(startCompFX, sc.compEffects, k: k, p: p)
            if p >= 0.5 && !discreteDone { applyDiscrete() }
        }

        func finish() {
            sceneTween?.invalidate()
            sceneTween = nil
            sceneProgress = nil
            step(1)
            for r in fadeOutStop {
                stopLayer(r)
                layers[r].opacity = sc.layers[r].opacity
            }
        }

        guard T > 0 else {
            applyDiscrete()
            step(1)
            return
        }
        let t0 = CACurrentMediaTime()
        sceneProgress = 0
        step(0)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = min((CACurrentMediaTime() - t0) / T, 1)
            if p >= 1 { finish(); return }
            self.sceneProgress = p
            step(p)
        }
        RunLoop.main.add(timer, forMode: .common)
        sceneTween = timer
    }

    /// シーンで流すクリップ：段 → スロット番号。目印があれば目印で探し、そのクリップが今ある段で流す
    /// （目印の無い前のシーンは、列とデッキで探す）
    func sceneTargets(_ sc: VJScene) -> [Int: Int] {
        var out: [Int: Int] = [:]
        let sceneDeck = deckIndex(sc.deck) ?? 0
        for r in 0..<min(layers.count, sc.playing.count) {
            if let ids = sc.playingIDs, r < ids.count {
                guard let id = ids[r], let i = slots.firstIndex(where: { $0?.id == id }) else { continue }
                let l = layerOf(i)
                // 動かして同じ段に 2 つ来たら、元からその段のものを優先
                if out[l] == nil || l == r { out[l] = i }
                continue
            }
            guard let c = sc.playing[r], c >= 0, c < columns else { continue }
            let d = sc.layerDecks.flatMap { $0.indices.contains(r) ? deckIndex($0[r]) : nil } ?? sceneDeck
            let i = slotIndex(deck: d, layer: r, column: c)
            if slots[i] != nil { out[r] = i }
        }
        return out
    }

    /// 目印の無い前のシーンに、今その場所にあるクリップの目印を覚えさせる（読み込んだとき）
    func adoptSceneClipIDs() {
        guard scenes.contains(where: { $0.playingIDs == nil }) else { return }
        scenes = scenes.map { sc in
            guard sc.playingIDs == nil else { return sc }
            var s2 = sc
            let t = sceneTargets(sc)
            s2.playingIDs = sc.playing.indices.map { r in t[r].flatMap { slots[$0]?.id } }
            return s2
        }
    }

    /// エフェクトの並びを a → b に混ぜる。同じ種類が同じ順で並んでいれば値をなめらかに動かし、
    /// そうでなければ半分の所で入れ替える
    static func mixEffects(_ a: [Effect], _ b: [Effect], k: Double, p: Double) -> [Effect] {
        if p >= 1 { return b }
        guard a.count == b.count, zip(a, b).allSatisfy({ $0.kind == $1.kind }) else { return p < 0.5 ? a : b }
        return zip(a, b).map { ea, eb in
            var e = eb
            e.enabled = p < 0.5 ? ea.enabled : eb.enabled
            let ps = eb.kind.params
            e.values = ps.indices.map { i in
                let va = ea.value(i), vb = eb.value(i)
                // 選択肢・オン/オフは半分の所で切り替える
                return ps[i].animatable ? va + (vb - va) * k : (p < 0.5 ? va : vb)
            }
            e.color = p < 0.5 ? ea.color : eb.color
            return e
        }
    }
}

extension RenderLoop {
    /// 出力の今の絵の小さな画像（PNG）。シーンのサムネイル用（メインスレッドから）
    func snapshotPNG(from source: MTLTexture? = nil, width w: Int = 192, height h: Int = 108) -> Data? {
        guard let src = source ?? lastComposite() else { return nil }
        let ctx = MetalContext.shared
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let dst = ctx.device.makeTexture(descriptor: td), let cb = ctx.queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        var u = Uniforms(hinv: matrix_identity_float3x3, viewSize: SIMD2(Float(w), Float(h)), mode: 1, master: 1)
        enc.setRenderPipelineState(ctx.pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(ctx.sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        dst.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2); px[i + 3] = 255 }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: w * 4, bitsPerPixel: 32) else { return nil }
        px.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, px.count) }
        return rep.representation(using: .png, properties: [:])
    }
}

import SwiftUI

/// 右下の「シーン」タブ：今の状態を保存して、ボタン 1 つで切り替える
struct ScenesPanel: View {
    @EnvironmentObject var engine: Engine
    /// 1 行に並べるシーンの数（大きさ）
    @AppStorage("sceneColumns") private var sceneColumns = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    engine.addScene()
                } label: {
                    Label("今の状態をシーンに保存", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .controlSize(.large)
                .help("再生中のクリップ・レイヤーとコンポジションの設定（不透明度・重ね方・位置・エフェクトなど）を丸ごと保存")
                Button {
                    engine.addEmptyScene()
                } label: {
                    Label("空のシーン", systemImage: "plus")
                }
                .controlSize(.large)
                .help("何も流さない空のシーンを足して、そのまま編集を始める（出力はそのまま）。グリッドでクリップを押して組み立てる")
            }
            HStack(alignment: .center, spacing: 8) {
                Text("絵で切り替え・名前の帯で編集・右クリックでほか")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("絵をクリックで切り替え（フェード時間はシーンごと）。下の名前の帯をクリックで、出力はそのままグリッドで編集。右クリックで上書き・名前・フェード時間・デッキ・削除")
                Spacer(minLength: 0)
                Picker("", selection: $sceneColumns) {
                    Text("大").tag(2)
                    Text("中").tag(3)
                    Text("小").tag(4)
                    Text("最小").tag(6)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("シーンの大きさ（1 行に並べる数）")
            }
            if engine.scenes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("まだシーンがありません。\n良い組み合わせができたら「今の状態をシーンに保存」").multilineTextAlignment(.center)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    let n = min(max(sceneColumns, 2), 6)
                    let gap: CGFloat = n >= 4 ? 5 : 8
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: n), spacing: gap) {
                        ForEach(Array(engine.scenes.enumerated()), id: \.element.id) { i, s in
                            SceneTile(scene: s, number: i + 1, size: n >= 6 ? 2 : (n >= 4 ? 1 : 0),
                                      active: engine.activeSceneID == s.id,
                                      editing: engine.editingSceneID == s.id,
                                      progress: engine.activeSceneID == s.id ? engine.sceneProgress : nil)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

/// シーンのボタン（サムネイル・番号・名前・フェード時間）
struct SceneTile: View {
    @EnvironmentObject var engine: Engine
    let scene: VJScene
    let number: Int
    /// 0 = 大・中、1 = 小、2 = 最小（文字を小さく・省く）
    var size = 0
    let active: Bool
    let editing: Bool
    let progress: Double?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let d = scene.thumbnail, let img = NSImage(data: d) {
                        Image(nsImage: img).resizable().aspectRatio(16.0 / 9.0, contentMode: .fill)
                    } else {
                        Color.black.aspectRatio(16.0 / 9.0, contentMode: .fill)
                    }
                }
                .clipped()
                Text("\(number)")
                    .font(.system(size: size >= 2 ? 9 : 11, weight: .bold).monospacedDigit())
                    .padding(.horizontal, size >= 2 ? 3 : 5).padding(.vertical, 1)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                    .padding(size >= 2 ? 2 : 4)
            }
            .overlay(alignment: .bottom) {
                if let progress {
                    GeometryReader { g in
                        Rectangle().fill(Color.teal).frame(width: g.size.width * progress)
                    }
                    .frame(height: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { engine.recallScene(scene.id) }
            // キューの一覧へドラッグして足せる
            .onDrag { NSItemProvider(object: ("halovj-scene:" + scene.id.uuidString) as NSString) }
            .help("クリックで「\(scene.name)」に切り替え（\(VJScene.fadeLabel(scene.fade))）")
            HStack(spacing: 4) {
                if editing && size < 2 { Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .bold)) }
                Text(scene.name).font(.system(size: size >= 2 ? 10 : (size == 1 ? 11 : 12), weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if size == 0, engine.decks.count > 1, let d = engine.deckIndex(scene.deck) ?? Optional(0) {
                    Text(engine.decks[d].name)
                        .font(.system(size: 9, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                if size < 2 {
                    Text(VJScene.fadeLabel(scene.fade))
                        .font(.system(size: size == 1 ? 9 : 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(editing ? Color.white : scene.fade > 0 ? Color.teal : Color.secondary)
                }
            }
            .padding(.horizontal, size >= 2 ? 3 : 6)
            .frame(height: size >= 2 ? 18 : (size == 1 ? 20 : 24))
            .background(editing ? Color.accentColor.opacity(0.9) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if editing { engine.closeSceneEditor() } else { engine.editScene(scene.id) }
            }
            .help(editing ? "クリックで編集を終える"
                  : "クリックで「\(scene.name)」を編集（出力はそのまま。グリッドでクリップを選び、プレビューで見ながら直せる）")
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.teal.opacity(0.25) : Color.white.opacity(hovering ? 0.10 : 0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.teal : Color.gray.opacity(0.3), lineWidth: active ? 2 : 1))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("編集（出力はそのまま）") { engine.editScene(scene.id) }
            Button("キューに足す") { engine.addCue(.scene(scene.id)) }
            Button("今の状態で上書き") { engine.overwriteScene(scene.id) }
            Button("名前を変える…") { rename() }
            if engine.decks.count > 1 {
                Menu("デッキ") {
                    ForEach(engine.decks) { d in
                        Button(((engine.deckIndex(scene.deck) ?? 0) == engine.deckIndex(d.id) ? "✓ " : "") + d.name) {
                            engine.updateScene(scene.id) { $0.deck = d.id; $0.layerDecks = nil }
                            if engine.editingSceneID == scene.id { engine.reloadSceneDraft() }
                        }
                    }
                }
            }
            Menu("フェード時間") {
                ForEach(VJScene.fadeChoices, id: \.self) { f in
                    Button((scene.fade == f ? "✓ " : "") + VJScene.fadeLabel(f)) { engine.updateScene(scene.id) { $0.fade = f } }
                }
            }
            Divider()
            Button("削除", role: .destructive) { engine.deleteScene(scene.id) }
        }
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "シーンの名前"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = scene.name
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { engine.updateScene(scene.id) { $0.name = name } }
    }
}
