import AVFoundation
import Foundation
import QuartzCore

/// コードレビューで直した所の確かめ（OSC・MIDI・音の形・レイヤーの増減・保存の読み方・元に戻す など）
extension SelfTest {
    static func testReviewFixes(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        // A1. OSC の NaN・無限大は数として扱わない（値に入らない）
        let hub = OSCHub.shared
        hub.forTests = true
        let nanMsg = OSCMessage.decode(OSCMessage(address: "/review/nan", args: [.float(.nan)]).encode())
        let infMsg = OSCMessage(address: "/review/inf", args: [.float(.infinity)])
        let strMsg = OSCMessage(address: "/review/str", args: [.string("nan")])
        for m in nanMsg + [infMsg, strMsg] { hub.handle(m, runCommands: false) }
        hub.handle(OSCMessage(address: "/review/ok", args: [.float(0.25)]), runCommands: false)
        check(nanMsg.first?.number == nil && hub.value("/review/nan") == nil && hub.value("/review/inf") == nil
              && hub.value("/review/str") == nil && hub.value("/review/ok") == 0.25,
              "OSC：NaN・無限大が届いても値に入らない（ふつうの数は入る）")

        // A2. MIDI のノートは弱く叩いても「押した」。離した（0）は離した。CC は 64 で分ける
        check(ControlHub.pressValue(.note, 10.0 / 127) == 1 && ControlHub.pressValue(.note, 0) == 0
              && ControlHub.pressValue(.cc, 63.0 / 127) == 0 && ControlHub.pressValue(.cc, 64.0 / 127) == 1,
              "MIDI：ノートは弱く叩いても押した扱い（ベロシティ 10 → 1）")

        // A9. バンドルの入れ子は 8 段まで（それより深いものは読まない）
        func bundle(_ inner: Data) -> Data {
            var d = Data("#bundle".utf8); d.append(0)
            d.append(contentsOf: [UInt8](repeating: 0, count: 8))
            withUnsafeBytes(of: UInt32(inner.count).bigEndian) { d.append(contentsOf: $0) }
            d.append(inner)
            return d
        }
        func nested(_ n: Int) -> Data {
            var d = OSCMessage(address: "/review/deep", args: [.float(1)]).encode()
            for _ in 0..<n { d = bundle(d) }
            return d
        }
        check(OSCMessage.decode(nested(3)).count == 1 && OSCMessage.decode(nested(OSCMessage.maxBundleDepth)).count == 1
              && OSCMessage.decode(nested(OSCMessage.maxBundleDepth + 1)).isEmpty && OSCMessage.decode(nested(2000)).isEmpty,
              "OSC：バンドルの入れ子は 8 段まで読む（深すぎるものは捨てる。2000 段でも落ちない）")

        // A8. 音の形：輪より大きいかたまりが来ても落ちない
        if let fmt = AVAudioFormat(standardFormatWithSampleRate: 192_000, channels: 1),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 20000) {
            buf.frameLength = 20000
            for i in 0..<20000 { buf.floatChannelData![0][i] = Float(sin(Double(i) / 30)) * 0.3 }
            AudioReactive.shared.feed(buf, time: CACurrentMediaTime())
            let s = AudioReactive.shared.scopeSamples(count: 512)
            check(s?.samples.count == 512 && AudioReactive.shared.scopeLastCount <= AudioReactive.shared.scopeRing.count,
                  "音の形：輪（16384）より大きい音のかたまりでも落ちない")
        }

        // B1. プレビューしている段を消しても、プレビューの絵を取りに来て落ちない
        do {
            let e = Engine(persistent: false)
            let last = e.layers.count - 1
            let i = e.slotIndex(deck: 0, layer: last, column: 0)
            _ = e.placeGenerator(.solid, at: i)
            e.trigger(i)
            e.inspectedIndex = i
            e.syncRenderState()
            wait(0.05)
            e.removeLayer(last)
            let d = e.previewDraws()
            check(e.layers.count == last && d.isEmpty, "レイヤー：プレビューしている段を消しても落ちない（プレビューは空に）")
            e.stopAll()
        }

        // C1(a). 知らない種類のエフェクトが 1 つ混ざっていても、その 1 つだけ落として読む
        do {
            let layer = Engine.SavedLayer(opacity: 1, blend: 0, volume: 1,
                                          effects: [Effect(kind: .invert), Effect(kind: .mirror), Effect(kind: .posterize)])
            var ok = false
            if let data = try? JSONEncoder().encode(layer),
               var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               var fx = obj["effects"] as? [[String: Any]] {
                fx[1]["kind"] = "kindFromTheFuture"
                obj["effects"] = fx
                if let d2 = try? JSONSerialization.data(withJSONObject: obj),
                   let back = try? JSONDecoder().decode(Engine.SavedLayer.self, from: d2) {
                    ok = back.effects?.map(\.kind) == [.invert, .posterize]
                }
            }
            check(ok, "保存：知らない種類のエフェクトが混ざっていても、その 1 つだけ飛ばして読める")
        }

