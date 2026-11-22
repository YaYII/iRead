import Foundation

// MARK: - 字数

/// 字数只在这里数。
///
/// 为什么不用 `text.count`：那会把换行、缩进、段间空行都算成字，
/// 而读者和平台数的是正文内容。去掉空白后的字符数（含标点）才对得上。
enum WritingText {
    static func count(_ text: String) -> Int {
        text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
    }
}

// MARK: - 创作方式

/// 这一本是怎么起头的。决定 AI 拿到什么材料、被要求做什么。
enum WritingMode: String, Codable, CaseIterable, Identifiable {
    /// 重构：拿一本已有的书当底本，保留人物与设定，换一套写法重写
    case rewrite
    /// 续写：从底本的某一章之后接着往下写
    case continuation
    /// 原创：只借用书架的「口味」，不绑定某一本
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rewrite: return "重构底本"
        case .continuation: return "续写底本"
        case .original: return "全新创作"
        }
    }

    var subtitle: String {
        switch self {
        case .rewrite: return "保留人物与设定，换一套写法重写"
        case .continuation: return "从底本某一章之后接着写下去"
        case .original: return "照你书架的口味，起一个全新的故事"
        }
    }

    var icon: String {
        switch self {
        case .rewrite: return "arrow.triangle.2.circlepath"
        case .continuation: return "text.append"
        case .original: return "sparkles"
        }
    }
}

// MARK: - 章节草稿

struct WritingSegment: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var text: String
    var createdAt: Date = Date()
    /// 初稿是 AI 写的（之后用户改过也仍为 true，只表示来源，不代表未经修改）
    var generated: Bool = false

    /// 这一章要完成什么（排章时写下的一句话），生成时当成硬约束
    var goal: String? = nil
    /// 审查时顺手产出的一句话摘要。
    ///
    /// 这是长篇能写下去的关键：一百章不可能每次把全文发给模型，
    /// 但让它「写完顺便交一句 40 字摘要」几乎不额外花钱 —— 审查那次调用本来就要读完整章。
    /// 之后写第 80 章时，前 79 章的摘要（约 3000 字）就够交代来龙去脉。
    var recap: String? = nil
    /// 最近一次审查没过、但用户选择保留时留下的问题
    var issues: [String]? = nil

    /// 字数一律由程序数，不问模型。
    ///
    /// 口径统一在 `WritingText.count`：去掉空白后的字符数（含标点）。
    /// UI 上的「2363 字」、日志里的字数、发给审查 AI 的那个数字，必须是同一个 ——
    /// 否则卡片说 2363、审查说「只有 1900 字」，用户没法判断谁对。
    var wordCount: Int { WritingText.count(text) }

    /// 卡片上显示的三行预览
    var preview: String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 写作项目

/// 一本「自己在写的书」。
///
/// 为什么不复用 `Book`：书是作者的成品，写作是半成品。塞进同一张表会让书架混进草稿、
/// 让下载进度/书源这些字段对草稿毫无意义，删除和导出时也互相牵连。
/// 这里只留来源书的 id 与书名，作为「这本是从哪儿长出来的」溯源信息。
struct WritingProject: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var mode: WritingMode
    /// 用户给的一句话方向，作为每次生成的长期设定（不是一次性的指令）
    var brief: String = ""
    var sourceBookID: String? = nil
    var sourceBookTitle: String? = nil
    /// 续写从底本的第几章之后开始（0 基）
    var sourceChapterIndex: Int? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var segments: [WritingSegment] = []

    /// 故事大纲 / 设定集：主线、人物、世界观、禁忌。每次生成都带上，是长篇不跑偏的锚。
    /// 用可选类型是为了让加这个字段之前存下的稿子还能解码（非可选加默认值解码会直接失败）。
    var outline: String? = nil
    /// 章纲队列：接下来每一章要写什么（一句话一条），排章时写入，按顺序消费。
    var plan: [String]? = nil

    var outlineText: String { outline ?? "" }

    /// 下一章的目标（还没写的第一条章纲）
    var nextGoal: String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.first
    }

    var wordCount: Int { segments.reduce(0) { $0 + $1.wordCount } }

    var summary: String {
        var parts = ["\(segments.count) 章", "\(wordCount) 字"]
        if let sourceBookTitle { parts.append("源自《\(sourceBookTitle)》") }
        return parts.joined(separator: " · ")
    }

    var lastPreview: String {
        segments.last?.preview ?? "还没有正文"
    }
}

// MARK: - 阅读页 AI 动作

/// 阅读页那个 AI 入口能做的三件事。
///
/// 三种动作产出的都是「另一本可以继续写下去的稿子」，不是对原书的修改 ——
/// 看是看，写是写，混在一起会让人不敢点。
enum ChapterAIAction: String, CaseIterable, Identifiable {
    /// 改写本章：剧情不动，换写法
    case rewrite
    /// 换个走向：从转折点分叉
    case redirect
    /// 接着写：从本章结尾往后写一章
    case continuation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rewrite: return "改写本章"
        case .redirect: return "换个走向"
        case .continuation: return "接着写"
        }
    }

    var subtitle: String {
        switch self {
        case .rewrite: return "剧情不变，重写文笔与节奏"
        case .redirect: return "从转折点分叉，走另一条路"
        case .continuation: return "从本章结尾往后写一章"
        }
    }

    var icon: String {
        switch self {
        case .rewrite: return "text.badge.checkmark"
        case .redirect: return "arrow.triangle.branch"
        case .continuation: return "text.append"
        }
    }

    /// 存进写作后，项目用哪种方式归类
    var writingMode: WritingMode {
        switch self {
        case .rewrite, .redirect: return .rewrite
        case .continuation: return .continuation
        }
    }
}
