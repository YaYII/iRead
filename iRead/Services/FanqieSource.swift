import Foundation

/// 专用源：番茄小说网页版（fanqienovel.com）
///
/// 三条链路（2026-11 实测均可用，纯 HTTP、无签名、无登录）：
/// - 搜索：`novel.snssdk.com/api/novel/channel/homepage/search/search/v1/` 官方轻量接口，返回明文 JSON
/// - 目录：`fanqienovel.com/api/reader/directory/detail?bookId=`，一次拿全量章节 ID
/// - 正文：`fanqienovel.com/reader/{itemId}` 页面内嵌的 `window.__INITIAL_STATE__`
///
/// 网页正文里的常用字被替换成私有区码点（PUA），靠自定义 woff2 字体显示成真字。
/// 当前字体 `DNMrHsV173Pd4pgy` 对应固定码表 `fanqie-charset.json`（随包），
/// 直接按码点区间还原即可，不需要 OCR、不需要下载字体。
/// 若官网换字体，会明确报错，不会把乱码写进书架。
enum FanqieSource {

    static let host = "https://fanqienovel.com"
    private static let searchHost = "https://novel.snssdk.com"
    private static let stateMarker = "window.__INITIAL_STATE__="
    private static let puaBase = 58344          // 0xE3E8，码表第 0 组起始 gid
    private static let supportedFont = "DNMrHsV173Pd4pgy"

