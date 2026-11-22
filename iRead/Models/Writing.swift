import Foundation

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

    var wordCount: Int { text.count }

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
