import SwiftUI

/// 「写作」Tab：自己的书都在这儿。
///
/// 和书架刻意分成两个空间：书架是别人写完的书（只读），这里是自己写了一半的书。
/// 混在一起会出现「我不小心改到原著了吗」这种担心 —— 而 AI 改写最怕用户不敢点。
struct WritingHomeView: View {
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var writing = WritingStore.shared
    @ObservedObject private var ai = AISettings.shared

    @State private var path: [String] = []
    @State private var showNew = false
    @State private var deleteTarget: WritingProject?

    private var theme: ReadingTheme { settings.theme }

    private var totalWords: Int {
        writing.projects.reduce(0) { $0 + $1.wordCount }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    if !ai.isConfigured { setupBanner }
                    summaryBar
                    if writing.projects.isEmpty {
                        emptyState
                    } else {
                        ForEach(writing.projects) { project in
                            NavigationLink(value: project.id) {
                                projectCard(project)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteTarget = project
                                } label: {
                                    Label("删除这本", systemImage: "trash")
                                }
                            }
                        }
                    }
                    hint
                }
                .padding(16)
                // 标签栏 + 悬浮「听」球的高度，别让最后一张卡被压住
                .padding(.bottom, 96)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("写作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                    .accessibilityLabel("新建作品")
                }
            }
            .navigationDestination(for: String.self) { id in
                WritingEditorView(projectID: id)
                    .environmentObject(settings)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showNew) {
                NewWritingSheet { id in
                    showNew = false
                    path = [id]
                }
                .environmentObject(settings)
                .environmentObject(store)
            }
            .alert("删除《\(deleteTarget?.title ?? "")》？",
                   isPresented: Binding(
                       get: { deleteTarget != nil },
                       set: { if !$0 { deleteTarget = nil } }
                   )) {
                Button("删除", role: .destructive) {
                    if let target = deleteTarget { writing.delete(target.id) }
                    deleteTarget = nil
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("稿件会从本机删掉，导出过的 txt 不受影响。")
            }
            .onAppear {
                applyDebugArguments()
            }
        }
    }

    // MARK: - 概览

    /// 没配 AI 时先说清楚，别让人点进编辑器写了半天才发现生不出来
    private var setupBanner: some View {
        Button {
            NotificationCenter.default.post(name: .iReadOpenSettings, object: nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 还没配置")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.foreground)
                    Text("去「设置 → AI 写作」选服务商、填 Key；本地模型不用 Key。")
                        .font(.caption2)
                        .foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.accent.opacity(0.3), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summaryBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(writing.projects.count)")
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.accent)
            Text("本")
                .font(.caption)
                .foregroundStyle(theme.secondary)
            Text("·")
                .font(.caption)
                .foregroundStyle(theme.secondary.opacity(0.5))
            Text("\(totalWords)")
                .font(.system(size: 22, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.foreground)
            Text("字")
                .font(.caption)
                .foregroundStyle(theme.secondary)
            Spacer()
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.accent)
                .padding(.top, 28)
            Text("让 AI 写一本你的书")
                .font(.headline)
                .foregroundStyle(theme.foreground)
            Text("拿书架上任何一本当底本重构、续写，\n或者只告诉它你喜欢什么类型。\nAI 写出来的东西只进这里，不会动原著一个字。")
                .font(.subheadline)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Button {
                showNew = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("开始创作")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.background)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 项目卡

    private func projectCard(_ project: WritingProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(project.title)
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(project.mode.title)
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.accent.opacity(0.12)))
            }
            Text(project.summary)
                .font(.caption)
                .foregroundStyle(theme.secondary)
            Text(project.lastPreview)
                .font(.subheadline)
                .foregroundStyle(theme.foreground.opacity(0.72))
                .lineLimit(2)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text(shortDate(project.updatedAt))
                Spacer()
                Text("继续写")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption2)
            .foregroundStyle(theme.secondary.opacity(0.9))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.foreground.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var hint: some View {
        Text("写作与书架分开存放：导出 txt 可直接投平台，删稿不会影响原著。")
            .font(.caption2)
            .foregroundStyle(theme.secondary.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 自测

    /// `--debug-writing-new`：直接弹新建页；`--seed-writing title`：塞一本样本便于截图
    private func applyDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--debug-writing-new") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showNew = true }
        }
        if let index = args.firstIndex(of: "--seed-writing"), index + 1 < args.count,
           writing.projects.isEmpty {
            let title = args[index + 1]
            let book = store.books.first { !$0.isComic }
            var project = writing.create(
                title: title,
                mode: book == nil ? .original : .rewrite,
                brief: "都市悬疑，节奏快一点",
                sourceBookID: book?.id,
                sourceBookTitle: book?.title
            )
            // `--seed-outline "..."`：给样本稿塞一份大纲，用来测连写是不是真的照着走
            if let i = args.firstIndex(of: "--seed-outline"), i + 1 < args.count {
                project.outline = args[i + 1]
                writing.update(project)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { path = [project.id] }
        }
        // 仅供截图：直接打开最近一本
        if args.contains("--open-writing"), let first = writing.projects.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + Demo.step(0.4)) { path = [first.id] }
        }
    }
}

