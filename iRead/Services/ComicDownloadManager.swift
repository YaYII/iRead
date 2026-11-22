import Foundation
import ImageIO

/// 漫画下载器：按「话」为单位把图片抓到本地。
///
/// 为什么不做「边下边读」：文字书一章几百 KB，追加写就完事；漫画一话几十张图，
/// 半话的图片对阅读毫无意义（缺页比没下更难受），所以按话原子完成 ——
/// 一话下完才写进 meta.json，没下完的不会出现在阅读器里。
///
/// 整本之间是**串行队列**：同一时刻只下一本，其余排队、前一本下完自动接上。
/// 漫画的数据量大得多（一话几十张图、整本上千张），几本同时下会把带宽和内存
/// 一起占满，结果每本都只下到开头几话；串行反而能一本一本地真正下完。
/// 阅读器里点开某一话走的仍是 `ensureChapter`，不受队列影响（用户在等，得插队）。
@MainActor
final class ComicDownloadManager: ObservableObject {
    static let shared = ComicDownloadManager()

    struct Task: Identifiable {
        let bookID: String
        var title: String
        var total: Int
        var completed: Int = 0
        var failed: Int = 0
        var currentChapter: String?
        var status: DownloadStatus = .queued
        var errorMessage: String?

        var id: String { bookID }

        var progress: Double {
            guard total > 0 else { return 0 }
            return Double(completed) / Double(total)
        }

        var isActive: Bool { [.queued, .fetching, .paused].contains(status) }
    }

    @Published private(set) var tasks: [String: Task] = [:]

    /// 每个书只允许一个下载任务在跑：同一本书并发写同一个 meta.json 会互相覆盖
    private var runners: [String: Swift.Task<Void, Never>] = [:]
    /// 排队中的书（FIFO）
    private var pending: [String] = []
    /// 当前正在下的那本；nil 表示队列空闲
    private var runningID: String?
    /// 排队期间要用的参数：下哪几话、从哪个源下。
    /// `id` 用来区分「同一本书的不同轮次」—— 用户点「停止」后马上又点「缓存全部」时，
    /// 上一轮的 `run` 可能还没退出，收尾时不能把新一轮的登记和状态一起抹掉。
    struct Job {
        let id = UUID()
        let chapters: [Int]
        let source: NovelSource
    }
    private var jobs: [String: Job] = [:]
    /// 单张图下载并发：站点普遍扛不住高并发，3 是比较稳的折中
    private let imageConcurrency = 3

    func task(for bookID: String) -> Task? { tasks[bookID] }

    // MARK: - 队列

    /// 队列空闲时取队首开跑。整本漫画串行：一话几十张图、话内已经 3 张并发，
    /// 几本一起下会把带宽和内存一起吃掉，还可能被图床限速，反而更慢。
    private func pump() {
        guard runningID == nil else { return }
        while let next = pending.first {
            pending.removeFirst()
            guard var task = tasks[next], task.isActive, let job = jobs[next] else { continue }
            runningID = next
            task.status = .fetching
            tasks[next] = task
            runners[next] = Swift.Task { [weak self] in
                await self?.run(bookID: next, job: job)
            }
            return
        }
    }

