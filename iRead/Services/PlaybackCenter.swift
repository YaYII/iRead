import Foundation
import Combine

/// 当前「占用播放体系」的那一档。
///
/// 同一时刻只有一档在出声，但两档各自保留播放位置：切走只是暂停，不是丢掉。
enum PlaybackKind: String {
    case none
    case book
    case music
}

/// 全局播放中枢：听书与音乐共用一个播放体系，只区分「现在听的是哪一档」。
///
/// 以前两套播放器各管各的：`MusicPlayer.play` 里直接 `ListeningCenter.stop()`，
/// 听书开播时又把音乐晾在一边，于是两条悬浮条互相挤、谁先出声谁把对方清空。
/// 这里把「现在是谁在播」收成一份状态：
///
/// - 出声仍然只有一个：切换时另一方只 `pause()`，进度和曲目都留着，随时能接回去
/// - 界面只认 `kind`：迷你条、全屏播放器都按它渲染，不存在谁强制占领
/// - 锁屏信息也只由当前这一档写，两边不再抢 `MPNowPlayingInfoCenter`
final class PlaybackCenter: ObservableObject {
    static let shared = PlaybackCenter()

    /// 当前这一档：书 / 音乐 / 空
    @Published private(set) var kind: PlaybackKind = .none
    /// 统一播放器（全屏）：内容随 `kind` 切换，入口只有一个
    @Published var wantsPlayer = false

    let music = MusicPlayer.shared
    let listening = ListeningCenter.shared

    private var bag = Set<AnyCancellable>()

    private init() {
        // 两档引擎的状态变化都要让界面重绘：
        // 迷你条 / 播放器只订阅中枢这一份，不必各自记住要观察谁
        music.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        listening.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // 谁真的开始出声，播放体系就交给谁。
        // 点歌、点播放按钮、锁屏播放都会走到这里，不用每个入口自己记得切换。
        music.$isPlaying
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.handOver(to: .music) }
            .store(in: &bag)

        listening.$isActive
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.handOver(to: .book) }
            .store(in: &bag)
    }

    // MARK: - 归属

    func owns(_ target: PlaybackKind) -> Bool { kind == target }

    /// 开始播某一档：另一档**只暂停**，不销毁。
    func handOver(to next: PlaybackKind) {
        guard next != .none else { return }
        if kind != next {
            switch next {
            case .music:
                // 听书暂停：书还在、章节还在、字还在，切回来接着念
                if listening.isActive { listening.pause() }
            case .book:
                // 音乐暂停：曲目和进度都留着，切回来接着放
                if music.isPlaying { music.pause() }
            case .none:
                break
            }
            kind = next
        }
    }

    /// 某一档被彻底关掉：能退回另一档就退，否则清空
    func didStop(_ stopped: PlaybackKind) {
        guard kind == stopped else { return }
        if listening.isActive || listening.bookID != nil {
            kind = .book
        } else if music.track != nil {
            kind = .music
        } else {
            kind = .none
            wantsPlayer = false
        }
    }

    // MARK: - 统一状态（迷你条 / 播放器共用）

    var isPlaying: Bool {
        switch kind {
        case .book: return listening.isActive && !listening.isPaused
        case .music: return music.isPlaying
        case .none: return false
        }
    }

    /// 在准备（下载音频 / 加载语音模型），按钮位置显示菊花
    var isBusy: Bool {
        switch kind {
        case .book: return listening.isPreparingModel
        case .music: return music.isBuffering
        case .none: return false
        }
    }

    var title: String {
        switch kind {
        case .book: return listening.bookTitle
        case .music: return music.track?.title ?? ""
        case .none: return ""
        }
    }

    var subtitle: String {
        switch kind {
        case .book:
            if listening.isPreparingModel { return "正在加载语音模型…" }
            if listening.isIdle { return "待播放 · \(listening.chapterTitle)" }
            if listening.isPaused { return "已暂停 · \(listening.chapterTitle)" }
            return "正在朗读 · \(listening.chapterTitle)"
        case .music:
            return music.track?.artist ?? ""
        case .none:
            return ""
        }
    }

    /// 0...1，迷你条底部那条细线用
    var progress: Double {
        switch kind {
        case .book:
            return min(1, max(0, listening.chapterProgress))
        case .music:
            guard music.duration > 0 else { return 0 }
            return min(1, max(0, music.currentTime / music.duration))
        case .none:
            return 0
        }
    }

    // MARK: - 统一控制

    func toggle() {
        switch kind {
        case .book: listening.toggle()
        case .music: music.toggle()
        case .none: break
        }
    }

    func next() {
        switch kind {
        case .book: listening.nextChapter()
        case .music: music.next()
        case .none: break
        }
    }

    func stop() {
        switch kind {
        case .book: listening.stop()
        case .music: music.stop()
        case .none: break
        }
    }

    func openPlayer() {
        guard kind != .none else { return }
        wantsPlayer = true
    }

    // MARK: - 在两档之间来回切

    /// 另一档还有没有内容可接（播放器底部「切回去」那条用）
    var resumableOtherKind: PlaybackKind? {
        switch kind {
        case .book: return music.track != nil ? .music : nil
        case .music: return (listening.isActive || listening.bookID != nil) ? .book : nil
        case .none: return nil
        }
    }

    var otherTitle: String {
        switch resumableOtherKind {
        case .music: return music.track?.title ?? ""
        case .book: return listening.bookTitle
        default: return ""
        }
    }

    /// 切回另一档：真正接着播（这才是「同一个播放体系」该有的手感）
    func resumeOther() {
        switch resumableOtherKind {
        case .music:
            music.resume()
            handOver(to: .music)
        case .book:
            if listening.isActive { listening.resumePlayback() } else { listening.start() }
            handOver(to: .book)
        default:
            break
        }
    }
}
