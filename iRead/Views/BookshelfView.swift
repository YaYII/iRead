import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

/// 书架首页。只负责展示与交互，打开阅读器由外层通过 onOpenBook 决定。
struct BookshelfView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var settings: ReaderSettings
    /// 下载进度 / 暂停继续来自单例，@Published 变化会自动刷新书架
    @ObservedObject private var downloadManager = NovelDownloadManager.shared

    /// 由外层 ContentView 决定如何打开阅读器，本视图不自行导航到 ReaderView。
    var onOpenBook: (Book) -> Void
    /// 长按「听书」入口：打开阅读器并自动开始朗读
    var onListenBook: (Book) -> Void
    /// 右上角齿轮：设置不再是 Tab，由外层弹 sheet
    var onOpenSettings: () -> Void

    @State private var searchText = ""
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    @State private var showGrid = true
    @State private var showImport = false

    /// 书架分类：左边电子书（默认），右边漫画书。
    /// 两类共用 `store.books` 这张表（`kind` 区分），只是展示与入口分开，
    /// 这样备份、搜索、进度逻辑都不必各写一份。
    @State private var shelf: ShelfKind = .ebook
    @State private var showComicSearch = false
    @State private var showComicImporter = false
    @ObservedObject private var comicDownloads = ComicDownloadManager.shared

    enum ShelfKind: String, CaseIterable, Identifiable {
        case ebook
        case comic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ebook: return "电子书"
            case .comic: return "漫画书"
            }
        }

        var icon: String {
            switch self {
            case .ebook: return "book.closed"
            case .comic: return "rectangle.stack"
            }
        }
    }

    @State private var showRename = false
    @State private var renameText = ""
    @State private var bookToRename: Book?

    @State private var showDeleteConfirm = false
    @State private var bookToDelete: Book?

    /// 「检查更新」的手动结果提示（自动续传是静默的，不打扰阅读）
    @State private var updateNotice: String?
    @State private var showUpdateNotice = false
    @State private var checkingBookID: String?

    init(
        onOpenBook: @escaping (Book) -> Void = { _ in },
        onListenBook: @escaping (Book) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.onOpenBook = onOpenBook
        self.onListenBook = onListenBook
        self.onOpenSettings = onOpenSettings
    }

    /// 番茄式书架：九宫格（三列），封面小、信息少。窄屏（SE）也能放下三列。
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 70, maximum: 112), spacing: 24)]
    }

    /// 置顶优先，其次最近阅读，其次添加时间；搜索按书名 / 作者过滤。
    /// 先按分类过滤：电子书和漫画书是两个书架，互相看不到。
    private var sortedBooks: [Book] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.books.filter { book in
            guard book.isComic == (shelf == .comic) else { return false }
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
                shelfPicker
                if let message = store.lastError {
                    errorBanner(message)
                }
                if showSearch || !searchText.isEmpty {
                    searchBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

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
        .sheet(isPresented: $showComicSearch) {
            ComicSearchView()
        }
        .fileImporter(
            isPresented: $showComicImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            importComic(result)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("iReadSwitchToComicShelf"))) { _ in
            shelf = .comic
        }
        .onChange(of: shelf) { _, newValue in
            // 听书悬浮球挂在根视图上，漫画既不能听也没有「当前书」，
            // 在漫画分类下留在那儿只会占地方，用这个共享标记把它收起来。
            ShelfMode.shared.isComic = (newValue == .comic)
        }
        .onAppear {
            ShelfMode.shared.isComic = (shelf == .comic)
            // 仅供自动化自测：--shelf-comic 启动直接落在漫画书架
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--shelf-comic") {
                shelf = .comic
                ShelfMode.shared.isComic = true
            }
            // 仅供自动化自测：--open-comic-search 从书架检验「漫画搜索」sheet 入口
            if args.contains("--open-comic-search") {
                shelf = .comic
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showComicSearch = true }
            }
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
            Text("书籍文件与阅读进度将一并移除，且无法恢复。")
        }
        .alert("检查更新", isPresented: $showUpdateNotice) {
            Button("好", role: .cancel) { }
        } message: {
            Text(updateNotice ?? "")
        }
    }

    // MARK: - 顶部区域

    /// 紧凑标题行：书名标题 + 数量 + 视图切换 + 导入，一行说完。
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("书架")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(settings.theme.foreground)
            Text("\(shelfCount) 本")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(settings.theme.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(settings.theme.secondary.opacity(0.14)))
            Spacer(minLength: 4)
            // 搜索收进图标，和番茄书架一致：不占常驻一行
            Button {
                // 漫画书架的放大镜进「漫画搜索」模块：和搜书是两个互不相干的入口
                if shelf == .comic {
                    searchFocused = false
                    showComicSearch = true
                    return
                }
                if showSearch {
                    searchFocused = false
                    searchText = ""
                    withAnimation(.easeInOut(duration: 0.18)) { showSearch = false }
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) { showSearch = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(showSearch && shelf == .ebook ? settings.theme.accent : settings.theme.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shelf == .comic ? "搜索漫画" : (showSearch ? "收起搜索" : "搜索书架"))

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showGrid.toggle() }
            } label: {
                Image(systemName: showGrid ? "square.grid.2x2" : "list.bullet")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(settings.theme.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showGrid ? "切换为列表视图" : "切换为网格视图")

            Button {
                if shelf == .comic { showComicImporter = true } else { showImport = true }
            } label: {
                Image(systemName: "plus")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(settings.theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shelf == .comic ? "导入漫画图片" : "导入书籍")

            // 设置只做一个 icon，不占 Tab、不带文字：齿轮本身就够表意
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(settings.theme.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// 书架分类切换：左边电子书（默认）、右边漫画书，带各自数量。
    /// 用自绘胶囊而不是系统 Picker：系统分段控件的字号跟着动态字体走，
    /// 在书架这种小标题行里会撑高，且配色不受阅读主题控制。
    private var shelfPicker: some View {
        HStack(spacing: 4) {
            ForEach(ShelfKind.allCases) { kind in
                let selected = shelf == kind
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shelf = kind
                        searchText = ""
                        searchFocused = false
                        showSearch = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: kind.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(kind.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        Text("\(bookCount(kind))")
                            .font(.system(size: 10, weight: .medium))
                            .opacity(0.65)
                    }
                    .foregroundStyle(selected ? settings.theme.foreground : settings.theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule()
                            .fill(selected ? settings.theme.background : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 3, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(settings.theme.secondary.opacity(0.13)))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var shelfCount: Int { bookCount(shelf) }

    private func bookCount(_ kind: ShelfKind) -> Int {
        store.books.reduce(0) { $0 + ($1.isComic == (kind == .comic) ? 1 : 0) }
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(settings.theme.secondary)
            TextField("搜索书名或作者", text: $searchText)
                .font(.system(size: 12))
                .focused($searchFocused)
                .foregroundStyle(settings.theme.foreground)
                .tint(settings.theme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(settings.theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(settings.theme.secondary.opacity(0.13))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 内容区域

    private var gridContent: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(sortedBooks) { book in
                gridCard(book: book)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 96)
    }

    private var listContent: some View {
        VStack(spacing: 8) {
            ForEach(sortedBooks) { book in
                listRow(book: book)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 96)
    }

    private var emptyState: some View {
        let isComic = shelf == .comic
        let isEmptyShelf = bookCount(shelf) == 0
        return VStack(spacing: 16) {
            Image(systemName: isEmptyShelf ? (isComic ? "rectangle.stack" : "books.vertical") : "magnifyingglass")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(settings.theme.secondary)
            Text(isEmptyShelf ? (isComic ? "还没有漫画" : "书架还是空的") : "没有找到匹配的书")
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            Text(isEmptyShelf
                 ? (isComic
                    ? "搜索在线漫画，或把手机里的图片导入成一本。"
                    : "导入本地 TXT 文件，开始你的离线阅读。")
                 : "试试更换书名或作者关键词。")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
                .multilineTextAlignment(.center)
            if isEmptyShelf {
                HStack(spacing: 10) {
                    Button {
                        if isComic { showComicSearch = true } else { showImport = true }
                    } label: {
                        Text(isComic ? "搜索漫画" : "导入 TXT")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(settings.theme.accent))
                    }
                    .buttonStyle(.plain)

                    if isComic {
                        Button {
                            showComicImporter = true
                        } label: {
                            Text("导入图片")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(settings.theme.accent)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Capsule().stroke(settings.theme.accent, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - 书卡

    /// 网格卡只剩封面 + 一行书名，和番茄书架一致；作者、进度都在封面里。
    private func gridCard(book: Book) -> some View {
        Button {
            onOpenBook(book)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                // 先用透明占位把格子撑成 3:4，再叠封面，保证每列封面等宽等高
                Color.clear
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay { coverView(book: book) }

                Text(book.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(settings.theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 下载控制层作为 Button 的 overlay（不在 label 内）：既盖在封面上，
        // 又不会把内层暂停按钮的点击冒泡到外层 onOpenBook。
        .overlay(alignment: .top) {
            downloadLayer(for: book)
                // 卡片宽度即封面宽度，按 3:4 撑出封面高度，正好盖住封面
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
        }
        .overlay(alignment: .top) {
            comicDownloadLayer(for: book)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
        }
        .contextMenu { contextMenuItems(for: book) }
    }

    private func listRow(book: Book) -> some View {
        Button {
            onOpenBook(book)
        } label: {
            HStack(spacing: 10) {
                coverView(book: book, showsBadges: false, showsTitle: false)
                    .frame(width: 46, height: 62)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(book.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(settings.theme.foreground)
                            .lineLimit(1)
                        if book.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(settings.theme.accent)
                        }
                        if book.isFinished {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(settings.theme.accent)
                        }
                    }
                    Text(book.displayAuthor)
                        .font(.system(size: 10))
                        .foregroundStyle(settings.theme.secondary)
                        .lineLimit(1)
                    // 网络书下到一半：显示实际缺口，别只写「共 N 章」让人以为已经全本
                    if book.missingChapters > 0 {
                        Text("已下 \(book.downloadedChapters)/\(book.download?.total ?? 0) 章 · 还差 \(book.missingChapters) 章")
                            .font(.system(size: 10))
                            .foregroundStyle(settings.theme.accent)
                            .lineLimit(1)
                    } else {
                        Text("共 \(book.chapterCount) 章 · 已读 \(book.progressPercent)")
                            .font(.system(size: 10))
                            .foregroundStyle(settings.theme.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(settings.theme.secondary.opacity(0.7))
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(settings.theme.foreground.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 同样放到 overlay（Button 外）：列表里封面固定在左上角 46×62、内边距 9
        .overlay(alignment: .topLeading) {
            downloadLayer(for: book, compact: true)
                .frame(width: 46, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .offset(x: 9, y: 9)
        }
        .overlay(alignment: .topLeading) {
            comicDownloadLayer(for: book, compact: true)
                .frame(width: 46, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .offset(x: 9, y: 9)
        }
        .contextMenu { contextMenuItems(for: book) }
    }

    /// 生成式封面：渐变底 + 居中书名，底部一条细进度线；置顶 / 已读用小角标。
    /// 列表里的小缩略图不重复画书名（右侧已有标题），只留色块和书脊。
    /// 漫画有实拍封面（第一张已下载的图），走另一套渲染。
    @ViewBuilder
    private func coverView(
        book: Book,
        showsBadges: Bool = true,
        showsTitle: Bool = true
    ) -> some View {
        if book.isComic {
            ComicShelfCover(
                book: book,
                theme: settings.theme,
                showsBadges: showsBadges,
                showsTitle: showsTitle
            )
        } else {
            generatedCover(book: book, showsBadges: showsBadges, showsTitle: showsTitle)
        }
    }

    private func generatedCover(
        book: Book,
        showsBadges: Bool = true,
        showsTitle: Bool = true
    ) -> some View {
        let hue = min(1, max(0, book.coverHue))
        let top = Color(hue: hue, saturation: 0.56, brightness: 0.74)
        let bottom = Color(hue: hue, saturation: 0.68, brightness: 0.42)
        let progress = min(1, max(0, book.progress))

        return ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)

            // 书脊
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.black.opacity(0.12))
                    .frame(width: 4)
                Spacer(minLength: 0)
            }

            if showsTitle {
                Text(book.title)
                    .font(.system(size: 11, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 6)
            }

            if showsBadges {
                VStack {
                    HStack(alignment: .top, spacing: 4) {
                        if book.isPinned {
                            cornerBadge(systemName: "pin.fill", rotation: -25)
                        }
                        Spacer(minLength: 0)
                        if book.isFinished {
                            cornerBadge(systemName: "checkmark", rotation: 0)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(5)
            }

            // 阅读进度：贴底细线，不额外占高度
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.18))
                        if progress > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: geo.size.width * CGFloat(progress))
                        }
                    }
                }
                .frame(height: 2.5)
            }

            // 网络书没下完：封面上直接标「还差几章」。
            // 只在没有下载任务盖着的时候看得见；有任务时进度层会盖住这里，
            // 那边显示的是「下载中 x%」，信息不重复。
            if showsBadges, !book.isComic, book.missingChapters > 0 {
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Text("还差 \(book.missingChapters) 章")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
    }

    private func cornerBadge(systemName: String, rotation: Double) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(rotation))
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.black.opacity(0.35)))
    }

    // MARK: - 下载状态层

    /// 书有活跃下载任务时才叠加；compact 用于列表小封面（46×62）。
    /// 整层挂在卡片 Button 的 overlay 上（Button 外），暂停按钮用 plain 样式 +
    /// 自身 action 处理，其余区域 allowsHitTesting(false) 透传给外层打开阅读器，
    /// 因此点暂停不会冒泡触发 onOpenBook，点封面仍照常打开「下几章读几章」。
    @ViewBuilder
    private func downloadLayer(for book: Book, compact: Bool = false) -> some View {
        if let task = downloadManager.task(forBookID: book.id), task.isActive {
            downloadLayerContent(task: task, book: book, compact: compact)
        }
    }

    private func downloadLayerContent(task: DownloadTask, book: Book, compact: Bool) -> some View {
        let isPaused = task.status == .paused
        // 下载是单本队列：没轮到的那本要能看出「在排队」，别以为它也在跑
        let isQueued = task.status == .queued
        let statusText: String = {
            if isPaused { return "已暂停" }
            if isQueued { return "等待中" }
            // 卡片宽不到 90pt，带章节数必然被截成省略号；进度交给下面的百分比和进度条
            return "下载中"
        }()
        let progress = min(1, max(0, task.progress))

        return ZStack {
            // 半透明遮罩让下载状态一眼可见；不吃点击，封面其余区域仍可打开阅读器
            Color.black.opacity(0.30)
                .allowsHitTesting(false)

            VStack(spacing: compact ? 1 : 4) {
                // 状态文字 + 暂停/继续按钮：暂停中显示 play，下载中显示 pause
                HStack(spacing: 3) {
                    Text(statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(settings.theme.foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .allowsHitTesting(false)

                    Button {
                        downloadManager.togglePause(book.id)
                    } label: {
                        Image(systemName: isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: compact ? 12 : 16))
                            .foregroundStyle(settings.theme.accent)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel(isPaused ? "继续下载《\(book.title)》" : "暂停下载《\(book.title)》")
                }
                .padding(.horizontal, compact ? 3 : 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(settings.theme.background.opacity(0.82))
                        .allowsHitTesting(false)
                )

                Spacer(minLength: 0)

                // 下载进度：比阅读细线更粗、用主题强调色，并带百分比文字，和阅读进度区分
                VStack(spacing: 1) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(settings.theme.secondary.opacity(0.30))
                            Capsule()
                                .fill(settings.theme.accent)
                                .frame(width: geo.size.width * CGFloat(progress))
                        }
                    }
                    .frame(height: compact ? 4 : 6)
                    if !compact {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 8, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(settings.theme.foreground)
                    }
                }
                .allowsHitTesting(false)
            }
            .padding(compact ? 2 : 5)
        }
    }

    // MARK: - 漫画缓存 / 本地导入

    /// 漫画缓存进度：盖在封面上显示「缓存 x/y 话」。
    /// 和文字书的下载层分开画：那边按「章」统计、带暂停按钮，这边是整本批量缓存，
    /// 中途只能整体停，交互口径不一样。
    @ViewBuilder
    private func comicDownloadLayer(for book: Book, compact: Bool = false) -> some View {
        if book.isComic, let task = comicDownloads.task(for: book.id), task.isActive {
            ZStack {
                Color.black.opacity(0.42)
                    .allowsHitTesting(false)
                VStack(spacing: 3) {
                    Spacer(minLength: 0)
                    Text(task.status == .queued ? "排队中" : "缓存 \(task.completed)/\(task.total)")
                        .font(.system(size: compact ? 7 : 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(.black.opacity(0.45)))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.28))
                            Capsule()
                                .fill(.white)
                                .frame(width: max(0, geo.size.width * task.progress))
                        }
                    }
                    .frame(height: compact ? 3 : 4)
                }
                .padding(compact ? 3 : 6)
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func cacheAll(_ book: Book) {
        guard let meta = store.comicMeta(for: book.id),
              let source = SourceStore.shared.source(meta.sourceID) else { return }
        comicDownloads.start(book: book, source: source)
    }

    private func importComic(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            do {
                _ = try store.importComic(
                    images: urls,
                    title: urls.first?.deletingPathExtension().lastPathComponent ?? "本地漫画"
                )
                shelf = .comic
            } catch {
                store.lastError = error.localizedDescription
            }
        case .failure(let error):
            store.lastError = "无法读取图片：\(error.localizedDescription)"
        }
    }

    // MARK: - 长按菜单

    /// 手动核对更新。
    /// 本地已知有缺口（`missingChapters > 0`）就不必再等一次目录请求，直接接着下；
    /// 否则回源查一次，有新章就自动排进队列 —— 全本也只多这一次请求。
    @MainActor
    private func checkUpdates(for book: Book) {
        let hasActive = downloadManager.task(forBookID: book.id)?.isActive == true
        guard !hasActive else { return }
        if book.missingChapters > 0 {
            downloadManager.continueDownload(book.id)
            return
        }
        checkingBookID = book.id
        Task { @MainActor in
            let added = await downloadManager.checkForUpdates(bookID: book.id)
            checkingBookID = nil
            let total = store.book(book.id)?.chapterCount ?? book.chapterCount
            updateNotice = added > 0
                ? "发现 \(added) 章新内容，已加入下载队列。"
                : "已是最新（共 \(total) 章）。"
            showUpdateNotice = true
        }
    }

    @ViewBuilder
    private func contextMenuItems(for book: Book) -> some View {
        if book.isComic {
            Button {
                cacheAll(book)
            } label: {
                Label("缓存全部", systemImage: "arrow.down.circle")
            }
        } else {
            Button {
                onListenBook(book)
            } label: {
                Label("听书", systemImage: "headphones")
            }
            // 网络书：手动回源核对一次目录。有缺口就直接接着下，
            // 没有缺口才发一次请求；全本也不会再提示「未下完」。
            if book.remoteURL != nil {
                Button {
                    checkUpdates(for: book)
                } label: {
                    Label(
                        book.missingChapters > 0 ? "继续下载还差 \(book.missingChapters) 章" : "检查更新",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(checkingBookID == book.id)
            }
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

// MARK: - 漫画书架封面

/// 漫画封面：优先用本机第一张已下载的图，没有就退回渐变 + 书名。
///
/// 不用远程封面：漫画书架可能长期离线用，为了封面每次进 App 都发请求很浪费；
/// 而且缓存过的漫画迟早有本地图，两套来源会让封面闪一下再换。
// MARK: - 漫画封面

/// 书架当前分类的跨视图标记。
///
/// 只有一件事需要它：听书悬浮球挂在 `ContentView` 根部（切标签也不能消失），
/// 但漫画书架里那个「听」没有意义。与其把书架状态提升到根视图再逐层传，
/// 不如让书架把「现在是不是漫画分类」写进这个单例，根部按需隐藏。
@MainActor
final class ShelfMode: ObservableObject {
    static let shared = ShelfMode()
    @Published var isComic = false
    private init() {}
}

private struct ComicShelfCover: View {
    let book: Book
    let theme: ReadingTheme
    var showsBadges: Bool = true
    var showsTitle: Bool = true

    @State private var image: UIImage?
    /// 已缓存话数 / 总话数。nil 表示还没读出来或这本没有目录。
    @State private var cacheCount: (have: Int, total: Int)?

    var body: some View {
        let hue = min(1, max(0, book.coverHue))
        let progress = min(1, max(0, book.progress))

        return ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.48, brightness: 0.68),
                    Color(hue: hue, saturation: 0.62, brightness: 0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if let image {
                // 必须显式约束到容器尺寸：`scaledToFill` 会把 ZStack 撑得比卡片大，
                // 外层 clipShape 一裁，角落上的角标就跟着被切掉一半。
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                VStack(spacing: 3) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                    if showsTitle {
                        Text(book.title)
                            .font(.system(size: 10, weight: .bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .padding(6)
            }

            if showsBadges {
                VStack {
                    HStack(alignment: .top, spacing: 3) {
                        if book.isPinned { cornerBadge(systemName: "pin.fill", rotation: -25) }
                        Spacer(minLength: 0)
                        // 已缓存话数：下过才显示。放右上角和「已读」勾同排，
                        // 不和封面底部的书名抢位置
                        if let cacheCount, cacheCount.have > 0 {
                            HStack(spacing: 1.5) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 7, weight: .bold))
                                Text("\(cacheCount.have)/\(cacheCount.total)")
                                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                        }
                        if book.isFinished { cornerBadge(systemName: "checkmark", rotation: 0) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(5)
            }

            // 阅读进度：贴底细线，和文字书保持一致
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.20))
                        if progress > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: geo.size.width * CGFloat(progress))
                        }
                    }
                }
                .frame(height: 2.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
        // fileSize 变了说明新下了图，封面可能从占位变成实图，重新取一次
        .task(id: "\(book.id)|\(book.fileSize)") {
            guard let url = LibraryStore.shared.comicCoverURL(for: book) else { return }
            let thumb = await Task.detached(priority: .utility) {
                ComicCoverThumbnail.load(url: url, maxPixel: 360)
            }.value
            if !Task.isCancelled { image = thumb }
            // 顺带读一下缓存进度。meta.json 只有几 KB，一屏十几本也就十几 KB，
            // 比让用户点进去才知道「这本下没下过」划算。
            let cached = await Task.detached(priority: .utility) { () -> (have: Int, total: Int)? in
                guard let meta = LibraryStore.shared.comicMeta(for: book.id),
                      !meta.chapters.isEmpty else { return nil }
                return (meta.downloadedChapters, meta.chapters.count)
            }.value
            if !Task.isCancelled { cacheCount = cached }
        }
    }

    private func cornerBadge(systemName: String, rotation: Double) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(rotation))
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.black.opacity(0.35)))
    }
}

/// 书架封面只需要几十像素高，整页图直接解码会白白吃掉几十 MB 内存。
/// 用 ImageIO 的缩略图接口按目标尺寸解码，代价只有原图的百分之几。
private enum ComicCoverThumbnail {
    static func load(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
