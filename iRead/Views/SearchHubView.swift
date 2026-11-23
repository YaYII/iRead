import SwiftUI

/// 统一搜索入口。
///
/// 以前「搜书」「漫画」各占一个 Tab，再加音乐、动漫、视频就没地方放了。
/// 现在只留一个搜索 Tab，五个频道左右滑：顶部是频道条，下面还是各自的搜索页。
/// 每个频道保留自己的输入框 —— 书名人名、图片、曲风、片名本来就不是一套检索。
struct SearchHubView: View {
    @ObservedObject private var settings = ReaderSettings.shared

    @State private var category: SearchCategory

    init(initial: SearchCategory = .book) {
        _category = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            channelBar

            TabView(selection: $category) {
                NovelSearchView()
                    .tag(SearchCategory.book)

                ComicSearchView()
                    .tag(SearchCategory.comic)

                MusicSearchView()
                    .tag(SearchCategory.music)

                VideoSearchView(kind: .anime)
                    .tag(SearchCategory.anime)

                VideoSearchView(kind: .video)
                    .tag(SearchCategory.video)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(settings.theme.background)
        .preferredColorScheme(settings.theme.colorScheme)
        .onAppear(perform: applyDebugArguments)
        .onReceive(NotificationCenter.default.publisher(for: .iReadSwitchSearchCategory)) { note in
            guard let raw = note.object as? String,
                  let target = SearchCategory(rawValue: raw) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { category = target }
        }
    }

    // MARK: - 频道条

    private var channelBar: some View {
        HStack(spacing: 4) {
            ForEach(SearchCategory.allCases) { item in
                let selected = category == item
                Button {
                    guard category != item else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { category = item }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(item.shortTitle)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? .white : settings.theme.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule().fill(selected ? settings.theme.accent : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(settings.theme.secondary.opacity(0.13)))
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func applyDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--search-category"), index + 1 < args.count,
           let target = SearchCategory(rawValue: args[index + 1]) {
            category = target
        }
        if args.contains("--search-music") { category = .music }
        if args.contains("--search-anime") { category = .anime }
        if args.contains("--search-video") { category = .video }
        if args.contains(where: { $0.hasPrefix("--comic-search") }) { category = .comic }
    }
}

extension Notification.Name {
    /// 书架点「音乐 / 视频」分类的放大镜时，请求搜索页切到对应频道。
    /// object 传 `SearchCategory.rawValue`。
    static let iReadSwitchSearchCategory = Notification.Name("iReadSwitchSearchCategory")
}
