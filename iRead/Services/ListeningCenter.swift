import Foundation
import Combine
import MediaPlayer
import os

/// 全局听书中心。
///
/// 以前的朗读游标（听到第几章第几个字）和「下一段读什么」都放在阅读页里，
/// 于是听书天然绑死在 ReaderView 上：退出阅读页就停，打开另一本书会抢占朗读。
/// 这里把这些状态收进单例，阅读页退化成「只负责把高亮贴回正文」的显示层。
///
/// 对外语义：
/// - `resume(bookID:)` 接着上次的朗读记录读；没有记录才用阅读进度兜底
/// - `play(bookID:chapter:char:)` 显式从某处开始（长按选句、播放器切章）
/// - 听书位置与阅读位置是两套记录，互不覆盖，因此可以「听 A 看 B」
final class ListeningCenter: ObservableObject {
    static let shared = ListeningCenter()

    // MARK: - 对外状态

    /// 正在听的书的 id；nil 表示没有在听（迷你条隐藏）
    @Published private(set) var bookID: String?
    @Published private(set) var bookTitle = ""
    @Published private(set) var author = ""
    @Published private(set) var coverHue: Double = 0.06
    @Published private(set) var chapterIndex = 0
    @Published private(set) var chapterTitle = ""
    @Published private(set) var chapterCount = 0
    /// 当前朗读句子所在的章
    @Published private(set) var spokenChapter = 0
    /// 当前朗读的句子区间（**章内坐标**），供阅读页贴高亮
    @Published private(set) var spokenRange: NSRange?
    /// 当前朗读位置（章内字符），供阅读页把视口带到起点
    @Published private(set) var currentChar = 0
    /// 本章听读进度 0...1
    @Published private(set) var chapterProgress: Double = 0

    // SpeechService 的状态镜像：直接观察它会让每个视图都多一个依赖，
    // 这里统一转成听书中心自己的属性，界面只认这一份。
    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var activeEngine: SpeechEngineKind = .system

    var isPlayingSomething: Bool { bookID != nil }
    /// 已经选好了书、但还没开始播：播放器和悬浮胶囊都显示「播放」，不显示「暂停」
    var isIdle: Bool { bookID != nil && !isActive }

    // MARK: - 打开阅读页跟读

    /// 听书组件请求打开某本书的阅读页（由 ContentView 消费）
    @Published private(set) var readerRequest: String?

    /// 阅读页是否处于「跟读」状态。
    /// 这是**持久状态**而非一次性标志：sheet 收起 + fullScreenCover 重建时
    /// SwiftUI 可能多次创建 ReaderView，一次性标志会被第一个实例吃掉。
    @Published private(set) var isFollowAlong = false

    /// 「边听边读」：关掉播放器，打开真正的阅读界面并跟随朗读
    func requestFollowAlong(bookID id: String) {
        isFollowAlong = true
        readerRequest = id
    }

    func consumeReaderRequest() -> String? {
        defer { readerRequest = nil }
        return readerRequest
    }

    /// 退出跟读（听书停止 / 读完时调用）
    func endFollowAlong() {
        isFollowAlong = false
    }

    /// 本章剩余进度（播放器进度条用）
    var overallProgress: Double {
        guard chapterCount > 0 else { return 0 }
        return min(1, max(0, (Double(chapterIndex) + chapterProgress) / Double(chapterCount)))
    }
    var engineName: String { activeEngine == .piper ? "本地神经语音" : "系统语音" }

    private let speech = SpeechService.shared
    private let store = LibraryStore.shared
    private let settings = ReaderSettings.shared
    private let log = Logger(subsystem: "com.yingyang.iread", category: "Listening")

    private var content: BookContent?
    /// 本章下一个待读字符
    private var offset = 0
    /// 当前这一段（chunk）在章内的起点，引擎回调的区间是相对它的
    private var base = 0
    /// 当前正在念的句子在章内的起点：改语速/音色后从这里重读
    private var sentenceStart = 0
    /// 暂停期间改过语速/音色，等继续时再生效
    private var pendingSettingsRestart = false
    /// 两段之间的空档里按了暂停：下一段先别念，等继续时再补上
    private var pendingChunk = false
    private var bag = Set<AnyCancellable>()

