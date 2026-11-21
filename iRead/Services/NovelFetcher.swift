import Foundation

/// 网络书源抓取引擎：按 NovelSource 的规则，把网页/JSON 解析成搜索结果、章节、正文。
/// 依赖 SelectorEngine 做取值，WebText 做清洗，NovelHTTPClient 做请求。
enum NovelFetcher {

    // MARK: - 搜索

    static func search(source: NovelSource, keyword: String) async throws -> [SearchResult] {
        if source.kind?.lowercased() == "github" {
            return try await GitHubBookSource.search(keyword: keyword, source: source)
        }
        if source.kind?.lowercased() == "fanqie" {
            return try await FanqieSource.search(keyword: keyword, source: source)
        }
        if source.kind?.lowercased() == "qimao" {
            return try await QimaoSource.search(keyword: keyword, source: source)
        }
        let rule = source.search
        let url = fill(rule.url, source: source, extras: ["key": encoded(keyword), "page": "1"])
        guard !url.isEmpty else { return [] }
        let resp = try await request(rule, url: url, source: source)

        let items = selectList(rule.list, from: resp.text, source: source)
        return items.compactMap { item in
            let title = field("title", rule: rule, from: item, source: source) ?? ""
            guard !title.isEmpty else { return nil }
            let author = field("author", rule: rule, from: item, source: source) ?? ""
            let rawURL = field("url", rule: rule, from: item, source: source) ?? ""
            let detailURL = fullURL(rawURL, prefix: rule.urlPrefix, source: source)
            guard !detailURL.isEmpty else { return nil }
            return SearchResult(
                title: title,
                author: author,
                detailURL: detailURL,
                coverURL: coverURL(rule, item: item, source: source),
                intro: field("intro", rule: rule, from: item, source: source),
                sourceID: source.id,
                sourceName: source.name
            )
        }
    }

    // MARK: - 章节目录

    static func chapters(result: SearchResult, source: NovelSource) async throws -> NovelDetail {
        if source.kind?.lowercased() == "github" {
            return try await GitHubBookSource.chapters(result: result, source: source)
        }
        if source.kind?.lowercased() == "fanqie" {
            return try await FanqieSource.chapters(result: result, source: source)
        }
        if source.kind?.lowercased() == "qimao" {
            return try await QimaoSource.chapters(result: result, source: source)
        }
        let rule = source.chapter
        let listURL = fill(rule.url, source: source, extras: [
            "url": encoded(result.detailURL),
            "key": encoded(result.title)
        ])
        let target = listURL.isEmpty ? result.detailURL : listURL
        let resp = try await request(rule, url: target, source: source)

        let items = selectList(rule.list, from: resp.text, source: source)
        var chapters = items.enumerated().compactMap { idx, item -> ChapterLink? in
            let title = field("title", rule: rule, from: item, source: source) ?? "第 \(idx + 1) 章"
            let rawURL = field("url", rule: rule, from: item, source: source) ?? ""
            let chapterURL = fullURL(rawURL, prefix: rule.urlPrefix, source: source)
            return ChapterLink(index: idx, title: title, url: chapterURL.isEmpty ? "\(idx)" : chapterURL)
        }
        if chapters.isEmpty {
            // 兜底：整页当一章，保证任何源都能下载
            chapters = [ChapterLink(index: 0, title: result.title, url: result.detailURL)]
        }

        // 详情规则（可选）：补书名/作者/简介/封面
        var title = result.title
        var author = result.author
        var intro = result.intro ?? ""
        var cover = result.coverURL
        let detailRule = source.detail
        if !detailRule.url.isEmpty {
            let dURL = fill(detailRule.url, source: source, extras: ["url": encoded(result.detailURL)])
            if let dResp = try? await request(detailRule, url: dURL, source: source) {
                title = field("title", rule: detailRule, from: dResp.text, source: source) ?? title
                author = field("author", rule: detailRule, from: dResp.text, source: source) ?? author
                intro = field("intro", rule: detailRule, from: dResp.text, source: source) ?? intro
                cover = coverURL(detailRule, item: dResp.text, source: source) ?? cover
            }
        }

        return NovelDetail(
            title: title,
            author: author,
            intro: intro,
            coverURL: cover,
            detailURL: result.detailURL,
            sourceID: source.id,
            sourceName: source.name,
            chapters: chapters
        )
    }

    // MARK: - 章节规模（搜索结果列表用）

    /// 搜索列表里提前显示章节数，方便判断同名书该下哪个源。
    /// 返回 nil 表示这个源给不出（整本 txt 的公版源）。
    static func chapterStats(result: SearchResult, source: NovelSource) async throws -> ChapterStats? {
        switch source.kind?.lowercased() {
        case "fanqie":
            return try await FanqieSource.stats(result: result)
        case "qimao":
            return try await QimaoSource.stats(result: result)
        case "github":
            return nil
        default:
            // 通用规则源：抓一次目录页数条目数（就是可下载章数）
            let detail = try await chapters(result: result, source: source)
            return ChapterStats(available: detail.chapters.count, total: detail.chapters.count)
        }
    }

