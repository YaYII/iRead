import Foundation
import SwiftUI

/// 网络搜书页：遍历已启用书源聚合搜索结果，展示可下载的书目并进入书籍详情。
/// 主题、书源、下载状态均通过单例读取，保证在 sheet 中单独呈现时也能拿到数据。
struct NovelSearchView: View {
    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var downloadManager = NovelDownloadManager.shared

    @State private var keyword = ""
    @State private var isSearching = false
    @State private var results: [SearchResult] = []
    @State private var errorMessage: String?
    @State private var warningMessage: String?
    @State private var hasSearched = false
    @State private var showNotice = false
    @State private var showSourceManager = false
    @State private var selectedResult: SearchResult?
    /// 仅供自动化自测：直接弹出站点登录页
    @State private var loginSite: AccountStore.Site?
    /// 当前搜索任务：再次搜索时先取消旧的，避免旧结果回填到新关键词上
    @State private var searchTask: Task<Void, Never>?
    /// 每条结果的章节规模（懒加载，滚到哪查到哪）
    @State private var stats: [String: ChapterStats] = [:]
    @State private var statsLoading: Set<String> = []
    /// 章节数查询失败的条目：网络抖动或书源风控，一次失败不代表下不了，
    /// 重试一次仍失败就标「章数未知」而不是躲起来。
    @State private var statsFailed: Set<String> = []
    /// 章节信息拿不到（目录为空 / 一章正文都没有）的条目直接隐藏：点进去也下不了。
    /// 保留开关，方便回看「为什么被过滤」。
    @State private var hideUnavailable = true
    /// 排序：默认按书源顺序（同名书相邻）；切到「章节最多」时按可下章数降序。
    @State private var sortMode: SortMode = .source
    /// 「章节最多」需要先把整批结果的章节数查完（列表本身是滚到哪查到哪）
    @State private var statsLoadTask: Task<Void, Never>?
    /// 章节数查询限流：同时最多 4 个，避免把书源打爆
    private static let statsGate = StatsGate(limit: 4)

    private enum SortMode {
        case source
        case chapters

