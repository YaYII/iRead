import Foundation
import SwiftUI
import UIKit

/// 全局排版设置，UserDefaults 持久化。所有阅读页、设置面板共享同一实例。
final class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()

    private enum Key {
        static let fontSize = "iRead.setting.fontSize"
        static let lineSpacing = "iRead.setting.lineSpacing"
        static let paragraphSpacing = "iRead.setting.paragraphSpacing"
        static let horizontalMargin = "iRead.setting.horizontalMargin"
        static let verticalMargin = "iRead.setting.verticalMargin"
        static let theme = "iRead.setting.theme"
        static let pageTurnStyle = "iRead.setting.pageTurnStyle"
        static let isBold = "iRead.setting.isBold"
        static let firstLineIndent = "iRead.setting.firstLineIndent"
        static let keepScreenOn = "iRead.setting.keepScreenOn"
        static let brightness = "iRead.setting.brightness"
        static let speechRate = "iRead.setting.speechRate"
        static let speechVoiceID = "iRead.setting.speechVoiceID"
        static let readingMode = "iRead.setting.readingMode"
        static let speechEngine = "iRead.setting.speechEngine"
        static let voiceProfile = "iRead.setting.voiceProfile"
        static let textTint = "iRead.setting.textTint"
        static let eyeCare = "iRead.setting.eyeCare"
        static let autoReadSpeed = "iRead.setting.autoReadSpeed"
    }

    @Published var fontSize: CGFloat { didSet { store(Double(fontSize), Key.fontSize) } }
    @Published var lineSpacing: CGFloat { didSet { store(Double(lineSpacing), Key.lineSpacing) } }
    @Published var paragraphSpacing: CGFloat { didSet { store(Double(paragraphSpacing), Key.paragraphSpacing) } }
    @Published var horizontalMargin: CGFloat { didSet { store(Double(horizontalMargin), Key.horizontalMargin) } }
    @Published var verticalMargin: CGFloat { didSet { store(Double(verticalMargin), Key.verticalMargin) } }
    @Published var theme: ReadingTheme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    /// 翻页方式（含「上下」这一档），是阅读方式与动效的唯一真相
    @Published var pageTurnStyle: PageTurnStyle {
        didSet {
            defaults.set(pageTurnStyle.rawValue, forKey: Key.pageTurnStyle)
            // 由翻页方式反推阅读方式，避免两处状态打架
            let mode = pageTurnStyle.readingMode
            if readingMode != mode { readingMode = mode }
        }
    }
    @Published var isBold: Bool { didSet { defaults.set(isBold, forKey: Key.isBold) } }
    @Published var firstLineIndent: Bool { didSet { defaults.set(firstLineIndent, forKey: Key.firstLineIndent) } }
    @Published var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: Key.keepScreenOn) } }
    @Published var brightness: Double {
        didSet {
            defaults.set(brightness, forKey: Key.brightness)
            applyBrightness()
        }
    }
    /// 听书语速，AVSpeechUtterance.rate，0.5 为系统默认（约等于 1 倍速）
    @Published var speechRate: Double {
        didSet { defaults.set(speechRate, forKey: Key.speechRate) }
    }
    /// 听书音色标识，空串表示系统默认中文音色
    @Published var speechVoiceID: String {
        didSet { defaults.set(speechVoiceID, forKey: Key.speechVoiceID) }
    }
    /// 阅读方式：上下滑动 / 左右翻页。由 `pageTurnStyle` 驱动，一般不直接改。
    @Published var readingMode: ReadingMode {
        didSet {
            defaults.set(readingMode.rawValue, forKey: Key.readingMode)
            // 反向同步：外部只改阅读方式时（如工具栏切换、调试参数），翻页方式跟着走
            guard !isSyncing else { return }
            isSyncing = true
            defer { isSyncing = false }
            if readingMode == .scroll {
                if pageTurnStyle != .scroll { pageTurnStyle = .scroll }
            } else if pageTurnStyle == .scroll {
                pageTurnStyle = .slide
            }
        }
    }
    /// 听书引擎：内置 Piper 神经语音 / 系统语音
    @Published var speechEngine: SpeechEngineKind {
        didSet { defaults.set(speechEngine.rawValue, forKey: Key.speechEngine) }
    }
    /// 听书音色档位：女声（内置神经）/ 男声（内置神经）/ 粤语（系统 yue-HK）
    @Published var voiceProfile: VoiceProfile {
        didSet {
            defaults.set(voiceProfile.rawValue, forKey: Key.voiceProfile)
            // 档位决定引擎，保持 speechEngine 同步，避免两处状态打架
            if speechEngine != voiceProfile.engine { speechEngine = voiceProfile.engine }
        }
    }
    /// 正文字色，叠加在主题背景之上
    @Published var textTint: TextTint {
        didSet { defaults.set(textTint.rawValue, forKey: Key.textTint) }
    }
    /// 护眼模式：在正文上叠一层暖色滤镜，降低蓝光
    @Published var eyeCare: Bool {
        didSet { defaults.set(eyeCare, forKey: Key.eyeCare) }
    }
    /// 自动阅读速度：每页停留秒数
    @Published var autoReadSpeed: Double {
        didSet { defaults.set(autoReadSpeed, forKey: Key.autoReadSpeed) }
    }

    /// 防止 pageTurnStyle / readingMode 互相触发死循环
    private var isSyncing = false

    /// 实际用于正文的色值（主题前景色被 textTint 覆盖）
    var effectiveForeground: Color { Color(hex: effectiveForegroundHex) }
    var effectiveUIForeground: UIColor { UIColor(hex: effectiveForegroundHex) }

    private var effectiveForegroundHex: UInt32 {
        // 夜间背景下墨黑/棕/灰这些深色字会糊掉，统一回落到主题前景色（番茄同样做法）
        guard theme != .night else { return theme.fgHex }
        return textTint.hexValue ?? theme.fgHex
    }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        fontSize = Self.cg(Key.fontSize, 20)
        lineSpacing = Self.cg(Key.lineSpacing, 9)
        paragraphSpacing = Self.cg(Key.paragraphSpacing, 12)
        horizontalMargin = Self.cg(Key.horizontalMargin, 24)
        verticalMargin = Self.cg(Key.verticalMargin, 30)
        theme = ReadingTheme(rawValue: d.string(forKey: Key.theme) ?? "") ?? .paper
        let storedMode = ReadingMode(rawValue: d.string(forKey: Key.readingMode) ?? "") ?? .scroll
        readingMode = storedMode
        pageTurnStyle = PageTurnStyle.fromStored(d.string(forKey: Key.pageTurnStyle) ?? "", mode: storedMode)
        isBold = d.object(forKey: Key.isBold) as? Bool ?? false
        firstLineIndent = d.object(forKey: Key.firstLineIndent) as? Bool ?? true
        keepScreenOn = d.object(forKey: Key.keepScreenOn) as? Bool ?? true
        brightness = d.object(forKey: Key.brightness) as? Double ?? 0.8
        speechRate = d.object(forKey: Key.speechRate) as? Double ?? 0.5
        speechVoiceID = d.string(forKey: Key.speechVoiceID) ?? ""
        let engine = SpeechEngineKind(rawValue: d.string(forKey: Key.speechEngine) ?? "") ?? .piper
        speechEngine = engine
        textTint = TextTint(rawValue: d.string(forKey: Key.textTint) ?? "") ?? .auto
        eyeCare = d.object(forKey: Key.eyeCare) as? Bool ?? false
        autoReadSpeed = d.object(forKey: Key.autoReadSpeed) as? Double ?? 12
        // 旧版本只存了引擎；没有档位记录时按引擎推断，避免升级后听感突变
        if let raw = d.string(forKey: Key.voiceProfile), let saved = VoiceProfile.fromStored(raw) {
            voiceProfile = saved
        } else {
            voiceProfile = engine == .system ? .cantonese : .neuralFemale
        }
    }

    private static func cg(_ key: String, _ fallback: CGFloat) -> CGFloat {
        guard let n = UserDefaults.standard.object(forKey: key) as? NSNumber else { return fallback }
        return CGFloat(n.doubleValue)
    }

    private func store(_ value: Double, _ key: String) {
        defaults.set(value, forKey: key)
    }

    func applyBrightness() {
        UIScreen.main.brightness = CGFloat(min(1, max(0.15, brightness)))
    }

    func reset() {
        fontSize = 20
        lineSpacing = 9
        paragraphSpacing = 12
        horizontalMargin = 24
        verticalMargin = 30
        theme = .paper
        // 直接设翻页方式，readingMode 会由它自动同步
        pageTurnStyle = .scroll
        isBold = false
        firstLineIndent = true
        keepScreenOn = true
        brightness = 0.8
        speechRate = 0.5
        speechVoiceID = ""
        speechEngine = .piper
        voiceProfile = .neuralFemale
        textTint = .auto
        eyeCare = false
        autoReadSpeed = 12
        applyBrightness()
    }
}
