import Foundation
import UIKit

/// 章节正文排版。
///
/// 只负责把每章纯文本按当前排版设置生成一份带属性字符串，
/// 连续滚动容器拿去做 CoreText 绘制；不做分页。
final class ChapterTextProvider {
    let content: BookContent
    private let settings: ReaderSettings
    private var cache: [Int: NSAttributedString] = [:]
    private var signature = ""

    init(content: BookContent, settings: ReaderSettings) {
        self.content = content
        self.settings = settings
    }

    func invalidate() {
        cache.removeAll()
    }

    private var currentSignature: String {
        "\(settings.fontSize)|\(settings.lineSpacing)|\(settings.paragraphSpacing)|\(settings.isBold)|\(settings.firstLineIndent)|\(settings.theme.rawValue)"
    }

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
    func attributed(_ index: Int) -> NSAttributedString {
        let sig = currentSignature
        if sig != signature {
            cache.removeAll()
            signature = sig
        }
        if let cached = cache[index] { return cached }

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
        cache[index] = result
        return result
    }
}
