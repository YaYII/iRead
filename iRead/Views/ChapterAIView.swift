import SwiftUI

/// 阅读页顶部的 AI 入口：改写本章 / 换个走向 / 接着写。
///
/// 这里只负责「生一段新文字」，从不回写原书。想留着继续写，就存进「写作」——
/// 阅读永远只读，AI 也改不到作者写的东西。
struct ChapterAIView: View {
    let bookID: String
    let bookTitle: String
    let chapterIndex: Int
    let chapterTitle: String
    let chapterText: String
    let previousTail: String
    var onOpenWriting: () -> Void

    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case form, running, done, stopped, failed, saved
    }

    @State private var action: ChapterAIAction = .rewrite
    @State private var instruction = ""
    @State private var phase: Phase = .form
    @State private var text = ""
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    /// 思维链字数：只用于「还在想」的提示，不显示内容
    @State private var thinkingChars = 0

    private var theme: ReadingTheme { settings.theme }

    private let suggestions = ["更紧凑", "文笔再冷一点", "多写细节", "对白多一点", "别改结尾"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if phase == .form {
                                form
                            } else {
                                resultBody
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(16)
                    }
                    .onChange(of: text) { _, _ in
                        guard phase == .running else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                if phase != .form { footer }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("AI 改写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        task?.cancel()
                        dismiss()
                    }
                    .foregroundStyle(theme.secondary)
                }
            }
        }
        .interactiveDismissDisabled(phase == .running)
        .onDisappear { task?.cancel() }
        .onAppear {
            // 仅供截图/自测：直接按「改写本章」跑一遍
            if ProcessInfo.processInfo.arguments.contains("--ai-run") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { start() }
            }
        }
    }

    // MARK: - 表单

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chapterTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(2)
                Text("本章 \(chapterText.count) 字 · 生成结果会存进「写作」，不会改动原书")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
            }

            VStack(spacing: 8) {
                ForEach(ChapterAIAction.allCases) { item in
                    Button {
                        action = item
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(action == item ? theme.accent : theme.secondary)
                                .frame(width: 20, height: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(theme.foreground)
                                Text(item.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(theme.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: action == item ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(action == item ? theme.accent : theme.secondary.opacity(0.35))
                        }
                        .padding(11)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(action == item ? theme.accent.opacity(0.08) : theme.foreground.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .stroke(action == item ? theme.accent.opacity(0.5) : theme.secondary.opacity(0.14),
                                        lineWidth: action == item ? 1 : 0.5)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("这一版想怎么改（可以空着）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondary)
                TextField("比如：节奏更快，别写景，让配角先开口", text: $instruction, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(2...4)
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.foreground.opacity(0.05)))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(suggestions, id: \.self) { item in
                            Button {
                                if instruction.isEmpty {
                                    instruction = item
                                } else if !instruction.contains(item) {
                                    instruction += "，\(item)"
                                }
                            } label: {
                                Text(item)
                                    .font(.caption2)
                                    .foregroundStyle(theme.accent)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(theme.accent.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button(action: start) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("生成")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 11).fill(theme.accent))
            }
            .buttonStyle(.plain)

            Text("会把第 \(chapterIndex + 1) 章正文发给 \(AISettings.shared.providerName)。生成内容仅存本机。")
                .font(.caption2)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 结果

    private var resultBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: action.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(action.title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if phase == .running {
                    Text("已 \(text.count) 字")
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(theme.accent)

            if let errorText {
                VStack(alignment: .leading, spacing: 6) {
                    Label("这次没写成", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if text.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(theme.accent)
                    Text(thinkingChars > 0 ? "正在构思（已想 \(thinkingChars) 字）…" : "正在重写这一章…")
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                }
            } else {
                Text(text + (phase == .running ? "▍" : ""))
                    .font(.custom("Songti SC", size: 17))
                    .foregroundStyle(theme.foreground)
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            switch phase {
            case .running:
                Button {
                    task?.cancel()
                } label: {
                    Text("停止")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 11).fill(theme.foreground.opacity(0.06)))
                }
                .buttonStyle(.plain)
            case .done:
                HStack(spacing: 10) {
                    Button {
                        start()
                    } label: {
                        Text("再写一版")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 11).fill(theme.foreground.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    Button {
                        save()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tray.and.arrow.down")
                            Text("存进写作")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 11).fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                }
            case .stopped:
                HStack(spacing: 10) {
                    Button {
                        phase = .form
                    } label: {
                        Text("改条件")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 11).fill(theme.foreground.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    Button {
                        save()
                    } label: {
                        Text("保留这部分")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 11).fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                }
            case .failed:
                HStack(spacing: 10) {
                    Button {
                        phase = .form
                    } label: {
                        Text("返回")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 11).fill(theme.foreground.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
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
                }
            case .saved:
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accent)
                        Text("已存进「写作」，可以接着往下写")
                            .font(.caption)
                            .foregroundStyle(theme.secondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                        } label: {
                            Text("留在这")
                                .font(.subheadline)
                                .foregroundStyle(theme.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 11).fill(theme.foreground.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        Button {
                            onOpenWriting()
                            dismiss()
                        } label: {
                            Text("去写作看")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.background)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 11).fill(theme.accent))
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .form:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
    }

    // MARK: - 动作

    private func start() {
        guard AISettings.shared.isConfigured else {
            phase = .failed
            errorText = AIError.notConfigured.localizedDescription
            return
        }
        task?.cancel()
        phase = .running
        text = ""
        errorText = nil
        thinkingChars = 0
        let messages = buildMessages()
        task = Task { await run(messages) }
    }

    private func buildMessages() -> [AIMessage] {
        switch action {
        case .rewrite:
            return WritingPrompts.rewrite(
                bookTitle: bookTitle,
                chapterTitle: chapterTitle,
                chapterText: chapterText,
                previousTail: previousTail,
                instruction: instruction
            )
        case .redirect:
            return WritingPrompts.redirect(
                bookTitle: bookTitle,
                chapterTitle: chapterTitle,
                chapterText: chapterText,
                instruction: instruction
            )
        case .continuation:
            return WritingPrompts.continueChapter(
                bookTitle: bookTitle,
                chapterTitle: chapterTitle,
                chapterIndex: chapterIndex,
                chapterText: chapterText,
                instruction: instruction
            )
        }
    }

    private func run(_ messages: [AIMessage]) async {
        do {
            let result = try await AIClient.shared.stream(messages: messages) { snapshot in
                text = snapshot
            } onReasoning: { count in
                thinkingChars = count
            }
            text = result
            phase = .done
            // 仅供自测：生成完直接走一遍「存进写作」，验证草稿落盘
            if ProcessInfo.processInfo.arguments.contains("--ai-save") { save() }
        } catch {
            if Task.isCancelled || error is CancellationError {
                phase = .stopped
            } else {
                errorText = error.localizedDescription
                phase = .failed
            }
        }
    }

    private func save() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        let projectTitle: String
        let segmentTitle: String
        let body: String
        switch action {
        case .rewrite:
            projectTitle = "《\(bookTitle)》改写"
            segmentTitle = "\(chapterTitle)（改写）"
            body = content
        case .redirect:
            projectTitle = "《\(bookTitle)》另一个走向"
            segmentTitle = "\(chapterTitle)（分叉）"
            body = content
        case .continuation:
            projectTitle = "《\(bookTitle)》续写"
            let parsed = WritingPrompts.splitChapter(content, fallbackTitle: "第\(chapterIndex + 2)章")
            segmentTitle = parsed.title
            body = parsed.body
        }

        let created = WritingStore.shared.create(
            title: projectTitle,
            mode: action.writingMode,
            brief: instruction,
            sourceBookID: bookID,
            sourceBookTitle: bookTitle,
            sourceChapterIndex: chapterIndex
        )
        guard var project = WritingStore.shared.project(created.id) else { return }
        project.segments = [WritingSegment(title: segmentTitle, text: body, generated: true)]
        WritingStore.shared.update(project)
        phase = .saved
    }
}
