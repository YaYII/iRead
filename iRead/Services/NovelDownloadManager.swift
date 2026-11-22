import Foundation
import SwiftUI

/// 下载管理器：书一点下载就立刻进书架（占位），正文分批抓、抓完一批写一批，
/// 做到「下几章读几章」；进度直接挂在书架上，支持暂停 / 继续 / 取消。
/// 下载完成后阅读走的仍是原有离线链路，不依赖网络。
///
/// 下载是**队列式**的：同一时刻只下一本，其余排队。
/// 小说一批要并发抓 4 个章节页，几本一起下只会互相抢带宽，每本进度都卡在个位数，
/// 看起来一本都下不完，内存里还同时挂着好几个抓取循环。串行之后是一本接一本真正
/// 下完，其余显示「排队中」，前一本结束自动接上。
/// 暂停的书会退出循环、让出位置（而不是挂在那儿占着槽位），等用户手动点「继续」
/// 再重新排队 —— 否则暂停一本就等于把整条队列冻住。
final class NovelDownloadManager: ObservableObject {
    static let shared = NovelDownloadManager()

    @Published private(set) var tasks: [DownloadTask] = []
    /// 下载完成书数变化时递增，书架据此刷新
    @Published private(set) var completedCount = 0

    /// 每本书的暂停/取消标记
    private var pausedIDs = Set<String>()
    private var cancelledIDs = Set<String>()
    /// 保存下载上下文，供「继续」时重新发起（detail/source 不落盘，进程内有效）
    private var contexts: [String: (detail: NovelDetail, source: NovelSource)] = [:]

    /// 排队中的书（FIFO，存 bookID）。只在主线程读写。
    private var pending: [String] = []
    /// 当前正在下载的那本；nil 表示队列空闲
    private var runningID: String?
    private let store = LibraryStore.shared

    private init() {}

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

    func downloadedBookID(for searchID: String) -> String? {
        tasks.first { $0.sourceKey == searchID && $0.status == .done }?.resultBookID
    }

    // MARK: - 队列调度

    /// 队列空闲时取队首开跑，一次只放一本出去。
    private func pump() {
        guard runningID == nil else { return }
        while let next = pending.first {
            pending.removeFirst()
            // 排队期间可能被取消 / 暂停 / 已经下完，这些都不该再开跑
            guard let task = task(forBookID: next), task.status == .queued,
                  let ctx = contexts[next] else { continue }
            runningID = next
            updateNow(next) { $0.status = .fetching; $0.errorMessage = nil }
            Task { [weak self] in
                await self?.run(bookID: next, detail: ctx.detail, source: ctx.source)
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
        pausedIDs.insert(bookID)
        let work = {
            // 排队中的直接摘出队列；正在跑的把退出信号交给 shouldStop，
            // 循环会在下一批边界停下，run 收尾时让下一本进场。
            self.pending.removeAll { $0 == bookID }
            self.updateNow(bookID) { $0.status = .paused; $0.errorMessage = nil }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func resume(_ bookID: String) {
        guard let task = task(forBookID: bookID), task.status == .paused else { return }
        pausedIDs.remove(bookID)
        guard contexts[bookID] != nil else { return }
        let work = {
            // 状态必须先同步改回 queued，否则 pump 取到队首时还会把它当暂停跳过
            self.updateNow(bookID) { $0.status = .queued; $0.errorMessage = nil }
            self.enqueue(bookID, front: true)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func togglePause(_ bookID: String) {
        if task(forBookID: bookID)?.status == .paused { resume(bookID) } else { pause(bookID) }
    }

    /// 取消：停止抓取，但已下载的章节保留在书架（可继续读）
    func cancel(_ bookID: String) {
        cancelledIDs.insert(bookID)
        pausedIDs.remove(bookID)
        let work = {
            self.pending.removeAll { $0 == bookID }
            self.updateNow(bookID) { $0.status = .cancelled; $0.errorMessage = nil }
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

        let book = store.createStreamingBook(
            title: detail.title,
            author: detail.author,
            totalChapters: detail.chapters.count,
            source: source.id
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
        cancelledIDs.remove(bookID)
        pausedIDs.remove(bookID)
        contexts[bookID] = (detail, source)
        tasks.insert(task, at: 0)
        enqueue(bookID)
        return bookID
    }

    /// 切后台再回来等场景：如果任务还在但循环已退出，可重新排队（保留已下章节）
    func retryIfNeeded(_ bookID: String) {
        guard let task = task(forBookID: bookID),
              [.failed, .cancelled].contains(task.status),
              contexts[bookID] != nil else { return }
        cancelledIDs.remove(bookID)
        pausedIDs.remove(bookID)
        let work = {
            self.updateNow(bookID) { $0.status = .queued; $0.errorMessage = nil }
            self.enqueue(bookID)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - 下载循环

    private func run(bookID: String, detail: NovelDetail, source: NovelSource) async {
        let total = detail.chapters.count
        // 已写进去的章节数 = 当前 task 进度，续传时从这批之后开始
        var written = task(forBookID: bookID)?.completedChapters ?? 0
        let batch = source.kind?.lowercased() == "fanqie" ? 3 : 4
        var outcome: DownloadStatus = .done
        var failureMessage: String?

        do {
            try await NovelFetcher.streamChapters(
                detail: detail,
                source: source,
                batch: batch,
                // 断点续传：失败/取消/暂停后重新开始时，前面这些章已落盘，从断点继续。
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
                shouldStop: { [weak self] in
                    guard let self else { return true }
                    return self.cancelledIDs.contains(bookID) || self.pausedIDs.contains(bookID)
                },
                waitUntilResumed: {}
            )

            store.finalizeStreamingBook(bookID: bookID, expectedChapters: total)
        } catch {
            let isCancelled = (error as? NovelFetcher.FetchError) == .cancelled
            if isCancelled && pausedIDs.contains(bookID) {
                outcome = .paused
            } else if isCancelled {
                outcome = .cancelled
            } else {
                outcome = .failed
                failureMessage = error.localizedDescription
                NSLog("[Download] failed %@: %@", bookID, error.localizedDescription)
            }
        }

        // 交给主线程的是快照：这些 var 在闭包里被改过，直接捕获会触发并发告警
        let finalStatus = outcome
        let finalWritten = written
        let finalMessage = failureMessage
        await MainActor.run {
            // 用户在这几毫秒内点了「继续」：任务已经重新排队，状态交给下一轮，别覆盖
            let requeued = self.task(forBookID: bookID)?.status == .queued
            if !requeued {
                self.updateNow(bookID) {
                    $0.status = finalStatus
                    $0.completedChapters = finalStatus == .done ? total : finalWritten
                    $0.errorMessage = finalMessage
                }
            }
            if finalStatus == .done {
                self.completedCount += 1
                self.contexts[bookID] = nil
            }
            self.finishRun(bookID)
        }
    }

    /// 搜索结果 detailURL 与详情页 detailURL 保持一致，避免映射错位
    private func resultKey(detail: NovelDetail, source: NovelSource) -> String {
        detail.detailURL.isEmpty ? "\(source.id)|\(detail.title)" : detail.detailURL
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
