import Foundation
import SwiftUI

/// 动漫 / 视频。两类共用一张表、一个播放器，只在检索源上分开：
/// 动漫走开源动画片单，视频走公共领域影像与用户添加的直链。
enum VideoKind: String, Codable, CaseIterable {
    case anime
    case video

    var title: String {
        switch self {
        case .anime: return "动漫"
        case .video: return "视频"
        }
    }
}

struct VideoItem: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var summary: String
    var coverURL: String?
    /// 在线播放地址：mp4 / mov / m3u8
    var streamURL: String
    var duration: Double
    var license: String
    var sourceName: String
    var kind: VideoKind

    /// 已下载到本机的文件名（Documents/Video/ 下）
    var localFile: String? = nil
    var bytes: Int64 = 0
    var isFavorite: Bool = false
    var addedAt: Date? = nil
    var lastPlayedAt: Date? = nil
    /// 上次看到的位置（0...1），进播放器自动接上
    var progress: Double = 0
    var hue: Double = 0.55

    var isDownloaded: Bool { !(localFile ?? "").isEmpty }

    var durationText: String {
        guard duration > 0, duration.isFinite else { return "" }
        let total = Int(duration.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, summary, coverURL, streamURL, duration, license
        case sourceName, kind, localFile, bytes, isFavorite
        case addedAt, lastPlayedAt, progress, hue
    }

    init(
        id: String,
        title: String,
        summary: String,
        coverURL: String?,
        streamURL: String,
        duration: Double = 0,
        license: String,
        sourceName: String,
        kind: VideoKind,
        hue: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.coverURL = coverURL
        self.streamURL = streamURL
        self.duration = duration
        self.license = license
        self.sourceName = sourceName
        self.kind = kind
        self.hue = hue ?? MediaArt.hue(for: id)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamURL) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        kind = VideoKind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "video") ?? .video
        localFile = try c.decodeIfPresent(String.self, forKey: .localFile)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? MediaArt.hue(for: id)
    }
}
