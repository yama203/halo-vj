import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// 右下「ソース」タブ：Mac のフォルダの動画を一覧して、グリッドへドラッグで置く。
/// フォルダの登録はアプリの設定（プロジェクトには入らない）
final class SourceBrowser: ObservableObject {
    static let shared = SourceBrowser()

    /// 登録したフォルダ
    @Published private(set) var roots: [URL] = []
    /// 今見ているフォルダ（登録したフォルダの中）
    @Published private(set) var current: URL?
    @Published private(set) var subfolders: [URL] = []
    @Published private(set) var files: [URL] = []
    @Published private(set) var loading = false

    private let rootsKey = "sourceFolders"
    private let currentKey = "sourceCurrent"

    private init() {
        let d = UserDefaults.standard
        roots = (d.stringArray(forKey: rootsKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if let c = d.string(forKey: currentKey), FileManager.default.fileExists(atPath: c),
           roots.contains(where: { c.hasPrefix($0.path) }) {
            open(URL(fileURLWithPath: c, isDirectory: true))
        } else if let r = roots.first {
            open(r)
        }
    }

    /// いま見ているフォルダが入っている登録フォルダ
    var currentRoot: URL? {
        guard let c = current else { return nil }
        return roots.filter { c.path == $0.path || c.path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    /// 登録フォルダから今のフォルダまでの道のり（登録フォルダ → … → 今）
    var trail: [URL] {
        guard let root = currentRoot, var c = current else { return [] }
        var out = [c]
        while c.path != root.path {
            c = c.deletingLastPathComponent()
            out.insert(c, at: 0)
            if c.path == "/" { break }
        }
        return out
    }

    func addFolderWithPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.message = L("素材の入っているフォルダを選ぶ（中のフォルダもたどれます）")
        guard p.runModal() == .OK else { return }
        for u in p.urls where !roots.contains(where: { $0.path == u.path }) { roots.append(u) }
        saveRoots()
        if let u = p.urls.first { open(u) }
    }

    func removeRoot(_ u: URL) {
        roots.removeAll { $0.path == u.path }
        saveRoots()
        if currentRoot == nil || currentRoot?.path == u.path {
            if let r = roots.first { open(r) } else { current = nil; subfolders = []; files = [] }
        }
    }

    private func saveRoots() {
        UserDefaults.standard.set(roots.map(\.path), forKey: rootsKey)
    }

    /// フォルダを開く（中のフォルダと動画を読む）
    func open(_ dir: URL) {
        current = dir
        UserDefaults.standard.set(dir.path, forKey: currentKey)
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (dirs, movies) = Self.list(dir)
            DispatchQueue.main.async {
                guard self.current == dir else { return }
                self.subfolders = dirs
                self.files = movies
                self.loading = false
            }
        }
    }

    func reload() { if let c = current { open(c) } }

    /// フォルダの中身：フォルダと動画（名前順。隠しファイルは除く）
    static func list(_ dir: URL) -> ([URL], [URL]) {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        var dirs: [URL] = [], movies: [URL] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if v?.isDirectory == true && v?.isPackage != true {
                dirs.append(u)
            } else if isMovie(u) || StillImage.isImage(u) {
                movies.append(u)
            }
        }
        let byName: (URL, URL) -> Bool = { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (dirs.sorted(by: byName), movies.sorted(by: byName))
    }

    static func isMovie(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .movie) || t.conforms(to: .video)
    }
}

/// 動画の小さなコマ（なぞると早送りで見られる）と長さ。作ったものは覚えておく
final class SourceThumbs: @unchecked Sendable {
    static let shared = SourceThumbs()
    static let frameCount = 6

    final class Thumb {
        let frames: [CGImage]
        let duration: Double
        init(frames: [CGImage], duration: Double) { self.frames = frames; self.duration = duration }
    }

    private let cache = NSCache<NSURL, Thumb>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    init() { cache.countLimit = 300 }

