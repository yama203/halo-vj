import Foundation
import IOKit
import QuartzCore
import SwiftUI

/// CPU・GPU・メモリ・描画のコマ数を 1 秒ごとに測る（画面下の状態表示用）。
/// 測るのは別のスレッドで、メインスレッドには結果を書くだけ
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    struct Sample: Equatable {
        /// このアプリの CPU（マシン全体を 100% として）
        var appCPU = 0.0
        /// マシン全体の CPU
        var totalCPU = 0.0
        /// GPU の使用率（取れなければ nil）
        var gpu: Double?
        /// このアプリのメモリ（MB）
        var memoryMB = 0.0
        /// 描画のコマ数（1 秒あたり）
        var fps = 0.0
        /// いちばん長く描けなかった間隔（ms）
        var maxGapMs = 0.0
    }

    @Published private(set) var sample = Sample()

    private let queue = DispatchQueue(label: "SystemMonitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastWall = 0.0
    private var lastAppCPU = 0.0
    private var lastHostTicks: (busy: UInt64, total: UInt64)?
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.measure() }
        t.resume()
        timer = t
    }

    private func measure() {
        let wall = CACurrentMediaTime()
        let cpu = Self.appCPUSeconds()
        let host = Self.hostTicks()
        let counts = RenderLoop.shared.takeMonitorCounts()
        var s = Sample()
        if lastWall > 0 {
            let dt = max(wall - lastWall, 0.001)
            s.appCPU = min(max((cpu - lastAppCPU) / dt / cores * 100, 0), 100)
            s.fps = Double(counts.ticks) / dt
            s.maxGapMs = counts.maxGapMs
        }
        if let host, let last = lastHostTicks, host.total > last.total {
            s.totalCPU = Double(host.busy - last.busy) / Double(host.total - last.total) * 100
        }
        s.gpu = Self.gpuUtilization()
        s.memoryMB = Self.memoryMB()
        lastWall = wall
        lastAppCPU = cpu
        lastHostTicks = host
        DispatchQueue.main.async { if self.sample != s { self.sample = s } }
        logIfAsked(s, wall: wall)
    }

    // MARK: 安定性のテスト用：VJ_STATS_LOG=ファイル で、10 秒ごとに様子を書き足す（CSV）
    private static let logPath = ProcessInfo.processInfo.environment["VJ_STATS_LOG"]
    private var logStart = 0.0
    private var lastLog = 0.0
    private var worstGap = 0.0
    private var fpsSum = 0.0, fpsN = 0.0, fpsMin = 1e9

    private func logIfAsked(_ s: Sample, wall: Double) {
        guard let path = Self.logPath, s.fps > 0 else { return }
        if logStart == 0 {
            logStart = wall; lastLog = wall
            try? ("経過秒,描画fps平均,描画fps最低,最長の止まりms,アプリCPU%,GPU%,メモリMB,開いているファイル,スレッド,自動の切り替え回数\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        worstGap = max(worstGap, s.maxGapMs)
        fpsSum += s.fps; fpsN += 1; fpsMin = min(fpsMin, s.fps)
        guard wall - lastLog >= 10 else { return }
        lastLog = wall
        let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        var nThreads = -1
        if task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS {
            nThreads = Int(count)
            if let threads {
                for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[i]) }
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
            }
        }
        let fired = DispatchQueue.main.sync { Engine.shared.autoRunner.firedCount }
        let line = String(format: "%.0f,%.1f,%.1f,%.0f,%.1f,%.0f,%.0f,%d,%d,%d\n", wall - logStart, fpsSum / max(fpsN, 1), fpsMin,
                          worstGap, s.appCPU, s.gpu ?? -1, s.memoryMB, fds, nThreads, fired)
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        worstGap = 0; fpsSum = 0; fpsN = 0; fpsMin = 1e9
    }

    /// このアプリが使った CPU 時間（秒、全スレッドの合計）
    private static func appCPUSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func sec(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return sec(u.ru_utime) + sec(u.ru_stime)
    }

    /// マシン全体の CPU の刻み（使っていた分と全体）
    static func hostTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let user = UInt64(t.0), sys = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        return (user + sys + nice, user + sys + idle + nice)
    }

    /// GPU の使用率（%）。IOKit の IOAccelerator が出している値を読む
    static func gpuUtilization() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        var entry = IOIteratorNext(it)
        while entry != 0 {
            if let p = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let v = (p["Device Utilization %"] ?? p["GPU Activity(%)"]) as? NSNumber {
                best = max(best ?? 0, v.doubleValue)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(it)
        }
        return best
    }

    /// このアプリのメモリ（アクティビティモニタの「メモリ」と同じ phys_footprint、MB）
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// ウィンドウのいちばん下の、小さな状態表示（CPU・GPU・メモリ・描画のコマ数）
struct StatusBar: View {
    @ObservedObject private var mon = SystemMonitor.shared

    var body: some View {
        let s = mon.sample
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            item("CPU", String(format: "%.0f%%", s.appCPU), level(s.appCPU, 50, 80))
                .help(String(format: L("このアプリの CPU（マシン全体を 100%% として）。マシン全体では %.0f%%"), s.totalCPU))
            item(L("全体"), String(format: "%.0f%%", s.totalCPU), level(s.totalCPU, 60, 85))
                .help(L("マシン全体の CPU（ほかのアプリも含む）"))
            item("GPU", s.gpu.map { String(format: "%.0f%%", $0) } ?? "—", level(s.gpu ?? 0, 60, 85))
                .help(L("GPU の使用率（ほかのアプリも含む）"))
            item(L("メモリ"), s.memoryMB >= 1024 ? String(format: "%.1f GB", s.memoryMB / 1024) : String(format: "%.0f MB", s.memoryMB),
                 .secondary)
                .help(L("このアプリが使っているメモリ"))
            item(L("描画"), String(format: "%.0f fps", s.fps), s.maxGapMs > 50 ? .orange : .secondary)
                .help(String(format: L("1 秒に何回描いているか（画面のリフレッシュレートに合わせて描く）。直近 1 秒でいちばん長くあいたのは %.0f ms"), s.maxGapMs))
        }
        .font(.system(size: 10.5).monospacedDigit())
        .padding(.horizontal, 12)
        .frame(height: 20)
        .background(Color.black.opacity(0.18))
        .onAppear { SystemMonitor.shared.start() }
    }

    private func level(_ v: Double, _ warn: Double, _ bad: Double) -> Color {
        v >= bad ? .red : v >= warn ? .orange : .secondary
    }

    private func item(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(color)
        }
    }
}
