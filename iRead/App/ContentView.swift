import SwiftUI

/// 录演示视频用的步进间隔。
///
/// 自测参数原本是「0.4 秒后自动打开」，跑起来一闪而过，录屏根本看不清。
/// `--demo-pace 4` 把每一步拉到 4 秒，让界面停够时间再走下一步；
/// 不传这个参数时行为完全不变。
enum Demo {
    static var pace: TimeInterval {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--demo-pace"), index + 1 < args.count,
              let value = Double(args[index + 1]), value > 0 else { return 0 }
        return value
    }

    /// 有 pace 就按 pace 走，没有就用原来的默认延迟
    static func step(_ base: TimeInterval) -> TimeInterval {
        pace > 0 ? pace : base
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    /// 听书是全局组件，书架只负责发起/收起，不承载播放状态
    @ObservedObject private var listening = ListeningCenter.shared
    /// 音乐也是全局播放：切标签、进阅读器都不该停
    @ObservedObject private var music = MusicPlayer.shared
    /// 书架当前分类：只有「电子书」下才有可听的当前书
    @ObservedObject private var shelfMode = ShelfMode.shared

    @State private var selection = 0
    @State private var activeBook: Book?
    @State private var showPlayer = false
    @State private var showWiFiTransfer = false
    @State private var showDownloads = false
    @State private var showSettings = false

    /// 「听」球只在书架（电子书分类）出现。
    /// 搜索页有自己的音乐/视频播放器，漫画、音乐、视频分类没有「当前在听的书」，
    /// 写作页是稿纸，这几处留着球只会点开一个空界面。
    private var showsListeningDock: Bool {
        guard selection == 0 else { return false }
        return shelfMode.isEbook
    }

    var body: some View {
        TabView(selection: $selection) {
            BookshelfView(
                onOpenBook: { book in
                    activeBook = book
                },
                onListenBook: { book in
                    // 只把书装进听书组件并打开界面，不在这里出声
                    listening.prepare(bookID: book.id)
                    showPlayer = true
                },
                onOpenSettings: {
                    showSettings = true
                },
                onOpenSearch: { category in
                    selection = 1
                    // 搜索页按频道懒加载，先切标签再告诉它落到哪一格
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .iReadSwitchSearchCategory,
                            object: category.rawValue
                        )
                    }
                }
            )
            .tabItem {
                Label("书架", systemImage: "books.vertical")
            }
            .tag(0)

            // 统一搜索：书籍 / 漫画 / 音乐 / 动漫 / 视频五个频道左右滑。
            // 以前「搜书」「漫画」各占一个 Tab，再加音乐视频就放不下了。
            ZStack(alignment: .bottomTrailing) {
                SearchHubView()
                if !NovelDownloadManager.shared.tasks.isEmpty {
                    Button {
                        showDownloads = true
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(settings.theme.accent))
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.bottom, 84)
                }
            }
            .tabItem {
                Label("搜索", systemImage: "magnifyingglass")
            }
            .tag(1)

