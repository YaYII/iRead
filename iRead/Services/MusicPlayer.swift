import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// 全局音乐播放器。
///
/// 它和听书共用一套播放体系（`PlaybackCenter`）：同一时刻只有一档出声，
/// 切换时另一方只暂停、不销毁，所以听 A 听 B 可以随时来回。
/// 播放在线地址的同时把文件存到 `MusicStore`，下次直接读本地。
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    @Published private(set) var track: MusicTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var shuffle = false
    @Published var repeatMode: MusicRepeatMode = .all

    private var player: AVPlayer?
    private var queue: [MusicTrack] = []
    private var index = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var remoteConfigured = false
    /// 用户在等待下载期间有没有按过暂停：下载完成后据此决定是否自动起播
    private var wantsPlayWhenReady = true

    var isActive: Bool { track != nil }

    // MARK: - 播放控制

    /// 播放一首歌。`queue` 传当前列表，用于上一首/下一首。
    func play(_ item: MusicTrack, queue list: [MusicTrack]? = nil) {
        // 播放体系交给音乐：听书只暂停，书和章节都留着，随时能切回去
        PlaybackCenter.shared.handOver(to: .music)

        let stored = MusicStore.shared.remember(item)
        track = stored

        if let list, !list.isEmpty {
            queue = list.map { MusicStore.shared.remember($0) }
            index = queue.firstIndex(where: { $0.id == stored.id }) ?? 0
        } else if !queue.contains(where: { $0.id == stored.id }) {
            queue = [stored]
            index = 0
        } else {
            index = queue.firstIndex(where: { $0.id == stored.id }) ?? 0
        }

        prepare(stored)
        MusicStore.shared.notePlayed(stored.id)
    }

    func toggle() {
        guard track != nil else { return }
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        wantsPlayWhenReady = true
        PlaybackCenter.shared.handOver(to: .music)
        guard let player else {
            // 还在下载：下完会自动起播，这里只翻转意图
            return
        }
        activateSession()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        wantsPlayWhenReady = false
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func stop() {
        wantsPlayWhenReady = false
        player?.pause()
        removeObservers()
        player = nil
        track = nil
        isPlaying = false
        isBuffering = false
        currentTime = 0
        duration = 0
        queue = []
        index = 0
        if PlaybackCenter.shared.owns(.music) {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        // 关掉音乐后如果书还在，播放体系交回听书（迷你条跟着换过去）
        PlaybackCenter.shared.didStop(.music)
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if auto, repeatMode == .one, let track {
            prepare(track)
            return
        }
        if shuffle, queue.count > 1 {
            var nextIndex = Int.random(in: 0..<queue.count)
            if nextIndex == index { nextIndex = (nextIndex + 1) % queue.count }
            index = nextIndex
        } else if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all || !auto {
            index = 0
        } else {
            pause()
            currentTime = 0
            player?.seek(to: .zero)
            return
        }
        prepare(queue[index])
        MusicStore.shared.notePlayed(queue[index].id)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        // 播过 3 秒以上先回到开头，符合常见播放器手感
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        index = index > 0 ? index - 1 : queue.count - 1
        prepare(queue[index])
        MusicStore.shared.notePlayed(queue[index].id)
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player?.seek(to: target) { [weak self] _ in
            self?.currentTime = max(0, seconds)
            self?.updateNowPlaying()
        }
    }

    /// 点进度条：传 0...1
    func seek(ratio: Double) {
        guard duration > 0 else { return }
        seek(to: duration * min(max(ratio, 0), 1))
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        updateNowPlaying()
    }

    // MARK: - 内部

    /// 决定「这首从哪放」：
    /// - 已缓存 / 本地有文件 → 立刻播本地；
    /// - 没缓存 → 先下载到本地再播。
    ///
    /// 为什么不直接 `AVPlayer(url: remote)`：ccMixter 校验 `Referer`，
    /// AVPlayer 发不出自定义请求头，直连必然 403。统一「先下后播」
    /// 顺带就把「自动保存、下次不用再下载」这条需求做了。
    private func prepare(_ item: MusicTrack) {
        wantsPlayWhenReady = true
        removeObservers()
        player?.pause()
        player = nil

        track = item
        duration = item.duration
        currentTime = 0
        isBuffering = true
        isPlaying = false
        updateNowPlaying()

        if let local = MusicStore.shared.localURL(for: item) {
            startPlayback(url: local, item: item)
            return
        }

        // 一首 mp3 通常 1~4 MB，几秒内下完；期间界面显示缓冲态
        MusicStore.shared.autoCache(item) { [weak self] result in
            guard let self, self.track?.id == item.id else { return }
            switch result {
            case .success(let file):
                if self.wantsPlayWhenReady {
                    self.startPlayback(url: file, item: item)
                } else {
                    // 下载期间用户按了暂停：备好但不自动响
                    self.player = AVPlayer(url: file)
                    self.isBuffering = false
                    self.isPlaying = false
                    self.updateNowPlaying()
                }
            case .failure:
                // 兜底：源不校验防盗链时，直连也能出声
                guard let remote = URL(string: item.streamURL) else {
                    self.isBuffering = false
                    self.isPlaying = false
                    return
                }
                self.startPlayback(url: remote, item: item)
            }
        }
    }

    private func startPlayback(url: URL, item: MusicTrack) {
        activateSession()

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = true

        player = newPlayer
        track = item
        duration = item.duration
        currentTime = 0
        isBuffering = true

        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    if self.duration <= 0 {
                        let seconds = CMTimeGetSeconds(item.duration)
                        if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    }
                case .failed:
                    self.isBuffering = false
                    self.isPlaying = false
                default:
                    break
                }
            }
        }

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = max(0, CMTimeGetSeconds(time))
            if self.duration <= 0 {
                let total = CMTimeGetSeconds(newPlayer.currentItem?.duration ?? .zero)
                if total.isFinite, total > 0 { self.duration = total }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.next(auto: true)
        }

        if wantsPlayWhenReady {
            newPlayer.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        configureRemoteCommandsIfNeeded()
        updateNowPlaying()
    }

    private func removeObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])
        try? session.setActive(true)
    }

    // MARK: - 锁屏 / 控制中心

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteConfigured else { return }
        remoteConfigured = true

        let center = MPRemoteCommandCenter.shared()
        // 听书那边也注册了同名命令：只有当前这一档能响应，
        // 否则锁屏按一次暂停会把两个播放器都停掉/都叫醒。
        center.playCommand.addTarget { [weak self] _ in
            guard PlaybackCenter.shared.owns(.music) else { return .success }
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard PlaybackCenter.shared.owns(.music) else { return .success }
            self?.pause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard PlaybackCenter.shared.owns(.music) else { return .success }
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard PlaybackCenter.shared.owns(.music) else { return .success }
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard PlaybackCenter.shared.owns(.music) else { return .success }
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        // 锁屏信息只由当前这一档写：听书切到音乐会互相覆盖，出现「歌名 + 书名」的错乱
        guard PlaybackCenter.shared.owns(.music) else { return }
        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
