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
    var join: String?                   // 多段/多页拼接符
    var cleanTail: String?              // 对 list 每项再跑的清洗管道
    var urlPrefix: String?              // 只返回 id 时拼在前面的前缀

    init() {}
    /// 成员初始化器：所有参数带默认值，便于在书源规则里只写需要的字段。
    init(url: String = "", method: String? = nil, body: String? = nil,
         headers: [String: String]? = nil, list: String? = nil,
         fields: [String: String]? = nil, page: PageRule? = nil,
         join: String? = nil, cleanTail: String? = nil, urlPrefix: String? = nil) {
        self.url = url
        self.method = method
        self.body = body
        self.headers = headers
        self.list = list
        self.fields = fields
        self.page = page
        self.join = join
        self.cleanTail = cleanTail
        self.urlPrefix = urlPrefix
    }
}

struct PageRule: Codable, Hashable {
    var start: Int = 1
    var max: Int = 100
    var step: Int = 1
    var stopWhenEmpty: Bool = true
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
    /// 专用源：github（公版书单）、fanqie（番茄网页版 + 字体码表）、qimao（七猫网页版），其余走通用规则
    var kind: String?
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
        case charset, headers, type, kind
    }

    var isJSON: Bool { type?.lowercased() == "json" }
    /// 兼容旧代码里的读取
    var searchURL: String { search.url }

    static func == (lhs: NovelSource, rhs: NovelSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
