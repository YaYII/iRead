import Foundation

/// MangaDex 专用漫画源。
///
/// 为什么单独写一个 `kind`，而不是纯规则源：它的链路是三步且带派生参数 ——
/// 搜索拿 manga id → `feed` 拿 chapter id → `at-home/server/{chapterId}` 拿
/// 图片服务器地址、hash 和文件名，最后自己拼成图片 URL。静态规则 DSL
/// 表达不了「拿上一步的返回值当下一步的输入」，所以按番茄/七猫的做法走专用实现。
///
/// 接口都是公开的，无需登录；官方建议自定义 User-Agent 并控制在 5 请求/秒以内，
/// 下载端因此把并发压在 3。
enum MangaDexSource {

    private static let api = "https://api.mangadex.org"
    private static let uploads = "https://uploads.mangadex.org"

    /// 请求 API 和图片时专用的 User-Agent。
    ///
    /// MangaDex 的 edge 会对「长得像浏览器」的 UA 回一个 JS 校验页
    /// （302 → `mangadex.org/edge/challenge`，正文是 HTML），JSON 解析必然失败；
    /// 它官方也要求调用方用可识别的自定义 UA。所以这里显式覆盖
    /// `NovelHTTPClient` 全局那份 Safari UA。
    ///
    /// 图片服务器（`*.mangadex.network`）更隐蔽：带 Safari UA 时不报错也不挑战，
    /// 而是对**除前几张以外**的请求直接回 404（实测同一 URL 用 curl 或换 UA 就是 200）。
    /// 表现是章节只能下下来开头几张，其余全失败，看起来特别像「图源不全」。
    static let appUserAgent = "iRead/1.0 (iOS; https://github.com/YaYII/iRead)"

    /// 中文优先：zh 是简体/通用，zh-hk 是港台译本，两个都要。
    private static let chineseLanguages = ["zh", "zh-hk"]

    // MARK: - 搜索

    static func search(keyword: String, source: NovelSource) async throws -> [SearchResult] {
        var results = try await searchOnce(keyword: keyword, chineseOnly: true, source: source)
        // 有些作品只有英文/日文译本；中文过滤后一本都不剩时退回全语言，
        // 否则用户搜得到却什么都看不到，比看到外文更莫名其妙。
        if results.isEmpty {
            results = try await searchOnce(keyword: keyword, chineseOnly: false, source: source)
        }
        return results
    }

    private static func searchOnce(
        keyword: String,
        chineseOnly: Bool,
        source: NovelSource
    ) async throws -> [SearchResult] {
        var items: [URLQueryItem] = [
            .init(name: "title", value: keyword),
            .init(name: "limit", value: "20"),
            .init(name: "order[relevance]", value: "desc"),
            .init(name: "includes[]", value: "cover_art"),
            .init(name: "includes[]", value: "author"),
            .init(name: "contentRating[]", value: "safe"),
            .init(name: "contentRating[]", value: "suggestive")
        ]
        if chineseOnly {
            for lang in chineseLanguages {
                items.append(.init(name: "availableTranslatedLanguage[]", value: lang))
            }
        }
        let data = try await get("/manga", query: items)
        let list = try decode(MDList<MDManga>.self, from: data, path: "/manga")
        return list.data.compactMap { manga in
            let title = preferredTitle(manga)
            guard !title.isEmpty else { return nil }
            return SearchResult(
                title: title,
                author: authorName(manga) ?? "",
                detailURL: manga.id,
                coverURL: coverURL(manga),
                intro: preferredDescription(manga),
                sourceID: source.id,
                sourceName: source.name
            )
        }
    }

    // MARK: - 目录

    static func chapters(result: SearchResult, source: NovelSource) async throws -> NovelDetail {
        // result.detailURL 是 manga id（搜索页直接存的 id，不是网页地址）
        let mangaID = result.detailURL
        var list = try await feed(mangaID: mangaID, languages: chineseLanguages)
        if list.isEmpty {
            list = try await feed(mangaID: mangaID, languages: nil)
        }
        let chapters = normalize(list)
        guard !chapters.isEmpty else { throw MangaDexError.noChapters }

        return NovelDetail(
            title: result.title,
            author: result.author,
            intro: result.intro ?? "",
            coverURL: result.coverURL,
            detailURL: mangaID,
            sourceID: source.id,
            sourceName: source.name,
            chapters: chapters
        )
    }

