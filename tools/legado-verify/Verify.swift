import Foundation

/// 书源规则联网验证工具（macOS 命令行）。
///
/// 直接复用 App 里的 SelectorEngine / WebText / NovelHTTPClient 与 NovelSource 模型，
/// 所以验证结果与真机行为一致，不会出现「Python 模拟能跑、App 跑不通」的偏差。
///
/// 用法：
///   swiftc -O -parse-as-library iRead/Models/NovelModels.swift \
///       iRead/Services/SelectorEngine.swift iRead/Services/WebText.swift \
///       iRead/Services/NovelHTTPClient.swift tools/legado-verify/*.swift -o /tmp/legado-verify
///   /tmp/legado-verify <书源.json> <关键词> [输出.json]
///
/// 三阶段：搜索 → 目录 → 正文，任一阶段失败即记为不可用。

@main
struct Verify {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("用法: legado-verify <书源.json> <关键词> [输出.json]")
            exit(2)
        }
        let packURL = URL(fileURLWithPath: args[1])
        let keyword = args[2]
        let outPath = args.count > 3 ? args[3] : ""

        guard let data = try? Data(contentsOf: packURL) else {
            print("读不到书源文件：\(packURL.path)")
            exit(1)
        }
        let sources: [NovelSource]
        do {
            sources = try JSONDecoder().decode([NovelSource].self, from: data)
        } catch {
            print("书源 JSON 解析失败：\(error)")
            exit(1)
        }

        var rows: [[String: Any]] = []
        for source in sources {
            var row: [String: Any] = ["id": source.id, "name": source.name, "host": source.baseURL]
            let started = Date()
            do {
                // 1) 搜索
                let searchURL = WebText.fill(source.search.url, placeholders: [
                    "host": source.baseURL,
                    "key": encoded(keyword),
                    "page": "1"
                ])
                let html = try await request(source.search, url: searchURL, source: source)
                let items = SelectorEngine.select(source.search.list ?? "", from: html)
                let results = items.compactMap { item -> (String, String)? in
                    guard let title = field("title", source.search, item, source),
                          let url = field("url", source.search, item, source),
                          !title.isEmpty, !url.isEmpty else { return nil }
                    let full = WebText.absolute(url, base: source.baseURL) ?? url
                    return (title, full)
                }
                row["searchCount"] = results.count
                guard let first = results.first else {
                    row["ok"] = false
                    row["error"] = "搜索无结果"
                    rows.append(row)
                    print("✗ \(source.name) 搜索 0 条")
                    continue
                }
                row["book"] = first.0
                row["detailURL"] = first.1

                // 2) 目录（与 NovelFetcher.chapters 一致：chapter.url 为空时用详情页）
                let tocURL = WebText.fill(source.chapter.url, placeholders: [
                    "host": source.baseURL,
                    "url": encoded(first.1),
                    "key": encoded(first.0)
                ])
                let tocPage = try await request(source.chapter,
                                                url: tocURL.isEmpty ? first.1 : tocURL,
                                                source: source)
                let tocItems = SelectorEngine.select(source.chapter.list ?? "", from: tocPage)
                let chapters = tocItems.compactMap { item -> (String, String)? in
                    guard let title = field("title", source.chapter, item, source),
                          let url = field("url", source.chapter, item, source),
                          !url.isEmpty else { return nil }
                    return (WebText.decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines),
                            WebText.absolute(url, base: first.1) ?? url)
                }
                // 与 NovelFetcher 一致：按 URL 去重（目录里的「最新章节」区块会重复同一章）
                var seen = Set<String>()
                let uniq = chapters.filter { seen.insert($0.1).inserted }
                row["chapters"] = uniq.count
                row["rawChapters"] = chapters.count
                row["tocSample"] = (Array(uniq.prefix(3)).map(\.0) + [uniq.last?.0 ?? ""]).joined(separator: " | ")
                guard let chapter = uniq.first else {
                    row["ok"] = false
                    row["error"] = "目录为空"
                    rows.append(row)
                    print("✗ \(source.name) 目录 0 章")
                    continue
                }
                row["firstChapter"] = chapter.0
                row["chapterURL"] = chapter.1

                // 3) 正文（与 NovelFetcher.content 一致：支持 page 模板与 nextPage 跟页）
                var pageTexts: [String] = []
                var pageURL = WebText.fill(source.content.url, placeholders: [
                    "host": source.baseURL,
                    "url": encoded(chapter.1),
                    "page": "1",
                    "key": encoded(chapter.0)
                ])
                if pageURL.isEmpty { pageURL = chapter.1 }
                if let nextSelector = source.content.nextPage, !nextSelector.isEmpty {
                    var visited = Set<String>()
                    var pages = 0
                    while !pageURL.isEmpty, pages < 20, !visited.contains(pageURL) {
                        visited.insert(pageURL)
                        let html = try await request(source.content, url: pageURL, source: source)
                        pageTexts.append(html)
                        pages += 1
                        guard let next = SelectorEngine.first(nextSelector, from: html),
                              let abs = WebText.absolute(next, base: pageURL),
                              !visited.contains(abs) else { break }
                        pageURL = abs
                    }
                    row["pages"] = pageTexts.count
                } else {
                    pageTexts.append(try await request(source.content, url: pageURL, source: source))
                }
                let blocks = pageTexts.flatMap { SelectorEngine.select(source.content.list ?? "", from: $0) }
                if let raw = blocks.first {
                    row["blockCount"] = blocks.count
                    row["blockLen"] = raw.count
                    row["rawHead"] = String(raw.prefix(400))
                    row["rawTail"] = String(raw.suffix(400))
                }
                let text = blocks
                    .map { block -> String in
                        // 与 NovelFetcher.cleanSegments 一致：先 cleanTail 管道，再转纯文本
                        var value = WebText.decodeEntities(block)
                        if let tail = source.content.cleanTail, !tail.isEmpty {
                            value = SelectorEngine.first(tail, from: value) ?? value
                        }
                        return WebText.htmlToText(value)
                    }
                    .filter { !$0.isEmpty }
                    .joined(separator: source.content.join ?? "\n\n")
                let clean = WebText.cleanWhitespace(text)
                row["contentLen"] = clean.count
                row["head"] = String(clean.prefix(120))
                row["tail"] = String(clean.suffix(120))
                row["ok"] = clean.count >= 500
                if clean.count < 500 { row["error"] = "正文过短" }
                let cost = String(format: "%.1fs", Date().timeIntervalSince(started))
                print("\(clean.count >= 500 ? "✓" : "✗") \(source.name) 搜索 \(results.count) · 目录 \(chapters.count) · 正文 \(clean.count) 字 · \(cost)")
            } catch {
                row["ok"] = false
                row["error"] = "\(error)"
                print("✗ \(source.name) 异常 \(error)")
            }
            rows.append(row)
        }

        if !outPath.isEmpty,
           let out = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? out.write(to: URL(fileURLWithPath: outPath))
        }
        let ok = rows.filter { ($0["ok"] as? Bool) == true }.count
        print("\n汇总：\(ok)/\(sources.count) 条可用")
    }

    // MARK: - 与 NovelFetcher 保持一致的小工具

    static func request(_ rule: RuleSection, url: String, source: NovelSource) async throws -> String {
        var headers = source.headers ?? [:]
        if let h = rule.headers { headers.merge(h) { _, new in new } }
        if (rule.method ?? "GET").uppercased() == "POST", let body = rule.body {
            return try await NovelHTTPClient.post(url, body: body, headers: headers).text
        }
        return try await NovelHTTPClient.get(url, headers: headers).text
    }

    static func field(_ name: String, _ rule: RuleSection, _ item: String, _ source: NovelSource) -> String? {
        guard let sel = rule.fields?[name], !sel.isEmpty else { return nil }
        let values = source.isJSON
            ? SelectorEngine.jsonValues(item, path: sel)
            : SelectorEngine.select(sel, from: item)
        return values.first.map { WebText.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
