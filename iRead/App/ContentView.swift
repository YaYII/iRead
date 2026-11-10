import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings

    @State private var selection = 0
    @State private var activeBook: Book?
    @State private var autoStartListen = false

    var body: some View {
        TabView(selection: $selection) {
            BookshelfView(
                onOpenBook: { book in
                    autoStartListen = false
                    activeBook = book
                },
                onListenBook: { book in
                    autoStartListen = true
                    activeBook = book
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
        .fullScreenCover(item: $activeBook) { book in
            ReaderView(bookID: book.id, autoStartListen: autoStartListen)
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
            if args.contains("--debug-reader") {
                if args.contains("--night") { settings.theme = .night }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    activeBook = store.books.first
                }
            } else if args.contains("--debug-settings") {
                selection = 1
            }
        }
    }
}
