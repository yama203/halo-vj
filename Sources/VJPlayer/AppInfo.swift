import Foundation

/// アプリの名前と、設定・キャッシュの置き場所。
/// （ソースコードの中の名前は VJPlayer のまま。画面と保存場所は Halo VJ）
enum AppInfo {
    static let name = "Halo VJ"

    /// ~/Library/Application Support/Halo VJ（以前の VJPlayer フォルダがあれば移す）
    static var supportDirectory: URL { directory(.applicationSupportDirectory, sub: nil) }

    /// ~/Library/Caches/Halo VJ（以前の VJPlayer フォルダがあれば移す）
    static var cacheDirectory: URL { directory(.cachesDirectory, sub: nil) }

    private static func directory(_ base: FileManager.SearchPathDirectory, sub: String?) -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: base, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let old = root.appendingPathComponent("VJPlayer", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            // 名前を変える前の設定・キャッシュを引き継ぐ
            try? fm.moveItem(at: old, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