    // MARK: - 正文（支持分页）

    static func content(chapter: ChapterLink, source: NovelSource) async throws -> String {
        if source.kind?.lowercased() == "fanqie" {
            return try await FanqieSource.content(chapter: chapter, source: source)
        }
        if source.kind?.lowercased() == "qimao" {
            return try await QimaoSource.content(chapter: chapter, source: source)
        }
        let rule = source.content
        var segments: [String] = []

        if let page = rule.page, page.max > 0 {
            var pageNum = page.start
            var fetched = 0
            while fetched < page.max {
                if pageNum > page.start, (pageNum - page.start) % page.step != 0 { pageNum += 1; continue }
                let url = fill(rule.url, source: source, extras: [
                    "url": encoded(chapter.url),
                    "page": String(pageNum),
                    "key": encoded(chapter.title)
                ])
                let text = try await request(rule, url: url, source: source).text
                let parts = cleanSegments(selectList(rule.list, from: text, source: source), rule: rule, source: source)
                if parts.isEmpty {
                    if page.stopWhenEmpty { break }
                } else {
                    segments.append(contentsOf: parts)
                }
                pageNum += 1
                fetched += 1
            }
        } else {
            let url = fill(rule.url, source: source, extras: [
                "url": encoded(chapter.url),
                "page": "1",
                "key": encoded(chapter.title)
            ])
            let target = url.isEmpty ? chapter.url : url
            let text = try await request(rule, url: target, source: source).text
            let parts = cleanSegments(selectList(rule.list, from: text, source: source), rule: rule, source: source)
            segments.append(contentsOf: parts)
        }

        if segments.isEmpty {
            // 规则没写正文选择器：整页转纯文本
            let url = fill(rule.url, source: source, extras: ["url": encoded(chapter.url), "page": "1"])
            let text = try await request(rule, url: url.isEmpty ? chapter.url : url, source: source).text
            return WebText.htmlToText(text)
        }
        let separator = rule.join ?? "\n\n"
        return WebText.cleanWhitespace(segments.joined(separator: separator))
    }

    /// 流式抓章：按章节顺序抓取并回调，供「边下边读」使用。
    /// - parameter batch: 每批章数，抓完一批立即回调一次（含该批所有章节文本）
    /// - parameter onBatch: 回调批次序号起点与章节文本；按顺序串行回调
    /// - parameter shouldPause: 返回 true 时暂停在下批之前等待（用于暂停/继续）
    /// - parameter shouldStop: 返回 true 时提前结束（取消）
    static func streamChapters(
        detail: NovelDetail,
        source: NovelSource,
        batch: Int = 4,
        onBatch: @escaping (Int, [(title: String, text: String)]) -> Void,
        shouldPause: @escaping () -> Bool,
        shouldStop: @escaping () -> Bool,
        waitUntilResumed: @escaping () async -> Void
    ) async throws {
        // GitHub 公版源是整本 txt，没有逐章结构，直接一次性给一章，由阅读器自己分章
        if source.kind?.lowercased() == "github" {
            if shouldStop() { throw FetchError.cancelled }
            let data = try await GitHubBookSource.fullText(detail: detail)
            guard let text = String(data: data, encoding: .utf8) else { throw FetchError.encode }
            onBatch(0, [(detail.title, text)])
            return
        }

        let chapters = detail.chapters
        var next = 0
        while next < chapters.count {
            if shouldStop() { throw FetchError.cancelled }
            // 暂停：在批次边界等待，不丢已抓章节
            while shouldPause() {
                if shouldStop() { throw FetchError.cancelled }
                await waitUntilResumed()
            }

            let end = min(next + batch, chapters.count)
            let slice = Array(chapters[next..<end])
            // 批内并发，按章内 offset 回填保序（task group 完成序是乱的）
            var texts = [String](repeating: "", count: slice.count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (offset, chapter) in slice.enumerated() {
                    group.addTask {
                        if shouldStop() { throw FetchError.cancelled }
                        let text = try await chapterText(chapter, source: source)
                        return (offset, text)
                    }
                }
                for try await (offset, text) in group {
                    texts[offset] = text
                }
            }
            let payload = zip(slice, texts).map { ($0.title, $1) }
            onBatch(next, payload)
            next = end
        }
    }

    /// 单章抓取：番茄/七猫个别章节可能到页面侧才报告锁定，跳过它，不让整本下载失败。
    private static func chapterText(_ chapter: ChapterLink, source: NovelSource) async throws -> String {
        do {
            return try await content(chapter: chapter, source: source)
        } catch let error as FanqieSource.FetchError {
            if case .locked = error {
                NSLog("[Fetcher] 跳过需授权章节：%@", chapter.title)
                return ""
            }
            throw error
        } catch let error as QimaoSource.FetchError {
            if case .locked = error {
                NSLog("[Fetcher] 跳过七猫会员章：%@", chapter.title)
                return ""
            }
            throw error
        }
    }

