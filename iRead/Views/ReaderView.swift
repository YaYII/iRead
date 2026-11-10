import SwiftUI
import UIKit

/// 阅读页。
/// 两种阅读方式共用同一套 CoreText 排版属性：
/// - 上下滑动（默认）：整章排成一条，像网页一样连续滚动
/// - 左右翻页：按屏分页，整页翻动
struct ReaderView: View {
    let bookID: String
    /// 由书架「听书」入口进入时为 true，打开后自动开始朗读
    var autoStartListen: Bool = false

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var speech = SpeechService.shared

    @State private var content: BookContent?
    @State private var paginator: Paginator?
    @State private var chapterIndex = 0
    @State private var pageIndex = 0
    @State private var turnDirection = 1
    @State private var refreshToken = UUID()
    @State private var showChrome = true
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var loadFailed = false
    @State private var pendingListenStart = false
    /// 自动阅读进行中
    @State private var autoReading = false
    @State private var autoReadTask: Task<Void, Never>?

    // 上下滑动模式
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
    /// 双击/续读指定的起始点，等翻页完成后由 onChange 消费
    @State private var pendingSpeechFrom: Int?

    private var theme: ReadingTheme { settings.theme }
    private var isScrollMode: Bool { settings.readingMode == .scroll }
    private let chromeReserve: CGFloat = 100

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
            if let content, let paginator {
                readerBody(content: content, paginator: paginator)
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
            stopAutoRead()
            if isScrollMode {
                persistScrollProgress(
                    chapter: scrollProxy.chapter,
                    charIndex: scrollProxy.characterIndex,
                    throttled: false
                )
            }
            speech.stop()
        }
        .onReceive(speech.$spokenRange) { range in
            applySpokenRange(range)
        }
        .onReceive(settings.objectWillChange) { _ in
            if isScrollMode, scrollProxy.hasRendered {
                scrollProxy.refreshPosition()
                scrollAnchorChapter = scrollProxy.chapter
                scrollAnchorChar = scrollProxy.characterIndex
                scrollSpeechOffset = scrollProxy.characterIndex
            }
            paginator?.invalidate()
            refreshToken = UUID()
        }
        .onChange(of: settings.readingMode) { _, newMode in
            if newMode == .scroll {
                if scrollProxy.hasRendered {
                    scrollProxy.refreshPosition()
                    scrollAnchorChapter = scrollProxy.chapter
                    scrollAnchorChar = scrollProxy.characterIndex
                } else {
                    scrollAnchorChapter = chapterIndex
                    scrollAnchorChar = 0
                }
            }
            refreshToken = UUID()
        }
        .sheet(isPresented: $showChapters) {
            Group {
                if let book = store.book(bookID), let content {
                    NavigationStack {
                        ChapterListView(book: book, content: content, currentIndex: chapterIndex) { index in
                            jump(toChapter: index, page: 0)
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
                    BookmarksView(book: book) { chapter, page in
                        jump(toChapter: chapter, page: page)
                    }
                }
            }
            .environmentObject(store)
            .environmentObject(settings)
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 主体

    private func readerBody(content: BookContent, paginator: Paginator) -> some View {
        GeometryReader { geo in
            let hPad = settings.horizontalMargin
            let vPad = settings.verticalMargin
            let contentWidth = max(140, geo.size.width - hPad * 2)
            // 底部工具栏是浮层，固定预留高度，避免正文末行被遮住
            let visibleHeight = max(180, geo.size.height - vPad * 2 - 24 - 28 - chromeReserve)
            let pageSize = CGSize(width: contentWidth, height: visibleHeight)

            ZStack(alignment: .top) {
                theme.background.ignoresSafeArea()

                if isScrollMode {
                    scrollBody(
                        content: content,
                        paginator: paginator,
                        geo: geo,
                        contentWidth: contentWidth,
                        pageSize: pageSize,
                        hPad: hPad,
                        vPad: vPad
                    )
                } else {
                    pagedBody(
                        content: content,
                        paginator: paginator,
                        geo: geo,
                        pageSize: pageSize,
                        hPad: hPad,
                        vPad: vPad
                    )
                }

                if showChrome {
                    chrome(content: content, paginator: paginator, size: pageSize)
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
                        ReaderPanel(
                            onStartAutoRead: {
                                withAnimation(.easeInOut(duration: 0.2)) { showSettings = false }
                                startAutoRead(paginator: paginator, size: pageSize)
                            },
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.2)) { showSettings = false }
                            },
                            maxHeight: min(560, geo.size.height * 0.74)
                        )
                    }
                    .transition(.move(edge: .bottom))
                    .zIndex(4)
                }

                // 自动阅读进行中：底部提示条 + 停止按钮
                if autoReading && !showSettings {
                    VStack {
                        Spacer()
                        autoReadBar(paginator: paginator, size: pageSize)
                    }
                    .transition(.opacity)
                    .zIndex(3)
                }

                if speech.isActive && !showChrome && !showSettings {
                    VStack {
                        Spacer()
                        miniListenBar(content: content, paginator: paginator, size: pageSize)
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
            // 仅供截图/自测：直接进自动阅读
            .task {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--autoread") {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard !autoReading else { return }
                    settings.autoReadSpeed = 3
                    startAutoRead(paginator: paginator, size: pageSize)
                }
                // 仅供自测：模拟在屏幕某点长按选中
                if let p = debugLongPressPoint, isScrollMode {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    scrollProxy.selectSentence(at: p)
                }
                // 仅供自测：模拟在屏幕某点双击（x,y 单位 pt）
                if let i = args.firstIndex(of: "--doubletap"), i + 1 < args.count {
                    let nums = args[i + 1].split(separator: ",").compactMap { Double($0) }
                    if nums.count == 2 {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        simulateDoubleTap(
                            at: CGPoint(x: nums[0], y: nums[1]),
                            paginator: paginator,
                            size: pageSize,
                            hPad: hPad,
                            vPad: vPad
                        )
                    }
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: showChrome)
        .animation(.easeInOut(duration: 0.22), value: showSettings)
    }

    // MARK: - 上下滑动

    private func scrollBody(
        content: BookContent,
        paginator: Paginator,
        geo: GeometryProxy,
        contentWidth: CGFloat,
        pageSize: CGSize,
        hPad: CGFloat,
        vPad: CGFloat
    ) -> some View {
        // 顶部：给状态栏下的工具栏留位（收起时只留一点）
        let topReserve: CGFloat = showChrome ? 58 : 6
        // 底部：工具栏是浮层，固定预留（含安全区），避免末行被遮
        let bottomReserve: CGFloat = 152
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
            attributedProvider: { ch in paginator.chapterAttributed(ch) },
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
                scrollProxy.lastPageCount = max(1, paginator.pageCount(chapter: ch, size: pageSize))
                if ch != chapterIndex {
                    chapterIndex = ch
                    pageIndex = 0
                    scrollSpeechOffset = char
                }
                persistScrollProgress(chapter: ch, charIndex: char, throttled: true)
            },
            onTap: {
                withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
            },
            onDoubleTap: { ch, char in
                guard !showSettings else { return }
                startSpeechFromTap(chapter: ch, char: char, paginator: paginator, size: pageSize)
            }
        )
        .frame(width: geo.size.width, height: geo.size.height)
        .onAppear {
            scrollProxy.lastPageCount = max(1, paginator.pageCount(chapter: chapterIndex, size: pageSize))
            if pendingListenStart {
                pendingListenStart = false
                startListening(paginator: paginator, size: pageSize)
            }
        }
        .onChange(of: refreshToken) { _, _ in
            guard speech.isActive else { return }
            speakNextScrollChunk()
        }
    }

    // MARK: - 左右翻页

    private func pagedBody(
        content: BookContent,
        paginator: Paginator,
        geo: GeometryProxy,
        pageSize: CGSize,
        hPad: CGFloat,
        vPad: CGFloat
    ) -> some View {
        let safePage = min(max(0, pageIndex), max(0, paginator.pageCount(chapter: chapterIndex, size: pageSize) - 1))
        let page = paginator.page(chapter: chapterIndex, page: safePage, size: pageSize)
        let key = "\(chapterIndex)-\(safePage)-\(Int(pageSize.width))-\(Int(pageSize.height))-\(refreshToken.uuidString)"

        return VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                Text(store.book(bookID)?.title ?? "")
                    .font(.caption2)
                    .lineLimit(1)
                Spacer()
                Text(content.chapterTitle(at: chapterIndex))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.secondary)
            .frame(height: 24)

            ZStack {
                CoreTextPage(
                    pageText: page.text,
                    startLocation: page.start,
                    highlightRange: speechHighlight,
                    highlightColor: theme.speechHighlight,
                    readingTheme: theme,
                    onStartSpeech: { char in
                        startSpeechFromTap(
                            chapter: chapterIndex,
                            char: char,
                            paginator: paginator,
                            size: pageSize
                        )
                    },
                    debugLongPress: debugLongPressPoint.map {
                        CGPoint(x: $0.x - hPad, y: $0.y - vPad - 24)
                    }
                )
                    .frame(width: pageSize.width, height: pageSize.height)
                    .id(key)
                    .transition(pageTransition)
                    .animation(pageAnimation, value: key)
                    // 仿真档额外叠一点 3D 折角，和纯平移区分开
                    .rotation3DEffect(
                        .degrees(page3DRotation.angle),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: page3DRotation.anchor,
                        perspective: page3DRotation.perspective
                    )
                    .animation(pageAnimation, value: turnDirection)
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()

            HStack(spacing: 8) {
                Text("\(safePage + 1) / \(max(1, paginator.pageCount(chapter: chapterIndex, size: pageSize)))")
                Spacer()
                Text("\(Int(paginator.progress(chapter: chapterIndex, page: safePage, size: pageSize) * 100))%")
            }
            .font(.caption2)
            .foregroundStyle(theme.secondary)
            .frame(height: 28)
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let dx = value.translation.width
                    if dx < -45 {
                        goNext(paginator: paginator, size: pageSize)
                    } else if dx > 45 {
                        goPrevious(paginator: paginator, size: pageSize)
                    }
                }
        )
        .onTapGesture(count: 2, coordinateSpace: .local) { location in
            // 双击正文：从点到的段落开始朗读
            let point = CGPoint(x: location.x - hPad, y: location.y - vPad - 24)
            guard let char = TextHighlight.characterIndex(
                in: page.text, startLocation: page.start, size: pageSize, point: point
            ) else { return }
            startSpeechFromTap(
                chapter: chapterIndex,
                char: char,
                paginator: paginator,
                size: pageSize
            )
        }
        .onTapGesture(count: 1, coordinateSpace: .local) { location in
            // 单击分区：左/右翻页，中间呼出工具栏（双击优先，单击会等双击失败）
            let x = location.x
            if x < geo.size.width * 0.32 {
                goPrevious(paginator: paginator, size: pageSize)
            } else if x > geo.size.width * 0.68 {
                goNext(paginator: paginator, size: pageSize)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
            }
        }
        .onAppear {
            if pendingListenStart {
                pendingListenStart = false
                startListening(paginator: paginator, size: pageSize)
            }
        }
        .onChange(of: key) { _, _ in
            // 页面内容变化（翻页/跳章/排版变更）后，听书状态下从新页继续读；
            // 暂停中翻页会取消暂停，避免恢复时读的是上一页的剩余内容
            guard speech.isActive else { return }
            let from = pendingSpeechFrom
            pendingSpeechFrom = nil
            speakPage(paginator: paginator, size: pageSize, from: from)
        }
    }

    // MARK: - 工具栏

    private func chrome(content: BookContent, paginator: Paginator, size: CGSize) -> some View {
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
                    toggleListening(paginator: paginator, size: size)
                } label: {
                    Image(systemName: speech.isActive ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.body)
                }
                Button {
                    toggleBookmark(paginator: paginator, size: size)
                } label: {
                    Image(systemName: isCurrentBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.body)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.regularMaterial, ignoresSafeAreaEdges: .top)

            Spacer()

            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        chapterStep(-1, paginator: paginator, size: size)
                    } label: {
                        Text("上一章").font(.caption2)
                    }
                    .disabled(chapterIndex == 0)

                    Slider(
                        value: Binding(
                            get: { Double(chapterIndex) },
                            set: { jumpToChapter(Int($0.rounded()), paginator: paginator, size: size) }
                        ),
                        in: 0...Double(max(1, content.chapterCount - 1)),
                        step: 1
                    )
                    .controlSize(.small)

                    Button {
                        chapterStep(1, paginator: paginator, size: size)
                    } label: {
                        Text("下一章").font(.caption2)
                    }
                    .disabled(chapterIndex >= content.chapterCount - 1)
                }
                .frame(height: 24)

                HStack(spacing: 0) {
                    toolbarItem("目录", "list.bullet") { showChapters = true }
                    toolbarItem("书签", "bookmark") { showBookmarks = true }
                    toolbarItem("排版", "textformat.size") { showSettings = true }
                    toolbarItem(
                        settings.readingMode == .scroll ? "翻页" : "滑动",
                        settings.readingMode == .scroll ? "book.pages" : "arrow.up.and.down.text.horizontal"
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.readingMode = settings.readingMode == .scroll ? .page : .scroll
                        }
                    }
                    toolbarItem("沉浸", "eye.slash") { showChrome = false }
                }
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

    /// 自动阅读进行中的底部提示条
    private func autoReadBar(paginator: Paginator, size: CGSize) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.accent)
            Text("自动阅读中 · 每 \(Int(settings.autoReadSpeed)) 秒翻一页")
                .font(.caption)
                .foregroundStyle(theme.secondary)
            Spacer()
            Button {
                stopAutoRead()
            } label: {
                Text("停止")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    /// 沉浸模式下的迷你听书条
    private func miniListenBar(content: BookContent, paginator: Paginator, size: CGSize) -> some View {
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
                Text(positionLine(content: content, paginator: paginator, size: size))
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

    private func positionLine(content: BookContent, paginator: Paginator, size: CGSize) -> String {
        let title = content.chapterTitle(at: chapterIndex)
        if isScrollMode {
            let length = max(1, content.chapterText(at: chapterIndex).length)
            let ratio = Double(min(max(0, scrollProxy.characterIndex), length)) / Double(length)
            let percent = Int(min(1, max(0, ratio)) * 100)
            return "\(title) · 本章 \(percent)%"
        }
        let page = min(max(0, pageIndex), max(0, paginator.pageCount(chapter: chapterIndex, size: size) - 1))
        return "\(title) · 第 \(page + 1) 页"
    }

    // MARK: - 听书控制

    private func toggleListening(paginator: Paginator, size: CGSize) {
        if speech.isActive {
            stopListening()
        } else {
            startListening(paginator: paginator, size: size)
        }
    }

    private func startListening(paginator: Paginator, size: CGSize) {
        // 续读：从上次停下的那一段接着读，而不是从当前屏/页的开头重来
        let resume = store.speechPosition(for: bookID)
        let sameChapter = resume?.chapter == chapterIndex

        if isScrollMode {
            var start = max(0, scrollProxy.characterIndex)
            if sameChapter, let r = resume {
                start = paragraphStart(chapter: chapterIndex, char: r.char)
            }
            chapterIndex = min(max(0, chapterIndex), max(0, (content?.chapterCount ?? 1) - 1))
            scrollSpeechOffset = start
            speechChapter = chapterIndex
            scrollProxy.scroll(toChapter: chapterIndex, char: start, animated: true)
            speakNextScrollChunk()
            return
        }

        speakPage(paginator: paginator, size: size, from: sameChapter ? resume?.char : nil)
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
        if isScrollMode {
            scrollProxy.ensureVisible(chapter: speechChapter, char: absolute.location)
        }
    }

    /// 读当前页；`from` 指定章内起始位置（双击处 / 上次停下的地方）
    private func speakPage(paginator: Paginator, size: CGSize, from: Int? = nil) {
        let count = max(1, paginator.pageCount(chapter: chapterIndex, size: size))
        pageIndex = min(max(0, pageIndex), count - 1)
        let page = paginator.page(chapter: chapterIndex, page: pageIndex, size: size)
        let pageEnd = page.range.location + page.range.length

        var start = page.range.location
        if let raw = from, raw >= page.range.location, raw < pageEnd {
            // 从段落开头读，不从半句中间起
            start = max(page.range.location, paragraphStart(chapter: chapterIndex, char: raw))
        }
        let range = NSRange(location: start, length: max(0, pageEnd - start))

        speechChapter = chapterIndex
        speechBase = start
        speech.onAdvance = { advanceForSpeech(paginator: paginator, size: size) }
        speech.start(
            text: paginator.plainText(chapter: chapterIndex, range: range),
            rate: settings.speechRate,
            profile: settings.voiceProfile
        )
    }

    /// 双击正文：从点到的段落开始读
    private func startSpeechFromTap(chapter: Int, char: Int, paginator: Paginator, size: CGSize) {
        guard let content, content.chapters.indices.contains(chapter) else { return }
        let start = paragraphStart(chapter: chapter, char: char)

        if isScrollMode {
            chapterIndex = chapter
            speechChapter = chapter
            scrollSpeechOffset = start
            scrollAnchorChapter = chapter
            scrollAnchorChar = start
            scrollProxy.chapter = chapter
            scrollProxy.characterIndex = start
            scrollProxy.scroll(toChapter: chapter, char: start, animated: true)
            speakNextScrollChunk()
            return
        }

        let target = paginator.pageIndex(chapter: chapter, forCharacter: start, size: size)
        chapterIndex = chapter
        if target == pageIndex {
            speakPage(paginator: paginator, size: size, from: start)
        } else {
            // 先翻页，翻页后的 onChange 会用到这个起点
            pendingSpeechFrom = start
            pageIndex = target
        }
    }

    /// 仅供自测：把屏幕坐标当成双击点，走和手势完全一致的命中测试
    private func simulateDoubleTap(
        at point: CGPoint,
        paginator: Paginator,
        size: CGSize,
        hPad: CGFloat,
        vPad: CGFloat
    ) {
        if isScrollMode {
            guard let hit = scrollProxy.characterIndex(near: point) else { return }
            startSpeechFromTap(chapter: hit.chapter, char: hit.char, paginator: paginator, size: size)
            return
        }
        let page = paginator.page(chapter: chapterIndex, page: pageIndex, size: size)
        let local = CGPoint(x: point.x - hPad, y: point.y - vPad - 24)
        guard let char = TextHighlight.characterIndex(
            in: page.text, startLocation: page.start, size: size, point: local
        ) else { return }
        startSpeechFromTap(chapter: chapterIndex, char: char, paginator: paginator, size: size)
    }

    /// 翻页模式：一页读完自动翻页；全书读完自动停止
    private func advanceForSpeech(paginator: Paginator, size: CGSize) {
        let count = paginator.pageCount(chapter: chapterIndex, size: size)
        if pageIndex + 1 < count {
            turnDirection = 1
            pageIndex += 1
        } else if chapterIndex + 1 < (content?.chapterCount ?? 0) {
            turnDirection = 1
            chapterIndex += 1
            pageIndex = 0
        } else {
            speech.stop()
            return
        }
        saveProgress(paginator: paginator, size: size)
    }

    /// 滑动模式：按段朗读，读完自动往下滚，跨章连续
    private func speakNextScrollChunk() {
        guard let content, content.chapters.indices.contains(chapterIndex) else { return }
        let text = content.chapterText(at: chapterIndex)
        if scrollSpeechOffset >= text.length {
            if chapterIndex + 1 < content.chapterCount {
                chapterIndex += 1
                pageIndex = 0
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

    // MARK: - 翻页 / 进度

    private var currentScrollPage: Int {
        guard let content, content.chapters.indices.contains(chapterIndex) else { return 0 }
        let length = max(1, content.chapterText(at: chapterIndex).length)
        let ratio = Double(min(max(0, scrollProxy.characterIndex), length)) / Double(length)
        let pageCount = max(1, scrollProxy.lastPageCount)
        return min(pageCount - 1, max(0, Int(ratio * Double(pageCount))))
    }

    private var isCurrentBookmarked: Bool {
        let page = isScrollMode ? currentScrollPage : pageIndex
        return store.isBookmarked(bookID: bookID, chapterIndex: chapterIndex, pageIndex: page)
    }

    /// 翻页动效。`.scroll` 不会走到这里（那条路径整章连续滚动）。
    private var pageTransition: AnyTransition {
        switch settings.pageTurnStyle {
        case .curl:
            // 仿真：新页从右侧带着 3D 翻转进来，旧页向左退一点并压暗
            return turnDirection > 0
                ? .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                  )
                : .asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                  )
        case .cover:
            // 覆盖：新页滑入盖住旧页，旧页原地不动
            return turnDirection > 0
                ? .asymmetric(insertion: .move(edge: .trailing), removal: .identity)
                : .asymmetric(insertion: .move(edge: .leading), removal: .identity)
        case .slide:
            return turnDirection > 0
                ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
                : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
        case .scroll, .none:
            return .identity
        }
    }

    private var pageAnimation: Animation? {
        switch settings.pageTurnStyle {
        case .none, .scroll: return nil
        case .curl: return .easeInOut(duration: 0.34)
        case .cover: return .easeOut(duration: 0.26)
        case .slide: return .easeOut(duration: 0.24)
        }
    }

    /// 仿真翻页的 3D 效果（作用在整页容器上）
    private var page3DRotation: (angle: Double, anchor: UnitPoint, perspective: CGFloat) {
        guard settings.pageTurnStyle == .curl else { return (0, .center, 0) }
        // 新页从外侧略微折入，配合阴影形成翻书感
        return (turnDirection > 0 ? -8 : 8, turnDirection > 0 ? .trailing : .leading, 0.35)
    }

    private func goNext(paginator: Paginator, size: CGSize) {
        let count = paginator.pageCount(chapter: chapterIndex, size: size)
        if pageIndex + 1 < count {
            turnDirection = 1
            pageIndex += 1
        } else if chapterIndex + 1 < (content?.chapterCount ?? 0) {
            turnDirection = 1
            chapterIndex += 1
            pageIndex = 0
        }
        saveProgress(paginator: paginator, size: size)
    }

    private func goPrevious(paginator: Paginator, size: CGSize) {
        if pageIndex > 0 {
            turnDirection = -1
            pageIndex -= 1
        } else if chapterIndex > 0 {
            turnDirection = -1
            chapterIndex -= 1
            pageIndex = max(0, paginator.pageCount(chapter: chapterIndex, size: size) - 1)
        }
        saveProgress(paginator: paginator, size: size)
    }

    // MARK: - 自动阅读

    /// 每隔 `autoReadSpeed` 秒翻一页 / 滚一屏，读到全书末尾自动停。
    /// 用手势或点屏幕会打断它（见 body 的 simultaneousGesture）。
    private func startAutoRead(paginator: Paginator, size: CGSize) {
        stopAutoRead()
        autoReading = true
        // 自动阅读时不希望工具栏弹出来挡字
        withAnimation(.easeInOut(duration: 0.2)) { showChrome = false }
        UIApplication.shared.isIdleTimerDisabled = true

        autoReadTask = Task { @MainActor in
            while !Task.isCancelled {
                let seconds = max(3, settings.autoReadSpeed)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { return }
                guard autoReading else { return }

                if isScrollMode {
                    // 滚动模式：往下滚一屏（扣掉一点重叠，避免跳字）
                    let step = max(120, size.height * 0.86)
                    let moved = scrollProxy.scrollBy(step, animated: true)
                    if !moved {
                        // 到全书末尾了
                        stopAutoRead()
                        return
                    }
                } else {
                    let pageCount = paginator.pageCount(chapter: chapterIndex, size: size)
                    let isLastPage = pageIndex + 1 >= pageCount
                    let isLastChapter = chapterIndex + 1 >= (content?.chapterCount ?? 0)
                    if isLastPage && isLastChapter {
                        stopAutoRead()
                        return
                    }
                    goNext(paginator: paginator, size: size)
                }
            }
        }
    }

    private func stopAutoRead() {
        autoReadTask?.cancel()
        autoReadTask = nil
        if autoReading {
            autoReading = false
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        }
    }

    /// 切章。翻页模式按页走，滑动模式从头（或从末尾）开始
    private func chapterStep(_ delta: Int, paginator: Paginator, size: CGSize) {
        if isScrollMode {
            goChapterStart(delta)
        } else {
            let target = min(max(0, chapterIndex + delta), max(0, (content?.chapterCount ?? 1) - 1))
            turnDirection = delta > 0 ? 1 : -1
            chapterIndex = target
            pageIndex = 0
            saveProgress(paginator: paginator, size: size)
        }
    }

    /// 跳章。滑动模式下把锚点挪到目标章，让滚动容器重建窗口并定位过去。
    private func goChapterStart(_ delta: Int, atEnd: Bool = false) {
        guard let content else { return }
        let target = min(max(0, chapterIndex + delta), max(0, content.chapterCount - 1))
        turnDirection = delta > 0 ? 1 : -1
        chapterIndex = target
        pageIndex = 0
        scrollSpeechOffset = 0
        speechChapter = target
        speechBase = 0
        speechHighlight = nil
        pendingSpeechFrom = nil
        scrollAnchorChapter = target
        scrollAnchorChar = 0
        scrollProxy.chapter = target
        scrollProxy.characterIndex = 0
        refreshToken = UUID()
    }

    private func jumpToChapter(_ chapter: Int, paginator: Paginator, size: CGSize) {
        guard let content else { return }
        let target = min(max(0, chapter), max(0, content.chapterCount - 1))
        chapterIndex = target
        pageIndex = 0
        speechChapter = target
        speechBase = 0
        speechHighlight = nil
        pendingSpeechFrom = nil
        scrollAnchorChapter = target
        scrollAnchorChar = 0
        scrollProxy.chapter = target
        scrollProxy.characterIndex = 0
        scrollSpeechOffset = 0
        speechChapter = target
        speechBase = 0
        speechHighlight = nil
        pendingSpeechFrom = nil
        turnDirection = 1
        refreshToken = UUID()
    }

    private func jump(toChapter chapter: Int, page: Int) {
        guard let content else { return }
        let target = min(max(0, chapter), max(0, content.chapterCount - 1))
        chapterIndex = target
        pageIndex = max(0, page)
        if isScrollMode {
            // 书签记录的是「页」，这里换算成章内字符位置
            let text = content.chapterText(at: target)
            let pageCount = max(1, paginator?.pageCount(chapter: target, size: CGSize(width: 320, height: 480)) ?? 1)
            let ratio = pageCount > 1 ? Double(pageIndex) / Double(pageCount) : 0
            let char = min(text.length, max(0, Int(ratio * Double(text.length))))
            scrollAnchorChapter = target
            scrollAnchorChar = char
            scrollProxy.chapter = target
            scrollProxy.characterIndex = char
        }
        scrollSpeechOffset = 0
        speechChapter = target
        speechBase = 0
        speechHighlight = nil
        pendingSpeechFrom = nil
        refreshToken = UUID()
        showChapters = false
        showBookmarks = false
        if let paginator {
            let size = CGSize(width: 320, height: 480)
            let progress = paginator.progress(chapter: chapterIndex, page: pageIndex, size: size)
            store.updateReading(bookID: bookID, chapterIndex: chapterIndex, pageIndex: pageIndex, progress: progress)
        }
    }

    private func toggleBookmark(paginator: Paginator, size: CGSize) {
        if isScrollMode {
            let text = content?.chapterText(at: chapterIndex) ?? ""
            let start = max(0, min(scrollProxy.characterIndex, max(0, text.length - 1)))
            let length = min(60, max(0, text.length - start))
            let excerpt: String
            if length > 0 {
                excerpt = text.substring(with: NSRange(location: start, length: length))
                    .replacingOccurrences(of: "\n", with: " ")
            } else {
                excerpt = content?.chapterTitle(at: chapterIndex) ?? ""
            }
            store.toggleBookmark(
                bookID: bookID,
                chapterIndex: chapterIndex,
                pageIndex: currentScrollPage,
                excerpt: excerpt
            )
            return
        }
        let safePage = min(max(0, pageIndex), max(0, paginator.pageCount(chapter: chapterIndex, size: size) - 1))
        let page = paginator.page(chapter: chapterIndex, page: safePage, size: size)
        let excerpt = content?.excerpt(chapter: chapterIndex, range: page.range) ?? ""
        store.toggleBookmark(
            bookID: bookID,
            chapterIndex: chapterIndex,
            pageIndex: pageIndex,
            excerpt: excerpt
        )
    }

    private func saveProgress(paginator: Paginator, size: CGSize) {
        let progress = paginator.progress(chapter: chapterIndex, page: pageIndex, size: size)
        store.updateReading(
            bookID: bookID,
            chapterIndex: chapterIndex,
            pageIndex: pageIndex,
            progress: progress,
            scrollRatio: nil
        )
    }

    private func persistScrollProgress(chapter: Int, charIndex: Int, throttled: Bool) {
        guard let content, content.chapters.indices.contains(chapter) else { return }
        if throttled, Date().timeIntervalSince(scrollProxy.lastSaveAt) < 1.5 { return }
        scrollProxy.lastSaveAt = Date()

        let length = max(1, content.chapterText(at: chapter).length)
        let ratio = Double(min(max(0, charIndex), length)) / Double(length)
        let pageCount = max(1, scrollProxy.lastPageCount)
        let page = min(pageCount - 1, max(0, Int(ratio * Double(pageCount))))
        let absolute = content.chapters[chapter].location + max(0, charIndex)
        let progress = content.totalLength > 0
            ? min(1, max(0, Double(absolute) / Double(content.totalLength)))
            : 0
        store.updateReading(
            bookID: bookID,
            chapterIndex: chapter,
            pageIndex: page,
            progress: progress,
            scrollRatio: ratio
        )
    }

    private func prepare() {
        guard let loaded = store.content(for: bookID) else {
            loadFailed = true
            return
        }
        let engine = Paginator(content: loaded, settings: settings)
        content = loaded
        paginator = engine
        chapterIndex = min(max(0, store.book(bookID)?.lastChapterIndex ?? 0), max(0, loaded.chapterCount - 1))
        pageIndex = max(0, store.book(bookID)?.lastPageIndex ?? 0)
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
        if args.contains("--page") { settings.readingMode = .page }
        if args.contains("--scroll") { settings.readingMode = .scroll }
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
        if args.contains("--tint-brown") { settings.textTint = .brown }
        if args.contains("--tint-cream") { settings.textTint = .cream }
        if let i = args.firstIndex(of: "--turn"), i + 1 < args.count,
           let style = PageTurnStyle(rawValue: args[i + 1]) {
            settings.pageTurnStyle = style
        }
    }
}
