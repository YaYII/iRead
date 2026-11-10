import SwiftUI
import UIKit

/// 阅读页：上下连续滚动。
///
/// 多章堆叠在同一条 `UIScrollView` 里，滑到章末自然接上下一章；
/// 正文用 CoreText 排版，听书时高亮正在朗读的那一句并自动跟随滚动。
struct ReaderView: View {
    let bookID: String

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    /// 听书是全局组件，这里只观察它，不拥有播放状态
    @ObservedObject private var listening = ListeningCenter.shared

    @State private var content: BookContent?
    @State private var typesetter: ChapterTextProvider?
    @State private var chapterIndex = 0
    @State private var refreshToken = UUID()
    @State private var showChrome = true
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var showPlayer = false
    @State private var loadFailed = false

    @StateObject private var scrollProxy = ScrollProxy()
    /// 重建滚动视图时使用的锚点（章 + 章内字符）
    @State private var scrollAnchorChapter = 0
    @State private var scrollAnchorChar = 0

    /// 正在朗读的区间（章内坐标），仅在「听的就是这本书」时有值
    @State private var speechHighlight: NSRange?

    private var theme: ReadingTheme { settings.theme }

    /// 影响排版的设置指纹。只有这些变了才需要重排重画；
    /// 亮度、语速、屏幕常亮之类的改动不该惊动正文。
    private var layoutToken: String {
        [
            "\(settings.fontSize)",
            "\(settings.lineSpacing)",
            "\(settings.paragraphSpacing)",
            "\(Int(settings.horizontalMargin))",
            "\(Int(settings.verticalMargin))",
            settings.isBold ? "b" : "-",
            settings.firstLineIndent ? "i" : "-",
            settings.theme.rawValue
        ].joined(separator: "|")
    }