    /// 结束/取消的任务留一小会儿给界面收起动画，随后清掉
    private func scheduleCleanup(_ bookID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.tasks[bookID]?.isActive == false else { return }
            self.tasks[bookID] = nil
        }
    }

    // MARK: - 启动 / 取消

    /// 下载指定的一些话（只下还没下完的）。`chapters` 传 nil 表示整本。
    func start(book: Book, source: NovelSource, chapters: [Int]? = nil) {
        guard book.isComic else { return }
        // 已经在跑或已经在排队：重复点不再加一个任务
        guard tasks[book.id]?.isActive != true else { return }
        guard let meta = LibraryStore.shared.comicMeta(for: book.id) else { return }

        let targets: [Int]
        if let chapters {
            targets = chapters
        } else {
            targets = meta.chapters.filter { !$0.isDownloaded }.map(\.index)
        }
        guard !targets.isEmpty else { return }

        tasks[book.id] = Task(
            bookID: book.id,
            title: book.title,
            total: targets.count,
            status: .queued
        )
        jobs[book.id] = Job(chapters: targets, source: source)
        if !pending.contains(book.id) { pending.append(book.id) }
        pump()
    }

    func cancel(_ bookID: String) {
        pending.removeAll { $0 == bookID }
        jobs[bookID] = nil
        runners[bookID]?.cancel()
        runners[bookID] = nil
        if var task = tasks[bookID] {
            task.status = .cancelled
            task.currentChapter = nil
            tasks[bookID] = task
        }
        // 正在跑的那本：取消让循环在本章边界退出，run 的 defer 会接下一本；
        // 排队中的那本直接从队列摘掉即可。
        scheduleCleanup(bookID)
    }

    /// 书架删除漫画时一并清掉任务
    func forget(_ bookID: String) {
        pending.removeAll { $0 == bookID }
        jobs[bookID] = nil
        runners[bookID]?.cancel()
        runners[bookID] = nil
        tasks[bookID] = nil
    }

    // MARK: - 执行

    private func run(bookID: String, job: Job) async {
        // 不管从哪条路径退出（下完 / 取消 / 任务已被清掉），都要释放槽位并接下一本
        defer {
            // 用户可能已经「停止 → 重新缓存」：jobs 里换成新一轮的登记了，别抹掉，
            // 也不要把 runningID 的归属搞乱（pump 会接着跑新一轮）
            if jobs[bookID]?.id == job.id { jobs[bookID] = nil }
            runners[bookID] = nil
            if runningID == bookID { runningID = nil }
            pump()
            scheduleCleanup(bookID)
        }

        let chapters = job.chapters
        let source = job.source
        var completed = 0
        var failed = 0

        for index in chapters {
            if Swift.Task.isCancelled { break }
            guard let meta = LibraryStore.shared.comicMeta(for: bookID),
                  let chapter = meta.chapters.first(where: { $0.index == index }) else { continue }
            // 这一轮已经被新一轮取代：立刻收手，别把新一轮的状态写成自己的
            if jobs[bookID]?.id != job.id { break }
            tasks[bookID]?.status = .fetching
            tasks[bookID]?.currentChapter = chapter.shortTitle

            do {
                try await downloadChapter(bookID: bookID, chapter: chapter, source: source)
                completed += 1
                if jobs[bookID]?.id == job.id { tasks[bookID]?.completed = completed }
            } catch {
                if Swift.Task.isCancelled { break }
                failed += 1
                if jobs[bookID]?.id == job.id { tasks[bookID]?.failed = failed }
                NSLog("[Comic] 第 %d 话下载失败：%@", index, error.localizedDescription)
            }
        }

        // 不是「当前这一轮」就不要再改状态：cancel 已经写好 .cancelled，
        // 新一轮也已经把自己的任务登记进 tasks
        guard jobs[bookID]?.id == job.id else { return }
        // tasks[bookID] 可能已被 forget 清掉
        guard var task = tasks[bookID] else { return }
        task.currentChapter = nil
        if Swift.Task.isCancelled {
            task.status = .cancelled
        } else if completed == 0 {
            task.status = .failed
            task.errorMessage = "这一批没有下载成功的章节"
        } else {
            task.status = .done
        }
        tasks[bookID] = task
    }

    // MARK: - 阅读器按需下载

    /// 阅读器进入某一话时调用：已下完直接返回；没下完就地下完再返回。
    /// 和「缓存全部」共用同一条下载路径，避免两套逻辑下出两种残缺状态。
    func ensureChapter(
        book: Book,
        chapterIndex: Int,
        source: NovelSource?,
        progress: ((String) -> Void)? = nil
    ) async throws -> [ComicPage] {
        guard let meta = LibraryStore.shared.comicMeta(for: book.id),
              let chapter = meta.chapters.first(where: { $0.index == chapterIndex }) else {
            throw DownloadError.chapterUnavailable
        }
        if chapter.isDownloaded { return chapter.pages }
        // 本地导入的漫画没有远程地址，缺页就是缺页，没法补
        guard let source else { throw DownloadError.chapterUnavailable }

        try await downloadChapter(bookID: book.id, chapter: chapter, source: source, progress: progress)
        let updated = LibraryStore.shared.comicMeta(for: book.id)?
            .chapters.first { $0.index == chapterIndex }
        return updated?.pages ?? []
    }

    /// 下载一话。已下过的页直接跳过（断点续传），下完才回写 meta。
    private func downloadChapter(
        bookID: String,
        chapter: ComicChapter,
        source: NovelSource,
        progress: ((String) -> Void)? = nil
    ) async throws {
        guard let book = LibraryStore.shared.book(bookID) else { throw DownloadError.chapterUnavailable }

        var pages = chapter.pages
        if pages.isEmpty {
            progress?("正在解析图片…")
            pages = try await ComicFetcher.pages(
                chapter: ChapterLink(index: chapter.index, title: chapter.title, url: chapter.remoteURL),
                source: source
            )
        }

        let fm = FileManager.default
        let dir = LibraryStore.shared.comicChapterDirectory(book: book, chapterIndex: chapter.index)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // 只补还没落到本地的页：上次中断留下的文件继续用
        let pending = pages.indices.filter { !pages[$0].isLocal }
        guard !pending.isEmpty else { return }

        let addresses = pages.map(\.remote)
        var bytes: Int64 = 0
        var done = 0
        var lastError: Error?
        progress?("下载中 0/\(pending.count)")

        // 滚动窗口下载：始终最多 imageConcurrency 张在飞，完成一张补一张。
        // 结果按下标回填，保证页码顺序（任务完成顺序是乱的）。
        try await withThrowingTaskGroup(of: (Int, Result<Data, Error>).self) { group in
            var next = 0
            while next < min(imageConcurrency, pending.count) {
                let i = pending[next]
                let address = addresses[i]
                group.addTask {
                    do {
                        return (i, .success(try await ComicFetcher.downloadImage(address, source: source)))
                    } catch {
                        return (i, .failure(error))
                    }
                }
                next += 1
            }
            for try await (i, result) in group {
                if Swift.Task.isCancelled {
                    group.cancelAll()
                    throw CancellationError()
                }
                switch result {
                case .success(let data):
                    let name = String(format: "%03d.%@", i + 1, Self.fileExtension(for: addresses[i]))
                    do {
                        try data.write(to: dir.appendingPathComponent(name))
                        pages[i].file = name
                        let size = Self.pixelSize(of: data)
                        pages[i].width = size.width
                        pages[i].height = size.height
                        bytes += Int64(data.count)
                        done += 1
                    } catch {
                        lastError = error
                    }
                case .failure(let error):
                    lastError = error
                }
                progress?("下载中 \(done)/\(pending.count)")
                if next < pending.count {
                    let j = pending[next]
                    let address = addresses[j]
                    group.addTask {
                        do {
                            return (j, .success(try await ComicFetcher.downloadImage(address, source: source)))
                        } catch {
                            return (j, .failure(error))
                        }
                    }
                    next += 1
                }
            }
        }

        // 一张都没下成：当作整话失败，别把空壳写进 meta
        guard done > 0 else {
            throw lastError ?? DownloadError.noImages
        }
        LibraryStore.shared.updateComicPages(
            bookID: bookID,
            chapterIndex: chapter.index,
            pages: pages,
            extraBytes: bytes
        )
    }

    // MARK: - 工具

    private static func fileExtension(for url: String) -> String {
        let path = URL(string: url)?.pathExtension.lowercased() ?? ""
        let allowed = ["jpg", "jpeg", "png", "webp", "gif"]
        return allowed.contains(path) ? path : "jpg"
    }

    /// 只读图片头拿像素尺寸，不解码整张图
    private static func pixelSize(of data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return (0, 0)
        }
        return (width, height)
    }

    enum DownloadError: LocalizedError {
        case chapterUnavailable
        case noImages

        var errorDescription: String? {
            switch self {
            case .chapterUnavailable: return "找不到这一话"
            case .noImages: return "没能解析出图片"
            }
        }
    }
}