        var title: String {
            switch self {
            case .source: return "按书源"
            case .chapters: return "章节最多"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // 搜过一次就把「大标题 + 免责声明卡」收起来：这两块常驻要吃掉将近一半屏高，
                // 结果一多就没地方看了。声明在设置页、书籍详情页都还在，这里留个 ⓘ 随时可查。
                if hasSearched {
                    compactHeader
                } else {
                    header
                    disclaimer
                }
                searchBar
                content
            }
            .animation(.easeInOut(duration: 0.22), value: hasSearched)
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .alert("使用说明", isPresented: $showNotice) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(UsageNotice.text + "\n\n搜索仅用于找书，正文下载到本机后离线阅读；第三方书源请自行判断来源。")
        }
        .sheet(isPresented: $showSourceManager) {
            SourceManagerView()
        }
        .sheet(item: $selectedResult) { result in
            NovelDetailView(result: result)
        }
        .sheet(item: $loginSite) { site in
            AccountLoginView(site: site)
        }
        .onAppear {
            // 仅供自动化自测：--search-key=红楼梦 启动时自动填入并搜索
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--search-key"), i + 1 < args.count {
                keyword = args[i + 1]
                performSearch()
            }
            // 仅供自动化自测：--show-unavailable 启动时不过滤，用于截图/核对被隐藏的条目
            if args.contains("--show-unavailable") {
                hideUnavailable = false
            }
            // 仅供自动化自测：--debug-sources 直接打开书源管理（截图/核对账号登录区）
            if args.contains("--debug-sources") {
                showSourceManager = true
            }
            // 仅供自动化自测：--sort-chapters 在搜索结果到齐后自动点一次排序（见 performSearch 末尾）
            // 仅供自动化自测：--debug-login fanqie 直接打开对应站点的登录页
            if let i = args.firstIndex(of: "--debug-login"), i + 1 < args.count,
               let site = AccountStore.site(forKey: args[i + 1]) {
                loginSite = site
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("搜书")
                    .font(.largeTitle.bold())
                    .foregroundStyle(settings.theme.foreground)
                Text("从已启用书源中查找书名与作者")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer()
            Button {
                showSourceManager = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(settings.theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(settings.theme.secondary.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("书源管理")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    /// 搜过之后用的细顶栏：只留标题和两个入口，把高度让给结果列表。
    private var compactHeader: some View {
        HStack(spacing: 8) {
            Text("搜书")
                .font(.title3.bold())
                .foregroundStyle(settings.theme.foreground)
            Spacer()
            Button {
                showNotice = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(settings.theme.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(settings.theme.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("使用说明")
            Button {
                showSourceManager = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(settings.theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(settings.theme.secondary.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("书源管理")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(UsageNotice.text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(settings.theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Text("搜索仅用于找书，正文下载到本机后离线阅读；第三方书源请自行判断来源。")
                    .font(.caption2)
                    .foregroundStyle(settings.theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.theme.secondary.opacity(0.12))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(settings.theme.secondary)
            TextField("搜索书名或作者", text: $keyword)
                .foregroundStyle(settings.theme.foreground)
                .tint(settings.theme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { performSearch() }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(settings.theme.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                performSearch()
            } label: {
                Text("搜索")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(settings.theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
        if !visibleResults.isEmpty {
            // 统计/排序这一条固定在列表上方：排序会让列表重排并轻微滚动，
            // 放进 ScrollView 里会被顶出屏幕，排序按钮就摸不到了。
            VStack(alignment: .leading, spacing: 0) {
                if let warning = warningMessage {
                    warningBanner(warning)
                        .padding(.horizontal, 20)
                }
                summaryBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(resultGroups) { group in
                            resultGroup(group)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
        } else if isSearching {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(settings.theme.accent)
                Text("正在搜索书源…")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            stateView(
                systemName: "exclamationmark.triangle",
                title: "搜索失败",
                message: error
            )
        } else if !results.isEmpty {
            stateView(
                systemName: "lock.doc",
                title: "这些书都下不了",
                message: "找到 \(results.count) 本，但目录为空或章节全部需要会员，没有可下载的免费章节。换个书源或关键词试试。"
            )
        } else if hasSearched {
            stateView(
                systemName: "magnifyingglass",
                title: "没有找到匹配的书",
                message: "换个书名或作者关键词，或到书源管理中启用更多书源。"
            )
        } else {
            stateView(
                systemName: "books.vertical",
                title: "开始找书",
                message: "输入书名或作者，点击搜索即可在已启用书源中查找。"
            )
        }
    }

    /// 列表上方那条：数量统计 + 排序切换 + 显示全部/只看可下载。
    private var summaryBar: some View {
        HStack(spacing: 6) {
            if isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .tint(settings.theme.secondary)
            }
            Text(listSummary)
                .font(.footnote)
                .foregroundStyle(settings.theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            sortButton
            if filteredCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        hideUnavailable.toggle()
                    }
                } label: {
                    Text(hideUnavailable ? "显示全部" : "只看可下载")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(settings.theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 排序切换：只在「书源顺序」和「章节最多」之间切，按钮上直接显示当前口径。
    /// 搜索没结束前不给点 —— 结果还在陆续回来，这时候排序没有意义。
    private var sortButton: some View {
        Button {
            toggleSort()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: sortMode == .chapters ? "arrow.down.to.line" : "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text(sortMode.title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(sortMode == .chapters ? settings.theme.accent : settings.theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    (sortMode == .chapters ? settings.theme.accent : settings.theme.secondary).opacity(0.12)
                )
            )
            .opacity(isSearching ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isSearching)
    }

    /// 同名书分组：多源都有的书放在同一区块，组内直接对比各源可下章数，
    /// 章数最多的来源标「章节最多」，方便决定下载哪个源。
    private func resultGroup(_ group: ResultGroup) -> some View {
        let best = bestResultIDs(in: group)
        return VStack(alignment: .leading, spacing: 8) {
            if group.items.count > 1 {
                // 作者一致才算「同一本书的多个源」；作者不同只是重名，得提示别混着选
                let authors = Set(group.items.map {
                    $0.author.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty })
                HStack(spacing: 6) {
                    Image(systemName: authors.count <= 1 ? "square.stack.3d.up.fill" : "exclamationmark.circle")
                        .font(.caption2)
                    Text(authors.count <= 1
                         ? "同名书 · \(group.items.count) 个源都有"
                         : "同名 · \(group.items.count) 个条目，作者不同请核对")
                        .font(.caption2.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(settings.theme.secondary)
                .padding(.leading, 4)
            }
            ForEach(group.items) { item in
                resultRow(item, isBest: best.contains(item.id))
            }
        }
    }

    /// 组内可下章数最多的结果（并列则都标）。stats 是懒加载的，
    /// 必须等整组都查过再判定，否则先返回的会白捡「章节最多」。
    private func bestResultIDs(in group: ResultGroup) -> Set<String> {
        guard group.items.count > 1 else { return [] }
        let values = group.items.compactMap { stats[$0.id] }
        guard values.count == group.items.count else { return [] }
        guard let peak = values.map(\.available).max(), peak > 0 else { return [] }
        return Set(group.items.filter { stats[$0.id]?.available == peak }.map(\.id))
    }

    private func resultRow(_ result: SearchResult, isBest: Bool = false) -> some View {
        Button {
            selectedResult = result
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(result.title)
                            .font(.headline)
                            .foregroundStyle(settings.theme.foreground)
                            .lineLimit(1)
                        if isBest {
                            Text("章节最多")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(settings.theme.accent))
                        }
                        if isDownloaded(result) {
                            Text("已下载")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(settings.theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(settings.theme.accent.opacity(0.14)))
                        }
                    }
                    Text(result.author.isEmpty ? "作者未知" : result.author)
                        .font(.caption)
                        .foregroundStyle(settings.theme.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(result.sourceName)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(settings.theme.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(settings.theme.secondary.opacity(0.16)))
                        if let s = stats[result.id] {
                            Text(chapterLabel(s))
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(s.available > 0 ? settings.theme.accent : settings.theme.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        (s.available > 0 ? settings.theme.accent : settings.theme.secondary)
                                            .opacity(0.12)
                                    )
                                )
                        } else if statsFailed.contains(result.id) {
                            Text("章数未知")
                                .font(.caption2)
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(settings.theme.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(settings.theme.secondary.opacity(0.12)))
                        }
                        if let intro = result.intro, !intro.isEmpty {
                            Text(intro)
                                .font(.caption2)
                                .foregroundStyle(settings.theme.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(settings.theme.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(settings.theme.foreground.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .task(id: result.id) { await loadStats(result) }
    }

    // MARK: - 章节数

    /// 切换排序：切到「章节最多」时先把整批章节数补齐，否则没查到的书会被排到最后。
    private func toggleSort() {
        statsLoadTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            sortMode = sortMode == .source ? .chapters : .source
        }
        guard sortMode == .chapters else { return }
        statsLoadTask = Task { await loadAllStats() }
    }

    /// 整批补章节数：并发上限由 StatsGate 控制（同时 4 个），不会把书源打爆；
    /// 已查到或已判定失败的直接跳过，切来切去不会重复请求。
    /// 每条请求本身有 6 秒上限，所以整批一定会结束；收尾时仍没结果的标「章数未知」，
    /// 免得顶部的「正在统计章节…」永远转下去。
    private func loadAllStats() async {
        let pending = results.filter { stats[$0.id] == nil && !statsFailed.contains($0.id) }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for item in pending {
                group.addTask { await self.loadStats(item) }
            }
        }
        guard !Task.isCancelled else { return }
        for item in pending where stats[item.id] == nil && !statsFailed.contains(item.id) {
            statsFailed.insert(item.id)
        }
    }

    /// 滚到哪查到哪：只给当前可见的结果补章节数，4 个源 × 十几本也不会一次性打满。
    @MainActor
    private func loadStats(_ result: SearchResult) async {
        guard stats[result.id] == nil, !statsLoading.contains(result.id),
              let source = sourceStore.source(result.sourceID) else { return }
        statsLoading.insert(result.id)
        let attemptStart = Date()
        var value = await fetchStats(result, source: source)
        // 失败先重试一次，但只重试「快速失败」：卡到超时的那种重试只会再来一次 6 秒
        if value == nil, Date().timeIntervalSince(attemptStart) < 4 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            value = await fetchStats(result, source: source)
        }
        statsLoading.remove(result.id)
        // 被取消（快速滚走 / 新一轮搜索）：既不记结果也不记失败，下次还能重查
        guard !Task.isCancelled else { return }
        if let value {
            statsFailed.remove(result.id)
            if value.available == 0 {
                // 确认下不了：淡出，配合上面的过滤，列表不会生硬跳变
                withAnimation(.easeInOut(duration: 0.2)) { stats[result.id] = value }
            } else {
                stats[result.id] = value
            }
        } else {
            statsFailed.insert(result.id)
        }
    }

    private func fetchStats(_ result: SearchResult, source: NovelSource) async -> ChapterStats? {
        // 没拿到并发名额通常是任务已被取消，直接放弃，别把请求打出去
        let queued = Date()
        guard await Self.statsGate.wait() else { return nil }
        let started = Date()
        // 单条设上限：书源偶发挂住（番茄常见 25s+ 不返回）时，不能让它把并发名额一直占着，
        // 否则整批统计会被三条卡死的请求拖垮。
        let value = try? await Self.withTimeout(seconds: 6) {
            try await NovelFetcher.chapterStats(result: result, source: source)
        }
        await Self.statsGate.signal()
        if ProcessInfo.processInfo.arguments.contains("--search-log") {
            NSLog("[Stats] %@ %.2fs（排队 %.2fs）%@",
                  source.name, Date().timeIntervalSince(started), started.timeIntervalSince(queued),
                  value.map { "\($0.available)/\($0.total)" } ?? "失败")
        }
        return value
    }

    private func chapterLabel(_ s: ChapterStats) -> String {
        // 目录接口返回空：书是占位/已下架，不是「有章节但读不到」
        if s.total == 0 { return "目录为空" }
        if s.available == 0 { return "无可下载章" }
        if s.available >= s.total { return "共 \(s.total) 章" }
        return "可下 \(s.available)/\(s.total) 章"
    }

    /// 可下载的条目：章节规模已知且可下章数 > 0。
    /// 还在查的条目先留着（避免列表闪一下又回来），查完确认 0 章再移除。
    private var visibleResults: [SearchResult] {
        guard hideUnavailable else { return results }
        return results.filter { stats[$0.id]?.available != 0 }
    }

    /// 已确认下不了的条目数（目录为空 / 一章都拿不到正文）
    private var filteredCount: Int {
        results.filter { stats[$0.id]?.available == 0 }.count
    }

    private var listSummary: String {
        if isSearching {
            return "已找到 \(visibleResults.count) 本可下载，其它书源还在返回…"
        }
        if sortMode == .chapters, statsPendingCount > 0 {
            return "正在统计章节…还剩 \(statsPendingCount) 本"
        }
        if hideUnavailable, filteredCount > 0 {
            return "共 \(visibleResults.count) 本可下载，已隐藏 \(filteredCount) 本"
        }
        return "共找到 \(visibleResults.count) 本"
    }

    /// 还没拿到章节数、也没判定失败的条目数（「章节最多」排序的准备进度）
    private var statsPendingCount: Int {
        results.filter { stats[$0.id] == nil && !statsFailed.contains($0.id) }.count
    }

    /// 已聚类的 results 里，同名书是相邻的，这里再切成展示分组。
    /// 默认保持书源顺序；切到「章节最多」后组内按可下章数降序、组间按组内最好成绩降序，
    /// 同名书仍然挨在一起，排序不会把「同一本书的几个源」拆散。
    private var resultGroups: [ResultGroup] {
        var groups: [ResultGroup] = []
        var seen: [String: Int] = [:]
        /// 原始顺序：排序时做最后一级比较，保证章数相同的条目位置稳定
        var originalIndex: [String: Int] = [:]
        for (index, item) in visibleResults.enumerated() {
            originalIndex[item.id] = index
            let key = Self.normalizedTitle(item.title)
            if let position = seen[key] {
                groups[position].items.append(item)
            } else {
                seen[key] = groups.count
                groups.append(ResultGroup(id: "\(groups.count)|\(key)", title: item.title, items: [item]))
            }
        }
        guard sortMode == .chapters else { return groups }
        // 不等到全部查完才排：点排序立刻按已有章数排，没查到的沉底，
        // 查到一本就插回它该在的位置（配合顶部「正在统计章节…」提示）。

        let ranked = groups.map { group -> (group: ResultGroup, best: Int, firstIndex: Int) in
            var sorted = group
            sorted.items.sort { lhs, rhs in
                let l = chapterRank(lhs), r = chapterRank(rhs)
                if l.available != r.available { return l.available > r.available }
                if l.total != r.total { return l.total > r.total }
                return (originalIndex[lhs.id] ?? 0) < (originalIndex[rhs.id] ?? 0)
            }
            let best = sorted.items.map { chapterRank($0).available }.max() ?? -1
            return (sorted, best, originalIndex[group.items.first?.id ?? ""] ?? 0)
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.best != rhs.best { return lhs.best > rhs.best }
                return lhs.firstIndex < rhs.firstIndex
            }
            .map(\.group)
    }

    /// 排序用的章节规模：可下章数优先，其次总章数；还没查到/查失败的排在最后。
    private func chapterRank(_ result: SearchResult) -> (available: Int, total: Int) {
        guard let value = stats[result.id] else { return (-1, 0) }
        return (value.available, value.total)
    }

    private struct ResultGroup: Identifiable {
        let id: String
        let title: String
        var items: [SearchResult]
    }

    /// 同名书聚在一起（组按首次出现顺序，组内保持书源顺序），方便横向比较各源章节数。
    private static func clusterByTitle(_ items: [SearchResult]) -> [SearchResult] {
        var order: [String] = []
        var groups: [String: [SearchResult]] = [:]
        for item in items {
            let key = normalizedTitle(item.title)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.flatMap { groups[$0] ?? [] }
    }

    private static func normalizedTitle(_ raw: String) -> String {
        var s = raw
        for token in ["《", "》", "〈", "〉", "「", "」", " ", "\u{3000}"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        return s.lowercased()
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(settings.theme.accent)
            Text(message)
                .font(.footnote)
                .foregroundStyle(settings.theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.theme.accent.opacity(0.12))
        )
        .padding(.bottom, 10)
    }

    private func stateView(systemName: String, title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 48, weight: .light))
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
        .padding(.horizontal, 40)
    }

    // MARK: - 行为

    private func isDownloaded(_ result: SearchResult) -> Bool {
        // DownloadTask.id 实为详情 URL，而 SearchResult.id 为 "sourceID|detailURL"；
        // 两种写法都尝试，确保已下载标记可靠显示。
        downloadManager.downloadedBookID(for: result.id) != nil
            || downloadManager.downloadedBookID(for: result.detailURL) != nil
    }

    private func performSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hasSearched = false
            results = []
            errorMessage = "请输入书名或作者关键词"
            warningMessage = nil
            return
        }

        var sources = sourceStore.enabledSources
        // 仅供自动化自测：--search-source=<id> 只搜指定书源，便于单独截图/验证
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--search-source"), i + 1 < args.count {
            sources = sources.filter { $0.id == args[i + 1] }
        }
        guard !sources.isEmpty else {
            hasSearched = true
            results = []
            errorMessage = "当前没有启用的书源，请先到书源管理中添加或启用书源。"
            warningMessage = nil
            return
        }

        isSearching = true
        hasSearched = true
        results = []
        // 新一轮搜索回到书源顺序：排序是搜索完之后的手动动作，搜索过程中不重排
        sortMode = .source
        // 新一轮搜索：旧的章节规模缓存全部作废，否则新结果会沿用上一轮的过滤判定
        stats.removeAll()
        statsFailed.removeAll()
        statsLoading.removeAll()
        statsLoadTask?.cancel()
        statsLoadTask = nil
        errorMessage = nil
        warningMessage = nil

        searchTask?.cancel()
        let targets = sources
        let query = trimmed
        let verbose = ProcessInfo.processInfo.arguments.contains("--search-log")
        searchTask = Task {
            // 每个书源一个并发任务：谁先返回谁先上屏，单个源超时/报错不影响其它源。
            var buckets: [String: [SearchResult]] = [:]
            var failures: [String] = []
            var timeouts: [String] = []

            await withTaskGroup(of: (String, String, Double, SourceOutcome).self) { group in
                for source in targets {
                    group.addTask {
                        let started = Date()
                        func elapsed() -> Double { Date().timeIntervalSince(started) }
                        do {
                            let hits = try await Self.withTimeout(seconds: 12) {
                                try await NovelFetcher.search(source: source, keyword: query)
                            }
                            return (source.id, source.name, elapsed(), .success(hits))
                        } catch is SearchTimeoutError {
                            return (source.id, source.name, elapsed(), .timeout)
                        } catch {
                            return (source.id, source.name, elapsed(), .failed(error.localizedDescription))
                        }
                    }
                }
                for await (id, name, seconds, outcome) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    if verbose {
                        NSLog("[Search] %@ %.2fs -> %@", name, seconds, outcome.logDescription)
                    }
                    switch outcome {
                    case .success(let hits):
                        buckets[id] = hits
                        // 按书源顺序拼接，再把同名书聚到一起（同名不同源相邻，方便比章节数）
                        results = Self.clusterByTitle(targets.flatMap { buckets[$0.id] ?? [] })
                    case .timeout:
                        timeouts.append(name)
                    case .failed(let message):
                        failures.append("\(name)：\(message)")
                    }
                }
            }
            guard !Task.isCancelled else { return }
            isSearching = false
            if results.isEmpty {
                var reasons = failures
                if !timeouts.isEmpty {
                    reasons.append("\(timeouts.joined(separator: "、"))：超时")
                }
                errorMessage = reasons.isEmpty
                    ? "没有找到匹配的书，换个关键词试试。"
                    : "所有书源均搜索失败：\(reasons.prefix(2).joined(separator: "；"))"
            } else {
                var notes = failures
                if !timeouts.isEmpty {
                    notes.append("\(timeouts.joined(separator: "、"))：超时")
                }
                warningMessage = notes.isEmpty ? nil : "部分书源未返回：\(notes.prefix(2).joined(separator: "；"))"
            }
            // 仅供自动化自测：--sort-chapters 在搜索结束后自动点一次排序（模拟用户操作）
            if ProcessInfo.processInfo.arguments.contains("--sort-chapters") {
                toggleSort()
            }
        }
    }

    /// 单源结果，带来源标记，便于并发回填时区分成功/超时/失败。
    private enum SourceOutcome {
        case success([SearchResult])
        case timeout
        case failed(String)

        var logDescription: String {
            switch self {
            case .success(let hits): return "\(hits.count) 本"
            case .timeout: return "超时"
            case .failed(let message): return "失败 \(message)"
            }
        }
    }

    private struct SearchTimeoutError: Error {}

    /// 给单个书源设上限：一个站点挂住（或返回超慢）时，不让整轮搜索一直转圈。
    private static func withTimeout<T>(
        seconds: Double,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SearchTimeoutError()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw SearchTimeoutError() }
            return value
        }
    }
}

/// 简单信号量：限制同时进行的章节数查询（懒加载时最多 3 个并发）。
/// `wait()` 返回是否拿到名额：任务已被取消时直接返回 false，
/// 避免「排进等待队列却永远没人 resume」把名额耗死（取消不会唤醒 continuation）。
private actor StatsGate {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { free = limit }

    func wait() async -> Bool {
        if free > 0 {
            free -= 1
            return true
        }
        // 已经取消的任务不排队：取消不会唤醒 continuation，排进去就永久占位了
        if Task.isCancelled { return false }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return true
    }

    func signal() {
        if waiters.isEmpty {
            free += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
