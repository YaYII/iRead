import Foundation
import CryptoKit
import AVFoundation

/// 本机音乐库。
///
/// 和书一样只存一份索引 + 文件：`Documents/Music/library.json` 管元数据，
/// `Documents/Music/Cache/<sha>.mp3` 是缓存下来的音频。
/// 在线播放过一次就会落盘（「自动保存」），下次直接从本机播，不再走网络。
final class MusicStore: ObservableObject {
    static let shared = MusicStore()

    @Published private(set) var tracks: [MusicTrack] = []

    let musicDir: URL
    let cacheDir: URL
    private let indexURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        musicDir = documents.appendingPathComponent("Music", isDirectory: true)
        cacheDir = musicDir.appendingPathComponent("Cache", isDirectory: true)
        indexURL = musicDir.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 查询

    func track(id: String) -> MusicTrack? {
        tracks.first { $0.id == id }
    }

    var cachedTracks: [MusicTrack] {
        tracks.filter(\.isCached)
    }

    var favorites: [MusicTrack] {
        tracks.filter(\.isFavorite)
    }

    func localURL(for track: MusicTrack) -> URL? {
        guard let file = track.cachedFile, !file.isEmpty else { return nil }
        let url = cacheDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 播放列表里的实际地址：已缓存播本地，否则播远程
    func playbackURL(for track: MusicTrack) -> URL? {
        if let local = localURL(for: track) { return local }
        return URL(string: track.streamURL)
    }

    func cacheState(for track: MusicTrack) -> MediaDownloader.DownloadState? {
        MediaDownloader.shared.state(for: "music:\(track.id)")
    }

    // MARK: - 写入

    /// 播放即入库：搜到的歌不点「收藏」也会进「我的音乐」，
    /// 否则用户下次想再听同一首要重新搜一遍。
    @discardableResult
    func remember(_ track: MusicTrack) -> MusicTrack {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            var merged = tracks[index]
            merged.title = track.title
            merged.artist = track.artist
            merged.duration = track.duration
            merged.streamURL = track.streamURL
            merged.license = track.license
            merged.licenseURL = track.licenseURL
            merged.sourceID = track.sourceID
            merged.sourceName = track.sourceName
            tracks[index] = merged
            save()
            return merged
        }
        var fresh = track
        fresh.addedAt = Date()
        fresh.hue = track.hue == 0.08 ? MediaArt.hue(for: track.id) : track.hue
        tracks.insert(fresh, at: 0)
        save()
        return fresh
    }

    func markCached(_ id: String, file: String, bytes: Int64) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].cachedFile = file
        tracks[index].cachedBytes = bytes
        save()
    }

    func notePlayed(_ id: String) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].lastPlayedAt = Date()
        tracks[index].playCount += 1
        save()
    }

    func toggleFavorite(_ id: String) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].isFavorite.toggle()
        save()
    }

    func delete(_ id: String) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        if let file = tracks[index].cachedFile, !file.isEmpty {
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(file))
        }
        tracks.remove(at: index)
        save()
    }

    // MARK: - 自动缓存

    /// 边听边存：播过的歌落盘，下次直接从本机播，不再走网络。
    ///
    /// 回调在主线程，结果里给的是**本地文件**，播放器据此起播 ——
    /// ccMixter 校验 Referer，AVPlayer 直连必然 403，只能等落盘再播。
    func autoCache(_ track: MusicTrack, completion: ((Result<URL, Error>) -> Void)? = nil) {
        if let local = localURL(for: track) {
            completion?(.success(local))
            return
        }
        guard !track.streamURL.isEmpty, let url = URL(string: track.streamURL) else {
            completion?(.failure(MediaDownloader.DownloadError.empty))
            return
        }
        let destination = cacheDir.appendingPathComponent(Self.fileName(for: track.id))
        MediaDownloader.shared.download(
            id: "music:\(track.id)",
            url: url,
            destination: destination,
            kind: .audio,
            headers: track.requestHeaders
        ) { [weak self] result in
            guard let self, case .success(let file) = result else {
                completion?(result)
                return
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            self.markCached(track.id, file: file.lastPathComponent, bytes: bytes)
            self.refineDuration(track.id, file: file)
            completion?(result)
        }
    }

    /// 曲库给的时长经常是空的（列表里全是 `--:--`）。
    /// 落盘后读一次真实时长补上，只补缺失的，不覆盖已有值。
    private func refineDuration(_ id: String, file: URL) {
        guard let index = tracks.firstIndex(where: { $0.id == id }),
              tracks[index].duration <= 0 else { return }
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: file)
            guard let value = try? await asset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(value)
            guard seconds.isFinite, seconds > 0 else { return }
            await MainActor.run {
                guard let index = self.tracks.firstIndex(where: { $0.id == id }),
                      self.tracks[index].duration <= 0 else { return }
                self.tracks[index].duration = seconds
                self.save()
            }
        }
    }

    // MARK: - 落盘

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([MusicTrack].self, from: data) else { return }
        tracks = list
        sanitizeCache()
    }

    /// 自愈：早期版本把 403 的 10 字节错误页当成了 mp3 存进来，
    /// 索引里还标着「已缓存」，导致点播放永远没声音。
    /// 启动时把不可播的缓存文件连同索引标记一起清掉，让下次播放重新下载。
    private func sanitizeCache() {
        let fm = FileManager.default
        var changed = false
        for index in tracks.indices {
            guard let file = tracks[index].cachedFile, !file.isEmpty else { continue }
            let url = cacheDir.appendingPathComponent(file)
            let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if bytes < 64 * 1024 {
                try? fm.removeItem(at: url)
                tracks[index].cachedFile = nil
                tracks[index].cachedBytes = 0
                changed = true
            }
        }
        if changed { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 文件名只由 id 决定：同一首歌无论从哪个入口下都落到同一个文件
    private static func fileName(for id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32)) + ".mp3"
    }
}
