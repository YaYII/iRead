import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    /// 听书是全局组件，书架只负责发起/收起，不承载播放状态
    @ObservedObject private var listening = ListeningCenter.shared

    @State private var selection = 0
    @State private var activeBook: Book?
    @State private var showPlayer = false

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
                }
            )
            .tabItem {
                Label("书架", systemImage: "books.vertical")
            }
            .tag(0)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(1)
        }
        .tint(settings.theme.accent)
        .preferredColorScheme(settings.theme.colorScheme)
        // 听书悬浮组件常驻在标签栏上方：右下「听」球进界面，左下胶囊控制播放。
        // 用 overlay 而非 safeAreaInset —— 悬浮球不该把书架列表往上顶出一块空白。
        // 挂在根视图上，切标签、退出阅读页都不会消失。
        .overlay(alignment: .bottom) {
            ListeningFloatingDock(onOpen: openPlayer, bottomInset: 72)
                .environmentObject(settings)
        }
        .fullScreenCover(item: $activeBook) { book in
            ReaderView(bookID: book.id)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showPlayer) {
            ListeningPlayerView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .onAppear {
            // 仅供自动化预览/截图使用，正常启动不会命中
            let args = ProcessInfo.processInfo.arguments
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
                if args.contains("--night") { settings.theme = .night }
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
                selection = 1
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
}