    private init() {
        speech.$isActive
            .receive(on: DispatchQueue.main)
            .assign(to: &$isActive)
        speech.$isPaused
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPaused)
        speech.$isSpeaking
            .receive(on: DispatchQueue.main)
            .assign(to: &$isSpeaking)
        speech.$isPreparingModel
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPreparingModel)
        speech.$activeEngine
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeEngine)

        speech.$spokenRange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] range in self?.consumeSpokenRange(range) }
            .store(in: &bag)

        // 播放/暂停要同步到锁屏，否则锁屏按钮和真实状态会对不上
        speech.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateNowPlaying() }
            .store(in: &bag)
        speech.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateNowPlaying() }
            .store(in: &bag)

        // 语速 / 音色在播放中调整：从当前这句重读，别回到本章开头。
        // 拖滑块会连续触发，debounce 一下避免反复掐断音频。
        settings.$speechRate
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartCurrentSentence() }
            .store(in: &bag)
        settings.$voiceProfile
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartCurrentSentence() }
            .store(in: &bag)

        configureRemoteCommands()
    }

    // MARK: - 开始 / 停止

    /// 只把书装进听书组件并定位到续读点，**不发声**。
    ///
    /// 所有 UI 入口（悬浮「听」球、书架长按、阅读页喇叭、选书/选章）都走这里；
    /// 真正的播放只由播放器里的播放按钮触发。这样「点开听书」和「开始朗读」是两件事。
    func prepare(bookID id: String, fallbackChapter: Int? = nil, fallbackChar: Int? = nil) {
        guard let content = store.content(for: id), content.chapterCount > 0,
              let book = store.book(id) else { return }
        // 已经选中的就是这本：别打断正在播的声音，也别把位置拨回去
        if bookID == id { return }

        if isActive { halt() }
        attach(book: book, content: content)

        let target = resumeTarget(
            content: content,
            book: book,
            fallbackChapter: fallbackChapter,
            fallbackChar: fallbackChar
        )
        let text = content.chapterText(at: target.chapter)
        let char = min(max(0, target.char), text.length)
        seek(chapter: target.chapter, char: char, persist: false)
        store.setSpeechPosition(bookID: id, chapter: target.chapter, char: char)
        log.notice("prepare book=\(String(id.prefix(6)), privacy: .public) ch=\(target.chapter, privacy: .public) char=\(char, privacy: .public) idle")
        updateNowPlaying()
    }

    /// 从当前选好的位置开始播（播放器/悬浮胶囊的播放按钮）
    func start() {
        guard bookID != nil, !isActive, let content,
              content.chapters.indices.contains(chapterIndex) else { return }
        let length = content.chapterText(at: chapterIndex).length
        begin(chapter: chapterIndex, char: min(max(0, offset), length), snapToParagraph: false)
    }

    /// 选章 / 选句：正在播就立刻切过去，还没播就只挪游标（等用户按播放）
    func seekTo(chapter: Int, char: Int, snapToParagraph: Bool = false) {
        guard let id = bookID, content != nil else { return }
        if isActive {
            play(bookID: id, chapter: chapter, char: char, snapToParagraph: snapToParagraph)
        } else {
            locate(chapter: chapter, char: char)
        }
    }

    /// 只定位，绝不改变播放状态（阅读页长按选句：把起点交给听书组件）
    func locate(chapter: Int, char: Int) {
        guard let content, content.chapters.indices.contains(chapter), bookID != nil else { return }
        let length = content.chapterText(at: chapter).length
        seek(chapter: chapter, char: min(max(0, char), length), persist: true)
        updateNowPlaying()
    }

    /// 只挪游标，不碰音频
    private func seek(chapter: Int, char: Int, persist: Bool) {
        guard let content, content.chapters.indices.contains(chapter), let id = bookID else { return }
        let text = content.chapterText(at: chapter)
        let start = min(max(0, char), text.length)
        chapterIndex = chapter
        offset = start
        base = start
        sentenceStart = start
        currentChar = start
        spokenChapter = chapter
        spokenRange = nil
        chapterProgress = Double(start) / Double(max(1, text.length))
        updateChapterMeta()
        if persist { store.setSpeechPosition(bookID: id, chapter: chapter, char: start) }
    }

    /// 接着上次的朗读记录读。没有记录时用阅读进度兜底，
    /// 再没有就用调用方给的位置（阅读页传当前视口）。
    /// 自动化自测用；UI 入口一律走 prepare + start，避免「点一下就出声」。
    func resume(bookID id: String, fallbackChapter: Int? = nil, fallbackChar: Int? = nil) {
        guard let content = store.content(for: id), content.chapterCount > 0,
              let book = store.book(id) else { return }
        log.notice("resume book=\(String(id.prefix(6)), privacy: .public) fallback=\(fallbackChapter ?? -1, privacy: .public)/\(fallbackChar ?? -1, privacy: .public)")
        attach(book: book, content: content)
        let target = resumeTarget(
            content: content,
            book: book,
            fallbackChapter: fallbackChapter,
            fallbackChar: fallbackChar
        )
        begin(chapter: target.chapter, char: target.char, snapToParagraph: false)
    }

    /// 显式从某处开始（长按选句、播放器切章）
    func play(bookID id: String, chapter: Int, char: Int, snapToParagraph: Bool = false) {
        guard let content = store.content(for: id), content.chapterCount > 0,
              let book = store.book(id) else { return }
        attach(book: book, content: content)
        begin(chapter: chapter, char: char, snapToParagraph: snapToParagraph)
    }

    func pause() { speech.pause() ; updateNowPlaying() }

    func resumePlayback() {
        // 暂停期间改过语速/音色：按新设置从当前这句重来，而不是接着用旧语速念
        if pendingSettingsRestart, let id = bookID, isActive {
            pendingSettingsRestart = false
            pendingChunk = false
            play(bookID: id, chapter: chapterIndex, char: sentenceStart)
            updateNowPlaying()
            return
        }
        speech.resume()
        // 暂停按在两段之间的空档里：上一段其实已经念完了，continueSpeaking 接不上，
        // 这里补念下一段（start 内部会先 halt，不会和残留音频叠在一起）
        if pendingChunk, isActive, bookID != nil {
            pendingChunk = false
            speakNextChunk()
        }
        updateNowPlaying()
    }

    func toggle() {
        guard speech.isActive else {
            start()
            return
        }
        // 必须走自己的 pause()/resumePlayback()：直接调 speech.toggle() 会绕开
        // 「暂停期间改的语速/音色」和「空档里按下的暂停」，这两笔账都要在恢复时还上
        if isPaused {
            resumePlayback()
        } else {
            pause()
        }
    }

    /// 彻底退出听书：迷你条消失，但朗读记录保留，下次还能接着听
    func stop() {
        guard bookID != nil || speech.isActive else { return }
        halt()
        bookID = nil
        bookTitle = ""
        author = ""
        chapterTitle = ""
        chapterCount = 0
        chapterIndex = 0
        chapterProgress = 0
        currentChar = 0
        spokenRange = nil
        content = nil
        endFollowAlong()
        updateNowPlaying()
    }

    // MARK: - 章节

    /// 切章：正在播才换段出声；待播放时只把游标挪过去，等用户按播放
    func nextChapter() {
        guard let id = bookID, chapterIndex + 1 < chapterCount else { return }
        let target = chapterIndex + 1
        if isActive {
            play(bookID: id, chapter: target, char: 0)
        } else {
            seek(chapter: target, char: 0, persist: true)
            updateNowPlaying()
        }
    }

    func previousChapter() {
        guard let id = bookID else { return }
        // 已经听了一段就重听本章开头，否则退到上一章（和常见播放器一致）
        let target = (chapterProgress > 0.04 || chapterIndex == 0)
            ? chapterIndex : max(0, chapterIndex - 1)
        if isActive {
            play(bookID: id, chapter: target, char: 0)
        } else {
            seek(chapter: target, char: 0, persist: true)
            updateNowPlaying()
        }
    }

    // MARK: - 内部

    private func attach(book: Book, content: BookContent) {
        let switching = bookID != book.id
        bookID = book.id
        bookTitle = book.title
        author = book.displayAuthor
        coverHue = book.coverHue
        chapterCount = content.chapterCount
        if switching {
            chapterIndex = min(max(0, book.lastChapterIndex), max(0, content.chapterCount - 1))
            chapterProgress = 0
            spokenRange = nil
        }
        self.content = content
    }

    private func begin(chapter: Int, char: Int, snapToParagraph: Bool) {
        guard let content, content.chapters.indices.contains(chapter), let id = bookID else { return }
        let text = content.chapterText(at: chapter)
        let start = snapToParagraph
            ? Self.paragraphStart(in: text, char: char)
            : min(max(0, char), text.length)

        chapterIndex = chapter
        offset = start
        base = start
        sentenceStart = start
        currentChar = start
        chapterProgress = Double(start) / Double(max(1, text.length))
        spokenChapter = chapter
        spokenRange = nil
        updateChapterMeta()
        store.setSpeechPosition(bookID: id, chapter: chapter, char: start)
        log.notice("begin ch=\(chapter, privacy: .public) char=\(start, privacy: .public) snap=\(snapToParagraph, privacy: .public)")
        #if DEBUG
        print("[Listening] begin book=\(id.prefix(8)) ch=\(chapter) char=\(start) snap=\(snapToParagraph)")
        #endif
        speakNextChunk()
    }

    /// 按段朗读：读满约 260 字或到句末收尾，读完自动跨章
    private func speakNextChunk() {
        guard let content, let id = bookID, content.chapters.indices.contains(chapterIndex) else {
            halt()
            return
        }
        let text = content.chapterText(at: chapterIndex)
        if offset >= text.length {
            if chapterIndex + 1 < content.chapterCount {
                chapterIndex += 1
                offset = 0
                base = 0
                sentenceStart = 0
                currentChar = 0
                chapterProgress = 0
                spokenChapter = chapterIndex
                spokenRange = nil
                updateChapterMeta()
                store.setSpeechPosition(bookID: id, chapter: chapterIndex, char: 0)
                // 跨章留一点气口，避免上一章最后一句和下一章标题黏在一起
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isActive, self.bookID == id else { return }
                    self.speakNextChunk()
                }
            } else {
                finishBook()
            }
            return
        }

        let start = max(0, offset)
        let (chunk, next) = Self.chunk(in: text, from: start)
        guard !chunk.isEmpty else {
            offset = text.length
            speakNextChunk()
            return
        }
        offset = next
        base = start
        chapterProgress = Double(start) / Double(max(1, text.length))

        speech.onAdvance = { [weak self] in
            guard let self else { return }
            // 上一段念完时用户其实是暂停状态（按在两段之间的空档里）：
            // 先别开下一段，否则「暂停」这键就被下一段吞了
            if self.isPaused {
                self.pendingChunk = true
                return
            }
            self.speakNextChunk()
        }
        speech.start(text: chunk, rate: settings.speechRate, profile: settings.voiceProfile)
        log.notice("chunk ch=\(self.chapterIndex, privacy: .public) start=\(start, privacy: .public) next=\(next, privacy: .public)")
        updateNowPlaying()
    }

    /// 全书读完：清掉续读记录，下次播放从头开始
    private func finishBook() {
        let id = bookID
        halt()
        if let id { store.clearSpeechPosition(bookID: id) }
        chapterIndex = 0
        offset = 0
        base = 0
        chapterProgress = 0
        currentChar = 0
        spokenRange = nil
        bookID = nil
        endFollowAlong()
        updateNowPlaying()
    }

    private func halt() {
        speech.onAdvance = nil
        pendingSettingsRestart = false
        pendingChunk = false
        speech.stop()
    }

    /// 语速/音色变化：只重读当前这句。
    /// 暂停中改了设置不能立即重读（会突然出声），先记下来等「继续」时按新设置从这句起。
    private func restartCurrentSentence() {
        guard bookID != nil, isActive else { return }
        if isPaused {
            pendingSettingsRestart = true
            log.notice("settings changed while paused, will restart on resume")
            return
        }
        let chapter = chapterIndex
        let char = sentenceStart
        log.notice("restart sentence=\(char, privacy: .public) rate=\(self.settings.speechRate, privacy: .public) voice=\(self.settings.voiceProfile.rawValue, privacy: .public)")
        play(bookID: bookID!, chapter: chapter, char: char)
    }

    private func updateChapterMeta() {
        guard let content else { return }
        chapterTitle = content.chapterTitle(at: chapterIndex)
        chapterCount = content.chapterCount
    }

    private func consumeSpokenRange(_ range: NSRange?) {
        guard isActive, let range, range.length > 0,
              let content, content.chapters.indices.contains(chapterIndex) else {
            if spokenRange != nil { spokenRange = nil }
            return
        }
        let absolute = NSRange(location: base + range.location, length: range.length)
        if absolute != spokenRange {
            spokenRange = absolute
        }
        spokenChapter = chapterIndex
        sentenceStart = absolute.location
        currentChar = absolute.location
        let length = max(1, content.chapterText(at: chapterIndex).length)
        chapterProgress = Double(min(absolute.location, length)) / Double(length)
        if let id = bookID {
            store.setSpeechPosition(bookID: id, chapter: chapterIndex, char: absolute.location)
        }
    }

    private func resumeTarget(
        content: BookContent,
        book: Book,
        fallbackChapter: Int?,
        fallbackChar: Int?
    ) -> (chapter: Int, char: Int) {
        let lastChapter = content.chapterCount - 1
        if let r = store.speechPosition(for: book.id), content.chapters.indices.contains(r.chapter) {
            let length = content.chapterText(at: r.chapter).length
            if r.char < length { return (r.chapter, r.char) }
            // 记录停在章末：接着读下一章；已经是最后一章就从书首重新开始
            return r.chapter < lastChapter ? (r.chapter + 1, 0) : (0, 0)
        }
        if let ch = fallbackChapter, content.chapters.indices.contains(ch) {
            let length = content.chapterText(at: ch).length
            return (ch, min(max(0, fallbackChar ?? 0), length))
        }
        let chapter = min(max(0, book.lastChapterIndex), lastChapter)
        let length = content.chapterText(at: chapter).length
        let ratio = min(1, max(0, book.lastScrollRatio ?? 0))
        return (chapter, min(length, max(0, Int(ratio * Double(length)))))
    }

    // MARK: - 文本切分

    /// 段落起点：上一个换行符之后
    static func paragraphStart(in text: NSString, char: Int) -> Int {
        guard text.length > 0 else { return 0 }
        var i = min(max(0, char), text.length - 1)
        while i > 0 {
            if text.substring(with: NSRange(location: i - 1, length: 1)) == "\n" { break }
            i -= 1
        }
        return i
    }

    /// 从 offset 起取一小段（约 260 字），尽量在句末或段末收尾
    static func chunk(in text: NSString, from offset: Int) -> (String, Int) {
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
        return (text.substring(with: NSRange(location: offset, length: max(0, cut - offset))), cut)
    }

    // MARK: - 锁屏 / 控制中心

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.resumePlayback() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.nextChapter() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previousChapter() }
            return .success
        }
    }

    /// 锁屏/控制中心展示。没有精确音频时长，只给曲目信息与播放状态，
    /// 不填 duration 避免出现一条乱跳的进度条。
    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let id = bookID, !id.isEmpty else {
            center.nowPlayingInfo = nil
            MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = false
            MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = false
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: bookTitle,
            MPMediaItemPropertyArtist: author,
            MPMediaItemPropertyAlbumTitle: chapterTitle,
            MPNowPlayingInfoPropertyPlaybackRate: (speech.isActive && !speech.isPaused) ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let content {
            let chapterLength = content.chapterText(at: chapterIndex).length
            let chapterElapsed = Int(chapterProgress * Double(chapterLength))
            // 估算时长：中文 TTS 正常语速约 5.5 字/秒。只用于锁屏进度展示。
            let total = Double(content.totalLength) * 0.18
            let absolute = content.chapters.indices.contains(chapterIndex)
                ? content.chapters[chapterIndex].location + chapterElapsed
                : 0
            info[MPMediaItemPropertyPlaybackDuration] = max(1, total)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = min(total, Double(absolute) * 0.18)
        }
        center.nowPlayingInfo = info
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = chapterIndex + 1 < chapterCount
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = true
    }
}
