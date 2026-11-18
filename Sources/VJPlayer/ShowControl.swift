import AppKit
import SwiftUI

// 進行を自動で進める：カウントダウンが 0 になったら次へ・キューの自動送り・時刻で発火・リハーサル用の時計ずらし・予備機との同期。
// 判定はメインスレッドの 1 本のタイマー（0.1 秒ごと）で行う。予約が 1 つも無いときはタイマーを止める。
// 見回りの中身は showTick(now:host:) にまとめて、テストからは時刻を渡して呼ぶ。

/// 進行で使う「今」。リハーサルのときだけ、本当の時刻からずらせる
enum ShowClock {
    private static let lock = NSLock()
    private static var _offset: TimeInterval = 0
    /// ずらし（秒）。保存しない。0 = 本当の時刻。描画スレッドからも読むのでロックの中で
    static var offset: TimeInterval {
        get { lock.withLock { _offset } }
        set { lock.withLock { _offset = newValue } }
    }
    static var now: Date { Date().addingTimeInterval(offset) }
    /// host 時刻（CACurrentMediaTime の秒）の時点の「今」（時計のジェネレーターが描くとき）
    static func wall(atHost t: Double) -> Date { Date(timeIntervalSinceNow: t - CACurrentMediaTime() + offset) }

    /// その日の 0 時からの秒
    static func secondsOfDay(_ d: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
        return Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)) + Double(c.nanosecond ?? 0) / 1e9
    }

    /// 残りの表示（「0:03」「12:30」「1:02:03」）。秒は切り上げ
    static func countdown(_ s: Double) -> String {
        let t = max(Int(ceil(s - 1e-9)), 0)
        let h = t / 3600, m = (t / 60) % 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// ずらしの表示（「+3:12:05」「-0:00:30」）
    static func offsetText(_ o: TimeInterval) -> String {
        let t = Int(abs(o).rounded())
        return (o < 0 ? "-" : "+") + String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}

/// その日の 時:分:秒（日付は持たない。毎日その時刻）
struct TimeOfDay: Codable, Equatable {
    var h: Int
    var m: Int
    var s: Int

    /// 0 時からの秒（範囲の外の値は丸める）
    var seconds: Double { Double(min(max(h, 0), 23) * 3600 + min(max(m, 0), 59) * 60 + min(max(s, 0), 59)) }
    /// 「19:00:00」
    var label: String { String(format: "%02d:%02d:%02d", min(max(h, 0), 23), min(max(m, 0), 59), min(max(s, 0), 59)) }
    /// 札の短い形（秒が 0 なら「19:00」）
    var shortLabel: String { s == 0 ? String(format: "%02d:%02d", min(max(h, 0), 23), min(max(m, 0), 59)) : label }

    init(h: Int, m: Int, s: Int) { self.h = h; self.m = m; self.s = s }
    init(_ d: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
        self.init(h: c.hour ?? 0, m: c.minute ?? 0, s: c.second ?? 0)
    }

    /// 前の見回り（a 秒）から今（b 秒）の間に、t 秒をまたいだか（0 時をまたいだときも）
    static func crossed(_ t: Double, from a: Double, to b: Double) -> Bool {
        if b >= a { return a < t && t <= b }
        return t > a || t <= b
    }

    /// 今（now）からその時刻までの秒（今日の時刻が過ぎていれば明日の時刻まで）
    func until(_ now: Date) -> Double {
        var d = seconds - ShowClock.secondsOfDay(now)
        if d < 0 { d += 86400 }
        return d
    }
}

/// 自動送りの予約（出したキューに自動送りがあるとき）
struct CueFollowPending: Equatable {
    /// 予約を持っているキュー
    var cueID: UUID
    /// ○秒後に次へ：その時刻（CACurrentMediaTime の秒）。nil = クリップが終わったら
    var fireAt: Double?
    /// 終わったら次へ：見ているクリップと、出したときのアウト点に着いた回数
    var clipID: UUID?
    var endCount: Int
}

extension Engine {
    /// 見回りの間隔（秒）
    static let showTickInterval = 0.1
    /// 見回りの間がこれより空いたら（スリープから戻った・時計を大きく動かした）、時刻のキューは出さない
    static let showMaxGap = 5.0

    /// 見回りが要るか：自動送りの予約・時刻のキュー・出力で出している「0 になったら次へ」の時計のどれかがある
    var needsShowTimer: Bool {
        guard cueAutoEnabled, !cueFollower else { return false }
        if cueFollow != nil { return true }
        if cues.contains(where: { $0.at != nil }) { return true }
        return activeByLayer.contains { a in
            guard let a, slots.indices.contains(a), let g = slots[a]?.generator else { return false }
            return ClockText.advancesCue(g)
        }
    }

    /// 見回りのタイマーを、要るときだけ回す（止めるときは、前の見回りの記憶も捨てる）
    func updateShowTimer() {
        if needsShowTimer {
            guard showTimer == nil, showTimerEnabled else { return }
            let t = Timer(timeInterval: Self.showTickInterval, repeats: true) { [weak self] _ in
                self?.showTick(now: ShowClock.now, host: CACurrentMediaTime())
            }
            RunLoop.main.add(t, forMode: .common)
            showTimer = t
        } else {
            showTimer?.invalidate()
            showTimer = nil
            // 止めている間に 0 をまたいだ・時刻を過ぎたものを、次に回したときに出さないように
            if !clockRemaining.isEmpty { clockRemaining = [:] }
            showLastTick = nil
        }
    }

    /// 「自動で進める」を入切した
    func cueAutoChanged() {
        // 切ったら、持っている予約も捨てる（入れ直したときに、過ぎた予約がいきなり出ないように）
        if !cueAutoEnabled { cueFollow = nil }
        updateShowTimer()
    }

    /// キューの並びが変わった：予約のキューが無くなっていれば消す
    func cuesChangedForShow() {
        if let f = cueFollow, !cues.contains(where: { $0.id == f.cueID }) { cueFollow = nil }
        updateShowTimer()
    }

    /// 見回りを最初から（プロジェクトを開いたとき。既に過ぎている時刻・0 は出さない）
    func resetShowWatch() {
        clockRemaining = [:]
        showLastTick = nil
        cueFollow = nil
    }

    /// 見回り：時刻・0 になった時計・自動送りを見て、要れば 1 回だけキューを出す。
    /// now は進行の「今」（ShowClock.now）、host は CACurrentMediaTime の秒
    func showTick(now: Date, host: Double) {
        let allowed = cueAutoEnabled && !cueFollower
        // 1. 時刻：前の見回りの時刻と比べて、またいだキュー（何番目でも。同じ時刻が 2 つあれば上のもの）
        var timed: Int?
        if let last = showLastTick {
            let gap = now.timeIntervalSince(last)
            if gap > 0, gap <= Self.showMaxGap {
                let a = ShowClock.secondsOfDay(last), b = ShowClock.secondsOfDay(now)
                timed = cues.firstIndex { c in c.at.map { TimeOfDay.crossed($0.seconds, from: a, to: b) } ?? false }
            }
        }
        showLastTick = now
        // 2. 時計：出力で出している「0 になったら次へ」の時計が、正 → 0 以下に変わった
        var zero = false
        var seen: [UUID: Double] = [:]
        for a in activeByLayer.compactMap({ $0 }) where slots.indices.contains(a) {
            guard let s = slots[a], let g = s.generator, ClockText.advancesCue(g) else { continue }
            guard let rem = ClockText.at(g, wall: now, elapsed: max(host - s.animOrigin, 0)).remaining else { continue }
            if let prev = clockRemaining[s.id], prev > 0, rem <= 0 { zero = true }
            seen[s.id] = rem
        }
        clockRemaining = seen
        // 3. 自動送り：○秒が過ぎた・クリップがアウト点に着いた
        var follow = false
        if let f = cueFollow {
            if let at = f.fireAt {
                follow = host >= at
            } else if let cid = f.clipID, let i = slots.firstIndex(where: { $0?.id == cid }), let s = slots[i] {
                if s.endCount > f.endCount {
                    follow = true
                } else if activeByLayer[layerOf(i)] == i, let r = s.remainingToOut(at: host), r <= s.frameLength {
                    // 残りが 1 コマ以下（ループは着いた瞬間に頭へ戻るので、回数でも見ている）
                    follow = true
                }
            }
        }
        guard allowed else { return }
        // 出すのは 1 回の見回りで 1 回まで（時刻 → 0 → 自動送りの順。どれも「次」なら 1 回だけ進む）
        if let timed {
            lastGoHost = CACurrentMediaTime()
            fireCue(timed)
        } else if zero || follow {
            fireNextCueAuto()
        }
    }

    /// 自動で次へ：連打よけは見ないが、最後に出した時刻は更新する（直後の人の二度押しを防ぐ）
    @discardableResult
    func fireNextCueAuto() -> Bool {
        guard let n = nextCue else {
            // もう次が無い：予約を捨てて見回りを止める
            cueFollow = nil
            return false
        }
        lastGoHost = CACurrentMediaTime()
        fireCue(n)
        return true
    }

    /// 予備機：本番機から来た「今ここにいる」（番号は 1 から）。今がもうその番号なら何もしない
    func followRemoteCue(_ number: Int) {
        guard cueFollower, number >= 1, cues.indices.contains(number - 1), currentCue != number - 1 else { return }
        lastGoHost = CACurrentMediaTime()
        fireCue(number - 1)
    }

    /// リハーサル：時計をずらす（0 = 本当の時刻）。変えた瞬間は「またいだ」の判定を取り直す
    func setShowClockOffset(_ o: TimeInterval) {
        ShowClock.offset = o
        showClockOffset = o
        showLastTick = nil
        // カウントダウンの残りも飛ぶので、前の残りを忘れる（変えた瞬間に 0 で進まないように）
        clockRemaining = [:]
    }

    /// リハーサル：今がその時刻になるようにずらす
    func setShowClock(to t: TimeOfDay) {
        let real = Date()
        var d = t.seconds - ShowClock.secondsOfDay(real)
        // 近い方へ（23:59 → 0:00 のように日をまたぐときに、まる 1 日ずらさない）
        if d > 43200 { d -= 86400 } else if d < -43200 { d += 86400 }
        setShowClockOffset(d)
    }

    /// 自動送りの予約の残り（秒。○秒後のときだけ）
    func cueFollowRemaining(host: Double) -> Double? {
        guard let at = cueFollow?.fireAt else { return nil }
        return max(at - host, 0)
    }

    /// 自動送りの札の短い文字（「3秒」「終わり」）。nil = 設定なし
    func cueFollowLabel(_ c: Cue) -> String? {
        guard let f = c.follow else { return nil }
        if let a = f.after { return Cue.seconds(a) }
        return L("終わり")
    }

    /// 「終わったら次へ」を選べるキューか（動画のクリップだけ。ジェネレーター・静止画・カメラは終わりが無い）
    func cueCanFollowEnd(_ c: Cue) -> Bool {
        guard case .clip = c.kind, let i = cueClipIndex(c), let s = slots[i] else { return false }
        return !s.isStill
    }
}

// MARK: - 画面

/// キューのパネルの上の帯：リハーサル中（黄色）・予備機として追っている（青）
struct ShowBanners: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        if engine.cueFollower {
            banner(L("予備機として追っている（本番機のキューで進む。自動の発火はしない）"), icon: "personalhotspot", tint: .blue) {
                Button(L("やめる")) { OSCHub.shared.followCues = false; engine.cueFollower = false }
            }
        }
        if engine.showClockOffset != 0 {
            banner(L("リハーサル中：時計 \(ShowClock.offsetText(engine.showClockOffset))"), icon: "clock.badge.exclamationmark", tint: .yellow) {
                Button(L("本当の時刻に戻す")) { engine.setShowClockOffset(0) }
            }
        }
    }

    private func banner<B: View>(_ text: String, icon: String, tint: Color, @ViewBuilder button: () -> B) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(text).font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            button().controlSize(.small)
        }
        .foregroundStyle(tint == .yellow ? Color.black : Color.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(tint == .yellow ? 0.9 : 0.6)))
    }
}

