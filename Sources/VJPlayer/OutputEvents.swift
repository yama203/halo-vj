import Foundation
import SwiftUI

// 出力が切り替わったことを知らせる（出力モニターを一瞬光らせて、何に変わったかを出す）。
// クリップを出した・シーンを呼んだ・止めた・自動操縦が切り替えた。一度にたくさん変わったときは 1 つにまとめる。

struct OutputEvent: Equatable {
    enum Kind { case clip, scene, stop }
    var id = UUID()
    var text: String
    var kind: Kind
    /// 自動操縦が出したもの
    var auto = false

    var color: Color {
        switch kind {
        case .clip: Color.green
        case .scene: Color.purple
        case .stop: Color.gray
        }
    }
}

extension Engine {
    /// クリップを出した（trigger から）
    func noteOutputClip(layer r: Int, name: String) {
        guard outputEventMute == 0 else { return }
        queueOutputEvent("L\(r + 1)  \(name)", kind: .clip)
    }

    /// 止めた（stopLayer から）
    func noteOutputStop(layer r: Int) {
        guard outputEventMute == 0 else { return }
        queueOutputEvent("L\(r + 1) を止めた", kind: .stop)
    }

    /// シーンを呼んだ（中で出すクリップは数えない）
    func noteOutputScene(_ name: String) {
        outputPending = []
        outputEvent = OutputEvent(text: "シーン  \(name)", kind: .scene, auto: autoRunner.acting)
    }

    /// 同じ瞬間の変化をまとめてから知らせる（列ごとに出す・全部止めるなど）
    private func queueOutputEvent(_ text: String, kind: OutputEvent.Kind) {
        let first = outputPending.isEmpty
        outputPending.append((text, kind, autoRunner.acting))
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.outputPending.isEmpty else { return }
            let items = self.outputPending
            self.outputPending = []
            let auto = items.contains { $0.2 }
            if items.count == 1 {
                self.outputEvent = OutputEvent(text: items[0].0, kind: items[0].1, auto: auto)
            } else if items.allSatisfy({ $0.1 == .stop }) {
                self.outputEvent = OutputEvent(text: "\(items.count) つのレイヤーを止めた", kind: .stop, auto: auto)
            } else {
                let n = items.filter { $0.1 == .clip }.count
                self.outputEvent = OutputEvent(text: "\(n) つのクリップを出した", kind: .clip, auto: auto)
            }
        }
    }
}

/// 出力モニターの上に重ねる：縁が光って、左上に何に変わったかが出て、すっと消える
struct OutputFlashOverlay: View {
    @EnvironmentObject var engine: Engine
    @AppStorage("flashOnOutput") private var flashOnOutput = true
    @State private var flash = 0.0
    @State private var shown: OutputEvent?

    var body: some View {
        let c = shown?.color ?? .green
        ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(c.opacity(flash), lineWidth: 3)
                .shadow(color: c.opacity(0.8 * flash), radius: 10)
            if let e = shown {
                HStack(spacing: 5) {
                    if e.auto { Image(systemName: "airplane").font(.system(size: 10, weight: .bold)) }
                    Text(e.text).font(.system(size: 12, weight: .bold)).lineLimit(1)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(c))
                .padding(8)
                .opacity(min(flash * 1.6, 1))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: engine.outputEvent) { _, e in
            guard flashOnOutput, let e else { return }
            shown = e
            flash = 1
            withAnimation(.easeOut(duration: 1.4)) { flash = 0 }
        }
    }
}
