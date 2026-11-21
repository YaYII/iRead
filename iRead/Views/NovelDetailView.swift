import Foundation
import SwiftUI

/// 书籍详情页：展示章节目录，提供整本下载、进度跟踪与取消。
struct NovelDetailView: View {
    let result: SearchResult

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var downloadManager = NovelDownloadManager.shared

    @State private var detail: NovelDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// 下载任务的 bookID 即详情 URL，用它关联当前书籍的任务。
    private var currentTask: DownloadTask? {
        downloadManager.task(forSourceKey: result.detailURL)
    }

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                content
                footer
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .task { await loadDetail() }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("书籍详情")
                    .font(.headline)
                    .foregroundStyle(settings.theme.secondary)
                Text(result.title)
                    .font(.title2.bold())
                    .foregroundStyle(settings.theme.foreground)
                    .lineLimit(1)
                Text("下载后书立即进入书架，可边下边读")
                    .font(.caption2)
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(settings.theme.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(settings.theme.secondary.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                ProgressView()
                    .tint(settings.theme.accent)
                Text("正在获取章节目录…")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        } else if let detail = detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    infoSection(detail)
                    chapterSection(detail)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        } else {
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(settings.theme.secondary)
                Text(errorMessage ?? "无法加载书籍详情")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.foreground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await loadDetail() }
                } label: {
                    Text("重试")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(settings.theme.accent))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        }
    }

    private func infoSection(_ detail: NovelDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.title)
                .font(.title2.bold())
                .foregroundStyle(settings.theme.foreground)
            HStack(spacing: 8) {
                Label(detail.author.isEmpty ? "作者未知" : detail.author, systemImage: "person")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
                Text("·")
                    .foregroundStyle(settings.theme.secondary)
                Label("\(detail.chapters.count) 章", systemImage: "list.bullet")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
            if !detail.intro.isEmpty {
                Text(detail.intro)
                    .font(.footnote)
                    .foregroundStyle(settings.theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
            }
            Text("来源：\(detail.sourceName)")
                .font(.caption2)
                .foregroundStyle(settings.theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(settings.theme.foreground.opacity(0.05))
        )
    }

    private func chapterSection(_ detail: NovelDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("章节目录（共 \(detail.chapters.count) 章）")
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            LazyVStack(spacing: 0) {
                ForEach(detail.chapters) { chapter in
                    HStack(spacing: 12) {
                        Text("\(chapter.index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(settings.theme.secondary)
                            .frame(width: 30, alignment: .trailing)
                        Text(chapter.title)
                            .font(.subheadline)
                            .foregroundStyle(settings.theme.foreground)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Divider()
                        .background(settings.theme.secondary.opacity(0.2))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(settings.theme.foreground.opacity(0.05))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - 底部操作区

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            Text(UsageNotice.text)
                .font(.caption2)
                .foregroundStyle(settings.theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let task = currentTask {
                switch task.status {
                case .queued, .fetching, .paused:
                    VStack(spacing: 8) {
                        HStack {
                            Text("正在下载 \(task.completedChapters)/\(task.totalChapters) 章")
                                .font(.subheadline)
                                .foregroundStyle(settings.theme.foreground)
                            Spacer()
                            Text("\(Int(task.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(settings.theme.secondary)
                        }
                        ProgressView(value: task.progress)
                            .tint(settings.theme.accent)
                        outlineButton(title: "取消下载") {
                            downloadManager.cancel(task.bookID)
                        }
                    }
                case .done:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(settings.theme.accent)
                        Text("已加入书架，可离线阅读")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(settings.theme.foreground)
                    }
                    filledButton(title: "完成") {
                        dismiss()
                    }
                case .failed, .cancelled:
                    if let message = task.errorMessage, !message.isEmpty {
                        Text("下载失败：\(message)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if task.status == .cancelled {
                        Text("下载已取消")
                            .font(.caption)
                            .foregroundStyle(settings.theme.secondary)
                    }
                    HStack(spacing: 12) {
                        filledButton(title: "重新下载") {
                            downloadManager.dismiss(task.bookID)
                            startDownload()
                        }
                        outlineButton(title: "取消") {
                            dismiss()
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    filledButton(title: "下载全书") {
                        startDownload()
                    }
                    .disabled(detail == nil)

                    outlineButton(title: "取消") {
                        dismiss()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(settings.theme.background)
        .overlay(
            Divider().background(settings.theme.secondary.opacity(0.2)),
            alignment: .top
        )
    }

    private func filledButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(settings.theme.accent)
                )
        }
        .buttonStyle(.plain)
    }

    private func outlineButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(settings.theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(settings.theme.accent, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 行为

    private func loadDetail() async {
        isLoading = true
        errorMessage = nil
        guard let source = SourceStore.shared.source(result.sourceID) else {
            isLoading = false
            errorMessage = "找不到书源「\(result.sourceName)」，它可能已被删除。"
            return
        }
        do {
            let loaded = try await NovelFetcher.chapters(result: result, source: source)
            await MainActor.run {
                self.detail = loaded
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "获取章节目录失败：\(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    private func startDownload() {
        guard let source = SourceStore.shared.source(result.sourceID) else {
            errorMessage = "找不到书源，无法下载。"
            return
        }
        guard let detail = detail else { return }
        // 新入口是同步的：书立即进书架并返回 bookID，正文由管理器后台分批抓取
        NovelDownloadManager.shared.download(detail: detail, source: source)
        // 书已在书架，关掉详情并通知根视图切到书架
        dismiss()
        NotificationCenter.default.post(name: Notification.Name("iReadOpenBookshelf"), object: nil)
    }
}