/// 「自動で進める」の入切と、リハーサルの時計（キューのパネルの、キューを足すの並び）
struct CueAutoControls: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.cueCompact) private var compact
    @State private var showRehearsal = false

    var body: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $engine.cueAutoEnabled) {
                Label(L("自動"), systemImage: engine.cueAutoEnabled ? "bolt.fill" : "bolt.slash")
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(.teal)
            .disabled(engine.cueFollower)
            .help(engine.cueAutoEnabled
                  ? L("自動で進める：オン（自動送り・時刻・時計の 0 で次へ進む）。押すと止める")
                  : L("自動で進める：止めている（自動送り・時刻・時計の 0 では進まない）。押すと戻す"))
            Button { showRehearsal = true } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(engine.showClockOffset != 0 ? Color.yellow : Color.secondary)
            }
            .controlSize(.small)
            .help(L("リハーサル：時刻を仮に決める（時刻のキュー・カウントダウンを試す）"))
            .popover(isPresented: $showRehearsal, arrowEdge: .bottom) {
                RehearsalClockPopover().environmentObject(engine)
            }
        }
        .fixedSize()
    }
}

/// リハーサル：今を決めた時刻にする・本当の時刻に戻す
private struct RehearsalClockPopover: View {
    @EnvironmentObject var engine: Engine
    @State private var t = TimeOfDay(ShowClock.now)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(L("リハーサル：時刻を仮に決める"), icon: "clock.arrow.circlepath", tint: .yellow)
            Text(L("キューの時刻・カウントダウンの時計が、この時刻で動きます。保存しません（開き直すと本当の時刻）"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TimeOfDayFields(t: $t)
            HStack(spacing: 6) {
                Button(L("今を \(t.label) にする")) { engine.setShowClock(to: t) }
                    .buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
                if let next = nextTimedCue {
                    Button(L("次の時刻のキューの 10 秒前")) {
                        let s = Int(next.seconds) - 10 + 86400
                        engine.setShowClock(to: TimeOfDay(h: (s / 3600) % 24, m: (s / 60) % 60, s: s % 60))
                    }
                    .help(L("「\(next.label)」の 10 秒前にする"))
                }
            }
            Button(L("本当の時刻に戻す")) { engine.setShowClockOffset(0) }
                .disabled(engine.showClockOffset == 0)
            if engine.showClockOffset != 0 {
                Text(L("今のずらし：\(ShowClock.offsetText(engine.showClockOffset))"))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.yellow)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// 今から次に来る時刻のキュー
    private var nextTimedCue: TimeOfDay? {
        let now = ShowClock.now
        return engine.cues.compactMap(\.at).min { $0.until(now) < $1.until(now) }
    }
}

/// 時・分・秒の 3 つの欄
struct TimeOfDayFields: View {
    @Binding var t: TimeOfDay

    var body: some View {
        HStack(spacing: 4) {
            field($t.h, 0...23)
            Text(":").font(.system(size: 14, weight: .bold))
            field($t.m, 0...59)
            Text(":").font(.system(size: 14, weight: .bold))
            field($t.s, 0...59)
        }
    }

    private func field(_ v: Binding<Int>, _ r: ClosedRange<Int>) -> some View {
        HStack(spacing: 1) {
            TextField("", value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = min(max($0, r.lowerBound), r.upperBound) }),
                      format: .number.grouping(.never))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 36)
            Stepper("", value: v, in: r).labelsHidden()
        }
    }
}

