import Foundation
import SwiftUI

struct BundledChapter: Codable {
    let title: String
    let text: String
}

struct BundledBook: Codable {
    let title: String
    let author: String
    let chapters: [BundledChapter]
}

enum LibraryError: LocalizedError {
    case tooLarge
    case unreadable

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "文件超过 60 MB，请先拆分后再导入"
        case .unreadable: return "无法读取该文件，请确认是 UTF-8 / GBK 编码的 TXT 文本"
        }
    }
}

/// 书架数据仓库。书正文存 Documents/Books/<uuid>.txt（统一 UTF-8），
/// 元数据与书签分别存 library.json / bookmarks.json。
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var books: [Book] = []
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published var lastError: String?

    private let fm = FileManager.default
    private let booksDir: URL
    private let metaURL: URL
    private let bookmarkURL: URL
    private var cache: [String: BookContent] = [:]

    init() {
        let doc = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDir = doc.appendingPathComponent("Books", isDirectory: true)
        metaURL = doc.appendingPathComponent("library.json")
        bookmarkURL = doc.appendingPathComponent("bookmarks.json")
        try? fm.createDirectory(at: booksDir, withIntermediateDirectories: true)
        load()
        seedIfNeeded()
    }

    // MARK: - 读取

    func content(for bookID: String) -> BookContent? {
        if let cached = cache[bookID] { return cached }
        guard let book = books.first(where: { $0.id == bookID }) else { return nil }
        let url = booksDir.appendingPathComponent(book.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parsed = TextParser.parse(data)
        let content = BookContent(text: parsed.text, chapters: parsed.chapters)
        cache[bookID] = content
        return content
    }

    func book(_ id: String) -> Book? { books.first { $0.id == id } }
    func bookmarks(for bookID: String) -> [Bookmark] {
        bookmarks.filter { $0.bookID == bookID }.sorted { $0.createdAt > $1.createdAt }
    }
    func isBookmarked(bookID: String, chapterIndex: Int, charOffset: Int) -> Bool {
        bookmarks.contains {
            $0.bookID == bookID && $0.chapterIndex == chapterIndex
                && abs(($0.charOffset ?? -10_000) - charOffset) <= 40
        }
    }

    // MARK: - 导入 / 删除

    @discardableResult
    func importBook(from url: URL) throws -> Book {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw LibraryError.unreadable }
        guard data.count < 60 * 1024 * 1024 else { throw LibraryError.tooLarge }

        let parsed = TextParser.parse(data)
        guard parsed.text.length > 0 else { throw LibraryError.unreadable }
        guard let body = (parsed.text as String).data(using: .utf8) else { throw LibraryError.unreadable }

        let id = UUID().uuidString
        let fileName = "\(id).txt"
        try body.write(to: booksDir.appendingPathComponent(fileName))

        let title = url.deletingPathExtension().lastPathComponent
        let book = Book(
            id: id,
            title: title,
            author: "",
            fileName: fileName,
            addedAt: Date(),
            lastReadAt: nil,
            chapterCount: parsed.chapters.count,
            fileSize: Int64(body.count),
            lastChapterIndex: 0,
            progress: 0,
            coverHue: Double(books.count % 8) / 8.0 + 0.04,
            isPinned: false,
            isFinished: false,
            source: "imported"
        )
        var list = books
        list.insert(book, at: 0)
        books = list
        save()
        return book
    }

    func delete(book: Book) {
        var list = books
        list.removeAll { $0.id == book.id }
        books = list
        var marks = bookmarks
        marks.removeAll { $0.bookID == book.id }
        bookmarks = marks
        cache[book.id] = nil
        try? fm.removeItem(at: booksDir.appendingPathComponent(book.fileName))
        save()
    }

    // MARK: - 元数据更新

    func togglePin(book: Book) { mutate(book.id) { $0.isPinned.toggle() } }
    func toggleFinished(book: Book) { mutate(book.id) { $0.isFinished.toggle() } }

    func rename(book: Book, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(book.id) { $0.title = trimmed }
    }

    func updateReading(
        bookID: String,
        chapterIndex: Int,
        progress: Double,
        scrollRatio: Double? = nil
    ) {
        mutate(bookID) {
            $0.lastChapterIndex = chapterIndex
            $0.progress = min(1, max(0, progress))
            $0.lastReadAt = Date()
            $0.lastScrollRatio = scrollRatio.map { min(1, max(0, $0)) }
        }
    }

    func toggleBookmark(bookID: String, chapterIndex: Int, charOffset: Int, excerpt: String) {
        if let existing = bookmarks.first(where: {
            $0.bookID == bookID && $0.chapterIndex == chapterIndex
                && abs(($0.charOffset ?? -10_000) - charOffset) <= 40
        }) {
            removeBookmark(existing)
            return
        }
        var list = bookmarks
        list.append(Bookmark(
            id: UUID().uuidString,
            bookID: bookID,
            chapterIndex: chapterIndex,
            charOffset: charOffset,
            excerpt: String(excerpt.prefix(60)),
            createdAt: Date()
        ))
        bookmarks = list
        save()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        var list = bookmarks
        list.removeAll { $0.id == bookmark.id }
        bookmarks = list
        save()
    }

    /// 设置变更后清掉正文缓存
    func invalidateContentCache() { cache.removeAll() }

    // MARK: - 听书续读位置

    /// 上次朗读停下的位置。单独存 UserDefaults 而不是写进 library.json，
    /// 因为朗读时每句都会更新，不能每次都重写整个书架索引。
    func speechPosition(for bookID: String) -> (chapter: Int, char: Int)? {
        guard let raw = UserDefaults.standard.dictionary(forKey: "iRead.speech.\(bookID)"),
              let chapter = raw["c"] as? Int,
              let char = raw["i"] as? Int,
              chapter >= 0, char >= 0 else { return nil }
        return (chapter, char)
    }

    func setSpeechPosition(bookID: String, chapter: Int, char: Int) {
        guard chapter >= 0, char >= 0 else { return }
        UserDefaults.standard.set(["c": chapter, "i": char], forKey: "iRead.speech.\(bookID)")
    }

    func clearSpeechPosition(bookID: String) {
        UserDefaults.standard.removeObject(forKey: "iRead.speech.\(bookID)")
    }

    // MARK: - 持久化

    private func mutate(_ id: String, _ block: (inout Book) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        var list = books
        block(&list[index])
        books = list
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(books) { try? data.write(to: metaURL) }
        if let data = try? encoder.encode(bookmarks) { try? data.write(to: bookmarkURL) }
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: metaURL),
           let list = try? decoder.decode([Book].self, from: data) {
            books = list.filter { fm.fileExists(atPath: booksDir.appendingPathComponent($0.fileName).path) }
        }
        if let data = try? Data(contentsOf: bookmarkURL),
           let list = try? decoder.decode([Bookmark].self, from: data) {
            bookmarks = list
        }
    }

    private func seedIfNeeded() {
        let key = "iRead.seeded.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        for (i, sample) in SampleBooks.all.enumerated() {
            var body = ""
            for chapter in sample.chapters {
                body += chapter.title + "\n\n" + chapter.text + "\n\n"
            }
            guard let data = body.data(using: .utf8) else { continue }
            let id = UUID().uuidString
            let fileName = "\(id).txt"
            guard (try? data.write(to: booksDir.appendingPathComponent(fileName))) != nil else { continue }
            let parsed = TextParser.parse(data)
            books.append(Book(
                id: id,
                title: sample.title,
                author: sample.author,
                fileName: fileName,
                addedAt: Date().addingTimeInterval(Double(-i * 3600)),
                lastReadAt: nil,
                chapterCount: parsed.chapters.count,
                fileSize: Int64(data.count),
                lastChapterIndex: 0,
                progress: 0,
                coverHue: [0.06, 0.52, 0.32, 0.78][i % 4],
                isPinned: i == 0,
                isFinished: false,
                source: "builtin"
            ))
        }
        save()
    }
}
