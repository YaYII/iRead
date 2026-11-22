import SwiftUI

/// 漫画详情：加载目录、入书架、按话缓存、进阅读器。
struct ComicDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var downloads = ComicDownloadManager.shared

    let result: SearchResult

    @State private var detail: NovelDetail?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var book: Book?
    @State private var meta: ComicMeta?
    @State private var openRequest: OpenRequest?
    @State private var showFullIntro = false

    private var source: NovelSource? { sourceStore.source(result.sourceID) }
    private var remoteKey: String { "\(result.sourceID)|\(result.detailURL)" }

    private let chapterColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8, alignment: .leading),
        count: 3
    )

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                navigationBar
                if loading {
                    loadingState
                } else if let detail {
                    content(detail)
                } else {
                    errorState
                }
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .fullScreenCover(item: $openRequest) { request in
            ComicReaderView(bookID: request.bookID, startChapter: request.chapter)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .onAppear { loadIfNeeded() }
        // 下载进度变化（每下完一话一次）后刷新缓存状态，书卡上的对勾才会及时出现
        .onReceive(downloads.$tasks) { _ in reloadMeta() }
    }

    // MARK: - 导航

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.theme.foreground)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(detail?.title ?? result.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(settings.theme.foreground)
                .lineLimit(1)
            Spacer()
            // 占位，保持标题居中
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    // MARK: - 内容

    private func content(_ detail: NovelDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary(detail)
                actions(detail)
                chapterSection(detail)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }

    private func summary(_ detail: NovelDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ComicCoverImage(
                    url: detail.coverURL.flatMap(URL.init(string:)),
                    title: detail.title,
                    hue: Double(UInt(bitPattern: detail.title.hashValue) % 8) / 8.0
                )
                .frame(width: 104, height: 138)

                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(settings.theme.foreground)
                        .lineLimit(3)
                    Text(detail.author.isEmpty ? "作者未知" : detail.author)
                        .font(.system(size: 12))
                        .foregroundStyle(settings.theme.secondary)
                    HStack(spacing: 6) {
                        Text(detail.sourceName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(settings.theme.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(settings.theme.secondary.opacity(0.14)))
                        Text("\(detail.chapters.count) 话")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(settings.theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(settings.theme.accent.opacity(0.12)))
                    }
                    if let meta {
                        Text(cacheSummary(meta))
                            .font(.system(size: 10))
                            .foregroundStyle(settings.theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }

            if !detail.intro.isEmpty {
                Text(detail.intro)
                    .font(.system(size: 12))
                    .foregroundStyle(settings.theme.secondary)
                    .lineLimit(showFullIntro ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { showFullIntro.toggle() } }
            }
        }
    }

    private func cacheSummary(_ meta: ComicMeta) -> String {
        if meta.downloadedChapters == 0 { return "尚未缓存" }
        return "已缓存 \(meta.downloadedChapters)/\(meta.chapters.count) 话 · \(meta.downloadedPages) 页"
    }

    private func actions(_ detail: NovelDetail) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    startReading(detail, chapter: detail.chapters.first?.index ?? 0)
                } label: {
                    Text("开始阅读")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(settings.theme.accent))
                }
                .buttonStyle(.plain)

                Button {
                    startDownload(detail)
                } label: {
                    Text(cacheButtonTitle(detail))
                        .font(.system(size: 14, weight: .semibold))
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

            if let task = book.flatMap({ downloads.task(for: $0.id) }), task.isActive {
                HStack(spacing: 8) {
                    ProgressView(value: task.progress)
                        .tint(settings.theme.accent)
                    Text("\(task.completed)/\(task.total) 话")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(settings.theme.secondary)
                    Button("停止") {
                        if let book { downloads.cancel(book.id) }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(settings.theme.secondary)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func cacheButtonTitle(_ detail: NovelDetail) -> String {
        if let task = book.flatMap({ downloads.task(for: $0.id) }), task.isActive {
            return "缓存中 \(Int(task.progress * 100))%"
        }
        return "缓存全部"
    }

    private func chapterSection(_ detail: NovelDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("章节目录")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(settings.theme.foreground)
                Spacer()
                if let book {
                    Text(readingPositionLabel(book))
                        .font(.system(size: 10))
                        .foregroundStyle(settings.theme.secondary)
                }
            }

            LazyVGrid(columns: chapterColumns, alignment: .leading, spacing: 8) {
                ForEach(detail.chapters) { chapter in
                    chapterChip(chapter, detail: detail)
                }
            }
        }
    }

    private func chapterChip(_ chapter: ChapterLink, detail: NovelDetail) -> some View {
        let cached = meta?.chapters.first { $0.index == chapter.index }
        let downloaded = cached?.isDownloaded ?? false
        let reading = book?.lastChapterIndex == chapter.index

        return Button {
            startReading(detail, chapter: chapter.index)
        } label: {
            HStack(spacing: 3) {
                Text(chapter.title)
                    .font(.system(size: 11, weight: reading ? .semibold : .regular))
                    .foregroundStyle(reading ? settings.theme.accent : settings.theme.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if downloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(settings.theme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(reading
                          ? settings.theme.accent.opacity(0.12)
                          : settings.theme.foreground.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    private func readingPositionLabel(_ book: Book) -> String {
        guard let meta, !meta.chapters.isEmpty else { return "" }
        let chapter = meta.chapters.first { $0.index == book.lastChapterIndex }
        return "读到 \(chapter?.shortTitle ?? "第 1 话")"
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(settings.theme.accent)
            Text("正在加载目录…")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(settings.theme.secondary)
            Text("目录加载失败")
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            Text(errorMessage ?? "请稍后重试，或换一个书源。")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") {
                loading = true
                errorMessage = nil
                loadIfNeeded(force: true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Capsule().fill(settings.theme.accent))
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 行为

    private func loadIfNeeded(force: Bool = false) {
        guard detail == nil || force else { return }
        guard let source else {
            loading = false
            errorMessage = "找不到这个书源，可能已经被删除。"
            return
        }
        loading = true
        Task {
            do {
                let loaded = try await ComicFetcher.detail(result: result, source: source)
                detail = loaded
                // 仅供自动化自测：--comic-read 加载完直接进第一话
                if ProcessInfo.processInfo.arguments.contains("--comic-read"), let first = loaded.chapters.first {
                    loading = false
                    startReading(loaded, chapter: first.index)
                    return
                }
                // 已经在书架里：直接用现成的目录，顺带把新章节补进来（连载漫画会更新）
                if let existing = store.comicBook(remoteKey: remoteKey) {
                    store.updateComicChapters(bookID: existing.id, chapters: loaded.chapters)
                    book = existing
                    reloadMeta()
                    loading = false
                    return
                }
                loading = false
            } catch {
                loading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reloadMeta() {
        guard let book else { return }
        meta = store.comicMeta(for: book.id)
    }

    @discardableResult
    private func ensureBook(_ detail: NovelDetail) -> Book? {
        if let existing = store.comicBook(remoteKey: remoteKey) {
            book = existing
            meta = store.comicMeta(for: existing.id)
            return existing
        }
        let created = store.createComicBook(
            title: detail.title,
            author: detail.author,
            sourceID: result.sourceID,
            remoteURL: result.detailURL,
            chapters: detail.chapters
        )
        book = created
        meta = store.comicMeta(for: created.id)
        return created
    }

    private func startReading(_ detail: NovelDetail, chapter: Int) {
        guard let book = ensureBook(detail) else { return }
        // 首次进入：目录里还没有页码，阅读器会自己拉这一话的图片清单再下载
        openRequest = OpenRequest(bookID: book.id, chapter: chapter)
    }

    private func startDownload(_ detail: NovelDetail) {
        guard let book = ensureBook(detail), let source else { return }
        downloads.start(book: book, source: source)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { reloadMeta() }
    }

    struct OpenRequest: Identifiable {
        let bookID: String
        let chapter: Int
        var id: String { "\(bookID)|\(chapter)" }
    }
}