/// キューの時刻の設定（行の右クリック・時刻の札から）
struct CueTimePopover: View {
    @EnvironmentObject var engine: Engine
    let cue: Cue
    @State private var t: TimeOfDay
    @Environment(\.dismiss) private var dismiss

    init(cue: Cue) {
        self.cue = cue
        _t = State(initialValue: cue.at ?? TimeOfDay(ShowClock.now.addingTimeInterval(60)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(L("この時刻になったら出す"), icon: "alarm", tint: .teal)
            TimeOfDayFields(t: $t)
            HStack(spacing: 6) {
                Button(L("今から 1 分後")) { t = TimeOfDay(ShowClock.now.addingTimeInterval(60)) }
                Spacer(minLength: 0)
                if cue.at != nil {
                    Button(L("消す")) { engine.updateCue(cue.id) { $0.at = nil }; dismiss() }
                }
                Button(L("決める")) { engine.updateCue(cue.id) { $0.at = t }; dismiss() }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .keyboardShortcut(.defaultAction)
            }
            Text(L("毎日この時刻に、順番に関係なく出します（日付は持たない）。キューのパネルの「自動」を切ると出ません"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// 行の時刻の札：「19:00」、1 時間以内なら「あと 12:30」も
struct CueTimeBadge: View {
    @EnvironmentObject var engine: Engine
    let at: TimeOfDay

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let left = at.until(ShowClock.now)
            let soon = left <= 3600 && !off
            // 狭いときは「あと」だけ → 時刻だけ、の順に短くする（札が行の幅を押し広げないように）
            ViewThatFits(in: .horizontal) {
                badge(time: true, left: soon ? left : nil)
                if soon { badge(time: false, left: left) }
                badge(time: true, left: nil)
                Image(systemName: "alarm").font(.system(size: 8, weight: .bold)).foregroundStyle(off ? Color.secondary : Color.teal)
            }
        }
        .help(off ? L("\(at.label) に出す（今は止めている）") : L("\(at.label) に出す（押して変える）"))
    }
}

extension CueTimeBadge {
    private var off: Bool { !engine.cueAutoEnabled || engine.cueFollower }

    private func badge(time: Bool, left: Double?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "alarm").font(.system(size: 8, weight: .bold))
            if time { Text(at.shortLabel).font(.system(size: 10, weight: .bold).monospacedDigit()) }
            if let left { Text(L("あと \(ShowClock.countdown(left))")).font(.system(size: 10).monospacedDigit()) }
        }
        .strikethrough(off)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(off ? Color.secondary : Color.teal)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 3).fill((off ? Color.gray : Color.teal).opacity(0.15)))
    }
}

