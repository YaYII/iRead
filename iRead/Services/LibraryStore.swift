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
    /// 漫画要按目录读写图片，扩展与下载器也得拿到这个路径，故不再 private
    let booksDir: URL
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
        return try importBook(data: data, title: url.deletingPathExtension().lastPathComponent)
    }

    /// 从内存数据导入（WiFi 传书用）。title 为不含扩展名的书名。
    @discardableResult
    func importBook(data: Data, title: String) throws -> Book {
        guard !data.isEmpty else { throw LibraryError.unreadable }
        guard data.count < 60 * 1024 * 1024 else { throw LibraryError.tooLarge }

        let parsed = TextParser.parse(data)
        guard parsed.text.length > 0 else { throw LibraryError.unreadable }
        guard let body = (parsed.text as String).data(using: .utf8) else { throw LibraryError.unreadable }

        let id = UUID().uuidString
        let fileName = "\(id).txt"
        try body.write(to: booksDir.appendingPathComponent(fileName))

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = Book(
            id: id,
            title: trimmedTitle.isEmpty ? "未命名书籍" : trimmedTitle,
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

    // MARK: - 流式入库（边下边读）

    /// 下载一开始就先建一本占位书进书架：这样用户立刻能点开，
    /// 后续抓到的章节逐章追加进去，做到「下几章读几章」。
    /// - Returns: 这本书的 id，后续 appendChunk 用它定位。
    @discardableResult
    func createStreamingBook(
        title: String,
        author: String = "",
        totalChapters: Int,
        source: String
    ) -> Book {
        let id = UUID().uuidString
        let fileName = "\(id).txt"
        // 从空文件起步。以前这里先写一行书名占位，导致正文第一行是书名，
        // 目录解析会多出一个「开篇」章节（章数比实际多 1、点进去只有书名）。
        // 空文件时阅读器拿到的是一个空白「第 1 节」，第一批章节到了就有内容。
        let seed = ""
        try? (seed.data(using: .utf8) ?? Data()).write(to: booksDir.appendingPathComponent(fileName))
        let book = Book(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书籍" : title,
            author: author,
            fileName: fileName,
            addedAt: Date(),
            lastReadAt: nil,
            chapterCount: 0,
            fileSize: Int64(seed.utf8.count),
            lastChapterIndex: 0,
            progress: 0,
            coverHue: Double(books.count % 8) / 8.0 + 0.04,
            isPinned: false,
            isFinished: false,
            source: source
        )
        var list = books
        list.insert(book, at: 0)
        books = list
        cache[book.id] = nil
        save()
        return book
    }

    /// 把一批已抓到的章节追加进占位书，并立即刷新书架/阅读器。
    /// 每章写成「标题 + 正文」，TextParser 下次打开会按「第X章」重新切目录。
    ///
    /// 性能要点：**只追加、不重读全书**。早先的实现每批都要
    /// 「读全文 → 字符串拼接 → `.atomic` 全量重写 → 全文 TextParser.parse」，
    /// 一本 1300 章的书（每批 4 章 = 325 批）就是 325 次全量 I/O 加 325 次全文正则解析，
    /// 整体 O(n²)。下载时 CPU/IO 长时间打满，机身发热、掉电明显。
    func appendChapters(to bookID: String, chapters: [(title: String, text: String)]) {
        guard let book = self.book(bookID), !chapters.isEmpty else { return }
        let url = booksDir.appendingPathComponent(book.fileName)

        var payload = ""
        for chapter in chapters {
            payload += "\(chapter.title)\n\n\(chapter.text)\n\n"
        }
        // 按「真正写进文件的行」统计章数，而不是拿标题字符串去判断：
        // 个别站点标题里会混进换行/异常空白，字符串判定和落盘后的行判定会差一条，
        // 章数就会永远对不上。这里和 TextParser 用同一套行扫描口径。
        let recognized = payload.split(separator: "\n").reduce(into: 0) { count, line in
            if TextParser.isChapterTitle(String(line)) { count += 1 }
        }
        guard let data = payload.data(using: .utf8), appendFile(data, to: url) else { return }

        // 清掉这本书的正文缓存，阅读器下次进入会重新解析出新增章节
        let added = Int64(data.count)
        let update = {
            // 缓存与 @Published 都只在主线程动：content(for:) 在主线程读 cache，
            // 后台直接写字典会有并发读写风险
            self.cache[bookID] = nil
            self.mutate(bookID) {
                // 章数按标题增量累加，不再为每批做一次全文解析；
                // 下载结束的 finalizeStreamingBook 会做一次全量校准。
                $0.chapterCount += recognized
                $0.fileSize += added
            }
        }
        // onBatch 在下载 Task 里回调，@Published 必须回主线程改
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    /// 末尾追加写。文件不存在时直接创建。
    private func appendFile(_ data: Data, to url: URL) -> Bool {
        if !fm.fileExists(atPath: url.path) {
            return (try? data.write(to: url)) != nil
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            NSLog("[Library] open failed: %@", url.lastPathComponent)
            return false
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            NSLog("[Library] append failed: %@", error.localizedDescription)
            return false
        }
    }

    /// 下载结束（完成/失败/取消）后，用最终章节数校正元数据。
    func finalizeStreamingBook(bookID: String, expectedChapters: Int) {
        guard let book = self.book(bookID) else { return }
        let url = booksDir.appendingPathComponent(book.fileName)
        guard let data = try? Data(contentsOf: url) else { return }
        // 全量解析只做这一次（下载结束时校准章数），放到后台，别卡主线程
        let parsed = TextParser.parse(data)
        let update = {
            self.cache[bookID] = nil
            self.mutate(bookID) {
                // 抓到的章数可能少于预期（锁章被跳过），以实际落盘为准
                $0.chapterCount = parsed.chapters.count
                $0.fileSize = Int64(data.count)
            }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
        _ = expectedChapters
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

    // MARK: - 漫画

    /// 漫画的存储目录：`Documents/Books/<uuid>.comic/`。
    /// 一本书一个目录：`meta.json` 存章节与图片清单，`c<章节号>/` 存这一话的图片。
    /// 和文字书放在同一个 Books 目录里，`library.json` 的 fileName 列两种都装得下
    /// （目录同样能被 `fileExists` 命中，加载时的过滤逻辑不用改）。
    func comicDirectory(for book: Book) -> URL {
        booksDir.appendingPathComponent(book.fileName, isDirectory: true)
    }

    func comicChapterDirectory(book: Book, chapterIndex: Int) -> URL {
        comicDirectory(for: book).appendingPathComponent("c\(chapterIndex)", isDirectory: true)
    }

    func comicMeta(for bookID: String) -> ComicMeta? {
        guard let book = book(bookID), book.isComic else { return nil }
        let url = comicDirectory(for: book).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ComicMeta.self, from: data)
    }

    func saveComicMeta(_ meta: ComicMeta, for bookID: String) {
        guard let book = book(bookID), book.isComic else { return }
        let dir = comicDirectory(for: book)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: dir.appendingPathComponent("meta.json"))
    }

    /// 网络漫画是否已经入库（同一个书源 + 同一个详情地址视为同一本）
    func comicBook(remoteKey: String) -> Book? {
        books.first { $0.isComic && $0.remoteKey == remoteKey }
    }

    /// 新建一本网络漫画。目录、meta.json、书架条目一次建好，
    /// 之后下载器只往里补图片，不碰书籍索引以外的东西。
    @discardableResult
    func createComicBook(
        title: String,
        author: String,
        sourceID: String,
        remoteURL: String,
        chapters: [ChapterLink]
    ) -> Book {
        let id = UUID().uuidString
        let fileName = "\(id).comic"
        let dir = booksDir.appendingPathComponent(fileName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var meta = ComicMeta()
        meta.sourceID = sourceID
        meta.remoteURL = remoteURL
        meta.chapters = chapters.map {
            ComicChapter(index: $0.index, title: $0.title, remoteURL: $0.url)
        }
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = Book(
            id: id,
            title: trimmed.isEmpty ? "未命名漫画" : trimmed,
            author: author,
            fileName: fileName,
            addedAt: Date(),
            lastReadAt: nil,
            chapterCount: chapters.count,
            fileSize: 0,
            lastChapterIndex: 0,
            progress: 0,
            coverHue: Double(books.count % 8) / 8.0 + 0.04,
            isPinned: false,
            isFinished: false,
            source: sourceID,
            kind: "comic",
            remoteKey: "\(sourceID)|\(remoteURL)"
        )
        var list = books
        list.insert(book, at: 0)
        books = list
        save()
        return book
    }

    /// 目录刷新：保留已经下到本地的图片（同一话、同一地址），新章节补空壳。
    func updateComicChapters(bookID: String, chapters: [ChapterLink]) {
        guard var meta = comicMeta(for: bookID) else { return }
        var existing: [Int: ComicChapter] = [:]
        for chapter in meta.chapters { existing[chapter.index] = chapter }
        meta.chapters = chapters.map { link in
            if var old = existing[link.index], old.remoteURL == link.url {
                old.title = link.title
                return old
            }
            return ComicChapter(index: link.index, title: link.title, remoteURL: link.url)
        }
        saveComicMeta(meta, for: bookID)
        mutateOnMain(bookID) { $0.chapterCount = meta.chapters.count }
    }

    /// 一话下完（或补了几页）后回写清单并累计体积。
    func updateComicPages(bookID: String, chapterIndex: Int, pages: [ComicPage], extraBytes: Int64 = 0) {
        guard var meta = comicMeta(for: bookID),
              let idx = meta.chapters.firstIndex(where: { $0.index == chapterIndex }) else { return }
        meta.chapters[idx].pages = pages
        saveComicMeta(meta, for: bookID)
        if extraBytes > 0 {
            mutateOnMain(bookID) { $0.fileSize += extraBytes }
        }
    }

    func comicPageURL(bookID: String, chapterIndex: Int, file: String) -> URL? {
        guard let book = book(bookID), book.isComic else { return nil }
        return comicChapterDirectory(book: book, chapterIndex: chapterIndex)
            .appendingPathComponent(file)
    }

    /// 书架封面：直接用本机第一张已下载的图，省流量也不用等网络
    func comicCoverURL(for book: Book) -> URL? {
        guard book.isComic, let meta = comicMeta(for: book.id),
              let first = meta.firstLocalPage else { return nil }
        return comicPageURL(bookID: book.id, chapterIndex: first.chapter, file: first.file)
    }

    /// 导入本地图片当一本漫画。按文件名排序，一话装完。
    @discardableResult
    func importComic(images: [URL], title: String) throws -> Book {
        let sorted = images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !sorted.isEmpty else { throw LibraryError.unreadable }

        let id = UUID().uuidString
        let fileName = "\(id).comic"
        let dir = booksDir.appendingPathComponent(fileName, isDirectory: true)
        let chapterDir = dir.appendingPathComponent("c0", isDirectory: true)
        try fm.createDirectory(at: chapterDir, withIntermediateDirectories: true)

        var pages: [ComicPage] = []
        var bytes: Int64 = 0
        for (i, url) in sorted.enumerated() {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { continue }
            // 相册里可能是 HEIC，也可能是 4000px 的原图。统一转 JPEG 并限制长边，
            // 既省空间，也避免阅读器里几十张巨图同时解码把内存顶爆。
            let normalized = image.normalizedForComic(maxSide: 2000)
            guard let jpeg = normalized.jpegData(compressionQuality: 0.9) else { continue }
            let name = String(format: "%03d.jpg", i + 1)
            guard (try? jpeg.write(to: chapterDir.appendingPathComponent(name))) != nil else { continue }
            bytes += Int64(jpeg.count)
            pages.append(ComicPage(
                remote: "",
                file: name,
                width: Int(normalized.size.width),
                height: Int(normalized.size.height)
            ))
        }
        guard !pages.isEmpty else { throw LibraryError.unreadable }

        var meta = ComicMeta()
        meta.chapters = [ComicChapter(index: 0, title: "全一话", remoteURL: "", pages: pages)]
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = Book(
            id: id,
            title: trimmed.isEmpty ? "本地漫画" : trimmed,
            author: "",
            fileName: fileName,
            addedAt: Date(),
            lastReadAt: nil,
            chapterCount: 1,
            fileSize: bytes,
            lastChapterIndex: 0,
            progress: 0,
            coverHue: Double(books.count % 8) / 8.0 + 0.04,
            isPinned: false,
            isFinished: false,
            source: "imported",
            kind: "comic"
        )
        var list = books
        list.insert(book, at: 0)
        books = list
        save()
        return book
    }

    /// `@Published` 只能在主线程改：下载器在后台把图写完再回来更新书架
    private func mutateOnMain(_ id: String, _ block: @escaping (inout Book) -> Void) {
        if Thread.isMainThread {
            mutate(id, block)
        } else {
            DispatchQueue.main.async { self.mutate(id, block) }
        }
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

// MARK: - 图片规整

private extension UIImage {
    /// 长边超过 `maxSide` 就等比缩到 `maxSide`，同时把 EXIF 旋正。
    ///
    /// 相册里导出的图可能是 HEIC、可能带 90° 旋转信息、也可能有 4000px 长边。
    /// 漫画是一屏一张整图，几十张原图同时驻留会把内存顶爆，
    /// 所以导入时就统一成 JPEG、顺手缩到手机看得清的尺寸。
    func normalizedForComic(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        let ratio = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: max(1, size.width * ratio), height: max(1, size.height * ratio))
        let format = UIGraphicsImageRendererFormat.default()
        // 尺寸按像素算：保持 1x，避免 2x/3x 屏又把像素数乘回去
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
