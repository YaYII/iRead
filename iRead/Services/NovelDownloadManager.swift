import Foundation
import SwiftUI

/// 下载管理器：书一点下载就立刻进书架（占位），正文分批抓、抓完一批写一批，
/// 做到「下几章读几章」；进度直接挂在书架上，支持暂停 / 继续 / 取消。
/// 下载完成后阅读走的仍是原有离线链路，不依赖网络。
///
/// 下载是**队列式**的：同一时刻只下一本，其余排队。
/// 小说一批要并发抓 4 个章节页，几本一起下只会互相抢带宽，每本进度都卡在个位数，
/// 看起来一本都下不完，内存里还同时挂着好几个抓取循环。串行之后是一本接一本真正
/// 下完，其余显示「等待中」，前一本结束自动接上。
/// 暂停的书会退出循环、让出位置（而不是挂在那儿占着槽位），等用户手动点「继续」
/// 再重新排队 —— 否则暂停一本就等于把整条队列冻住。
///
/// 队列与进度**落盘**：状态记在 `Book.download`，进度就是“已抓多少章”。
/// 闪退 / 被系统杀掉之后重启，`restore()` 会把没下完的书按已抓章数重新排队续传。
/// 以前这些只活在这个类里，重启后既不知道下了多少、也不知道该回哪个源，
/// 只能重新点「下载全书」整本重下 —— 已下的几百章全白费。
final class NovelDownloadManager: ObservableObject {
    static let shared = NovelDownloadManager()

    @Published private(set) var tasks: [DownloadTask] = []
    /// 下载完成书数变化时递增，书架据此刷新
    @Published private(set) var completedCount = 0

    /// 每本书的暂停/取消标记。
    /// 主线程写、下载循环（后台）读，所以统一走 flagLock —— Swift 的 Set 在被写入的
    /// 同一瞬间被另一线程读会踩内存，这类崩溃往往没有日志，只表现为「用着用着突然没了」。
    private let flagLock = NSLock()
    private var pausedIDs = Set<String>()
    private var cancelledIDs = Set<String>()

    /// 下载上下文（目录 + 书源），供「继续」时不必重新抓目录。
    /// 只在内存里：进程重启后由 `context(for:)` 按 `Book.remoteURL` 回源拿一次。
    private var contexts: [String: (detail: NovelDetail, source: NovelSource)] = [:]

    /// 排队中的书（FIFO，存 bookID）。只在主线程读写。
    private var pending: [String] = []
    /// 当前正在下载的那本；nil 表示队列空闲
    private var runningID: String?
    private let store = LibraryStore.shared

    /// 打开书时顺手核对目录的最小间隔。
    /// 每次进阅读器都发一次目录请求太费电，6 小时够覆盖「追更」：
    /// 长期追的书一天最多多查 4 次，看完本就再也不查。
    private static let refreshInterval: TimeInterval = 6 * 3600

    /// 仅供自检：把回源拿到的目录截断到前 N 章。
    /// 验证的是「续传从第几章开始」，不需要为了这点事把 700 章整本下完。
    var debugChapterLimit: Int?

    private init() {
        restore()
    }

    var activeTasks: [DownloadTask] {
        tasks.filter { $0.isActive }
    }

    func isDownloading(_ bookID: String) -> Bool {
        activeTasks.contains { $0.bookID == bookID }
    }

    /// 书架卡片用：这本书对应的下载任务（含进度/状态/暂停继续）
    func task(forBookID bookID: String) -> DownloadTask? {
        tasks.first { $0.bookID == bookID }
    }

    func task(forSourceKey key: String) -> DownloadTask? {
        tasks.first { $0.sourceKey == key }
    }

    /// 搜索结果里判断「这本书是不是已经下过了」。
    /// 先查任务表；重启后已完成的任务不在表里，再按来源地址查书架。
    func downloadedBookID(for searchID: String) -> String? {
        if let task = tasks.first(where: { $0.sourceKey == searchID && $0.status == .done }) {
            return task.resultBookID
        }
        return store.books.first { !$0.isComic && $0.remoteURL == searchID }?.id
    }

    // MARK: - 启动恢复

