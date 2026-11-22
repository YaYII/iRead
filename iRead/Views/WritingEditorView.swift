import SwiftUI
import UIKit

/// 写作编辑器：一章一张卡，点进去改正文；底部是「让 AI 写下一章」。
///
/// 章节拆成独立 sheet 编辑，而不是把一堆 TextEditor 堆在 ScrollView 里 ——
/// 嵌套滚动会互相抢手势，写到第三章就会发现光标跟着页面跑。
struct WritingEditorView: View {
    let projectID: String

    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var writing = WritingStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editingSegment: WritingSegment?
    /// 生成请求打包成一个值再弹 sheet。
    ///
    /// 之前是 headline / detail / messages / isPresented 四个 @State 分开设，
    /// 出现过「sheet 先渲染、状态还没跟上」的空快照：界面空白、提示也没有。
    /// 一个 item 只有一次状态跃迁，不会读到半截数据。
    @State private var request: GenerationRequest?
    @State private var exportURL: URL?
    @State private var showDeleteConfirm = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showNoConfig = false
    @State private var showAutoWrite = false
    @State private var showOutline = false
    /// 待确认「从第 N 章往后重写」的下标
    @State private var pendingRewrite: Int?

    @ObservedObject private var pipeline = WritingPipeline.shared

    private var theme: ReadingTheme { settings.theme }

    private var project: WritingProject? { writing.project(projectID) }

    var body: some View {
        // 拆成两段：一条链上堆五个 sheet + 三个 alert + 确认框，
        // 类型检查会直接超时（"unable to type-check this expression in reasonable time"）。
        sheetHost
            .alert("重命名", isPresented: $showRename) {
                TextField("书名", text: $renameText)
                Button("保存") {
                    guard var project else { return }
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    project.title = name.isEmpty ? "未命名作品" : name
                    writing.update(project)
                }
                Button("取消", role: .cancel) {}
            }
            .alert("还没配置 AI 服务", isPresented: $showNoConfig) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("到「设置 → AI 写作」选一个服务商、填上 API Key，再回来写。本地模型不需要 Key。")
            }
            .alert("删除《\(project?.title ?? "")》？", isPresented: $showDeleteConfirm) {
                Button("删除", role: .destructive) {
                    writing.delete(projectID)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("稿件会从本机删掉，导出过的 txt 不受影响。")
            }
            .onAppear { autoGenerateIfAsked() }
    }

    private var sheetHost: some View {
        panel
            .sheet(item: $editingSegment) { segment in
                NavigationStack {
                    ChapterEditorView(projectID: projectID, segmentID: segment.id)
                        .environmentObject(settings)
                }
            }
            .sheet(item: $request) { item in
                GenerationSheet(
                    headline: item.headline,
                    detail: item.detail,
                    messages: item.messages
                ) { raw in
                    // 由请求自己决定落到哪儿：新写一章、还是替换某一章
                    item.onSave(raw)
                }
                .environmentObject(settings)
            }
            .sheet(isPresented: $showAutoWrite) {
                AutoWriteSheet(projectID: projectID)
                    .environmentObject(settings)
            }
            .sheet(isPresented: $showOutline) {
                OutlineSheet(projectID: projectID)
                    .environmentObject(settings)
                    .environmentObject(store)
            }
            .sheet(item: Binding(
                get: { exportURL.map { ExportFile(url: $0) } },
                set: { if $0 == nil { exportURL = nil } }
            )) { file in
                ExportShareSheet(items: [file.url])
            }
            .confirmationDialog(
                rewriteTitle,
                isPresented: rewritePresented,
                titleVisibility: .visible
            ) {
                Button("重写这 \(rewriteCount(from: pendingRewrite ?? 0)) 章", role: .destructive) {
                    if let index = pendingRewrite { rewriteFrom(index) }
                }
                Button("取消", role: .cancel) { pendingRewrite = nil }
            } message: {
                Text("这一章和它后面的章节会被删掉重新写，删了不能恢复。想留底的话先导出 TXT。")
            }
    }

    private var rewriteTitle: String {
        "从第 \((pendingRewrite ?? 0) + 1) 章往后重写？"
    }

    private var rewritePresented: Binding<Bool> {
        Binding(
            get: { pendingRewrite != nil },
            set: { if !$0 { pendingRewrite = nil } }
        )
    }

