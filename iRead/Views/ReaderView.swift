import SwiftUI
import UIKit

/// 阅读页：上下连续滚动。
///
/// 多章堆叠在同一条 `UIScrollView` 里，滑到章末自然接上下一章；
/// 正文用 CoreText 排版，听书时高亮正在朗读的那一句并自动跟随滚动。
struct ReaderView: View {
    let bookID: String
    /// 由书架「听书」入口进入时为 true，打开后自动开始朗读
    var autoStartListen: Bool = false

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var speech = SpeechService.shared

    @State private var content: BookContent?
    @State private var typesetter: ChapterTextProvider?
    @State private var chapterIndex = 0
    @State private var refreshToken = UUID()
    @State private var showChrome = true
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var loadFailed = false
    @State private var pendingListenStart = false

    @StateObject private var scrollProxy = ScrollProxy()
    /// 重建滚动视图时使用的锚点（章 + 章内字符）
    @State private var scrollAnchorChapter = 0
    @State private var scrollAnchorChar = 0
    @State private var scrollSpeechOffset: Int = 0

    // 听书
    /// 当前朗读文本所在的章
    @State private var speechChapter = 0
    /// 当前朗读文本在章内的起始偏移（把引擎给的相对区间换算成章内坐标）
    @State private var speechBase = 0
    /// 正在朗读的区间（章内坐标），画在正文上
    @State private var speechHighlight: NSRange?

