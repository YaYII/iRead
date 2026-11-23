import SwiftUI

/// 统一的「正在播放」悬浮条。
///
/// 听书和音乐共用这一条：显示什么由 `PlaybackCenter.kind` 决定，
/// 不再出现「音乐条把听书球挤掉」或者两条互相打架的情况。
/// 视觉上照汽水音乐的做法：圆角封面 + 两行文字 + 一排轻按钮，
/// 底部一条 2pt 进度线，不抢正文的注意力。
struct NowPlayingDock: View {
    @ObservedObject private var playback = PlaybackCenter.shared
    @ObservedObject private var settings = ReaderSettings.shared

    /// 没在播时是否显示「听」球。书架、阅读页需要这个入口；
    /// 搜索、写作这些页面不需要，免得点开一个空播放器。
    var showsEntry: Bool = true
    /// 距容器底部的距离：书架要避开标签栏，阅读页要避开底部工具栏
    var bottomInset: CGFloat = 12
    var onOpen: () -> Void

    private var theme: ReadingTheme { settings.theme }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if playback.kind == .none {
                Spacer(minLength: 0)
                if showsEntry {
                    entryBall
                        .transition(.scale(scale: 0.86, anchor: .bottomTrailing).combined(with: .opacity))
                }
            } else {
                // 在播时占满整行，才有汽水那种「一条压在标签栏上」的分量
                capsule
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, bottomInset)
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: playback.kind)
    }

    // MARK: - 没在播：只有一颗「听」球

    private var entryBall: some View {
        Button(action: onOpen) {
            ZStack {
                Circle().fill(Color(white: 0.24).opacity(0.92))
                Text("听")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开听书")
    }

    // MARK: - 在播：封面 + 标题 + 控制

    private var capsule: some View {
        HStack(spacing: 8) {
            Button {
                playback.openPlayer()
            } label: {
                HStack(spacing: 9) {
                    cover
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)
                        Text(playback.subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            playButton
            nextButton
            closeButton
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(theme.background)
                .shadow(color: .black.opacity(0.16), radius: 11, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(theme.secondary.opacity(0.16), lineWidth: 0.6)
        )
        .overlay(alignment: .bottom) { progressLine }
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }

    /// 封面：书用渐变底 + 书名首字，音乐用渐变底 + 音符，和两边的全屏播放器一致
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(MediaArt.gradient(hue, dark: theme == .night))
            if playback.kind == .music {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                Text(String(playback.title.prefix(1)))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
            }
        }
        .frame(width: 38, height: 38)
    }

    private var hue: Double {
        switch playback.kind {
        case .music: return playback.music.track?.hue ?? 0.6
        case .book: return playback.listening.coverHue
        case .none: return 0.6
        }
    }

    private var playButton: some View {
        Button {
            playback.toggle()
        } label: {
            ZStack {
                if playback.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(theme.accent)
                } else {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
    }

    private var nextButton: some View {
        Button {
            playback.next()
        } label: {
            Image(systemName: playback.kind == .book ? "forward.end.fill" : "forward.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondary)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.kind == .book ? "下一章" : "下一首")
    }

    private var closeButton: some View {
        Button {
            playback.stop()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.secondary.opacity(0.7))
                .frame(width: 24, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.kind == .book ? "退出听书" : "停止播放")
    }

    private var progressLine: some View {
        GeometryReader { geo in
            Capsule()
                .fill(theme.accent.opacity(0.75))
                .frame(width: max(0, geo.size.width * playback.progress), height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .allowsHitTesting(false)
    }
}

/// 全屏播放器：**一个入口、两种形态**。
///
/// 当前在听书就是听书播放器，在听音乐就是音乐播放器；
/// 两档之间切换用底部的「切到…」，内容原地换掉，不叠两个弹窗。
struct NowPlayingView: View {
    @ObservedObject private var playback = PlaybackCenter.shared
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .environmentObject(store)
            .environmentObject(settings)
    }

    @ViewBuilder
    private var content: some View {
        switch playback.kind {
        case .music:
            MusicPlayerView()
        case .book:
            ListeningPlayerView()
        case .none:
            emptyState
        }
    }

    private var emptyState: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "play.slash")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(settings.theme.secondary)
                Text("现在没有在播的内容")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
                Button("关闭") { dismiss() }
                    .font(.footnote.weight(.medium))
                    .padding(.top, 4)
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
    }
}

/// 播放器底部那条「另一档还在等着」的入口。
///
/// 这才是「同一个播放体系」的具体体现：切走只是暂停，
/// 换回来时从原来的位置接着播，而不是从头开始。
struct PlaybackSwitchChip: View {
    @ObservedObject private var playback = PlaybackCenter.shared
    @ObservedObject private var settings = ReaderSettings.shared

    var body: some View {
        if let other = playback.resumableOtherKind {
            Button {
                playback.resumeOther()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: other == .music ? "music.note" : "headphones")
                        .font(.system(size: 15))
                        .foregroundStyle(settings.theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(other == .music ? "接着听音乐" : "接着听书")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(settings.theme.foreground)
                        Text(playback.otherTitle)
                            .font(.system(size: 10))
                            .foregroundStyle(settings.theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(settings.theme.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(settings.theme.foreground.opacity(0.05))
                )
                .contentShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
        }
    }
}