            // 写作：和「看」分开的第三个空间。书架上的是别人写的成品，
            // 这里是自己（和 AI）写的草稿，两边不共用表、不互相覆盖。
            WritingHomeView()
                .tabItem {
                    Label("写作", systemImage: "square.and.pencil")
                }
                .tag(2)
        }
        .tint(settings.theme.accent)
        .preferredColorScheme(settings.theme.colorScheme)
        // 音乐条优先于「听」球：两者不会同时出声，开音乐时朗读已停。
        // 用 overlay 而非 safeAreaInset —— 悬浮条不该把书架列表往上顶出一块空白。
        .overlay(alignment: .bottom) {
            if music.isActive {
                MusicMiniBar()
                    .environmentObject(settings)
                    .padding(.bottom, 62)
            } else if showsListeningDock {
                ListeningFloatingDock(onOpen: openPlayer, bottomInset: 72)
                    .environmentObject(settings)
            }
        }
        .fullScreenCover(item: $activeBook) { book in
            // 漫画走图片阅读器，文字书走排版阅读器：两者的「一页」不是一个概念
            if book.isComic {
                ComicReaderView(bookID: book.id)
                    .environmentObject(store)
                    .environmentObject(settings)
            } else {
                ReaderView(bookID: book.id)
                    .environmentObject(store)
                    .environmentObject(settings)
            }
        }
        .sheet(isPresented: $showPlayer) {
            ListeningPlayerView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        // 音乐播放器挂根视图：搜索结果、书架、迷你条都只是把 wantsPlayerSheet 置 true
        .sheet(isPresented: $music.wantsPlayerSheet) {
            MusicPlayerView()
        }
        .sheet(isPresented: $showWiFiTransfer) {
            WiFiTransferView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(presentedAsSheet: true)
                .environmentObject(store)
                .environmentObject(settings)
        }
        // 下载任务页：搜书页那颗下载胶囊点开的就这一个入口。
        // 之前 showDownloads 只被赋值、没有对应的 sheet，点了没反应（页面写了但没接上）。
        .sheet(isPresented: $showDownloads) {
            DownloadTasksView()
                .environmentObject(settings)
        }
        .onAppear {
            // 仅供自动化预览/截图使用，正常启动不会命中
            let args = ProcessInfo.processInfo.arguments
            // AI 服务配置：截图/自测时不必进设置页手打（模拟器没法输入）
            applyAIDebugArguments(args)
            // --bookdash-selftest：绘本链路（书目→详情→内页→下第一张图）自检
            if args.contains("--bookdash-selftest") {
                Task { await PictureBookSource.selfTest() }
            }
            // --writing：直接切到写作页
            if args.contains("--writing") { selection = 2 }
            // --night：截图时强制夜间主题（任何入口都生效）
            if args.contains("--night") { settings.theme = .night }
            // --speed 1.7：截图时指定语速（0.4～4.0）
            if let i = args.firstIndex(of: "--speed"), i + 1 < args.count,
               let v = Double(args[i + 1]) {
                settings.speechSpeed = min(max(v, 0.4), 4.0)
            }
            // --theme paper|sepia|green|night：截图时指定主题
            if let i = args.firstIndex(of: "--theme"), i + 1 < args.count,
               let t = ReadingTheme(rawValue: args[i + 1]) {
                settings.theme = t
            }
            // --debug-wifi：直接打开 WiFi 传书页（自测/自动化用）
            if args.contains("--debug-wifi") {
                showWiFiTransfer = true
            }
            // --debug-search：直接切到搜索页（默认书籍频道）
            if args.contains("--debug-search") {
                selection = 1
            }
            // --search-music / --search-anime / --search-video：直接落到对应频道
            if args.contains("--search-music") || args.contains("--search-anime")
                || args.contains("--search-video") || args.contains("--search-category") {
                selection = 1
            }
            // --debug-downloads：直接打开下载任务页（自测/截图用）
            if args.contains("--debug-downloads") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showDownloads = true
                }
            }
            // --comic-search=关键字：切到搜索页的漫画频道并自动搜索
            if args.contains(where: { $0.hasPrefix("--comic-search") }) {
                selection = 1
            }
            // --debug-comic：直接打开书架里第一本漫画（自测/截图用）
            if args.contains("--debug-comic") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    activeBook = store.books.first { $0.isComic }
                }
            }
            // --voice cantonese / male / female：截图时指定音色档位
            if let i = args.firstIndex(of: "--voice"), i + 1 < args.count {
                switch args[i + 1] {
                case "female": settings.voiceProfile = .neuralFemale
                case "male": settings.voiceProfile = .neuralMale
                case "cantonese": settings.voiceProfile = .cantonese
                default: break
                }
            }
            // 仅供自测：指定要听第几本（不打开阅读页），配合 --debug-reader 验证「听 A 看 B」
            if let i = args.firstIndex(of: "--listen-index"), i + 1 < args.count,
               let index = Int(args[i + 1]), store.books.indices.contains(index) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    ListeningCenter.shared.resume(bookID: store.books[index].id)
                }
            }
            if args.contains("--debug-player") {
                // 仅供自测：预选书并打开播放器（待播放，不出声）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let book = store.books.first {
                        listening.prepare(bookID: book.id)
                    }
                    showPlayer = true
                }
            } else if args.contains("--debug-reader") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    activeBook = store.books.first
                }
                // 仅供自测：自动退出阅读页，验证听书仍在继续
                if args.contains("--auto-exit-reader") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        activeBook = nil
                    }
                }
            } else if args.contains("--debug-settings") {
                // 仅供自测：设置已改为书架齿轮弹出的 sheet
                showSettings = true
            }
            // 仅供自测：模拟「打开播放器 → 点边听边读」的真实时序
            if args.contains("--debug-player-follow") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let book = store.books.first else { return }
                    listening.resume(bookID: book.id)
                    showPlayer = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        showPlayer = false
                        listening.requestFollowAlong(bookID: book.id)
                    }
                }
            }
            // 仅供自测：阅读器**已经开着**时点边听边读，验证不重新唤起阅读页
            if args.contains("--debug-follow-existing") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    activeBook = store.books.first
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    guard let book = store.books.first else { return }
                    listening.resume(bookID: book.id)
                    showPlayer = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    guard let book = store.books.first else { return }
                    showPlayer = false
                    listening.requestFollowAlong(bookID: book.id)
                }
            }
            // 仅供自测：开播后直接从听书组件打开阅读页跟读
            if args.contains("--debug-follow") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let book = store.books.first else { return }
                    listening.resume(bookID: book.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        listening.requestFollowAlong(bookID: book.id)
                    }
                }
            }
        }
        .onChange(of: listening.readerRequest) { _, id in
            guard let id, let book = store.book(id) else { return }
            _ = listening.consumeReaderRequest()
            openReaderFollowing(book: book)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("iReadOpenBookshelf"))) { _ in
            // 详情页点下载后立即跳到书架（书已进书架，可边下边读）
            selection = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .iReadOpenWriting)) { _ in
            // 阅读页把 AI 生成的内容存进写作后点「去写作看」：
            // 先收拾掉阅读页，再切标签（顺序反了会看到标签切换被盖在阅读页下面）
            activeBook = nil
            selection = 2
        }
        .onReceive(NotificationCenter.default.publisher(for: .iReadOpenSettings)) { _ in
            // 写作页的「AI 还没配置」引导：直接弹设置
            showSettings = true
        }
    }

    /// 「边听边读」：只收起听书界面，**绝不重新唤起阅读器**。
    /// - 阅读器已经开着 → 什么都不做，现有阅读页通过 `isFollowAlong` 原地切到跟读
    ///   （听 A 看 B 时当前页不是 A，就保持现状，不抢用户正在读的书）
    /// - 还在书架 / 设置页 → 才把正在听的那本打开成阅读页
    private func openReaderFollowing(book: Book) {
        let alreadyReading = activeBook != nil
        showPlayer = false
        guard !alreadyReading else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            activeBook = book
        }
    }

    /// 悬浮「听」球的唯一入口：只打开听书界面，播放由界面里的按钮决定。
    /// 没有选中过书时先预选一本，让界面有东西可显示（依然不发声）。
    private func openPlayer() {
        if !listening.isPlayingSomething, let book = store.books.first {
            listening.prepare(bookID: book.id)
        }
        showPlayer = true
    }

    /// 仅供自测：用启动参数配好 AI 服务，省掉在模拟器里手打（本来也打不了字）
    private func applyAIDebugArguments(_ args: [String]) {
        let ai = AISettings.shared
        if args.contains("--ai-reset") {
            ai.setAPIKey("")
            ai.baseURL = ""
            ai.model = ""
        }
        // --ai-provider opencode-go：直接切到某个预设（在 --ai-base/--ai-model 之前，
        // 让后面两项仍能覆盖，方便测「预设 + 换模型」的组合）
        if let index = args.firstIndex(of: "--ai-provider"), index + 1 < args.count,
           let provider = AIProvider.all.first(where: { $0.id == args[index + 1] }) {
            ai.apply(provider)
        }
        if let index = args.firstIndex(of: "--ai-base"), index + 1 < args.count {
            ai.baseURL = args[index + 1]
        }
        if let index = args.firstIndex(of: "--ai-model"), index + 1 < args.count {
            ai.model = args[index + 1]
        }
        if let index = args.firstIndex(of: "--ai-key"), index + 1 < args.count {
            ai.setAPIKey(args[index + 1])
        }
        // --ai-ping：真发一次最短请求，把结果打到控制台。
        // 排查「Key 填了但生成不动」时，先看这一行比翻界面快。
        if args.contains("--ai-ping") {
            Task {
                do {
                    let reply = try await AIClient.shared.ping()
                    print("[iRead] ai-ping ok -> \(reply.prefix(40))")
                } catch {
                    print("[iRead] ai-ping failed -> \(error.localizedDescription)")
                }
            }
        }
    }
}

extension Notification.Name {
    /// 阅读页存完 AI 稿子后，请求切到「写作」标签
    static let iReadOpenWriting = Notification.Name("iReadOpenWriting")
    /// 写作页请求打开全局设置（配置 AI 服务）
    static let iReadOpenSettings = Notification.Name("iReadOpenSettings")
}
