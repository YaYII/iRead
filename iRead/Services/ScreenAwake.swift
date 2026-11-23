import UIKit

/// 谁需要「屏幕别息」在这里登记，统一由它去设 `isIdleTimerDisabled`。
///
/// 为什么不能各写各的：这个开关全局只有一个布尔值。
/// 以前连写开跑设 `true`，接着进阅读页，`ReaderView` 按自己的「屏幕常亮」偏好
/// 又设回 `false` —— 连写还在跑，屏幕却开始自动变暗；用户看到的是「AI 不写了」，
/// 实际是息屏后 App 被 iOS 挂起。单章生成（`GenerationSheet`）更是一个都没设，
/// 三十秒后一样息屏。
///
/// 用 Set 而不是引用计数：同一个功能重复登记一次不该要求配对注销两次；
/// 万一漏调一次 `end`，后果也只是提前关灯，不会永远关不掉（那样更耗电）。
@MainActor
enum ScreenAwake {
    enum Holder: Hashable {
        /// 阅读页的「屏幕常亮」偏好
        case reading
        /// 长篇流水线（连写 / 按意见重写）
        case pipeline
        /// 单章生成面板（写下一章、续写、按意见改这章）
        case generation
        /// 记场记：采用改稿后要再跑一次抽取，放在面板关掉之后，
        /// 这时没有别的 holder 撑着，用户一锁屏这条记录就断了
        case log

        var debugName: String {
            switch self {
            case .reading: return "reading"
            case .pipeline: return "pipeline"
            case .generation: return "generation"
            case .log: return "log"
            }
        }
    }

    private static var holders: Set<Holder> = []

    static var isActive: Bool { !holders.isEmpty }

    static func begin(_ holder: Holder) {
        guard holders.insert(holder).inserted else { return }
        apply()
    }

    static func end(_ holder: Holder) {
        guard holders.remove(holder) != nil else { return }
        apply()
    }

    /// 阅读页那个是「开 / 关」偏好，不是「开始 / 结束」，单独给一个入口
    static func set(_ holder: Holder, active: Bool) {
        if active { begin(holder) } else { end(holder) }
    }

    /// 回到前台时重新设一遍。
    ///
    /// iOS 在挂起、下拉控制中心、来电这些时候会把这个标志清掉；不重设的话，
    /// 「切出去看一眼再回来接着写」跑一分钟屏幕又黑了，用户会以为开关没生效。
    static func refresh() {
        apply()
    }

    private static func apply() {
        UIApplication.shared.isIdleTimerDisabled = !holders.isEmpty
        // 走 NSLog 而不是 print：真机/模拟器都能在「控制台.app」和 log show 里捞到，
        // 排查「写着写着屏幕黑了」时，先看这一行有没有被谁顶掉
        NSLog("[iRead] screen awake %@ %@",
              !holders.isEmpty ? "on" : "off",
              holders.map(\.debugName).sorted().joined(separator: ","))
    }
}
