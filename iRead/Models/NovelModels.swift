import Foundation

// MARK: - 规则配置

/// 单类规则（搜索/详情/目录/正文共用）。选择器 DSL 见 SelectorEngine。
struct RuleSection: Codable, Hashable {
    var url: String = ""
    var method: String?                 // GET(默认) | POST
    var body: String?
    var headers: [String: String]?
    var list: String?                   // 把页面切成"项"数组的选择器
    var fields: [String: String]?       // 字段名 → 选择器
    var page: PageRule?                 // 分页配置
    var nextPage: String?               // 「下一页」链接选择器：取不到即停（正文分页站）
    var join: String?                   // 多段/多页拼接符
    var cleanTail: String?              // 对 list 每项再跑的清洗管道
    var urlPrefix: String?              // 只返回 id 时拼在前面的前缀

    init() {}
    /// 成员初始化器：所有参数带默认值，便于在书源规则里只写需要的字段。
    init(url: String = "", method: String? = nil, body: String? = nil,
         headers: [String: String]? = nil, list: String? = nil,
         fields: [String: String]? = nil, page: PageRule? = nil,
         nextPage: String? = nil,
         join: String? = nil, cleanTail: String? = nil, urlPrefix: String? = nil) {
        self.url = url
        self.method = method
        self.body = body
        self.headers = headers
        self.list = list
        self.fields = fields
        self.page = page
        self.nextPage = nextPage
        self.join = join
        self.cleanTail = cleanTail
        self.urlPrefix = urlPrefix
    }

    enum CodingKeys: String, CodingKey {
        case url, method, body, headers, list, fields, page, nextPage, join, cleanTail, urlPrefix
    }

    /// 手写解码：只写 `list` + `fields` 的极简规则也能导入（默认值不参与合成解码，
    /// 之前必须把 url/method/body/... 全部写全，用户手写 JSON 一律报「不是有效的书源」）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        list = try c.decodeIfPresent(String.self, forKey: .list)
        fields = try c.decodeIfPresent([String: String].self, forKey: .fields)
        page = try c.decodeIfPresent(PageRule.self, forKey: .page)
        nextPage = try c.decodeIfPresent(String.self, forKey: .nextPage)
        join = try c.decodeIfPresent(String.self, forKey: .join)
        cleanTail = try c.decodeIfPresent(String.self, forKey: .cleanTail)
        urlPrefix = try c.decodeIfPresent(String.self, forKey: .urlPrefix)
    }
}

struct PageRule: Codable, Hashable {
    var start: Int = 1
    var max: Int = 100
    var step: Int = 1
    var stopWhenEmpty: Bool = true

    init(start: Int = 1, max: Int = 100, step: Int = 1, stopWhenEmpty: Bool = true) {
        self.start = start
        self.max = max
        self.step = step
        self.stopWhenEmpty = stopWhenEmpty
    }

    enum CodingKeys: String, CodingKey { case start, max, step, stopWhenEmpty }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 1
        max = try c.decodeIfPresent(Int.self, forKey: .max) ?? 100
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 1
        stopWhenEmpty = try c.decodeIfPresent(Bool.self, forKey: .stopWhenEmpty) ?? true
    }
}

// MARK: - 网络书源

/// 一个书源 = 一组"怎么从某个网站抓数据"的规则。内置与用户导入共用同一套结构。
struct NovelSource: Codable, Identifiable, Hashable {
    var schemaVersion: Int = 1
    var id: String
    var name: String
    /// 站点主页，用于把相对路径补成绝对 URL（JSON 中对应 host）
    var baseURL: String
    var charset: String?
    var headers: [String: String]?
    /// "json" 时按 JSON path 解析，否则按 HTML 选择器
    var type: String?
    /// 专用源：github（公版书单）、fanqie（番茄网页版 + 字体码表）、qimao（七猫网页版）、
    /// mangadex（公开漫画 API），其余走通用规则
    var kind: String?
    /// "book"（默认，文字书）| "comic"（漫画）。
    /// 漫画源和文字源共用同一套规则 DSL 与同一个存储，只是入口、解析方式、阅读器不同：
    /// 漫画的 `content.list` 取到的是图片地址而不是正文。
    var media: String? = nil
    var enabled: Bool = true
    /// 内置源不可删除，但可禁用
    var isBuiltin: Bool = false
    var note: String = ""

