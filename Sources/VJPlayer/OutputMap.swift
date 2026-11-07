import AppKit
import Metal
import QuartzCore
import SwiftUI
import simd

// 出力の分割：コンポジションのどこを（取る所＝四角）、どの出力のどこへ（映す所＝四隅）、端をどれだけなじませて（エッジブレンド）出すか。
// 複数のプロジェクター・LED ウォール・別々のディスプレイ（出力 1〜3）に、コンポジションの一部ずつを出す。
// 分割を使わないときは今までどおり（出力 1 に、四隅の調整をかけて全体を出す）。プロジェクトに保存される。

struct OutputSlice: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "スライス"
    var enabled = true
    /// 出す出力（0 = 出力 1）
    var output = 0
    /// 取る所：コンポジションの左上を 0,0、右下を 1,1 とした四角（x, y, 幅, 高さ）
    var input: [Double] = [0, 0, 1, 1]
    /// 映す所：出力の画面の左上を 0,0、右下を 1,1 とした四隅（左上・右上・右下・左下）
    var corners: [[Double]] = [[0, 0], [1, 0], [1, 1], [0, 1]]
    /// 端をなじませる幅（スライスの幅・高さに対する割合。左・右・上・下）
    var feather: [Double] = [0, 0, 0, 0]

    var inputRect: CGRect { CGRect(x: input[0], y: input[1], width: input[2], height: input[3]) }
}

struct OutputMap: Codable, Equatable {
    var enabled = false
    var slices: [OutputSlice] = []
    var active: Bool { enabled && slices.contains { $0.enabled } }

    /// よく使う並べ方：count 台を横（または縦）に、overlap の割合だけ重ねて並べる。separate なら別々の出力へ
    static func preset(count: Int, vertical: Bool = false, overlap: Double = 0, separate: Bool = false) -> [OutputSlice] {
        let n = max(count, 1)
        // 重ねた分も入れて、n 台で 1 になる 1 台の幅
        let w = 1 / (Double(n) - overlap * Double(n - 1))
        return (0..<n).map { i in
            var s = OutputSlice()
            s.name = vertical ? "上から \(i + 1)" : "左から \(i + 1)"
            let start = Double(i) * w * (1 - overlap)
            s.input = vertical ? [0, start, 1, w] : [start, 0, w, 1]
            // 映す所：別々の出力なら画面いっぱい、同じ出力なら並べて置く
            if separate {
                s.output = min(i, OutputController.maxOutputs - 1)
            } else {
                let a = Double(i) / Double(n), b = Double(i + 1) / Double(n)
                s.corners = vertical ? [[0, a], [1, a], [1, b], [0, b]] : [[a, 0], [b, 0], [b, 1], [a, 1]]
            }
            // 重ねた所をなじませる（隣と重なる側だけ。重ねた幅 ＝ 1 台の幅 × overlap）
            let ff = min(max(overlap, 0), 0.5)
            if vertical {
                s.feather = [0, 0, i > 0 ? ff : 0, i < n - 1 ? ff : 0]
            } else {
                s.feather = [i > 0 ? ff : 0, i < n - 1 ? ff : 0, 0, 0]
            }
            return s
        }
    }
}

// MARK: - 描く

private let sliceShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VO { float4 pos [[position]]; float2 uv; };
vertex VO os_v(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o; o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0); o.uv = c; return o;
}
struct SliceU { float3x3 hinv; float4 input; float4 feather; float4 extra; };   // extra = 番号, 0, 0, 0
struct SlicesU { int count; float master; int testPattern; float pad; };

