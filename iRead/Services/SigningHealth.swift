import Foundation

/// App 自带的签名有效期感知。
///
/// 免费 Personal Team 的 provisioning profile 只有 7 天（开发证书是 1 年，两回事），
/// iOS 每次启动都会校验它，过期后 App 直接打不开。
///
/// **重要边界**：沙盒里的普通 App 不能给自己重新签名安装，这是 iOS 的系统限制。
/// 真正的续签由 iPhone 上的 SideStore 通过本地 VPN 回环 + 配对文件完成，
/// 它向 Apple 申请新的 7 天描述文件并覆盖安装（沙盒数据保留）。
/// 所以这里只做「感知 + 提醒」：让用户不会被突然掉签打个措手不及，
/// 在到期前知道要去 SideStore 点一下 Refresh All。
enum SigningHealth {
    struct Status {
        let expiresAt: Date?
        let daysLeft: Int?

        /// ≤ 2 天时提醒。真机自签才需要关心；App Store 版没有这个文件
        var needsAttention: Bool {
            guard let daysLeft else { return false }
            return daysLeft <= 2
        }

        var summary: String {
            guard let expiresAt, let daysLeft else { return "长期有效" }
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            let date = formatter.string(from: expiresAt)
            if needsAttention {
                return "\(daysLeft) 天 · 请到 SideStore 刷新（\(date) 到期）"
            }
            return "\(daysLeft) 天（\(date) 到期）"
        }
    }

    static func current() -> Status {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let plist = extractPlist(from: data),
              let dict = try? PropertyListSerialization.propertyList(
                  from: plist, options: [], format: nil
              ) as? [String: Any],
              let date = dict["ExpirationDate"] as? Date else {
            return Status(expiresAt: nil, daysLeft: nil)
        }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        return Status(expiresAt: date, daysLeft: max(0, days))
    }

    /// mobileprovision 是 CMS 签名包，但 plist 明文就嵌在里面。
    /// iOS 沙盒没有公开的 CMSDecoder 接口，直接截取 `<?xml … </plist>` 即可。
    private static func extractPlist(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        let startTag = Array("<?xml".utf8)
        let endTag = Array("</plist>".utf8)

        func find(_ needle: [UInt8], from: Int) -> Int? {
            guard !needle.isEmpty, needle.count <= bytes.count - from else { return nil }
            for i in from...(bytes.count - needle.count) {
                if Array(bytes[i..<(i + needle.count)]) == needle { return i }
            }
            return nil
        }

        guard let start = find(startTag, from: 0),
              let end = find(endTag, from: start + startTag.count) else { return nil }
        return Data(bytes[start...(end + endTag.count - 1)])
    }
}