    var search: RuleSection = RuleSection()
    var detail: RuleSection = RuleSection()
    var chapter: RuleSection = RuleSection()
    var content: RuleSection = RuleSection()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, note, enabled, isBuiltin
        case search, detail, chapter, content
        case baseURL = "host"
        case charset, headers, type, kind, media
    }

    /// 手写解码放在 extension 里（写在结构体内部会抑制成员初始化器）。
    /// 缺省的区块按空规则处理，缺省的字段用默认值——
    /// 这样用户只写 `id/name/host/search/chapter/content` 也能导入成功。
    var isJSON: Bool { type?.lowercased() == "json" }
    /// 漫画源：走独立的漫画搜索入口与图片解析，不进「搜书」
    var isComic: Bool { media?.lowercased() == "comic" }
    /// 兼容旧代码里的读取
    var searchURL: String { search.url }

    static func == (lhs: NovelSource, rhs: NovelSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension NovelSource {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        charset = try c.decodeIfPresent(String.self, forKey: .charset)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        media = try c.decodeIfPresent(String.self, forKey: .media)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        isBuiltin = try c.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        search = try c.decodeIfPresent(RuleSection.self, forKey: .search) ?? RuleSection()
        detail = try c.decodeIfPresent(RuleSection.self, forKey: .detail) ?? RuleSection()
        chapter = try c.decodeIfPresent(RuleSection.self, forKey: .chapter) ?? RuleSection()
        content = try c.decodeIfPresent(RuleSection.self, forKey: .content) ?? RuleSection()
    }
}

// MARK: - 搜索结果

struct SearchResult: Identifiable, Hashable {
    var id: String { "\(sourceID)|\(detailURL)" }
    var title: String
    var author: String
    var detailURL: String
    var coverURL: String?
    var intro: String?
    var sourceID: String
    var sourceName: String
}

/// 搜索结果阶段能提前拿到的章节规模，用于横向比较同一本书在不同书源能下多少。
struct ChapterStats: Hashable {
    /// 可下载章节数（会员章/锁章已排除）
    var available: Int
    /// 目录里的总章节数
    var total: Int
}

// MARK: - 章节链接

struct ChapterLink: Identifiable, Hashable {
    var id: String { url }
    var index: Int
    var title: String
    var url: String
}

// MARK: - 书籍详情

struct NovelDetail: Identifiable {
    var id: String { detailURL }
    var title: String
    var author: String
    var intro: String
    var coverURL: String?
    var detailURL: String
    var sourceID: String
    var sourceName: String
    var chapters: [ChapterLink]
}

// MARK: - 下载任务

enum DownloadStatus: String {
    case queued = "排队中"
    case fetching = "下载中"
    case paused = "已暂停"
    case done = "已完成"
    case failed = "失败"
    case cancelled = "已取消"
}

struct DownloadTask: Identifiable {
    /// 书架里那本书的 id（书一下载就进书架，task 与书一一对应）
    var id: String { bookID }
    let bookID: String
    let title: String
    let sourceName: String
    /// 搜索结果里的 detailURL，用于把任务映射回搜索卡片
    var sourceKey: String = ""
    var totalChapters: Int
    var completedChapters: Int = 0
    var status: DownloadStatus = .queued
    var errorMessage: String?
    var resultBookID: String?

    var progress: Double {
        guard totalChapters > 0 else { return 0 }
        return Double(completedChapters) / Double(totalChapters)
    }

    var isActive: Bool {
        [.queued, .fetching, .paused].contains(status)
    }
}