    private var theme: ReadingTheme { settings.theme }

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
            speech.stop()
        }
        .onReceive(speech.$spokenRange) { range in
            applySpokenRange(range)
        }
        .onReceive(settings.objectWillChange) { _ in
            if scrollProxy.hasRendered {
                scrollProxy.refreshPosition()
                scrollAnchorChapter = scrollProxy.chapter
                scrollAnchorChar = scrollProxy.characterIndex
                scrollSpeechOffset = scrollProxy.characterIndex
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

                if speech.isActive && !showChrome && !showSettings {
                    VStack {
                        Spacer()
                        miniListenBar(content: content)
                    }
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
                if ProcessInfo.processInfo.arguments.contains("--panel") {
                    showSettings = true
                }
                if let p = debugLongPressPoint {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    scrollProxy.selectSentence(at: p)
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
            highlightChapter: speechChapter,
            highlightRange: speechHighlight,
            highlightColor: theme.speechHighlight,
            onPositionChange: { ch, char in
                scrollProxy.chapter = ch
                scrollProxy.characterIndex = char
                if ch != chapterIndex {
                    chapterIndex = ch
                    scrollSpeechOffset = char
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
        .onAppear {
            if pendingListenStart {
                pendingListenStart = false
                startListening()
            }
        }
        .onChange(of: refreshToken) { _, _ in
            guard speech.isActive else { return }
            speakNextScrollChunk()
        }
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
                    toggleListening()
                } label: {
                    Image(systemName: speech.isActive ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.body)
                }
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

    /// 沉浸模式下的迷你听书条
    private func miniListenBar(content: BookContent) -> some View {
        HStack(spacing: 14) {
            Button {
                speech.toggle()
            } label: {
                Image(systemName: speech.isPaused ? "play.fill" : "pause.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(theme.accent.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(speech.isPaused ? "听书已暂停" : (speech.isSpeaking ? "正在朗读" : "准备朗读…"))
                    .font(.footnote.weight(.medium))
                Text(positionLine(content: content))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.foreground)

            Spacer()

            Button {
                stopListening()
            } label: {
                Image(systemName: "stop.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func positionLine(content: BookContent) -> String {
        let title = content.chapterTitle(at: chapterIndex)
        let length = max(1, content.chapterText(at: chapterIndex).length)
        let ratio = Double(min(max(0, scrollProxy.characterIndex), length)) / Double(length)
        let percent = Int(min(1, max(0, ratio)) * 100)
        return "\(title) · 本章 \(percent)%"
    }

    // MARK: - 听书控制

    private func toggleListening() {
        if speech.isActive {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        guard let content else { return }
        // 续读：从上次停下的那一段接着读，而不是从当前屏的开头重来
        let resume = store.speechPosition(for: bookID)
        let sameChapter = resume?.chapter == chapterIndex

        var start = max(0, scrollProxy.characterIndex)
        if sameChapter, let r = resume {
            start = paragraphStart(chapter: chapterIndex, char: r.char)
        }
        chapterIndex = min(max(0, chapterIndex), max(0, content.chapterCount - 1))
        scrollSpeechOffset = start
        speechChapter = chapterIndex
        scrollProxy.scroll(toChapter: chapterIndex, char: start, animated: true)
        speakNextScrollChunk()
    }

    private func stopListening() {
        speech.stop()
        speechHighlight = nil
    }

    /// 把引擎给的相对区间换算成章内坐标，画高亮并记住位置
    private func applySpokenRange(_ range: NSRange?) {
        guard speech.isActive, let range, range.length > 0 else {
            if speechHighlight != nil { speechHighlight = nil }
            return
        }
        let absolute = NSRange(location: speechBase + range.location, length: range.length)
        speechHighlight = absolute
        // 逐句记录，重开时从这里续读
        store.setSpeechPosition(bookID: bookID, chapter: speechChapter, char: absolute.location)
        scrollProxy.ensureVisible(chapter: speechChapter, char: absolute.location)
    }

    /// 长按选中一句后点气泡 ▶：从这句的开头开始读。
    /// 点击屏幕不再触发朗读——点到的位置无法可靠对应到某一块文字，
    /// 必须先长按选中，把要读的句子确定下来。
    private func startSpeechFromSelection(chapter: Int, char: Int) {
        guard let content, content.chapters.indices.contains(chapter) else { return }
        let start = max(0, char)   // char 已经是选中句的起点，不再回退到段落开头

        chapterIndex = chapter
        speechChapter = chapter
        scrollSpeechOffset = start
        scrollAnchorChapter = chapter
        scrollAnchorChar = start
        scrollProxy.chapter = chapter
        scrollProxy.characterIndex = start
        speakNextScrollChunk()   // 内部会滚到这一句并往后连续读
    }

    /// 按段朗读，读完自动往下滚，跨章连续
    private func speakNextScrollChunk() {
        guard let content, content.chapters.indices.contains(chapterIndex) else { return }
        let text = content.chapterText(at: chapterIndex)
        if scrollSpeechOffset >= text.length {
            if chapterIndex + 1 < content.chapterCount {
                chapterIndex += 1
                scrollAnchorChapter = chapterIndex
                scrollAnchorChar = 0
                scrollSpeechOffset = 0
                scrollProxy.chapter = chapterIndex
                scrollProxy.characterIndex = 0
                refreshToken = UUID()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                    guard speech.isActive else { return }
                    speakNextScrollChunk()
                }
            } else {
                speech.stop()
            }
            return
        }

        let start = max(0, scrollSpeechOffset)
        let (chunk, next) = scrollChunk(in: text, from: start)
        guard !chunk.isEmpty else {
            scrollSpeechOffset = text.length
            speakNextScrollChunk()
            return
        }
        scrollSpeechOffset = next
        speechChapter = chapterIndex
        speechBase = start
        scrollProxy.scroll(toChapter: chapterIndex, char: start, animated: true)

        speech.onAdvance = { [self] in speakNextScrollChunk() }
        speech.start(
            text: chunk,
            rate: settings.speechRate,
            profile: settings.voiceProfile
        )
    }

    /// 段落起点：上一个换行符之后。中文 txt 通常一段一行，正好对应视觉上的自然段。
    private func paragraphStart(chapter: Int, char: Int) -> Int {
        guard let content, content.chapters.indices.contains(chapter) else { return max(0, char) }
        let text = content.chapterText(at: chapter)
        guard text.length > 0 else { return 0 }
        var i = min(max(0, char), text.length - 1)
        while i > 0 {
            if text.substring(with: NSRange(location: i - 1, length: 1)) == "\n" {
                break
            }
            i -= 1
        }
        return i
    }

    /// 从 offset 起取一小段（约 260 字），尽量在句末或段末收尾
    private func scrollChunk(in text: NSString, from offset: Int) -> (String, Int) {
        guard offset < text.length else { return ("", text.length) }
        let limit = min(text.length, offset + 260)
        var cut = limit
        if limit < text.length {
            let terminators: Set<Character> = ["。", "！", "？", "；", "…", "\n"]
            var i = limit
            var steps = 0
            while i > offset + 40, steps < 90 {
                let unit = text.substring(with: NSRange(location: i - 1, length: 1))
                if let ch = unit.first, terminators.contains(ch) {
                    cut = i
                    break
                }
                i -= 1
                steps += 1
            }
        }
        let chunk = text.substring(with: NSRange(location: offset, length: max(0, cut - offset)))
        return (chunk, cut)
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
        scrollSpeechOffset = offset
        speechChapter = target
        speechBase = offset
        speechHighlight = nil
        scrollAnchorChapter = target
        scrollAnchorChar = offset
        scrollProxy.chapter = target
        scrollProxy.characterIndex = offset
        refreshToken = UUID()
        showChapters = false
        showBookmarks = false
        persistScrollProgress(chapter: target, charIndex: offset, throttled: false)
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
        speechChapter = chapterIndex
        speechBase = scrollAnchorChar
        settings.applyBrightness()
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        pendingListenStart = autoStartListen
            || ProcessInfo.processInfo.arguments.contains("--listen")
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
