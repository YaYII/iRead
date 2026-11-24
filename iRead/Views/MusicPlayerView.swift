import SwiftUI

/// 全屏音乐播放器。设计上尽量少：一张封面、一条进度、五个按钮。
/// 歌词和评论开源曲库没有，硬塞只会让人以为加载失败。
struct MusicPlayerView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var store = MusicStore.shared
    @ObservedObject private var settings = ReaderSettings.shared
    /// 必须订阅下载器，否则「正在存到本机 xx%」会永远停在 0%
    @ObservedObject private var downloads = MediaDownloader.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    /// 播放器里的是 `play()` 那一刻的快照，缓存完成 / 收藏变化都写在 store 里。
    /// 显示时按 id 回 store 取最新的一份，否则「已存到本机」永远不会亮。
    private var liveTrack: MusicTrack? {
        guard let track = player.track else { return nil }
        return store.track(id: track.id) ?? track
    }

    var body: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()

            // 封面色晕，让整页不是一块死白/死黑
            if let track = player.track {
                Circle()
                    .fill(MediaArt.gradient(track.hue, dark: settings.theme == .night))
                    .frame(width: 420, height: 420)
                    .blur(radius: 90)
                    .opacity(settings.theme == .night ? 0.28 : 0.18)
                    .offset(y: -160)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                artwork
                Spacer(minLength: 22)
                titleBlock
                progress
                controls
                // 听书还在等着：点一下原地换成听书播放器（同一个播放体系）
                switchRow
                footer
                Spacer(minLength: 18)
            }
            .padding(.horizontal, 28)
        }
        .preferredColorScheme(settings.theme.colorScheme)
    }

    // MARK: - 组件

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(settings.theme.foreground)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(settings.theme.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(settings.theme.secondary)
                .tracking(0.6)

            Spacer()

            Button {
                if let id = liveTrack?.id {
                    store.toggleFavorite(id)
                }
            } label: {
                Image(systemName: (liveTrack?.isFavorite == true) ? "heart.fill" : "heart")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle((liveTrack?.isFavorite == true) ? settings.theme.accent : settings.theme.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    /// 缓冲/下载中也算一种状态，写「已暂停」会让人以为自己按错了
    private var statusText: String {
        if player.isPlaying { return "正在播放" }
        if player.isBuffering { return "正在准备" }
        return "已暂停"
    }

    private var artwork: some View {
        ZStack {
            if let track = player.track {
                if let image = ArtworkStore.image(for: track) {
                    // 导入的歌带专辑图：铺满，底部压一层渐变，来源字才看得清
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .overlay(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.42)],
                                startPoint: .center, endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 26))
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 14)
                } else {
                    RoundedRectangle(cornerRadius: 26)
                        .fill(MediaArt.gradient(track.hue, dark: settings.theme == .night))
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 14)

                    Image(systemName: "music.note")
                        .font(.system(size: 92, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.9))
                }

                VStack {
                    Spacer()
                    HStack {
                        Text(track.sourceName.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        if track.hasLocalAudio {
                            Label(track.isLocal ? "本机文件" : "本机",
                                  systemImage: track.isLocal ? "folder.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(16)
                }
            } else {
                RoundedRectangle(cornerRadius: 26)
                    .fill(settings.theme.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 60, weight: .ultraLight))
                            .foregroundStyle(settings.theme.secondary)
                    )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(player.track?.title ?? "没有在播的歌")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(settings.theme.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(player.track?.artist ?? "")
                .font(.system(size: 13))
                .foregroundStyle(settings.theme.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
    }

    private var progress: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : player.currentTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = player.currentTime
                        isScrubbing = true
                    } else {
                        player.seek(to: scrubValue)
                        isScrubbing = false
                    }
                }
            )
            .tint(settings.theme.accent)

            HStack {
                Text(timeText(isScrubbing ? scrubValue : player.currentTime))
                Spacer()
                Text(timeText(player.duration))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(settings.theme.secondary)
            .monospacedDigit()
        }
        .padding(.top, 20)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                player.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(player.shuffle ? settings.theme.accent : settings.theme.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(settings.theme.foreground)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                player.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(settings.theme.accent)
                        .frame(width: 68, height: 68)
                        .shadow(color: settings.theme.accent.opacity(0.35), radius: 10, y: 5)
                    if player.isBuffering {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(settings.theme.foreground)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                player.cycleRepeat()
            } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(player.repeatMode == .off ? settings.theme.secondary : settings.theme.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
    }

    private var switchRow: some View {
        PlaybackSwitchChip()
            .padding(.top, 16)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let track = liveTrack {
                HStack(spacing: 6) {
                    if track.isLocal {
                        // 自己的文件，没有「下载/缓存」这回事，别写「在线播放」
                        Label("本机文件，不联网", systemImage: "folder.fill")
                            .foregroundStyle(settings.theme.accent)
                    } else if track.isCached {
                        Label("已存到本机", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(settings.theme.accent)
                    } else if let state = store.cacheState(for: track), state.isActive {
                        // 首播是「先下后放」：不下完不出声，所以文案要说清在等什么。
                        // 头几秒服务端还没回包，received 是 0 —— 这时写 0% 看着像卡死。
                        let percent = Int(state.progress * 100)
                        Label {
                            Text(state.received == 0
                                 ? "首次播放，正在连接曲库…"
                                 : "首次播放，正在下载 \(percent)%（存好自动开始）")
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                        .foregroundStyle(settings.theme.secondary)
                    } else if let state = store.cacheState(for: track), state.failed != nil {
                        Label("缓存失败，下次播放会重试", systemImage: "exclamationmark.circle")
                            .foregroundStyle(settings.theme.secondary)
                    } else {
                        Label("在线播放", systemImage: "wifi")
                            .foregroundStyle(settings.theme.secondary)
                    }
                    Spacer()
                }
                .font(.system(size: 10, weight: .medium))
                .padding(.top, 18)

                HStack(spacing: 4) {
                    Text(track.license)
                    if let url = URL(string: track.licenseURL) {
                        Link("查看许可", destination: url)
                    }
                    Spacer()
                    Text(track.sourceName)
                }
                .font(.system(size: 10))
                .foregroundStyle(settings.theme.secondary.opacity(0.85))
            }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
