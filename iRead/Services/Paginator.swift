import Foundation
import UIKit
import CoreText

/// CoreText 分页引擎。分页与渲染使用同一份带属性的章节字符串，
/// 保证「每页首行缩进 / 行距」在计算和绘制时完全一致。
final class Paginator {
    struct Key: Hashable {
        let chapter: Int
        let width: Int
        let height: Int
        let fontSize: Int
        let lineSpacing: Int
        let paragraphSpacing: Int
        let bold: Bool
        let indent: Bool
        let theme: String
    }

    let content: BookContent
    private let settings: ReaderSettings
    private var pageCache: [Key: [NSRange]] = [:]
    private var attrCache: [Int: NSAttributedString] = [:]
    private var attrSignature: String = ""

    init(content: BookContent, settings: ReaderSettings) {
        self.content = content
        self.settings = settings
    }

    func invalidate() {
        pageCache.removeAll()
        attrCache.removeAll()
    }

    private var signature: String {
        "\(settings.fontSize)|\(settings.lineSpacing)|\(settings.paragraphSpacing)|\(settings.isBold)|\(settings.firstLineIndent)|\(settings.theme.rawValue)"
    }

    private func key(chapter: Int, size: CGSize) -> Key {
        Key(
            chapter: chapter,
            width: Int(size.width),
            height: Int(size.height),
            fontSize: Int(settings.fontSize * 10),
            lineSpacing: Int(settings.lineSpacing * 10),
            paragraphSpacing: Int(settings.paragraphSpacing * 10),
            bold: settings.isBold,
            indent: settings.firstLineIndent,
            theme: settings.theme.rawValue
        )
    }

    // MARK: - 排版属性

    private func bodyAttributes() -> [NSAttributedString.Key: Any] {
        let size = settings.fontSize
        let font: UIFont
        if settings.isBold {
            font = UIFont(name: "PingFangSC-Semibold", size: size)
                ?? UIFont.systemFont(ofSize: size, weight: .semibold)
        } else {
            font = UIFont(name: "PingFangSC-Regular", size: size)
                ?? UIFont.systemFont(ofSize: size)
        }

        let para = NSMutableParagraphStyle()
        para.lineSpacing = settings.lineSpacing
        para.paragraphSpacing = settings.paragraphSpacing
        para.firstLineHeadIndent = settings.firstLineIndent ? size * 2 : 0
        para.headIndent = 0
        para.tailIndent = 0
        para.alignment = .justified
        // 按 Unicode 断行规则排版，遵守 CJK 标点禁则（避免逗号、句号出现在行首）；
        // byCharWrapping 会硬按字符断行，破坏中文避头尾。
        para.lineBreakMode = .byWordWrapping

        return [
            .font: font,
            .foregroundColor: settings.theme.uiForeground,
            .paragraphStyle: para,
            .kern: 0.2
        ]
    }

    /// 整章的带属性字符串；首行若是章节标题则加粗放大。
    func chapterAttributed(_ index: Int) -> NSAttributedString {
        let sig = signature
        if sig != attrSignature {
            attrCache.removeAll()
            pageCache.removeAll()
            attrSignature = sig
        }
        if let cached = attrCache[index] { return cached }

        let raw = content.chapterText(at: index) as String
        let attributed = NSMutableAttributedString(string: raw, attributes: bodyAttributes())

        if let firstLine = raw.components(separatedBy: "\n").first {
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = content.chapterTitle(at: index)
            if !trimmed.isEmpty, trimmed.utf16.count <= 48,
               (trimmed == expected || expected.contains(trimmed)) {
                var titleAttrs = bodyAttributes()
                let titleFont = UIFont(name: "PingFangSC-Semibold", size: settings.fontSize + 3)
                    ?? UIFont.systemFont(ofSize: settings.fontSize + 3, weight: .semibold)
                titleAttrs[.font] = titleFont
                titleAttrs[.foregroundColor] = settings.theme.uiForeground
                attributed.setAttributes(titleAttrs, range: NSRange(location: 0, length: trimmed.utf16.count))
            }
        }

        let result = NSAttributedString(attributedString: attributed)
        attrCache[index] = result
        return result
    }

    // MARK: - 分页

    func pageRanges(chapter index: Int, size: CGSize) -> [NSRange] {
        guard size.width >= 80, size.height >= 120 else { return [] }
        let k = key(chapter: index, size: size)
        if let cached = pageCache[k] { return cached }

        // 排版设置变化时清缓存
        let sig = signature
        if sig != attrSignature {
            attrCache.removeAll()
            pageCache.removeAll()
            attrSignature = sig
        }

        let attributed = chapterAttributed(index)
        guard attributed.length > 0 else { return [] }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var ranges: [NSRange] = []
        var location = 0
        var safety = 0
        while location < attributed.length, safety < 20000 {
            safety += 1
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 { break }
            ranges.append(NSRange(location: visible.location, length: visible.length))
            location = visible.location + visible.length
        }
        if ranges.isEmpty {
            ranges = [NSRange(location: 0, length: attributed.length)]
        }
        pageCache[k] = ranges
        return ranges
    }

    func pageCount(chapter index: Int, size: CGSize) -> Int {
        pageRanges(chapter: index, size: size).count
    }

    /// 某个字符落在第几页（用于「从双击处开始朗读」「回到上次读到的地方」）
    func pageIndex(chapter index: Int, forCharacter char: Int, size: CGSize) -> Int {
        let ranges = pageRanges(chapter: index, size: size)
        guard !ranges.isEmpty else { return 0 }
        for (i, r) in ranges.enumerated() where char < r.location + r.length {
            return i
        }
        return ranges.count - 1
    }

    func page(chapter index: Int, page pageIndex: Int, size: CGSize) -> (text: NSAttributedString, start: Int, range: NSRange) {
        let ranges = pageRanges(chapter: index, size: size)
        guard !ranges.isEmpty else {
            return (chapterAttributed(index), 0, NSRange(location: 0, length: 0))
        }
        let safe = min(max(0, pageIndex), ranges.count - 1)
        return (chapterAttributed(index), ranges[safe].location, ranges[safe])
    }

    func plainText(chapter index: Int, range: NSRange) -> String {
        let chapter = content.chapterText(at: index)
        let end = min(range.location + range.length, chapter.length)
        guard range.location >= 0, end > range.location else { return "" }
        return chapter.substring(with: NSRange(location: range.location, length: end - range.location))
    }

    /// 按字符位置估算全书进度
    func progress(chapter index: Int, page pageIndex: Int, size: CGSize) -> Double {
        let ranges = pageRanges(chapter: index, size: size)
        guard !ranges.isEmpty, content.totalLength > 0 else { return 0 }
        let r = ranges[min(max(0, pageIndex), ranges.count - 1)]
        guard content.chapters.indices.contains(index) else { return 0 }
        let absolute = content.chapters[index].location + r.location + r.length
        return min(1, Double(absolute) / Double(content.totalLength))
    }
}
