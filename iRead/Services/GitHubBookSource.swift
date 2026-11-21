import Foundation

/// 专用源：GitHub 托管的公版古籍 txt 集合。
/// 搜索：git trees API 列出仓库所有 .txt 路径 → 本地按文件名匹配（带缓存，避免每次请求 API）。
/// 下载：raw.githubusercontent.com 直取正文。版权为公版古籍，资源稳定、大陆可达。
enum GitHubBookSource {

    struct Repo {
        let name: String
        let fullName: String      // owner/repo
        let branch: String
        let note: String
    }

    /// 精挑的公版古籍仓库（bookfetch 项目实测列表）
    static let repos: [Repo] = [
        Repo(name: "殆知阁古籍", fullName: "garychowcmu/daizhigev20", branch: "master",
             note: "1.5 万+ 本古代文献：经史子集、道藏佛藏、小说诗词"),
        Repo(name: "中医药古籍", fullName: "xiaopangxia/TCM-Ancient-Books", branch: "master",
             note: "约 700 本中医药古籍：神农本草经、本草纲目等"),
        Repo(name: "综合书库", fullName: "mymmsc/books", branch: "master",
             note: "综合资料库，含部分公版古籍与文本资料")
    ]

    // MARK: - 缓存（进程内，按仓库）

    private static var pathCache: [String: [String]] = [:]

    private static func treeURL(_ repo: Repo) -> String {
        "https://api.github.com/repos/\(repo.fullName)/git/trees/\(repo.branch)?recursive=1"
    }

    private static func rawURL(_ repo: Repo, path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        // jsDelivr 对大陆更友好、带 CDN 缓存；失败时 download 会回落到 raw
        return "https://cdn.jsdelivr.net/gh/\(repo.fullName)@\(repo.branch)/\(encoded)"
    }

    private static func rawFallbackURL(_ repo: Repo, path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "https://raw.githubusercontent.com/\(repo.fullName)/\(repo.branch)/\(encoded)"
    }

    /// 从 detailURL（jsDelivr 地址）反推仓库与路径，用于失败回落。
    private static func repoAndPath(from url: String) -> (Repo, String)? {
        for repo in repos {
            let prefix = "https://cdn.jsdelivr.net/gh/\(repo.fullName)@\(repo.branch)/"
            if url.hasPrefix(prefix) {
                let encoded = String(url.dropFirst(prefix.count))
                let path = encoded.removingPercentEncoding ?? encoded
                return (repo, path)
            }
        }
        return nil
    }

    /// 内置书单条目：[书名, 仓库内路径]
    private struct BookEntry {
        let title: String
        let path: String
    }

    /// 从 App bundle 加载静态书单（随 App 打包，无需网络、不受 GitHub API 限流）。
    private static func bundledEntries() -> [BookEntry] {
        guard let url = Bundle.main.url(forResource: "daizhigev20", withExtension: "json", subdirectory: "booklists"),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let books = json["books"] as? [Any] else { return [] }
        return books.compactMap { item in
            guard let pair = item as? [Any], pair.count >= 2,
                  let title = pair[0] as? String, let path = pair[1] as? String else { return nil }
            return BookEntry(title: title, path: path)
        }
    }

    /// 取仓库所有 txt 路径：优先本地书单，其次 API（进程内缓存）。
    private static func txtPaths(_ repo: Repo) async throws -> [String] {
        if let cached = pathCache[repo.fullName] { return cached }
        // 殆知阁有随包书单，直接返回，零网络请求
        if repo.fullName == "garychowcmu/daizhigev20" {
            let paths = bundledEntries().map { $0.path }
            if !paths.isEmpty {
                pathCache[repo.fullName] = paths
                return paths
            }
        }
        let resp = try await NovelHTTPClient.get(treeURL(repo), headers: [
            "Accept": "application/vnd.github+json",
            "User-Agent": "iRead/1.0 (public-domain book reader)"
        ])
        guard let data = resp.text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tree = json["tree"] as? [[String: Any]] else {
            throw FetchError.parse
        }
        let paths = tree.compactMap { item -> String? in
            guard let path = item["path"] as? String, path.lowercased().hasSuffix(".txt") else { return nil }
            return path
        }
        pathCache[repo.fullName] = paths
        return paths
    }

    // MARK: - 搜索

    static func search(keyword: String, source: NovelSource) async throws -> [SearchResult] {
        // source.baseURL 存 "owner/repo"，据此定位仓库；为空则搜全部内置仓库
        let targets = repos.filter { source.baseURL.isEmpty || $0.fullName == source.baseURL }
        var results: [SearchResult] = []
        for repo in targets {
            let paths = (try? await txtPaths(repo)) ?? []
            for path in paths {
                let fileName = (path as NSString).lastPathComponent
                let title = (fileName as NSString).deletingPathExtension
                guard match(title, keyword) else { continue }
                let raw = rawURL(repo, path: path)
                results.append(SearchResult(
                    title: title,
                    author: "",
                    detailURL: raw,        // 详情 URL 即 raw 正文地址
                    coverURL: nil,
                    intro: repo.note,
                    sourceID: source.id,
                    sourceName: source.name.isEmpty ? repo.name : source.name
                ))
                if results.count >= 200 { return results } // 限制数量，避免一次返回上万本
            }
        }
        return results
    }

    /// 宽松匹配：关键词包含在书名里，或书名包含在关键词里。
    private static func match(_ title: String, _ keyword: String) -> Bool {
        let t = title.lowercased()
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return false }
        return t.contains(k) || k.contains(t)
    }

    // MARK: - 章节 / 正文

    /// GitHub 源的书是整篇 txt，按段落/标题行切成"章节"以便阅读器分章。
    static func chapters(result: SearchResult, source: NovelSource) async throws -> NovelDetail {
        // 直接用 raw 地址作为唯一章节；阅读器 TextParser 会再按"第X章"规则细切
        let chapter = ChapterLink(index: 0, title: result.title, url: result.detailURL)
        return NovelDetail(
            title: result.title,
            author: result.author,
            intro: result.intro ?? "",
            coverURL: nil,
            detailURL: result.detailURL,
            sourceID: source.id,
            sourceName: source.name,
            chapters: [chapter]
        )
    }

    /// 整本 txt 直接下载（不走分页）。jsDelivr 失败自动回落 raw.githubusercontent。
    static func fullText(detail: NovelDetail) async throws -> Data {
        do {
            let resp = try await NovelHTTPClient.get(detail.detailURL)
            return resp.data
        } catch {
            if let (repo, path) = repoAndPath(from: detail.detailURL) {
                let fallback = rawFallbackURL(repo, path: path)
                NSLog("[GitHubSource] jsDelivr failed, fallback to raw: %@", fallback)
                let resp = try await NovelHTTPClient.get(fallback)
                return resp.data
            }
            throw error
        }
    }

    enum FetchError: LocalizedError {
        case parse
        var errorDescription: String? {
            switch self { case .parse: return "书单数据解析失败" }
        }
    }
}