    /// 仅供自测：`--longpress x,y` 注入一次长按
    private var debugLongPressPoint: CGPoint? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--longpress"), i + 1 < args.count else { return nil }
        let nums = args[i + 1].split(separator: ",").compactMap { Double($0) }
        guard nums.count == 2 else { return nil }
        return CGPoint(x: nums[0], y: nums[1])
    }

    var body: some View {
        Group {
            if let content, let typesetter {
                readerBody(content: content, typesetter: typesetter)
            } else {
                VStack(spacing: 14) {
                    if !loadFailed { ProgressView() }
                    Text(loadFailed ? "无法打开这本书" : "正在排版…")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondary)
                    if loadFailed {
                        Button("返回书架") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background.ignoresSafeArea())
            }
        }
        .preferredColorScheme(theme.colorScheme)
        .onAppear { prepare() }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            persistScrollProgress(
                chapter: scrollProxy.chapter,
                charIndex: scrollProxy.characterIndex,
                throttled: false
            )
            // 注意：这里**不停止朗读**。听书是独立组件，退出阅读页继续播。
        }
        .onReceive(listening.$spokenRange) { _ in syncListeningHighlight() }
        .onReceive(listening.$spokenChapter) { _ in syncListeningHighlight() }
        .onReceive(listening.$bookID) { _ in syncListeningHighlight() }
        // 只有影响排版的设置变了才重排。亮度、语速、常亮这些不该触发重排，
        // 更不该动朗读进度 —— 以前监听 objectWillChange 时会把 scrollSpeechOffset
        // 覆盖成当前屏位置，结果就是「一调字号，朗读从眼前这段重读」。
        .onChange(of: settings.keepScreenOn) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        .onChange(of: layoutToken) { _, _ in
            if scrollProxy.hasRendered {
                scrollProxy.refreshPosition()
                scrollAnchorChapter = scrollProxy.chapter
                scrollAnchorChar = scrollProxy.characterIndex
            }
            typesetter?.invalidate()
            refreshToken = UUID()
        }
        .sheet(isPresented: $showChapters) {
            Group {
                if let book = store.book(bookID), let content {
                    NavigationStack {
                        ChapterListView(book: book, content: content, currentIndex: chapterIndex) { index in
                            jump(toChapter: index, char: 0)
                        }
                        .navigationTitle("目录")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("关闭") { showChapters = false }
                            }
                        }
                    }
                }
            }
            .environmentObject(store)
            .environmentObject(settings)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showBookmarks) {
            Group {
                if let book = store.book(bookID) {
                    BookmarksView(book: book) { chapter, char in
                        jump(toChapter: chapter, char: char)
                    }
                }
            }
            .environmentObject(store)
            .environmentObject(settings)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPlayer) {
            ListeningPlayerView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }

    // MARK: - 主体

    private func readerBody(content: BookContent, typesetter: ChapterTextProvider) -> some View {
        GeometryReader { geo in
            let hPad = settings.horizontalMargin
            let vPad = settings.verticalMargin
            let contentWidth = max(140, geo.size.width - hPad * 2)

            ZStack(alignment: .top) {
                theme.background.ignoresSafeArea()

                scrollBody(
                    content: content,
                    typesetter: typesetter,
                    geo: geo,
                    contentWidth: contentWidth,
                    hPad: hPad,
                    vPad: vPad
                )

                if showChrome {
                    chrome(content: content)
                        .transition(.opacity)
                        .zIndex(2)
                }

                // 排版面板：内嵌浮层而非 sheet，上半屏正文仍可见，调字号能立刻看到效果
                if showSettings {
                    VStack(spacing: 0) {
                        // 点上方正文区域收起面板（番茄同款手感）
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) { showSettings = false }
                            }
                        ReaderPanel(maxHeight: min(560, geo.size.height * 0.74))
                    }
                    .transition(.move(edge: .bottom))
                    .zIndex(4)
                }

                // 听书悬浮组件：常驻「听」球 + 正在听时的控制胶囊。
                // 不随沉浸模式消失，也不判断听的是不是这本书 —— 听 A 看 B 时照样能控制。
                // 它浮在正文上，跟 UITextView / 滚动容器没有任何耦合。
                if !showSettings {
                    ListeningFloatingDock(
                        onOpen: openPlayer,
                        bottomInset: showChrome ? 78 : 24
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
                }

                // 护眼滤镜：一层极淡的暖色，降低蓝光又不至于糊掉文字
                if settings.eyeCare {
                    Color(hex: 0xFFB45A)
                        .opacity(theme == .night ? 0.09 : 0.11)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .zIndex(5)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // 仅供自测：模拟在屏幕某点长按选中
            .task {
                if let p = debugLongPressPoint {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    scrollProxy.selectSentence(at: p)
                }
                // 仅供自测：听书过程中模拟用户手动往下滚，验证不会再被拽回
                if ProcessInfo.processInfo.arguments.contains("--scroll-away") {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    scrollProxy.simulateUserScroll(by: 600)
                }
                // 仅供自测：听书过程中改字号，验证不会重读
                if ProcessInfo.processInfo.arguments.contains("--font-bump") {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    #if DEBUG
                    print("[Reader] font-bump \(settings.fontSize) → \(settings.fontSize + 2)")
                    #endif
                    settings.fontSize += 2
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: showChrome)
        .animation(.easeInOut(duration: 0.22), value: showSettings)
    }

    // MARK: - 连续滚动

    private func scrollBody(
        content: BookContent,
        typesetter: ChapterTextProvider,
        geo: GeometryProxy,
        contentWidth: CGFloat,
        hPad: CGFloat,
        vPad: CGFloat
    ) -> some View {
        // 顶部：给状态栏下的工具栏留位（收起时只留一点）
        let topReserve: CGFloat = showChrome ? 58 : 6
        // 底部：工具栏是浮层，固定预留（含安全区），避免末行被遮。
        // 上下章导航去掉后底栏只剩一行按钮，留白同步收窄。
        let bottomReserve: CGFloat = 120
        // 注意：签名里**不含章号**。章号变化只代表用户滚到了下一章，
        // 不应该触发整本重建，否则无缝滚动就断了。
        let signature = [
            "book",
            "\(settings.fontSize)",
            "\(settings.lineSpacing)",
            "\(settings.paragraphSpacing)",
            "\(settings.isBold)",
            "\(settings.firstLineIndent)",
            settings.theme.rawValue,
            "\(Int(contentWidth))",
            refreshToken.uuidString
        ].joined(separator: "|")

        return BookScrollView(
            chapterCount: content.chapterCount,
            attributedProvider: { ch in typesetter.attributed(ch) },
            theme: theme,
            contentWidth: contentWidth,
            horizontalInset: hPad,
            topInset: vPad + topReserve,
            bottomInset: vPad + bottomReserve,
            startChapter: scrollAnchorChapter,
            startCharacter: scrollAnchorChar,
            signature: signature,
            proxy: scrollProxy,
            highlightChapter: listening.bookID == bookID ? listening.spokenChapter : -1,
            highlightRange: speechHighlight,
            highlightColor: theme.speechHighlight,
            onPositionChange: { ch, char in
                scrollProxy.chapter = ch
                scrollProxy.characterIndex = char
                // 只更新「用户看到哪一章」，不要动朗读进度：
                // 排版变化（改字号）会让这里报出不同的章号，
                // 一旦把 scrollSpeechOffset 覆盖掉，下一段就会从你眼前的位置重读。
                if ch != chapterIndex {
                    chapterIndex = ch
                }
                persistScrollProgress(chapter: ch, charIndex: char, throttled: true)
            },
            onTap: {
                withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
            },
            onStartSpeech: { ch, char in
                guard !showSettings else { return }
                startSpeechFromSelection(chapter: ch, char: char)
            }
        )
        .frame(width: geo.size.width, height: geo.size.height)
        // 重排（改字号/行距/主题）只影响排版，跟朗读进度无关：
        // 这里千万不要再调 speakNextScrollChunk()，否则会把正在念的这一段掐断，
        // 直接从下一段起播，听感上就是「跳了一段」。高亮由 updateUIView 重新贴回。
    }

    // MARK: - 工具栏

    private func chrome(content: BookContent) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.book(bookID)?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(content.chapterTitle(at: chapterIndex))
                        .font(.caption2)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    openPlayer()
                } label: {
                    Image(systemName: "headphones")
                        .font(.body)
                        .foregroundStyle(isListeningThisBook ? theme.accent : theme.foreground)
                }
                .accessibilityLabel("打开听书")
                Button {
                    toggleBookmark()
                } label: {
                    Image(systemName: isCurrentBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.body)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.regularMaterial, ignoresSafeAreaEdges: .top)

            Spacer()

            HStack(spacing: 0) {
                toolbarItem("目录", "list.bullet") { showChapters = true }
                toolbarItem("书签", "bookmark") { showBookmarks = true }
                toolbarItem("排版", "textformat.size") { showSettings = true }
                toolbarItem("沉浸", "eye.slash") { showChrome = false }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
        }
        .foregroundStyle(theme.foreground)
    }

    private func toolbarItem(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 听书控制（只负责发起与定位，播放状态由 ListeningCenter 管）

    /// 正在听的是不是这本书。听别人的书时，本页既不贴高亮也不当作已开播。
    private var isListeningThisBook: Bool {
        listening.bookID == bookID && listening.isActive
    }

    /// 所有听书入口（顶部耳机、右下悬浮球）都只打开听书界面，不在这里出声。
    /// 没有选中过书时，把当前这本装进听书组件作预选（依然不播）；
    /// 已经在听别的书时一律不打断，换书由播放器内部的「选书」完成。
    private func openPlayer() {
        if !listening.isPlayingSomething {
            let last = max(0, (content?.chapterCount ?? 1) - 1)
            let chapter = min(max(0, chapterIndex), last)
            listening.prepare(
                bookID: bookID,
                fallbackChapter: chapter,
                fallbackChar: max(0, scrollProxy.characterIndex)
            )
        }
        showPlayer = true
    }

    /// 高亮只在「正在听的就是这本书」时贴回正文。
    /// 听 A 看 B 时这里会自动清空，不干扰正在读的页面。
    private func syncListeningHighlight() {
        guard listening.bookID == bookID,
              let range = listening.spokenRange,
              range.length > 0 else {
            if speechHighlight != nil { speechHighlight = nil }
            return
        }
        speechHighlight = range
        scrollProxy.ensureVisible(chapter: listening.spokenChapter, char: range.location)
    }

    /// 长按选中一句后点气泡 ▶：把听书起点定位到这句，并打开听书界面。
    /// 点击屏幕不再触发朗读——点到的位置无法可靠对应到某一块文字，
    /// 必须先长按选中，把要读的句子确定下来。
    private func startSpeechFromSelection(chapter: Int, char: Int) {
        guard let content, content.chapters.indices.contains(chapter) else { return }
        if listening.isActive && listening.bookID == bookID {
            // 本来就在听这本：只是换个起点，别把声音掐掉
            listening.seekTo(chapter: chapter, char: char)
        } else {
            // 没在听（或听的是别的书）：装好这本 + 定位到选中句，等用户按播放
            listening.prepare(bookID: bookID, fallbackChapter: chapter, fallbackChar: char)
            listening.locate(chapter: chapter, char: char)
        }
        showPlayer = true
    }

    // MARK: - 进度 / 书签

    private var isCurrentBookmarked: Bool {
        store.isBookmarked(
            bookID: bookID,
            chapterIndex: chapterIndex,
            charOffset: scrollProxy.characterIndex
        )
    }

    /// 跳章 / 跳书签：把锚点挪到目标位置，让滚动容器重建窗口并定位过去。
    private func jump(toChapter chapter: Int, char: Int) {
        guard let content else { return }
        let target = min(max(0, chapter), max(0, content.chapterCount - 1))
        let length = content.chapterText(at: target).length
        let offset = min(max(0, char), length)

        chapterIndex = target
        scrollAnchorChapter = target
        scrollAnchorChar = offset
        scrollProxy.chapter = target
        scrollProxy.characterIndex = offset
        speechHighlight = nil
        showChapters = false
        showBookmarks = false
        persistScrollProgress(chapter: target, charIndex: offset, throttled: false)

        // 只在「正在听的就是这本书」时把朗读带过来。
        // 听 A 看 B 时，在 B 里跳章绝不能动 A 的播放位置。
        if listening.bookID == bookID {
            if listening.isActive {
                // 正在听这本：朗读跟着换地方，别一边显示新章节一边念旧位置。
                listening.play(bookID: bookID, chapter: target, char: offset, snapToParagraph: false)
            } else {
                // 暂停中：同步朗读记录，下次播从这儿起
                store.setSpeechPosition(bookID: bookID, chapter: target, char: offset)
            }
        }
    }

    private func toggleBookmark() {
        guard let content else { return }
        let text = content.chapterText(at: chapterIndex)
        let start = max(0, min(scrollProxy.characterIndex, max(0, text.length - 1)))
        let length = min(60, max(0, text.length - start))
        let excerpt: String
        if length > 0 {
            excerpt = text.substring(with: NSRange(location: start, length: length))
                .replacingOccurrences(of: "\n", with: " ")
        } else {
            excerpt = content.chapterTitle(at: chapterIndex)
        }
        store.toggleBookmark(
            bookID: bookID,
            chapterIndex: chapterIndex,
            charOffset: start,
            excerpt: excerpt
        )
    }

    private func persistScrollProgress(chapter: Int, charIndex: Int, throttled: Bool) {
        guard let content, content.chapters.indices.contains(chapter) else { return }
        if throttled, Date().timeIntervalSince(scrollProxy.lastSaveAt) < 1.5 { return }
        scrollProxy.lastSaveAt = Date()

        let length = max(1, content.chapterText(at: chapter).length)
        let ratio = Double(min(max(0, charIndex), length)) / Double(length)
        let absolute = content.chapters[chapter].location + max(0, charIndex)
        let progress = content.totalLength > 0
            ? min(1, max(0, Double(absolute) / Double(content.totalLength)))
            : 0
        store.updateReading(
            bookID: bookID,
            chapterIndex: chapter,
            progress: progress,
            scrollRatio: ratio
        )
    }

    private func prepare() {
        guard let loaded = store.content(for: bookID) else {
            loadFailed = true
            return
        }
        let engine = ChapterTextProvider(content: loaded, settings: settings)
        content = loaded
        typesetter = engine
        chapterIndex = min(max(0, store.book(bookID)?.lastChapterIndex ?? 0), max(0, loaded.chapterCount - 1))
        // 恢复上次阅读位置：章内比例 → 章内字符位置
        let savedRatio = min(1, max(0, store.book(bookID)?.lastScrollRatio ?? 0))
        let chapterLength = loaded.chapterText(at: chapterIndex).length
        scrollAnchorChapter = chapterIndex
        scrollAnchorChar = min(chapterLength, max(0, Int(savedRatio * Double(chapterLength))))
        scrollProxy.chapter = chapterIndex
        scrollProxy.characterIndex = scrollAnchorChar
        // 如果打开的就是正在听的那本，把当前朗读句贴回来
        syncListeningHighlight()
        settings.applyBrightness()
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--scroll-mid") {
            scrollAnchorChar = Int(Double(chapterLength) * 0.45)
            scrollProxy.characterIndex = scrollAnchorChar
        }
        // 仅供截图：定位到章末，验证下一章是否已经无缝接上
        if args.contains("--scroll-end") {
            scrollAnchorChar = max(0, chapterLength - 60)
            scrollProxy.characterIndex = scrollAnchorChar
        }
        if args.contains("--immersive") {
            showChrome = false
        }
        // 仅供截图：直接弹出番茄式设置面板
        if args.contains("--panel") { showSettings = true }
        if args.contains("--eyecare") { settings.eyeCare = true }
    }
}