    /// 把上次没下完的书重新排进队列。
    ///
    /// - 排队中 / 下载中：本该继续却被打断，直接续传；
    /// - 暂停：恢复成「已暂停」但**不入队** —— 用户主动停的，不能自己跑起来，
    ///   但任务要回列表里，否则重启后书架上什么都没有，用户还得去长按找入口；
    /// - 失败 / 取消：不恢复，免得书源挂了每次启动都白跑。书架上仍显示「还差 N 章」，
    ///   长按「检查更新」或详情页「继续下载」可以手动续。
    private func restore() {
        // 书架是新书在前；队列要「谁先点的先下」，所以倒着遍历
        for book in store.books.reversed() where !book.isComic {
            guard let record = book.download, let state = book.downloadState else { continue }
            guard state == .queued || state == .fetching || state == .paused else { continue }
            // 本地章数其实已经够：上次是下完了没来得及收尾
            if record.total > 0, book.downloadedChapters >= record.total {
                store.setDownloadState(bookID: book.id, state: .done, total: record.total)
                continue
            }
            let task = DownloadTask(
                bookID: book.id,
                title: book.title,
                sourceName: SourceStore.shared.source(book.source)?.name ?? "网络书源",
                sourceKey: book.remoteURL ?? "",
                totalChapters: max(record.total, book.downloadedChapters),
                completedChapters: book.downloadedChapters,
                status: state == .paused ? .paused : .queued,
                resultBookID: book.id
            )
            tasks.insert(task, at: 0)
            if state == .paused {
                setPaused(book.id, true)
            } else {
                enqueue(book.id)
            }
        }
    }

    // MARK: - 队列调度

    /// 队列空闲时取队首开跑，一次只放一本出去。
    private func pump() {
        guard runningID == nil else { return }
        while let next = pending.first {
            pending.removeFirst()
            // 排队期间可能被取消 / 暂停 / 已经下完，这些都不该再开跑
            guard let task = task(forBookID: next), task.status == .queued else { continue }
            runningID = next
            // 续传起点在开跑这一刻取快照：后台循环不该去读主线程正在改的 tasks
            let startAt = task.completedChapters
            updateNow(next) { $0.status = .fetching; $0.errorMessage = nil }
            Task { [weak self] in
                await self?.run(bookID: next, startAt: startAt)
            }
            return
        }
    }

    /// 一轮下载结束：释放占用，顺手接上下一本
    private func finishRun(_ bookID: String) {
        if runningID == bookID { runningID = nil }
        pump()
    }