/// 行の右の自動送りのボタン（設定が無ければ印だけ）
struct CueFollowButton: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.cueCompact) private var compact
    let cue: Cue

    var body: some View {
        let full = engine.cueFollowLabel(cue)
        // 狭いときは印だけ（決めてあれば青緑）
        let label = compact ? nil : full
        let off = !engine.cueAutoEnabled || engine.cueFollower
        let color: Color = full == nil ? .secondary : (off ? .secondary : .teal)
        Menu {
            CueFollowMenuItems(cue: cue)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .bold))
                if let label { Text(label).font(.system(size: 10, weight: .semibold).monospacedDigit()).strikethrough(off) }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(color)
        .tint(color)
        .padding(.horizontal, label == nil ? 4 : 6)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12)))
        .opacity(full == nil ? 0.6 : 1)
        .help(full.map { L("自動で次へ：\($0)\(off ? L("（今は止めている）") : "")。押して選ぶ") } ?? L("自動で次へ：なし。押して選ぶ"))
    }
}

/// 自動送りの選択肢（行のボタン・右クリック）
struct CueFollowMenuItems: View {
    @EnvironmentObject var engine: Engine
    let cue: Cue

    var body: some View {
        Button((cue.follow == nil ? "✓ " : "") + L("自動で進めない")) { engine.updateCue(cue.id) { $0.follow = nil } }
        Divider()
        if engine.cueCanFollowEnd(cue) || cue.follow.map({ $0.after == nil }) == true {
            Button((cue.follow != nil && cue.follow?.after == nil ? "✓ " : "") + L("クリップが終わったら次へ")) {
                engine.updateCue(cue.id) { $0.follow = Cue.Follow(after: nil) }
            }
        }
        ForEach(Cue.followChoices, id: \.self) { s in
            Button((cue.follow?.after == s ? "✓ " : "") + L("\(Cue.seconds(s))後に次へ")) {
                engine.updateCue(cue.id) { $0.follow = Cue.Follow(after: s) }
            }
        }
        let custom = cue.follow?.after.flatMap { Cue.followChoices.contains($0) ? nil : $0 }
        Button((custom != nil ? "✓ " : "") + L("秒数を入れる…") + (custom.map { "（\(Cue.seconds($0))）" } ?? "")) {
            let initial = cue.follow?.after.map { String(format: "%g", $0) } ?? ""
            if let s = askText(title: L("何秒後に次へ進むか（0.1〜3600）"), initial: initial),
               let v = Double(s.replacingOccurrences(of: "秒", with: "")), v.isFinite {
                engine.updateCue(cue.id) { $0.follow = Cue.Follow(after: min(max(v, 0.1), 3600)) }
            }
        }
    }
}

