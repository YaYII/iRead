import Foundation
import SwiftUI

/// 音乐条目。
///
/// 只存「能播」需要的最小集合：流地址、许可、来源。
/// 歌词、专辑这些开源曲库大多没有，硬造字段只会让列表空空荡荡。
struct MusicTrack: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var duration: Double
    /// 在线播放地址（ccMixter 直链 mp3）
    var streamURL: String
    var license: String
    var licenseURL: String
    var sourceID: String
    var sourceName: String

    /// 已缓存到本机的文件名（Documents/Music/Cache/ 下），nil = 还没下完
    var cachedFile: String? = nil
    var cachedBytes: Int64 = 0
    /// 本机导入的原始音频文件名（Documents/Music/Local/ 下）。
    ///
    /// 和 `cachedFile` 是两回事：缓存是「听过一次就存一份副本」，删了还能重下；
    /// 导入是用户自己的文件，删了就是真删。所以不能合并成一个字段。
    var localFile: String? = nil
    /// 从音频标签里抽出来的封面（Documents/Music/Artwork/ 下），没有就退回程序化封面
    var artworkFile: String? = nil
    var isFavorite: Bool = false
    var addedAt: Date? = nil
    var lastPlayedAt: Date? = nil
    var playCount: Int = 0
    /// 没有封面图时的程序化封面色相（0...1）。存下来而不是每次算，
    /// 保证同一首歌在搜索结果、播放器、书架里颜色一致。
    var hue: Double = 0.08

    var isCached: Bool { !(cachedFile ?? "").isEmpty }

    /// 用户自己导进来的（不是从在线曲库下来的）
    var isLocal: Bool { !(localFile ?? "").isEmpty }

    /// 只要有本地文件就不该再走网络 —— 缓存和导入都算
    var hasLocalAudio: Bool { isCached || isLocal }


    var source: MusicCatalogSource? { MusicCatalogSource(rawValue: sourceID) }

    /// 拉音频时要带的请求头（防盗链）。
    /// 缓存和播放共用同一套，避免「下载成功但播放 403」这类不一致。
    var requestHeaders: [String: String] {
        source?.requestHeaders ?? MusicCatalogSource.defaultHeaders
    }

    var durationText: String {
        guard duration > 0, duration.isFinite else { return "--:--" }
        let total = Int(duration.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, duration, streamURL, license, licenseURL
        case sourceID, sourceName, cachedFile, cachedBytes, isFavorite
        case localFile, artworkFile
        case addedAt, lastPlayedAt, playCount, hue
    }

    init(
        id: String,
        title: String,
        artist: String,
        duration: Double,
        streamURL: String,
        license: String,
        licenseURL: String,
        sourceID: String,
        sourceName: String,
        hue: Double = 0.08
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
        self.streamURL = streamURL
        self.license = license
        self.licenseURL = licenseURL
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.hue = hue
    }

    /// 手写解码：`hue / playCount` 是后加的字段，老 library.json 里没有，
    /// 合成解码不会套用属性默认值，缺键会整条失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamURL) ?? ""
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        licenseURL = try c.decodeIfPresent(String.self, forKey: .licenseURL) ?? ""
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        cachedFile = try c.decodeIfPresent(String.self, forKey: .cachedFile)
        cachedBytes = try c.decodeIfPresent(Int64.self, forKey: .cachedBytes) ?? 0
        localFile = try c.decodeIfPresent(String.self, forKey: .localFile)
        artworkFile = try c.decodeIfPresent(String.self, forKey: .artworkFile)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0.08
    }
}

/// 音乐列表来源。
/// - ccMixter / Jamendo：在线开源曲库，免注册（Jamendo 要免费 client_id）；
/// - local：用户自己的文件（「文件」App、WiFi 传歌、Finder 拖进来都算）。
///   它不联网、也没有许可条款，界面上不列进「曲库」清单。
enum MusicCatalogSource: String, CaseIterable, Identifiable {
    case ccmixter
    case jamendo
    case local

    var id: String { rawValue }

    /// 「曲库」清单只列在线源，本机导入不是一个曲库
    static var online: [MusicCatalogSource] { [.ccmixter, .jamendo] }

    var title: String {
        switch self {
        case .ccmixter: return "ccMixter"
        case .jamendo: return "Jamendo"
        case .local: return "本机导入"
        }
    }

    var siteURL: String {
        switch self {
        case .ccmixter: return "https://ccmixter.org"
        case .jamendo: return "https://www.jamendo.com"
        case .local: return ""
        }
    }

    var note: String {
        switch self {
        case .ccmixter: return "Creative Commons 混音社区，免注册直连"
        case .jamendo: return "需要免费 client_id，填在音乐页底部"
        case .local: return "你自己的音频文件，不联网、不上传"
        }
    }

    static let defaultHeaders: [String: String] = [
        "User-Agent": "iRead/1.0 (iPhone; iOS)"
    ]

    /// ccMixter 的音频直链做了防盗链：请求头里必须带**带结尾斜杠**的来源页，
    /// 不带（或写成 `https://ccmixter.org`）一律 403 + 10 字节 HTML。
    /// 实测 `Origin` 单独加也没用，只认 `Referer`；UA 无所谓。
    ///
    /// 这也意味着 AVPlayer 直连 remote 是过不去的 —— 只能「先下后播」。
    var requestHeaders: [String: String] {
        var headers = Self.defaultHeaders
        switch self {
        case .ccmixter:
            headers["Referer"] = "https://ccmixter.org/"
        case .jamendo, .local:
            break
        }
        return headers
    }
}

/// 播放器的循环方式
enum MusicRepeatMode: String, CaseIterable {
    case off
    case all
    case one

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var next: MusicRepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var title: String {
        switch self {
        case .off: return "不循环"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }
}

/// 程序化封面：开源曲库多数没有专辑图。
/// 用稳定的色相 + 首字 + 音符画一张，比灰色占位体面，也不会每次刷新变色。
enum MediaArt {
    /// FNV-1a：Swift 的 hashValue 每次启动都变，不能拿来配色。
    static func hue(for id: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Double(hash % 360) / 360.0
    }

    static func gradient(_ hue: Double, dark: Bool = false) -> LinearGradient {
        let h = hue.truncatingRemainder(dividingBy: 1)
        let top = Color(hue: h, saturation: dark ? 0.42 : 0.52, brightness: dark ? 0.52 : 0.92)
        let bottom = Color(hue: (h + 0.06).truncatingRemainder(dividingBy: 1),
                           saturation: dark ? 0.52 : 0.62,
                           brightness: dark ? 0.34 : 0.72)
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
