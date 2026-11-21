import Foundation
import os
import SherpaOnnxC

/// 随 App 打包的中文神经语音模型。
///
/// 两个模型都是 Piper VITS、22050Hz、共用同一套 espeak-ng 音素化数据，
/// 因此可以复用同一条推理管线，只是 onnx 与 tokens 不同。
enum PiperModel: String, CaseIterable, Identifiable {
    /// 「花颜」中文女声，medium 精度，音质最自然
    case female = "zh_CN-huayan-medium"
    /// 「超文」中文男声，int8 量化，体积只有女声的 1/3
    case male = "zh_CN-chaowen-medium"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .female: return "花颜"
        case .male:   return "超文"
        }
    }

    var genderName: String {
        switch self {
        case .female: return "女声"
        case .male:   return "男声"
        }
    }

    /// Bundle 内的子目录名（Vendor/piper/<folder>/）
    var folder: String {
        switch self {
        case .female: return "huayan"
        case .male:   return "chaowen"
        }
    }

    /// 音素化方式。两个模型虽然都是 Piper VITS + IPA tokens，
    /// 但入口完全不同，配错会直接在 `SherpaOnnxCreateOfflineTts` 里抛 C++ 异常崩溃：
    /// - 花颜（piper 原版）：走 espeak-ng，需要 `data_dir`
    /// - 超文（sherpa 配方版）：走词典，需要 `lexicon.txt` + `phone.fst`
    ///   注意 C API 规定「提供 data_dir 时 lexicon 被忽略」，所以两者必须二选一。
    var usesLexicon: Bool {
        switch self {
        case .female: return false
        case .male:   return true
        }
    }
}

/// 本地神经语音（Piper VITS / sherpa-onnx）封装。
///
/// 完全离线：模型与 espeak-ng 音素化数据随 App 打包，推理在本机 CPU 完成，
/// 不联网、不计费。
///
/// 设计要点：
/// - 模型加载很重（男声 18MB / 女声 60MB），只在首次朗读时懒加载，之后常驻。
///   两个模型各自独立缓存，切音色时无需重复加载已用过的那个。
/// - 合成是同步 CPU 密集操作，统一放在专用串行队列，绝不占用主线程。
/// - 每次合成都带一个 generation 令牌，用户停止/切换后旧结果直接丢弃。
final class PiperSynthesizer {
    static let shared = PiperSynthesizer()

    private let log = Logger(subsystem: "com.yingyang.iread", category: "Piper")
    private let queue = DispatchQueue(label: "iread.piper.synth", qos: .userInitiated)

    /// 串行保护的可变状态
    private var handles: [PiperModel: OpaquePointer] = [:]
    private var loading: Set<PiperModel> = []
    private var sampleRates: [PiperModel: Int32] = [:]
    private var lastError: String?

    /// 递增令牌：停止时 +1，使在途合成结果失效
    private var generation: Int = 0

    private init() {}

    // MARK: - 资源定位

    /// Bundle 内 piper 资源根目录（以 folder reference 方式打包，保留目录结构）
    private var resourceRoot: URL? {
        if let u = Bundle.main.url(forResource: "piper", withExtension: nil) { return u }
        // 兜底：直接按路径拼（部分打包方式下 url(forResource:) 找不到目录）
        if let base = Bundle.main.resourceURL {
            let u = base.appendingPathComponent("piper", isDirectory: true)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private func modelPath(_ model: PiperModel) -> String? {
        resourceRoot?.appendingPathComponent(model.folder, isDirectory: true)
            .appendingPathComponent("\(model.rawValue).onnx").path
    }

    private func tokensPath(_ model: PiperModel) -> String? {
        resourceRoot?.appendingPathComponent(model.folder, isDirectory: true)
            .appendingPathComponent("tokens.txt").path
    }

    private func lexiconPath(_ model: PiperModel) -> String? {
        resourceRoot?.appendingPathComponent(model.folder, isDirectory: true)
            .appendingPathComponent("lexicon.txt").path
    }

    /// espeak-ng 音素化数据，只有走 espeak 的模型需要
    private var dataDir: String? {
        resourceRoot?.appendingPathComponent("espeak-ng-data", isDirectory: true).path
    }

    /// 指定模型的资源是否齐全（不看是否已加载）
    func isAvailable(_ model: PiperModel) -> Bool {
        guard let m = modelPath(model), let t = tokensPath(model) else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: m), fm.fileExists(atPath: t) else { return false }
        if model.usesLexicon {
            guard let l = lexiconPath(model) else { return false }
            return fm.fileExists(atPath: l)
        }
        guard let d = dataDir else { return false }
        return fm.fileExists(atPath: d)
    }

    /// 任一模型可用即视为本地语音能力可用
    var isAvailable: Bool { PiperModel.allCases.contains { isAvailable($0) } }

    /// 轻量状态快照，避免主线程被合成队列阻塞
    private let snapshotLock = NSLock()
    private var readySnapshot: Set<PiperModel> = []
    private var errorSnapshot: String?

    /// 指定模型是否已经加载完成（不阻塞）
    func isReady(_ model: PiperModel) -> Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return readySnapshot.contains(model)
    }

    var outputSampleRate: Int32 {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return sampleRates.values.first ?? 22050
    }

    func outputSampleRate(_ model: PiperModel) -> Int32 {
        queue.sync { sampleRates[model] ?? 22050 }
    }

