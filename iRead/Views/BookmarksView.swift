import SwiftUI
import Foundation

/// 书签列表：展示某本书的全部书签，支持左滑删除与点击跳转。
/// 阅读器里只有这一个书签入口 —— 加/删当前位置的书签也在这里做，
/// 不再在顶栏另放一颗按钮（两处入口用户会以为是两个功能）。
struct BookmarksView: View {
    let book: Book
    /// 阅读器当前所在位置：判断「这里有没有书签」、加书签时取哪段文字
    var chapterIndex: Int = 0
    var charOffset: Int = 0
    /// 加/取消当前位置的书签；由阅读器提供（它才知道当前位置的正文）
    var onToggleCurrent: (() -> Void)? = nil
    let onJump: (Int, Int) -> Void

    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    // 主题配色用单例读取，避免依赖外层是否注入 environmentObject
    @ObservedObject private var settings = ReaderSettings.shared

    private var theme: ReadingTheme { settings.theme }

    private var items: [Bookmark] {
        store.bookmarks(for: book.id)
    }

    /// 当前位置是否已有书签（阈值与 store 内一致，40 字以内算同一处）
    private var isCurrentBookmarked: Bool {
        store.isBookmarked(bookID: book.id, chapterIndex: chapterIndex, charOffset: charOffset)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if items.isEmpty {
                emptyState
            } else {
                bookmarkList
            }
        }
        .background(theme.background.ignoresSafeArea())
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text(items.isEmpty ? "暂无书签" : "共 \(items.count) 个书签")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onToggleCurrent {
                Button(action: onToggleCurrent) {
                    HStack(spacing: 4) {
                        Image(systemName: isCurrentBookmarked ? "bookmark.slash" : "bookmark.badge.plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text(isCurrentBookmarked ? "取消书签" : "加书签")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().stroke(theme.accent, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.foreground.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - 列表

    private var bookmarkList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { bookmark in
                    bookmarkRow(bookmark)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.removeBookmark(bookmark)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        Button {
            onJump(bookmark.chapterIndex, bookmark.charOffset ?? 0)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(bookmark.excerpt.isEmpty ? book.title : bookmark.excerpt)
                    .font(.body)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    Label("第 \(bookmark.chapterIndex + 1) 章", systemImage: "book.closed")
                    Spacer(minLength: 4)
                    Text(shortDate(bookmark.createdAt))
                }
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.foreground.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark")
                .font(.system(size: 42))
                .foregroundStyle(theme.secondary.opacity(0.6))
            Text("还没有书签")
                .font(.headline)
                .foregroundStyle(theme.foreground)
            Text("阅读时点击书签按钮，即可在这里快速回到那个位置")
                .font(.subheadline)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 时间格式化

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "昨天 HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}
