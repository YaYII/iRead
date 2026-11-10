import SwiftUI
import Foundation

/// 目录页：展示全书章节、按标题搜索，点击跳转并关闭。
/// 外层负责 NavigationStack / sheet 的呈现，这里只负责内容与 dismiss。
struct ChapterListView: View {
    let book: Book
    let content: BookContent
    let currentIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    // 主题配色用单例读取，避免依赖外层是否注入 environmentObject
    @ObservedObject private var settings = ReaderSettings.shared
    @State private var query = ""

    private var theme: ReadingTheme { settings.theme }

    private var filteredChapters: [Chapter] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return content.chapters }
        return content.chapters.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            chapterList
            footer
        }
        .background(theme.background.ignoresSafeArea())
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(book.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            Text("共 \(content.chapterCount) 章")
                .font(.subheadline)
                .foregroundStyle(theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.secondary)
            TextField("搜索章节标题", text: $query)
                .foregroundStyle(theme.foreground)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - 章节列表

    private var chapterList: some View {
        List {
            if filteredChapters.isEmpty {
                Text("未找到匹配的章节")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(theme.background)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredChapters) { chapter in
                    Button {
                        onSelect(chapter.index)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(chapter.index == currentIndex ? theme.accent : Color.clear)
                                .frame(width: 3, height: 22)

                            Text("第 \(chapter.index + 1) 章")
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                                .frame(width: 58, alignment: .leading)

                            Text(chapter.title)
                                .font(.body)
                                .foregroundStyle(chapter.index == currentIndex ? theme.accent : theme.foreground)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if chapter.index == currentIndex {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        chapter.index == currentIndex
                            ? theme.accent.opacity(0.08)
                            : theme.background
                    )
                    .listRowSeparatorTint(theme.secondary.opacity(0.22))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部提示

    private var footer: some View {
        Text("本章起读，进度自动保存")
            .font(.footnote)
            .foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(theme.background)
    }
}
