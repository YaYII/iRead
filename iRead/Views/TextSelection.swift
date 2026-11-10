import UIKit

// MARK: - 句子边界

/// 「从这里朗读」以整句为单位：中文长句从半句开始读很别扭，
/// 而系统选中是用户手指划到的范围，起读点要落到有字的地方。
enum SentenceRange {
    private static let terminators: Set<Character> = [
        "。", "！", "？", "；", "…", "\n", "!", "?", ";", "：", ":"
    ]
    private static let closers: Set<Character> = ["」", "』", "”", "’", "）", ")", "】", "》"]

    /// 空白、换行、全角空格都算「没字」
    private static func isBlank(_ ch: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(ch) else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || scalar == "\u{3000}"
    }

    /// 从 index 起第一个有字的字符位置（选中范围常从空白开始）
    static func readableStart(at index: Int, in text: NSString) -> Int {
        guard text.length > 0 else { return 0 }
        var i = min(max(0, index), text.length - 1)
        while i < text.length - 1, isBlank(text.character(at: i)) { i += 1 }
        return i
    }

    /// 包含 `index` 这一句的区间
    static func containing(_ index: Int, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        // 落在段落之间的空行上时，先挪到有字的位置，否则只会选中一个换行符
        let target = readableStart(at: index, in: text)

        var start = target
        while start > 0 {
            if isBlank(text.character(at: start - 1)) { break }
            let prev = text.substring(with: NSRange(location: start - 1, length: 1))
            if let ch = prev.first, terminators.contains(ch) { break }
            start -= 1
        }

        var end = target
        while end < text.length {
            let unit = text.substring(with: NSRange(location: end, length: 1))
            guard let ch = unit.first else { break }
            end += 1
            if terminators.contains(ch) {
                // 把紧跟的右引号/右括号一起选进去
                if end < text.length,
                   let next = text.substring(with: NSRange(location: end, length: 1)).first,
                   closers.contains(next) {
                    end += 1
                }
                break
            }
        }
        return NSRange(location: start, length: max(0, end - start))
    }
}