    /// 抓整本书，逐章串行拼成可导入的 TXT。
    static func fullText(
        detail: NovelDetail,
        source: NovelSource,
        onProgress: @escaping (Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws -> Data {
        // GitHub 公版源：整本 txt 直接下载，不需逐章拼接
        if source.kind?.lowercased() == "github" {
            if isCancelled() { throw FetchError.cancelled }
            let data = try await GitHubBookSource.fullText(detail: detail)
            onProgress(detail.chapters.count)
            return data
        }
        var body = "\(detail.title)\n作者：\(detail.author)\n\n"

        // 有界并发逐章抓取：站点单章 0.4~3s，串行 200 章要几分钟。
        // 用 6 并发把耗时压到十几秒；结果按章节下标回填，保证正文顺序。
        let chapters = detail.chapters
        // 番茄官网对高频请求较敏感，降到 3 并发，避免触发限流/验证码
        let concurrency = source.kind?.lowercased() == "fanqie" ? 3 : 6
        var texts = [String](repeating: "", count: chapters.count)
        var completed = 0  // 仅在 for-await 串行消费里递增，无需加锁

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var nextIndex = 0
            // 先塞满并发窗口
            while nextIndex < min(concurrency, chapters.count) {
                let idx = nextIndex
                group.addTask {
                    if isCancelled() { throw FetchError.cancelled }
                    let text = try await chapterText(chapters[idx], source: source)
                    return (idx, text)
                }
                nextIndex += 1
            }
            // 完成一个补一个
            for try await (idx, text) in group {
                texts[idx] = text
                completed += 1
                onProgress(completed)
                if nextIndex < chapters.count {
                    let idx2 = nextIndex
                    group.addTask {
                        if isCancelled() { throw FetchError.cancelled }
                        let text = try await chapterText(chapters[idx2], source: source)
                        return (idx2, text)
                    }
                    nextIndex += 1
                }
            }
        }

        for (i, chapter) in chapters.enumerated() {
            body += "\(chapter.title)\n\n\(texts[i])\n\n"
        }
        guard let data = body.data(using: .utf8) else { throw FetchError.encode }
        return data
    }

    enum FetchError: LocalizedError {
        case cancelled
        case encode
        var errorDescription: String? {
            switch self {
            case .cancelled: return "已取消"
            case .encode: return "文本编码失败"
            }
        }
    }

    // MARK: - 规则执行辅助

    private static func request(_ rule: RuleSection, url: String, source: NovelSource) async throws -> NovelHTTPClient.Response {
        var headers = source.headers ?? [:]
        if let h = rule.headers { headers.merge(h) { _, new in new } }
        let method = (rule.method ?? "GET").uppercased()
        if method == "POST", let body = rule.body {
            return try await NovelHTTPClient.post(url, body: body, headers: headers)
        }
        return try await NovelHTTPClient.get(url, headers: headers)
    }

    private static func selectList(_ selector: String?, from text: String, source: NovelSource) -> [String] {
        guard let selector, !selector.isEmpty else { return [text] }
        if source.isJSON {
            return SelectorEngine.jsonValues(text, path: selector)
        }
        return SelectorEngine.select(selector, from: text)
    }

    private static func field(_ name: String, rule: RuleSection, from item: String, source: NovelSource) -> String? {
        guard let selector = rule.fields?[name], !selector.isEmpty else { return nil }
        let values = source.isJSON
            ? SelectorEngine.jsonValues(item, path: selector)
            : SelectorEngine.select(selector, from: item)
        return values.first.map { WebText.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func cleanSegments(_ items: [String], rule: RuleSection, source: NovelSource) -> [String] {
        items.compactMap { item in
            var value = WebText.decodeEntities(item)
            if let cleanTail = rule.cleanTail, !cleanTail.isEmpty {
                value = SelectorEngine.first(cleanTail, from: value) ?? value
            }
            value = WebText.htmlToText(value)
            return value.isEmpty ? nil : value
        }
    }

    private static func coverURL(_ rule: RuleSection, item: String, source: NovelSource) -> String? {
        guard let selector = rule.fields?["cover"], !selector.isEmpty else { return nil }
        let values = source.isJSON
            ? SelectorEngine.jsonValues(item, path: selector)
            : SelectorEngine.select(selector, from: item)
        guard let raw = values.first else { return nil }
        return WebText.absolute(raw, base: source.baseURL)
    }

    private static func fullURL(_ raw: String, prefix: String?, source: NovelSource) -> String {
        if raw.isEmpty { return "" }
        if let prefix, !prefix.isEmpty, !raw.hasPrefix("http") {
            return WebText.absolute(prefix + raw, base: source.baseURL) ?? (prefix + raw)
        }
        return WebText.absolute(raw, base: source.baseURL) ?? raw
    }

    private static func fill(_ template: String, source: NovelSource, extras: [String: String]) -> String {
        var placeholders: [String: String] = ["host": source.baseURL]
        placeholders.merge(extras) { _, new in new }
        return WebText.fill(template, placeholders: placeholders)
    }

    private static func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
