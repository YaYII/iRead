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
                }
        }
    }

    /// 调试用：启动参数 `--list-voices` 时打印系统全部语音，
    /// 用来确认中文男声/粤语是否真的存在（不靠猜）。
    private static func runVoiceListIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--list-voices") else { return }
        let all = AVSpeechSynthesisVoice.speechVoices()
        print("[Voices] total=\(all.count)")
        for v in all.sorted(by: { $0.language < $1.language }) {
            print("[Voices] \(v.language) | \(v.name) | q=\(v.quality.rawValue) | \(v.identifier)")
        }
        print("[Voices] maleChinese=\(SpeechService.maleChineseVoice()?.name ?? "nil") lang=\(SpeechService.maleChineseVoice()?.language ?? "-")")
        print("[Voices] cantonese=\(SpeechService.cantoneseVoice()?.name ?? "nil") lang=\(SpeechService.cantoneseVoice()?.language ?? "-")")
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
