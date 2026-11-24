import Foundation
import AVFoundation
import CryptoKit
import UIKit

/// 把自己拥有的音频文件导进音乐库。
///
/// 为什么要有这条路径：免费又合法的在线曲库只有 CC 那一批（器乐、电子为主），
/// 想听华语流行只能用自己的文件 —— 在别的平台买了歌，下载到手机上导进来听，
/// 这个用法完全合法，也是唯一不碰版权的办法。
///
/// 三个入口共用这一套：
/// - `importFile(at:)`：「文件」App 选文件（安全作用域 URL）
/// - `importData(_:fileName:)`：WiFi 传歌
/// - `scanInbox()`：Finder / 「文件」App 直接把歌丢进 iRead 的 Documents
///
/// 整个类钉在主线程：`MusicStore` 是 `@Published`，在后台线程改会触发
/// 「Publishing changes from background threads」；真正重的文件拷贝用
/// `Task.detached` 丢出去，不占主线程。
@MainActor
final class LocalMusicImport {

    enum ImportError: LocalizedError {
        case unsupported(String)
        case emptyFile
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext):
                return ext.isEmpty ? "不认识的音频格式" : "不支持 \(ext.uppercased()) 格式"
            case .emptyFile: return "文件是空的"
            case .copyFailed(let name): return "写入失败：\(name)"
            }
        }
    }

    /// AVFoundation 能解的常见格式。ogg / opus 只在系统支持的容器里能放，
    /// 放不了会在播放时失败，导入阶段先放行 —— 报错比直接拒收更好懂。
    nonisolated static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "caf", "alac", "mp2", "ogg", "opus"
    ]

    nonisolated static func isAudioFile(_ name: String) -> Bool {
        supportedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: - 入口

    /// 「文件」App 选来的 URL 带安全作用域，读之前必须 start，读完 stop
    @discardableResult
    static func importFile(at url: URL) async throws -> MusicTrack {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try await importFile(url: url, originalName: url.lastPathComponent)
    }

    /// WiFi 传歌：浏览器把整段 body 发过来，没有文件 URL 可用
    @discardableResult
    static func importData(_ data: Data, fileName: String) async throws -> MusicTrack {
        guard isAudioFile(fileName) else {
            throw ImportError.unsupported((fileName as NSString).pathExtension)
        }
        guard data.count > 0 else { throw ImportError.emptyFile }

        let name = (fileName as NSString).lastPathComponent
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((name as NSString).pathExtension)
        do {
            try data.write(to: temp, options: .atomic)
        } catch {
            throw ImportError.copyFailed(name)
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        return try await importFile(url: temp, originalName: name)
    }

    /// 扫描 Documents 根目录里被拖进来的音频。
    ///
    /// `UIFileSharingEnabled` 是开着的，Finder 和「文件」App 都能直接往 iRead 里丢文件，
    /// 但丢进来只是躺在沙盒里，不扫一遍永远不会出现在书架上。
    @discardableResult
    static func scanInbox() async -> (imported: Int, failed: Int) {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let imports = documents.appendingPathComponent("Imports", isDirectory: true)

        func audioFiles(in dir: URL) -> [URL] {
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return files.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && isAudioFile($0.lastPathComponent)
            }
        }

        var candidates = audioFiles(in: imports)

        // Documents 根目录也是用户可见的落点，但里面还住着 App 自己的东西
        // （历史版本把语音自检的 wav 写在根目录）。按命名认得出是自检产物的直接跳过；
        // 体积只做「空壳文件」兜底，不能拿大小当判据 —— 一首 8 秒的 mp3 也就一百多 KB。
        for url in audioFiles(in: documents) {
            let name = url.lastPathComponent
            if name.hasPrefix("merged-") || name.hasPrefix("zh_CN-") || name.hasPrefix("yue-") {
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size >= Self.inboxMinimumBytes else {
                NSLog("[MusicImport] skip tiny audio %@ (%d B)", name, size)
                continue
            }
            candidates.append(url)
        }
        guard !candidates.isEmpty else { return (0, 0) }

        var imported = 0, failed = 0
        for url in candidates {
            do {
                let track = try await importFile(url: url, originalName: url.lastPathComponent)
                // 导入成功才删原件：复制失败时用户的文件还在
                try? fm.removeItem(at: url)
                imported += 1
                NSLog("[MusicImport] inbox %@ → %@ · %@", url.lastPathComponent, track.title, track.artist)
            } catch {
                failed += 1
                NSLog("[MusicImport] inbox failed %@: %@", url.lastPathComponent,
                      error.localizedDescription)
            }
        }
        return (imported, failed)
    }

    /// 根目录扫描的体积下限：只用来排除传输中断留下的空壳文件。
    /// 不要拿它当「是不是歌」的判据 —— 短音频本来就小。
    private static let inboxMinimumBytes = 8 * 1024

    // MARK: - 主流程

    /// 拷贝 + 读标签 + 入库。`originalName` 决定兜底歌名，`url` 只负责内容。
    private static func importFile(url: URL, originalName: String) async throws -> MusicTrack {
        let ext = (originalName as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ImportError.unsupported(ext) }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard size > 0 else { throw ImportError.emptyFile }

        // 同一个文件重复导入要落到同一条记录：文件名 + 字节数足够稳定，
        // 又不用把几十 MB 读一遍算哈希
        let id = "local-" + fingerprint(name: originalName, size: size)
        let fileName = id + "." + ext
        let destination = MusicStore.shared.localDir.appendingPathComponent(fileName)

        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: url, to: destination)
                }.value
            } catch {
                throw ImportError.copyFailed(originalName)
            }
        }

        let parsed = parseName(originalName)
        let meta = await readMetadata(url: destination, fallbackTitle: parsed.title)
        let title = meta.title.isEmpty ? parsed.title : meta.title
        let artist = meta.artist.isEmpty ? parsed.artist : meta.artist

        // 同一首歌换个文件名再导一次，不该在书架上变成两张一样的卡。
        // 判据用「标题 + 歌手 + 时长」：文件名靠不住（「01. 晴天.mp3」「周杰伦-晴天.mp3」
        // 都可能是同一首），时长差 2 秒内认为是同一份录音。
        if let existing = MusicStore.shared.tracks.first(where: { candidate in
            candidate.isLocal
                && candidate.title == title
                && candidate.artist == artist
                && abs(candidate.duration - meta.duration) < 2
        }) {
            // 刚拷进来的这份是多余的。同 id 时 destination 就是它自己的文件，不能删
            if existing.localFile != fileName {
                try? FileManager.default.removeItem(at: destination)
            }
            NSLog("[MusicImport] duplicate %@ · %@，沿用已有记录", title, artist)
            return existing
        }

        var artworkFile: String?
        if let data = meta.artwork, let image = UIImage(data: data),
           let jpeg = image.jpegData(compressionQuality: 0.82) {
            let name = id + ".jpg"
            let artURL = MusicStore.shared.artworkDir.appendingPathComponent(name)
            if (try? jpeg.write(to: artURL, options: .atomic)) != nil {
                artworkFile = name
            }
        }

        let track = MusicTrack(
            id: id,
            title: title,
            artist: artist,
            duration: meta.duration,
            streamURL: "",
            license: "本机文件",
            licenseURL: "",
            sourceID: MusicCatalogSource.local.rawValue,
            sourceName: "本机导入",
            hue: MediaArt.hue(for: id)
        )

        var stored = track
        stored.localFile = fileName
        stored.artworkFile = artworkFile
        stored.cachedBytes = size

        return MusicStore.shared.remember(stored)
    }

    /// 读容器里的标签。读不到就返回空，交给文件名兜底 —— 导入不能因为没标签就失败。
    private static func readMetadata(url: URL, fallbackTitle: String) async -> Metadata {
        var result = Metadata(title: "", artist: "", duration: 0, artwork: nil)
        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { result.duration = seconds }
        }

        guard let items = try? await asset.load(.commonMetadata) else { return result }
        for item in items {
            guard let key = item.commonKey?.rawValue else { continue }
            switch key {
            case "title":
                if let value = try? await item.load(.stringValue),
                   let text = tidy(value) { result.title = text }
            case "artist":
                if let value = try? await item.load(.stringValue),
                   let text = tidy(value) { result.artist = text }
            case "artwork":
                result.artwork = try? await item.load(.dataValue)
            default:
                break
            }
        }
        return result
    }

    // MARK: - 文件名兜底

    /// 「周杰伦 - 晴天.mp3」→ 歌手/歌名；带序号的「01. 晴天」把序号剥掉。
    /// 中文歌文件名这两种写法占了绝大多数，标签缺了也不至于满屏乱码。
    nonisolated static func parseName(_ fileName: String) -> (title: String, artist: String) {
        var base = (fileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉开头的曲目号：01 / 01. / 01 - / 01_
        if let range = base.range(of: #"^\d{1,3}\s*[.\-_、]\s*"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)

        for separator in [" - ", " – ", " — ", "-"] {
            let parts = base.components(separatedBy: separator)
            if parts.count == 2 {
                let left = parts[0].trimmingCharacters(in: .whitespaces)
                let right = parts[1].trimmingCharacters(in: .whitespaces)
                if !left.isEmpty, !right.isEmpty {
                    return (title: right, artist: left)
                }
            }
        }
        return (title: base.isEmpty ? "未命名" : base, artist: "未知歌手")
    }

    nonisolated private static func tidy(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    nonisolated private static func fingerprint(name: String, size: Int64) -> String {
        let digest = SHA256.hash(data: Data("\(name)|\(size)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(20))
    }

    private struct Metadata {
        var title: String
        var artist: String
        var duration: Double
        var artwork: Data?
    }
}

/// 内嵌封面的小缓存。
///
/// 书架是网格，`body` 一刷新就会重读几十张图；`NSCache` 命中一次之后
/// 不再碰磁盘，滚动才不会一卡一卡的。图片本身很小（压过 0.82 的 JPEG）。
@MainActor
enum ArtworkStore {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for track: MusicTrack) -> UIImage? {
        guard let file = track.artworkFile, !file.isEmpty else { return nil }
        let key = file as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = MusicStore.shared.artworkDir.appendingPathComponent(file)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