    var errorDescription: String? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return errorSnapshot
    }

    private func publishSnapshot(ready model: PiperModel? = nil, notReady: Bool = false, error: String?? = nil) {
        snapshotLock.lock()
        if let model {
            if notReady { readySnapshot.remove(model) } else { readySnapshot.insert(model) }
        }
        if let error { errorSnapshot = error }
        snapshotLock.unlock()
    }

    // MARK: - 加载

    /// 同步加载模型（会阻塞调用线程，务必不要在主线程调用）。
    /// 重复调用是安全的：已加载时直接返回 true。
    @discardableResult
    func loadIfNeeded(_ model: PiperModel) -> Bool {
        queue.sync { loadLocked(model) }
    }

    /// 调用前必须已在 queue 上
    private func loadLocked(_ model: PiperModel) -> Bool {
        if handles[model] != nil { return true }
        if loading.contains(model) { return false }
        loading.insert(model)
        defer { loading.remove(model) }

        guard isAvailable(model),
              let path = modelPath(model),
              let tokens = tokensPath(model) else {
            lastError = "未找到内置语音模型资源（\(model.displayName)）"
            publishSnapshot(ready: model, notReady: true, error: .some(lastError))
            log.error("piper resources missing for \(model.rawValue, privacy: .public)")
            return false
        }

        var config = SherpaOnnxOfflineTtsConfig()
        config.model.vits.noise_scale = 0.667
        config.model.vits.noise_scale_w = 0.8
        config.model.vits.length_scale = 1.0
        config.model.num_threads = 2
        config.model.debug = 0
        config.max_num_sentences = 1
        config.silence_scale = 0.2

        // 词典路径与 espeak 路径互斥：配错会直接抛 C++ 异常
        let lexicon: String? = model.usesLexicon ? lexiconPath(model) : nil
        let espeak: String? = model.usesLexicon ? nil : dataDir
        if model.usesLexicon && lexicon == nil {
            lastError = "缺少词典资源（\(model.displayName)）"
            publishSnapshot(ready: model, notReady: true, error: .some(lastError))
            return false
        }

        let created: OpaquePointer? = path.withCString { m in
            tokens.withCString { t in
                "cpu".withCString { provider in
                    config.model.vits.model = m
                    config.model.vits.tokens = t
                    config.model.provider = provider
                    if let lexicon {
                        return lexicon.withCString { lex in
                            config.model.vits.lexicon = lex
                            config.model.vits.data_dir = nil
                            return SherpaOnnxCreateOfflineTts(&config)
                        }
                    }
                    guard let espeak else { return nil }
                    return espeak.withCString { d in
                        config.model.vits.data_dir = d
                        config.model.vits.lexicon = nil
                        return SherpaOnnxCreateOfflineTts(&config)
                    }
                }
            }
        }

        guard let handle = created else {
            lastError = "语音模型加载失败（\(model.displayName)）"
            publishSnapshot(ready: model, notReady: true, error: .some(lastError))
            log.error("SherpaOnnxCreateOfflineTts returned nil for \(model.rawValue, privacy: .public)")
            return false
        }

        handles[model] = handle
        let sr = SherpaOnnxOfflineTtsSampleRate(handle)
        sampleRates[model] = sr > 0 ? sr : 22050
        lastError = nil
        publishSnapshot(ready: model, error: .some(nil))
        log.info("piper ready \(model.rawValue, privacy: .public) sampleRate=\(sr, privacy: .public)")
        return true
    }

    // MARK: - 合成

    /// 把一段文本合成为单声道浮点 PCM（范围 [-1, 1]）。
    /// - Parameters:
    ///   - text: 待合成文本，建议不超过 120 字，过长会明显增加延迟
    ///   - speed: 语速倍率，1.0 为正常
    ///   - model: 使用哪个音色模型
    ///   - token: 本次请求的令牌，若期间发生 stop 则返回 nil
    /// - Returns: (采样, 采样率)，失败或作废时返回 nil
    func synthesize(
        text: String,
        speed: Float,
        model: PiperModel,
        token: Int
    ) -> (samples: [Float], sampleRate: Int32)? {
        queue.sync { () -> (samples: [Float], sampleRate: Int32)? in
            guard token == generation else { return nil }
            guard loadLocked(model), let handle = handles[model] else { return nil }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            var gen = SherpaOnnxGenerationConfig()
            // 调用方（SpeechService）已经把倍率拆成「合成 ≤2 倍 + 播放拉伸」，
            // 这里只做兜底钳制。下限放到 0.4 是为了支持慢速朗读。
            gen.speed = max(0.4, min(2.0, speed))
            gen.sid = 0
            gen.silence_scale = 0.2

            let audio: UnsafePointer<SherpaOnnxGeneratedAudio>? = trimmed.withCString { cstr in
                SherpaOnnxOfflineTtsGenerateWithConfig(handle, cstr, &gen, nil, nil)
            }

            guard let audio else {
                log.error("generate failed for text len=\(trimmed.count, privacy: .public)")
                return nil
            }
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }

            let n = Int(audio.pointee.n)
            guard n > 0, let ptr = audio.pointee.samples else { return nil }
            let samples = Array(UnsafeBufferPointer(start: ptr, count: n))
            let sr = audio.pointee.sample_rate > 0 ? audio.pointee.sample_rate : (sampleRates[model] ?? 22050)
            return (samples, sr)
        }
    }

    /// 作废所有在途合成（用户停止、切换章节、退出听书时调用）
    func cancelPending() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
        }
    }

    /// 当前令牌，交给调用方在合成时回传以判定是否作废
    func currentToken() -> Int {
        queue.sync { generation }
    }

    /// 释放全部模型（退出听书很久后可调用；App 正常使用中无需调用）
    func shutdown() {
        queue.sync {
            generation &+= 1
            for (_, handle) in handles {
                SherpaOnnxDestroyOfflineTts(handle)
            }
            handles.removeAll()
            sampleRates.removeAll()
            snapshotLock.lock()
            readySnapshot.removeAll()
            snapshotLock.unlock()
        }
    }
}
