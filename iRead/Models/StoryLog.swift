import Foundation

// MARK: - 场记

/// 一条场记的种类。
///
/// 分类不是装饰：生成时按类取用 —— 人物状态全带、事件只带最近几十条、
/// 伏笔只带没回收的。如果全是一锅「摘要」，模型会淹在无关信息里，
/// 该记住的境界反而被挤掉。
enum StoryLogKind: String, Codable, CaseIterable, Identifiable {
    /// 人物的状态：境界、位置、伤势、身份、关系
    case character
    /// 改变了局势、后面必须承接的事
    case event
    /// 埋下但还没揭晓的线索
    case thread
    /// 拿到 / 失去 / 损坏的关键物件
    case item
    /// 这一章首次明确的世界规则
    case world

    var id: String { rawValue }

    var title: String {
        switch self {
        case .character: return "人物"
        case .event: return "事件"
        case .thread: return "伏笔"
        case .item: return "物件"
        case .world: return "设定"
        }
    }

    var icon: String {
        switch self {
        case .character: return "person.fill"
        case .event: return "bolt.fill"
        case .thread: return "link"
        case .item: return "shippingbox.fill"
        case .world: return "globe.asia.australia.fill"
        }
    }
}

/// 一条场记。
///
/// 刻意保持「一句话 + 来源章节」这么窄：一条写不清的事，说明它还不该被记住。
/// `segmentID` 是硬链，不是章序号 —— 中间删一章、重排一次，序号会变，id 不会。
struct StoryLogEntry: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var kind: StoryLogKind = .event
    /// 谁 / 什么：书中原名。人物就是人名，物件就是物件名。
    var subject: String = ""
    /// 一句话事实：发生了什么、变成什么样。不超过 60 字。
    var summary: String = ""
    /// 来源章节
    var segmentID: String = ""
    /// 来源章节序号（0 基）。章节被删后可能对不上，显示时以 segmentID 为准。
    var chapterIndex: Int = 0
    var chapterTitle: String = ""
    var createdAt: Date = Date()
    /// 伏笔是否已回收。非伏笔恒为 false。
    var resolved: Bool = false

    /// 日志行里的「第 3 章」
    var chapterLabel: String { "第 \(chapterIndex + 1) 章" }

    /// 一行日志的正文：人物｜萧炎：从炼气二层突破到三层
    var line: String { "\(kind.title)｜\(subject)：\(summary)" }
}