    private var panel: some View {
        Group {
            if let project {
                content(project)
            } else {
                Text("这本稿子已经不在了")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background.ignoresSafeArea())
            }
        }
        .navigationTitle(project?.title ?? "写作")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = project?.title ?? ""
                        showRename = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button {
                        exportTXT()
                    } label: {
                        Label("导出 TXT", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除这本", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(theme.accent)
                }
            }
        }
    }

    // MARK: - 主体

    private func content(_ project: WritingProject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                metaCard(project)
                if project.segments.isEmpty {
                    emptyChapterCard
                } else {
                    ForEach(Array(project.segments.enumerated()), id: \.element.id) { index, segment in
                        Button {
                            editingSegment = segment
                        } label: {
                            chapterCard(index: index, segment: segment)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                startRewrite(index)
                            } label: {
                                Label("重写本章", systemImage: "arrow.clockwise")
                            }
                            Button {
                                pendingRewrite = index
                            } label: {
                                Label("从这一章往后重写", systemImage: "arrow.triangle.branch")
                            }
                            Divider()
                            Button(role: .destructive) {
                                deleteSegment(segment)
                            } label: {
                                Label("删除本章", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 130)
        }
        .background(theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            bottomBar(project)
        }
    }

    private func metaCard(_ project: WritingProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(project.mode.title, systemImage: project.mode.icon)
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                Spacer()
                Text("\(project.segments.count) 章 · \(project.wordCount) 字")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
            }
            if !project.brief.isEmpty {
                Text(project.brief)
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source = project.sourceBookTitle {
                Text("底本：《\(source)》")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary.opacity(0.9))
            }
            Divider().overlay(theme.secondary.opacity(0.15))
            Button {
                showOutline = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 11))
                    Text(project.outlineText.isEmpty
                         ? "还没有故事大纲 —— 长篇建议先写一份"
                         : "故事大纲 · \(WritingText.count(project.outlineText)) 字")
                        .font(.caption)
                    Spacer()
                    if let plan = project.plan, !plan.isEmpty {
                        Text("章纲还剩 \(plan.count) 条")
                            .font(.caption2)
                            .foregroundStyle(theme.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(project.outlineText.isEmpty ? theme.secondary : theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.foreground.opacity(0.04)))
    }

    private var emptyChapterCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.page")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.accent)
            Text("还没有正文")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.foreground)
            Text("点下面的按钮，AI 会按方向和底本写出第一章；\n写出来不满意可以整章删掉重写，不会动到书架。")
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.foreground.opacity(0.04)))
    }

    private func chapterCard(index: Int, segment: WritingSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(segment.title.isEmpty ? "第 \(index + 1) 章" : segment.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                if segment.generated {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                if segment.issues?.isEmpty == false {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                Text("\(segment.wordCount) 字")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondary)
            }
            if let issues = segment.issues, !issues.isEmpty {
                Text("审查未过：\(issues.first ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Text(segment.preview)
                .font(.custom("Songti SC", size: 14))
                .foregroundStyle(theme.foreground.opacity(0.75))
                .lineLimit(3)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.foreground.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - 底部生成条

    private func bottomBar(_ project: WritingProject) -> some View {
        VStack(spacing: 6) {
            if pipeline.projectID == projectID, pipeline.stage.isRunning {
                Button {
                    showAutoWrite = true
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("连写中 · \(pipeline.stage.label) · \(pipeline.completed)/\(pipeline.target)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.accent)
                        Spacer()
                        Text("查看")
                            .font(.caption2)
                            .foregroundStyle(theme.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(theme.accent.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button {
                    startGeneration(project)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(project.segments.isEmpty ? "让 AI 写第一章" : "让 AI 写第 \(project.segments.count + 1) 章")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
                }
                .buttonStyle(.plain)

                Button {
                    showAutoWrite = true
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.system(size: 13, weight: .semibold))
                        Text("连写")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(theme.accent)
                    .frame(width: 62)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }

            Text("单章会把最近 \(recentChapterCount(project)) 章（约 \(recentCharacterCount(project)) 字）发给 \(AISettings.shared.providerName)")
                .font(.caption2)
                .foregroundStyle(theme.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
    }

    // MARK: - 生成

    private func startGeneration(_ project: WritingProject) {
        guard AISettings.shared.isConfigured else {
            showNoConfig = true
            return
        }
        if project.segments.isEmpty {
            request = GenerationRequest(
                headline: "正在写第一章",
                detail: "《\(project.title)》 · \(AISettings.shared.providerName) \(AISettings.shared.model)",
                messages: WritingPrompts.firstChapter(
                    title: project.title,
                    brief: project.brief,
                    taste: tasteProfile(),
                    sourceTitle: project.sourceBookTitle,
                    sourceOpening: sourceOpening(project)
                )
            ) { raw in
                appendChapter(raw)
            }
        } else {
            let number = project.segments.count + 1
            request = GenerationRequest(
                headline: "正在写第 \(number) 章",
                detail: project.nextGoal.map { "本章目标：\($0)" }
                    ?? "接着前 \(recentChapterCount(project)) 章的结尾往下写",
                messages: WritingPrompts.nextChapter(
                    project: project,
                    context: WritingPrompts.Context(
                        outline: project.outlineText,
                        recaps: WritingPrompts.recapLines(project),
                        recent: recentText(project),
                        goal: project.nextGoal
                    )
                )
            ) { raw in
                appendChapter(raw)
            }
        }
    }

    private func appendChapter(_ raw: String) {
        guard var project = writing.project(projectID) else { return }
        let number = project.segments.count + 1
        let goal = project.nextGoal
        let parsed = WritingPrompts.splitChapter(raw, fallbackTitle: "第\(number)章")
        var segment = WritingSegment(title: parsed.title, text: parsed.body, generated: true)
        segment.goal = goal
        project.segments.append(segment)
        // 用掉一条章纲，下一章接着用下一条
        if var plan = project.plan, !plan.isEmpty {
            plan.removeFirst()
            project.plan = plan.isEmpty ? nil : plan
        }
        writing.update(project)
    }

    /// 重写本章：替换原位置，不动后面的章节
    private func startRewrite(_ index: Int) {
        guard let project, project.segments.indices.contains(index) else { return }
        let segment = project.segments[index]
        request = GenerationRequest(
            headline: "重写第 \(index + 1) 章",
            detail: "保留已发生的事，只换写法 · \(AISettings.shared.model)",
            messages: WritingPrompts.rewriteChapterAt(
                project: project,
                index: index,
                segment: segment,
                previousTail: index > 0 ? project.segments[index - 1].text : "",
                context: WritingPrompts.Context(
                    outline: project.outlineText,
                    recaps: WritingPrompts.recapLines(project),
                    goal: segment.goal
                )
            )
        ) { raw in
            replaceChapter(raw, at: index)
        }
    }

    private func replaceChapter(_ raw: String, at index: Int) {
        guard var project = writing.project(projectID),
              project.segments.indices.contains(index) else { return }
        let parsed = WritingPrompts.splitChapter(raw, fallbackTitle: project.segments[index].title)
        var segment = project.segments[index]
        segment.title = parsed.title
        segment.text = parsed.body
        segment.createdAt = Date()
        segment.generated = true
        segment.issues = nil
        // 正文换了，旧摘要就不能再用
        segment.recap = nil
        project.segments[index] = segment
        writing.update(project)
    }

    private func rewriteCount(from index: Int) -> Int {
        guard let project else { return 0 }
        return max(1, project.segments.count - index)
    }

    /// 从第 index 章往后重写：截掉这一段，把原来的章纲捡回来，交给连写流水线重新跑
    private func rewriteFrom(_ index: Int) {
        guard var project else { return }
        let count = rewriteCount(from: index)
        let goals = project.segments[index...].compactMap { $0.goal }
        project.segments.removeSubrange(index...)
        project.plan = goals.isEmpty ? nil : goals
        writing.update(project)
        pendingRewrite = nil
        guard AISettings.shared.isConfigured else {
            showNoConfig = true
            return
        }
        showAutoWrite = true
        pipeline.start(projectID: projectID, chapters: count, planFirst: false)
    }

    private func deleteSegment(_ segment: WritingSegment) {
        guard var project = writing.project(projectID) else { return }
        project.segments.removeAll { $0.id == segment.id }
        writing.update(project)
    }

    /// 最近两章、合计不超过 9000 字：再往前对下一章的帮助很小，只会烧 token
    private func recentText(_ project: WritingProject) -> String {
        var picked: [String] = []
        var total = 0
        for segment in project.segments.reversed() {
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            picked.insert("\(segment.title)\n\(body)", at: 0)
            total += body.count
            if picked.count >= 2 || total >= 9000 { break }
        }
        return picked.joined(separator: "\n\n")
    }

    private func recentChapterCount(_ project: WritingProject) -> Int {
        min(2, project.segments.filter { !$0.text.isEmpty }.count)
    }

    private func recentCharacterCount(_ project: WritingProject) -> Int {
        min(9000, project.segments.suffix(2).reduce(0) { $0 + $1.wordCount })
    }

    /// 口味画像只发书名：正文属于作者，没必要为了「判断类型」整本上传
    private func tasteProfile() -> String {
        let titles = store.books
            .filter { !$0.isComic }
            .prefix(6)
            .map { "《\($0.title)》" }
        return titles.joined(separator: "、")
    }

    private func sourceOpening(_ project: WritingProject) -> String? {
        guard let id = project.sourceBookID,
              let content = store.content(for: id) else { return nil }
        return content.chapterText(at: 0) as String
    }

    // MARK: - 导出

    private func exportTXT() {
        guard let project, !project.segments.isEmpty else { return }
        exportURL = try? writing.exportTXT(project)
    }

    // MARK: - 自测

    /// `--write-gen`：进编辑器后自动点一次「写下一章」，用于验证端到端链路
    private func autoGenerateIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard let project else { return }
        if args.contains("--export-writing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                exportTXT()
                print("[iRead] export -> \(exportURL?.path ?? "nil")")
            }
        }
        if args.contains("--open-chapter"), let first = project.segments.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { editingSegment = first }
        }
        if args.contains("--open-auto") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showAutoWrite = true }
        }
        if args.contains("--auto-write") || args.contains("--open-outline") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if args.contains("--open-outline") { showOutline = true } else { showAutoWrite = true }
            }
        }
        guard args.contains("--write-gen"), request == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if request == nil { startGeneration(project) }
        }
    }
}

/// 一次生成请求。打包成一个值，避免多个 @State 分步设置时被 sheet 读到半截。
struct GenerationRequest: Identifiable {
    let id = UUID()
    let headline: String
    let detail: String
    let messages: [AIMessage]
    let onSave: (String) -> Void
}

// MARK: - 章节编辑

struct ChapterEditorView: View {
    let projectID: String
    let segmentID: String

    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var request: GenerationRequest?
    @State private var saveTask: Task<Void, Never>?

    private var theme: ReadingTheme { settings.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("章节标题", text: $title)
                .font(.headline)
                .foregroundStyle(theme.foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .onChange(of: title) { _, _ in scheduleSave() }

            Divider().opacity(0.3)

            TextEditor(text: $text)
                .font(.custom("Songti SC", size: 17))
                .foregroundStyle(theme.foreground)
                .lineSpacing(7)
                .scrollContentBackground(.hidden)
                .background(theme.background)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .onChange(of: text) { _, _ in scheduleSave() }
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("编辑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") {
                    flush()
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accent)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    prepareExtension()
                } label: {
                    Label("AI 续写", systemImage: "sparkles")
                        .font(.subheadline)
                }
                .foregroundStyle(theme.accent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(item: $request) { item in
            GenerationSheet(
                headline: item.headline,
                detail: item.detail,
                messages: item.messages
            ) { raw in
                let body = WritingPrompts.splitChapter(raw, fallbackTitle: title).body
                if text.hasSuffix("\n") {
                    text += "\n" + body
                } else {
                    text += "\n\n" + body
                }
                flush()
            }
            .environmentObject(settings)
        }
        .onAppear(perform: load)
        .onDisappear(perform: flush)
    }

    private func load() {
        guard !loaded, let project = WritingStore.shared.project(projectID),
              let segment = project.segments.first(where: { $0.id == segmentID }) else { return }
        title = segment.title
        text = segment.text
        loaded = true
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { flush() }
        }
    }

    /// 把编辑框里的内容写回仓库。没改过就不写，避免每次开关都刷新 updatedAt。
    private func flush() {
        guard loaded, var project = WritingStore.shared.project(projectID),
              let index = project.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let old = project.segments[index]
        guard old.title != title || old.text != text else { return }
        project.segments[index].title = title
        project.segments[index].text = text
        WritingStore.shared.update(project)
    }

    private func prepareExtension() {
        flush()
        guard let project = WritingStore.shared.project(projectID),
              let segment = project.segments.first(where: { $0.id == segmentID }) else { return }
        request = GenerationRequest(
            headline: "正在续写这一章",
            detail: "\(AISettings.shared.providerName) \(AISettings.shared.model)",
            messages: WritingPrompts.extendSegment(project: project, segment: segment)
        ) { raw in
            let body = WritingPrompts.splitChapter(raw, fallbackTitle: title).body
            text += text.hasSuffix("\n") ? "\n" + body : "\n\n" + body
            flush()
        }
    }
}

// MARK: - 生成过程

/// 流式生成面板：边写边显示，随时能停。
struct GenerationSheet: View {
    let headline: String
    let detail: String
    let messages: [AIMessage]
    var onSave: (String) -> Void

    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case running, done, stopped, failed
    }

    @State private var text = ""
    @State private var phase: Phase = .running
    @State private var errorText: String?
    /// 模型在思维链阶段吐出的字数：只用来显示「还在干活」，正文里不出现
    @State private var thinkingChars = 0
    /// 流式请求挂在这个 task 上：点「停止」或关掉面板都能真把连接掐掉，
    /// 否则模型会继续在后台把整章写完、白烧额度
    @State private var task: Task<Void, Never>?
    /// onAppear 有可能被调多次（sheet 重建等），只许自动开跑一次，
    /// 否则会同时发好几个请求，白烧额度
    @State private var started = false

    private var theme: ReadingTheme { settings.theme }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.3)
                streamingBody
                footer
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("AI 写作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                    .foregroundStyle(theme.secondary)
                }
            }
            .onAppear {
                guard !started else { return }
                started = true
                start()
            }
            .onDisappear { task?.cancel() }
        }
        .interactiveDismissDisabled(phase == .running)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.foreground)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(theme.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var streamingBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let errorText {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("这次没写成", systemImage: "exclamationmark.triangle")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.orange)
                            Text(errorText)
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 20)
                    } else if text.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().tint(theme.accent)
                            Text(thinkingChars > 0 ? "正在构思（已想 \(thinkingChars) 字）…" : "正在起笔…")
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                        }
                        .padding(.top, 20)
                    } else {
                        Text(text + (phase == .running ? "▍" : ""))
                            .font(.custom("Songti SC", size: 17))
                            .foregroundStyle(theme.foreground)
                            .lineSpacing(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .onChange(of: text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            switch phase {
            case .running:
                HStack(spacing: 10) {
                    Button {
                        cancel()
                    } label: {
                        Text("停止")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 11).fill(theme.foreground.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    Text("已 \(WritingText.count(text)) 字")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.secondary)
                        .frame(width: 68)
                }
            case .done:
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent)
                    Text("已保存到这本稿子")
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                    Spacer()
                    Button("完成") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
                .padding(.vertical, 4)
            case .stopped:
                HStack(spacing: 10) {
                    Button {
                        onSave(text)
                        dismiss()
                    } label: {
                        Text("保留这部分")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 11).fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        dismiss()
                    } label: {
                        Text("丢弃")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 11).fill(theme.foreground.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            case .failed:
                HStack(spacing: 10) {
                    Button {
                        start()
                    } label: {
                        Text("重试")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 11).fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                    Button {
                        dismiss()
                    } label: {
                        Text("关闭")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 11).fill(theme.foreground.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
    }

    private func start() {
        task?.cancel()
        task = Task { await run() }
    }

    private func run() async {
        guard !messages.isEmpty else {
            errorText = detail
            phase = .failed
            return
        }
        phase = .running
        errorText = nil
        text = ""
        thinkingChars = 0
        do {
            let result = try await AIClient.shared.stream(messages: messages) { snapshot in
                text = snapshot
            } onReasoning: { count in
                thinkingChars = count
            }
            text = result
            phase = .done
            onSave(result)
        } catch {
            if Task.isCancelled || error is CancellationError {
                phase = .stopped
            } else {
                errorText = error.localizedDescription
                phase = .failed
            }
        }
    }

    private func cancel() {
        task?.cancel()
    }
}

// MARK: - 导出分享

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ExportShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