// MARK: - 新建

struct NewWritingSheet: View {
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var onCreate: (String) -> Void

    @State private var title = ""
    @State private var mode: WritingMode = .original
    @State private var brief = ""
    @State private var sourceBookID: String?

    private var theme: ReadingTheme { settings.theme }

    private var textBooks: [Book] {
        store.books.filter { !$0.isComic }
    }

    private var sourceBook: Book? {
        textBooks.first { $0.id == sourceBookID }
    }

    private var canCreate: Bool {
        mode == .original || sourceBook != nil
    }

    private let suggestions = ["都市悬疑", "古风志怪", "修仙升级", "甜宠日常", "末日求生", "职场群像"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    modeSection
                    titleSection
                    if mode != .original { sourceSection }
                    briefSection
                    privacyNote
                }
                .padding(16)
                .padding(.bottom, 90)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("新建作品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(theme.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: create) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("开始写第一章")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canCreate ? theme.background : theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(canCreate ? theme.accent : theme.foreground.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
            }
        }
    }

    // MARK: 方式

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("从哪儿开始")
            ForEach(WritingMode.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        mode = item
                        if item == .original { sourceBookID = nil }
                        if sourceBookID == nil, item != .original, let first = textBooks.first {
                            sourceBookID = first.id
                        }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(mode == item ? theme.accent : theme.secondary)
                            .frame(width: 22, height: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(theme.foreground)
                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: mode == item ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(mode == item ? theme.accent : theme.secondary.opacity(0.35))
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(mode == item ? theme.accent.opacity(0.08) : theme.foreground.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(mode == item ? theme.accent.opacity(0.55) : theme.secondary.opacity(0.14),
                                    lineWidth: mode == item ? 1 : 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 书名

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("书名")
            TextField("给这本书取个名字（之后能改）", text: $title)
                .font(.subheadline)
                .foregroundStyle(theme.foreground)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.foreground.opacity(0.05)))
        }
    }

    // MARK: 底本

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("底本")
            Menu {
                ForEach(textBooks) { book in
                    Button {
                        sourceBookID = book.id
                    } label: {
                        Label("\(book.title) · \(book.chapterCount) 章", systemImage: book.id == sourceBookID ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceBook?.title ?? "从书架选一本")
                            .font(.subheadline)
                            .foregroundStyle(theme.foreground)
                        Text(sourceBook.map { "\($0.chapterCount) 章 · 会读它的开头当参照" } ?? "书架上的文字书")
                            .font(.caption2)
                            .foregroundStyle(theme.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(theme.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.foreground.opacity(0.05)))
            }
            if mode == .continuation {
                Text("会从这本书的最后一章之后接着写；想从中间某章分叉，去阅读页用顶部的 AI 入口。")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if textBooks.isEmpty {
                Text("书架里还没有文字书。先去「书架」导入或下载一本。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: 方向

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("方向（一句话就够）")
            TextField("比如：都市悬疑，主角是个失眠的修表匠", text: $brief, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(theme.foreground)
                .lineLimit(2...5)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.foreground.opacity(0.05)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { item in
                        Button {
                            if brief.isEmpty {
                                brief = item
                            } else if !brief.contains(item) {
                                brief += "，\(item)"
                            }
                        } label: {
                            Text(item)
                                .font(.caption)
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(theme.accent.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondary)
            Text("只有你选中的底本开头会发给 AI 服务；书架其他书只发书名，用来判断你偏好什么类型。")
                .font(.caption2)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondary)
    }

    // MARK: 创建

    private func create() {
        // 书名留空时先用一个临时名，第一章生成后按 AI 给的方向补
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = WritingStore.shared.create(
            title: finalTitle.isEmpty ? "未命名作品" : finalTitle,
            mode: mode,
            brief: brief,
            sourceBookID: sourceBook?.id,
            sourceBookTitle: sourceBook?.title,
            sourceChapterIndex: mode == .continuation ? max(0, (sourceBook?.chapterCount ?? 1) - 1) : nil
        )
        onCreate(project.id)
    }
}