        // C1(b). 読めない保存ファイルは、上書きで失わないように移してから空で始める
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("vjplayer-broken-state-test", isDirectory: true)
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("state.json")
            try? Data("{ これは壊れた JSON".utf8).write(to: url)
            let (st, moved) = Engine.loadSavedState(at: url)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let movedData = moved.flatMap { try? Data(contentsOf: $0) }
            check(st == nil && !fm.fileExists(atPath: url.path) && names.count == 1 && names[0].hasPrefix("state.broken-")
                  && movedData == Data("{ これは壊れた JSON".utf8),
                  "保存：読めない state.json は state.broken-日時.json へ移して、空で始める（\(names)）")
            let (none, moved2) = Engine.loadSavedState(at: dir.appendingPathComponent("none.json"))
            check(none == nil && moved2 == nil, "保存：ファイルが無いときは何も移さない")
            try? fm.removeItem(at: dir)
        }

        // C2. 動画を付け直しても、クリップの目印は変わらない（複製は新しい目印）
        do {
            let e = Engine(persistent: false)
            e.load(urls: [URL(fileURLWithPath: paths[0])], startingAt: 0)
            let id = e.slots[0]?.id
            e.relinkSlot(0, to: URL(fileURLWithPath: paths[1]))
            e.duplicateSlot(0, to: 1)
            check(id != nil && e.slots[0]?.id == id && e.slots[0]?.url.lastPathComponent == URL(fileURLWithPath: paths[1]).lastPathComponent && e.slots[1]?.id != id,
                  "クリップの付け直し：目印はそのまま（シーン・キューが見失わない）。複製は別の目印（\(id.map { "\($0)" } ?? "nil") → \(e.slots[0]?.id.uuidString ?? "nil")・\(e.slots[0]?.url.path ?? "")）")
        }

        // C3. 段の数が変わる操作を戻しても、ブラックアウト・BPM・コンポジション速度はそのまま
        do {
            let e = Engine(persistent: false)
            e.commitUndoStep()
            e.insertLayer(at: 0)
            e.commitUndoStep()
            e.isBlackout = true
            e.bpm = 133
            e.masterSpeed = 1.5
            let n = e.layers.count
            e.undo()
            check(e.layers.count == n - 1 && e.isBlackout && abs(e.bpm - 133) < 1e-9 && abs(e.masterSpeed - 1.5) < 1e-9,
                  "元に戻す：段を足したのを戻しても、ブラックアウト・BPM・速度は変わらない")
            e.isBlackout = false
            e.masterSpeed = 1
        }

        // C4. シーンのフェード中にレイヤーを消しても落ちない
        do {
            let e = Engine(persistent: false)
            for r in e.layers.indices { _ = e.placeGenerator(.solid, at: e.slotIndex(deck: 0, layer: r, column: 0)); e.trigger(e.slotIndex(deck: 0, layer: r, column: 0)) }
            let sc = e.addScene()
            e.stopAll()
            e.recallScene(sc.id, fade: 1)
            wait(0.1)
            e.removeLayer(e.layers.count - 1)
            wait(0.2)
            check(e.sceneTween == nil && e.sceneProgress == nil, "シーン：フェード中にレイヤーを消すと、フェードを止める（落ちない）")
            e.stopAll()
        }

        // C5. 自動操縦のレイヤーのルールも、段の増減についてくる（消えた段のルールはオフ）
        do {
            let e = Engine(persistent: false)
            e.autopilot = AutoPilot(rules: [AutoRule(target: .layer(1)), AutoRule(target: .layer(0))])
            e.insertLayer(at: 0)
            let shifted = e.autopilot.rules.map(\.target) == [.layer(2), .layer(1)]
            e.removeLayer(1)
            let r = e.autopilot.rules
            check(shifted && r[0].target == .layer(1) && r[0].on && !r[1].on,
                  "自動操縦：段を足す・消すと、レイヤーのルールもついてくる（消えた段のルールはオフ）")
        }

        // C6. シーンの編集中に戻すと、編集中のシーンも読み直す
        do {
            let e = Engine(persistent: false)
            let sc = e.addScene()
            e.commitUndoStep()
            e.editScene(sc.id)
            let d0 = e.sceneDraft
            e.layers[0].opacity = 0.3
            e.commitUndoStep()
            e.undo()
            check(d0 != nil && e.sceneDraft != nil && e.sceneDraft !== d0, "元に戻す：シーンの編集中なら、編集中のシーンを読み直す")
            e.closeSceneEditor()
        }

        // C7. 素材をまとめるとき、前からある同じ名前の別のファイルは消さずに番号を進める
        do {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("vjplayer-collect-review", isDirectory: true)
            try? fm.removeItem(at: tmp)
            let media = tmp.appendingPathComponent("まとめ/素材", isDirectory: true)
            try? fm.createDirectory(at: media, withIntermediateDirectories: true)
            let src = URL(fileURLWithPath: paths[0])
            let theirs = media.appendingPathComponent(src.lastPathComponent)
            try? Data("利用者の別のファイル".utf8).write(to: theirs)
            let e = Engine(persistent: false)
            e.load(urls: [src], startingAt: 0)
            let r = try? Engine.collect(e.collectPlan(into: tmp, name: "まとめ"))
            let kept = (try? Data(contentsOf: theirs)) == Data("利用者の別のファイル".utf8)
            let second = media.appendingPathComponent(src.deletingPathExtension().lastPathComponent + " 2." + src.pathExtension)
            check(r?.copied == 1 && kept && fm.fileExists(atPath: second.path),
                  "素材をまとめて保存：前からある同じ名前の別のファイルは消さず、「名前 2」でコピーする")
            try? fm.removeItem(at: tmp)
        }

        // C8. ⇧クリックの選択は、クリップを動かすとついていき、消すと外れる
        do {
            let e = Engine(persistent: false)
            _ = e.placeGenerator(.solid, at: 0)
            _ = e.placeGenerator(.noise, at: 1)
            e.toggleMultiSelect(0)
            e.toggleMultiSelect(1)
            e.moveSlot(0, to: 2)
            let moved = e.multiSelection == [1, 2]
            e.clear(1)
            check(moved && e.multiSelection == [2], "複数選択：クリップを動かすと選択もついていき、消したクリップは選択から外れる")
        }
    }
}
