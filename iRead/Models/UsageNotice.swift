import Foundation

/// 使用声明：全 App 统一文案，集中定义，避免各页面表述不一致。
enum UsageNotice {
    /// 完整声明（原样展示）
    static let text = "仅供个人学习、禁止传播、禁止批量、看完即删、责任自担。"

    /// 分条展示用
    static let items = ["仅供个人学习", "禁止传播", "禁止批量", "看完即删", "责任自担"]
}
