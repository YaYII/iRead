import Foundation

/// 专用源：七猫小说网页版（qimao.com）
///
/// 三条链路（2026-11-21 实测，纯 HTTP、无签名、无登录）：
/// - 搜索：`/qimaoapi/api/search/result?keyword=`，明文 JSON，`data.search_list`
/// - 目录：`/qimaoapi/api/book/chapter-list?book_id=`，一次拿全量章节
/// - 正文：POST `/qimaoapi/api/book/chapter`（表单 `book_id` / `chapter_id`），返回 HTML 段落
///
/// **必须走移动站 `m.qimao.com`**：桌面站 `www.qimao.com` 会被阿里云 WAF 拦成
/// `acw_sc__v2` JS 校验页（返回 200 + HTML，JSON 接口全废），移动站同一套 qimaoapi 不受影响。
///
/// ## 关于「全本免费」的真实边界（重要，别再按「登录就能读」做）
///
/// 七猫确实不按章收费，但**免费是在它自己的 App 里**（看广告换阅读）。
/// 网页端对每本书只开放前面一段（实测 6~155 章），后面的章节在
/// `chapter-list` 里标 `is_vip=1`，而且不是「登录即可」：
///
/// - 移动站章节接口带完整登录 Cookie 仍返回 `is_login=0` + 一段密文；
/// - 桌面站会员章页面渲染后，正文区只有 canvas 画出的一小段试读，
///   页面上明写：「下载【七猫免费小说APP】，继续在APP内免费畅读全本内容」/
///   「在APP端开通会员，继续在电脑端无广告免费畅读」。
///
/// 也就是说后段章节的解锁条件是「App 内会员」，不是「登录」。本源因此
/// 只收网页端真正给得出正文的章节，`is_vip=1` 一律跳过并在简介里说明还差多少章，
/// 让用户在搜索结果页就能看到「可下 X / 共 Y 章」，自己决定下不下。
enum QimaoSource {

    static let host = "https://m.qimao.com"

