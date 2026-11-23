import Foundation
import CryptoKit

/// 本机影视库。和音乐库同构：索引 + 文件，播放过就进书架。
final class VideoStore: ObservableObject {
    static let shared = VideoStore()

    @Published private(set) var items: [VideoItem] = []

    let videoDir: URL
    private let indexURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        videoDir = documents.appendingPathComponent("Video", isDirectory: true)
        indexURL = videoDir.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
        load()
    }

    func item(id: String) -> VideoItem? {
        items.first { $0.id == id }
    }

    var downloaded: [VideoItem] { items.filter(\.isDownloaded) }
    var favorites: [VideoItem] { items.filter(\.isFavorite) }

    func localURL(for item: VideoItem) -> URL? {
        guard let file = item.localFile, !file.isEmpty else { return nil }
        let url = videoDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func playbackURL(for item: VideoItem) -> URL? {
        if let local = localURL(for: item) { return local }
        return URL(string: item.streamURL)
    }

    func downloadState(for item: VideoItem) -> MediaDownloader.DownloadState? {
        MediaDownloader.shared.state(for: "video:\(item.id)")
    }

    @discardableResult
    func remember(_ item: VideoItem) -> VideoItem {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var merged = items[index]
            merged.title = item.title
            merged.summary = item.summary
            merged.coverURL = item.coverURL ?? merged.coverURL
            merged.streamURL = item.streamURL
            merged.license = item.license
            merged.sourceName = item.sourceName
            merged.kind = item.kind
            items[index] = merged
            save()
            return merged
        }
        var fresh = item
        fresh.addedAt = Date()
        items.insert(fresh, at: 0)
        save()
        return fresh
    }

    func markDownloaded(_ id: String, file: String, bytes: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].localFile = file
        items[index].bytes = bytes
        save()
    }

    func notePlayed(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lastPlayedAt = Date()
        save()
    }

    func updateProgress(_ id: String, ratio: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = min(max(ratio, 0), 1)
        items[index].lastPlayedAt = Date()
        save()
    }

    func toggleFavorite(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFavorite.toggle()
        save()
    }

    func delete(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let file = items[index].localFile, !file.isEmpty {
            try? FileManager.default.removeItem(at: videoDir.appendingPathComponent(file))
        }
        items.remove(at: index)
        save()
    }

    /// 视频下载：m3u8 是切片清单，不能按单文件存，直接不提供下载
    func download(_ item: VideoItem, completion: (() -> Void)? = nil) {
        guard !item.isDownloaded, !item.streamURL.contains(".m3u8"),
              let url = URL(string: item.streamURL) else { return }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let destination = videoDir.appendingPathComponent(Self.fileName(for: item.id) + "." + ext)
        MediaDownloader.shared.download(
            id: "video:\(item.id)",
            url: url,
            destination: destination,
            kind: .video
        ) { [weak self] result in
            guard let self, case .success(let file) = result else { return }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            self.markDownloaded(item.id, file: file.lastPathComponent, bytes: bytes)
            completion?()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([VideoItem].self, from: data) else { return }
        items = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func fileName(for id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}
