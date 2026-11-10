import Foundation
import SwiftUI
import UIKit

// MARK: - 颜色工具

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

// MARK: - 章节
/// location / length 均为全书规范化文本（NSString）的 UTF-16 偏移。
struct Chapter: Identifiable, Codable, Hashable {
    var id: String
    var index: Int
    var title: String
    var location: Int
    var length: Int

    var range: NSRange { NSRange(location: location, length: length) }
}

// MARK: - 书籍

struct Book: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var author: String
    /// Documents/Books/ 下的文件名，内容为规范化后的 UTF-8 纯文本
    var fileName: String
    var addedAt: Date
    var lastReadAt: Date?
    var chapterCount: Int
    var fileSize: Int64
    var lastChapterIndex: Int
    /// 章内位置（0...1），恢复阅读位置用
    var lastScrollRatio: Double? = nil
    /// 0...1
    var progress: Double
    /// 封面色相 0...1
    var coverHue: Double
    var isPinned: Bool
    var isFinished: Bool
    /// "builtin" | "imported"
    var source: String

    var displayAuthor: String { author.trimmingCharacters(in: .whitespaces).isEmpty ? "佚名" : author }
    var progressPercent: String { String(format: "%.1f%%", min(1, max(0, progress)) * 100) }
    var isRead: Bool { lastReadAt != nil }
}

// MARK: - 书签

struct Bookmark: Identifiable, Codable, Hashable {
    var id: String
    var bookID: String
    var chapterIndex: Int
    /// 章内字符位置。旧版本按「页」记录，没有这个字段，回落到章首。
    var charOffset: Int? = nil
    var excerpt: String
    var createdAt: Date
}

// MARK: - 阅读主题

enum ReadingTheme: String, CaseIterable, Identifiable, Codable {
    case paper
    case sepia
    case green
    case night

    var id: String { rawValue }

    var name: String {
        switch self {
        case .paper: return "白纸"
        case .sepia: return "羊皮纸"
        case .green: return "护眼"
        case .night: return "夜间"
        }
    }

    var bgHex: UInt32 {
        switch self {
        case .paper: return 0xFFFDF8
        case .sepia: return 0xF3E8D0
        case .green: return 0xDDE9D5
        case .night: return 0x171A1D
        }
    }

    var fgHex: UInt32 {
        switch self {
        case .paper: return 0x24211D
        case .sepia: return 0x4A3A2A
        case .green: return 0x2F3B2C
        case .night: return 0xB9BEC4
        }
    }

    var subHex: UInt32 {
        switch self {
        case .paper: return 0x8B857B
        case .sepia: return 0x91826A
        case .green: return 0x74856C
        case .night: return 0x6E757C
        }
    }

    var accentHex: UInt32 {
        switch self {
        case .paper: return 0xB45F3C
        case .sepia: return 0x9A5B34
        case .green: return 0x4C7A4E
        case .night: return 0xD49A6A
        }
    }

    var background: Color { Color(hex: bgHex) }
    var uiBackground: UIColor { UIColor(hex: bgHex) }
    var foreground: Color { Color(hex: fgHex) }
    var uiForeground: UIColor { UIColor(hex: fgHex) }
    var secondary: Color { Color(hex: subHex) }
    var uiSecondary: UIColor { UIColor(hex: subHex) }
    var accent: Color { Color(hex: accentHex) }
    var uiAccent: UIColor { UIColor(hex: accentHex) }
    var colorScheme: ColorScheme { self == .night ? .dark : .light }

    /// 朗读高亮底色：主题色淡压一层，深色主题稍重一点才看得出来
    var speechHighlight: UIColor {
        uiAccent.withAlphaComponent(self == .night ? 0.30 : 0.20)
    }
}

// MARK: - 听书引擎

enum SpeechEngineKind: String, CaseIterable, Identifiable, Codable {
    case piper
    case system

    var id: String { rawValue }

    var name: String {
        switch self {
        case .piper: return "本地神经语音"
        case .system: return "系统语音"
        }
    }

    var detail: String {
        switch self {
        case .piper: return "随 App 内置的 Piper 中文模型，音色自然、完全离线"
        case .system: return "iOS 系统朗读音色，可切换不同人声"
        }
    }
}

/// 听书音色档位。
///
/// 做成「档位」而不是让用户直接挑音色，是因为两条引擎的音色体系完全不同：
/// 内置 Piper 有两个独立模型（女声花颜 / 男声超文），粤语只能由系统语音提供。
/// 用档位统一对外，内部再映射到具体引擎。
///
/// 注：iOS 系统本身**没有任何中文男声**（只有 Tingting / Meijia / Sinji 三个女声），
/// 所以男声必须走内置模型，不能靠 `AVSpeechSynthesisVoice`。
enum VoiceProfile: String, CaseIterable, Identifiable, Codable {
    /// 内置 Piper 女声「花颜」，音质最自然
    case neuralFemale
    /// 内置 Piper 男声「超文」，int8 量化、体积小
    case neuralMale
    /// 粤语（系统 yue-HK Sinji），用粤语读音念书面中文，适合学粤语
    case cantonese

    var id: String { rawValue }

    var name: String {
        switch self {
        case .neuralFemale: return "女声"
        case .neuralMale: return "男声"
        case .cantonese: return "粤语"
        }
    }

    var detail: String {
        switch self {
        case .neuralFemale: return "内置神经语音「花颜」，音色自然、完全离线"
        case .neuralMale: return "内置神经语音「超文」，男声、完全离线"
        case .cantonese: return "粤语朗读（yue-HK），用粤语读音念书面中文，适合学粤语"
        }
    }

    var badge: String {
        switch self {
        case .neuralFemale: return "内置神经 · 花颜 · 22050Hz"
        case .neuralMale: return "内置神经 · 超文 · 22050Hz"
        case .cantonese: return "系统语音 · 粤语"
        }
    }

    /// 该档位对应的内置模型；粤语走系统语音，故为 nil
    var piperModel: PiperModel? {
        switch self {
        case .neuralFemale: return .female
        case .neuralMale: return .male
        case .cantonese: return nil
        }
    }

    /// 该档位实际使用的引擎
    var engine: SpeechEngineKind {
        piperModel == nil ? .system : .piper
    }

    /// 兼容旧版本存储值（曾用 systemMale 表示男声）
    static func fromStored(_ raw: String) -> VoiceProfile? {
        if let v = VoiceProfile(rawValue: raw) { return v }
        if raw == "systemMale" { return .neuralMale }
        return nil
    }
}
