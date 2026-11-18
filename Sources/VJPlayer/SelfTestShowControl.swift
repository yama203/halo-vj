import AppKit
import Foundation

/// 進行を自動で進める（0 で次へ・自動送り・時刻・リハーサルの時計）・FX パッドのラッチ・予備機との同期の確かめ。
/// 見回りは showTick に時刻を渡して呼ぶ（タイマーは回さない）
extension SelfTest {
    static func testShowControl(paths: [String], check: (Bool, String) -> Void, wait: (Double) -> Void) {
        func engine() -> Engine {
            let e = Engine(persistent: false)
            e.showTimerEnabled = false
            return e
        }
        /// その段・列にクリップを置いて、それを出すキュー（ほかのレイヤーはそのまま）
        func place(_ e: Engine, _ layer: Int, _ col: Int, _ slot: ClipSlot) -> Cue {
            let i = e.slotIndex(deck: 0, layer: layer, column: col)
            e.setSlot(i, slot)
            var c = Cue(kind: .clip(deck: e.decks[0].id, layer: layer, column: col), clipID: slot.id)
            c.keepOthers = true
            return c
        }
        /// タイマーの時計（10 秒、0 になったら次へ）
        func timerClock(_ sec: Double = 10, advance: Bool = true) -> Effect {
            var g = Effect(kind: .clock)
            g.values[12] = 2; g.values[18] = 0; g.values[19] = sec; g.values[21] = advance ? 1 : 0
            return g
        }
        let solid = { ClipSlot(generator: Effect(kind: .solid)) }

        // 1. 0 になったら次のキューへ
        do {
            let e = engine()
            let clock = ClipSlot(generator: timerClock())
            e.cues = [place(e, 1, 0, clock), place(e, 0, 1, solid()), Cue(kind: .stopAll)]
            e.fireCue(0)
            let o = clock.animOrigin
            check(e.needsShowTimer, "0 で次へ：出力で出している「次のキューへ」の時計があると、見回りが要る")
            e.showTick(now: Date(), host: o + 5)
            let before = e.currentCue
            e.showTick(now: Date(), host: o + 10.05)
            let after = e.currentCue
            e.showTick(now: Date(), host: o + 10.2)
            e.showTick(now: Date(), host: o + 12)
            check(before == 0 && after == 1 && e.currentCue == 1,
                  "0 で次へ：残りが正 → 0 以下になった 1 回だけ進む（\(String(describing: before)) → \(String(describing: after)) → \(String(describing: e.currentCue))）")
            e.stopAll()
        }
        do {
            let e = engine()
            let clock = ClipSlot(generator: timerClock())
            e.cues = [place(e, 1, 0, clock), place(e, 0, 1, solid())]
            e.fireCue(0)
            let o = clock.animOrigin
            e.showTick(now: Date(), host: o + 20)
            e.showTick(now: Date(), host: o + 21)
            check(e.currentCue == 0, "0 で次へ：見始めたときに既に 0 以下なら進まない")
            e.stopAll()
        }
        do {
            let e = engine()
            let clock = ClipSlot(generator: timerClock())
            e.cues = [place(e, 0, 1, solid()), place(e, 1, 0, clock), Cue(kind: .stopAll)]
            e.fireCue(0)
            // 時計は置いただけ（出力に出していない）。時刻は時計の都合のよい所を渡す
            let o = CACurrentMediaTime()
            e.showTick(now: Date(), host: o + 5)
            e.showTick(now: Date(), host: o + 10.05)
            check(e.currentCue == 0 && !e.needsShowTimer, "0 で次へ：出力で出していない時計では進まない（見回りも要らない）")
            let off = ClipSlot(generator: timerClock(advance: false))
            e.setSlot(e.slotIndex(deck: 0, layer: 2, column: 0), off)
            e.trigger(e.slotIndex(deck: 0, layer: 2, column: 0))
            e.showTick(now: Date(), host: off.animOrigin + 5)
            e.showTick(now: Date(), host: off.animOrigin + 10.05)
            check(e.currentCue == 0, "0 で次へ：「何もしない」の時計では進まない")
            e.stopAll()
        }
        do {
            let e = engine()
            let a = ClipSlot(generator: timerClock()), b = ClipSlot(generator: timerClock())
            e.cues = [place(e, 0, 1, solid()), place(e, 0, 2, solid()), Cue(kind: .stopAll)]
            e.fireCue(0)
            e.setSlot(e.slotIndex(deck: 0, layer: 1, column: 0), a)
            e.setSlot(e.slotIndex(deck: 0, layer: 2, column: 0), b)
            e.trigger(e.slotIndex(deck: 0, layer: 1, column: 0))
            e.trigger(e.slotIndex(deck: 0, layer: 2, column: 0))
            let o = max(a.animOrigin, b.animOrigin)
            e.showTick(now: Date(), host: o + 5)
            e.showTick(now: Date(), host: o + 10.05)
            e.showTick(now: Date(), host: o + 10.2)
            check(e.currentCue == 1, "0 で次へ：2 つの時計が同時に 0 になっても、進むのは 1 回（\(String(describing: e.currentCue))）")
            e.stopAll()
        }

        // 2. キューの自動送り
        do {
            let e = engine()
            var c0 = place(e, 0, 0, solid()); c0.follow = Cue.Follow(after: 3)
            e.cues = [c0, place(e, 0, 1, solid()), Cue(kind: .stopAll)]
            e.fireCue(0)
            let h = CACurrentMediaTime()
            let pending = e.cueFollow?.cueID == c0.id && e.needsShowTimer
            e.showTick(now: Date(), host: h + 1)
            let early = e.currentCue
            e.showTick(now: Date(), host: h + 3.1)
            check(pending && early == 0 && e.currentCue == 1 && e.cueFollow == nil && e.lastGoHost > 0,
                  "自動送り：3 秒後に次へ進む（予約は出したキューが持ち、進んだら消える）")

            // 人が先に「次へ」を押したら、前の予約は消える
            e.fireCue(0)
            e.lastGoHost = 0
            e.goCue()
            e.showTick(now: Date(), host: CACurrentMediaTime() + 10)
            check(e.currentCue == 1 && e.cueFollow == nil, "自動送り：人が先に「次へ」を押したら、前のキューの予約は消える")

            // 戻ったら、戻る前のキューの予約は消える（戻った先のキューの予約だけが生きる）
            e.updateCue(e.cues[1].id) { $0.follow = Cue.Follow(after: 5) }
            e.fireCue(1)
            let had = e.cueFollow?.cueID == e.cues[1].id
            e.backCue()
            check(had && e.cueFollow?.cueID == e.cues[0].id, "自動送り：戻ったら、戻る前のキューの予約は消える")
            // キューを消したら、その予約も消える
            e.removeCue(e.cues[0].id)
            check(e.cueFollow == nil, "自動送り：予約を持つキューを消したら、予約も消える")
            // 最後のキューの自動送りは何もしない
            e.cues = [c0]
            e.fireCue(0)
            e.showTick(now: Date(), host: CACurrentMediaTime() + 4)
            check(e.currentCue == 0 && e.cueFollow == nil, "自動送り：次が無ければ何もせず、予約を捨てる")
            e.stopAll()
        }
        do {
            // クリップの終わりで次へ（テスト用の動画。アウト点を 0.6 秒に）
            let e = engine()
            let v = ClipSlot(url: URL(fileURLWithPath: paths[0]), endAction: .loop)
            let t0 = CACurrentMediaTime()
            while !v.isReady && CACurrentMediaTime() - t0 < 10 { wait(0.05) }
            v.setInOut(out: .some(0.6))
            var c0 = place(e, 0, 0, v); c0.follow = Cue.Follow(after: nil)
            let gen = place(e, 0, 1, solid())
            e.cues = [c0, gen, Cue(kind: .stopAll)]
            let canVideo = e.cueCanFollowEnd(c0), canGen = e.cueCanFollowEnd(gen)
            e.fireCue(0)
            let start = CACurrentMediaTime()
            var at: Double?
            while CACurrentMediaTime() - start < 3 {
                wait(0.02)
                e.showTick(now: Date(), host: CACurrentMediaTime())
                if e.currentCue == 1 { at = CACurrentMediaTime() - start; break }
            }
            check(v.isReady && canVideo && !canGen && at != nil && at! > 0.45 && at! < 1.2,
                  "自動送り：クリップがアウト点に着いたら次へ（ループのクリップでも 1 回目で。\(at.map { String(format: "%.2f 秒", $0) } ?? "進まない")）。ジェネレーターでは選べない")
            e.stopAll()
        }

        // 3. 時刻で発火
        do {
            let cal = Calendar.current
            let d0 = cal.date(bySettingHour: 18, minute: 59, second: 58, of: Date())!
            func timed() -> Engine {
                let e = engine()
                var c1 = place(e, 0, 1, solid()); c1.at = TimeOfDay(h: 19, m: 0, s: 0)
                e.cues = [place(e, 0, 0, solid()), c1, Cue(kind: .stopAll)]
                return e
            }
            let e = timed()
            e.showTick(now: d0, host: 0)
            e.showTick(now: d0.addingTimeInterval(1), host: 1)
            let early = e.currentCue
            e.showTick(now: d0.addingTimeInterval(2.05), host: 2)
            let fired = e.currentCue
            e.showTick(now: d0.addingTimeInterval(2.2), host: 2.2)
            check(early == nil && fired == 1 && e.currentCue == 1 && e.needsShowTimer,
                  "時刻：19:00:00 をまたいだら、その番号のキューが出る（順番に関係なく。1 回だけ）")
            e.stopAll()

            let e2 = timed()
            e2.showTick(now: d0.addingTimeInterval(5), host: 0)
            e2.showTick(now: d0.addingTimeInterval(6), host: 1)
            check(e2.currentCue == nil, "時刻：見始めたときに既に過ぎている時刻は出さない")

            let e3 = timed()
            e3.showTick(now: d0, host: 0)
            e3.showTick(now: d0.addingTimeInterval(7), host: 7)
            check(e3.currentCue == nil, "時刻：見回りの間が 5 秒より空いたら（スリープから戻ったなど）、またいでも出さない")

            let e4 = timed()
            e4.showTick(now: d0, host: 0)
            e4.setShowClockOffset(30)
            e4.showTick(now: d0.addingTimeInterval(3), host: 3)
            e4.setShowClockOffset(0)
            check(e4.currentCue == nil && ShowClock.offset == 0, "時刻：時計のずらしを変えた瞬間は、またいでも出さない")

            let e5 = engine()
            var m = place(e5, 0, 0, solid()); m.at = TimeOfDay(h: 0, m: 0, s: 0)
            e5.cues = [place(e5, 0, 1, solid()), m]
            let late = cal.date(bySettingHour: 23, minute: 59, second: 59, of: Date())!
            e5.showTick(now: late, host: 0)
            e5.showTick(now: late.addingTimeInterval(2), host: 2)
            check(e5.currentCue == 1 && TimeOfDay.crossed(2, from: 86399, to: 5) && !TimeOfDay.crossed(10, from: 86399, to: 5) && !TimeOfDay.crossed(10, from: 11, to: 20),
                  "時刻：0 時をまたぐ時刻（0:00:00）も出る")
            e5.stopAll()

            // リハーサル：今を決めた時刻にする → ShowClock.now がその時刻
            let e6 = engine()
            e6.setShowClock(to: TimeOfDay(h: 23, m: 59, s: 30))
            let shown = TimeOfDay(ShowClock.now)
            let wall = ShowClock.secondsOfDay(ShowClock.wall(atHost: CACurrentMediaTime()))
            e6.setShowClockOffset(0)
            check(shown == TimeOfDay(h: 23, m: 59, s: 30) || shown == TimeOfDay(h: 23, m: 59, s: 31),
                  "リハーサル：「今を 23:59:30 にする」で、進行の時計がその時刻になる（\(shown.label)）")
            check(abs(wall - (23 * 3600 + 59 * 60 + 30)) < 2 && ShowClock.offset == 0 && e6.showClockOffset == 0,
                  "リハーサル：時計のジェネレーターの時刻もずれる。戻すと本当の時刻")
            check(ShowClock.offsetText(3 * 3600 + 12 * 60 + 5) == "+3:12:05" && ShowClock.countdown(2.2) == "0:03"
                  && ShowClock.countdown(750) == "12:30", "リハーサル：帯の「+3:12:05」・残りの「0:03」「12:30」")
        }

        // 4. 「自動で進める」を切ると、どれも起きない
        do {
            let e = engine()
            let clock = ClipSlot(generator: timerClock())
            var c0 = place(e, 1, 0, clock); c0.follow = Cue.Follow(after: 1)
            var c2 = place(e, 0, 2, solid()); c2.at = TimeOfDay(h: 19, m: 0, s: 0)
            e.cues = [c0, place(e, 0, 1, solid()), c2, Cue(kind: .stopAll)]
            e.cueAutoEnabled = false
            e.fireCue(0)
            let o = clock.animOrigin
            let d0 = Calendar.current.date(bySettingHour: 18, minute: 59, second: 55, of: Date())!
            e.showTick(now: d0, host: o + 5)
            e.showTick(now: d0.addingTimeInterval(5.05), host: o + 10.05)
            let stayed = e.currentCue == 0 && e.cueFollow == nil && !e.needsShowTimer
            // 入れ直しても、止めていた間に過ぎたものは出ない
            e.cueAutoEnabled = true
            e.showTick(now: d0.addingTimeInterval(5.2), host: o + 10.2)
            check(stayed && e.currentCue == 0, "「自動で進める」を切ると、自動送り・時刻・0 での発火のどれも起きない（入れ直しても過ぎたものは出ない）")
            e.stopAll()
        }

        // 5. FX パッドのラッチ
        do {
            let e = engine()
            let p = e.pads[0], q = e.pads[1]
            p.effects = [Effect(kind: .invert)]; q.effects = [Effect(kind: .invert)]
            e.setPadLatch(p.id, true)
            e.padDown(p.id)
            let on1 = e.isPadHeld(p.id)
            e.padUp(p.id)
            let on2 = e.isPadHeld(p.id) && e.heldPadStacks().count == 1
            e.releaseAllPads()
            let on3 = e.isPadHeld(p.id)
            e.isBlackout = true; e.stopAll(); e.isBlackout = false
            let on4 = e.isPadHeld(p.id)
            e.padDown(p.id)
            let off = !e.isPadHeld(p.id)
            e.padUp(p.id)
            check(on1 && on2 && on3 && on4 && off && !e.isPadHeld(p.id),
                  "ラッチ：押す → 入る、離す・アプリから離れる・ブラックアウト・全停止 → 入ったまま、もう一度押す → 切れる")
            e.padDown(q.id)
            let qOn = e.isPadHeld(q.id)
            e.padUp(q.id)
            check(qOn && !e.isPadHeld(q.id), "ラッチ：ふつうのパッドは今までどおり（押している間だけ）")

            // OSC：1 で入切、0 は無視。/latch 0/1 で直接
            func osc(_ a: String, _ v: Float) { OSCCommands.run(OSCMessage(address: a, args: [.float(v)]), engine: e) }
            osc("/halo/pad/1", 1); let o1 = e.isPadHeld(p.id)
            osc("/halo/pad/1", 0); let o2 = e.isPadHeld(p.id)
            osc("/halo/pad/1", 1); let o3 = e.isPadHeld(p.id)
            osc("/halo/pad/1/latch", 1); let o4 = e.isPadHeld(p.id)
            osc("/halo/pad/1/latch", 0); let o5 = e.isPadHeld(p.id)
            check(o1 && o2 && !o3 && o4 && !o5, "ラッチ：OSC の /halo/pad/N 1 で入切（0 は無視）。/halo/pad/N/latch 1・0 で入れる・切る")

            // 元に戻すでも切れない・全部のラッチを切る・ラッチを外すと切れる
            e.padDown(p.id)
            e.commitUndoStep()
            e.masterOpacity = 0.5
            e.commitUndoStep()
            e.undo()
            let afterUndo = e.pads[0].latch && e.isPadHeld(e.pads[0].id)
            e.releaseAllLatches()
            let cleared = !e.isPadHeld(e.pads[0].id)
            e.padDown(e.pads[0].id)
            e.setPadLatch(e.pads[0].id, false)
            check(afterUndo && cleared && !e.isPadHeld(e.pads[0].id),
                  "ラッチ：元に戻すでは切れない。「全部のラッチを切る」・ラッチを外すと切れる")
            e.setPadLatch(e.pads[0].id, true)

            // 保存して読み直しても残る
            let data = try? JSONEncoder().encode(e.savedPads)
            let back = data.flatMap { try? JSONDecoder().decode([Engine.SavedPad].self, from: $0) }
            let made = e.makePads(back)
            check(made[0].latch && !made[1].latch, "ラッチ：保存して読み直しても残る（ほかのパッドはそのまま）")
        }

        // 6. 予備機との同期
        do {
            let e = engine()
            e.cues = [place(e, 0, 0, solid()), place(e, 0, 1, solid()), place(e, 0, 2, solid())]
            func cur(_ n: Float) { OSCCommands.run(OSCMessage(address: "/halo/cue/current", args: [.int(Int32(n))]), engine: e) }
            cur(2)
            let ignored = e.currentCue == nil
            var sent: [Int] = []
            e.onCueFired = { sent.append($0) }
            e.cueFollower = true
            cur(3)
            let fired = e.currentCue == 2 && e.activeByLayer[0] == e.slotIndex(deck: 0, layer: 0, column: 2)
            e.stopAll()
            cur(3)
            check(ignored && fired && e.activeByLayer[0] == nil && sent.isEmpty,
                  "予備機：/halo/cue/current 3 で 3 番目が出る・同じ番号は出し直さない・追っていなければ無視・追う側は送らない")
            // 追う側は自動の発火をしない
            e.updateCue(e.cues[0].id) { $0.at = TimeOfDay(h: 19, m: 0, s: 0) }
            let d0 = Calendar.current.date(bySettingHour: 18, minute: 59, second: 59, of: Date())!
            e.showTick(now: d0, host: 0)
            e.showTick(now: d0.addingTimeInterval(2), host: 2)
            check(e.currentCue == 2 && !e.needsShowTimer, "予備機：追う側は時刻・自動送り・0 での発火をしない")

            // 本番機（追わない側）は、出したキューとブラックアウトを知らせる
            let m = engine()
            m.cues = e.cues
            var cues: [Int] = [], bo: [Bool] = []
            m.onCueFired = { cues.append($0) }
            m.onBlackoutChanged = { bo.append($0) }
            m.fireCue(1)
            m.isBlackout = true
            m.isBlackout = false
            e.onBlackoutChanged = { _ in bo.append(true) }
            e.isBlackout = true
            check(cues == [1] && bo == [true, false], "予備機：本番機はキューを出すたびに番号を、ブラックアウトの入切を知らせる（追う側は知らせない）")
            e.isBlackout = false
            m.stopAll()
        }

        // 7. 古い保存（follow・at・latch・0 になったら が無い）が読める
        do {
            let old = #"{"kind":{"stopAll":{}},"id":"\#(UUID().uuidString)","note":"x"}"#
            let c = try? JSONDecoder().decode(Cue.self, from: Data(old.utf8))
            let pad = try? JSONDecoder().decode(Engine.SavedPad.self, from: Data(#"{"name":"a","key":"1"}"#.utf8))
            var clock = Effect(kind: .clock)
            clock.values = Array(clock.values.prefix(21))
            let ce = (try? JSONEncoder().encode(clock)).flatMap { try? JSONDecoder().decode(Effect.self, from: $0) }
            check(c != nil && c?.follow == nil && c?.at == nil && pad != nil && pad?.latch == nil
                  && ce?.values.count == 22 && ce.map(ClockText.advancesCue) == false,
                  "古い保存：自動送り・時刻・ラッチ・「0 になったら」の無いキュー・パッド・時計が読める")
            var n = Cue(kind: .stopAll)
            n.follow = Cue.Follow(after: 3); n.at = TimeOfDay(h: 19, m: 0, s: 5)
            let back = (try? JSONEncoder().encode(n)).flatMap { try? JSONDecoder().decode(Cue.self, from: $0) }
            check(back == n, "新しい保存：自動送り・時刻が保存して読み直せる")
        }
    }
}
