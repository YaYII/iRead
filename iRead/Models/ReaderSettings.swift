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
        static let isBold = "iRead.setting.isBold"
        static let firstLineIndent = "iRead.setting.firstLineIndent"
        static let keepScreenOn = "iRead.setting.keepScreenOn"
        static let brightness = "iRead.setting.brightness"
        static let speechRate = "iRead.setting.speechRate"
        static let speechVoiceID = "iRead.setting.speechVoiceID"
        static let speechEngine = "iRead.setting.speechEngine"
        static let voiceProfile = "iRead.setting.voiceProfile"
        static let eyeCare = "iRead.setting.eyeCare"
    }

    @Published var fontSize: CGFloat { didSet { store(Double(fontSize), Key.fontSize) } }
    @Published var lineSpacing: CGFloat { didSet { store(Double(lineSpacing), Key.lineSpacing) } }
    @Published var paragraphSpacing: CGFloat { didSet { store(Double(paragraphSpacing), Key.paragraphSpacing) } }
    @Published var horizontalMargin: CGFloat { didSet { store(Double(horizontalMargin), Key.horizontalMargin) } }
    @Published var verticalMargin: CGFloat { didSet { store(Double(verticalMargin), Key.verticalMargin) } }
    @Published var theme: ReadingTheme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
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
    /// 护眼模式：在正文上叠一层暖色滤镜，降低蓝光
    @Published var eyeCare: Bool {
        didSet { defaults.set(eyeCare, forKey: Key.eyeCare) }
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
        isBold = d.object(forKey: Key.isBold) as? Bool ?? false
        firstLineIndent = d.object(forKey: Key.firstLineIndent) as? Bool ?? true
        keepScreenOn = d.object(forKey: Key.keepScreenOn) as? Bool ?? true
        brightness = d.object(forKey: Key.brightness) as? Double ?? 0.8
        speechRate = d.object(forKey: Key.speechRate) as? Double ?? 0.5
        speechVoiceID = d.string(forKey: Key.speechVoiceID) ?? ""
        let engine = SpeechEngineKind(rawValue: d.string(forKey: Key.speechEngine) ?? "") ?? .piper
        speechEngine = engine
        eyeCare = d.object(forKey: Key.eyeCare) as? Bool ?? false
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
        isBold = false
        firstLineIndent = true
        keepScreenOn = true
        brightness = 0.8
        speechRate = 0.5
        speechVoiceID = ""
        speechEngine = .piper
        voiceProfile = .neuralFemale
        eyeCare = false
        applyBrightness()
    }
}
