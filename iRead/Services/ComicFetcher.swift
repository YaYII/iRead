import Foundation

/// 漫画抓取：搜索 / 目录 / 图片清单。
///
/// 和文字书共用书源体系（同一个 `NovelSource`，`media = "comic"` 区分），
/// 但图片清单的解析和正文完全不同，所以单独一层：
/// 文字书的 `content.list` 切出来的是段落，漫画切出来的是图片地址。
enum ComicFetcher {

    // MARK: - 搜索 / 目录

    static func search(source: NovelSource, keyword: String) async throws -> [SearchResult] {
        if source.kind?.lowercased() == "mangadex" {
            return try await MangaDexSource.search(keyword: keyword, source: source)
        }
        // 通用规则源：漫画站和文字站的搜索页结构一样（列表 + 书名 + 链接），直接复用
        return try await NovelFetcher.search(source: source, keyword: keyword)
    }

    static func detail(result: SearchResult, source: NovelSource) async throws -> NovelDetail {
        if source.kind?.lowercased() == "mangadex" {
            return try await MangaDexSource.chapters(result: result, source: source)
        }
        return try await NovelFetcher.chapters(result: result, source: source)
    }

    // MARK: - 图片清单

    static func pages(chapter: ChapterLink, source: NovelSource) async throws -> [ComicPage] {
        if source.kind?.lowercased() == "mangadex" {
            return try await MangaDexSource.pages(chapterID: chapter.url)
        }
        return try await rulePages(chapter: chapter, source: source)
    }

    /// 通用规则源取图：
    /// - `content.list` 用选择器切出每一项（可以是 `<img>` 整块，也可以已经是地址）
    /// - 每项再用 `content.fields["url"]` 取一次（可选）
    /// - 最后统一从 `src / data-src / data-original` 或正则里捞出图片地址
    ///
    /// 规则没写 `list` 时兜底扫整页 HTML 里的图片地址 —— 大部分漫画站一章一页、
    /// 图片直接铺在正文里，这样用户只填搜索和目录规则也能看。
    private static func rulePages(chapter: ChapterLink, source: NovelSource) async throws -> [ComicPage] {
        let rule = source.content
        let url = fill(rule.url.isEmpty ? "{url}" : rule.url, source: source, extras: [
            "url": chapter.url,
            "page": "1",
            "key": chapter.title
        ])
        let target = url.isEmpty ? chapter.url : url
        let resp = try await request(rule, url: target, source: source)

        var rawItems: [String]
        if let list = rule.list, !list.isEmpty {
            rawItems = source.isJSON
                ? SelectorEngine.jsonValues(resp.text, path: list)
                : SelectorEngine.select(list, from: resp.text)
        } else {
            rawItems = [resp.text]
        }

        // 每项再用 fields["url"] 收一次（有的规则 list 切的是卡片，地址在卡片里）
        if let urlSelector = rule.fields?["url"], !urlSelector.isEmpty {
            rawItems = rawItems.flatMap { item in
                source.isJSON
                    ? SelectorEngine.jsonValues(item, path: urlSelector)
                    : SelectorEngine.select(urlSelector, from: item)
            }
        }

        var seen = Set<String>()
        let pages: [ComicPage] = rawItems.compactMap { item in
            guard let address = imageAddress(from: item, base: resp.finalURL) else { return nil }
            guard seen.insert(address).inserted else { return nil }
            return ComicPage(remote: address)
        }
        guard !pages.isEmpty else { throw ComicFetchError.noImages }
        return pages
    }

    /// 把一条「可能是 HTML 块、可能是相对路径、可能是带参数的地址」统一成绝对图片地址。
    private static func imageAddress(from raw: String, base: String) -> String? {
        var value = WebText.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // 懒加载图：src 常是占位图，真实地址在 data-src / data-original 里
        if value.hasPrefix("<") {
            for attr in ["data-original", "data-src", "data-lazy-src", "data-echo", "src"] {
                if let found = SelectorEngine.attribute(attr, in: value), !found.isEmpty {
                    value = found
                    break
                }
            }
        }

        // 还不是地址：从文本里捞第一个图片链接（有些站把地址写在 style / 脚本里）
        let lower = value.lowercased()
        if !lower.hasPrefix("http") && !value.hasPrefix("//") && !value.hasPrefix("/") {
            let pattern = #"https?://[^\s"'<>]+?\.(?:jpg|jpeg|png|webp|gif|bmp)[^\s"'<>]*"#
            guard let found = WebText.captures(in: value, pattern: pattern, group: 0).first else { return nil }
            value = found
        }

        guard let absolute = WebText.absolute(value, base: base), !absolute.isEmpty else { return nil }
        // 明显不是图片的（广告脚本、占位 svg）直接丢掉
        let bad = [".js", ".css", ".svg", "loading", "blank.gif", "spacer"]
        if bad.contains(where: { absolute.lowercased().hasSuffix($0) || absolute.lowercased().contains($0) }) {
            return nil
        }
        return absolute
    }

    // MARK: - 下载单张图

    /// 下载单张图片。`source` 只用来决定请求头：MangaDex 的图床必须带自定义 UA，
    /// 带浏览器 UA 会被 Cloudflare 静默回 404（详见 `MangaDexSource.appUserAgent`）。
    static func downloadImage(_ url: String, source: NovelSource? = nil) async throws -> Data {
        var headers: [String: String]?
        if source?.kind?.lowercased() == "mangadex" {
            headers = ["User-Agent": MangaDexSource.appUserAgent]
        }
        do {
            let resp = try await NovelHTTPClient.get(url, headers: headers)
            guard !resp.data.isEmpty else { throw ComicFetchError.emptyImage }
            return resp.data
        } catch {
            NSLog("[Comic] 图片下载失败 %@ → %@", url, "\(error)")
            throw error
        }
    }

    // MARK: - 请求辅助

    private static func request(
        _ rule: RuleSection,
        url: String,
        source: NovelSource
    ) async throws -> NovelHTTPClient.Response {
        var headers = source.headers ?? [:]
        if let extra = rule.headers { headers.merge(extra) { _, new in new } }
        if (rule.method ?? "GET").uppercased() == "POST", let body = rule.body {
            return try await NovelHTTPClient.post(url, body: body, headers: headers)
        }
        return try await NovelHTTPClient.get(url, headers: headers)
    }

    private static func fill(_ template: String, source: NovelSource, extras: [String: String]) -> String {
        var placeholders: [String: String] = ["host": source.baseURL]
        placeholders.merge(extras) { _, new in new }
        return WebText.fill(template, placeholders: placeholders)
    }

    enum ComicFetchError: LocalizedError {
        case noImages
        case emptyImage
        case chapterUnavailable

        var errorDescription: String? {
            switch self {
            case .noImages: return "没能从这一话里解析出图片，可能是书源规则需要调整"
            case .emptyImage: return "图片下载为空"
            case .chapterUnavailable: return "这一话还没下载"
            }
        }
    }
}
