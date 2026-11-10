import Foundation
import CoreFoundation

struct ParsedBook {
    /// 规范化后的 UTF-8 文本（NSString 便于用 UTF-16 偏移做 CoreText 排版）
    let text: NSString
    let chapters: [Chapter]
}

/// TXT 导入：中文编码识别 + 章节目录规则解析。
/// 章节不单独存盘，每次打开书按当前规则重新解析，规则改动即时生效。
enum TextParser {

    // 第X章 / 卷X / Chapter N / 序章 / 楔子 / 番外 等
    private static let chapterPattern = #"^(?:第\s*[零〇一二三四五六七八九十百千万两0-9０-９]{1,12}\s*[章回节卷部篇集](?:\s*[^\n]{0,40})?|卷\s*[零〇一二三四五六七八九十百千万0-9０-９]{1,8}[^\n]{0,30}|Chapter\s+\d+[^\n]{0,40}|CHAPTER\s+\d+[^\n]{0,40}|序章|楔子|前言|引言|后记|尾声|番外[^\n]{0,20})$"#

    static func parse(_ data: Data) -> ParsedBook {
        let normalized = normalize(decode(data))
        let ns = normalized as NSString
        let lines = splitLines(ns)
        let regex = try? NSRegularExpression(pattern: chapterPattern, options: [])

        var titles: [(Int, String)] = []
        for (offset, line) in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf16.count <= 48 else { continue }
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            guard regex?.firstMatch(in: trimmed, options: [], range: range) != nil else { continue }
            // 相邻两行都是标题时，保留第一行（避免「第一卷 / 第一章」被重复切分）
            if let last = titles.last, offset - last.0 < 4 { continue }
            titles.append((offset, trimmed))
        }

        var chapters: [Chapter] = []
        if titles.count >= 2 {
            if titles[0].0 > 0 {
                chapters.append(makeChapter(index: chapters.count, title: "开篇", location: 0, length: titles[0].0))
            }
            for (k, item) in titles.enumerated() {
                let end = k + 1 < titles.count ? titles[k + 1].0 : ns.length
                chapters.append(makeChapter(index: chapters.count, title: item.1, location: item.0, length: max(0, end - item.0)))
            }
        } else {
            // 没有可识别目录时按固定长度自动分节，保证任何 TXT 都能读
            let chunk = 2400
            var pos = 0
            while pos < ns.length {
                let len = min(chunk, ns.length - pos)
                chapters.append(makeChapter(index: chapters.count, title: "第 \(chapters.count + 1) 节", location: pos, length: len))
                pos += len
            }
        }

        if chapters.isEmpty {
            chapters.append(makeChapter(index: 0, title: "正文", location: 0, length: ns.length))
        }
        return ParsedBook(text: ns, chapters: chapters)
    }

    private static func makeChapter(index: Int, title: String, location: Int, length: Int) -> Chapter {
        Chapter(id: "ch-\(index)", index: index, title: title, location: location, length: length)
    }

    private static func splitLines(_ ns: NSString) -> [(Int, String)] {
        var result: [(Int, String)] = []
        var start = 0
        var i = 0
        while i < ns.length {
            let ch = ns.character(at: i)
            if ch == 10 || ch == 13 {
                result.append((start, ns.substring(with: NSRange(location: start, length: i - start))))
                if ch == 13, i + 1 < ns.length, ns.character(at: i + 1) == 10 { i += 1 }
                start = i + 1
            }
            i += 1
        }
        if start <= ns.length {
            result.append((start, ns.substring(from: start)))
        }
        return result
    }

    static func normalize(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // 去掉中文 TXT 常见的段首全角/半角缩进，缩进交给排版引擎
        s = s.replacingOccurrences(of: "(?m)^[\\u{3000} \t]+", with: "", options: .regularExpression)
        // 连续空行压成一个
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - 编码识别（UTF-8 / UTF-16 / GB18030 / Big5）

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
