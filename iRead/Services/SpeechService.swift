import Foundation
import AVFoundation
import os

/// 听书引擎。两条路径：
///
/// - `.piper`：随 App 打包的 Piper VITS 中文神经语音，本地推理、完全离线、音质接近真人。
///   内部按句切分做流水线合成：第 N 句在播时，第 N+1 句已在后台合成，避免句间长停顿。
/// - `.system`：系统 `AVSpeechSynthesizer`，音色可选、资源占用低，作为兜底。
///
/// 对上层（ReaderView）暴露的接口保持一致：`start(text:rate:profile:)`
/// + `onAdvance` 回调请求下一段内容，形成连续听书。
///
/// 音色由 `VoiceProfile` 三档决定：女声（内置神经）/ 男声（系统）/ 粤语（系统 zh-HK）。
/// 男声与粤语复用系统语音，因此不增加 App 体积；粤语缺失时自动退回普通话男声。
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    /// 处于听书模式（开启后即使暂停也算，用于界面显示）
    @Published private(set) var isActive = false
    /// 已暂停
    @Published private(set) var isPaused = false
    /// 正在发声（含句间合成的短暂间隙）
    @Published private(set) var isSpeaking = false
    /// 首次加载本地模型（60MB，约 1 秒），用于界面提示
    @Published private(set) var isPreparingModel = false
    /// 实际生效的引擎（Piper 不可用时会自动降级为系统语音）
    @Published private(set) var activeEngine: SpeechEngineKind = .system
    /// 当前读到哪儿了 —— 相对于本次 `start(text:)` 传入字符串的区间。
    /// 上层据此在正文上画高亮，让人一眼看到读到了哪里。
    @Published private(set) var spokenRange: NSRange?

    /// 当前内容读完后请求下一段，由 ReaderView 设置
    var onAdvance: (() -> Void)?

    private let log = Logger(subsystem: "com.yingyang.iread", category: "Speech")

    // MARK: 系统语音
    private let synthesizer = AVSpeechSynthesizer()

    // MARK: 本地神经语音播放管线
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioReady = false
    private var pcmFormat: AVAudioFormat?
    /// 本次朗读的句子队列
    private var sentences: [String] = []
    /// 每句在原文里的区间，与 `sentences` 一一对应
    private var sentenceRanges: [NSRange] = []
    /// 已排进播放器的句子区间（按播放顺序）
    private var bufferRanges: [NSRange] = []
    /// 流水线计数（均在主线程读写）
    private var scheduledCount = 0
    private var playedCount = 0
    private var producerFinished = true
    /// 每次朗读递增；旧流水线的回调凭令牌自动失效
    private var runToken = 0

    private var currentSpeed: Float = 1.0
    private var currentProfile: VoiceProfile = .neuralFemale
    private var currentRate: Double = 0.5

    override init() {
        super.init()
        synthesizer.delegate = self
        activateAudioSession()
        observeInterruptions()
    }

    // MARK: - 音色

    /// 可选的中文音色，音质高的排前面（增强 > 标准）
    static func chineseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.language < $1.language
            }
    }

    /// 按 identifier 解析音色；找不到时回退到系统默认中文音色
    static func voice(for identifier: String) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let v = AVSpeechSynthesisVoice(identifier: identifier) {
            return v
        }
        return chineseVoices().first { $0.language == "zh-CN" }
            ?? chineseVoices().first
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    /// 本地神经语音是否可用（模型资源已打包）
    static var isPiperAvailable: Bool { PiperSynthesizer.shared.isAvailable }

    /// 中文男声。iOS 的中文男声是 Li-mu 系列，不同系统版本命名略有差异，
    /// 这里按「已知男声关键词 → 排除已知女声 → 兜底」三级策略挑。
    /// - Note: 实测 iOS 26 上**没有任何中文男声**，此方法会回落到女声。
    ///   因此「男声」档改走内置 Piper 模型，此方法仅作为兼容保留。
    static func maleChineseVoice() -> AVSpeechSynthesisVoice? {
        let mandarin = chineseVoices().filter { $0.language == "zh-CN" || $0.language.hasPrefix("zh-Hans") }
        let pool = mandarin.isEmpty ? chineseVoices() : mandarin
        let maleHints = ["li-mu", "limu", "li mu", "yunxi", "yunyang", "kangkang", "male"]
        for hint in maleHints {
            if let v = pool.first(where: { $0.name.lowercased().contains(hint) }) { return v }
            if let v = pool.first(where: { $0.identifier.lowercased().contains(hint) }) { return v }
        }
        return nil
    }

    /// 系统默认中文音色（降级兜底用）
    static func defaultChineseVoice() -> AVSpeechSynthesisVoice? {
        chineseVoices().first { $0.language == "zh-CN" }
            ?? chineseVoices().first
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    /// 粤语音色（系统 yue-HK，通常是 Sinji）。
    /// 注意：iOS 上粤语的 language 实际是 `yue-HK`，不是 `zh-HK`，两种都要认。
    static func cantoneseVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let yue = all.filter {
            let l = $0.language.lowercased()
            return l.hasPrefix("zh-hk") || l.hasPrefix("yue")
        }
        return yue.first { $0.quality == .enhanced }
            ?? yue.first { $0.quality == .premium }
            ?? yue.first
    }

    /// 粤语音色是否可用（系统未安装时可提示用户去设置里下载）
    static var isCantoneseAvailable: Bool { cantoneseVoice() != nil }

    /// 把音色档位解析成实际使用的系统音色。
    /// 女声/男声走内置模型，不需要系统音色，故返回 nil。
    static func voice(for profile: VoiceProfile) -> AVSpeechSynthesisVoice? {
        profile == .cantonese ? cantoneseVoice() : nil
    }

    /// 内置模型是否可用
    static func isPiperAvailable(_ model: PiperModel) -> Bool {
        PiperSynthesizer.shared.isAvailable(model)
    }

    // MARK: - 播放控制

    /// 朗读一段文本。已处于听书模式时再次调用会替换当前内容（用于翻页/换段/改语速）。
    func start(text: String, rate: Double, profile: VoiceProfile) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activateAudioSession()
        haltPlayback()

        isActive = true
        isPaused = false
        currentRate = rate

        guard !trimmed.isEmpty else {
            isSpeaking = false
            // 空内容没有可读文本，直接请求下一段，避免听书中断
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else { return }
                self.onAdvance?()
            }
            return
        }

        // 粤语音色没装时退回内置男声，至少不会哑掉
        var resolved = profile
        if profile == .cantonese && !Self.isCantoneseAvailable {
            log.error("cantonese voice unavailable, falling back to built-in male")
            resolved = .neuralMale
        }

        currentProfile = resolved

        if let model = resolved.piperModel {
            // 该档位的内置模型缺失时降级到系统中文音色
            if !Self.isPiperAvailable(model) {
                log.error("piper model \(model.rawValue, privacy: .public) unavailable, falling back to system voice")
                activeEngine = .system
                startSystem(trimmed, rate: rate, voice: Self.defaultChineseVoice())
                return
            }
            activeEngine = .piper
            startPiper(trimmed, rate: rate, model: model)
        } else {
            activeEngine = .system
            startSystem(trimmed, rate: rate, voice: Self.voice(for: resolved))
        }
    }

    func pause() {
        guard isActive, !isPaused else { return }
        if activeEngine == .piper {
            player.pause()
        } else {
            synthesizer.pauseSpeaking(at: .word)
        }
        isPaused = true
    }

    func resume() {
        guard isActive, isPaused else { return }
        if activeEngine == .piper {
            ensureAudioEngine()
            if !player.isPlaying { player.play() }
            isPaused = false
            // 若恰好在最后一句末尾暂停，恢复时不会再有播放回调，这里补一次收尾判断
            checkFinished(token: runToken)
            return
        }
        synthesizer.continueSpeaking()
        isPaused = false
    }

    func toggle() {
        isPaused ? resume() : pause()
    }

    func stop() {
        guard isActive else { return }
        haltPlayback()
        isActive = false
        isPaused = false
        isSpeaking = false
        onAdvance = nil
    }

    /// 立即静音并作废在途合成，但不改变 isActive（供换段/翻页复用）
    private func haltPlayback() {
        runToken &+= 1
        producerFinished = true
        sentences = []
        sentenceRanges = []
        bufferRanges = []
        scheduledCount = 0
        playedCount = 0
        spokenRange = nil
        if audioReady {
            player.stop()
        }
        synthesizer.stopSpeaking(at: .immediate)
        PiperSynthesizer.shared.cancelPending()
    }

    // MARK: - 系统语音路径

    private func startSystem(_ text: String, rate: Double, voice: AVSpeechSynthesisVoice?) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(min(max(rate, 0.1), 1.0))
        utterance.pitchMultiplier = 1.0
        // 标点停顿交给系统朗读引擎（它会按逗号/句号自然停顿）
        utterance.postUtteranceDelay = 0.25
        utterance.voice = voice ?? Self.defaultChineseVoice()
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    // MARK: - 本地神经语音路径

    private func startPiper(_ text: String, rate: Double, model: PiperModel) {
        // 系统语速 0.5 约等于正常语速，映射到 Piper 的 1.0 倍
        currentSpeed = Float(min(max(rate / 0.5, 0.6), 2.0))
        sentences = Self.splitForPiper(text, softBreak: model.usesLexicon)
        sentenceRanges = Self.ranges(of: sentences)
        bufferRanges = []
        scheduledCount = 0
        playedCount = 0
        producerFinished = false
        spokenRange = nil
        isSpeaking = true

        let token = runToken
        let needLoad = !PiperSynthesizer.shared.isReady(model)
        if needLoad { isPreparingModel = true }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // 首次加载模型（男声 18MB / 女声 60MB），约 0.3~1 秒；失败则整体降级
            let ok = PiperSynthesizer.shared.loadIfNeeded(model)
            DispatchQueue.main.async {
                guard token == self.runToken else { return }
                self.isPreparingModel = false
                guard ok else {
                    self.log.error("piper load failed: \(PiperSynthesizer.shared.errorDescription ?? "-", privacy: .public)")
                    self.activeEngine = .system
                    self.startSystem(text, rate: rate, voice: Self.defaultChineseVoice())
                    return
                }
                self.ensureAudioEngine()
                self.runPipeline(token: token, model: model)
            }
        }
    }

    /// 串行流水线：逐句合成，合成好一句就排进播放器。
    /// 第 N 句播放期间第 N+1 句正在合成，因此句间几乎无停顿。
    ///
    /// 注意：每句合成完会**按句尾标点补一段静音**再排进播放器。
    /// 因为 Piper 是逐句独立合成的，句与句之间本来没有停顿，
    /// 直接拼接会听起来像「一口气念到底」，这正是补静音要解决的问题。
    private func runPipeline(token: Int, model: PiperModel) {
        let queue = sentences
        let ranges = sentenceRanges
        let speed = currentSpeed

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for (i, text) in queue.enumerated() {
                // 令牌失效（用户停止/换段）就提前退出
                if PiperSynthesizer.shared.currentToken() != token { return }
                guard let result = PiperSynthesizer.shared.synthesize(
                    text: text, speed: speed, model: model, token: token
                ) else { continue }
                let samples = result.samples + Self.trailingSilence(for: text, sampleRate: result.sampleRate)
                let range = i < ranges.count ? ranges[i] : NSRange(location: 0, length: 0)
                DispatchQueue.main.async {
                    guard token == self.runToken else { return }
                    self.enqueue(samples, sampleRate: result.sampleRate, token: token, range: range)
                }
            }
            DispatchQueue.main.async {
                guard token == self.runToken else { return }
                self.producerFinished = true
                self.checkFinished(token: token)
            }
        }
    }

    /// 句子在原文里的字符区间（按顺序累加，切句不丢字符）
    private static func ranges(of sentences: [String]) -> [NSRange] {
        var out: [NSRange] = []
        var location = 0
        for sentence in sentences {
            let length = (sentence as NSString).length
            out.append(NSRange(location: location, length: length))
            location += length
        }
        return out
    }

    /// 按句尾标点决定停顿长度（秒）。这是让听感「有断句」的关键。
    static func trailingSilence(for text: String, sampleRate: Int32) -> [Float] {
        let tail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = tail.last else { return [] }
        let seconds: Double
        switch last {
        case "。":            seconds = 0.42
        case "！", "!":       seconds = 0.50
        case "？", "?":       seconds = 0.50
        case "…", "⋯":        seconds = 0.55
        case "；", ";":       seconds = 0.30
        case "：", ":":       seconds = 0.22
        case "，", ",", "、": seconds = 0.18
        case "\n":            seconds = 0.55
        case "\"", "”", "」": seconds = 0.40
        default:              seconds = 0.22
        }
        let count = Int(Double(sampleRate) * seconds)
        guard count > 0 else { return [] }
        return [Float](repeating: 0, count: count)
    }

    private func enqueue(_ samples: [Float], sampleRate: Int32, token: Int, range: NSRange) {
        guard token == runToken else { return }
        guard let format = pcmFormat, Int32(format.sampleRate) == sampleRate else {
            log.error("sample rate mismatch: got \(sampleRate, privacy: .public)")
            return
        }
        let frames = AVAudioFrameCount(samples.count)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return }

        buffer.frameLength = frames
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }

        bufferRanges.append(range)
        scheduledCount += 1
        // 第一句一进队列就点亮，避免开头几秒没有高亮
        if scheduledCount == 1, range.length > 0 { spokenRange = range }
        if !player.isPlaying && !isPaused { player.play() }

        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self, token == self.runToken else { return }
                self.playedCount += 1
                // 上一句播完 = 下一句开始，此时切高亮刚好跟上人声
                if self.playedCount < self.bufferRanges.count {
                    let next = self.bufferRanges[self.playedCount]
                    if next.length > 0 { self.spokenRange = next }
                }
                self.checkFinished(token: token)
            }
        }
    }

    private func checkFinished(token: Int) {
        guard token == runToken, isActive, !isPaused else { return }
        guard producerFinished, playedCount >= scheduledCount else { return }
        isSpeaking = false
        onAdvance?()
    }

    private func ensureAudioEngine() {
        guard !audioReady else {
            if !audioEngine.isRunning { try? audioEngine.start() }
            return
        }
        let rate = PiperSynthesizer.shared.outputSampleRate
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(rate),
            channels: 1,
            interleaved: false
        ) else {
            log.error("cannot create pcm format")
            return
        }
        pcmFormat = format
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()
        do {
            try audioEngine.start()
            audioReady = true
        } catch {
            log.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 按中文标点切句，兼顾长度上限，保证单句合成延迟足够低。
    ///
    /// - Parameter softBreak: 是否把逗号/顿号/冒号也当作断句点。
    ///   走词典的音素化模型（男声超文）词典里**没有任何标点**，逗号会被直接丢弃，
    ///   导致长句失去内部停顿、听起来「一口气念完」。此时必须靠切句把停顿补回来。
    ///   走 espeak 的模型（女声花颜）能自己处理标点，不需要切这么碎。
    static func splitForPiper(_ text: String, softBreak: Bool) -> [String] {
        var out: [String] = []
        var current = ""
        let stops: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…", "\n"]
        let softs: Set<Character> = ["，", ",", "、", "：", ":"]
        /// softBreak 下逗号断句的最小累计长度。
        /// 取 4 是因为中文短句常为「他推开窗，」这类 4~5 字结构，
        /// 阈值过高会让这些逗号落进同一段，停顿就丢了。
        let minSoftLength = 4

        for ch in text {
            current.append(ch)
            if stops.contains(ch), current.count >= 4 {
                out.append(current)
                current = ""
            } else if softBreak, softs.contains(ch), current.count >= minSoftLength {
                out.append(current)
                current = ""
            } else if current.count >= 80 {
                // 过长时优先在逗号处断开，找不到就硬切
                if let idx = current.lastIndex(where: { softs.contains($0) }),
                   current.distance(from: current.startIndex, to: idx) > 16 {
                    let cut = current.index(after: idx)
                    out.append(String(current[current.startIndex..<cut]))
                    current = String(current[cut...])
                } else {
                    out.append(current)
                    current = ""
                }
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(current) }
        return out
    }

    // MARK: - 音频会话与中断

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    /// 来电等系统中断：暂停；中断结束且允许恢复时继续
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.pause()
            } else if type == .ended,
                      let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                if options.contains(.shouldResume) { self.resume() }
            }
        }
    }

    /// 拔掉耳机：暂停，避免外放打扰
    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { self.pause() }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }

    /// 系统语音是逐词回调的，高亮可以做到词级
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async {
            guard self.activeEngine == .system, self.isActive else { return }
            self.spokenRange = characterRange
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.activeEngine == .system else { return }
            self.isSpeaking = false
            guard self.isActive, !self.isPaused else { return }
            self.onAdvance?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.activeEngine == .system else { return }
            self.isSpeaking = false
        }
    }
}
