import SwiftUI

/// 音乐频道：搜开源曲库，点一下就在线播，同时自动存一份到本机。
/// 「我的音乐」不是单独的收藏夹 —— 播过的歌都会进来，下次不用重搜。
struct MusicSearchView: View {
    /// 自检只跑一次，避免 TabView 翻页时重复触发
    private static var selftestStarted = false

    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var store = MusicStore.shared
    @ObservedObject private var player = MusicPlayer.shared
    /// 订阅下载器，「存到本机」的进度环才会动
    @ObservedObject private var downloads = MediaDownloader.shared

    @State private var keyword = ""
    @State private var results: [MusicTrack] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var showSources = false
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
        .sheet(isPresented: $showSources) {
            MusicSourceSheet()
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--music-selftest") {
                // TabView 翻页会让同一页 onAppear 多次触发，自检只跑一次
                if !Self.selftestStarted {
                    Self.selftestStarted = true
                    Task { await runSelfTest() }
                }
                return
            }
            if results.isEmpty, !hasSearched {
                loadRecommended()
            }
        }
    }

    private var dismissOnTap: some Gesture {
        TapGesture().onEnded { searchFocused = false }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("音乐")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(settings.theme.foreground)
                Text("开源曲库 · 在线播放，自动留在本机")
                    .font(.system(size: 10))
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer(minLength: 4)
            Button {
                showSources = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(settings.theme.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("音乐来源说明")
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
            TextField("搜歌名、风格或作者", text: $keyword)
                .focused($searchFocused)
                .font(.system(size: 13))
                .foregroundStyle(settings.theme.foreground)
                .tint(settings.theme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { performSearch() }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    hasSearched = false
                    results = []
                    loadRecommended()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(settings.theme.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                performSearch()
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
        if isSearching && results.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(settings.theme.accent)
                Text("正在翻开源曲库…")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !results.isEmpty {
            list
        } else if let errorMessage {
            stateView(
                icon: "exclamationmark.triangle",
                title: "没连上曲库",
                message: "\(errorMessage)\n\nccMixter 免注册，通常是因为网络被挡；\n换个网络或稍后再试。"
            )
        } else if hasSearched {
            stateView(
                icon: "music.note.list",
                title: "没有找到这首歌",
                message: "试试英文关键词，例如 piano、ambient、guitar。\nccMixter 的曲库以英文标注为主。"
            )
        } else {
            stateView(
                icon: "music.note",
                title: "想听点什么？",
                message: "上面是本周推荐。\n搜到的歌点一下就能播，边播边存，下次离线也能听。"
            )
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !store.onDeviceTracks.isEmpty, !hasSearched {
                    sectionHeader("我的音乐", detail: "\(store.onDeviceTracks.count) 首 · 已在本机")
                    ForEach(store.onDeviceTracks.prefix(6)) { track in
                        row(track, in: Array(store.onDeviceTracks.prefix(6)))
                    }
                    sectionHeader("推荐", detail: "ccMixter 热门")
                }

                ForEach(results) { track in
                    row(track, in: results)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(settings.theme.foreground)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(settings.theme.secondary)
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func row(_ item: MusicTrack, in queue: [MusicTrack]) -> some View {
        // 搜索结果里的是「刚搜到的副本」，cachedFile 一定为空。
        // 显示状态要回 store 取，否则已经存过的歌还挂着下载按钮。
        let track = store.track(id: item.id) ?? item
        let isCurrent = player.track?.id == track.id
        let cacheState = store.cacheState(for: track)

        return Button {
            searchFocused = false
            player.play(track, queue: queue)
            PlaybackCenter.shared.openPlayer()
        } label: {
            HStack(spacing: 12) {
                MusicCover(track: track, size: 52, showsNote: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? settings.theme.accent : settings.theme.foreground)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(track.artist)
                            .lineLimit(1)
                        Text("·")
                        Text(track.durationText)
                        if track.hasLocalAudio {
                            Image(systemName: track.isLocal ? "folder.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 9))
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(settings.theme.secondary)
                }

                Spacer(minLength: 6)

                trailing(track: track, cacheState: cacheState)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if track.hasLocalAudio {
                Button(role: .destructive) {
                    store.delete(track.id)
                } label: {
                    Label(track.isLocal ? "从库里删除（同时删文件）" : "从本机移除", systemImage: "trash")
                }
            }
            if let url = URL(string: track.licenseURL) {
                Link(destination: url) {
                    Label("查看许可：\(track.license)", systemImage: "doc.text")
                }
            }
        }
    }

    @ViewBuilder
    private func trailing(track: MusicTrack, cacheState: MediaDownloader.DownloadState?) -> some View {
        if track.hasLocalAudio {
            HStack(spacing: 3) {
                Image(systemName: track.isLocal ? "folder.fill" : "checkmark.circle.fill")
                    .font(.system(size: 10))
                Text(track.isLocal ? "本机" : "已存")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(settings.theme.accent)
        } else if let cacheState, cacheState.isActive {
            ZStack {
                Circle()
                    .stroke(settings.theme.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.05, cacheState.progress))
                    .stroke(settings.theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
        } else {
            Image(systemName: player.track?.id == track.id && player.isPlaying
                  ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(settings.theme.accent)
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

    private func loadRecommended() {
        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        searchTask = Task {
            do {
                let list = try await MusicCatalog.recommended()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    results = list
                    isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    /// 自检：--music-selftest 拉推荐 → 播第一首 → 等缓存落盘 → 打日志。
    /// 只验证网络、播放、落盘链路，不依赖 UI 点击（模拟器里点不了）。
    private func runSelfTest() async {
        isSearching = true
        do {
            let list = try await MusicCatalog.recommended(limit: 5)
            NSLog("[Music selftest] results=%d", list.count)
            guard let first = list.first else {
                NSLog("[Music selftest] empty")
                await MainActor.run { self.isSearching = false }
                return
            }
            NSLog("[Music selftest] first=%@ artist=%@ url=%@", first.title, first.artist, first.streamURL)
            await MainActor.run {
                self.results = list
                self.isSearching = false
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                self.player.play(first, queue: list)
                // 截图用：自检时也想看看全屏播放器的真实排版
                if ProcessInfo.processInfo.arguments.contains("--music-open-player") {
                    PlaybackCenter.shared.openPlayer()
                }
            }

            // 首播走「先下载再放」，9 MB 的曲子要几秒，固定等 12s 会测早了。
            // 轮询到落盘（或失败）为止，最多等 45 秒。
            var waited = 0.0
            while waited < 45 {
                let stored = MusicStore.shared.track(id: first.id)
                if stored?.isCached == true { break }
                if let state = MusicStore.shared.cacheState(for: first), state.failed != nil { break }
                // 每 2 秒打一次，能看出进度是真在走还是从 0 直接跳完成
                if waited.truncatingRemainder(dividingBy: 2) == 0 {
                    let state = MusicStore.shared.cacheState(for: first)
                    NSLog("[Music selftest] t=%.0fs progress=%.2f received=%lld/%lld",
                          waited,
                          state?.progress ?? -1,
                          state?.received ?? 0,
                          state?.total ?? 0)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 0.5
            }
            // 给播放器 3 秒真正出声
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            let stored = MusicStore.shared.track(id: first.id)
            let state = MusicStore.shared.cacheState(for: first)
            let snapshot = await MainActor.run {
                (playing: player.isPlaying, time: player.currentTime, total: player.duration)
            }
            NSLog("[Music selftest] playing=%d t=%.1f/%.0f cached=%@ bytes=%lld err=%@ waited=%.1fs",
                  snapshot.playing ? 1 : 0,
                  snapshot.time,
                  snapshot.total,
                  stored?.cachedFile ?? "-",
                  stored?.cachedBytes ?? 0,
                  state?.failed ?? "-",
                  waited)
        } catch {
            NSLog("[Music selftest] failed: %@", error.localizedDescription)
            await MainActor.run {
                self.isSearching = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func performSearch() {        searchFocused = false
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            hasSearched = false
            loadRecommended()
            return
        }

        searchTask?.cancel()
        isSearching = true
        hasSearched = true
        errorMessage = nil
        results = []

        searchTask = Task {
            do {
                let list = try await MusicCatalog.search(query)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    results = list
                    isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    results = []
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }
}

// MARK: - 封面

struct MusicCover: View {
    let track: MusicTrack
    var size: CGFloat
    var showsNote: Bool = true

    @State private var artwork: UIImage?

    var body: some View {
        ZStack {
            if let artwork {
                // 导入的歌带专辑图：直接铺满，缩略图里也能一眼认出是哪张
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.18)
                    .fill(MediaArt.gradient(track.hue))

                if showsNote {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.34, weight: .light))
                        .foregroundStyle(.white.opacity(0.92))
                }

                // 首字压在右下角，列表里扫一眼能区分同名歌
                if size >= 44 {
                    Text(String(track.title.prefix(1)).uppercased())
                        .font(.system(size: size * 0.16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(size * 0.08)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .task(id: track.artworkFile) {
            artwork = track.artworkFile == nil ? nil : ArtworkStore.image(for: track)
        }
    }
}

// MARK: - 来源说明

private struct MusicSourceSheet: View {
    @ObservedObject private var settings = ReaderSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var jamendoKey = MusicCatalog.jamendoClientID ?? ""

    var body: some View {
        NavigationStack {
            List {
                Section("曲库") {
                    // 只列在线源：本机导入不是「曲库」，也没有 key 要填
                    ForEach(MusicCatalogSource.online) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(source.title).font(.headline)
                                Spacer()
                                if source == .ccmixter {
                                    Text("已启用")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                } else if MusicCatalog.jamendoClientID != nil {
                                    Text("已配置")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(source.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let url = URL(string: source.siteURL) {
                                Link(source.siteURL, destination: url).font(.caption2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    SecureField("Jamendo client_id", text: $jamendoKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存") {
                        MusicCatalog.setJamendoClientID(jamendoKey)
                        dismiss()
                    }
                    .disabled(jamendoKey == (MusicCatalog.jamendoClientID ?? ""))
                } header: {
                    Text("Jamendo（可选）")
                } footer: {
                    Text("Jamendo 的免费 API key 在 developer.jamendo.com 注册后即可拿到。不填也能用 ccMixter，不影响播放。")
                }

                Section("版权") {
                    Text("曲目均来自 Creative Commons 授权曲库，每首歌的许可协议可在列表长按查看。App 不托管任何音频文件。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("音乐来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
    }
}
