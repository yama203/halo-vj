import AppKit
import Combine
import Sparkle
import SwiftUI

// 自動アップデート（Sparkle）：GitHub Releases に置いた appcast.xml を見て、新しい版があれば入れ替える。
// 本番中に急に窓が出ないよう、起動したとき以外に見つけた新しい版は、上部の小さなボタンで知らせるだけにする。

final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheck = false
    /// 見つけたけれど、まだ見せていない新しい版（上部のボタン用）
    @Published private(set) var pendingVersion: String?
    @Published var automaticallyChecks = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    private var controller: SPUStandardUpdaterController?
    private var bag: Set<AnyCancellable> = []

    /// .app から起動していて、更新の場所が書いてあるときだけ始める
    var isAvailable: Bool { controller != nil }

    func startIfNeeded() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller = c
        automaticallyChecks = c.updater.automaticallyChecksForUpdates
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.canCheck = v }.store(in: &bag)
    }

    func check() {
        pendingVersion = nil
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 起動したときに見つけたら、すぐ窓を出す。動いている途中に見つけたら、上部のボタンで知らせるだけ
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { pendingVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { pendingVersion = nil }

    func standardUserDriverWillFinishUpdateSession() { pendingVersion = nil }
}

/// アプリのメニューの「アップデートを確認…」
struct UpdateMenuItems: View {
    @ObservedObject var updater = AppUpdater.shared
    var body: some View {
        Button(L("アップデートを確認…")) { updater.check() }
            .disabled(!updater.canCheck)
    }
}

/// 上部の「新しい版」ボタン（動いている途中に新しい版を見つけたときだけ出る）
struct UpdateBadge: View {
    @ObservedObject var updater = AppUpdater.shared
    var body: some View {
        if let v = updater.pendingVersion {
            Button { updater.check() } label: {
                Label(L("新しい版 \(v)"), systemImage: "arrow.down.circle.fill").font(.system(size: 11))
            }
            .buttonStyle(.borderless).foregroundStyle(.green)
            .help(L("Halo VJ の新しい版があります。押すと中身を見て、入れるか決められます（本番中は後で）"))
        }
    }
}

/// 設定の窓の「アップデート」
struct UpdateSettingsSection: View {
    @ObservedObject var updater = AppUpdater.shared
    var body: some View {
        let info = Bundle.main.infoDictionary
        let ver = (info?["CFBundleShortVersionString"] as? String ?? "?") + L("（\(info?["CFBundleVersion"] as? String ?? "?")）")
        VStack(alignment: .leading, spacing: 6) {
            Text(L("今の版：\(ver)")).font(.system(size: 12))
            if updater.isAvailable {
                Toggle(L("新しい版を自動で確かめる（1 日 1 回）"), isOn: $updater.automaticallyChecks)
                Button(L("今すぐ確かめる")) { updater.check() }.disabled(!updater.canCheck)
            } else {
                Text(L("アップデートは .app から起動したときに使えます")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 確かめ用（VJ_UPDATE_TEST=記録のファイル）：窓を出さずに、見つけた版を落として入れ替え、開き直すまでを自動で進める

final class AutoUpdateTestDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    /// 確かめ用は開き直さない（開き直すと、ふだんの保存ファイルを使ってしまうので）
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }
    let logPath: String
    init(logPath: String) { self.logPath = logPath }
    private func log(_ s: String) {
        let line = "\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") \(s)\n"
        if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(toFile: logPath, atomically: true, encoding: .utf8) }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        log("permission"); reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { log("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("found \(appcastItem.displayVersionString) build \(appcastItem.versionString)"); reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { log("notfound \(error.localizedDescription)"); acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { log("error \(error.localizedDescription)"); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { log("download") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { log("extract") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { log("ready"); reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        log("installing terminated=\(applicationTerminated)")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { log("installed relaunched=\(relaunched)"); acknowledgement() }
    func dismissUpdateInstallation() {}
    func showUpdateInFocus() {}
}

extension AppUpdater {
    /// 確かめ用：起動したらすぐ確かめて、見つかれば入れる
    static func startTestIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["VJ_UPDATE_TEST"], !path.isEmpty,
              Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let driver = AutoUpdateTestDriver(logPath: path)
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        testRetain = (u, driver)
        do { try u.start() } catch { driver.showUpdaterError(error) {} ; return true }
        try? "".write(toFile: path + ".started", atomically: true, encoding: .utf8)
        u.checkForUpdates()
        return true
    }
}
private var testRetain: (SPUUpdater, AutoUpdateTestDriver)?