    private static func feed(mangaID: String, languages: [String]?) async throws -> [MDChapter] {
        var items: [URLQueryItem] = [
            .init(name: "limit", value: "500"),
            .init(name: "order[volume]", value: "asc"),
            .init(name: "order[chapter]", value: "asc"),
            .init(name: "includeEmptyPages", value: "0"),
            .init(name: "includeExternalUrl", value: "0"),
            .init(name: "includeFuturePublishAt", value: "0")
        ]
        for lang in languages ?? [] {
            items.append(.init(name: "translatedLanguage[]", value: lang))
        }
        let data = try await get("/manga/\(mangaID)/feed", query: items)
        let list = try decode(MDList<MDChapter>.self, from: data, path: "feed")
        return list.data
    }

    /// 同一话常有多个汉化组上传，按章节号去重（中文优先），再按章节号排序。
    /// 章节号是字符串（可能有 "12.5"），排序必须按数值，否则「第 10 话」会排到「第 2 话」前面。
    private static func normalize(_ feed: [MDChapter]) -> [ChapterLink] {
        let sorted = feed.sorted { lhs, rhs in
            let l = Double(lhs.attributes.chapter ?? "") ?? .greatestFiniteMagnitude
            let r = Double(rhs.attributes.chapter ?? "") ?? .greatestFiniteMagnitude
            if l != r { return l < r }
            return languageRank(lhs.attributes.translatedLanguage) < languageRank(rhs.attributes.translatedLanguage)
        }
        var seen = Set<String>()
        var links: [ChapterLink] = []
        for chapter in sorted {
            let key = chapter.attributes.chapter ?? chapter.id
            guard seen.insert(key).inserted else { continue }
            guard (chapter.attributes.pages ?? 0) > 0 else { continue }
            links.append(ChapterLink(
                index: links.count,
                title: chapterTitle(chapter, fallbackIndex: links.count),
                url: chapter.id
            ))
        }
        return links
    }

    private static func chapterTitle(_ chapter: MDChapter, fallbackIndex: Int) -> String {
        let number = chapter.attributes.chapter?.trimmingCharacters(in: .whitespaces)
        let name = chapter.attributes.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let number, !number.isEmpty {
            // "12.5" 这种半话保留小数，别四舍五入成一话
            return name.isEmpty ? "第 \(number) 话" : "第 \(number) 话 · \(name)"
        }
        if let volume = chapter.attributes.volume, !volume.isEmpty {
            return name.isEmpty ? "第 \(volume) 卷" : "第 \(volume) 卷 · \(name)"
        }
        return name.isEmpty ? "第 \(fallbackIndex + 1) 话" : name
    }

    private static func languageRank(_ code: String?) -> Int {
        switch code {
        case "zh": return 0
        case "zh-hk": return 1
        default: return 2
        }
    }

    // MARK: - 图片

    /// 一次拿到整话的图片地址。`/data/` 是原图，`/data-saver/` 是压缩图；
    /// 下载到本机是长期离线看，选原图，字更清楚。
    static func pages(chapterID: String) async throws -> [ComicPage] {
        let data = try await get("/at-home/server/\(chapterID)", query: [])
        let server = try decode(MDAtHome.self, from: data, path: "at-home")
        guard !server.chapter.data.isEmpty else { throw MangaDexError.noPages }
        return server.chapter.data.map { file in
            ComicPage(remote: "\(server.baseUrl)/data/\(server.chapter.hash)/\(file)")
        }
    }

    private static func coverURL(_ manga: MDManga) -> String? {
        guard let cover = manga.relationships?.first(where: { $0.type == "cover_art" }),
              let file = cover.attributes?.fileName else { return nil }
        return "\(uploads)/covers/\(manga.id)/\(file).512.jpg"
    }

