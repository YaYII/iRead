import SwiftUI
import UIKit
import AVFoundation

@main
struct iReadApp: App {
    @StateObject private var store = LibraryStore.shared
    @StateObject private var settings = ReaderSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .onAppear {
                    settings.applyBrightness()
                    Self.runVoiceListIfRequested()
                    Self.runTTSSelfTestIfRequested()
                    Self.runCantoneseSelfTestIfRequested()
                    Self.runCantoneseControlTestIfRequested()
                    Self.runCantoneseRestartTestIfRequested()
                    Self.runCantonesePipelineTestIfRequested()
                    Self.runDownloadSelfTestIfRequested()
                }
        }
    }

    /// 自检：--download-selftest=关键词 时跑通「搜索→详情→下载正文→入库」全链路，
    /// 用日志验证网络书源功能在真机上可用（不依赖 UI 点击）。
    private static func runDownloadSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--download-selftest"), i + 1 < args.count else { return }
        let keyword = args[i + 1]
        Task.detached {
            NSLog("[DL selftest] start keyword=%@", keyword)
            let store = SourceStore.shared
            // 可选 --selftest-source=<id> 指定源；否则默认取第一个 github 源（兼容旧行为）
            var wantedID: String?
            if let si = args.firstIndex(of: "--selftest-source"), si + 1 < args.count {
                wantedID = args[si + 1]
            }
            let source: NovelSource?
            if let wantedID {
                source = store.enabledSources.first { $0.id == wantedID }
            } else {
                source = store.enabledSources.first { $0.kind?.lowercased() == "github" }
            }
            guard let source else {
                NSLog("[DL selftest] no matching source enabled (wanted=%@)", wantedID ?? "github")
                return
            }
            NSLog("[DL selftest] source=%@", source.name)
            do {
                let results = try await NovelFetcher.search(source: source, keyword: keyword)
                NSLog("[DL selftest] search results=%d", results.count)
                guard let target = results.first(where: { $0.title == keyword }) ?? results.first else {
                    NSLog("[DL selftest] no target")
                    return
                }
                let detail = try await NovelFetcher.chapters(result: target, source: source)
                NSLog("[DL selftest] detail=%@ chapters=%d", detail.title, detail.chapters.count)

                // 走新的「边下边读」链路：书立即进书架，分批抓、抓完一批写一批
                let dm = NovelDownloadManager.shared
                let bookID = dm.download(detail: detail, source: source)
                let store = LibraryStore.shared
                NSLog("[DL selftest] book entered shelf immediately id=%@ chapters=%d",
                      bookID, store.book(bookID)?.chapterCount ?? -1)

                // 轮询：观察章节数随下载递增；中途暂停 1 秒后继续，验证暂停/继续可控
                var sawPartial = false
                var didPause = false
                let deadline = Date().addingTimeInterval(180)
                while Date() < deadline {
                    guard let task = dm.task(forBookID: bookID) else { break }
                    let onShelf = store.book(bookID)?.chapterCount ?? 0
                    NSLog("[DL selftest] progress=%d/%d shelfChapters=%d status=%@",
                          task.completedChapters, task.totalChapters, onShelf, task.status.rawValue)
                    if onShelf > 0, onShelf < task.totalChapters { sawPartial = true }
                    // 抓到一部分时暂停，确认章节数停住，再继续
                    if sawPartial, !didPause, onShelf < task.totalChapters {
                        didPause = true
                        dm.pause(bookID)
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let pausedCount = store.book(bookID)?.chapterCount ?? 0
                        NSLog("[DL selftest] after pause status=%@ chapters=%d",
                              dm.task(forBookID: bookID)?.status.rawValue ?? "-", pausedCount)
                        dm.resume(bookID)
                    }
                    if task.status == .done || task.status == .failed || task.status == .cancelled {
                        let finalCount = store.book(bookID)?.chapterCount ?? 0
                        NSLog("[DL selftest] final status=%@ shelfChapters=%d sawPartial=%@ didPause=%@",
                              task.status.rawValue, finalCount, sawPartial ? "YES" : "NO", didPause ? "YES" : "NO")
                        break
                    }
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
            } catch {
                NSLog("[DL selftest] FAILED: %@", error.localizedDescription)
            }
        }
    }

    /// 调试用：启动参数 `--list-voices` 时打印系统全部语音，
    /// 用来确认中文男声/粤语是否真的存在（不靠猜）。
    ///
    /// 真机上 stdout 拿不到（除非开着 Xcode 控制台），所以同时落盘到
    /// `Documents/voices.txt`，用 `devicectl device copy from` 取回。
    private static func runVoiceListIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--list-voices") else { return }
        let all = AVSpeechSynthesisVoice.speechVoices()
        var lines = ["total=\(all.count)"]
        for v in all.sorted(by: { $0.language < $1.language }) {
            lines.append("\(v.language) | \(v.name) | q=\(v.quality.rawValue) | \(v.identifier)")
        }
        lines.append("maleChinese=\(SpeechService.maleChineseVoice()?.name ?? "nil") lang=\(SpeechService.maleChineseVoice()?.language ?? "-")")
        lines.append("cantonese=\(SpeechService.cantoneseVoice()?.name ?? "nil") lang=\(SpeechService.cantoneseVoice()?.language ?? "-") id=\(SpeechService.cantoneseVoice()?.identifier ?? "-")")
        let text = lines.joined(separator: "\n")
        print("[Voices]\n\(text)")
        writeDebugFile(text, name: "voices.txt")
    }

    /// 调试用：`--yue-selftest` 跑一遍粤语播放链路，逐秒采样状态，
    /// 结果落盘到 `Documents/yue-selftest.txt`。
    ///
    /// 要回答的问题：选粤语后到底用了哪个音色、引擎在不在出声（`range` 有没有推进）、
    /// 会不会自动接下一段、有没有中途「静默停住」。
    /// 加 `--yue-long` 改用真实长度的整段文字（约 260 字，和 ListeningCenter 的切段一致）。
    private static func runCantoneseSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--yue-selftest") else { return }

        let isLong = args.contains("--yue-long")
        let voice = SpeechService.cantoneseVoice()
        // 段首故意带全角空格和换行：验证 speech.start 里的 trim 会不会让高亮偏移
        let paragraph = "　　夜色沉下来，城市的灯一盏一盏亮起，像有人把碎金撒在湿漉漉的柏油路上。老陈把卷帘门拉到一半，弯腰钻进去，随手拍了拍肩上的雨珠。收音机里正播着粤剧，锣鼓点子一下一下敲在空气里，把他带回了三十年前的西关大屋。\n"
        let chunks: [String] = isLong
            ? [String(repeating: paragraph, count: 3), String(repeating: paragraph, count: 3)]
            : ["第一段测试，粤语朗读是否正常。", "第二段测试，看它能不能自己接下去。", "第三段测试，到这里应该就结束了。"]
        let watchdog = isLong ? 180 : 25

        var lines: [String] = []
        var index = 0
        let started = Date()
        func stamp() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
        func flush() { writeDebugFile(lines.joined(separator: "\n"), name: "yue-selftest.txt") }

        let svc = SpeechService.shared
        lines.append("mode=\(isLong ? "long" : "short")")
        lines.append("available=\(SpeechService.isCantoneseAvailable)")
        lines.append("voice=\(voice?.name ?? "nil") lang=\(voice?.language ?? "-") q=\(voice?.quality.rawValue ?? -1) id=\(voice?.identifier ?? "-")")
        lines.append("chunks=\(chunks.count) lens=\(chunks.map(\.count))")
        flush()

        svc.onAdvance = {
            lines.append("\(stamp()) ADVANCE #\(index) engine=\(svc.activeEngine.rawValue) voice=\(svc.debugCurrentVoiceName ?? "-")")
            index += 1
            flush()
            if index < chunks.count {
                lines.append("\(stamp()) CALL start #\(index) len=\(chunks[index].count)")
                flush()
                svc.start(text: chunks[index], rate: 0.7, profile: .cantonese)
                lines.append("\(stamp()) AFTER start #\(index) active=\(svc.isActive) engine=\(svc.activeEngine.rawValue)")
                flush()
            } else {
                lines.append("\(stamp()) ALL DONE engine=\(svc.activeEngine.rawValue)")
                svc.stop()
                flush()
            }
        }

        // 引擎内部状态变化（start / stop / startSystem / delegate 回调）都记进同一个文件
        svc.debugTrace = { message in
            DispatchQueue.main.async {
                lines.append("\(stamp()) TRACE \(message)")
                flush()
            }
        }

        // 先把可能残留的听书会话清掉，排除「别的东西抢占播放」的干扰（必须在 start 之前）
        ListeningCenter.shared.stop()
        svc.start(text: chunks[0], rate: 0.7, profile: .cantonese)
        lines.append("\(stamp()) START engine=\(svc.activeEngine.rawValue) voice=\(svc.debugCurrentVoiceName ?? "-")")
        flush()

        // 每秒采样：range 在推进 = 引擎真的在念；连着一动不动 = 静默卡住
        var tick = 0
        var sameRangeTicks = 0
        var lastRange = ""
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            tick += 1
            let range = svc.spokenRange.map { "\($0.location)+\($0.length)" } ?? "-"
            if range == lastRange { sameRangeTicks += 1 } else { sameRangeTicks = 0; lastRange = range }
            lines.append("\(stamp()) t=\(tick) active=\(svc.isActive) paused=\(svc.isPaused) speaking=\(svc.isSpeaking) engine=\(svc.activeEngine.rawValue) range=\(range)")
            if svc.isActive && !svc.isPaused && sameRangeTicks == 8 {
                lines.append("\(stamp()) ⚠️ STALL：8 秒内 range 没动")
            }
            flush()
            if tick >= watchdog {
                timer.invalidate()
                lines.append("\(stamp()) WATCHDOG end (\(watchdog)s)")
                svc.stop()
                flush()
            }
        }
    }

    /// 调试用：`--yue-control` 专测「控制」这条链路 —— 暂停到底有没有真的停、
    /// 继续能不能接上、改语速会不会重新起。
    /// 结果落盘 `Documents/yue-control.txt`。
    private static func runCantoneseControlTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--yue-control") else { return }
        let svc = SpeechService.shared
        let text = String(
            repeating: "　　夜色沉下来，城市的灯一盏一盏亮起，像有人把碎金撒在湿漉漉的柏油路上。老陈把卷帘门拉到一半，弯腰钻进去，随手拍了拍肩上的雨珠。\n",
            count: 3
        )
        var lines: [String] = []
        let started = Date()
        func stamp() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
        func flush() { writeDebugFile(lines.joined(separator: "\n"), name: "yue-control.txt") }

        lines.append("text.length=\(text.count)")
        flush()

        svc.debugTrace = { message in
            DispatchQueue.main.async {
                lines.append("\(stamp()) TRACE \(message)")
                flush()
            }
        }
        svc.onAdvance = {
            lines.append("\(stamp()) ADVANCE (unexpected in control test)")
            flush()
        }
        svc.start(text: text, rate: 0.5, profile: .cantonese)
        lines.append("\(stamp()) START \(svc.debugSynthesizerState)")
        flush()

        var tick = 0
        var lastRange = ""
        var frozenTicks = 0
        var pausedAt = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            tick += 1
            let range = svc.spokenRange.map { "\($0.location)+\($0.length)" } ?? "-"
            if range == lastRange { frozenTicks += 1 } else { frozenTicks = 0; lastRange = range }

            switch tick {
            case 6:   // +3s：暂停
                lines.append("\(stamp()) >>> pause()")
                svc.pause()
                pausedAt = tick
            case 16:  // +8s：继续
                lines.append("\(stamp()) >>> resume()  (暂停已持续 \((tick - pausedAt) / 2)s)")
                svc.resume()
            case 22:  // +11s：暂停中改语速，看是否会重新起
                lines.append("\(stamp()) >>> rate 0.5 -> 0.4 (paused=\(svc.isPaused))")
                ReaderSettings.shared.speechRate = 0.4
            case 30:  // +15s：收尾
                lines.append("\(stamp()) >>> stop()")
                svc.stop()
                timer.invalidate()
                flush()
                return
            default: break
            }

            lines.append("\(stamp()) t\(tick) active=\(svc.isActive) paused=\(svc.isPaused) speaking=\(svc.isSpeaking) \(svc.debugSynthesizerState) range=\(range) frozen=\(frozenTicks)")
            flush()
        }
    }

    /// 调试用：`--yue-restart` 连续「打断重播」——等价于用户改语速 / 切章 / 换音色，
    /// 每次都走 `start()` 里那条 `stopSpeaking` → `speak` 的路。
    /// 判断标准：每次重播后 range 是否还能继续推进（不推进 = 声音被吞，静默卡死）。
    private static func runCantoneseRestartTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--yue-restart") else { return }
        let svc = SpeechService.shared
        let paragraph = "　　夜色沉下来，城市的灯一盏一盏亮起，像有人把碎金撒在湿漉漉的柏油路上。老陈把卷帘门拉到一半，弯腰钻进去，随手拍了拍肩上的雨珠。\n"
        var lines: [String] = []
        let started = Date()
        func stamp() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
        func flush() { writeDebugFile(lines.joined(separator: "\n"), name: "yue-restart.txt") }

        svc.debugTrace = { message in
            DispatchQueue.main.async {
                lines.append("\(stamp()) TRACE \(message)")
                flush()
            }
        }
        // 真机上 onAdvance 是接下一段的唯一入口：打断重播时它被误触发，
        // 就是「点一下控制，正文往前蹦一段」的病根。
        var spuriousAdvances = 0
        svc.onAdvance = {
            spuriousAdvances += 1
            lines.append("\(stamp()) ⚠️ onAdvance 被触发 #\(spuriousAdvances)（打断重播时不该发生）")
            flush()
        }
        svc.start(text: String(repeating: paragraph, count: 3), rate: 0.5, profile: .cantonese)
        lines.append("\(stamp()) START #0 rate=0.5 \(svc.debugSynthesizerState)")
        flush()

        var tick = 0
        var round = 0
        var lastRange = ""
        var frozen = 0
        var marks: [(tick: Int, range: String)] = []

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            tick += 1
            let range = svc.spokenRange.map { "\($0.location)+\($0.length)" } ?? "-"
            if range == lastRange { frozen += 1 } else { frozen = 0; lastRange = range }

            if tick == 8 || tick == 16 || tick == 24 {
                round += 1
                lines.append("\(stamp()) >>> RESTART #\(round) (rangeBefore=\(range) frozen=\(frozen))")
                svc.start(text: String(repeating: paragraph, count: 3), rate: 0.4, profile: .cantonese)
                marks.append((tick, range))
                frozen = 0
                lines.append("\(stamp()) after start #\(round) \(svc.debugSynthesizerState) active=\(svc.isActive)")
            }
            if tick >= 32 {
                timer.invalidate()
                lines.append("\(stamp()) END frozen=\(frozen) range=\(range) spuriousAdvances=\(spuriousAdvances)")
                svc.stop()
                flush()
                return
            }
            lines.append("\(stamp()) t\(tick) active=\(svc.isActive) paused=\(svc.isPaused) \(svc.debugSynthesizerState) range=\(range) frozen=\(frozen)")
            flush()
        }
    }

    /// 调试用：`--yue-pipeline` 走**真实听书链路**（真的书、真的切段、真的按钮），
    /// 把用户的操作用 `ListeningCenter.toggle()` 复现一遍：播放 → 暂停 → 暂停中改语速
    /// → 继续 → 再暂停 → 继续 → 停止。
    /// 判断标准：① 暂停期间 currentChar 不许自己往前跑；② 改语速后从**当前句**重读，
    /// 不许跳到下一段；③ 每次「继续」都真的出声。
    /// 结果落盘 `Documents/yue-pipeline.txt`。
    private static func runCantonesePipelineTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--yue-pipeline") else { return }
        let listening = ListeningCenter.shared
        let settings = ReaderSettings.shared
        var lines: [String] = []
        let started = Date()
        func stamp() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
        func flush() { writeDebugFile(lines.joined(separator: "\n"), name: "yue-pipeline.txt") }
        func snap(_ tag: String) -> String {
            "\(stamp()) \(tag) active=\(listening.isActive) paused=\(listening.isPaused) "
                + "char=\(listening.currentChar) ch=\(listening.spokenChapter) "
                + "\(SpeechService.shared.debugSynthesizerState)"
        }

        settings.voiceProfile = .cantonese
        settings.speechRate = 0.5

        // 等内置书灌进书架再开播
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let book = LibraryStore.shared.books.first else {
                lines.append("\(stamp()) ❌ 没有书，无法测试")
                flush()
                return
            }
            lines.append("\(stamp()) 书=\(book.title) id=\(book.id) voice=\(settings.voiceProfile.rawValue)")
            flush()
            listening.resume(bookID: book.id)

            var tick = 0
            var wasPaused = false
            var pauseBaseline = 0
            var pauseMax = 0
            var drifts: [Int] = []
            // 追一遍 SpeechService 内部的 start/stop/pause，看清「谁在什么时候重新起了一句」
            SpeechService.shared.debugTrace = { message in
                DispatchQueue.main.async {
                    lines.append("\(stamp())   · \(message)")
                    flush()
                }
            }
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                tick += 1
                // 暂停真正生效那一刻起算：期间 char 再往前跑多少
                if listening.isPaused {
                    if wasPaused {
                        pauseMax = max(pauseMax, listening.currentChar)
                    } else {
                        pauseBaseline = listening.currentChar
                        pauseMax = listening.currentChar
                    }
                } else if wasPaused {
                    drifts.append(pauseMax - pauseBaseline)
                }
                wasPaused = listening.isPaused

                switch tick {
                case 8:  // +4s：点暂停
                    lines.append(snap(">>> toggle() 暂停"))
                    listening.toggle()
                case 12: // +6s：暂停中改语速
                    lines.append("\(stamp()) >>> 暂停中改语速 0.5 -> 0.35")
                    settings.speechRate = 0.35
                case 18: // +9s：点继续（应按新语速从当前句重来）
                    lines.append(snap(">>> toggle() 继续"))
                    listening.toggle()
                case 26: // +13s：再暂停
                    lines.append(snap(">>> toggle() 再暂停"))
                    listening.toggle()
                case 32: // +16s：再继续
                    lines.append(snap(">>> toggle() 再继续"))
                    listening.toggle()
                case 40: // +20s：收尾
                    timer.invalidate()
                    lines.append(snap("END"))
                    lines.append("暂停期间 char 额外前进量=\(drifts)（应只有 0～几个字，不能一直往前跑）")
                    SpeechService.shared.debugTrace = nil
                    listening.stop()
                    flush()
                    return
                default: break
                }
                lines.append(snap("t\(tick)"))
                flush()
            }
        }
    }

    /// 把调试输出写到 Documents/，真机可通过 devicectl 取回
    private static func writeDebugFile(_ text: String, name: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 调试用：启动参数 `--tts-selftest` 时合成一句样本并打印耗时，
    /// 用于在无人工听感的自动化环境里验证本地语音链路是否真的通了。
    private static func runTTSSelfTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--tts-selftest") else { return }
        let piper = PiperSynthesizer.shared
        print("[SelfTest] piper available=\(piper.isAvailable)")
        let args = ProcessInfo.processInfo.arguments
        let models: [PiperModel] = args.contains("--male-only") ? [.male]
            : args.contains("--female-only") ? [.female]
            : PiperModel.allCases
        for m in models {
            print("[SelfTest] model \(m.rawValue) gender=\(m.genderName) available=\(piper.isAvailable(m))")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            for model in models {
                let t0 = Date()
                let ok = piper.loadIfNeeded(model)
                let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
                print("[SelfTest] load \(model.rawValue) ok=\(ok) cost=\(loadMs)ms rate=\(piper.outputSampleRate(model)) err=\(piper.errorDescription ?? "-")")
                guard ok else { continue }
                let token = piper.currentToken()
                for text in ["这是一段本地语音测试。", "夜色沉下来，城市的灯一盏一盏亮起。"] {
                    let t1 = Date()
                    let res = piper.synthesize(text: text, speed: 1.0, model: model, token: token)
                    let ms = Int(Date().timeIntervalSince(t1) * 1000)
                    if let res {
                        let seconds = Double(res.samples.count) / Double(res.sampleRate)
                        let peak = res.samples.map { abs($0) }.max() ?? 0
                        let f0 = Self.estimateF0(res.samples, sampleRate: res.sampleRate)
                        print("[SelfTest] \(model.rawValue) synth \"\(text)\" samples=\(res.samples.count) sr=\(res.sampleRate) audio=\(String(format: "%.2f", seconds))s peak=\(String(format: "%.3f", peak)) f0=\(String(format: "%.0f", f0))Hz cost=\(ms)ms")
                        Self.dumpWav(res.samples, sampleRate: res.sampleRate,
                                     name: "\(model.rawValue)-\(text.hashValue).wav")
                    } else {
                        print("[SelfTest] \(model.rawValue) synth \"\(text)\" FAILED cost=\(ms)ms")
                    }
                }
            }

            // 标点停顿验证：不同句尾应得到不同长度的静音
            for sample in ["好。", "好！", "好？", "好…", "好；", "好：", "好，", "好、"] {
                let silence = SpeechService.trailingSilence(for: sample, sampleRate: 22050)
                let sec = Double(silence.count) / 22050.0
                print("[SelfTest] silence \"\(sample)\" = \(String(format: "%.2f", sec))s")
            }

            // 切句验证：男声走词典，标点会被丢弃，必须靠切句补停顿
            let demo = "他推开窗，风灌进来，把桌上的纸吹得满地都是。"
            let hardOnly = SpeechService.splitForPiper(demo, softBreak: false)
            let softSplit = SpeechService.splitForPiper(demo, softBreak: true)
            print("[SelfTest] split hard(\(hardOnly.count)): \(hardOnly)")
            print("[SelfTest] split soft(\(softSplit.count)): \(softSplit)")

            // 逗号停顿验证：按 SpeechService 的真实流程（切句 → 按标点补静音）拼成整段落盘，
            // 之后用波形量逗号处的静音长度，避免只靠「听起来有停顿」这种主观判断。
            let pauseDemo = "夜色沉下来，城市的灯一盏一盏亮起。"
            for model in models {
                let parts = SpeechService.splitForPiper(pauseDemo, softBreak: true)
                var merged: [Float] = []
                var sampleRate: Int32 = 22050
                for part in parts {
                    guard let r = piper.synthesize(
                        text: part, speed: 1.0, model: model, token: piper.currentToken()
                    ) else { continue }
                    sampleRate = r.sampleRate
                    merged += r.samples
                    merged += SpeechService.trailingSilence(for: part, sampleRate: r.sampleRate)
                }
                print("[SelfTest] merged \(model.rawValue) parts=\(parts.count) \(parts) audio=\(String(format: "%.2f", Double(merged.count) / Double(sampleRate)))s")
                Self.dumpWav(merged, sampleRate: sampleRate, name: "merged-\(model.rawValue).wav")
            }

            // 播放链路：走 SpeechService + AVAudioEngine，验证 onAdvance 能正常触发
            DispatchQueue.main.async {
                let svc = SpeechService.shared
                svc.onAdvance = {
                    print("[SelfTest] playback finished, onAdvance fired, engine=\(svc.activeEngine.rawValue)")
                    svc.stop()
                }
                print("[SelfTest] start playback via SpeechService (male)")
                svc.start(
                    text: "播放链路测试，听得到就说明本地语音已经接通。",
                    rate: 0.5,
                    profile: .neuralMale
                )
            }
        }
    }

    /// 用自相关估基频（Hz）。用于客观判断音色是男声还是女声：
    /// 男声典型 85–180Hz，女声 165–255Hz。
    private static func estimateF0(_ samples: [Float], sampleRate: Int32) -> Double {
        let sr = Double(sampleRate)
        // 取中段 0.5s，避开首尾静音
        let window = Int(sr * 0.5)
        guard samples.count > window * 2 else { return 0 }
        let start = (samples.count - window) / 2
        let seg = Array(samples[start..<(start + window)])

        let minLag = Int(sr / 400)   // 400Hz 上限
        let maxLag = Int(sr / 70)    // 70Hz 下限
        guard maxLag < seg.count else { return 0 }

        var bestLag = 0
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            var i = 0
            while i + lag < seg.count {
                sum += seg[i] * seg[i + lag]
                i += 1
            }
            if sum > bestScore { bestScore = sum; bestLag = lag }
        }
        guard bestLag > 0 else { return 0 }
        return sr / Double(bestLag)
    }

    /// 把合成结果写成 WAV 到 Documents，方便拷出来人工试听
    private static func dumpWav(_ samples: [Float], sampleRate: Int32, name: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent(name)
        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = Int32(samples.count * 2)
        func le32(_ v: Int32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        func le16(_ v: Int16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
        data.append("RIFF".data(using: .ascii)!)
        data.append(le32(36 + dataSize))
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.append(le32(16))
        data.append(le16(1))
        data.append(le16(1))
        data.append(le32(sampleRate))
        data.append(le32(byteRate))
        data.append(le16(2))
        data.append(le16(16))
        data.append("data".data(using: .ascii)!)
        data.append(le32(dataSize))
        for s in samples {
            let clamped = max(-1, min(1, s))
            data.append(le16(Int16(clamped * 32767)))
        }
        try? data.write(to: url)
        print("[SelfTest] wav -> \(url.lastPathComponent) (\(data.count) bytes)")
    }
}
