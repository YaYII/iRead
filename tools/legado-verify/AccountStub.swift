import Foundation
import CoreFoundation

/// 命令行验证工具用的 AccountStore 桩：App 里它读 Keychain，
/// 这里只需要满足 NovelHTTPClient 的编译依赖，一律返回无 Cookie。
final class AccountStore {
    static let shared = AccountStore()
    private init() {}
    func cookie(forHost host: String) -> String? { nil }
}

/// TextParser 桩：App 里它还依赖 Chapter 模型（阅读器用），
/// 验证书源只需要其中的编码识别，这里原样搬过来，保证 GBK/Big5 站点解码一致。
enum TextParser {
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return String(data: data, encoding: .utf16LittleEndian) ?? String(decoding: data, as: UTF8.self)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(data: data, encoding: .utf16BigEndian) ?? String(decoding: data, as: UTF8.self)
        }
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
            return utf8
        }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let gbk = String(data: data, encoding: String.Encoding(rawValue: gb)), !gbk.isEmpty {
            return gbk
        }
        let big5 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)
        )
        if let b5 = String(data: data, encoding: String.Encoding(rawValue: big5)), !b5.isEmpty {
            return b5
        }
        return String(decoding: data, as: UTF8.self)
    }
}
