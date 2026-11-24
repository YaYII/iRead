import SwiftUI
import AVKit

/// 书架「音乐」分类。只展示进过本机库的歌（播过、缓存过、收藏过、导入过），
/// 在线搜索在「搜索 → 音乐」里，两个地方不重复。
struct MusicShelfGrid: View {
    var onSearch: () -> Void

    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var store = MusicStore.shared
    @ObservedObject private var player = MusicPlayer.shared

    @State private var showImporter = false
    @State private var importing = false
    @State private var note: String?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
        count: 3
    )

    private var tracks: [MusicTrack] {
        store.tracks.sorted { a, b in
            switch (a.lastPlayedAt, b.lastPlayedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.addedAt ?? .distantPast) > (b.addedAt ?? .distantPast)
            }
        }
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                empty
                    .padding(.top, 56)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(tracks) { track in
                            card(track)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            importPicked(result)
        }
    }

    /// 有歌之后入口收成一行小字，不再占一整屏
    private var header: some View {
        HStack(spacing: 10) {
            Text("\(tracks.count) 首")
                .font(.system(size: 11))
                .foregroundStyle(settings.theme.secondary)

            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(settings.theme.accent)
                    .transition(.opacity)
            }

            Spacer()

            Button {
                showImporter = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: importing ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text(importing ? "导入中" : "导入歌曲")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(settings.theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(settings.theme.accent.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(importing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .animation(.easeInOut(duration: 0.2), value: note)
    }

    private func importPicked(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            note = "导入失败：\(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            importing = true
            note = nil
            Task {
                var ok = 0
                var bad = 0
                for url in urls {
                    do {
                        try await LocalMusicImport.importFile(at: url)
                        ok += 1
                    } catch {
                        bad += 1
                        NSLog("[MusicImport] %@ failed: %@", url.lastPathComponent,
                              error.localizedDescription)
                    }
                }
                importing = false
                note = bad == 0 ? "已导入 \(ok) 首" : "导入 \(ok) 首，\(bad) 首失败"
                // 提示两秒后自己收掉，不占着那行
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                note = nil
            }
        }
    }

    private func card(_ track: MusicTrack) -> some View {
        let isCurrent = player.track?.id == track.id
        return Button {
            player.play(track, queue: tracks)
            PlaybackCenter.shared.openPlayer()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    MusicCover(track: track, size: 96, showsNote: true)
                        .frame(maxWidth: .infinity)

                    if isCurrent {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(.black.opacity(0.45)))
                            .padding(7)
                    }

                    if track.hasLocalAudio {
                        Image(systemName: track.isLocal ? "folder.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }

                Text(track.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(settings.theme.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(track.artist)
                    .font(.system(size: 9))
                    .foregroundStyle(settings.theme.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.toggleFavorite(track.id)
            } label: {
                Label(track.isFavorite ? "取消收藏" : "收藏", systemImage: track.isFavorite ? "heart.slash" : "heart")
            }
            Button(role: .destructive) {
                if player.track?.id == track.id { player.stop() }
                store.delete(track.id)
            } label: {
                Label("从本机移除", systemImage: "trash")
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(settings.theme.secondary)
            Text("还没有歌")
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            Text("去搜索里找开源曲库，或者把自己的音频导进来。\n导入的歌完全在本机，不联网也不上传。")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    onSearch()
                } label: {
                    Text("去找歌")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(settings.theme.accent))
                }
                .buttonStyle(.plain)

                Button {
                    showImporter = true
                } label: {
                    Text(importing ? "导入中…" : "从文件导入")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(settings.theme.accent)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().strokeBorder(settings.theme.accent.opacity(0.45), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(importing)
            }

            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(settings.theme.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}

/// 书架「视频」分类：播放过的、收藏的、下载下来的都在这里。
struct VideoShelfGrid: View {
    var onSearch: () -> Void

    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var store = VideoStore.shared

    @State private var playing: VideoItem?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
        count: 2
    )

    private var items: [VideoItem] {
        store.items.sorted { a, b in
            switch (a.lastPlayedAt, b.lastPlayedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.addedAt ?? .distantPast) > (b.addedAt ?? .distantPast)
            }
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                empty
                    .padding(.top, 56)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        card(item)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 120)
            }
        }
        .fullScreenCover(item: $playing) { item in
            VideoPlayerView(item: item)
        }
    }

    private func card(_ item: VideoItem) -> some View {
        Button {
            store.notePlayed(item.id)
            playing = item
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    VideoCover(item: item)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if item.progress > 0.01 {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(settings.theme.accent)
                                .frame(width: geo.size.width * min(max(item.progress, 0), 1), height: 2.5)
                        }
                        .frame(height: 2.5)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 5)
                    }
                }

                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(settings.theme.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    Text(item.sourceName)
                    if item.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 9))
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(settings.theme.secondary)
                .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.toggleFavorite(item.id)
            } label: {
                Label(item.isFavorite ? "取消收藏" : "收藏", systemImage: item.isFavorite ? "heart.slash" : "heart")
            }
            if !item.isDownloaded {
                Button {
                    store.download(item)
                } label: {
                    Label("下载到本机", systemImage: "arrow.down.circle")
                }
            }
            Button(role: .destructive) {
                store.delete(item.id)
            } label: {
                Label("从书架移除", systemImage: "trash")
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(settings.theme.secondary)
            Text("还没有视频")
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            Text("去搜索里看开源动画或公共领域影像。\n也可以自己贴一个 mp4 / m3u8 直链。")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
                .multilineTextAlignment(.center)
            Button {
                onSearch()
            } label: {
                Text("去找片")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(settings.theme.accent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}
