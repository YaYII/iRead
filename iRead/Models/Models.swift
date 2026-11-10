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
    var lastPageIndex: Int
    /// 上下滑动模式下的章内位置（0...1），nil 表示按 lastPageIndex 估算
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
    var pageIndex: Int
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

// MARK: - 翻页动效

/// 阅读方式 + 翻页动效合并成一条「翻页」选择，和番茄/起点等主流阅读器一致。
///
/// `.scroll` 是上下连续滚动（不是翻页，但放在同一组里更符合直觉：
/// 用户只关心「书怎么往下走」，不关心内部实现是滚动还是分页）。
enum PageTurnStyle: String, CaseIterable, Identifiable, Codable {
    case curl
    case cover
    case slide
    case scroll
    case none

    var id: String { rawValue }

    var name: String {
        switch self {
        case .curl: return "仿真"
        case .cover: return "覆盖"
        case .slide: return "平移"
        case .scroll: return "上下"
        case .none: return "无动画"
        }
    }

    var detail: String {
        switch self {
        case .curl: return "页面像纸一样翻折过去"
        case .cover: return "新页从右侧盖住旧页"
        case .slide: return "两页一起平移"
        case .scroll: return "网页式连续滚动，跨章无缝"
        case .none: return "直接切换，不带动效"
        }
    }

    /// 该档位对应的阅读方式
    var readingMode: ReadingMode { self == .scroll ? .scroll : .page }

    /// 设置页用的图标（一屏五个图标，比五个词更快扫）
    var icon: String {
        switch self {
        case .curl: return "book.closed"
        case .cover: return "rectangle.on.rectangle"
        case .slide: return "arrow.left.and.right"
        case .scroll: return "arrow.up.and.down"
        case .none: return "rectangle.dashed"
        }
    }

    /// 兼容旧版本存储值（旧版把阅读方式和动效分开存，且有一个 .fade）
    static func fromStored(_ raw: String, mode: ReadingMode) -> PageTurnStyle {
        if let v = PageTurnStyle(rawValue: raw) { return v }
        if raw == "fade" { return .none }
        return mode == .scroll ? .scroll : .slide
    }
}

// MARK: - 文字颜色

/// 正文文字颜色。叠加在主题背景之上，`auto` 表示跟随主题自带的配色。
enum TextTint: String, CaseIterable, Identifiable, Codable {
    case auto
    case ink
    case brown
    case slate
    case cream
    case gray

    var id: String { rawValue }

    var name: String {
        switch self {
        case .auto: return "跟随主题"
        case .ink: return "墨黑"
        case .brown: return "深棕"
        case .slate: return "灰蓝"
        case .cream: return "米白"
        case .gray: return "浅灰"
        }
    }

    /// 色板里显示的圆点颜色（auto 用主题前景色）
    func swatch(_ theme: ReadingTheme) -> Color {
        Color(hex: hexValue ?? theme.fgHex)
    }

    func uiColor(_ theme: ReadingTheme) -> UIColor {
        UIColor(hex: hexValue ?? theme.fgHex)
    }

    /// nil 表示跟随主题
    var hexValue: UInt32? {
        switch self {
        case .auto: return nil
        case .ink: return 0x1F1D1A
        case .brown: return 0x5B4433
        case .slate: return 0x3A4652
        case .cream: return 0xEDE6D8
        case .gray: return 0x8C8C8C
        }
    }
}

// MARK: - 阅读方式

/// 上下滑动（网页式连续阅读）或左右翻页。
enum ReadingMode: String, CaseIterable, Identifiable, Codable {
    case scroll
    case page

    var id: String { rawValue }

    var name: String {
        switch self {
        case .scroll: return "上下滑动"
        case .page: return "左右翻页"
        }
    }

    var detail: String {
        switch self {
        case .scroll: return "像网页一样连续滚动，最接近现在的阅读习惯"
        case .page: return "整页翻动，一屏一屏地读"
        }
    }

    var icon: String {
        switch self {
        case .scroll: return "arrow.up.and.down.text.horizontal"
        case .page: return "book.pages"
        }
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