    // MARK: - 辅助

    private static func preferredTitle(_ manga: MDManga) -> String {
        let title = manga.attributes.title
        let altTitles = manga.attributes.altTitles ?? []
        // 顺序很重要：`title` 里常同时有 en 和 ja-ro，如果先遍历 title 的
        // 全部候选键，英文名会抢在 altTitles 的中文名前面（"Demon Slayer" 而不是「滅鬼之刃」）。
        // 所以先把「所有能拿到中文名的地方」找完，再退到外文。
        for key in chineseLanguages {
            if let value = title[key], !value.isEmpty { return value }
        }
        for alt in altTitles {
            for key in chineseLanguages {
                if let value = alt[key], !value.isEmpty { return value }
            }
        }
        for key in ["ja-ro", "ja", "en"] {
            if let value = title[key], !value.isEmpty { return value }
        }
        for alt in altTitles {
            if let value = alt.values.first, !value.isEmpty { return value }
        }
        return title.values.first ?? ""
    }

    private static func preferredDescription(_ manga: MDManga) -> String? {
        guard let description = manga.attributes.description else { return nil }
        for key in chineseLanguages + ["en"] {
            if let value = description[key], !value.isEmpty {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return nil
    }

    private static func authorName(_ manga: MDManga) -> String? {
        let names = (manga.relationships ?? [])
            .filter { $0.type == "author" || $0.type == "artist" }
            .compactMap { $0.attributes?.name }
        return names.first
    }

    private static func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var comp = URLComponents(string: api + path)
        if !query.isEmpty { comp?.queryItems = query }
        guard let url = comp?.url else { throw MangaDexError.badURL }
        do {
            let resp = try await NovelHTTPClient.get(
                url.absoluteString,
                headers: ["User-Agent": appUserAgent]
            )
            return resp.data
        } catch {
            NSLog("[MangaDex] GET %@ 失败：%@", url.absoluteString, "\(error)")
            throw error
        }
    }

    /// 统一解码。失败时把开头一小段响应打进日志，并把「返回的是 HTML」
    /// 单独识别成被校验拦截 —— 两者对用户来说的处置完全不同。
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let head = String(decoding: data.prefix(1), as: UTF8.self)
            NSLog("[MangaDex] %@ 解析失败：%@\n响应开头：%@",
                  path, "\(error)", String(decoding: data.prefix(300), as: UTF8.self))
            throw head == "<" ? MangaDexError.blocked : MangaDexError.decode
        }
    }

    enum MangaDexError: LocalizedError {
        case badURL
        case decode
        case blocked
        case noChapters
        case noPages

        var errorDescription: String? {
            switch self {
            case .badURL: return "漫画源地址无效"
            case .decode: return "漫画源返回格式有变化，暂时无法解析"
            case .blocked: return "MangaDex 要求浏览器校验，稍后重试或换个网络"
            case .noChapters: return "这本漫画没有可阅读的章节"
            case .noPages: return "这一话没有可下载的图片"
            }
        }
    }

    // MARK: - 接口结构

    private struct MDList<T: Decodable>: Decodable {
        let data: [T]
    }

    private struct MDManga: Decodable {
        let id: String
        let attributes: Attributes
        let relationships: [Relationship]?

        struct Attributes: Decodable {
            let title: [String: String]
            let altTitles: [[String: String]]?
            let description: [String: String]?
            let availableTranslatedLanguages: [String]?
        }

        struct Relationship: Decodable {
            let type: String
            let attributes: Attributes?

            struct Attributes: Decodable {
                let name: String?
                let fileName: String?
            }
        }
    }

    private struct MDChapter: Decodable {
        let id: String
        let attributes: Attributes

        struct Attributes: Decodable {
            let volume: String?
            let chapter: String?
            let title: String?
            let pages: Int?
            let translatedLanguage: String?
        }
    }

    private struct MDAtHome: Decodable {
        let baseUrl: String
        let chapter: Chapter

        struct Chapter: Decodable {
            let hash: String
            let data: [String]
        }
    }
}
