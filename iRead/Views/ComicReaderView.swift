import SwiftUI

/// 漫画阅读器：整话图片自上而下连续滚动。
///
/// 为什么默认竖滑而不是左右翻页：中文漫画里条漫占大半，条漫本来就是一条长图，
/// 左右翻会把一条切成几十屏、翻得人晕；页漫竖滑也不会丢内容，只是少一点翻页感。
/// 所以先把竖滑做到位，翻页模式留待后续按用户反馈再加。
///
/// 背景固定纯黑，不跟阅读主题走：漫画是整屏彩图，浅色边框会一直抢注意力。
struct ComicReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings

    let bookID: String
    private let startChapter: Int?

    @State private var chapterIndex: Int
    @State private var meta: ComicMeta?
    @State private var pages: [ComicPage] = []
    @State private var loading = false
    @State private var statusText: String?
    @State private var errorMessage: String?
    @State private var showBars = true
    @State private var showCatalog = false
    @State private var loadTask: Task<Void, Never>?

    init(bookID: String, startChapter: Int? = nil) {
        self.bookID = bookID
        self.startChapter = startChapter
        _chapterIndex = State(initialValue: startChapter ?? 0)
    }

    private var book: Book? { store.book(bookID) }
    private var chapters: [ComicChapter] { meta?.chapters ?? [] }
    private var currentChapter: ComicChapter? {
        chapters.first { $0.index == chapterIndex }
    }
    private var hasPrev: Bool { chapters.contains { $0.index < chapterIndex } }
    private var hasNext: Bool { chapters.contains { $0.index > chapterIndex } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                        pageView(page)
                    }
                    chapterFooter
                }
                .padding(.bottom, showBars ? 92 : 24)
            }
            .contentShape(Rectangle())
            // 点画面任意位置收起/展开工具栏；只认单击，不然和滚动冲突
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { showBars.toggle() } }

            if loading { loadingOverlay }
            if let errorMessage { errorOverlay(errorMessage) }

            VStack(spacing: 0) {
                if showBars { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer(minLength: 0)
                if showBars { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!showBars)
        .sheet(isPresented: $showCatalog) { catalogSheet }
        .onAppear { bootstrap() }
        .onDisappear { saveProgress() }
    }

    // MARK: - 页面

    @ViewBuilder
    private func pageView(_ page: ComicPage) -> some View {
        if let url = store.comicPageURL(bookID: bookID, chapterIndex: chapterIndex, file: page.file) {
            ComicPageImage(url: url, aspect: page.aspectRatio)
        }
    }

    private var chapterFooter: some View {
        VStack(spacing: 12) {
            if !pages.isEmpty {
                Text("— \(currentChapter?.shortTitle ?? "本话") 完 —")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            HStack(spacing: 12) {
                if hasPrev { chapterButton("上一话", systemName: "chevron.left") { step(-1) } }
                if hasNext { chapterButton("下一话", systemName: "chevron.right", trailing: true) { step(1) } }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func chapterButton(
        _ title: String,
        systemName: String,
        trailing: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if !trailing { Image(systemName: systemName).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .medium))
                if trailing { Image(systemName: systemName).font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(book?.title ?? "漫画")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(currentChapter?.shortTitle ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                showCatalog = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("章节目录")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // 不做半透明：漫画页经常是白底，遮罩压上去会变成一条发灰的横带，
        // 白字直接糊在浅色上。索性接近不透明，保证任何画面上都读得清。
        .background(Color.black.opacity(0.94))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(hasPrev ? .white : .white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!hasPrev)

            VStack(spacing: 2) {
                Text("共 \(pages.count) 页")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                if let statusText {
                    Text(statusText)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                step(1)
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(hasNext ? .white : .white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!hasNext)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .background(Color.black.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text(statusText ?? "正在加载…")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.55)))
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("重试") { load(chapterIndex) }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Capsule().fill(.white))
                .buttonStyle(.plain)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.7)))
    }

    // MARK: - 目录

    private var catalogSheet: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chapters) { chapter in
                            Button {
                                showCatalog = false
                                load(chapter.index)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(chapter.shortTitle)
                                        .font(.system(size: 13, weight: chapter.index == chapterIndex ? .semibold : .regular))
                                        .foregroundStyle(chapter.index == chapterIndex ? .white : .white.opacity(0.7))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if chapter.index == chapterIndex {
                                        Text("在读")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(.white))
                                    } else if chapter.isDownloaded {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("章节目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showCatalog = false }
                        .foregroundStyle(.white)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    // MARK: - 加载

    private func bootstrap() {
        meta = store.comicMeta(for: bookID)
        if let startChapter {
            chapterIndex = startChapter
        } else if let book {
            chapterIndex = book.lastChapterIndex
        }
        load(chapterIndex)
    }

    private func load(_ index: Int) {
        guard let book, let meta else {
            errorMessage = "这本漫画的数据不完整"
            return
        }
        loadTask?.cancel()
        guard meta.chapters.contains(where: { $0.index == index }) else { return }
        saveProgress()
        chapterIndex = index
        pages = []
        errorMessage = nil
        loading = true
        statusText = "正在加载…"

        let source = SourceStore.shared.source(meta.sourceID)
        loadTask = Task {
            do {
                let result = try await ComicDownloadManager.shared.ensureChapter(
                    book: book,
                    chapterIndex: index,
                    source: source,
                    progress: { text in statusText = text }
                )
                guard !Task.isCancelled, chapterIndex == index else { return }
                pages = result.filter { $0.isLocal }
                self.meta = store.comicMeta(for: bookID)
                loading = false
                statusText = nil
                saveProgress()
            } catch {
                guard !Task.isCancelled else { return }
                loading = false
                statusText = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func step(_ delta: Int) {
        let candidates = chapters.map(\.index).sorted()
        guard let position = candidates.firstIndex(of: chapterIndex) else { return }
        let next = position + delta
        guard candidates.indices.contains(next) else { return }
        load(candidates[next])
    }

    private func saveProgress() {
        guard let meta, !meta.chapters.isEmpty else { return }
        let total = Double(meta.chapters.count)
        let ratio = (Double(chapterIndex) + 1) / total
        store.updateReading(
            bookID: bookID,
            chapterIndex: chapterIndex,
            progress: min(1, max(0, ratio)),
            scrollRatio: nil
        )
    }
}

// MARK: - 单页

/// 一张漫画图。用 `UIImage(contentsOfFile:)` 懒解码：SwiftUI 真正绘制时才解像素，
/// 滚出屏幕的页会被回收，不用自己写缓存池。
private struct ComicPageImage: View {
    let url: URL
    let aspect: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color(white: 0.12)
                    .aspectRatio(aspect > 0 ? aspect : 0.68, contentMode: .fit)
                    .overlay(
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.6))
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: url) {
            // 解码放到后台，别在大图滚动时卡住主线程
            let loaded = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)
            }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}