    /// 入队；`front` 用于「继续」——用户刚点的这本插到队首。
    private func enqueue(_ bookID: String, front: Bool = false) {
        let work = {
            if !self.pending.contains(bookID) {
                if front {
                    self.pending.insert(bookID, at: 0)
                } else {
                    self.pending.append(bookID)
                }
            }
            self.pump()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - 暂停 / 继续 / 取消

    func pause(_ bookID: String) {
        guard let task = task(forBookID: bookID), task.isActive else { return }
        setPaused(bookID, true)
        let work = {
            // 排队中的直接摘出队列；正在跑的把退出信号交给 shouldStop，
            // 循环会在下一批边界停下，run 收尾时让下一本进场。
            self.pending.removeAll { $0 == bookID }
            self.updateNow(bookID) { $0.status = .paused; $0.errorMessage = nil }
            self.persist(bookID, .paused)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func resume(_ bookID: String) {
        guard let task = task(forBookID: bookID), task.status == .paused else { return }
        setPaused(bookID, false)
        let work = {
            // 状态必须先同步改回 queued，否则 pump 取到队首时还会把它当暂停跳过
            self.updateNow(bookID) { $0.status = .queued; $0.errorMessage = nil }
            self.persist(bookID, .queued)
            self.enqueue(bookID, front: true)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func togglePause(_ bookID: String) {
        if task(forBookID: bookID)?.status == .paused { resume(bookID) } else { pause(bookID) }
    }

    /// 取消：停止抓取，但已下载的章节保留在书架（可继续读）
    func cancel(_ bookID: String) {
        setCancelled(bookID)
        setPaused(bookID, false)
        let work = {
            self.pending.removeAll { $0 == bookID }
            self.updateNow(bookID) { $0.status = .cancelled; $0.errorMessage = nil }
            self.persist(bookID, .cancelled)
            self.contexts[bookID] = nil
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func dismiss(_ bookID: String) {
        pending.removeAll { $0 == bookID }
        contexts[bookID] = nil
        tasks.removeAll { $0.bookID == bookID }
    }

    func clearFinished() {
        tasks.removeAll { [.done, .failed, .cancelled].contains($0.status) }
    }

    // MARK: - 主入口

    /// 点下载立即调用：先建占位书进书架，再排队等下载。
    /// - Returns: 刚进书架的书 id，调用方可立即跳到书架打开它。
    @discardableResult
    func download(detail: NovelDetail, source: NovelSource) -> String {
        let sourceKey = resultKey(detail: detail, source: source)
        // 同一本书重复点：若已在下载/已完成，直接返回已有书的 id
        if let existing = task(forSourceKey: sourceKey) {
            return existing.resultBookID ?? existing.bookID
        }
        // 任务表是内存态，重启后是空的，但书还在书架：
        // 这时绝不能再建一本 —— 按已抓章数继续下，剩下的章节补进来。
        if let book = store.books.first(where: { !$0.isComic && $0.remoteURL == sourceKey }) {
            contexts[book.id] = (detail, source)
            let total = detail.chapters.count
            let startAt = min(book.downloadedChapters, total)
            if startAt < total {
                enqueueFromDisk(bookID: book.id, total: total, startAt: startAt, front: true)
            }
            return book.id
        }

        let book = store.createStreamingBook(
            title: detail.title,
            author: detail.author,
            totalChapters: detail.chapters.count,
            source: source.id,
            remoteURL: sourceKey
        )
        let bookID = book.id
        let task = DownloadTask(
            bookID: bookID,
            title: detail.title,
            sourceName: source.name,
            sourceKey: sourceKey,
            totalChapters: detail.chapters.count,
            // 真正开跑由 pump 改成 .fetching：队列里其它书就停在这个状态
            status: .queued,
            resultBookID: bookID
        )
        setCancelled(bookID, false)
        setPaused(bookID, false)
        contexts[bookID] = (detail, source)
        tasks.insert(task, at: 0)
        enqueue(bookID)
        return bookID
    }

    /// 书架 / 详情页的「继续下载」：不依赖内存里的任务，
    /// 闪退后的半成品、取消过的、失败过的都从这里接着下。
    func continueDownload(_ bookID: String) {
        guard let book = store.book(bookID), !book.isComic,
              let url = book.remoteURL, !url.isEmpty else { return }
        if let task = task(forBookID: bookID) {
            if task.status == .paused { resume(bookID); return }
            if task.isActive { return }
        }
        // 目录规模未知（老书 / 从没下过）就先回源核对一次，顺带把该补的章节排进队列
        guard let record = book.download, record.total > 0 else {
            Task { @MainActor in _ = await self.checkForUpdates(bookID: bookID) }
            return
        }
        guard record.total > book.downloadedChapters else {
            store.setDownloadState(bookID: bookID, state: .done, total: record.total)
            return
        }
        enqueueFromDisk(bookID: bookID, total: record.total, startAt: book.downloadedChapters, front: true)
    }

    /// 回源核对目录：本地比书源少就接着下（从已落盘章数开始，前面的章节不重下）。
    /// - Returns: 待补章数；0 表示已是最新。
    /// 目录请求只发一次，返回的 detail 会缓存进 contexts，真正开跑时不再重复抓。
    @MainActor
    @discardableResult
    func checkForUpdates(bookID: String) async -> Int {
        guard let book = store.book(bookID), !book.isComic,
              let url = book.remoteURL, !url.isEmpty else { return 0 }
        guard let ctx = await context(for: bookID) else { return 0 }
        let remoteTotal = ctx.detail.chapters.count
        guard remoteTotal > 0 else { return 0 }
        // 记一笔：既是节流依据，也把「书源现在有多少章」更新到书架
        store.markDownloadChecked(bookID: bookID, total: remoteTotal)

        let startAt = min(book.downloadedChapters, remoteTotal)
        guard remoteTotal > startAt else {
            store.setDownloadState(bookID: bookID, state: .done, total: remoteTotal)
            return 0
        }
        enqueueFromDisk(bookID: bookID, total: remoteTotal, startAt: startAt, front: true)
        return remoteTotal - startAt
    }

    /// 打开一本书时顺手核对目录（节流，见 `refreshInterval`）。
    /// 已经在下载 / 刚查过的直接跳过，不做任何网络请求。
    @MainActor
    func checkForUpdatesIfStale(bookID: String) {
        guard let book = store.book(bookID), !book.isComic,
              let url = book.remoteURL, !url.isEmpty else { return }
        if let task = task(forBookID: bookID), task.isActive { return }
        if let last = book.download?.checkedAt,
           Date().timeIntervalSince(last) < Self.refreshInterval { return }
        Task { @MainActor in
            _ = await self.checkForUpdates(bookID: bookID)
        }
    }

    /// 仅供自检：把内存里的队列清空，按磁盘重新恢复一次 ——
    /// 等价于「杀进程再启动」，但不用真的重启（自检跑在 App 内部，没法自己重启）。
    func debugReloadFromDisk() {
        tasks.removeAll()
        pending.removeAll()
        runningID = nil
        contexts.removeAll()
        flagLock.lock()
        pausedIDs.removeAll()
        cancelledIDs.removeAll()
        flagLock.unlock()
        restore()
    }

    /// 切后台再回来等场景：任务还在但循环已退出，可重新排队（保留已下章节）
    func retryIfNeeded(_ bookID: String) {
        guard let task = task(forBookID: bookID),
              [.failed, .cancelled].contains(task.status) else { return }
        setCancelled(bookID, false)
        setPaused(bookID, false)
        let work = {
            self.updateNow(bookID) { $0.status = .queued; $0.errorMessage = nil }
            self.enqueue(bookID)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// 按落盘信息建任务并排队（书已经在书架里）
    private func enqueueFromDisk(bookID: String, total: Int, startAt: Int, front: Bool = false) {
        guard let book = store.book(bookID) else { return }
        setCancelled(bookID, false)
        setPaused(bookID, false)
        let start = max(0, total > 0 ? min(startAt, total) : startAt)
        if let idx = tasks.firstIndex(where: { $0.bookID == bookID }) {
            var t = tasks[idx]
            t.totalChapters = max(total, start)
            t.completedChapters = start
            t.status = .queued
            t.errorMessage = nil
            tasks[idx] = t
        } else {
            let task = DownloadTask(
                bookID: bookID,
                title: book.title,
                sourceName: SourceStore.shared.source(book.source)?.name ?? "网络书源",
                sourceKey: book.remoteURL ?? "",
                totalChapters: max(total, start),
                completedChapters: start,
                status: .queued,
                resultBookID: bookID
            )
            tasks.insert(task, at: 0)
        }
        store.setDownloadState(bookID: bookID, state: .queued, total: max(total, start))
        enqueue(bookID, front: front)
    }

    // MARK: - 下载循环

    /// 真正开跑。目录 / 书源按需回源：内存里有就用，重启后没有就按 `Book.remoteURL` 抓一次。
    private func run(bookID: String, startAt: Int) async {
        guard let ctx = await context(for: bookID) else {
            await finish(bookID, status: .failed, written: startAt, message: "获取章节目录失败，书源可能已失效")
            return
        }
        let detail = ctx.detail
        let source = ctx.source
        let total = detail.chapters.count
        // 目录可能比上次更长（追更）：先把总章数更新过来，书架上的 x/y 才准
        await MainActor.run {
            self.updateNow(bookID) { $0.totalChapters = total }
            self.store.setDownloadState(bookID: bookID, state: .fetching, total: total)
        }

        // 已写进去的章节数 = 续传起点；前面这些章的正文已经在文件里了
        var written = min(max(0, startAt), total)
        let batch = source.kind?.lowercased() == "fanqie" ? 3 : 4
        var outcome: DownloadStatus = .done
        var failureMessage: String?

        do {
            try await NovelFetcher.streamChapters(
                detail: detail,
                source: source,
                batch: batch,
                // 断点续传：失败/取消/暂停/闪退后重新开始时，从断点继续，不重下前面的
                startAt: written,
                onBatch: { [weak self] startIndex, chapters in
                    guard let self else { return }
                    // 逐章写入占位书：下几章就能读几章
                    self.store.appendChapters(to: bookID, chapters: chapters)
                    let newCount = min(startIndex + chapters.count, total)
                    if newCount > written {
                        written = newCount
                        self.update(bookID) { $0.completedChapters = newCount }
                    }
                },
                // 暂停不再「挂在边界等唤醒」：挂着的循环仍然占着队列槽位和一份内存。
                // 改成和取消一样在下一批边界退出，位置让给后面排队的书。
                shouldPause: { false },
                shouldStop: { [weak self] in self?.isStopped(bookID) ?? true },
                waitUntilResumed: {}
            )

            store.finalizeStreamingBook(bookID: bookID, expectedChapters: total)
        } catch {
            let isCancelled = (error as? NovelFetcher.FetchError) == .cancelled
            if isCancelled && isPaused(bookID) {
                outcome = .paused
            } else if isCancelled {
                outcome = .cancelled
            } else {
                outcome = .failed
                failureMessage = error.localizedDescription
                NSLog("[Download] failed %@: %@", bookID, error.localizedDescription)
            }
        }

        await finish(bookID, status: outcome, written: written, message: failureMessage)
    }

    /// 收尾：写终态、落盘、让出队列位置。
    private func finish(_ bookID: String, status: DownloadStatus, written: Int, message: String?) async {
        await MainActor.run {
            // 用户在这几毫秒内点了「继续」：任务已经重新排队，状态交给下一轮，别覆盖
            let requeued = self.task(forBookID: bookID)?.status == .queued
            if !requeued {
                self.updateNow(bookID) {
                    $0.status = status
                    $0.completedChapters = status == .done ? $0.totalChapters : written
                    $0.errorMessage = message
                }
                self.persist(bookID, status)
            }
            if status == .done {
                self.completedCount += 1
                self.contexts[bookID] = nil
            }
            self.finishRun(bookID)
        }
    }

    /// 拿这本书的目录与书源。
    /// 内存里有就直接用；重启后内存是空的，按 `Book.remoteURL` 回源抓一次目录
    /// （只有一次目录请求，不碰正文），拿到后缓存起来，真正开跑时不再重复抓。
    /// 完整目录（含还没下载的章节）。
    ///
    /// 阅读器的目录页光靠本地文件列不全：没下过的章根本不在文件里。
    /// 这里优先用内存缓存（正文正在下的时候本来就有完整目录），
    /// 没有才回源抓一次 —— 一个页面生命周期最多一次，不额外轮询。
    func catalog(for bookID: String) async -> NovelDetail? {
        await context(for: bookID)?.detail
    }

    private func context(for bookID: String) async -> (detail: NovelDetail, source: NovelSource)? {
        if let cached = contexts[bookID] { return cached }
        let hit = await MainActor.run { () -> (book: Book, source: NovelSource, url: String)? in
            guard let book = self.store.book(bookID),
                  let url = book.remoteURL, !url.isEmpty,
                  let source = SourceStore.shared.source(book.source) else { return nil }
            return (book, source, url)
        }
        guard let hit else { return nil }
        let result = SearchResult(
            title: hit.book.title,
            author: hit.book.author,
            detailURL: hit.url,
            coverURL: nil,
            intro: nil,
            sourceID: hit.source.id,
            sourceName: hit.source.name
        )
        guard var detail = try? await NovelFetcher.chapters(result: result, source: hit.source),
              !detail.chapters.isEmpty else { return nil }
        if let limit = debugChapterLimit, detail.chapters.count > limit {
            detail.chapters = Array(detail.chapters.prefix(limit))
        }
        await MainActor.run { self.contexts[bookID] = (detail, hit.source) }
        return (detail, hit.source)
    }

    /// 搜索结果 detailURL 与详情页 detailURL 保持一致，避免映射错位
    private func resultKey(detail: NovelDetail, source: NovelSource) -> String {
        detail.detailURL.isEmpty ? "\(source.id)|\(detail.title)" : detail.detailURL
    }

    // MARK: - 标记读写（加锁）

    private func isStopped(_ bookID: String) -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return cancelledIDs.contains(bookID) || pausedIDs.contains(bookID)
    }

    private func isPaused(_ bookID: String) -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return pausedIDs.contains(bookID)
    }

    private func setPaused(_ bookID: String, _ value: Bool) {
        flagLock.lock()
        if value { pausedIDs.insert(bookID) } else { pausedIDs.remove(bookID) }
        flagLock.unlock()
    }

    private func setCancelled(_ bookID: String, _ value: Bool = true) {
        flagLock.lock()
        if value { cancelledIDs.insert(bookID) } else { cancelledIDs.remove(bookID) }
        flagLock.unlock()
    }

    // MARK: - 任务表更新

    /// 状态变化落盘。只挂状态切换：进度不单独写，
    /// `appendChapters` 每批已经在同一次 library.json 写入里带上 fetched 了。
    private func persist(_ bookID: String, _ state: DownloadStatus) {
        store.setDownloadState(bookID: bookID, state: state)
    }

    /// 主线程同步改：pump 要在同一个 tick 里看到最新状态，async 版本会慢一拍
    private func updateNow(_ id: String, _ block: (inout DownloadTask) -> Void) {
        guard let idx = tasks.firstIndex(where: { $0.bookID == id }) else { return }
        var t = tasks[idx]
        block(&t)
        tasks[idx] = t
    }

    /// 后台线程用：抓完一批回填进度
    private func update(_ id: String, _ block: @escaping (inout DownloadTask) -> Void) {
        DispatchQueue.main.async {
            self.updateNow(id, block)
        }
    }
}
