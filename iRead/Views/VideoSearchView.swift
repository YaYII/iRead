import SwiftUI
import AVKit

/// 动漫 / 视频频道。两类只在检索源上不同，列表和播放器完全共用。
/// 在线播放为主；想留着慢慢看就点右边的下载。
struct VideoSearchView: View {
    let kind: VideoKind

    /// 自检只跑一次：动漫/视频两个频道共用这个视图，TabView 也会重复触发 onAppear
    private static var selftestStarted = false

    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var store = VideoStore.shared

    @State private var keyword = ""
    @State private var items: [VideoItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var playing: VideoItem?
    @State private var searchTask: Task<Void, Never>?
    @State private var showAddLink = false
    @State private var newTitle = ""
    @State private var newURL = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .simultaneousGesture(dismissOnTap)
                searchBar
                content
                    .simultaneousGesture(dismissOnTap)
            }
        }
        .fullScreenCover(item: $playing) { item in
            VideoPlayerView(item: item)
        }
        .alert("添加视频直链", isPresented: $showAddLink) {
            TextField("标题", text: $newTitle)
            TextField("https://…mp4 或 .m3u8", text: $newURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("添加") { addCustom() }
        } message: {
            Text("支持 mp4 / mov / m3u8。添加后会进「视频」书架，随时能看。")
        }
        .onAppear {
            if selftestRequested {
                if !Self.selftestStarted {
                    Self.selftestStarted = true
                    Task { await runSelfTest() }
                }
                return
            }
            if items.isEmpty, !hasSearched { load() }
        }
    }

    /// 自检参数按频道分开，否则两个频道会同时抢着跑
    private var selftestRequested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return kind == .anime ? args.contains("--anime-selftest") : args.contains("--video-selftest")
    }

    private var dismissOnTap: some Gesture {
        TapGesture().onEnded { searchFocused = false }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(settings.theme.foreground)
                Text(kind == .anime
                     ? "开源动画，点开就看"
                     : "公共领域影像，支持自己加直链")
                    .font(.system(size: 10))
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer(minLength: 4)

            Button {
                newTitle = ""
                newURL = ""
                showAddLink = true
            } label: {
                Image(systemName: "link.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(settings.theme.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("添加视频直链")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(settings.theme.secondary)
            TextField(kind == .anime ? "搜动画片名" : "搜视频主题，例如 moon、launch", text: $keyword)
                .focused($searchFocused)
                .font(.system(size: 13))
                .foregroundStyle(settings.theme.foreground)
                .tint(settings.theme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { load() }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    hasSearched = false
                    items = []
                    load()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(settings.theme.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                load()
            } label: {
                Text("搜索")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(settings.theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.theme.secondary.opacity(0.14))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isSearching && items.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(settings.theme.accent)
                Text(kind == .anime ? "正在读取开源片单…" : "正在检索 NASA 影像库…")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !items.isEmpty {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(items) { item in
                        card(item)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.immediately)
        } else if let errorMessage {
            stateView(
                icon: "exclamationmark.triangle",
                title: "没连上片库",
                message: "\(errorMessage)\n\n可以先用右上角「添加直链」贴一个 mp4 地址。"
            )
        } else if hasSearched {
            stateView(
                icon: "film",
                title: "没有找到",
                message: kind == .anime
                    ? "开源动画片单不大，试试 Big Buck Bunny、Sintel。"
                    : "换个英文主题再试，例如 earth、apollo、mars。"
            )
        } else {
            stateView(
                icon: kind == .anime ? "play.rectangle.on.rectangle" : "film",
                title: kind == .anime ? "开源动画" : "公共领域影像",
                message: kind == .anime
                    ? "Blender 基金会的开源动画，CC BY 授权，可直接在线播放。\n也可以从右上角添加自己的直链。"
                    : "NASA 影像库，公共领域，可直接在线播放与下载。\n自己手里有 mp4 / m3u8 也能加进来。"
            )
        }
    }

    private func card(_ item: VideoItem) -> some View {
        let state = store.downloadState(for: item)
        return Button {
            searchFocused = false
            VideoStore.shared.remember(item)
            VideoStore.shared.notePlayed(item.id)
            playing = item
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    VideoCover(item: item)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !item.durationText.isEmpty {
                        Text(item.durationText)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.55)))
                            .padding(8)
                    }

                    if item.isDownloaded {
                        Label("已下载", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.5)))
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(settings.theme.foreground)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(item.sourceName) · \(item.license)")
                            .font(.system(size: 10))
                            .foregroundStyle(settings.theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)

                    Button {
                        if let state, state.isActive {
                            MediaDownloader.shared.cancel(id: "video:\(item.id)")
                        } else {
                            store.remember(item)
                            store.download(item)
                        }
                    } label: {
                        downloadBadge(item: item, state: state)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.remember(item)
                store.toggleFavorite(item.id)
            } label: {
                Label(item.isFavorite ? "取消收藏" : "收藏到视频书架",
                      systemImage: item.isFavorite ? "heart.slash" : "heart")
            }
            if let url = URL(string: item.streamURL) {
                Link(destination: url) {
                    Label("在浏览器打开直链", systemImage: "safari")
                }
            }
        }
    }

    @ViewBuilder
    private func downloadBadge(item: VideoItem, state: MediaDownloader.DownloadState?) -> some View {
        if item.isDownloaded {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(settings.theme.accent)
                .frame(width: 34, height: 34)
        } else if let state, state.isActive {
            ZStack {
                Circle()
                    .stroke(settings.theme.secondary.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.05, state.progress))
                    .stroke(settings.theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(settings.theme.secondary)
            }
            .frame(width: 26, height: 26)
            .frame(width: 34, height: 34)
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(settings.theme.secondary)
                .frame(width: 34, height: 34)
        }
    }

    private func stateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(settings.theme.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 36)
    }

    // MARK: - 行为

    private func load() {
        searchFocused = false
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSearched = !query.isEmpty
        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        let requestedKind = kind

        searchTask = Task {
            do {
                let list = try await VideoCatalog.search(query, kind: requestedKind)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    items = list
                    isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    items = []
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    /// 自检：--video-selftest 拉片单并把第一条的封面/直链打进控制台；
    /// 加 --play 就真的打开播放器，用「时间在走」证明这条直链能解码。
    private func runSelfTest() async {
        isSearching = true
        do {
            let list = try await VideoCatalog.search("", kind: kind)
            NSLog("[Video selftest] kind=%@ count=%d", kind.rawValue, list.count)
            if let first = list.first {
                NSLog("[Video selftest] first=%@ cover=%@ stream=%@",
                      first.title, first.coverURL ?? "-", first.streamURL)
            }
            await MainActor.run {
                self.items = list
                self.isSearching = false
            }
            if ProcessInfo.processInfo.arguments.contains("--play"), let first = list.first {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { self.playing = first }
            }
        } catch {
            NSLog("[Video selftest] failed: %@", error.localizedDescription)
            await MainActor.run {
                self.isSearching = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func addCustom() {        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }

        let item = VideoItem(
            id: "custom-\(UUID().uuidString)",
            title: title.isEmpty ? "未命名视频" : title,
            summary: "手动添加的直链",
            coverURL: nil,
            streamURL: address,
            license: "用户添加",
            sourceName: "自定义直链",
            kind: kind
        )
        store.remember(item)
        playing = item
    }
}

/// 视频封面：有图用图，没图用稳定色块 + 片名首字，避免一片灰。
struct VideoCover: View {
    let item: VideoItem

    var body: some View {
        ZStack {
            if let cover = item.coverURL.flatMap(URL.init(string:)) {
                AsyncImage(url: cover) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallback
                    }
                }            } else {
                fallback
            }
        }
        .clipped()
    }

    private var fallback: some View {
        ZStack {
            MediaArt.gradient(item.hue)
            Image(systemName: item.kind == .anime ? "play.rectangle.fill" : "film.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - 播放器

struct VideoPlayerView: View {
    let item: VideoItem

    @ObservedObject private var store = VideoStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var errorText: String?
    @State private var timeObserver: Any?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var failureObserver: NSObjectProtocol?
    @State private var resumeAfterReady = false
    /// 自检用：只打一次「真的出画面了」的证据，避免每秒刷屏
    @State private var loggedPlayback = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
            } else if let errorText {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("这段视频播不了")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                    Button("返回") { dismiss() }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.white.opacity(0.16)))
                }
                .padding(32)
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(item.license)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { setup() }
        .onDisappear { teardown() }
    }

    private func setup() {
        store.remember(item)
        store.notePlayed(item.id)
        guard let url = store.playbackURL(for: item), url.scheme != nil else {
            let reason = "地址为空或格式不对：\(item.streamURL)"
            errorText = reason
            NSLog("[VideoPlayer] bad url %@", reason)
            return
        }

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer

        // 失败回调：给一句人话，而不是让用户对着黑屏等
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            errorText = error?.localizedDescription ?? "视频解码失败"
        }

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = CMTimeGetSeconds(time)
            let total = CMTimeGetSeconds(playerItem.duration)
            guard seconds.isFinite, total.isFinite, total > 0 else { return }
            store.updateProgress(item.id, ratio: seconds / total)
            // 时间在走 = 真的解码出声了，这是「能播」最硬的证据
            if !loggedPlayback, seconds > 1 {
                loggedPlayback = true
                NSLog("[VideoPlayer] playing t=%.1f/%.0f title=%@", seconds, total, item.title)
            }
        }

        // 状态观察：既负责「接着上次看」的 seek，也负责把解码失败报出来
        statusObservation = playerItem.observe(\.status, options: [.new]) { observed, _ in
            switch observed.status {
            case .readyToPlay:
                let total = CMTimeGetSeconds(observed.duration)
                NSLog("[VideoPlayer] ready total=%.0f title=%@", total, item.title)
                guard resumeAfterReady else { return }
                DispatchQueue.main.async {
                    guard total.isFinite, total > 0 else { return }
                    observed.seek(to: CMTime(seconds: total * item.progress, preferredTimescale: 600))
                    resumeAfterReady = false
                }
            case .failed:
                let reason = observed.error?.localizedDescription ?? "视频解码失败"
                NSLog("[VideoPlayer] failed %@ title=%@", reason, item.title)
                DispatchQueue.main.async { errorText = reason }
            default:
                break
            }
        }

        // 接着上次看：等能播了再 seek，太早 seek 会被丢弃
        if item.progress > 0.02, item.progress < 0.98 {
            resumeAfterReady = true
        }

        newPlayer.play()
    }

    private func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        failureObserver = nil
        player?.pause()
        player = nil
    }
}
