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
