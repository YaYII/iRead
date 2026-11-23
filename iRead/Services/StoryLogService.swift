import Foundation

/// 场记（线索日志）的抽取与维护。
///
/// 为什么单独成一层，不塞进 `WritingPipeline`：写新章、按意见重写、作者手动重写
/// 三条路都会改正文，三条路都得重记场记。塞在流水线里，手动改的那条就漏了 ——
/// 漏一次不影响，漏十次场记就和正文对不上，反而比没有更糟。
@MainActor
enum StoryLogService {

    /// 抽一章的场记并写回仓库。
    ///
    /// 不 throw：场记是辅助信息，失败了不该打断正在跑的长篇连写。
    /// 返回值是一句给用户看的话（成功、失败都说一句），不需要提示时返回 nil。
    @discardableResult
    static func harvest(projectID: String, segmentID: String, chapterIndex: Int) async -> String? {
        guard AISettings.shared.isConfigured else { return nil }
        guard let project = WritingStore.shared.project(projectID),
              let segment = project.segments.first(where: { $0.id == segmentID }) else { return nil }
        let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 下限放得很低：测试稿、片段本来就短，卡在 200 字会让它们永远没有场记，
        // 用户点「补齐」也补不出来，看着像功能坏了。真正的门槛是「有没有正文」。
        guard WritingText.count(body) >= 80 else { return nil }
        NSLog("[iRead] 场记开始 · %@ · %d 字", segment.title, WritingText.count(body))
        // 采用改稿后面板已经关了，这时没有别的 holder 撑着屏幕；
        // 这一趟要读整章、再等模型回几行 JSON，中途息屏就会断在这里
        ScreenAwake.begin(.log)
        defer { ScreenAwake.end(.log) }

        do {
            let raw = try await AIClient.shared.stream(
                messages: WritingPrompts.extractLog(
                    project: project,
                    chapterIndex: chapterIndex,
                    segment: segment,
                    known: WritingPrompts.logLines(project)
                ),
                temperature: 0.2,
                onDelta: { _ in }
            )
            let parsed = WritingPrompts.parseLog(raw)
            var entries = parsed.drafts.map { draft in
                StoryLogEntry(kind: draft.kind,
                              subject: draft.subject,
                              summary: draft.summary,
                              segmentID: segmentID,
                              chapterIndex: chapterIndex,
                              chapterTitle: segment.title)
            }

            // 一条都没抽出来时退回章节摘要：摘要本来就有（审查时顺手产的），
            // 拿它当一条「事件」比留一片空白强 —— 至少说明这一章发生过什么。
            if entries.isEmpty, let recap = segment.recap, !recap.isEmpty {
                entries = [StoryLogEntry(kind: .event,
                                         subject: "主线",
                                         summary: recap,
                                         segmentID: segmentID,
                                         chapterIndex: chapterIndex,
                                         chapterTitle: segment.title)]
            }
            guard !entries.isEmpty else {
                return parsed.warning
            }

            apply(entries: entries, resolved: parsed.resolved, projectID: projectID, segmentID: segmentID)
            NSLog("[iRead] 场记完成 · %@ · %d 条", segment.title, entries.count)
            return "场记记下 \(entries.count) 条"
        } catch {
            NSLog("[iRead] 场记失败 · %@", error.localizedDescription)
            return "场记没记成：\(error.localizedDescription)"
        }
    }

    /// 把某一章的场记整批替换。重写过的章必须整批换 ——
    /// 留着旧条目，日志会同时说「他还在青云宗」和「他已经下山了」。
    private static func apply(entries: [StoryLogEntry], resolved: [String],
                              projectID: String, segmentID: String) {
        guard var project = WritingStore.shared.project(projectID) else { return }
        var log = project.logEntries
        log.removeAll { $0.segmentID == segmentID }

        // 回收：模型给的是摘要前几个字，按包含关系认领
        if !resolved.isEmpty {
            for index in log.indices where log[index].kind == .thread && !log[index].resolved {
                let summary = log[index].summary
                if resolved.contains(where: { $0.count >= 4 && (summary.contains($0) || $0.contains(summary.prefix(12))) }) {
                    log[index].resolved = true
                }
            }
        }

        log.append(contentsOf: entries)
        // 按章排，同一章内保持抽取顺序。章序号会随删章变化，所以每次写入重排一遍。
        log.sort { lhs, rhs in
            if lhs.chapterIndex != rhs.chapterIndex { return lhs.chapterIndex < rhs.chapterIndex }
            return lhs.createdAt < rhs.createdAt
        }
        project.log = log
        WritingStore.shared.update(project)
    }

    /// 补齐没有场记的章节。
    ///
    /// 一章一次调用，串行跑：并发跑会同时改同一份 JSON，后写的把先写的覆盖掉。
    /// `progress` 每完成一章回调一次，界面拿它显示进度。
    static func backfill(projectID: String,
                         progress: (Int, Int) -> Void) async -> (done: Int, failed: Int) {
        guard let project = WritingStore.shared.project(projectID) else { return (0, 0) }
        let pending = project.chaptersWithoutLog
        guard !pending.isEmpty else { return (0, 0) }

        var done = 0
        var failed = 0
        for (step, index) in pending.enumerated() {
            if Task.isCancelled { break }
            guard let latest = WritingStore.shared.project(projectID),
                  latest.segments.indices.contains(index) else { continue }
            let segment = latest.segments[index]
            let message = await harvest(projectID: projectID, segmentID: segment.id, chapterIndex: index)
            if message?.hasPrefix("场记记下") == true || message == nil {
                done += 1
            } else {
                failed += 1
            }
            progress(step + 1, pending.count)
        }
        return (done, failed)
    }

    // MARK: - 作者的操作

    /// 手动把一条伏笔标为已回收
    static func toggleResolved(entryID: String, projectID: String) {
        guard var project = WritingStore.shared.project(projectID),
              let index = project.logEntries.firstIndex(where: { $0.id == entryID }),
              project.logEntries[index].kind == .thread else { return }
        var log = project.logEntries
        log[index].resolved.toggle()
        project.log = log
        WritingStore.shared.update(project)
    }

    static func delete(entryID: String, projectID: String) {
        guard var project = WritingStore.shared.project(projectID) else { return }
        project.log = project.logEntries.filter { $0.id != entryID }
        WritingStore.shared.update(project)
    }
}
