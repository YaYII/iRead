import SwiftUI

/// 线索日志：把「已经发生过的事实」按章列出来，一条一行。
///
/// 做成日志的样子不是玩形式：作者真正要回答的问题是两个 ——
/// 「AI 现在认定故事是什么样」和「这条认定是从哪一章读出来的」。
/// 前者靠一行一条、按时间排；后者靠每条都挂章号、点开就是原文。
/// 只给一段连贯的摘要，两个问题都答不了。
struct StoryLogView: View {
    let projectID: String

    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var writing = WritingStore.shared

    @State private var filter: StoryLogKind?
    /// 点开的那一章（带上「是哪条场记点进来的」，好在章节顶部标出来）
    @State private var peek: ChapterPeek?
    @State private var askBackfill = false
    @State private var backfilling = false
    @State private var backfillStep = ""

    private var theme: ReadingTheme { settings.theme }
    private var project: WritingProject? { writing.project(projectID) }

    private var allEntries: [StoryLogEntry] { project?.logEntries ?? [] }

    private var entries: [StoryLogEntry] {
        guard let filter else { return allEntries }
        return allEntries.filter { $0.kind == filter }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summaryBar
                Divider().opacity(0.25)
                if allEntries.isEmpty {
                    emptyState
                } else {
                    logList
                }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("线索日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(theme.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        askBackfill = true
                    } label: {
                        Text("补齐")
                            .foregroundStyle(canBackfill ? theme.accent : theme.secondary)
                    }
                    .disabled(!canBackfill || backfilling)
                }
            }
            .alert("补齐缺失的场记？", isPresented: $askBackfill) {
                Button("开始补齐") { runBackfill() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("还有 \(missingCount) 章没有场记。每章要调一次 AI，会花一点额度；补齐后 AI 写后面的章就有据可依了。")
            }
            .sheet(item: $peek) { item in
                ChapterLogPeek(projectID: projectID, segment: item.segment, entry: item.entry)
                    .environmentObject(settings)
            }
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                // `--open-log-peek`：自测用，直接点开第一条，验证「日志 → 来源章节」这条链
                if args.contains("--open-log-peek"),
                   let first = allEntries.first,
                   let project,
                   let segment = project.segments.first(where: { $0.id == first.segmentID }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        peek = ChapterPeek(segment: segment, entry: first)
                    }
                }
                // `--backfill-log`：自测用，进来就跑一次补齐
                if args.contains("--backfill-log"), missingCount > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { runBackfill() }
                }
            }
        }
    }

    private var missingCount: Int { project?.chaptersWithoutLog.count ?? 0 }
    private var canBackfill: Bool { missingCount > 0 }

    // MARK: - 顶部统计与筛选

    private var summaryBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                stat("\(allEntries.count)", "条事实")
                stat("\(allEntries.filter { $0.kind == .character }.count)", "人物状态")
                stat("\(project?.pendingThreads.count ?? 0)", "伏笔未回收")
                Spacer()
            }
            if backfilling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(backfillStep)
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(nil, title: "全部")
                    ForEach(StoryLogKind.allCases) { kind in
                        chip(kind, title: kind.title)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.foreground)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.secondary)
        }
    }

    private func chip(_ kind: StoryLogKind?, title: String) -> some View {
        let active = filter == kind
        return Button {
            filter = kind
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? theme.background : theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(active ? theme.accent : theme.foreground.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 日志列表

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    row(entry)
                    Divider()
                        .overlay(theme.secondary.opacity(0.1))
                        .padding(.leading, 42)
                }
                if entries.isEmpty {
                    Text("这一类还没有记录")
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func row(_ entry: StoryLogEntry) -> some View {
        Button {
            guard let project,
                  let segment = project.segments.first(where: { $0.id == entry.segmentID }) else { return }
            peek = ChapterPeek(segment: segment, entry: entry)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // 左边一根彩色细条 + 章号：扫一眼就知道这条是哪一类、从哪一章来
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint(entry.kind).opacity(entry.resolved ? 0.25 : 0.9))
                    .frame(width: 3)
                    .padding(.vertical, 3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.chapterLabel)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.secondary)
                        Text(entry.kind.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tint(entry.kind))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(tint(entry.kind).opacity(0.13)))
                        if entry.kind == .thread {
                            Text(entry.resolved ? "已回收" : "未回收")
                                .font(.system(size: 10))
                                .foregroundStyle(entry.resolved ? theme.secondary : .orange)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.secondary.opacity(0.6))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(entry.subject)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(entry.resolved ? theme.secondary : theme.foreground)
                        Text(entry.summary)
                            .font(.footnote)
                            .foregroundStyle(theme.foreground.opacity(entry.resolved ? 0.45 : 0.78))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if entry.kind == .thread {
                Button {
                    StoryLogService.toggleResolved(entryID: entry.id, projectID: projectID)
                } label: {
                    Label(entry.resolved ? "标为未回收" : "标为已回收", systemImage: "checkmark.circle")
                }
            }
            Button(role: .destructive) {
                StoryLogService.delete(entryID: entry.id, projectID: projectID)
            } label: {
                Label("删掉这条", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.line.last.and.arrowtriangle.forward")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.accent)
            Text("还没有场记")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.foreground)
            Text("每写完一章，AI 会顺手记下「谁变成了什么样、发生了什么、埋了什么伏笔」。\n老章可以点右上角「补齐」，逐章补一遍。")
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tint(_ kind: StoryLogKind) -> Color {
        switch kind {
        case .character: return theme.accent
        case .event: return .orange
        case .thread: return .purple
        case .item: return .teal
        case .world: return .blue
        }
    }

    // MARK: - 补齐

    private func runBackfill() {
        guard !backfilling else { return }
        backfilling = true
        backfillStep = "正在补齐…"
        Task { @MainActor in
            let result = await StoryLogService.backfill(projectID: projectID) { step, total in
                backfillStep = "已补 \(step)/\(total) 章"
            }
            backfilling = false
            backfillStep = result.failed > 0
                ? "补了 \(result.done) 章，\(result.failed) 章没补上"
                : "补了 \(result.done) 章"
        }
    }
}

// MARK: - 点开一条：这一章的原文

/// 一条场记 + 它来源的那一章。
///
/// 场记是 AI 对一章的「理解」，而理解可能是错的。把原文摆在同屏，作者才能判断
/// 「AI 记的这条对不对」—— 这一步不做，日志就只是一份没人敢信的摘要。
private struct ChapterPeek: Identifiable {
    let segment: WritingSegment
    let entry: StoryLogEntry
    var id: String { segment.id + entry.id }
}

private struct ChapterLogPeek: View {
    let projectID: String
    let segment: WritingSegment
    let entry: StoryLogEntry

    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    private var theme: ReadingTheme { settings.theme }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    banner
                    Text(segment.title.isEmpty ? "未命名章节" : segment.title)
                        .font(.headline)
                        .foregroundStyle(theme.foreground)
                    HStack(spacing: 8) {
                        Text("\(segment.wordCount) 字")
                        Text("·")
                        Text(entry.chapterLabel)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondary)

                    Text(segment.text)
                        .font(.custom("Songti SC", size: 16))
                        .foregroundStyle(theme.foreground.opacity(0.9))
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("来源章节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("这条场记是从下面这一章读出来的")
                .font(.caption2)
                .foregroundStyle(theme.accent)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(entry.subject)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                Text(entry.summary)
                    .font(.footnote)
                    .foregroundStyle(theme.foreground.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.accent.opacity(0.09)))
    }
}
