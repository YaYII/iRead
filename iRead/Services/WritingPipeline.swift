import Foundation
import UIKit

/// 长篇连写：写一章 → 审查 → （不过就带问题重写一次）→ 落盘 → 下一章。
///
/// 为什么是「外层状态机」而不是让模型自己当 agent：
/// 一百章跑两小时，中间一定会出错、会限流、会被系统挂起。只有外层代码掌握节奏，
/// 才能做到「一章一落盘、随时能停、停在哪儿下次从哪儿接、成本可算」。
/// 模型只在两个点上被调用：写正文、审稿。它不决定写几章，也不决定什么时候停。
///
/// 每章的审查调用顺便产出一句 40 字摘要，这是长篇的记忆来源 ——
/// 一百章不可能每次把全文发过去，摘要加起来才几千字。
@MainActor
final class WritingPipeline: ObservableObject {
    static let shared = WritingPipeline()

    enum Stage: Equatable {
        case idle
        case planning
        case writing(Int)
        case reviewing(Int)
        case repairing(Int)
        /// 按读者写在卡片上的意见改某一章
        case rewriting(Int)
        case paused
        case finished
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .idle, .paused, .finished, .failed: return false
            case .planning, .writing, .reviewing, .repairing, .rewriting: return true
            }
        }

        var label: String {
            switch self {
            case .idle: return "还没开始"
            case .planning: return "正在排章纲"
            case .writing(let n): return "正在写第 \(n) 章"
            case .reviewing(let n): return "正在审第 \(n) 章"
            case .repairing(let n): return "第 \(n) 章审查未过，正在改"
            case .rewriting(let n): return "正在按意见改第 \(n) 章"
            case .paused: return "已暂停"
            case .finished: return "已经写完"
            case .failed(let reason): return reason
            }
        }
    }

    /// 这一轮在干什么。界面文案和完成页的措辞按它分岔 ——
    /// 「连写 3 章」和「改 3 章」是两件事，用同一句「已经写完」会让人以为又多了三章。
    enum RunMode { case write, rewrite }

    @Published private(set) var mode: RunMode = .write

    /// 完成页的标题。重写模式不说「写完」，因为章数没变。
    var resultTitle: String {
        switch stage {
        case .finished: return mode == .rewrite ? "已经改完" : "已经写完"
        case .paused: return "已暂停"
        default: return stage.label
        }
    }

    struct LogLine: Identifiable {
        enum Kind { case info, ok, warn, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var streamText = ""
    @Published private(set) var thinkingChars = 0
    @Published private(set) var completed = 0
    @Published private(set) var target = 0
    @Published private(set) var projectID: String?
    /// 本次运行用到的章纲，界面上先给用户看一眼走向
    @Published private(set) var activePlan: [String] = []

    private var task: Task<Void, Never>?
    /// 程序判定的字数下限。提示词要 2200–3000 字，这里留一点余量：
    /// 低于 2000 基本就是没写完，直接重写比送去审更划算。
    private static let minWords = 2000
    /// 点了「暂停」：本章写完就停，不打断正在生成的内容
    private var pauseRequested = false
    /// 三次仍不过审时：停下等人看（默认），还是记个草稿接着往下写
    private var continueOnFail = false
    /// 本次运行里没过审的章，跑完一并列出来
    private var flagged: [String] = []

    private init() {}

    // MARK: - 对外控制

    func start(projectID: String, chapters: Int, planFirst: Bool, continueOnFail: Bool = false) {
        guard !stage.isRunning else { return }
        guard AISettings.shared.isConfigured else {
            stage = .failed("还没有配置 AI 服务")
            logs = [LogLine(kind: .error, text: "到「设置 → AI 写作」选一个服务商、填上 API Key。")]
            return
        }
        self.projectID = projectID
        self.continueOnFail = continueOnFail
        mode = .write
        target = chapters
        completed = 0
        flagged = []
        logs = []
        streamText = ""
        activePlan = []
        pauseRequested = false
        stage = .planning
        // 连写要跑很久，别让屏幕自己锁上
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { [weak self] in
            await self?.loop(projectID: projectID, chapters: chapters, planFirst: planFirst)
        }
    }

    /// 本章写完后停（已经写好的不会浪费）
    func pause() {
        guard stage.isRunning else { return }
        pauseRequested = true
        add(.info, mode == .rewrite ? "收到暂停：改完这一章就停" : "收到暂停：写完这一章就停")
    }

    /// 按读者写在章节卡上的意见，串行重写这些章。
    ///
    /// 为什么是「串行 + 逐章落盘」而不是一次把意见全塞给模型：
    /// 一次改多章，模型看不见自己刚改过的前文，越改越飘；而逐章落盘意味着
    /// 改到第三章不想改了，前两章已经是新的，随时能停、能看、能接着改。
    ///
    /// `indexes` 为 nil 时取当前所有带意见的章。
    func startRewrite(projectID: String, indexes: [Int]? = nil) {
        guard !stage.isRunning else { return }
        guard AISettings.shared.isConfigured else {
            stage = .failed("还没有配置 AI 服务")
            logs = [LogLine(kind: .error, text: "到「设置 → AI 写作」选一个服务商、填上 API Key。")]
            return
        }
        guard let project = WritingStore.shared.project(projectID) else {
            stage = .failed("这本稿子找不到了")
            return
        }
        // 只认真的有意见的章：没意见的章不该被「顺手重写」掉
        let targets = (indexes ?? project.commentedIndexes).filter { index in
            guard project.segments.indices.contains(index) else { return false }
            let note = (project.segments[index].comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !note.isEmpty
        }
        guard !targets.isEmpty else {
            stage = .failed("没有可改的章节")
            logs = [LogLine(kind: .info, text: "先在章节卡上写修改意见，再来按意见重写。")]
            return
        }

        self.projectID = projectID
        mode = .rewrite
        target = targets.count
        completed = 0
        flagged = []
        logs = []
        streamText = ""
        activePlan = []
        pauseRequested = false
        stage = .rewriting(targets[0] + 1)
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { [weak self] in
            await self?.rewriteLoop(projectID: projectID, indexes: targets)
        }
    }

    /// 立即停，当前章不保存（半章比没有更难受）
    func stop() {
        task?.cancel()
        task = nil
        pauseRequested = false
        UIApplication.shared.isIdleTimerDisabled = false
        if stage.isRunning {
            stage = .paused
            add(.warn, "已停止，当前章没有保存")
        }
    }

    func reset() {
        stop()
        stage = .idle
        logs = []
        streamText = ""
        completed = 0
        target = 0
        projectID = nil
        activePlan = []
    }

    // MARK: - 主循环

    private func loop(projectID: String, chapters: Int, planFirst: Bool) async {
        guard var project = WritingStore.shared.project(projectID) else {
            fail("这本稿子找不到了")
            return
        }

        do {
            try await ensurePlan(project: &project, chapters: chapters, planFirst: planFirst)

            for _ in 0..<chapters {
                try Task.checkCancellation()
                guard let current = WritingStore.shared.project(projectID) else {
                    fail("这本稿子被删掉了")
                    return
                }
                let passed = try await writeOneChapter(
                    current,
                    projectID: projectID,
                    number: current.segments.count + 1
                )
                guard passed else { return }

                if pauseRequested {
                    pauseRequested = false
                    stage = .paused
                    UIApplication.shared.isIdleTimerDisabled = false
                    add(.info, "已暂停：写完 \(completed) 章，后面接着写就行")
                    return
                }
            }

            UIApplication.shared.isIdleTimerDisabled = false
            stage = .finished
            add(.ok, "全部写完：本次 \(completed) 章，\(WritingStore.shared.project(projectID)?.wordCount ?? 0) 字")
            if !flagged.isEmpty {
                add(.warn, "\(flagged.count) 章没过审、已标在章节卡上：\(flagged.joined(separator: "、"))")
            }
        } catch is CancellationError {
            UIApplication.shared.isIdleTimerDisabled = false
            if stage.isRunning { stage = .paused }
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// 章纲：没有、或者不够这一轮用的，就先排一次
    private func ensurePlan(project: inout WritingProject, chapters: Int, planFirst: Bool) async throws {
        let existing = project.plan ?? []
        if !planFirst, existing.count >= 1 { return }
        if existing.count >= chapters { return }

        stage = .planning
        add(.info, "正在排 \(chapters) 章的章纲…")
        let raw = try await generate(
            WritingPrompts.plan(project: project, from: project.segments.count + 1, count: chapters),
            temperature: 0.7,
            mirror: false
        )
        let goals = Self.parsePlan(raw, count: chapters)
        guard !goals.isEmpty else {
            add(.warn, "章纲没解析出来，这一轮按大纲自由发挥")
            return
        }
        project.plan = goals
        WritingStore.shared.update(project)
        activePlan = goals
        for (i, goal) in goals.enumerated() {
            add(.info, "第\(project.segments.count + i + 1)章 · \(goal)")
        }
    }

    /// 写一章：生成 → 字数/审查 → 不过则重写一次 → 落盘。
    /// 返回 false 表示该停下来（审查两轮都不过），此时 stage 已设好原因。
    private func writeOneChapter(_ project: WritingProject, projectID: String, number: Int) async throws -> Bool {
        let goal = project.nextGoal
        let recent = Self.recentBody(project)
        // 第一章带底本开篇：重构/续写模式下，文风是「像原著」而不是「像模型」
        let opening: String? = project.segments.isEmpty && project.mode != .original
            ? project.sourceBookID
                .flatMap { LibraryStore.shared.content(for: $0)?.chapterText(at: 0) as String? }
            : nil
        var context = WritingPrompts.Context(
            outline: project.outlineText,
            recaps: WritingPrompts.recapLines(project),
            recent: recent,
            goal: goal,
            sourceOpening: opening
        )

        stage = .writing(number)
        streamText = ""
        thinkingChars = 0
        add(.info, "开始写第 \(number) 章")
        // 章纲刚刚在上面的日志里逐条列过，这里再说一遍只是刷屏；
        // 但章纲是上一次跑留下的（这次没重排），就得让用户看见本章要写什么。
        if let goal, !activePlan.contains(goal) {
            add(.info, "本章目标：\(goal)")
        }

        var raw = try await generate(
            WritingPrompts.nextChapter(project: project, context: context),
            temperature: 0.88
        )
        var parsed = WritingPrompts.splitChapter(raw, fallbackTitle: "第\(number)章")

        var passed = false
        var issues: [String] = []
        var recap = ""

        // 最多三轮：初稿 + 两次带问题局部修。仍不过就停下让人看，不无限烧钱。
        // 两次而不是一次，是因为「楼层写错」「人名写成另一个」这类问题一次常常改不干净，
        // 但每多一轮都是真金白银，所以上限卡死在两次。
        for attempt in 0...2 {
            try Task.checkCancellation()

            // 字数由程序数（不是让模型估），不达标不值得再花一次审查调用
            let words = WritingText.count(parsed.body)
            if words < Self.minWords {
                issues = ["本章 \(words) 字，少于 \(Self.minWords) 字的下限（目标 2200–3000 字）"]
                passed = false
            } else {
                stage = .reviewing(number)
                let reviewRaw = try await generate(
                    WritingPrompts.review(
                        project: project,
                        chapterTitle: parsed.title,
                        chapterText: parsed.body,
                        wordCount: words,
                        goal: goal,
                        recent: recent
                    ),
                    temperature: 0.2,
                    mirror: false
                )
                let outcome = WritingPrompts.parseVerdict(reviewRaw)
                if let warning = outcome.warning { add(.warn, "第\(number)章 · \(warning)") }
                passed = outcome.verdict.pass
                issues = outcome.verdict.issues
                recap = outcome.verdict.recap
            }
            if passed { break }
            guard attempt < 2 else { break }

            stage = .repairing(number)
            let round = attempt + 1
            add(.warn, "第\(number)章审查未过（第 \(round) 次）：\(issues.joined(separator: "；"))")
            context.feedback = issues
            raw = try await generate(
                WritingPrompts.nextChapter(project: project, context: context),
                temperature: 0.85
            )
            parsed = WritingPrompts.splitChapter(raw, fallbackTitle: "第\(number)章")
        }

        try Task.checkCancellation()

        // 落盘前再数一次：改成局部修以后正文变了，用最终这一版
        let finalWords = WritingText.count(parsed.body)
        var segment = WritingSegment(title: parsed.title, text: parsed.body, generated: true)
        segment.goal = goal
        segment.recap = recap.isEmpty ? nil : recap
        segment.issues = passed ? nil : issues

        guard var latest = WritingStore.shared.project(projectID) else {
            fail("这本稿子被删掉了")
            return false
        }
        latest.segments.append(segment)
        if var plan = latest.plan, !plan.isEmpty {
            plan.removeFirst()
            latest.plan = plan.isEmpty ? nil : plan
        }
        WritingStore.shared.update(latest)
        completed += 1
        streamText = ""

        if passed {
            // 标题里通常已经带「第N章」，日志不要再加一次，否则会「第1章 第1章 ……」
            add(.ok, "\(parsed.title) · \(finalWords) 字 · 通过审查")
            return true
        } else {
            add(.error, "\(parsed.title) · \(finalWords) 字 · 审查未过，已存为草稿")
            flagged.append(parsed.title)
            if continueOnFail {
                // 草稿已经在书里了，事件算发生过；接着写下去，最后统一列出哪几章要回头看。
                // 换成「跳过这一章」会让后文建立在一个没发生过的事件上，比留下瑕疵章更糟。
                add(.warn, "按设置继续写下一章")
                return true
            }
            stage = .failed("第 \(number) 章没过审，停在这里")
            add(.warn, "改一下大纲或这一章目标，再点「从这里重写」")
            UIApplication.shared.isIdleTimerDisabled = false
            return false
        }
    }

    // MARK: - 按意见重写

    /// 逐章改：生成 → 原位替换 → 清意见 → 落盘 → 下一章。
    ///
    /// 与 `writeOneChapter` 的两处关键差别：
    /// 1. **不动章纲、不改章数**。改写是原地替换，`plan` 一条都不消费 ——
    ///    后面的章节仍按原计划走，不会因为改了第三章就把第四章的走向挤掉。
    /// 2. **不跑审查**。审查判的是「有没有硬伤」，而这里的问题是读者自己指出的；
    ///    再花一次调用去问同一件事，只会多一轮等待和一份新意见。
    ///
    /// 没改成的章会保留意见，下次点「重写」还会被带上 —— 失败不会把用户的批注吃掉。
    private func rewriteLoop(projectID: String, indexes: [Int]) async {
        guard WritingStore.shared.project(projectID) != nil else {
            fail("这本稿子找不到了")
            return
        }
        var done = 0

        do {
            for index in indexes {
                try Task.checkCancellation()
                guard let current = WritingStore.shared.project(projectID) else {
                    fail("这本稿子被删掉了")
                    return
                }
                guard current.segments.indices.contains(index) else {
                    add(.warn, "第 \(index + 1) 章已经不在书里了，跳过")
                    continue
                }
                let segment = current.segments[index]
                let note = (segment.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !note.isEmpty else { continue }

                stage = .rewriting(index + 1)
                streamText = ""
                thinkingChars = 0
                add(.info, "开始改第 \(index + 1) 章 · 意见：\(Self.oneLine(note, 40))")

                // 摘要只取**这一章之前**的：本章自己的旧摘要正是要改掉的那个版本，
                // 把它塞回上下文，模型容易照着旧结论把意见又改回去。
                var before = current
                before.segments = Array(current.segments.prefix(index))
                let raw = try await generate(
                    WritingPrompts.rewriteChapterAt(
                        project: current,
                        index: index,
                        segment: segment,
                        previousTail: index > 0 ? current.segments[index - 1].text : "",
                        context: WritingPrompts.Context(
                            outline: current.outlineText,
                            recaps: WritingPrompts.recapLines(before),
                            goal: segment.goal
                        ),
                        comment: note
                    ),
                    temperature: 0.7
                )

                try Task.checkCancellation()

                // 生成要几分钟，期间用户可能删了这章、或在别处改过它。
                // 用 id 再确认一次：宁可少改一章，也不能把 user 刚敲的字覆盖掉。
                guard var latest = WritingStore.shared.project(projectID) else {
                    fail("这本稿子被删掉了")
                    return
                }
                guard latest.segments.indices.contains(index),
                      latest.segments[index].id == segment.id else {
                    add(.warn, "第 \(index + 1) 章在这期间被删了或挪了位置，跳过")
                    continue
                }

                let parsed = WritingPrompts.splitChapter(raw, fallbackTitle: segment.title)
                let words = WritingText.count(parsed.body)
                // 三百字以下基本是「模型只回了个开头」或者拒答，别拿它覆盖掉整章
                guard words >= 300 else {
                    add(.warn, "第 \(index + 1) 章只改出 \(words) 字，像是没改完，保留原样")
                    continue
                }

                var next = latest.segments[index]
                next.title = parsed.title
                next.text = parsed.body
                next.createdAt = Date()
                next.generated = true
                // 正文换了，这三项同时过期：摘要要重出、审查问题要重判、意见已经落实
                next.recap = nil
                next.issues = nil
                next.comment = nil
                next.commentAt = nil
                latest.segments[index] = next
                WritingStore.shared.update(latest)

                done += 1
                completed += 1
                streamText = ""
                add(.ok, "第 \(index + 1) 章改好了 · \(words) 字")

                // 提示词写了「篇幅 ±15%」，但它只是提示词。偏太多说明这一章被重写了，
                // 而不是被改了几处 —— 这种事得让用户自己看一眼才算数。
                let old = segment.wordCount
                if old > 0, abs(words - old) * 100 / old > 30 {
                    add(.warn, "篇幅从 \(old) 字变成 \(words) 字，改动偏大，回头核一下")
                }

                if pauseRequested {
                    pauseRequested = false
                    UIApplication.shared.isIdleTimerDisabled = false
                    stage = .paused
                    add(.info, "已暂停：改完 \(done) 章，剩下的意见还留着，下次接着点重写")
                    return
                }
            }

            UIApplication.shared.isIdleTimerDisabled = false
            if done < indexes.count {
                add(.warn, "\(indexes.count - done) 章没改（见上面的原因），意见还留着")
            }
            stage = .finished
            add(.ok, "按意见改完 \(done) 章")
        } catch is CancellationError {
            UIApplication.shared.isIdleTimerDisabled = false
            if stage.isRunning { stage = .paused }
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - 生成（带退避重试）

    private func generate(
        _ messages: [AIMessage],
        temperature: Double,
        mirror: Bool = true
    ) async throws -> String {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await AIClient.shared.stream(messages: messages, temperature: temperature) { [weak self] text in
                    // 只有正文生成才往预览区推。审查/排章返回的是 JSON，
                    // 推上去会看到一坨 {"pass": false...} 铺在正文位置上。
                    if mirror { self?.streamText = text }
                } onReasoning: { [weak self] count in
                    if mirror { self?.thinkingChars = count }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // 限流和服务端 5xx 值得等一等；别的（Key 错、模型名错）重试也没用
                if let ai = error as? AIError, case .http(let code, _) = ai, (code == 429 || code >= 500), attempt < 2 {
                    let wait = attempt == 0 ? 6 : 18
                    attempt += 1
                    add(.warn, "服务返回 \(code)，\(wait) 秒后重试")
                    try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                    continue
                }
                throw error
            }
        }
    }

    // MARK: - 工具

    private func add(_ kind: LogLine.Kind, _ text: String) {
        logs.append(LogLine(kind: kind, text: text))
        // 跑一百章日志会很长，留最近 200 条足够回溯
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        // 真机拿不到 stdout，但模拟器/自测时这一行能直接看出流水线走到哪一步
        print("[iRead] pipeline: \(text)")
    }

    /// 意见是多行的一段话，日志里只留一行、去掉换行带来的大段空白
    static func oneLine(_ text: String, _ limit: Int) -> String {
        let flat = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private func fail(_ reason: String) {
        UIApplication.shared.isIdleTimerDisabled = false
        stage = .failed(reason)
        add(.error, reason)
    }

    /// 最近两章正文、合计不超过 6000 字：再往前对文风的帮助很小，只会烧 token
    static func recentBody(_ project: WritingProject) -> String {
        var picked: [String] = []
        var total = 0
        for segment in project.segments.reversed() {
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            picked.insert("\(segment.title)\n\(body)", at: 0)
            total += body.count
            if picked.count >= 2 || total >= 6000 { break }
        }
        return picked.joined(separator: "\n\n")
    }

    /// 从模型输出里抠出章纲：只认「第X章：xxx」这种行，别的都当噪声
    static func parsePlan(_ raw: String, count: Int) -> [String] {
        var goals: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            var text = line.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if text.hasPrefix("-") || text.hasPrefix("·") || text.hasPrefix("•") {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard let colon = text.firstIndex(where: { $0 == "：" || $0 == ":" }) else { continue }
            let head = String(text[text.startIndex..<colon])
            guard head.contains("章") else { continue }
            let goal = String(text[text.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !goal.isEmpty else { continue }
            goals.append(goal)
            if goals.count >= count { break }
        }
        return goals
    }
}