/// 「今」の大きな表示の右上：自動送りの残り（「次へ あと 0:03」「終わったら次へ」）
struct CueFollowCountdown: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        if let f = engine.cueFollow {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let text = f.fireAt != nil
                    ? L("次へ あと \(ShowClock.countdown(engine.cueFollowRemaining(host: CACurrentMediaTime()) ?? 0))")
                    : L("終わったら次へ")
                Label(text, systemImage: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.teal)
                    .lineLimit(1)
            }
        }
    }
}

/// 「次」の大きな表示の右上：次の時刻のキューまで（1 時間以内）
struct NextTimedCueCountdown: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        if engine.cueAutoEnabled && !engine.cueFollower, engine.cues.contains(where: { $0.at != nil }) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let now = ShowClock.now
                if let best = engine.cues.enumerated().compactMap({ i, c in c.at.map { (i, $0.until(now)) } }).min(by: { $0.1 < $1.1 }),
                   best.1 <= 3600 {
                    Label(L("\(best.0 + 1) まで \(ShowClock.countdown(best.1))"), systemImage: "alarm")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// 出力モニターの隅の札：リハーサル中・入っているラッチのパッド
struct OutputShowBadges: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let latched = engine.pads.filter { $0.latch && engine.heldPads[$0.id] != nil }
        VStack(alignment: .leading, spacing: 3) {
            if engine.showClockOffset != 0 {
                Text(L("リハーサル中：時計 \(ShowClock.offsetText(engine.showClockOffset))"))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.yellow.opacity(0.9)))
            }
            if !latched.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                    Text(latched.map(\.displayName).joined(separator: L("・"))).font(.system(size: 10, weight: .bold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.85)))
                .help(L("ラッチで入っているパッド（もう一度押すと切れる）"))
            }
        }
        .allowsHitTesting(false)
    }
}

/// ラベルの見せ方を、条件で切り替える
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(Label($0).labelStyle(style)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
