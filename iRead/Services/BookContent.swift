import Foundation

/// 一本书在内存中的正文 + 目录，供分页引擎使用。
final class BookContent {
    let text: NSString
    let chapters: [Chapter]

    init(text: NSString, chapters: [Chapter]) {
        self.text = text
        self.chapters = chapters
    }

    var totalLength: Int { text.length }
    var chapterCount: Int { chapters.count }

    func chapterTitle(at index: Int) -> String {
        guard chapters.indices.contains(index) else { return "" }
        return chapters[index].title
    }

    func chapterText(at index: Int) -> NSString {
        guard chapters.indices.contains(index) else { return "" }
        let r = chapters[index].range
        let end = min(r.location + r.length, text.length)
        guard r.location >= 0, end > r.location else { return "" }
        return text.substring(with: NSRange(location: r.location, length: end - r.location)) as NSString
    }

    func excerpt(chapter index: Int, range: NSRange) -> String {
        let chapter = chapterText(at: index)
        let end = min(range.location + range.length, chapter.length)
        guard range.location >= 0, end > range.location else { return chapterTitle(at: index) }
        let raw = chapter.substring(with: NSRange(location: range.location, length: min(end - range.location, 60)))
        return raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