    private static let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Referer": "https://m.qimao.com/",
        "Accept": "application/json, text/plain, */*"
    ]

    // MARK: - 搜索

    static func search(keyword: String, source: NovelSource) async throws -> [SearchResult] {
        let url = "\(host)/qimaoapi/api/search/result?keyword=\(encode(keyword))&page=1"
        let text = try await NovelHTTPClient.get(url, headers: headers).text
        try checkChallenge(text)
        guard let json = parseJSON(text),
              let data = json["data"] as? [String: Any],
              let items = data["search_list"] as? [[String: Any]] else {
            throw FetchError.format
        }
        return items.compactMap { item in
            guard let bookID = string(item["book_id"]), !bookID.isEmpty else { return nil }
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return SearchResult(
                title: title,
                author: (item["author"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                detailURL: "\(host)/shuku/\(bookID)",
                coverURL: item["image_link"] as? String,
                intro: item["intro"] as? String,
                sourceID: source.id,
                sourceName: source.name
            )
        }
    }

    // MARK: - 目录

    static func chapters(result: SearchResult, source: NovelSource) async throws -> NovelDetail {
        guard let bookID = firstMatch(#"shuku/(\d+)"#, in: result.detailURL, group: 1) else {
            throw FetchError.format
        }
        let url = "\(host)/qimaoapi/api/book/chapter-list?book_id=\(bookID)"
        let text = try await NovelHTTPClient.get(url, headers: headers).text
        try checkChallenge(text)
        guard let json = parseJSON(text),
              let data = json["data"] as? [String: Any],
              let items = data["chapters"] as? [[String: Any]] else {
            throw FetchError.format
        }

        // 目录按 index 递增返回，这里再排一次，防止个别书顺序错乱。
        let sorted = items.sorted { (number($0["index"]) ?? 0) < (number($1["index"]) ?? 0) }

        var chapters: [ChapterLink] = []
        var lockedCount = 0
        for item in sorted {
            // 后段章节网页端只给一小段 canvas 试读，直接跳过，避免整本下载到一半失败。
            if string(item["is_vip"]) == "1" {
                lockedCount += 1
                continue
            }
            guard let chapterID = string(item["id"]), !chapterID.isEmpty else { continue }
            let rawTitle = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(ChapterLink(
                index: chapters.count,
                title: rawTitle.isEmpty ? "第 \(chapters.count + 1) 章" : rawTitle,
                url: "\(host)/shuku/\(bookID)-\(chapterID)"
            ))
        }
        guard !chapters.isEmpty else {
            // 目录一条都没有 ≠ 一章都下不了：多半是书已下架或 ID 失效
            throw items.isEmpty ? FetchError.emptyCatalog : FetchError.lockedAll
        }

        var intro = (result.intro ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if lockedCount > 0 {
            intro += "\n\n（本书共 \(items.count) 章，网页端只开放 \(chapters.count) 章；其余 \(lockedCount) 章要在七猫 App 内读，本源未收录）"
        }
        return NovelDetail(
            title: result.title,
            author: result.author,
            intro: intro,
            coverURL: result.coverURL,
            detailURL: result.detailURL,
            sourceID: source.id,
            sourceName: source.name,
            chapters: chapters
        )
    }

    // MARK: - 章节规模（搜索结果列表用）

    /// 只取数量：搜索结果里显示「可下 X / 共 Y 章」。
    /// 口径与本源的 `chapters()` 保持一致：`is_vip=1` 属于网页端不开放的章节，
    /// 不管有没有登录都下不了（登录不是解锁条件，App 内会员才是）。
    static func stats(result: SearchResult) async throws -> ChapterStats {
        guard let bookID = firstMatch(#"shuku/(\d+)"#, in: result.detailURL, group: 1) else {
            throw FetchError.format
        }
        let url = "\(host)/qimaoapi/api/book/chapter-list?book_id=\(bookID)"
        let text = try await NovelHTTPClient.get(url, headers: headers).text
        try checkChallenge(text)
        guard let json = parseJSON(text),
              let data = json["data"] as? [String: Any],
              let items = data["chapters"] as? [[String: Any]] else {
            throw FetchError.format
        }
        let available = items.filter {
            string($0["is_vip"]) != "1" && !(string($0["id"]) ?? "").isEmpty
        }.count
        return ChapterStats(available: available, total: items.count)
    }

    // MARK: - 单章正文

    static func content(chapter: ChapterLink, source: NovelSource) async throws -> String {
        guard let bookID = firstMatch(#"shuku/(\d+)-"#, in: chapter.url, group: 1),
              let chapterID = firstMatch(#"shuku/\d+-(\d+)"#, in: chapter.url, group: 1) else {
            throw FetchError.format
        }
        let data = try await chapterData(bookID: bookID, chapterID: chapterID, referer: chapter.url)
        guard let raw = data["content"] as? String, !raw.isEmpty else { throw FetchError.format }

        // 后段章节接口只回一段密文（canvas 试读的来源），不是我们的解析问题，跳过而不是写乱码
        guard raw.contains("<") else { throw FetchError.locked }

        let decoded = WebText.htmlToText(raw)
        guard !decoded.isEmpty else { throw FetchError.empty }
        return decoded
    }

    /// 取单章接口的 data 段（含 content / chapter / is_login）。
    private static func chapterData(bookID: String, chapterID: String, referer: String) async throws -> [String: Any] {
        let url = "\(host)/qimaoapi/api/book/chapter"
        var headers = headers
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Origin"] = host
        headers["Referer"] = referer
        let body = "book_id=\(bookID)&chapter_id=\(chapterID)"
        let text = try await NovelHTTPClient.post(url, body: body, headers: headers).text
        try checkChallenge(text)
        guard let json = parseJSON(text),
              let data = json["data"] as? [String: Any] else {
            throw FetchError.format
        }
        return data
    }

    /// 取 `chapter-detail-article` 里的正文文本；取不到返回空串。
    private static func extractArticle(_ html: String) -> String {
        guard let start = html.range(of: "chapter-detail-article") else { return "" }
        let tail = html[start.upperBound...]
        guard let openEnd = tail.firstIndex(of: ">") else { return "" }
        guard let close = tail.range(of: "</div>", range: openEnd..<tail.endIndex) else { return "" }
        let inner = tail[openEnd..<close.lowerBound]
        return WebText.htmlToText(String(inner)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 内部工具

    private static func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let r = Range(match.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    /// 关键词里的 `&`、`+`、`#` 不能原样进 query，否则搜索词会被截断。
    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 阿里云 WAF 的人机校验页：HTTP 200 + HTML（`<textarea id="renderData">` / `acw_sc__v2`）。
    /// 这种情况下 JSON 解析必然失败，要报「风控」而不是「结构变化」，免得误判成规则失效。
    private static func checkChallenge(_ text: String) throws {
        if text.contains("renderData") || text.contains("acw_sc__v2") || text.contains("aliyun_waf") {
            throw FetchError.blocked
        }
    }

    enum FetchError: LocalizedError {
        case format
        case locked
        case lockedAll
        case blocked
        case empty
        case emptyCatalog

        var errorDescription: String? {
            switch self {
            case .format: return "七猫页面结构变化，解析失败"
            case .locked: return "这一章网页端未开放（七猫只在 App 内提供）"
            case .lockedAll: return "这本书网页端没开放正文（七猫只在 App 内提供）"
            case .blocked: return "七猫触发人机校验（阿里云 WAF），请稍后再试"
            case .empty: return "官网未返回正文"
            case .emptyCatalog: return "七猫没有返回这本书的目录，可能已下架，换一个书源试试"
            }
        }
    }
}