static float3 sliceColor(float i) {
    float3 k = abs(fract(float3(i * 0.13 + 0.05) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return saturate(k - 1.0);
}
fragment float4 os_f(VO in [[stage_in]], constant SlicesU& u [[buffer(0)]], constant SliceU* sl [[buffer(1)]],
                     texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 sum = 0.0;
    for (int i = 0; i < u.count; i++) {
        float3 h = sl[i].hinv * float3(in.uv, 1.0);
        if (h.z <= 0.0) continue;
        float2 l = h.xy / h.z;
        if (any(l < 0.0) || any(l > 1.0)) continue;
        // 端をなじませる（隣と重なる所で、足して元の明るさになるように、光の量で混ぜる）
        float4 f = sl[i].feather;
        float w = 1.0;
        if (f.x > 0.0) w *= smoothstep(0.0, 1.0, l.x / f.x);
        if (f.y > 0.0) w *= smoothstep(0.0, 1.0, (1.0 - l.x) / f.y);
        if (f.z > 0.0) w *= smoothstep(0.0, 1.0, l.y / f.z);
        if (f.w > 0.0) w *= smoothstep(0.0, 1.0, (1.0 - l.y) / f.w);
        float3 c;
        if (u.testPattern != 0) {
            // テストパターン：スライスごとの色の格子と、ふち
            float2 g = abs(fract(l * 8.0) - 0.5);
            float line = step(0.46, max(g.x, g.y));
            float edge = step(min(min(l.x, 1.0 - l.x), min(l.y, 1.0 - l.y)), 0.01);
            c = mix(sliceColor(sl[i].extra.x) * 0.55, float3(1.0), max(line, edge));
        } else {
            float2 uv = sl[i].input.xy + l * sl[i].input.zw;
            c = tex.sample(s, uv).rgb;
        }
        sum += pow(max(c, 0.0), 2.2) * w;
    }
    return float4(pow(sum, 1.0 / 2.2) * u.master, 1.0);
}
"""

private struct SliceUniform {
    var hinv: simd_float3x3
    var input: SIMD4<Float>
    var feather: SIMD4<Float>
    var extra: SIMD4<Float>
}
private struct SlicesUniform {
    var count: Int32
    var master: Float
    var testPattern: Int32
    var pad: Float = 0
}

final class SliceRenderer {
    static let shared = SliceRenderer()
    let pipe: MTLRenderPipelineState
    private init() {
        let dev = MetalContext.shared.device
        let lib = try! dev.makeLibrary(source: sliceShaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "os_v")
        d.fragmentFunction = lib.makeFunction(name: "os_f")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipe = try! dev.makeRenderPipelineState(descriptor: d)
    }

    /// 出力 output の画面（target）に、そこへ出すスライスを描く
    func draw(_ map: OutputMap, output: Int, composite: MTLTexture?, master: Float, testPattern: Bool,
              into target: MTLTexture, cb: MTLCommandBuffer) {
        var us: [SliceUniform] = []
        for (i, s) in map.slices.enumerated() where s.enabled && s.output == output && s.corners.count == 4 && s.input.count == 4 {
            let q = s.corners.map { SIMD2(Float($0[0]), Float($0[1])) }
            let f = s.feather.count == 4 ? s.feather : [0, 0, 0, 0]
            us.append(SliceUniform(hinv: Homography.squareToQuad(q).inverse,
                                   input: SIMD4(s.input.map(Float.init)),
                                   feather: SIMD4(f.map { Float(min(max($0, 0), 1)) }),
                                   extra: SIMD4(Float(i), 0, 0, 0)))
            if us.count >= 16 { break }
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        if !us.isEmpty, composite != nil || testPattern {
            var u = SlicesUniform(count: Int32(us.count), master: master, testPattern: testPattern ? 1 : 0)
            enc.setRenderPipelineState(pipe)
            enc.setFragmentBytes(&u, length: MemoryLayout<SlicesUniform>.stride, index: 0)
            us.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            enc.setFragmentTexture(composite ?? MetalContext.shared.dummyTexture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }
}

// MARK: - 編集の窓

final class OutputMapWindow: NSObject, NSWindowDelegate {
    static let shared = OutputMapWindow()
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "出力の分割"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: OutputMapEditor().environmentObject(Engine.shared)
            .preferredColorScheme(.dark))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct OutputMapEditor: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var outputs = OutputController.shared
    @State private var selected: UUID?
    @State private var shownOutput = 0

    private var map: Binding<OutputMap> { $engine.outputMap }
    private var selIndex: Int? { engine.outputMap.slices.firstIndex { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Toggle("出力を分割する", isOn: map.enabled).toggleStyle(.switch)
                Menu("並べ方のひな形") {
                    Button("1 台（全体）") { setSlices(OutputMap.preset(count: 1)) }
                    Button("横に 2 台（15% 重ねてなじませる）") { setSlices(OutputMap.preset(count: 2, overlap: 0.15, separate: true)) }
                    Button("横に 3 台（15% 重ねてなじませる）") { setSlices(OutputMap.preset(count: 3, overlap: 0.15, separate: true)) }
                    Button("横に 2 台（重ねない）") { setSlices(OutputMap.preset(count: 2, separate: true)) }
                    Button("縦に 2 台（15% 重ねてなじませる）") { setSlices(OutputMap.preset(count: 2, vertical: true, overlap: 0.15, separate: true)) }
                    Divider()
                    Button("1 つの出力に、横に 2 つ並べる") { setSlices(OutputMap.preset(count: 2)) }
                    Button("1 つの出力に、横に 3 つ並べる") { setSlices(OutputMap.preset(count: 3)) }
                }
                .fixedSize()
                Toggle("テストパターン", isOn: $engine.testPattern).toggleStyle(.button)
                Spacer()
            }
            HStack(spacing: 12) {
                ForEach(0..<OutputController.maxOutputs, id: \.self) { i in
                    HStack(spacing: 4) {
                        Text("出力 \(i + 1)").font(.system(size: 12, weight: .semibold))
                        Picker("", selection: outputs.binding(i)) {
                            Text("なし").tag(OutputTarget.none)
                            Text("ウィンドウ").tag(OutputTarget.window)
                            ForEach(outputs.screens, id: \.self) { s in
                                Text(OutputController.label(of: s)).tag(OutputTarget.screen(OutputController.displayID(of: s)))
                            }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                sliceList.frame(width: 250)
                VStack(alignment: .leading, spacing: 6) {
                    Text("取る所（コンポジション）：四角をドラッグで動かす・角で大きさ").font(.system(size: 11)).foregroundStyle(.secondary)
                    ZStack {
                        MetalPreview(kind: .composition)
                        InputRectsOverlay(map: map, selected: $selected)
                    }
                    .aspectRatio(engine.outputAspect, contentMode: .fit)
                    .overlay(Rectangle().stroke(Color.gray.opacity(0.4)))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("映す所：四隅をドラッグ").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("", selection: $shownOutput) {
                            ForEach(0..<OutputController.maxOutputs, id: \.self) { Text("出力 \($0 + 1)").tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 220)
                    }
                    ZStack {
                        OutputPreview(output: shownOutput)
                        OutputCornersOverlay(map: map, output: shownOutput, selected: $selected)
                    }
                    .aspectRatio(outputs.aspect(of: shownOutput), contentMode: .fit)
                    .overlay(Rectangle().stroke(Color.gray.opacity(0.4)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear { if selected == nil { selected = engine.outputMap.slices.first?.id } }
    }

    private func setSlices(_ s: [OutputSlice]) {
        engine.outputMap.slices = s
        engine.outputMap.enabled = true
        selected = s.first?.id
    }

    @ViewBuilder private var sliceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("スライス").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { var s = OutputSlice(); s.name = "スライス \(engine.outputMap.slices.count + 1)"; engine.outputMap.slices.append(s); selected = s.id } label: { Image(systemName: "plus") }
                Button { if let i = selIndex { engine.outputMap.slices.remove(at: i); selected = engine.outputMap.slices.first?.id } } label: { Image(systemName: "minus") }
                    .disabled(selIndex == nil)
            }
            List(selection: $selected) {
                ForEach(engine.outputMap.slices) { s in
                    HStack {
                        Circle().fill(sliceColor(s)).frame(width: 8, height: 8)
                        Text(s.name).lineLimit(1)
                        Spacer()
                        Text("出力 \(s.output + 1)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .opacity(s.enabled ? 1 : 0.4)
                    .tag(s.id)
                }
            }
            .frame(height: 150)
            if let i = selIndex {
                SliceDetail(slice: map.slices[i])
            }
        }
    }

    private func sliceColor(_ s: OutputSlice) -> Color {
        let i = Double(engine.outputMap.slices.firstIndex { $0.id == s.id } ?? 0)
        return Color(hue: (i * 0.13 + 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 1)
    }
}

private struct SliceDetail: View {
    @Binding var slice: OutputSlice
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("名前", text: $slice.name)
            Toggle("出す", isOn: $slice.enabled)
            Picker("出力", selection: $slice.output) {
                ForEach(0..<OutputController.maxOutputs, id: \.self) { Text("出力 \($0 + 1)").tag($0) }
            }
            Text("取る所").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                drag("X", 0); drag("Y", 1)
            }
            HStack(spacing: 4) {
                drag("幅", 2); drag("高さ", 3)
            }
            Text("端をなじませる（エッジブレンド）").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 4) { feather("左", 0); feather("右", 1) }
            HStack(spacing: 4) { feather("上", 2); feather("下", 3) }
            Button("映す所の四隅を元に戻す") { slice.corners = [[0, 0], [1, 0], [1, 1], [0, 1]] }
        }
        .font(.system(size: 12))
    }

    private func drag(_ label: String, _ i: Int) -> some View {
        ValueDrag(label: label, value: Binding(get: { slice.input[i] }, set: { slice.input[i] = min(max($0, 0), i >= 2 ? 1 : 0.99) }),
                  range: 0...1, perPoint: 0.001, defaultValue: i >= 2 ? 1 : 0, format: EffectParam.percent)
            .frame(height: 26)
    }
    private func feather(_ label: String, _ i: Int) -> some View {
        ValueDrag(label: label, value: Binding(get: { slice.feather.count == 4 ? slice.feather[i] : 0 },
                                               set: { if slice.feather.count != 4 { slice.feather = [0, 0, 0, 0] }; slice.feather[i] = $0 }),
                  range: 0...0.5, perPoint: 0.001, defaultValue: 0, format: EffectParam.percent)
            .frame(height: 26)
    }
}

/// 取る所の四角（ドラッグで動かす・右下の角で大きさ）
private struct InputRectsOverlay: View {
    @Binding var map: OutputMap
    @Binding var selected: UUID?
    @State private var start: [Double]?

    var body: some View {
        GeometryReader { g in
            ForEach(Array(map.slices.enumerated()), id: \.element.id) { i, s in
                let r = CGRect(x: s.input[0] * g.size.width, y: s.input[1] * g.size.height,
                               width: s.input[2] * g.size.width, height: s.input[3] * g.size.height)
                let sel = s.id == selected
                ZStack(alignment: .bottomTrailing) {
                    Rectangle().fill(Color(hue: (Double(i) * 0.13 + 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 1)
                        .opacity(sel ? 0.25 : 0.1))
                    Rectangle().stroke(sel ? Color.yellow : Color.white.opacity(0.7), lineWidth: sel ? 2 : 1)
                    Text(s.name).font(.system(size: 10, weight: .bold)).foregroundStyle(.white).padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // 大きさ
                    Rectangle().fill(Color.yellow).frame(width: 10, height: 10)
                        .gesture(DragGesture().onChanged { v in
                            selected = s.id
                            if start == nil { start = s.input }
                            guard let st = start else { return }
                            map.slices[i].input[2] = min(max(st[2] + v.translation.width / g.size.width, 0.02), 1 - st[0])
                            map.slices[i].input[3] = min(max(st[3] + v.translation.height / g.size.height, 0.02), 1 - st[1])
                        }.onEnded { _ in start = nil })
                }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .gesture(DragGesture().onChanged { v in
                    selected = s.id
                    if start == nil { start = s.input }
                    guard let st = start else { return }
                    map.slices[i].input[0] = min(max(st[0] + v.translation.width / g.size.width, 0), 1 - st[2])
                    map.slices[i].input[1] = min(max(st[1] + v.translation.height / g.size.height, 0), 1 - st[3])
                }.onEnded { _ in start = nil })
            }
        }
    }
}

/// 映す所の四隅（ドラッグで動かす）
private struct OutputCornersOverlay: View {
    @Binding var map: OutputMap
    let output: Int
    @Binding var selected: UUID?

    var body: some View {
        GeometryReader { g in
            ForEach(Array(map.slices.enumerated()), id: \.element.id) { i, s in
                if s.output == output && s.corners.count == 4 {
                    let pts = s.corners.map { CGPoint(x: $0[0] * g.size.width, y: $0[1] * g.size.height) }
                    let sel = s.id == selected
                    Path { p in p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath() }
                        .stroke(sel ? Color.yellow : Color.white.opacity(0.6), lineWidth: sel ? 2 : 1)
                    if sel {
                        ForEach(0..<4, id: \.self) { k in
                            Circle().fill(Color.yellow).frame(width: 14, height: 14)
                                .position(pts[k])
                                .gesture(DragGesture().onChanged { v in
                                    map.slices[i].corners[k] = [min(max(v.location.x / g.size.width, -0.5), 1.5),
                                                                min(max(v.location.y / g.size.height, -0.5), 1.5)]
                                })
                        }
                    } else {
                        Color.clear.contentShape(Path { p in p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath() })
                            .onTapGesture { selected = s.id }
                    }
                }
            }
        }
    }
}

/// 出力 n の見た目（実際に出しているのと同じ）
private struct OutputPreview: NSViewRepresentable {
    let output: Int
    func makeNSView(context: Context) -> MetalLayerView { MetalLayerView(frame: .zero, kind: .output, output: output) }
    func updateNSView(_ v: MetalLayerView, context: Context) { v.setOutput(output) }
}
