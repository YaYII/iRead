import SwiftUI
import UniformTypeIdentifiers

/// 漫画搜索页：和「搜书」完全独立的模块，只遍历漫画源。
///
/// 为什么不做成搜书页里的一个开关：两个模块的输入（书名 / 漫画名）、
/// 输出（文字书 / 图片）、后续动作（进阅读器还是进漫画详情）都不一样，
/// 混在一个页面里会让每次搜索都白跑一半书源。
struct ComicSearchView: View {
    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var sourceStore = SourceStore.shared

    @State private var keyword = ""
    @State private var isSearching = false
    @State private var results: [SearchResult] = []
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var selected: SearchResult?
    @State private var showSourceManager = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showImporter = false
    /// 搜索框焦点：点别处收键盘，不用去够键盘上的「搜索」
    @FocusState private var searchFocused: Bool

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
        count: 3
    )

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .simultaneousGesture(dismissOnTap)
                searchBar
                content
                    .simultaneousGesture(dismissOnTap)
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .sheet(isPresented: $showSourceManager) {
            SourceManagerView(media: "comic")
        }
        .sheet(item: $selected) { result in
            ComicDetailView(result: result)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            importLocal(result)
        }
        .onAppear {
            // 仅供自动化自测：--comic-search 进击（或 --comic-search=进击）启动即搜
            let args = ProcessInfo.processInfo.arguments
            var query: String?
            if let i = args.firstIndex(of: "--comic-search"), i + 1 < args.count {
                query = args[i + 1]
            } else if let inline = args.first(where: { $0.hasPrefix("--comic-search=") }) {
                query = String(inline.dropFirst("--comic-search=".count))
            }
            if let query, !query.isEmpty {
                keyword = query
                performSearch()
            }
        }
    }

    // MARK: - 顶部

    /// 点空白处收键盘。用 `simultaneousGesture` 而不是 `onTapGesture`：
    /// 后者会把封面卡片自己的点击吃掉。
    private var dismissOnTap: some Gesture {
        TapGesture().onEnded { searchFocused = false }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("漫画")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(settings.theme.foreground)
                Text("从漫画源找作品，按话下载到本机")
                    .font(.system(size: 10))
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer(minLength: 4)
            Button {
                showImporter = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(settings.theme.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导入本地漫画")

            Button {
                showSourceManager = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(settings.theme.accent)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("漫画书源管理")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(settings.theme.secondary)
            TextField("搜索漫画名或作者", text: $keyword)
                .focused($searchFocused)
                .font(.system(size: 13))
                .foregroundStyle(settings.theme.foreground)
                .tint(settings.theme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { performSearch() }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(settings.theme.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                performSearch()
            } label: {
                Text("搜索")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(settings.theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.theme.secondary.opacity(0.14))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isSearching && results.isEmpty {
            loadingState
        } else if !results.isEmpty {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(results) { result in
                        resultCard(result)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.immediately)
        } else if let error = errorMessage {
            stateView(systemName: "exclamationmark.triangle", title: "搜索失败", message: error)
        } else if hasSearched {
            stateView(
                systemName: "rectangle.stack.badge.questionmark",
                title: "没找到这本漫画",
                message: "换个名字试试，或到漫画书源管理里启用更多源。\n也可以直接把本地图片导入书架。"
            )
        } else {
            introState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(settings.theme.accent)
            Text("正在搜索漫画源…")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var introState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(settings.theme.secondary)
            Text("找一本漫画")
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            Text("漫画和电子书是分开的两个书架。\n搜到的漫画按「话」缓存到本机，离线也能看。")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
                .multilineTextAlignment(.center)
            if sourceStore.enabledComicSources.isEmpty {
                Text("当前没有启用的漫画源")
                    .font(.caption)
                    .foregroundStyle(settings.theme.accent)
            }
            Button {
                showImporter = true
            } label: {
                Text("导入本地图片")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(settings.theme.accent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private func stateView(systemName: String, title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(settings.theme.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - 结果卡片

    private func resultCard(_ result: SearchResult) -> some View {
        Button {
            selected = result
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ComicCoverImage(
                    url: result.coverURL.flatMap(URL.init(string:)),
                    title: result.title,
                    hue: Double(UInt(bitPattern: result.title.hashValue) % 8) / 8.0
                )
                .aspectRatio(3.0 / 4.0, contentMode: .fit)

                Text(result.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(settings.theme.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(result.author.isEmpty ? result.sourceName : result.author)
                    .font(.system(size: 10))
                    .foregroundStyle(settings.theme.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 行为

    private func performSearch() {
        // 开搜就收键盘：封面网格要占满屏幕
        searchFocused = false
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "请输入漫画名或作者"
            hasSearched = false
            results = []
            return
        }
        let sources = sourceStore.enabledComicSources
        guard !sources.isEmpty else {
            hasSearched = true
            results = []
            errorMessage = "没有启用的漫画源，请到漫画书源管理里启用。"
            return
        }

        searchTask?.cancel()
        isSearching = true
        hasSearched = true
        results = []
        errorMessage = nil

        let query = trimmed
        searchTask = Task {
            var buckets: [String: [SearchResult]] = [:]
            var failures: [String] = []
            await withTaskGroup(of: (String, Result<[SearchResult], Error>).self) { group in
                for source in sources {
                    group.addTask {
                        do {
                            let hits = try await Self.withTimeout(seconds: 15) {
                                try await ComicFetcher.search(source: source, keyword: query)
                            }
                            return (source.id, .success(hits))
                        } catch {
                            return (source.id, .failure(error))
                        }
                    }
                }
                for await (id, outcome) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    switch outcome {
                    case .success(let hits): buckets[id] = hits
                    case .failure(let error): failures.append("\(id)：\(error.localizedDescription)")
                    }
                    // 谁先回来谁先上屏：漫画站的封面图慢，等全部源齐了再显示体感很差
                    results = sources.flatMap { buckets[$0.id] ?? [] }
                }
            }
            guard !Task.isCancelled else { return }
            isSearching = false
            if results.isEmpty {
                errorMessage = failures.isEmpty
                    ? "没有找到匹配的漫画，换个关键词试试。"
                    : "搜索失败：\(failures.prefix(2).joined(separator: "；"))"
            } else if ProcessInfo.processInfo.arguments.contains("--comic-open-first") {
                // 仅供自动化自测：搜完直接打开第一条
                selected = results.first
            }
        }
    }

    private func importLocal(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            do {
                _ = try LibraryStore.shared.importComic(
                    images: urls,
                    title: urls.first?.deletingPathExtension().lastPathComponent ?? "本地漫画"
                )
                // 导入完成直接回书架：漫画书架会多一本
                NotificationCenter.default.post(name: Notification.Name("iReadOpenBookshelf"), object: nil)
                NotificationCenter.default.post(name: Notification.Name("iReadSwitchToComicShelf"), object: nil)
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = "无法读取图片：\(error.localizedDescription)"
        }
    }

    private struct SearchTimeout: Error {}

    private static func withTimeout<T>(
        seconds: Double,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SearchTimeout()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw SearchTimeout() }
            return value
        }
    }
}

// MARK: - 封面

/// 漫画封面：远程图 + 加载中/失败的渐变占位。
/// 漫画封面是竖版海报，比例固定 3:4 才不会有的一行高一行的矮。
struct ComicCoverImage: View {
    let url: URL?
    let title: String
    var hue: Double = 0.5

    @State private var failed = false

    var body: some View {
        ZStack {
            if let url, !failed {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                            .onAppear { failed = true }
                    default:
                        placeholder
                            .overlay(ProgressView().controlSize(.small).tint(.white.opacity(0.8)))
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.42, brightness: 0.66),
                    Color(hue: hue, saturation: 0.55, brightness: 0.36)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white.opacity(0.92))
                .padding(8)
        }
    }
}
