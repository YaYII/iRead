import Foundation

// MARK: - 漫画图片

/// 一页漫画。`remote` 是下载地址，`file` 是落到本地后的文件名（未下载时为空串）。
struct ComicPage: Codable, Hashable, Identifiable {
    var remote: String
    /// 章节目录内的文件名，形如 `003.jpg`；空串表示还没下下来
    var file: String = ""
    /// 图片像素尺寸，下载时读一次存下来：阅读器靠它提前把位置撑好，
    /// 不用等图片解码完再跳一下布局。
    var width: Int = 0
    var height: Int = 0

    var id: String { remote }
    var isLocal: Bool { !file.isEmpty }

    /// 阅读器占位用的宽高比（未知时按常见条漫比例兜底）
    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 0.68 }
        return CGFloat(width) / CGFloat(height)
    }
}

// MARK: - 漫画章节

/// 一章漫画 = 一串图片。和文字书的 `Chapter` 不同，它自带图片清单：
/// 漫画按「话」下载，目录结构是 `<书>.comic/c<章节号>/<页码>.jpg`。
struct ComicChapter: Codable, Hashable, Identifiable {
    var index: Int
    var title: String
    /// 章节页地址，重新下载/补页时用
    var remoteURL: String = ""
    var pages: [ComicPage] = []

    var id: Int { index }

    var downloadedCount: Int { pages.reduce(0) { $0 + ($1.isLocal ? 1 : 0) } }
    var isDownloaded: Bool { !pages.isEmpty && downloadedCount == pages.count }
    var progress: Double {
        guard !pages.isEmpty else { return 0 }
        return Double(downloadedCount) / Double(pages.count)
    }

    /// 目录里显示的短标题：去掉「第 12 话」这类前面会重复的信息
    var shortTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "第 \(index + 1) 话" : trimmed
    }
}

// MARK: - 漫画元数据

/// 存在 `<书>.comic/meta.json`。不放 library.json：几百话 × 每话几十页，
/// 图片清单会把这本索引撑到几 MB，而书架只需要书名和进度。
struct ComicMeta: Codable {
    var version: Int = 1
    /// 来自哪个书源（重建书架条目时用）
    var sourceID: String = ""
    /// 搜索结果里的详情页地址，用于「同一本书不重复入库」
    var remoteURL: String = ""
    var chapters: [ComicChapter] = []

    var downloadedChapters: Int { chapters.reduce(0) { $0 + ($1.isDownloaded ? 1 : 0) } }
    var totalPages: Int { chapters.reduce(0) { $0 + $1.pages.count } }
    var downloadedPages: Int { chapters.reduce(0) { $0 + $1.downloadedCount } }

    /// 第一张已经下到本地的图，书架封面直接用它（比远程封面可靠，也不费流量）
    var firstLocalPage: (chapter: Int, file: String)? {
        for chapter in chapters {
            if let page = chapter.pages.first(where: { $0.isLocal }) {
                return (chapter.index, page.file)
            }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey { case version, sourceID, remoteURL, chapters }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL) ?? ""
        chapters = try c.decodeIfPresent([ComicChapter].self, forKey: .chapters) ?? []
    }
}
