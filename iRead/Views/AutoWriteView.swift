import SwiftUI

/// 连写：一次跑 N 章，每章写完先审、审过才往下走。
///
/// 界面刻意把「章纲」摆在开跑之前：一百章跑起来就是几小时，
/// 方向错了再回头删，比先看一眼章纲贵得多。
struct AutoWriteSheet: View {
    let projectID: String

    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var writing = WritingStore.shared
    @ObservedObject private var pipeline = WritingPipeline.shared

    @State private var chapters = 5
    @State private var planFirst = true
    @State private var mode: Mode = .config
    @State private var showOutline = false

    private enum Mode { case config, run, done }

    private var theme: ReadingTheme { settings.theme }
    private var project: WritingProject? { writing.project(projectID) }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .config: config
                case .run: running
                case .done: summary
                }
            }
            // 完成页内容比屏幕短，不撑满的话sheet 底下的白底会从上面露出来一条
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("连写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(mode == .config ? "完成" : "关闭") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
            .sheet(isPresented: $showOutline) {
                OutlineSheet(projectID: projectID).environmentObject(settings)
            }
        }
        .onAppear {
            // 重新打开时接上正在跑的那次，而不是又给一个「开始」
            if pipeline.projectID == projectID {
                if pipeline.stage.isRunning {
                    mode = .run
                } else if !pipeline.logs.isEmpty {
                    mode = .done
                }
            }
            autoStartIfAsked()
        }
        .onChange(of: pipeline.stage) { _, newValue in
            guard pipeline.projectID == projectID else { return }
            if !newValue.isRunning && mode == .run { mode = .done }
        }
    }

    // MARK: - 配置

    private var config: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                countCard
                planToggle
                outlineRow
                costNote
                startButton
            }
            .padding(16)
        }
    }

    private var countCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(chapters)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .monospacedDigit()
                Text("章")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondary)
                Spacer()
                Stepper("章数", value: $chapters, in: 1...100)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                ForEach([3, 5, 10, 20, 50], id: \.self) { value in
                    Button {
                        chapters = value
                    } label: {
                        Text("\(value)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(chapters == value ? theme.background : theme.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(chapters == value ? theme.accent : theme.foreground.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.foreground.opacity(0.04)))
    }

    private var planToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $planFirst) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("先排章纲")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.foreground)
                    Text("让 AI 先把每章一句话列出来，再照着写。多一次请求，但方向提前看得见。")
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(theme.accent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.foreground.opacity(0.04)))
    }

    private var outlineRow: some View {
        Button {
            showOutline = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("故事大纲")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.foreground)
                    Text(outlineStatus)
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.foreground.opacity(0.04)))
        }
        .buttonStyle(.plain)
    }

    private var outlineStatus: String {
        let outline = project?.outlineText ?? ""
        if outline.isEmpty {
            return "还没写。没有大纲也能写，但写到几十章容易飘，建议先让 AI 起一份再改。"
        }
        return "\(outline.count) 字 · 每次生成都会带上它"
    }

    private var costNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("每章 2 次请求（写 + 审），约 \(chapters * 2) 次，预计新增 \(chapters * 2500) 字左右。")
            Text("跑的时候会保持屏幕常亮，请留在 App 里；中途退出等于暂停在此章。")
            Text("审查未过会带问题局部重写，最多再改两次；仍不过就停在那章，不会一直重试烧额度。")
        }
        .font(.caption2)
        .foregroundStyle(theme.secondary)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var startButton: some View {
        Button {
            mode = .run
            pipeline.start(projectID: projectID, chapters: chapters, planFirst: planFirst)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text("开始连写 \(chapters) 章")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(!AISettings.shared.isConfigured)
        .opacity(AISettings.shared.isConfigured ? 1 : 0.5)
    }

    // MARK: - 运行中

    private var running: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(pipeline.stage.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.foreground)
                    Spacer()
                    Text("\(pipeline.completed)/\(max(pipeline.target, 1))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondary)
                }
                ProgressView(value: Double(pipeline.completed), total: Double(max(pipeline.target, 1)))
                    .tint(theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            streamPreview
            logList
            runningFooter
        }
    }

    private var streamPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if pipeline.streamText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(pipeline.thinkingChars > 0
                             ? "正在构思（已想 \(pipeline.thinkingChars) 字）…"
                             : "等待模型开口…")
                            .font(.caption)
                            .foregroundStyle(theme.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    Text(pipeline.streamText)
                        .font(.custom("Songti SC", size: 14))
                        .foregroundStyle(theme.foreground.opacity(0.8))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultScrollAnchor(.bottom)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.foreground.opacity(0.04)))
        .padding(.horizontal, 16)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pipeline.logs) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(color(for: line.kind))
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(line.text)
                                .font(.caption2)
                                .foregroundStyle(line.kind == .info ? theme.secondary : color(for: line.kind))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: pipeline.logs.count) { _, _ in
                if let last = pipeline.logs.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        // 给日志一块底色：内容少时它贴在底部，没有底色就像页面中间破了个洞
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.foreground.opacity(0.03)))
        .frame(height: 230)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func color(for kind: WritingPipeline.LogLine.Kind) -> Color {
        switch kind {
        case .info: return theme.secondary
        case .ok: return theme.accent
        case .warn: return .orange
        case .error: return .red
        }
    }

    private var runningFooter: some View {
        VStack(spacing: 8) {
            Text("关闭这个页面不会中断连写")
                .font(.caption2)
                .foregroundStyle(theme.secondary)

            HStack(spacing: 10) {
                Button {
                    pipeline.pause()
                } label: {
                    Text("写完这章暂停")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.foreground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.foreground.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .disabled(!pipeline.stage.isRunning)

                Button {
                    pipeline.stop()
                } label: {
                    Text("停止")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    // MARK: - 结束

    private var summary: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: iconForStage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(colorForStage)
                Text(pipeline.stage.label)
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                    .multilineTextAlignment(.center)
                if let project {
                    Text("共 \(project.segments.count) 章 · \(project.wordCount) 字")
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 18)

            logList

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Text("关闭")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.foreground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.foreground.opacity(0.07)))
                }
                .buttonStyle(.plain)

                Button {
                    mode = .config
                } label: {
                    Text("再写几章")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
    }

    private var iconForStage: String {
        switch pipeline.stage {
        case .finished: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "pause.circle"
        }
    }

    private var colorForStage: Color {
        switch pipeline.stage {
        case .finished: return theme.accent
        case .failed: return .orange
        default: return theme.secondary
        }
    }

    // MARK: - 自测

    private func autoStartIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard mode == .config, args.contains("--auto-write") else { return }
        if let index = args.firstIndex(of: "--auto-chapters"), index + 1 < args.count,
           let value = Int(args[index + 1]) {
            chapters = max(1, min(value, 100))
        }
        planFirst = !args.contains("--no-plan")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            mode = .run
            pipeline.start(projectID: projectID, chapters: chapters, planFirst: planFirst)
        }
    }
}

