import Foundation
import SwiftUI

/// 下载管理器：书一点下载就立刻进书架（占位），正文分批抓、抓完一批写一批，
/// 做到「下几章读几章」；进度直接挂在书架上，支持暂停 / 继续 / 取消。
/// 下载完成后阅读走的仍是原有离线链路，不依赖网络。
final class NovelDownloadManager: ObservableObject {
    static let shared = NovelDownloadManager()

    @Published private(set) var tasks: [DownloadTask] = []
    /// 下载完成书数变化时递增，书架据此刷新
    @Published private(set) var completedCount = 0

    /// 每本书的暂停/继续信号：key 为书架 bookID
    private var pausedIDs = Set<String>()
    private var cancelledIDs = Set<String>()
    private var resumeWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// 保存下载上下文，供「继续」时重新发起（detail/source 不落盘，进程内有效）
    private var contexts: [String: (detail: NovelDetail, source: NovelSource)] = [:]
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

    // MARK: - 暂停 / 继续 / 取消

    func pause(_ bookID: String) {
        guard let task = task(forBookID: bookID), task.isActive else { return }
        pausedIDs.insert(bookID)
        update(bookID) { $0.status = .paused }
    }

    func resume(_ bookID: String) {
        guard let task = task(forBookID: bookID), task.status == .paused else { return }
        pausedIDs.remove(bookID)
        update(bookID) { $0.status = .fetching }
        // 唤醒在批次边界等待的下载循环
        let waiters = resumeWaiters.removeValue(forKey: bookID) ?? []
        waiters.forEach { $0.resume() }
    }

    func togglePause(_ bookID: String) {
        if task(forBookID: bookID)?.status == .paused { resume(bookID) } else { pause(bookID) }
    }

    /// 取消：停止抓取，但已下载的章节保留在书架（可继续读）
    func cancel(_ bookID: String) {
        cancelledIDs.insert(bookID)
        pausedIDs.remove(bookID)
        resumeWaiters.removeValue(forKey: bookID)?.forEach { $0.resume() }
        update(bookID) { $0.status = .cancelled; $0.errorMessage = nil }
        contexts[bookID] = nil
    }

    func dismiss(_ bookID: String) {
        tasks.removeAll { $0.bookID == bookID }
    }

    func clearFinished() {
        tasks.removeAll { [.done, .failed, .cancelled].contains($0.status) }
    }

    // MARK: - 主入口

    /// 点下载立即调用：先建占位书进书架，再后台分批抓正文。
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
            status: .fetching,
            resultBookID: bookID
        )
        cancelledIDs.remove(bookID)
        pausedIDs.remove(bookID)
        contexts[bookID] = (detail, source)
        tasks.insert(task, at: 0)

        Task { [weak self] in
            await self?.run(bookID: bookID, detail: detail, source: source)
        }
        return bookID
    }

    /// 切后台再回来等场景：如果任务还在但循环已退出，可强制重启（保留已下章节）
    func retryIfNeeded(_ bookID: String) {
        guard let ctx = contexts[bookID],
              let task = task(forBookID: bookID),
              [.failed, .cancelled].contains(task.status) else { return }
        cancelledIDs.remove(bookID)
        update(bookID) { $0.status = .fetching; $0.errorMessage = nil }
        Task { [weak self] in
            await self?.run(bookID: bookID, detail: ctx.detail, source: ctx.source)
        }
    }

    // MARK: - 下载循环

    private func run(bookID: String, detail: NovelDetail, source: NovelSource) async {
        let total = detail.chapters.count
        // 已写进去的章节数 = 当前 task 进度，续传时从这批之后开始
        var written = task(forBookID: bookID)?.completedChapters ?? 0
        let batch = source.kind?.lowercased() == "fanqie" ? 3 : 4

        do {
            try await NovelFetcher.streamChapters(
                detail: detail,
                source: source,
                batch: batch,
                // 断点续传：失败/取消后重试时，前面这些章已落盘，从断点继续。
                // 以前这里没传，重试会把整本从头再下一遍（重复正文 + 白烧流量和电）。
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
                shouldPause: { [weak self] in self?.pausedIDs.contains(bookID) ?? false },
                shouldStop: { [weak self] in
                    self?.cancelledIDs.contains(bookID) ?? true
                },
                waitUntilResumed: { [weak self] in
                    await self?.waitForResume(bookID) ?? ()
                }
            )

            guard !cancelledIDs.contains(bookID) else { return }
            store.finalizeStreamingBook(bookID: bookID, expectedChapters: total)
            update(bookID) {
                $0.status = .done
                $0.completedChapters = total
                $0.errorMessage = nil
            }
            contexts[bookID] = nil
            await MainActor.run { completedCount += 1 }
        } catch {
            guard !cancelledIDs.contains(bookID) else { return }
            let isCancelled = (error as? NovelFetcher.FetchError) == .cancelled
            update(bookID) {
                $0.status = isCancelled ? .cancelled : .failed
                $0.completedChapters = written
                $0.errorMessage = isCancelled ? nil : error.localizedDescription
            }
            if !isCancelled { NSLog("[Download] failed %@: %@", bookID, error.localizedDescription) }
        }
    }

    /// 在批次边界挂起，等 resume 唤醒
    private func waitForResume(_ bookID: String) async {
        await withCheckedContinuation { continuation in
            resumeWaiters[bookID, default: []].append(continuation)
        }
    }

    /// 搜索结果 detailURL 与详情页 detailURL 保持一致，避免映射错位
    private func resultKey(detail: NovelDetail, source: NovelSource) -> String {
        detail.detailURL.isEmpty ? "\(source.id)|\(detail.title)" : detail.detailURL
    }

    private func update(_ id: String, _ block: @escaping (inout DownloadTask) -> Void) {
        DispatchQueue.main.async {
            guard let idx = self.tasks.firstIndex(where: { $0.bookID == id }) else { return }
            var t = self.tasks[idx]
            block(&t)
            self.tasks[idx] = t
        }
    }
}
