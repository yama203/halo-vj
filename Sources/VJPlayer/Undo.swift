import Foundation
import AppKit
import SwiftUI

// 元に戻す（⌘Z）・やり直す（⌘⇧Z）。
// 変更があって 0.6 秒落ち着いたら、そのときの中身（保存するのと同じもの）を 1 歩として覚える
// （値をドラッグしている間の細かな変化は、まとめて 1 歩になる）。
// 戻すとき、グリッドの形（段・列・デッキ）が同じなら、クリップは作り直さずに設定だけ戻す
// （再生中のクリップは止まらない・動画を読み直さない）。形が変わる操作（段を足す・消すなど）は、全体を作り直して戻す。

final class UndoHistory: ObservableObject {
    @Published fileprivate(set) var canUndo = false
    @Published fileprivate(set) var canRedo = false
    fileprivate var past: [Data] = []
    fileprivate var future: [Data] = []
    fileprivate var committed: Data?
    fileprivate var pending: DispatchWorkItem?
    static let limit = 60
    static let settle = 0.6

    fileprivate func update() {
        canUndo = !past.isEmpty || pending != nil
        canRedo = !future.isEmpty
    }
}

extension Engine {
    private func undoSnapshot() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        // 見ているデッキは戻す歩に数えない（切り替えただけで 1 歩にならないように）
        // BPM も、本番中に動かす値（自動検出でも変わる）なので数えない
        var s = makeState(relativeTo: nil)
        s.currentDeck = nil
        s.bpm = nil
        return try? enc.encode(s)
    }

    /// 今の中身を「戻す先のはじめ」にする（開いた・新しく作ったとき）
    func resetUndo() {
        let h = undoHistory
        h.pending?.cancel(); h.pending = nil
        h.past = []; h.future = []
        h.committed = undoSnapshot()
        h.update()
    }

    /// 変更があった（scheduleSave から）。落ち着いたら 1 歩として覚える
    func noteUndoChange() {
        let h = undoHistory
        h.pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.commitUndoStep() }
        h.pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + UndoHistory.settle, execute: w)
        if !h.canUndo { h.update() }
    }

    /// 待っている変更を、今すぐ 1 歩として覚える
    @discardableResult
    func commitUndoStep() -> Bool {
        let h = undoHistory
        h.pending?.cancel(); h.pending = nil
        guard let now = undoSnapshot() else { h.update(); return false }
        defer { h.update() }
        guard let prev = h.committed else { h.committed = now; return false }
        guard prev != now else { return false }
        // 自動操縦が変えている間の変化は、歩にしない（今の中身を「戻す先のはじめ」にするだけ）
        if CACurrentMediaTime() < undoAbsorbUntil { h.committed = now; return false }
        h.past.append(prev)
        if h.past.count > UndoHistory.limit { h.past.removeFirst(h.past.count - UndoHistory.limit) }
        h.future = []
        h.committed = now
        return true
    }

    func undo() {
        let h = undoHistory
        commitUndoStep()
        guard let prev = h.past.popLast(), let cur = h.committed else { h.update(); return }
        h.future.append(cur)
        h.committed = prev
        restoreForUndo(prev)
        h.update()
    }

    func redo() {
        let h = undoHistory
        if h.pending != nil { commitUndoStep() }
        guard let next = h.future.popLast(), let cur = h.committed else { h.update(); return }
        h.past.append(cur)
        h.committed = next
        restoreForUndo(next)
        h.update()
    }

    private func restoreForUndo(_ data: Data) {
        guard let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        let sameShape = (state.columns ?? Self.defaultColumns) == columns
            && (state.layers?.count ?? Self.defaultLayers) == layers.count
            && (state.decks?.map(\.id) ?? []) == decks.map(\.id)
        if sameShape {
            lightRestore(state)
        } else {
            // 形が変わる：全体を作り直す（戻した中身を、覚えている今の中身として残す）
            let h = undoHistory
            let past = h.past, future = h.future, committed = h.committed
            let deck = currentDeck
            apply(state, baseDir: projectURL?.deletingLastPathComponent())
            currentDeck = min(deck, decks.count - 1)
            h.past = past; h.future = future; h.committed = committed
        }
        scheduleSaveWithoutUndo()
    }

    /// 自動保存はするが、戻す歩には数えない
    private func scheduleSaveWithoutUndo() {
        let h = undoHistory
        let keep = h.committed
        scheduleSave()
        h.pending?.cancel(); h.pending = nil
        h.committed = keep
        h.update()
    }

    /// クリップを作り直さずに、設定だけ戻す（グリッドの形が同じとき）
    private func lightRestore(_ state: SavedState) {
        setRestoring(true)
        defer { setRestoring(false); syncRenderState() }
        masterOpacity = min(max(state.masterOpacity ?? 1, 0), 1)
        masterVolume = min(max(state.masterVolume ?? 1, 0), 1)
        compTransform.reset()
        state.compTransform?.apply(to: compTransform)
        anims = Self.decodeAnims(state.masterAnims)
        effects = state.compEffects ?? []
        compMuted = state.compMuted ?? false
        masterAudioMuted = state.masterAudioMuted ?? false
        scenes = state.scenes ?? []
        restorePads(state.pads)
        cues = state.cues ?? []
        if let c = currentCue, !cues.indices.contains(c) { currentCue = nil }
        bpm = state.bpm ?? bpm
        outputFormat = state.outputFormat ?? OutputFormat()
        corners = state.corners.count == 4 ? state.corners.map { SIMD2($0[0], $0[1]) } : Engine.defaultCorners
        outputMap = state.outputMap ?? OutputMap()
        dmxMap = state.dmxMap ?? DMXMap()
        autopilot = state.autopilot ?? AutoPilot()
        for (layer, saved) in zip(layers, state.layers ?? []) {
            layer.opacity = min(max(saved.opacity, 0), 1)
            layer.blend = BlendMode(rawValue: saved.blend) ?? .normal
            layer.volume = min(max(saved.volume, 0), 1)
            layer.transform.reset()
            saved.transform?.apply(to: layer.transform)
            layer.fadeTime = min(max(saved.fadeTime ?? 0, 0), 10)
            layer.transition = saved.transition.flatMap(Transition.init(rawValue:)) ?? .crossfade
            layer.anims = Self.decodeAnims(saved.anims)
            layer.effects = saved.effects ?? []
            layer.muted = saved.muted ?? false
            layer.audioMuted = saved.audioMuted ?? false
            layer.isAdjustment = saved.isAdjustment ?? false
            layer.blendFX = saved.blendFX ?? Effect(kind: layer.blend.effectKind ?? .overdrive)
            if let k = layer.blend.effectKind, layer.blendFX.kind != k { layer.blendFX = Effect(kind: k) }
            layer.title = saved.title ?? ""
        }
        // クリップ：同じ目印で同じ中身（同じ動画・同じ種類のジェネレーター）なら、そのクリップに設定を戻す
        var byID: [UUID: ClipSlot] = [:]
        for s in slots.compactMap({ $0 }) { byID[s.id] = s }
        let base = projectURL?.deletingLastPathComponent()
        var placed: [Int: ClipSlot?] = [:]
        for i in slots.indices {
            let saved = i < state.slots.count ? state.slots[i] : nil
            guard let saved else { placed[i] = .some(nil); continue }
            if let id = saved.id, let ex = byID[id], Self.sameMedia(ex, saved) {
                applySettings(saved, to: ex)
                ex.speed = saved.speed
                ex.endAction = saved.endAction.flatMap(EndAction.init(rawValue:)) ?? (saved.loop ? .loop : .hold)
                if ex.generator != nil, let g = saved.generator { ex.generator = g }
                if !ex.isEffectClip && ex.generator == nil {
                    ex.setInOut(in: saved.inPoint ?? 0, out: .some(saved.outPoint), notify: false)
                }
                placed[i] = .some(ex)
            } else {
                placed[i] = .some(makeSlot(saved, baseDir: base))
            }
        }
        for (i, s) in placed.sorted(by: { $0.key < $1.key }) {
            let new = s ?? nil
            if slots[i] !== new { setSlot(i, new) }
        }
    }

    private func restorePads(_ p: [SavedPad]?) {
        heldPads = [:]
        releasingPads = [:]
        pads = makePads(p)
    }

    private static func sameMedia(_ s: ClipSlot, _ saved: SavedSlot) -> Bool {
        if (saved.effectClip == true) != s.isEffectClip { return false }
        if s.isEffectClip { return true }
        if let g = saved.generator { return s.generator?.kind == g.kind }
        return s.generator == nil && s.url.path == saved.path
    }
}

/// 編集メニューの「元に戻す」「やり直す」
struct UndoMenuItems: View {
    @ObservedObject var history: UndoHistory
    var body: some View {
        // 文字を打っている間は、その欄の「元に戻す」
        Button(L("元に戻す")) {
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.undoManager?.canUndo == true { tv.undoManager?.undo() }
            else { Engine.shared.undo() }
        }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!history.canUndo)
        Button(L("やり直す")) {
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.undoManager?.canRedo == true { tv.undoManager?.redo() }
            else { Engine.shared.redo() }
        }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!history.canRedo)
    }
}