    private static let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Referer": "https://fanqienovel.com/",
        "Accept": "application/json, text/plain, */*"
    ]

    // MARK: - 字体码表

    /// 资源放在 Vendor/booklists（已作为 folder reference 注册进工程），随 App 打包。
    private static let charTable: [String] = {
        guard let url = Bundle.main.url(forResource: "fanqie-charset", withExtension: "json", subdirectory: "booklists"),
              let data = try? Data(contentsOf: url),
              let groups = (try? JSONSerialization.jsonObject(with: data)) as? [[String]],
              let first = groups.first else { return [] }
        return first
    }()

    /// PUA 码点 → 真字。区间外字符原样保留。
    static func decrypt(_ text: String) -> String {
        guard !charTable.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let offset = Int(scalar.value) - puaBase
            if offset >= 0, offset < charTable.count,
               let ch = charTable[offset].first, ch != "?" {
                out.append(ch)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// 正文里是否还有未还原的私有区字符（换字体时会发生）。
    private static func hasPUA(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0xE000 && $0.value <= 0xF8FF }
    }

    // MARK: - 搜索

    static func search(keyword: String, source: NovelSource) async throws -> [SearchResult] {
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(searchHost)/api/novel/channel/homepage/search/search/v1/?aid=1967&q=\(q)&offset=0"
        let text = try await NovelHTTPClient.get(url, headers: headers).text
        guard let json = parseJSON(text),
              let code = number(json["code"]), code == 0,
              let data = json["data"] as? [String: Any],
              let items = data["ret_data"] as? [[String: Any]] else {
            throw FetchError.format
        }
        return items.compactMap { item in
            guard let bookID = string(item["book_id"]), !bookID.isEmpty,
                  let rawTitle = item["title"] as? String else { return nil }
            let title = decrypt(rawTitle)
            guard !title.isEmpty else { return nil }
            return SearchResult(
                title: title,
                author: decrypt(item["author"] as? String ?? ""),
                detailURL: "\(host)/page/\(bookID)",
                coverURL: item["thumb_url"] as? String,
                intro: decrypt(item["abstract"] as? String ?? ""),
                sourceID: source.id,
                sourceName: source.name
            )
        }
    }

    // MARK: - 目录

    static func chapters(result: SearchResult, source: NovelSource) async throws -> NovelDetail {
        let bookID = (result.detailURL as NSString).lastPathComponent
        guard !bookID.isEmpty else { throw FetchError.format }
        let url = "\(host)/api/reader/directory/detail?bookId=\(bookID)"
        let text = try await NovelHTTPClient.get(url, headers: headers).text
        guard let json = parseJSON(text),
              let data = json["data"] as? [String: Any],
              let volumes = data["chapterListWithVolume"] as? [[[String: Any]]] else {
            throw FetchError.format
        }

        var chapters: [ChapterLink] = []
        var lockedCount = 0
        var totalCount = 0
        for volume in volumes {
            for item in volume {
                totalCount += 1
                // 目录里带锁章标记：直接跳过，避免整本下载在第一章就失败。
                if let locked = item["isChapterLock"] as? Bool, locked {
                    lockedCount += 1
                    continue
                }
                if let needPay = number(item["needPay"]), needPay > 0 {
                    lockedCount += 1
                    continue
                }
                guard let itemID = string(item["itemId"]), !itemID.isEmpty else { continue }
                let title = decrypt(item["title"] as? String ?? "")
                chapters.append(ChapterLink(
                    index: chapters.count,
                    title: title.isEmpty ? "第 \(chapters.count + 1) 章" : title,
                    url: "\(host)/reader/\(itemID)"
                ))
            }
        }
        guard !chapters.isEmpty else {
            // 目录为空 ≠ 全书锁章：番茄搜索里大量同名条目是用户上传的占位书，目录本来就是空的
            throw totalCount == 0 ? FetchError.emptyCatalog : FetchError.lockedAll
        }

        var intro = result.intro ?? ""
        if lockedCount > 0 {
            intro += "\n\n（另有 \(lockedCount) 章需官方授权，未收录）"
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

    /// 只取数量，不构造 ChapterLink：搜索结果里显示「可下 X / 共 Y 章」。
    static func stats(result: SearchResult) async throws -> ChapterStats {
        let bookID = (result.detailURL as NSString).lastPathComponent
        guard !bookID.isEmpty else { throw FetchError.format }
        let url = "\(host)/api/reader/directory/detail?bookId=\(bookID)"
        let text = try await NovelHTTPClient.get(url, headers: headers).text
        guard let json = parseJSON(text),
              let data = json["data"] as? [String: Any],
              let volumes = data["chapterListWithVolume"] as? [[[String: Any]]] else {
            throw FetchError.format
        }
        var total = 0
        var available = 0
        for volume in volumes {
            for item in volume {
                total += 1
                if let locked = item["isChapterLock"] as? Bool, locked { continue }
                if let needPay = number(item["needPay"]), needPay > 0 { continue }
                available += 1
            }
        }
        return ChapterStats(available: available, total: total)
    }

    // MARK: - 单章正文

    static func content(chapter: ChapterLink, source: NovelSource) async throws -> String {
        let text = try await NovelHTTPClient.get(chapter.url, headers: headers).text
        guard let state = initialState(text),
              let reader = state["reader"] as? [String: Any],
              let data = reader["chapterData"] as? [String: Any],
              let rawHTML = data["content"] as? String else {
            throw FetchError.format
        }

        // 付费/锁章只读不到，明确报错；不去碰任何登录态或解锁流程。
        if let locked = data["isChapterLock"] as? Bool, locked { throw FetchError.locked }
        if let needPay = number(data["needPay"]), needPay > 0 { throw FetchError.locked }

        // 字体 ID 变了就别把乱码写进书架
        if let common = state["common"] as? [String: Any], let css = common["css"] as? String,
           let font = css.components(separatedBy: "font-family:").dropFirst().first?
                         .components(separatedBy: ";").first,
           !font.isEmpty, font != supportedFont {
            NSLog("[Fanqie] 官网字体已变化：%@（内置码表可能失效）", font)
            throw FetchError.fontChanged
        }

        let decoded = WebText.htmlToText(decrypt(rawHTML))
        guard !decoded.isEmpty else { throw FetchError.empty }
        if hasPUA(decoded) { throw FetchError.fontChanged }
        return decoded
    }

    // MARK: - 内部工具

    /// 从整页 HTML 中安全提取 `window.__INITIAL_STATE__=` 后面的 JSON（不执行脚本）。
    private static func initialState(_ html: String) -> [String: Any]? {
        guard let range = html.range(of: stateMarker) else { return nil }
        let chars = Array(html[range.upperBound...])
        var depth = 0
        var inString = false
        var escaped = false
        var end = -1
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" || c == "[" {
                depth += 1
            } else if c == "}" || c == "]" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
        }
        guard end > 0 else { return nil }
        return parseJSON(String(chars[0...end]))
    }

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

    enum FetchError: LocalizedError {
        case format
        case locked
        case lockedAll
        case emptyCatalog
        case fontChanged
        case empty

        var errorDescription: String? {
            switch self {
            case .format: return "番茄页面结构变化，解析失败"
            case .locked: return "该章节需要官方授权或登录，未读取"
            case .lockedAll: return "这本书的章节均需官方授权，未收录"
            case .emptyCatalog: return "番茄返回的目录为空，该条目可能已下架或是用户上传的占位书"
            case .fontChanged: return "官网字体已更换，内置码表无法还原，请更新 iRead"
            case .empty: return "官网未返回正文"
            }
        }
    }
}
