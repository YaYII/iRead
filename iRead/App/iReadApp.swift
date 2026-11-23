import SwiftUI
import UIKit
import AVFoundation

@main
struct iReadApp: App {
    @StateObject private var store = LibraryStore.shared
    @StateObject private var settings = ReaderSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .onChange(of: scenePhase) { _, phase in
                    // 回到前台时把「屏幕常亮」重新设一遍：iOS 在挂起、控制中心、
                    // 来电之后会清掉这个标志，不重设的话回来写一分钟屏幕又黑了
                    if phase == .active { ScreenAwake.refresh() }
                }
                .onAppear {
                    settings.applyBrightness()
                    Self.runVoiceListIfRequested()
                    Self.runTTSSelfTestIfRequested()
                    Self.runCantoneseSelfTestIfRequested()
                    Self.runCantoneseControlTestIfRequested()
                    Self.runCantoneseRestartTestIfRequested()
                    Self.runCantonesePipelineTestIfRequested()
                    Self.runSpeedSelfTestIfRequested()
                    Self.runDownloadSelfTestIfRequested()
                    Self.runQueueSelfTestIfRequested()
                    Self.runComicQueueSelfTestIfRequested()
                    Self.runResumeSelfTestIfRequested()
                }
        }
    }

    /// 自检：--download-selftest=关键词 时跑通「搜索→详情→下载正文→入库」全链路，
    /// 用日志验证网络书源功能在真机上可用（不依赖 UI 点击）。
    private static func runDownloadSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--download-selftest"), i + 1 < args.count else { return }
        let keyword = args[i + 1]
        Task.detached {
            NSLog("[DL selftest] start keyword=%@", keyword)
            let store = SourceStore.shared
            // 可选 --selftest-source=<id> 指定源；否则默认取第一个 github 源（兼容旧行为）
            var wantedID: String?
            if let si = args.firstIndex(of: "--selftest-source"), si + 1 < args.count {
                wantedID = args[si + 1]
            }
            let source: NovelSource?
            if let wantedID {
                source = store.enabledSources.first { $0.id == wantedID }
            } else {
                source = store.enabledSources.first { $0.kind?.lowercased() == "github" }
            }
            guard let source else {
                NSLog("[DL selftest] no matching source enabled (wanted=%@)", wantedID ?? "github")
                return
            }
            NSLog("[DL selftest] source=%@", source.name)
            do {
                let results = try await NovelFetcher.search(source: source, keyword: keyword)
                NSLog("[DL selftest] search results=%d", results.count)
                guard let target = results.first(where: { $0.title == keyword }) ?? results.first else {
                    NSLog("[DL selftest] no target")
                    return
                }
                let detail = try await NovelFetcher.chapters(result: target, source: source)
                NSLog("[DL selftest] detail=%@ chapters=%d", detail.title, detail.chapters.count)

                // 走新的「边下边读」链路：书立即进书架，分批抓、抓完一批写一批
                let dm = NovelDownloadManager.shared
                let bookID = dm.download(detail: detail, source: source)
                let store = LibraryStore.shared
                NSLog("[DL selftest] book entered shelf immediately id=%@ chapters=%d",
                      bookID, store.book(bookID)?.chapterCount ?? -1)

                // 轮询：观察章节数随下载递增；中途暂停 1 秒后继续，验证暂停/继续可控
                var sawPartial = false
                var didPause = false
                let deadline = Date().addingTimeInterval(180)
                while Date() < deadline {
                    guard let task = dm.task(forBookID: bookID) else { break }
                    let onShelf = store.book(bookID)?.chapterCount ?? 0
                    NSLog("[DL selftest] progress=%d/%d shelfChapters=%d status=%@",
                          task.completedChapters, task.totalChapters, onShelf, task.status.rawValue)
                    if onShelf > 0, onShelf < task.totalChapters { sawPartial = true }
                    // 抓到一部分时暂停，确认章节数停住，再继续
                    if sawPartial, !didPause, onShelf < task.totalChapters {
                        didPause = true
                        dm.pause(bookID)
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let pausedCount = store.book(bookID)?.chapterCount ?? 0
                        NSLog("[DL selftest] after pause status=%@ chapters=%d",
                              dm.task(forBookID: bookID)?.status.rawValue ?? "-", pausedCount)
                        dm.resume(bookID)
                    }
                    if task.status == .done || task.status == .failed || task.status == .cancelled {
                        let finalCount = store.book(bookID)?.chapterCount ?? 0
                        NSLog("[DL selftest] final status=%@ shelfChapters=%d sawPartial=%@ didPause=%@",
                              task.status.rawValue, finalCount, sawPartial ? "YES" : "NO", didPause ? "YES" : "NO")
                        break
                    }
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
            } catch {
                NSLog("[DL selftest] FAILED: %@", error.localizedDescription)
            }
        }
    }

    /// 自检：`--queue-selftest` 同时点两本书下载，验证下载器真的是「一本一本」。
    ///
    /// 分两轮：第一轮不干预，看是不是严格串行、前一本结束后自动接力；
    /// 第二轮（加 `--queue-pause`）在第一本下载中暂停，看操作有没有让出队列位置。
    /// 结果落盘 `Documents/queue-selftest.txt`（真机用 devicectl 取回）。
    ///
    /// 可选参数：`--queue-keyword 斗罗大陆`、`--queue-source bqg-92xs`、
    /// `--queue-chapters 20`、`--queue-pause`。
    private static func runQueueSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--queue-selftest") else { return }
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let keyword = value(after: "--queue-keyword") ?? "斗罗大陆"
        let wantedSource = value(after: "--queue-source") ?? "bqg-92xs"
        let chapterLimit = value(after: "--queue-chapters").flatMap(Int.init) ?? 20
        let testPause = args.contains("--queue-pause")

        Task.detached {
            var lines: [String] = []
            let started = Date()
            func stamp() -> String { String(format: "+%6.1fs", Date().timeIntervalSince(started)) }
            // 这个函数跑在 detached task 里，不能直接调 MainActor 隔离的 writeDebugFile
            func flush() {
                guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                try? lines.joined(separator: "\n").write(
                    to: dir.appendingPathComponent("queue-selftest.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            func log(_ text: String) {
                lines.append("\(stamp()) \(text)")
                flush()
            }
            log("start keyword=\(keyword) source=\(wantedSource) chapters=\(chapterLimit) pause=\(testPause)")

            guard let source = SourceStore.shared.enabledSources.first(where: { $0.id == wantedSource }) else {
                log("FAILED: 没有启用的书源 \(wantedSource)")
                return
            }
            let dm = NovelDownloadManager.shared
            let store = LibraryStore.shared
            var created: [String] = []

            do {
                let results = try await NovelFetcher.search(source: source, keyword: keyword)
                log("search results=\(results.count)")
                // 需要四本：两轮各用两本。第二轮必须换书，否则同一批 URL 命中
                // URLCache，20 章几十毫秒就「下完」，根本取不到暂停窗口。
                guard results.count >= 4 else {
                    log("FAILED: 结果不足四本，无法验证两轮队列")
                    return
                }
                // 每本只取前 N 章：要验证的是调度顺序，不是把整本下完
                var parsed: [NovelDetail] = []
                for result in results.prefix(4) {
                    var detail = try await NovelFetcher.chapters(result: result, source: source)
                    detail.chapters = Array(detail.chapters.prefix(chapterLimit))
                    parsed.append(detail)
                    log("detail 《\(detail.title)》 chapters=\(detail.chapters.count)")
                }
                let books = parsed

                // 一轮 = 连点两本 + 每 80ms 采样，直到两本都结束
                func round(_ name: String, pair: [NovelDetail], pauseFirst: Bool) async -> Bool {
                    let first = await MainActor.run { dm.download(detail: pair[0], source: source) }
                    let second = await MainActor.run { dm.download(detail: pair[1], source: source) }
                    created.append(contentsOf: [first, second])
                    log("\(name) enqueued 《\(pair[0].title)》《\(pair[1].title)》")

                    var maxFetching = 0
                    var overlaps = 0
                    var firstEndAt: Date?
                    var secondStartAfterFirstEnd: Bool?
                    var pausedFirst = false
                    var pauseStartedAt: Date?
                    var secondRanWhilePaused = false
                    var resumed = false
                    let deadline = Date().addingTimeInterval(300)

                    while Date() < deadline {
                        let snap = await MainActor.run { dm.tasks }
                        let fetching = snap.filter { $0.status == .fetching }
                        maxFetching = max(maxFetching, fetching.count)
                        if fetching.count > 1 {
                            overlaps += 1
                            log("\(name) OVERLAP! \(fetching.map(\.title).joined(separator: " + "))")
                        }
                        let t1 = snap.first { $0.bookID == first }
                        let t2 = snap.first { $0.bookID == second }

                        if firstEndAt == nil, let t1, [.done, .failed, .cancelled].contains(t1.status) {
                            firstEndAt = Date()
                            log("\(name) first end \(t1.status.rawValue) \(t1.completedChapters)/\(t1.totalChapters)")
                        }
                        if secondStartAfterFirstEnd == nil, let t2, t2.status == .fetching {
                            secondStartAfterFirstEnd = firstEndAt != nil
                            log("\(name) second start afterFirstEnd=\(firstEndAt != nil)")
                        }
                        // 第一本下到一半时按暂停：它该让出位置，第二本接着跑
                        if pauseFirst, !pausedFirst, let t1, t1.status == .fetching, t1.completedChapters > 0 {
                            pausedFirst = true
                            pauseStartedAt = Date()
                            await MainActor.run { dm.pause(first) }
                            log("\(name) pause first at \(t1.completedChapters)/\(t1.totalChapters)")
                        }
                        if pausedFirst, !resumed, let t2, t2.status == .fetching {
                            secondRanWhilePaused = true
                        }
                        // 暂停满 1 秒再继续，给第二本留出真正开跑的时间
                        if pausedFirst, !resumed, let pauseStartedAt,
                           Date().timeIntervalSince(pauseStartedAt) > 1.0 {
                            resumed = true
                            await MainActor.run { dm.resume(first) }
                            log("\(name) resume first")
                        }

                        let done1 = t1.map { [.done, .failed, .cancelled].contains($0.status) } ?? false
                        let done2 = t2.map { [.done, .failed, .cancelled].contains($0.status) } ?? false
                        if done1 && done2 { break }
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }

                    let t1 = await MainActor.run { dm.task(forBookID: first) }
                    let t2 = await MainActor.run { dm.task(forBookID: second) }
                    log("\(name) final first=\(t1?.status.rawValue ?? "nil") \(t1?.completedChapters ?? -1)/\(t1?.totalChapters ?? -1)")
                    log("\(name) final second=\(t2?.status.rawValue ?? "nil") \(t2?.completedChapters ?? -1)/\(t2?.totalChapters ?? -1)")
                    log("\(name) maxFetching=\(maxFetching) overlaps=\(overlaps) secondStart=\(secondStartAfterFirstEnd.map { $0 ? "after-first" : "before-first" } ?? "never")")

                    let serialOK = maxFetching <= 1
                    if pauseFirst {
                        let ok = serialOK && pausedFirst && secondRanWhilePaused && resumed
                        log("\(name) VERDICT serial=\(serialOK ? "PASS" : "FAIL") pauseRelease=\(secondRanWhilePaused ? "PASS" : "FAIL") resume=\(resumed ? "PASS" : "FAIL")")
                        return ok
                    }
                    let handoff = secondStartAfterFirstEnd ?? false
                    log("\(name) VERDICT serial=\(serialOK ? "PASS" : "FAIL") handoff=\(handoff ? "PASS" : "FAIL")")
                    return serialOK && handoff
                }

                let round1 = await round("round1", pair: Array(books[0..<2]), pauseFirst: false)

                if testPause {
                    let round2 = await round("round2", pair: Array(books[2..<4]), pauseFirst: true)
                    log("ALL \(round1 && round2 ? "PASS" : "FAIL")")
                } else {
                    log("ALL \(round1 ? "PASS" : "FAIL")")
                }
            } catch {
                log("FAILED: \(error.localizedDescription)")
            }

            // 自检建的书从书架清掉，别污染正式藏书
            for id in created {
                if let book = store.book(id) {
                    await MainActor.run { store.delete(book: book) }
                }
            }
            log("cleanup removed \(created.count) test books")
        }
    }

    /// 自检：`--resume-selftest` 验证「闪退后自动续传」。
    ///
    /// 复现方式（不用真的杀进程）：先按正常流程建书、只写入前 `--resume-seed` 章
    /// （等价于下到一半被系统杀掉），状态留在「下载中」，然后让下载器
    /// `debugReloadFromDisk()` 重新从磁盘恢复一次 —— 这跟重启 App 后的 `init` 走同一条路。
    ///
    /// 判定：
    /// ① 续传起点 = 已写章数（不是 0，否则等于整本重下）；
    /// ② 没有重复下载：`fetched` 等于目录章数，且**文件里第一章标题只出现 1 次**
    ///    （从头重下的话这一章会被写第二遍）。注意不能拿 `chapterCount` 判 ——
    ///    它是 `TextParser` 按标题识别出来的，站点标题不规范时会比实际少一两章；
    /// ③ 暂停状态能活过重启（恢复后仍是暂停、不会自己开跑，章节数不动）。
    ///
    /// 结果落盘 `Documents/resume-selftest.txt`，跑完把测试书删掉。
    private static func runResumeSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--resume-selftest") else { return }
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let keyword = value(after: "--resume-keyword") ?? "斗罗大陆"
        let wantedSource = value(after: "--resume-source") ?? "bqg-92xs"
        let totalChapters = value(after: "--resume-chapters").flatMap(Int.init) ?? 12
        let seedChapters = value(after: "--resume-seed").flatMap(Int.init) ?? 4

        Task.detached {
            var lines: [String] = []
            let started = Date()
            func stamp() -> String { String(format: "+%6.1fs", Date().timeIntervalSince(started)) }
            func flush() {
                guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                try? lines.joined(separator: "\n").write(
                    to: dir.appendingPathComponent("resume-selftest.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            func log(_ text: String) {
                lines.append("\(stamp()) \(text)")
                flush()
            }
            log("start keyword=\(keyword) source=\(wantedSource) total=\(totalChapters) seed=\(seedChapters)")

            guard let source = SourceStore.shared.enabledSources.first(where: { $0.id == wantedSource }) else {
                log("FAILED: 没有启用的书源 \(wantedSource)")
                return
            }
            let dm = NovelDownloadManager.shared
            let store = LibraryStore.shared
            var created: [String] = []
            // 恢复时会重新回源抓目录（这是真实行为），这里截断到同样的章数，
            // 否则一本 700 章的书要下好几分钟才轮得到判定
            await MainActor.run { dm.debugChapterLimit = totalChapters }

            do {
                let results = try await NovelFetcher.search(source: source, keyword: keyword)
                guard results.count >= 2 else {
                    log("FAILED: 结果不足两本（一本测续传、一本测暂停）")
                    return
                }
                var details: [NovelDetail] = []
                for result in results.prefix(2) {
                    var detail = try await NovelFetcher.chapters(result: result, source: source)
                    detail.chapters = Array(detail.chapters.prefix(totalChapters))
                    details.append(detail)
                    log("detail 《\(detail.title)》 chapters=\(detail.chapters.count)")
                }

                // 造现场：建书 + 只写前 seed 章 + 状态停在「下载中」
                func seedHalfDownloaded(_ detail: NovelDetail) async throws -> String {
                    let bookID: String = await MainActor.run {
                        let book = store.createStreamingBook(
                            title: detail.title,
                            author: detail.author,
                            totalChapters: detail.chapters.count,
                            source: source.id,
                            remoteURL: detail.detailURL
                        )
                        return book.id
                    }
                    var payload: [(title: String, text: String)] = []
                    for chapter in detail.chapters.prefix(seedChapters) {
                        let text = try await NovelFetcher.content(chapter: chapter, source: source)
                        payload.append((chapter.title, text))
                    }
                    let batch = payload
                    await MainActor.run {
                        store.appendChapters(to: bookID, chapters: batch)
                        store.setDownloadState(bookID: bookID, state: .fetching, total: detail.chapters.count)
                    }
                    return bookID
                }

                // 同名残留先清掉，保证从「一章没下」开始
                for detail in details {
                    for book in store.books where book.title == detail.title && !book.isComic {
                        await MainActor.run {
                            dm.dismiss(book.id)
                            store.delete(book: book)
                        }
                    }
                }

                // MARK: 第一轮 · 下载到一半被闪退
                let first = try await seedHalfDownloaded(details[0])
                created.append(first)
                let before = await MainActor.run { store.book(first) }
                log("造现场 《\(details[0].title)》 已写=\(before?.downloadedChapters ?? -1) chapterCount=\(before?.chapterCount ?? -1) state=\(before?.downloadState?.rawValue ?? "-")")

                await MainActor.run { dm.debugReloadFromDisk() }
                let restored = await MainActor.run { dm.task(forBookID: first) }
                log("恢复后 起点=\(restored?.completedChapters ?? -1) 总数=\(restored?.totalChapters ?? -1) 状态=\(restored?.status.rawValue ?? "nil")")

                let deadline = Date().addingTimeInterval(240)
                while Date() < deadline {
                    let task = await MainActor.run { dm.task(forBookID: first) }
                    guard let task else { break }
                    if [.done, .failed, .cancelled].contains(task.status) {
                        log("结束 \(task.status.rawValue) \(task.completedChapters)/\(task.totalChapters)")
                        break
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }

                let after = await MainActor.run { store.book(first) }
                let expected = details[0].chapters.count
                let chapters = after?.chapterCount ?? -1
                let fetched = after?.download?.fetched ?? -1
                // 是否重复下载，直接看文件里第一章标题出现了几次：
                // 从 0 重下的话，这一章会被写第二遍。
                let repeatCount: Int = await MainActor.run {
                    guard let book = after,
                          let body = try? String(
                            contentsOf: store.booksDir.appendingPathComponent(book.fileName),
                            encoding: .utf8
                          ) else { return -1 }
                    let title = details[0].chapters[0].title
                    guard !title.isEmpty else { return -1 }
                    return body.components(separatedBy: title).count - 1
                }
                let startOK = (restored?.completedChapters ?? -1) == seedChapters
                // chapterCount 是「解析出来的章数」，个别标题站点写得怪会少算一两章，
                // 不能拿它当唯一判据；抓取口径（fetched）和文件里有没有重复才是关键。
                let noDuplicate = fetched == expected && repeatCount == 1
                log("最终 落盘=\(chapters) fetched=\(fetched) 期望=\(expected) 首章重复=\(repeatCount) 次")

                // MARK: 第二轮 · 暂停要能活过重启
                let second = try await seedHalfDownloaded(details[1])
                created.append(second)
                await MainActor.run {
                    store.setDownloadState(bookID: second, state: .paused, total: details[1].chapters.count)
                    dm.debugReloadFromDisk()
                }
                let pausedTask = await MainActor.run { dm.task(forBookID: second) }
                // 给队列 3 秒机会：暂停的书如果被错误地自动开跑，这里就能看出来
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let pausedBook = await MainActor.run { store.book(second) }
                let statusAfterWait = await MainActor.run { dm.task(forBookID: second)?.status }
                let stayedPaused = pausedTask?.status == .paused && statusAfterWait == .paused
                let untouched = (pausedBook?.downloadedChapters ?? -1) == seedChapters
                log("暂停轮 状态=\(pausedTask?.status.rawValue ?? "nil") 3 秒后已写=\(pausedBook?.downloadedChapters ?? -1)")

                log("VERDICT 续传起点=\(startOK ? "PASS" : "FAIL") 无重复下载=\(noDuplicate ? "PASS" : "FAIL") 暂停保持=\(stayedPaused && untouched ? "PASS" : "FAIL")")
                let allPass = startOK && noDuplicate && stayedPaused && untouched
                log("ALL \(allPass ? "PASS" : "FAIL")")
            } catch {
                log("FAILED: \(error.localizedDescription)")
            }

            for id in created {
                await MainActor.run {
                    dm.dismiss(id)
                    if let book = store.book(id) { store.delete(book: book) }
                }
            }
            await MainActor.run { dm.debugChapterLimit = nil }
            log("cleanup removed \(created.count) test books")
        }
    }

    /// 自检：`--comic-queue-selftest` 同时「缓存全部」两本漫画，验证整本串行。
    ///
    /// 要回答的问题：两本会不会同时在下？第二本是不是等第一本结束才自动接手？
    /// 结果落盘 `Documents/comic-queue-selftest.txt`。
    /// 每本只排队前 `--comic-chapters`（默认 2）话，测完把建的书删掉。
    private static func runComicQueueSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--comic-queue-selftest") else { return }
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let keyword = value(after: "--comic-keyword") ?? "鬼滅之刃"
        let chapterLimit = value(after: "--comic-chapters").flatMap(Int.init) ?? 2

        Task.detached {
            var lines: [String] = []
            let started = Date()
            func stamp() -> String { String(format: "+%6.1fs", Date().timeIntervalSince(started)) }
            func flush() {
                guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                try? lines.joined(separator: "\n").write(
                    to: dir.appendingPathComponent("comic-queue-selftest.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            func log(_ text: String) {
                lines.append("\(stamp()) \(text)")
                flush()
            }
            log("start keyword=\(keyword) chapters=\(chapterLimit)")

            guard let source = SourceStore.shared.enabledComicSources.first(where: { $0.kind?.lowercased() == "mangadex" }) else {
                log("FAILED: 没有启用的漫画源")
                return
            }
            let manager = await MainActor.run { ComicDownloadManager.shared }
            let store = LibraryStore.shared
            var createdIDs: [String] = []

            do {
                let results = try await ComicFetcher.search(source: source, keyword: keyword)
                log("search results=\(results.count)")
                guard results.count >= 2 else {
                    log("FAILED: 漫画结果不足两本")
                    return
                }

                var books: [Book] = []
                for result in results.prefix(2) {
                    let detail = try await ComicFetcher.detail(result: result, source: source)
                    log("detail 《\(detail.title)》 chapters=\(detail.chapters.count)")
                    // 同名漫画先清掉再建：保证每轮都是从「一话没下」开始的干净状态，
                    // 否则上一轮下过的图会让这一轮几十毫秒就结束，取不到并发窗口
                    if let existing = store.comicBook(remoteKey: result.detailURL) {
                        await MainActor.run {
                            manager.forget(existing.id)
                            store.delete(book: existing)
                        }
                    }
                    let book = store.createComicBook(
                        title: detail.title,
                        author: detail.author,
                        sourceID: source.id,
                        remoteURL: result.detailURL,
                        chapters: detail.chapters
                    )
                    createdIDs.append(book.id)
                    books.append(book)
                    // 只下前几话：验证的是「整本串行」，不是把上百话下完
                    let targets = detail.chapters.prefix(chapterLimit).map(\.index)
                    await MainActor.run {
                        manager.start(book: book, source: source, chapters: Array(targets))
                    }
                    log("start 《\(book.title)》 chapters=\(targets.count)")
                    // 中间不等待：第二本应当直接进队列
                }
                let shelfBooks = books

                var maxRunning = 0
                var overlaps = 0
                var firstEndAt: Date?
                var secondStartAfterFirstEnd: Bool?
                let deadline = Date().addingTimeInterval(420)
                while Date() < deadline {
                    let snap = await MainActor.run { manager.tasks }
                    let running = snap.values.filter { $0.status == .fetching }
                    maxRunning = max(maxRunning, running.count)
                    if running.count > 1 {
                        overlaps += 1
                        log("OVERLAP! \(running.map(\.title).joined(separator: " + "))")
                    }
                    let t1 = snap[shelfBooks[0].id]
                    let t2 = snap[shelfBooks[1].id]
                    if firstEndAt == nil, let t1, [.done, .failed, .cancelled].contains(t1.status) {
                        firstEndAt = Date()
                        log("first end \(t1.status.rawValue) \(t1.completed)/\(t1.total) 话")
                    }
                    if secondStartAfterFirstEnd == nil, let t2, t2.status == .fetching {
                        secondStartAfterFirstEnd = firstEndAt != nil
                        log("second start afterFirstEnd=\(firstEndAt != nil)")
                    }
                    // 漫画任务在结束后 2.5s 会被清出字典，nil 就是「已经收尾」，不能当未完
                    let done1 = t1.map { [.done, .failed, .cancelled].contains($0.status) } ?? true
                    let done2 = t2.map { [.done, .failed, .cancelled].contains($0.status) } ?? true
                    if done1 && done2 { break }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }

                let t1 = await MainActor.run { manager.task(for: shelfBooks[0].id) }
                let t2 = await MainActor.run { manager.task(for: shelfBooks[1].id) }
                log("final first=\(t1?.status.rawValue ?? "nil") \(t1?.completed ?? -1)/\(t1?.total ?? -1)")
                log("final second=\(t2?.status.rawValue ?? "nil") \(t2?.completed ?? -1)/\(t2?.total ?? -1)")
                log("maxRunning=\(maxRunning) overlaps=\(overlaps)")
                let serialOK = maxRunning <= 1
                let handoff = secondStartAfterFirstEnd ?? false
                log("VERDICT 串行=\(serialOK ? "PASS" : "FAIL") 接力=\(handoff ? "PASS" : "FAIL")")
            } catch {
                log("FAILED: \(error.localizedDescription)")
            }

            for id in createdIDs {
                await MainActor.run { manager.forget(id) }
                if let book = store.book(id) {
                    await MainActor.run {
                        ComicDownloadManager.shared.forget(id)
                        store.delete(book: book)
                    }
                }
            }
            log("cleanup removed \(createdIDs.count) test books")
        }
    }

    /// 调试用：启动参数 `--list-voices` 时打印系统全部语音，
    /// 用来确认中文男声/粤语是否真的存在（不靠猜）。
    ///
    /// 真机上 stdout 拿不到（除非开着 Xcode 控制台），所以同时落盘到
    /// `Documents/voices.txt`，用 `devicectl device copy from` 取回。
    private static func runVoiceListIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--list-voices") else { return }
        let all = AVSpeechSynthesisVoice.speechVoices()
        var lines = ["total=\(all.count)"]
        for v in all.sorted(by: { $0.language < $1.language }) {
            lines.append("\(v.language) | \(v.name) | q=\(v.quality.rawValue) | \(v.identifier)")
        }
        lines.append("maleChinese=\(SpeechService.maleChineseVoice()?.name ?? "nil") lang=\(SpeechService.maleChineseVoice()?.language ?? "-")")
        lines.append("cantonese=\(SpeechService.cantoneseVoice()?.name ?? "nil") lang=\(SpeechService.cantoneseVoice()?.language ?? "-") id=\(SpeechService.cantoneseVoice()?.identifier ?? "-")")
        let text = lines.joined(separator: "\n")
        print("[Voices]\n\(text)")
        writeDebugFile(text, name: "voices.txt")
    }

    /// 调试用：`--yue-selftest` 跑一遍粤语播放链路，逐秒采样状态，
    /// 结果落盘到 `Documents/yue-selftest.txt`。
    ///
    /// 要回答的问题：选粤语后到底用了哪个音色、引擎在不在出声（`range` 有没有推进）、
    /// 会不会自动接下一段、有没有中途「静默停住」。
    /// 加 `--yue-long` 改用真实长度的整段文字（约 260 字，和 ListeningCenter 的切段一致）。
    private static func runCantoneseSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--yue-selftest") else { return }

        let isLong = args.contains("--yue-long")
        let voice = SpeechService.cantoneseVoice()
        // 段首故意带全角空格和换行：验证 speech.start 里的 trim 会不会让高亮偏移
        let paragraph = "　　夜色沉下来，城市的灯一盏一盏亮起，像有人把碎金撒在湿漉漉的柏油路上。老陈把卷帘门拉到一半，弯腰钻进去，随手拍了拍肩上的雨珠。收音机里正播着粤剧，锣鼓点子一下一下敲在空气里，把他带回了三十年前的西关大屋。\n"
        let chunks: [String] = isLong
            ? [String(repeating: paragraph, count: 3), String(repeating: paragraph, count: 3)]
            : ["第一段测试，粤语朗读是否正常。", "第二段测试，看它能不能自己接下去。", "第三段测试，到这里应该就结束了。"]
        let watchdog = isLong ? 180 : 25

        var lines: [String] = []
        var index = 0
        let started = Date()
        func stamp() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
        func flush() { writeDebugFile(lines.joined(separator: "\n"), name: "yue-selftest.txt") }

        let svc = SpeechService.shared
        lines.append("mode=\(isLong ? "long" : "short")")
        lines.append("available=\(SpeechService.isCantoneseAvailable)")
        lines.append("voice=\(voice?.name ?? "nil") lang=\(voice?.language ?? "-") q=\(voice?.quality.rawValue ?? -1) id=\(voice?.identifier ?? "-")")
        lines.append("chunks=\(chunks.count) lens=\(chunks.map(\.count))")
        flush()

        svc.onAdvance = {
            lines.append("\(stamp()) ADVANCE #\(index) engine=\(svc.activeEngine.rawValue) voice=\(svc.debugCurrentVoiceName ?? "-")")
            index += 1
            flush()
            if index < chunks.count {
                lines.append("\(stamp()) CALL start #\(index) len=\(chunks[index].count)")
                flush()
                svc.start(text: chunks[index], speed: 1.4, profile: .cantonese)
                lines.append("\(stamp()) AFTER start #\(index) active=\(svc.isActive) engine=\(svc.activeEngine.rawValue)")
                flush()
            } else {
                lines.append("\(stamp()) ALL DONE engine=\(svc.activeEngine.rawValue)")
                svc.stop()
                flush()
            }
        }

        // 引擎内部状态变化（start / stop / startSystem / delegate 回调）都记进同一个文件
        svc.debugTrace = { message in
            DispatchQueue.main.async {
                lines.append("\(stamp()) TRACE \(message)")
                flush()
            }
        }

        // 先把可能残留的听书会话清掉，排除「别的东西抢占播放」的干扰（必须在 start 之前）
        ListeningCenter.shared.stop()
        svc.start(text: chunks[0], speed: 1.4, profile: .cantonese)
        lines.append("\(stamp()) START engine=\(svc.activeEngine.rawValue) voice=\(svc.debugCurrentVoiceName ?? "-")")
        flush()

        // 每秒采样：range 在推进 = 引擎真的在念；连着一动不动 = 静默卡住
        var tick = 0
        var sameRangeTicks = 0
        var lastRange = ""
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            tick += 1
            let range = svc.spokenRange.map { "\($0.location)+\($0.length)" } ?? "-"
            if range == lastRange { sameRangeTicks += 1 } else { sameRangeTicks = 0; lastRange = range }
            lines.append("\(stamp()) t=\(tick) active=\(svc.isActive) paused=\(svc.isPaused) speaking=\(svc.isSpeaking) engine=\(svc.activeEngine.rawValue) range=\(range)")
            if svc.isActive && !svc.isPaused && sameRangeTicks == 8 {
                lines.append("\(stamp()) ⚠️ STALL：8 秒内 range 没动")
            }
            flush()
            if tick >= watchdog {
                timer.invalidate()
                lines.append("\(stamp()) WATCHDOG end (\(watchdog)s)")
                svc.stop()
                flush()
            }
        }
    }

    /// 调试用：`--yue-control` 专测「控制」这条链路 —— 暂停到底有没有真的停、
    /// 继续能不能接上、改语速会不会重新起。
    /// 结果落盘 `Documents/yue-control.txt`。
    private static func runCantoneseControlTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--yue-control") else { return }
        let svc = SpeechService.shared
        let text = String(
            repeating: "　　夜色沉下来，城市的灯一盏一盏亮起，像有人把碎金撒在湿漉漉的柏油路上。老陈把卷帘门拉到一半，弯腰钻进去，随手拍了拍肩上的雨珠。\n",
            count: 3
        )
        var lines: [String] = []
        let started = Date()
        func stamp() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
        func flush() { writeDebugFile(lines.joined(separator: "\n"), name: "yue-control.txt") }

        lines.append("text.length=\(text.count)")
        flush()

        svc.debugTrace = { message in
            DispatchQueue.main.async {
                lines.append("\(stamp()) TRACE \(message)")
                flush()
            }
        }
        svc.onAdvance = {
            lines.append("\(stamp()) ADVANCE (unexpected in control test)")
            flush()
        }
        svc.start(text: text, speed: 1.0, profile: .cantonese)
        lines.append("\(stamp()) START \(svc.debugSynthesizerState)")
        flush()

        var tick = 0
        var lastRange = ""
        var frozenTicks = 0
        var pausedAt = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            tick += 1
            let range = svc.spokenRange.map { "\($0.location)+\($0.length)" } ?? "-"
            if range == lastRange { frozenTicks += 1 } else { frozenTicks = 0; lastRange = range }

            switch tick {
            case 6:   // +3s：暂停
                lines.append("\(stamp()) >>> pause()")
                svc.pause()
                pausedAt = tick
            case 16:  // +8s：继续
                lines.append("\(stamp()) >>> resume()  (暂停已持续 \((tick - pausedAt) / 2)s)")
                svc.resume()
            case 22:  // +11s：暂停中改语速，看是否会重新起
                lines.append("\(stamp()) >>> speed 1.0 -> 0.8 (paused=\(svc.isPaused))")
                ReaderSettings.shared.speechSpeed = 0.8
            case 30:  // +15s：收尾
                lines.append("\(stamp()) >>> stop()")
                svc.stop()
                timer.invalidate()
                flush()
                return
            default: break
            }

            lines.append("\(stamp()) t\(tick) active=\(svc.isActive) paused=\(svc.isPaused) speaking=\(svc.isSpeaking) \(svc.debugSynthesizerState) range=\(range) frozen=\(frozenTicks)")
            flush()
        }
    }

    /// 调试用：`--yue-restart` 连续「打断重播」——等价于用户改语速 / 切章 / 换音色，
    /// 每次都走 `start()` 里那条 `stopSpeaking` → `speak` 的路。
    /// 判断标准：每次重播后 range 是否还能继续推进（不推进 = 声音被吞，静默卡死）。
    private static func runCantoneseRestartTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--yue-restart") else { return }
        let svc = SpeechService.shared
        let paragraph = "　　夜色沉下来，城市的灯一盏一盏亮起，像有人把碎金撒在湿漉漉的柏油路上。老陈把卷帘门拉到一半，弯腰钻进去，随手拍了拍肩上的雨珠。\n"
        var lines: [String] = []
        let started = Date()
        func stamp() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
        func flush() { writeDebugFile(lines.joined(separator: "\n"), name: "yue-restart.txt") }

        svc.debugTrace = { message in
            DispatchQueue.main.async {
                lines.append("\(stamp()) TRACE \(message)")
                flush()
            }
        }
        // 真机上 onAdvance 是接下一段的唯一入口：打断重播时它被误触发，
        // 就是「点一下控制，正文往前蹦一段」的病根。
        var spuriousAdvances = 0
        svc.onAdvance = {
            spuriousAdvances += 1
            lines.append("\(stamp()) ⚠️ onAdvance 被触发 #\(spuriousAdvances)（打断重播时不该发生）")
            flush()
        }
        svc.start(text: String(repeating: paragraph, count: 3), speed: 1.0, profile: .cantonese)
        lines.append("\(stamp()) START #0 rate=0.5 \(svc.debugSynthesizerState)")
        flush()

        var tick = 0
        var round = 0
        var lastRange = ""
        var frozen = 0
        var marks: [(tick: Int, range: String)] = []

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            tick += 1
            let range = svc.spokenRange.map { "\($0.location)+\($0.length)" } ?? "-"
            if range == lastRange { frozen += 1 } else { frozen = 0; lastRange = range }

            if tick == 8 || tick == 16 || tick == 24 {
                round += 1
                lines.append("\(stamp()) >>> RESTART #\(round) (rangeBefore=\(range) frozen=\(frozen))")
                svc.start(text: String(repeating: paragraph, count: 3), speed: 0.8, profile: .cantonese)
                marks.append((tick, range))
                frozen = 0
                lines.append("\(stamp()) after start #\(round) \(svc.debugSynthesizerState) active=\(svc.isActive)")
            }
            if tick >= 32 {
                timer.invalidate()
                lines.append("\(stamp()) END frozen=\(frozen) range=\(range) spuriousAdvances=\(spuriousAdvances)")
                svc.stop()
                flush()
                return
            }
            lines.append("\(stamp()) t\(tick) active=\(svc.isActive) paused=\(svc.isPaused) \(svc.debugSynthesizerState) range=\(range) frozen=\(frozen)")
            flush()
        }
    }

    /// 调试用：`--yue-pipeline` 走**真实听书链路**（真的书、真的切段、真的按钮），
    /// 把用户的操作用 `ListeningCenter.toggle()` 复现一遍：播放 → 暂停 → 暂停中改语速
    /// → 继续 → 再暂停 → 继续 → 停止。
    /// 判断标准：① 暂停期间 currentChar 不许自己往前跑；② 改语速后从**当前句**重读，
    /// 不许跳到下一段；③ 每次「继续」都真的出声。
    /// 结果落盘 `Documents/yue-pipeline.txt`。
    private static func runCantonesePipelineTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--yue-pipeline") else { return }
        let listening = ListeningCenter.shared
        let settings = ReaderSettings.shared
        var lines: [String] = []
        let started = Date()
        func stamp() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
        func flush() { writeDebugFile(lines.joined(separator: "\n"), name: "yue-pipeline.txt") }
        func snap(_ tag: String) -> String {
            "\(stamp()) \(tag) active=\(listening.isActive) paused=\(listening.isPaused) "
                + "char=\(listening.currentChar) ch=\(listening.spokenChapter) "
                + "\(SpeechService.shared.debugSynthesizerState)"
        }

        settings.voiceProfile = .cantonese
        settings.speechSpeed = 1.0

        // 等内置书灌进书架再开播
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let book = LibraryStore.shared.books.first else {
                lines.append("\(stamp()) ❌ 没有书，无法测试")
                flush()
                return
            }
            lines.append("\(stamp()) 书=\(book.title) id=\(book.id) voice=\(settings.voiceProfile.rawValue)")
            flush()
            listening.resume(bookID: book.id)

            var tick = 0
            var wasPaused = false
            var pauseBaseline = 0
            var pauseMax = 0
            var drifts: [Int] = []
            // 追一遍 SpeechService 内部的 start/stop/pause，看清「谁在什么时候重新起了一句」
            SpeechService.shared.debugTrace = { message in
                DispatchQueue.main.async {
                    lines.append("\(stamp())   · \(message)")
                    flush()
                }
            }
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                tick += 1
                // 暂停真正生效那一刻起算：期间 char 再往前跑多少
                if listening.isPaused {
                    if wasPaused {
                        pauseMax = max(pauseMax, listening.currentChar)
                    } else {
                        pauseBaseline = listening.currentChar
                        pauseMax = listening.currentChar
                    }
                } else if wasPaused {
                    drifts.append(pauseMax - pauseBaseline)
                }
                wasPaused = listening.isPaused

                switch tick {
                case 8:  // +4s：点暂停
                    lines.append(snap(">>> toggle() 暂停"))
                    listening.toggle()
                case 12: // +6s：暂停中改语速
                    lines.append("\(stamp()) >>> 暂停中改语速 1.0 -> 0.7")
                    settings.speechSpeed = 0.7
                case 18: // +9s：点继续（应按新语速从当前句重来）
                    lines.append(snap(">>> toggle() 继续"))
                    listening.toggle()
                case 26: // +13s：再暂停
                    lines.append(snap(">>> toggle() 再暂停"))
                    listening.toggle()
                case 32: // +16s：再继续
                    lines.append(snap(">>> toggle() 再继续"))
                    listening.toggle()
                case 40: // +20s：收尾
                    timer.invalidate()
                    lines.append(snap("END"))
                    lines.append("暂停期间 char 额外前进量=\(drifts)（应只有 0～几个字，不能一直往前跑）")
                    SpeechService.shared.debugTrace = nil
                    listening.stop()
                    flush()
                    return
                default: break
                }
                lines.append(snap("t\(tick)"))
                flush()
            }
        }
    }

    /// 自检：`--speed-selftest` 用内置女声依次以 1.0x / 2.0x / 4.0x 念同一段话，
    /// 记下每档**实际耗时**。
    ///
    /// 要验证的是「合成封顶 2 倍 + `AVAudioUnitTimePitch` 拉伸」这条路真的能到 4 倍：
    /// 如果 4.0x 的耗时约等于 1.0x 的 1/4，说明拉伸生效、而且播放回调也跟着加速了
    /// （高亮不会掉队）；如果耗时几乎没变，说明 timePitch 没接进图里。
    /// 结果落盘 `Documents/speed-selftest.txt`。
    private static func runSpeedSelfTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--speed-selftest") else { return }
        let svc = SpeechService.shared
        // 只用**一句**：多句的话总耗时会被逐句合成的 CPU 时间盖住，量不出播放倍率。
        // 第一档 1.0x 当预热（模型首次加载要几秒），不计入对比。
        let text = "夜色沉下来，城市的灯一盏一盏亮起。"
        let speeds: [Double] = [1.0, 1.0, 2.0, 4.0]

        var index = 0
        var lines: [String] = []
        var legStart = Date()
        let started = Date()
        func stamp() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
        func flush() { writeDebugFile(lines.joined(separator: "\n"), name: "speed-selftest.txt") }

        // 别让听书会话抢播放
        ListeningCenter.shared.stop()
        lines.append("textLen=\(text.count) speeds=\(speeds)")
        flush()

        // 先量一下模型对 speed 的响应：同样的文字，speed 越大音频应该越短。
        // 这一步是「播放倍率对不上」时的第一手证据。
        DispatchQueue.global(qos: .userInitiated).async {
            let piper = PiperSynthesizer.shared
            guard piper.loadIfNeeded(.female) else {
                lines.append("synth sweep: model load failed")
                flush()
                return
            }
            let token = piper.currentToken()
            for s in [1.0, 1.5, 2.0] as [Float] {
                let t0 = Date()
                if let r = piper.synthesize(text: text, speed: s, model: .female, token: token) {
                    let sec = Double(r.samples.count) / Double(r.sampleRate)
                    lines.append(String(format: "synth sweep speed=%.1f audio=%.2fs cost=%.2fs",
                                        s, sec, Date().timeIntervalSince(t0)))
                } else {
                    lines.append(String(format: "synth sweep speed=%.1f FAILED", s))
                }
                flush()
            }
        }

        func playNext() {
            guard index < speeds.count else {
                lines.append("\(stamp()) ALL DONE")
                flush()
                svc.stop()
                return
            }
            let speed = speeds[index]
            lines.append("\(stamp()) >>> \(speed)x begin")
            flush()
            legStart = Date()
            svc.start(text: text, speed: speed, profile: .neuralFemale)
        }

        svc.onAdvance = {
            let elapsed = Date().timeIntervalSince(legStart)
            lines.append(String(format: "%.1fs <<< %@x done elapsed=%.2fs engine=%@",
                                Date().timeIntervalSince(started), "\(speeds[index])",
                                elapsed, svc.activeEngine.rawValue))
            flush()
            index += 1
            playNext()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { playNext() }
    }

    /// 把调试输出写到 Documents/，真机可通过 devicectl 取回
    private static func writeDebugFile(_ text: String, name: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 调试用：启动参数 `--tts-selftest` 时合成一句样本并打印耗时，
    /// 用于在无人工听感的自动化环境里验证本地语音链路是否真的通了。
    private static func runTTSSelfTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--tts-selftest") else { return }
        let piper = PiperSynthesizer.shared
        print("[SelfTest] piper available=\(piper.isAvailable)")
        let args = ProcessInfo.processInfo.arguments
        let models: [PiperModel] = args.contains("--male-only") ? [.male]
            : args.contains("--female-only") ? [.female]
            : PiperModel.allCases
        for m in models {
            print("[SelfTest] model \(m.rawValue) gender=\(m.genderName) available=\(piper.isAvailable(m))")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            for model in models {
                let t0 = Date()
                let ok = piper.loadIfNeeded(model)
                let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
                print("[SelfTest] load \(model.rawValue) ok=\(ok) cost=\(loadMs)ms rate=\(piper.outputSampleRate(model)) err=\(piper.errorDescription ?? "-")")
                guard ok else { continue }
                let token = piper.currentToken()
                for text in ["这是一段本地语音测试。", "夜色沉下来，城市的灯一盏一盏亮起。"] {
                    let t1 = Date()
                    let res = piper.synthesize(text: text, speed: 1.0, model: model, token: token)
                    let ms = Int(Date().timeIntervalSince(t1) * 1000)
                    if let res {
                        let seconds = Double(res.samples.count) / Double(res.sampleRate)
                        let peak = res.samples.map { abs($0) }.max() ?? 0
                        let f0 = Self.estimateF0(res.samples, sampleRate: res.sampleRate)
                        print("[SelfTest] \(model.rawValue) synth \"\(text)\" samples=\(res.samples.count) sr=\(res.sampleRate) audio=\(String(format: "%.2f", seconds))s peak=\(String(format: "%.3f", peak)) f0=\(String(format: "%.0f", f0))Hz cost=\(ms)ms")
                        Self.dumpWav(res.samples, sampleRate: res.sampleRate,
                                     name: "\(model.rawValue)-\(text.hashValue).wav")
                    } else {
                        print("[SelfTest] \(model.rawValue) synth \"\(text)\" FAILED cost=\(ms)ms")
                    }
                }
            }

            // 标点停顿验证：不同句尾应得到不同长度的静音
            for sample in ["好。", "好！", "好？", "好…", "好；", "好：", "好，", "好、"] {
                let silence = SpeechService.trailingSilence(for: sample, sampleRate: 22050)
                let sec = Double(silence.count) / 22050.0
                print("[SelfTest] silence \"\(sample)\" = \(String(format: "%.2f", sec))s")
            }

            // 切句验证：男声走词典，标点会被丢弃，必须靠切句补停顿
            let demo = "他推开窗，风灌进来，把桌上的纸吹得满地都是。"
            let hardOnly = SpeechService.splitForPiper(demo, softBreak: false)
            let softSplit = SpeechService.splitForPiper(demo, softBreak: true)
            print("[SelfTest] split hard(\(hardOnly.count)): \(hardOnly)")
            print("[SelfTest] split soft(\(softSplit.count)): \(softSplit)")

            // 逗号停顿验证：按 SpeechService 的真实流程（切句 → 按标点补静音）拼成整段落盘，
            // 之后用波形量逗号处的静音长度，避免只靠「听起来有停顿」这种主观判断。
            let pauseDemo = "夜色沉下来，城市的灯一盏一盏亮起。"
            for model in models {
                let parts = SpeechService.splitForPiper(pauseDemo, softBreak: true)
                var merged: [Float] = []
                var sampleRate: Int32 = 22050
                for part in parts {
                    guard let r = piper.synthesize(
                        text: part, speed: 1.0, model: model, token: piper.currentToken()
                    ) else { continue }
                    sampleRate = r.sampleRate
                    merged += r.samples
                    merged += SpeechService.trailingSilence(for: part, sampleRate: r.sampleRate)
                }
                print("[SelfTest] merged \(model.rawValue) parts=\(parts.count) \(parts) audio=\(String(format: "%.2f", Double(merged.count) / Double(sampleRate)))s")
                Self.dumpWav(merged, sampleRate: sampleRate, name: "merged-\(model.rawValue).wav")
            }

            // 播放链路：走 SpeechService + AVAudioEngine，验证 onAdvance 能正常触发
            DispatchQueue.main.async {
                let svc = SpeechService.shared
                svc.onAdvance = {
                    print("[SelfTest] playback finished, onAdvance fired, engine=\(svc.activeEngine.rawValue)")
                    svc.stop()
                }
                print("[SelfTest] start playback via SpeechService (male)")
                svc.start(
                    text: "播放链路测试，听得到就说明本地语音已经接通。",
                    speed: 1.0,
                    profile: .neuralMale
                )
            }
        }
    }

    /// 用自相关估基频（Hz）。用于客观判断音色是男声还是女声：
    /// 男声典型 85–180Hz，女声 165–255Hz。
    private static func estimateF0(_ samples: [Float], sampleRate: Int32) -> Double {
        let sr = Double(sampleRate)
        // 取中段 0.5s，避开首尾静音
        let window = Int(sr * 0.5)
        guard samples.count > window * 2 else { return 0 }
        let start = (samples.count - window) / 2
        let seg = Array(samples[start..<(start + window)])

        let minLag = Int(sr / 400)   // 400Hz 上限
        let maxLag = Int(sr / 70)    // 70Hz 下限
        guard maxLag < seg.count else { return 0 }

        var bestLag = 0
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            var i = 0
            while i + lag < seg.count {
                sum += seg[i] * seg[i + lag]
                i += 1
            }
            if sum > bestScore { bestScore = sum; bestLag = lag }
        }
        guard bestLag > 0 else { return 0 }
        return sr / Double(bestLag)
    }

    /// 把合成结果写成 WAV 到 Documents，方便拷出来人工试听
    private static func dumpWav(_ samples: [Float], sampleRate: Int32, name: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent(name)
        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = Int32(samples.count * 2)
        func le32(_ v: Int32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        func le16(_ v: Int16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
        data.append("RIFF".data(using: .ascii)!)
        data.append(le32(36 + dataSize))
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.append(le32(16))
        data.append(le16(1))
        data.append(le16(1))
        data.append(le32(sampleRate))
        data.append(le32(byteRate))
        data.append(le16(2))
        data.append(le16(16))
        data.append("data".data(using: .ascii)!)
        data.append(le32(dataSize))
        for s in samples {
            let clamped = max(-1, min(1, s))
            data.append(le16(Int16(clamped * 32767)))
        }
        try? data.write(to: url)
        print("[SelfTest] wav -> \(url.lastPathComponent) (\(data.count) bytes)")
    }
}
