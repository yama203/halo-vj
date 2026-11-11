import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import SwiftUI

// カメラ・キャプチャの入力：Web カメラ・HDMI キャプチャ・iPhone（連係カメラ）の映像を、ジェネレーター「カメラから」で置く。
// 受け取り口はアプリ全体で、機器ごとに 1 つ（同じカメラを何枚の枠に置いても 1 回だけ開く）。しばらく使わなければ閉じる。

struct CameraDevice: Hashable, Identifiable {
    let id: String     // AVCaptureDevice.uniqueID
    let name: String

    static func list() -> [CameraDevice] {
        let s = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                                 mediaType: .video, position: .unspecified)
        return s.devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// 1 つのカメラから、いちばん新しい絵を受け取り続ける
private final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "VJPlayer.camera")
    private var cache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latest: CVMetalTexture?
    var used = CACurrentMediaTime()

    init?(id: String) {
        super.init()
        guard let dev = AVCaptureDevice(uniqueID: id), let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { return nil }
        session.beginConfiguration()
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                             kCVPixelBufferMetalCompatibilityKey as String: true]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { return nil }
        session.addOutput(out)
        session.commitConfiguration()
        CVMetalTextureCacheCreate(nil, nil, MetalContext.shared.device, nil, &cache)
        queue.async { self.session.startRunning() }
    }

    func stop() { queue.async { self.session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb), let cache else { return }
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, CVPixelBufferGetWidth(pb),
                                                  CVPixelBufferGetHeight(pb), 0, &t)
        guard let t else { return }
        lock.withLock { latest = t }
    }

    /// いちばん新しい絵（受け取った CVMetalTexture ごと渡して、使い終わるまで持っておけるように）
    func frame() -> (MTLTexture, CVMetalTexture)? {
        lock.withLock {
            guard let l = latest, let tex = CVMetalTextureGetTexture(l) else { return nil }
            return (tex, l)
        }
    }
}

final class CameraInputs: ObservableObject {
    static let shared = CameraInputs()
    @Published private(set) var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private let lock = NSLock()
    private var sessions: [String: CameraSession] = [:]

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { self.permission = AVCaptureDevice.authorizationStatus(for: .video) }
        }
    }

    /// 使われなくなったカメラを閉じるまでの秒数（クリップを消す・止めると、このくらいでカメラの緑の印が消える）
    static let idleSeconds = 3.0

    /// しばらく絵を取りに来ていないカメラを閉じる（描画ループが毎コマ呼ぶ）。
    /// 前は「別のカメラを開くとき」にしか閉じなかったので、クリップを消してもカメラが点いたままだった
    func closeIdle(now: Double = CACurrentMediaTime()) {
        lock.withLock {
            guard !sessions.isEmpty else { return }
            for (k, s) in sessions where now - s.used > Self.idleSeconds { s.stop(); sessions[k] = nil }
        }
    }

    /// 開いているカメラの数（テスト用）
    var openCount: Int { lock.withLock { sessions.count } }

    /// 機器の今の絵（無ければ nil）。どのスレッドからでも
    func frame(_ id: String) -> (MTLTexture, CVMetalTexture)? {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return nil }
        let now = CACurrentMediaTime()
        return lock.withLock {
            if sessions[id] == nil {
                guard let s = CameraSession(id: id) else { return nil }
                sessions[id] = s
            }
            sessions[id]?.used = now
            return sessions[id]?.frame()
        }
    }
}

/// ジェネレーター「カメラから」の、機器の選び方
struct CameraSourcePicker: View {
    @Binding var effect: Effect
    @ObservedObject private var cams = CameraInputs.shared
    @State private var devices: [CameraDevice] = CameraDevice.list()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("カメラ").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $effect.text) {
                    Text("（選ぶ）").tag("")
                    ForEach(devices) { d in Text(d.name).tag(d.id) }
                    if !effect.text.isEmpty && !devices.contains(where: { $0.id == effect.text }) {
                        Text("（今はつながっていない）").tag(effect.text)
                    }
                }
                .labelsHidden()
                Button { devices = CameraDevice.list() } label: { Image(systemName: "arrow.clockwise") }
                    .help("カメラ・キャプチャの一覧を更新")
            }
            switch cams.permission {
            case .notDetermined:
                Button("カメラの使用を許可する…") { cams.requestAccess() }
            case .denied, .restricted:
                HStack {
                    Label("カメラの使用が許可されていません", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    Button("システム設定を開く") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                }
            default:
                EmptyView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            devices = CameraDevice.list()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            devices = CameraDevice.list()
        }
    }
}