    func cached(_ u: URL) -> Thumb? { cache.object(forKey: u as NSURL) }

    func load(_ u: URL, done: @escaping (Thumb?) -> Void) {
        if let t = cached(u) { done(t); return }
        queue.addOperation { [cache] in
            if StillImage.isImage(u) {
                // 静止画：1 コマだけ（長さは 0）。GIF などの動く画像は、なぞって見られるようにコマを間引いて持つ
                let thumb: Thumb?
                if let a = StillImage.loadAnimation(u, maxPixels: 240) {
                    let n = Self.frameCount
                    let pick = (0..<n).map { a.frames[min(a.frames.count - 1, $0 * a.frames.count / n)] }
                    thumb = Thumb(frames: pick, duration: a.duration)
                } else {
                    thumb = StillImage.load(u, maxPixels: 320).map { Thumb(frames: [$0], duration: 0) }
                }
                if let thumb { cache.setObject(thumb, forKey: u as NSURL) }
                DispatchQueue.main.async { done(thumb) }
                return
            }
            let asset = AVURLAsset(url: u)
            let dur = CMTimeGetSeconds(asset.duration)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 240, height: 135)
            let tol = CMTime(seconds: dur.isFinite ? max(dur / 20, 0.1) : 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceBefore = tol
            gen.requestedTimeToleranceAfter = tol
            let n = Self.frameCount
            var frames: [CGImage] = []
            for k in 0..<n {
                let t = dur.isFinite && dur > 0 ? dur * (Double(k) + 0.5) / Double(n) : 0
                if let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                    frames.append(img)
                }
            }
            let thumb = frames.isEmpty ? nil : Thumb(frames: frames, duration: dur.isFinite ? dur : 0)
            if let thumb { cache.setObject(thumb, forKey: u as NSURL) }
            DispatchQueue.main.async { done(thumb) }
        }
    }
}

// MARK: - 画面

struct SourcePanel: View {
    @ObservedObject var src = SourceBrowser.shared
    @AppStorage("sourceColumns") private var sourceColumns = 3
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // フォルダの切り替え・追加
            HStack(spacing: 6) {
                Menu {
                    ForEach(src.roots, id: \.path) { r in
                        Button(r.lastPathComponent) { src.open(r) }
                    }
                    if !src.roots.isEmpty { Divider() }
                    Button(L("フォルダを追加…")) { src.addFolderWithPanel() }
                    if let r = src.currentRoot {
                        Button(L("「\(r.lastPathComponent)」を一覧から外す")) { src.removeRoot(r) }
                    }
                } label: {
                    Label(src.currentRoot?.lastPathComponent ?? L("フォルダを選ぶ"), systemImage: "folder")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    src.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(src.current == nil)
                .help(L("読み直す"))
                Picker("", selection: $sourceColumns) {
                    Text(L("大")).tag(2)
                    Text(L("中")).tag(3)
                    Text(L("小")).tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help(L("サムネイルの大きさ"))
            }

            if src.current == nil {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(L("素材のフォルダを登録すると、中の動画・画像がここに並びます。\nグリッドへドラッグして置けます"))
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L("フォルダを追加…")) { src.addFolderWithPanel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 今の場所（クリックで戻る）
                let trail = src.trail
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(Array(trail.enumerated()), id: \.element.path) { i, u in
                            if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                            Button(u.lastPathComponent) { src.open(u) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: i == trail.count - 1 ? .semibold : .regular))
                                .foregroundStyle(i == trail.count - 1 ? Color.primary : Color.secondary)
                        }
                    }
                }
                .scrollIndicators(.never)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("名前で探す"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        let dirs = src.subfolders.filter(matches)
                        if !dirs.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                                ForEach(dirs, id: \.path) { d in
                                    Button { src.open(d) } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                                            Text(d.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 8)
                                        .frame(height: 28)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        let movies = src.files.filter(matches)
                        let n = min(max(sourceColumns, 2), 4)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: n), spacing: 6) {
                            ForEach(movies, id: \.path) { u in
                                SourceTile(url: u, small: n >= 4)
                            }
                        }
                        if movies.isEmpty && dirs.isEmpty && !src.loading {
                            Text(query.isEmpty ? L("このフォルダには動画・画像がありません") : L("見つかりません"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 20)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        // 検索欄に勝手に入力カーソルが入ると Esc（ブラックアウト）などが効かなくなるので外しておく
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    }

    private func matches(_ u: URL) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || u.lastPathComponent.localizedCaseInsensitiveContains(q)
    }
}