// MARK: - 大纲编辑

/// 大纲是长篇唯一能压住「越写越飘」的东西，所以给它一个正经编辑器，
/// 而不是塞在某个输入框里让人顺手写两句。
struct OutlineSheet: View {
    let projectID: String

    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var writing = WritingStore.shared

    @State private var text = ""
    @State private var loaded = false
    @State private var drafting = false
    @State private var draftTask: Task<Void, Never>?
    @State private var errorText: String?

    private var theme: ReadingTheme { settings.theme }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.custom("Songti SC", size: 15))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(theme.foreground.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(16)
                    .overlay {
                        if text.isEmpty && !drafting {
                            VStack(spacing: 6) {
                                Text("还没有大纲")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(theme.secondary)
                                Text("写清主线、人物、世界规则和「不写什么」，\nAI 每次生成都会带上它。")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondary.opacity(0.8))
                                    .multilineTextAlignment(.center)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if drafting {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.mini)
                                Text("正在起草")
                                    .font(.caption2)
                                    .foregroundStyle(theme.secondary)
                            }
                            .padding(10)
                        }
                    }

                if let errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }

                HStack(spacing: 10) {
                    Button {
                        draft()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text(drafting ? "起草中" : "让 AI 起草")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(drafting)

                    Button {
                        save()
                        dismiss()
                    } label: {
                        Text("保存")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("故事大纲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        draftTask?.cancel()
                        dismiss()
                    }
                    .foregroundStyle(theme.secondary)
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear { draftTask?.cancel() }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        text = writing.project(projectID)?.outlineText ?? ""
    }

    private func save() {
        guard var project = writing.project(projectID) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        project.outline = trimmed.isEmpty ? nil : trimmed
        writing.update(project)
    }

    private func draft() {
        guard let project = writing.project(projectID) else { return }
        errorText = nil
        drafting = true
        let taste = store.books.filter { !$0.isComic }.prefix(6).map { "《\($0.title)》" }.joined(separator: "、")
        let opening = project.sourceBookID.flatMap { store.content(for: $0)?.chapterText(at: 0) as String? }
        let messages = WritingPrompts.outlineDraft(
            title: project.title,
            brief: project.brief,
            taste: taste,
            sourceTitle: project.sourceBookTitle,
            sourceOpening: opening,
            existing: text
        )
        draftTask = Task {
            do {
                let result = try await AIClient.shared.stream(messages: messages, temperature: 0.8) { chunk in
                    text = chunk
                }
                text = result
                drafting = false
            } catch {
                if Task.isCancelled || error is CancellationError {
                    drafting = false
                } else {
                    errorText = error.localizedDescription
                    drafting = false
                }
            }
        }
    }
}
