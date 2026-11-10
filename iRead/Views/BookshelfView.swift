import Foundation
import SwiftUI

/// 书架首页。只负责展示与交互，打开阅读器由外层通过 onOpenBook 决定。
struct BookshelfView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var settings: ReaderSettings

    /// 由外层 ContentView 决定如何打开阅读器，本视图不自行导航到 ReaderView。
    var onOpenBook: (Book) -> Void
    /// 长按「听书」入口：打开阅读器并自动开始朗读
    var onListenBook: (Book) -> Void

    @State private var searchText = ""
    @State private var showGrid = true
    @State private var showImport = false

    @State private var showRename = false
    @State private var renameText = ""
    @State private var bookToRename: Book?

    @State private var showDeleteConfirm = false
    @State private var bookToDelete: Book?

    init(
        onOpenBook: @escaping (Book) -> Void = { _ in },
        onListenBook: @escaping (Book) -> Void = { _ in }
    ) {
        self.onOpenBook = onOpenBook
        self.onListenBook = onListenBook
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20)]
    }

    private var finishedCount: Int {
        store.books.filter { $0.isFinished }.count
    }

    /// 置顶优先，其次最近阅读，其次添加时间；搜索按书名 / 作者过滤。
    private var sortedBooks: [Book] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.books.filter { book in
            guard !query.isEmpty else { return true }
            return book.title.localizedCaseInsensitiveContains(query)
                || book.author.localizedCaseInsensitiveContains(query)
                || book.displayAuthor.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            switch (a.lastReadAt, b.lastReadAt) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return a.addedAt > b.addedAt
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                if let message = store.lastError {
                    errorBanner(message)
                }
                searchBar
                layoutToolbar

                ScrollView {
                    if sortedBooks.isEmpty {
                        emptyState
                            .padding(.top, 56)
                    } else if showGrid {
                        gridContent
                    } else {
                        listContent
                    }
                }
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .sheet(isPresented: $showImport) {
            ImportView()
                .environmentObject(store)
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("书名", text: $renameText)
            Button("取消", role: .cancel) { }
            Button("保存") {
                if let book = bookToRename {
                    store.rename(book: book, title: renameText)
                }
                bookToRename = nil
            }
        } message: {
            Text("输入新的书名，留空则不修改。")
        }
        .confirmationDialog(
            "删除《\(bookToDelete?.title ?? "")》？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let book = bookToDelete {
                    store.delete(book: book)
                }
                bookToDelete = nil
            }
            Button("取消", role: .cancel) { bookToDelete = nil }
        } message: {
            Text("书籍文件、阅读进度与书签将一并移除，且无法恢复。")
        }
    }

    // MARK: - 顶部区域

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("书架")
                    .font(.largeTitle.bold())
                    .foregroundStyle(settings.theme.foreground)
                Text("共 \(store.books.count) 本 · 已读 \(finishedCount) 本")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer()
            Button {
                showImport = true
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(settings.theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导入书籍")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(settings.theme.accent)
            Text(message)
                .font(.footnote)
                .foregroundStyle(settings.theme.foreground)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                store.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(settings.theme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.theme.accent.opacity(0.12))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(settings.theme.secondary)
            TextField("搜索书名或作者", text: $searchText)
                .foregroundStyle(settings.theme.foreground)
                .tint(settings.theme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(settings.theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.theme.secondary.opacity(0.14))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var layoutToolbar: some View {
        HStack {
            Text(showGrid ? "网格视图" : "列表视图")
                .font(.footnote)
                .foregroundStyle(settings.theme.secondary)
            Spacer()
            HStack(spacing: 4) {
                layoutButton(systemName: "square.grid.2x2", selected: showGrid) {
                    showGrid = true
                }
                layoutButton(systemName: "list.bullet", selected: !showGrid) {
                    showGrid = false
                }
            }
            .padding(3)
            .background(Capsule().fill(settings.theme.secondary.opacity(0.12)))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func layoutButton(
        systemName: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .white : settings.theme.secondary)
                .frame(width: 30, height: 26)
                .background(Capsule().fill(selected ? settings.theme.accent : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容区域

    private var gridContent: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(sortedBooks) { book in
                gridCard(book: book)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 96)
    }

    private var listContent: some View {
        VStack(spacing: 12) {
            ForEach(sortedBooks) { book in
                listRow(book: book)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 96)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: store.books.isEmpty ? "books.vertical" : "magnifyingglass")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(settings.theme.secondary)
            Text(store.books.isEmpty ? "书架还是空的" : "没有找到匹配的书")
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            Text(store.books.isEmpty
                 ? "导入本地 TXT 文件，开始你的离线阅读。"
                 : "试试更换书名或作者关键词。")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
                .multilineTextAlignment(.center)
            if store.books.isEmpty {
                Button {
                    showImport = true
                } label: {
                    Text("导入 TXT")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(settings.theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - 书卡

    private func gridCard(book: Book) -> some View {
        Button {
            onOpenBook(book)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                coverView(book: book)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)

                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(settings.theme.foreground)
                        .lineLimit(1)
                    Text(book.displayAuthor)
                        .font(.caption)
                        .foregroundStyle(settings.theme.secondary)
                        .lineLimit(1)
                }

                progressBar(progress: book.progress)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenuItems(for: book) }
    }

    private func listRow(book: Book) -> some View {
        Button {
            onOpenBook(book)
        } label: {
            HStack(spacing: 14) {
                coverView(book: book, compact: true)
                    .frame(width: 62, height: 84)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(book.title)
                            .font(.headline)
                            .foregroundStyle(settings.theme.foreground)
                            .lineLimit(1)
                        if book.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(settings.theme.accent)
                        }
                        if book.isFinished {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(settings.theme.accent)
                        }
                    }
                    Text(book.displayAuthor)
                        .font(.caption)
                        .foregroundStyle(settings.theme.secondary)
                        .lineLimit(1)
                    Text("共 \(book.chapterCount) 章 · 已读 \(book.progressPercent)")
                        .font(.caption2)
                        .foregroundStyle(settings.theme.secondary)
                        .lineLimit(1)
                    progressBar(progress: book.progress)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(settings.theme.foreground.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenuItems(for: book) }
    }

    /// 竖向渐变封面，中央书名 + 作者，角标与进度。compact 用于列表小封面。
    private func coverView(book: Book, compact: Bool = false) -> some View {
        let hue = min(1, max(0, book.coverHue))
        let top = Color(hue: hue, saturation: 0.58, brightness: 0.72)
        let bottom = Color(hue: hue, saturation: 0.68, brightness: 0.42)

        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [top, bottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 书脊
            HStack {
                Rectangle()
                    .fill(Color.black.opacity(0.14))
                    .frame(width: 7)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: compact ? 4 : 8) {
                Text(book.title)
                    .font(compact ? .caption.weight(.bold) : .title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(compact ? 2 : 3)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
                Text(book.displayAuthor)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? 8 : 14)

            if !compact {
                VStack {
                    HStack(alignment: .top) {
                        if book.isPinned {
                            badge(systemName: "pin.fill", rotation: -25)
                        }
                        Spacer()
                        if book.isFinished {
                            badge(systemName: "checkmark.circle.fill", rotation: 0)
                        }
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Text(book.progressPercent)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.28)))
                    }
                }
                .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
    }

    private func badge(systemName: String, rotation: Double) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(rotation))
            .padding(6)
            .background(Circle().fill(Color.black.opacity(0.28)))
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
        .frame(height: 4)
    }

    // MARK: - 长按菜单

    @ViewBuilder
    private func contextMenuItems(for book: Book) -> some View {
        Button {
            onListenBook(book)
        } label: {
            Label("听书", systemImage: "headphones")
        }
        Button {
            store.togglePin(book: book)
        } label: {
            Label(
                book.isPinned ? "取消置顶" : "置顶",
                systemImage: book.isPinned ? "pin.slash" : "pin"
            )
        }
        Button {
            store.toggleFinished(book: book)
        } label: {
            Label(
                book.isFinished ? "标记为未读" : "标记为已读",
                systemImage: book.isFinished ? "circle" : "checkmark.circle"
            )
        }
        Button {
            bookToRename = book
            renameText = book.title
            showRename = true
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            bookToDelete = book
            showDeleteConfirm = true
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}
