import Foundation
import SwiftUI

/// 下载任务页：展示所有章节下载任务的状态与进度，支持取消、移除与清理已结束任务。
struct DownloadTasksView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var downloadManager = NovelDownloadManager.shared

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
    }

    private var hasFinished: Bool {
        downloadManager.tasks.contains { [.done, .failed, .cancelled].contains($0.status) }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("下载任务")
                    .font(.largeTitle.bold())
                    .foregroundStyle(settings.theme.foreground)
                Text("进行中 \(downloadManager.activeTasks.count) 项 · 共 \(downloadManager.tasks.count) 项")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer()
            Button {
                downloadManager.clearFinished()
            } label: {
                Text("清除已结束")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(settings.theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().stroke(settings.theme.accent, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!hasFinished)
            // 以 sheet 呈现，得给个明确的关闭入口（下拉虽然也能关，但不明显）
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(settings.theme.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(settings.theme.foreground.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if downloadManager.tasks.isEmpty {
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(settings.theme.secondary)
                Text("暂无下载任务")
                    .font(.headline)
                    .foregroundStyle(settings.theme.foreground)
                Text("在搜书页选择书籍并点击「下载全书」，任务会显示在这里。")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(downloadManager.tasks) { task in
                        taskRow(task)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
    }

    private func taskRow(_ task: DownloadTask) -> some View {
        // isActive 已包含排队 / 下载中 / 已暂停，进度条与操作按钮据此显示
        let isActive = task.isActive

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(settings.theme.foreground)
                        .lineLimit(1)
                    Text("来源：\(task.sourceName)")
                        .font(.caption)
                        .foregroundStyle(settings.theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                statusTag(task.status)
            }

            if isActive {
                progressBar(progress: task.progress)
            }

            HStack(alignment: .top) {
                Text("\(task.completedChapters)/\(task.totalChapters) 章")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(settings.theme.secondary)
                Spacer(minLength: 8)
                if let message = task.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }

            HStack(spacing: 12) {
                Spacer()
                if isActive {
                    // 暂停 / 继续：paused 显示「继续」，其余显示「暂停」
                    actionButton(title: task.status == .paused ? "继续" : "暂停") {
                        downloadManager.togglePause(task.bookID)
                    }
                    actionButton(title: "取消") {
                        downloadManager.cancel(task.bookID)
                    }
                } else {
                    actionButton(title: "移除") {
                        downloadManager.dismiss(task.bookID)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(settings.theme.foreground.opacity(0.05))
        )
    }

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(settings.theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().stroke(settings.theme.accent, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func statusTag(_ status: DownloadStatus) -> some View {
        let color: Color = {
            switch status {
            case .done: return settings.theme.accent
            case .failed: return .red
            case .cancelled: return settings.theme.secondary
            case .queued, .fetching: return settings.theme.accent
            case .paused: return settings.theme.secondary
            }
        }()
        return Text(status.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func progressBar(progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(settings.theme.secondary.opacity(0.22))
                Capsule()
                    .fill(settings.theme.accent)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, progress))))
            }
        }
        .frame(height: 5)
    }
}