/// 動画 1 つ：サムネイル（左右になぞると中身を早送りで見られる）・名前・長さ。ドラッグでグリッドへ、ダブルクリックでプレビュー
private struct SourceTile: View {
    let url: URL
    var small = false
    @State private var thumb: SourceThumbs.Thumb?
    @State private var skim: Int?
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .bottomTrailing) {
                    Color.black
                    if let thumb, !thumb.frames.isEmpty {
                        let i = min(skim ?? 0, thumb.frames.count - 1)
                        Image(decorative: thumb.frames[i], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: g.size.width, height: g.size.height)
                            .clipped()
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let thumb, thumb.duration > 0 {
                        Text(Self.time(thumb.duration))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 3)
                            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                            .padding(3)
                    }
                    // なぞっている位置
                    if let s = skim, let thumb, thumb.frames.count > 1 {
                        Rectangle().fill(Color.white.opacity(0.8))
                            .frame(width: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .offset(x: g.size.width * (CGFloat(s) + 0.5) / CGFloat(thumb.frames.count) - 1)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let n = thumb?.frames.count ?? 0
                        skim = n > 0 ? min(max(Int(p.x / max(g.size.width, 1) * CGFloat(n)), 0), n - 1) : nil
                    case .ended:
                        skim = nil
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: small ? 9 : 10, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(height: small ? 16 : 18)
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3)))
        .onAppear {
            if thumb == nil { SourceThumbs.shared.load(url) { thumb = $0 } }
        }
        .onTapGesture(count: 2) { showPreview = true }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(L("\(url.lastPathComponent)\nグリッドの枠へドラッグして置く。左右になぞると中身を早送りで見られる。ダブルクリックでプレビュー（音なし）"))
        .popover(isPresented: $showPreview, arrowEdge: .leading) {
            SourcePreview(url: url)
        }
        .contextMenu {
            Button(L("プレビュー（音なし）")) { showPreview = true }
            Button(L("Finder で表示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// ダブルクリックのプレビュー：音なしでくり返し再生（会場に音が出ないように）
private struct SourcePreview: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var image: CGImage?
    private var isImage: Bool { StillImage.isImage(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if isImage && ["gif", "png", "apng", "webp"].contains(url.pathExtension.lowercased()) {
                    // 動く画像はそのまま動かす（macOS の画像表示）
                    AnimatedImageView(url: url)
                } else if isImage {
                    if let img = image {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.black
                    }
                } else if let player {
                    VideoPlayer(player: player)
                } else {
                    Color.black
                }
            }
            .frame(width: 480, height: 270)
            .background(Color.black)
            Text(url.lastPathComponent + (isImage ? "" : L("（音なし）")))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .onAppear {
            if isImage {
                let u = url
                DispatchQueue.global(qos: .userInitiated).async {
                    let img = StillImage.load(u, maxPixels: 1600)
                    DispatchQueue.main.async { image = img }
                }
                return
            }
            let p = AVQueuePlayer()
            p.isMuted = true
            looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            looper = nil
            player = nil
        }
    }
}

/// GIF などを動かして見せる（プレビュー用）
private struct AnimatedImageView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.image = NSImage(contentsOf: url)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {}
}
