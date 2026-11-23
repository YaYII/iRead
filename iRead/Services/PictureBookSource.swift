import Foundation

/// 儿童绘本源：Book Dash。
///
/// 为什么选它：所有书都是 CC BY 4.0，官网直接给出整本内页大图，
/// 不用登录、不用 key，境内能连上（2026-11 实测）。绘本的内页本身就是图片，
/// 正好复用漫画那套「按话缓存 + 图片阅读器」，不需要另写一个 PDF 渲染器。
///
/// 数据入口是 WordPress REST（`/wp-json/wp/v2/books`），
/// 内页图从书目页 HTML 里抽 `*_interior_spreads_*.jpg`，去掉尺寸后缀取原图。
enum PictureBookSource {

    enum BookDashError: LocalizedError {
        case badResponse(Int)
        case empty
        case noPages

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "绘本馆返回 HTTP \(code)"
            case .empty: return "绘本馆没有返回书目"
            case .noPages: return "这本书没有取到内页图片"
            }
        }
    }

    private static let restBase = "https://bookdash.org/wp-json/wp/v2/books"
    private static let site = "https://bookdash.org"
    /// languages 分类 id：621 = English，643 = Wordless（无字绘本）
    private static let readableLanguages = "621,643"

    // MARK: - 搜索

    static func search(keyword: String) async throws -> [SearchResult] {
        var components = URLComponents(string: restBase)!
        var items = [
            URLQueryItem(name: "per_page", value: "30"),
            URLQueryItem(name: "_embed", value: "1"),
            URLQueryItem(name: "orderby", value: "date"),
            URLQueryItem(name: "order", value: "desc"),
            // 只取英文（621）和无字（643）绘本。
            // Book Dash 同一个故事有十几种南非语言的译本，最新上传的往往是
            // 文达语、聪加语这类我们完全读不了的版本，不过滤的话首页全是它。
            URLQueryItem(name: "languages", value: Self.readableLanguages)
        ]
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "search", value: trimmed))
        }
        components.queryItems = items

        guard let url = components.url else { throw BookDashError.badResponse(0) }
        let data = try await get(url)

        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BookDashError.empty
        }

        var results: [SearchResult] = []
        for book in list {
            guard let link = book["link"] as? String else { continue }
            let title = decodeEntities((book["title"] as? [String: Any])?["rendered"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            // 默认列表里混着大量手语版（标题带 SASL）和盲文版。
            // 用户没主动搜 SASL 时先给普通版，找书页不至于一屏全是同一本书的改编。
            let lowered = title.lowercased()
            if trimmed.isEmpty, lowered.contains("sasl") { continue }

            let excerpt = stripTags(decodeEntities(
                (book["excerpt"] as? [String: Any])?["rendered"] as? String ?? ""
            ))
            let cover = featuredCover(book)

            results.append(SearchResult(
                title: title,
                author: "Book Dash",
                detailURL: link,
                coverURL: cover,
                intro: excerpt.isEmpty ? "CC BY 4.0 开源绘本" : excerpt,
                sourceID: "builtin-bookdash",
                sourceName: "Book Dash 绘本"
            ))
        }

        guard !results.isEmpty else { throw BookDashError.empty }
        NSLog("[PictureBook] search '%@' -> %d 本", trimmed, results.count)
        return results
    }

    // MARK: - 详情

    static func detail(result: SearchResult) async throws -> NovelDetail {
        guard let pageURL = URL(string: result.detailURL) else { throw BookDashError.badResponse(0) }
        let data = try await get(pageURL)
        let html = String(data: data, encoding: .utf8) ?? ""

        let title = result.title
        let author = metaContent(html, property: "book:author") ?? "Book Dash"
        let intro = result.intro ?? ""
        let pages = pageURLs(in: html, cover: result.coverURL)
        NSLog("[PictureBook] detail '%@' -> %d 页", title, pages.count)

        return NovelDetail(
            title: title,
            author: author.isEmpty ? "Book Dash" : author,
            intro: intro + "\n\n开源绘本，CC BY 4.0，可在本机离线阅读。",
            coverURL: result.coverURL,
            detailURL: result.detailURL,
            sourceID: result.sourceID,
            sourceName: result.sourceName,
            chapters: [
                ChapterLink(
                    index: 0,
                    title: pages.isEmpty ? "全本绘本" : "全本绘本 · \(pages.count) 页",
                    url: result.detailURL
                )
            ]
        )
    }

    // MARK: - 内页

    static func pages(bookURL: String) async throws -> [ComicPage] {
        guard let url = URL(string: bookURL) else { throw BookDashError.badResponse(0) }
        let data = try await get(url)
        let html = String(data: data, encoding: .utf8) ?? ""
        let urls = pageURLs(in: html, cover: nil)
        guard !urls.isEmpty else { throw BookDashError.noPages }
        NSLog("[PictureBook] pages '%@' -> %d 张", url.lastPathComponent, urls.count)
        return urls.map { ComicPage(remote: $0) }
    }

    // MARK: - 解析

    /// 从书目页抽内页大图。
    ///
    /// 站点改过版，两套结构都得认：
    /// - 现在（2026-11 实测）：整本书塞在 `read-book` 弹层里，
    ///   一串 `<a href="原图">` + `<img data-src="缩略图">`，DOM 顺序就是页序；
    /// - 老版：正文里直接排 `*_interior_spreads_3.jpg`，还带 428w/768w 尺寸变体。
    ///
    /// 新版优先。它给的是 `<a href>` 上的原图，不用再去尺寸后缀，也不怕命名规则变。
    private static func pageURLs(in html: String, cover: String?) -> [String] {
        if let block = galleryBlock(html) {
            let urls = originalImages(in: block)
            if !urls.isEmpty {
                // 新版把封面也放在画廊第一张，不用再补，补了会重复
                return urls
            }
        }

        let legacy = legacySpreads(in: html)
        guard let cover, !cover.isEmpty, !legacy.contains(cover) else { return legacy }
        return [cover] + legacy
    }

    /// 截出 `jsLazyLoadImgContainer` 这个画廊容器。
    /// 容器内只有 `<a>`/`<img>`，没有嵌套 div，所以遇到的第一个 `</div>` 就是结尾。
    private static func galleryBlock(_ html: String) -> Substring? {
        guard let anchor = html.range(of: "jsLazyLoadImgContainer") else { return nil }
        let rest = html[anchor.lowerBound...]
        guard let end = rest.firstRange(of: "</div>") else { return nil }
        return rest[..<end.lowerBound]
    }

    /// 画廊里 `<a href>` 指向原图；`data-src` 只是懒加载缩略图，不能用
    private static func originalImages(in block: Substring) -> [String] {
        let pattern = #"<a[^>]+href="(https://bookdash\.org/wp-content/uploads/[^"]+\.(?:jpg|jpeg|png|webp))""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let text = String(block)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var urls: [String] = []
        for match in regex.matches(in: text, options: [], range: range) {
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else { continue }
            let url = String(text[swiftRange])
            guard seen.insert(url).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    /// 老版结构：`*_interior_spreads_N.jpg`，去掉 `-1024x768` 尺寸后缀取原图
    private static func legacySpreads(in html: String) -> [String] {
        let pattern = #"https://bookdash\.org/wp-content/uploads/[^"'\s]+_interior_spreads_[^"'\s]+?\.(?:jpg|jpeg|png)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var seen = Set<String>()
        var pages: [String] = []

        for match in regex.matches(in: html, options: [], range: range) {
            guard let swiftRange = Range(match.range, in: html) else { continue }
            let raw = String(html[swiftRange])
            let full = raw.replacingOccurrences(
                of: #"-\d+x\d+(?=\.(?:jpg|jpeg|png)$)"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            guard seen.insert(full).inserted else { continue }
            pages.append(full)
        }

        pages.sort { pageNumber($0) < pageNumber($1) }
        return pages
    }

    private static func pageNumber(_ url: String) -> Int {
        guard let range = url.range(of: #"_interior_spreads_(\d+)\."#, options: .regularExpression) else {
            return 0
        }
        let digits = url[range].filter(\.isNumber)
        return Int(digits) ?? 0
    }

    private static func featuredCover(_ book: [String: Any]) -> String? {
        guard let embedded = book["_embedded"] as? [String: Any],
              let media = embedded["wp:featuredmedia"] as? [[String: Any]],
              let first = media.first else { return nil }
        if let url = first["source_url"] as? String { return url }
        if let details = first["media_details"] as? [String: Any],
           let sizes = details["sizes"] as? [String: Any],
           let medium = sizes["medium"] as? [String: Any],
           let url = medium["source_url"] as? String { return url }
        return nil
    }

    private static func metaContent(_ html: String, property: String) -> String? {
        let pattern = #"<meta[^>]+property="\#(property)"[^>]+content="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let value = decodeEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = [
            "&amp;": "&", "&quot;": "\"", "&#039;": "'", "&#39;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&hellip;": "…",
            "&mdash;": "—", "&ndash;": "–"
        ]
        for (key, value) in named {
            result = result.replacingOccurrences(of: key, with: value)
        }
        // 数字实体：&#8217; / &#x2019;
        if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: result),
                      let body = Range(match.range(at: 1), in: result) else { continue }
                let raw = String(result[body])
                let scalarValue: UInt32?
                if raw.hasPrefix("x") || raw.hasPrefix("X") {
                    scalarValue = UInt32(raw.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(raw)
                }
                if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                    result.replaceSubrange(full, with: String(Character(scalar)))
                }
            }
        }
        return result
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("iRead/1.0 (picture books)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BookDashError.badResponse(0) }
        guard http.statusCode == 200 else { throw BookDashError.badResponse(http.statusCode) }
        return data
    }

    // MARK: - 自检

    /// `--bookdash-selftest`：不用点界面，把「书目 → 详情 → 内页 → 真下一张图」
    /// 整条链路跑一遍。绘本这条路全靠 HTML 正则，源站一改版就会静默返回 0 页，
    /// 有这条日志比在阅读器里看到空白快得多。
    static func selfTest() async {
        do {
            let list = try await search(keyword: "")
            NSLog("[PictureBook selftest] books=%d first=%@ cover=%@",
                  list.count,
                  list.first?.title ?? "-",
                  list.first?.coverURL ?? "-")
            guard let first = list.first else { return }

            let detail = try await detail(result: first)
            NSLog("[PictureBook selftest] detail=%@ chapter=%@",
                  detail.title,
                  detail.chapters.first?.title ?? "-")

            let pages = try await pages(bookURL: first.detailURL)
            NSLog("[PictureBook selftest] pages=%d head=%@",
                  pages.count,
                  pages.first?.remote ?? "-")

            // 页数对不代表图能下：再真取一张，确认状态码和体积
            guard let head = pages.first?.remote, let url = URL(string: head) else { return }
            let data = try await get(url)
            NSLog("[PictureBook selftest] page0 bytes=%d", data.count)
        } catch {
            NSLog("[PictureBook selftest] failed: %@", error.localizedDescription)
        }
    }
}
