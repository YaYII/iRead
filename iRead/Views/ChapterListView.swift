import SwiftUI
import Foundation

/// 目录页：展示全书章节、按标题搜索，点击跳转并关闭。
/// 外层负责 NavigationStack / sheet 的呈现，这里只负责内容与 dismiss。
struct ChapterListView: View {
    let book: Book
    let content: BookContent
    let currentIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    /// 下载状态要实时跟着涨，所以观察单例而不是只读传入的 book 快照
    @ObservedObject private var downloadManager = NovelDownloadManager.shared
    // 主题配色用单例读取，避免依赖外层是否注入 environmentObject
    @ObservedObject private var settings = ReaderSettings.shared
    @State private var query = ""
    /// 书源那边的完整目录（只有没下完时才去取）。
    /// 本地文件里没有未下载的章，光靠 content 列不出「还差哪几章」。
    @State private var remoteTitles: [String]?
    /// 点了未下载的章时弹提示
    @State private var pendingIndex: Int?
    @State private var showUndownloadedAlert = false
    /// 搜索框焦点：点列表或空白就收键盘，不用去够键盘上的「完成」
    @FocusState private var searchFocused: Bool

    private var theme: ReadingTheme { settings.theme }

    /// 书架里的最新状态：下载会在阅读过程中继续，book 快照不会自己更新
    private var liveBook: Book { store.book(book.id) ?? book }

    /// 还差多少章没下（0 = 已是最新 / 非网络书）
    private var missing: Int { liveBook.missingChapters }

    private var isDownloading: Bool {
        downloadManager.task(forBookID: book.id)?.isActive ?? false
    }

    /// 头部那行说明：网络书报真实缺口，本地书才是「共 N 章」。
    /// 目录里只有已落盘的章节，所以「还差 N 章」必须写出来，
    /// 否则用户会以为这本书就这么多章。
    private var headerSubtitle: String {
        guard liveBook.remoteURL != nil,
              let total = liveBook.download?.total, total > 0 else {
            return "共 \(content.chapterCount) 章"
        }
        guard missing > 0 else { return "共 \(total) 章 · 已全部下载" }
        return "已下 \(liveBook.downloadedChapters)/\(total) 章 · 还差 \(missing) 章"
    }

    /// 目录行：可能已下载，也可能只在书源里（灰掉、点了提示先下载）
    private struct CatalogRow: Identifiable {
        let index: Int
        let title: String
        let isDownloaded: Bool
        var id: Int { index }
    }

    /// 合并后的目录。
    ///
    /// 下载过的用本地标题（阅读器显示的就是它）；没下过的用书源标题并置灰。
    /// 书源目录拿回来之前、或它并不比本地长（已下全 / 解析有偏差），
    /// 就退回「只列本地章节」的老行为，绝不凭空造行。
    private var allRows: [CatalogRow] {
        let local = content.chapters
        guard let remote = remoteTitles, remote.count > local.count else {
            return local.map { CatalogRow(index: $0.index, title: $0.title, isDownloaded: true) }
        }
        return remote.enumerated().map { i, title in
            let downloaded = i < local.count
            return CatalogRow(index: i, title: downloaded ? local[i].title : title, isDownloaded: downloaded)
        }
    }

    private var filteredRows: [CatalogRow] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return allRows }
        return allRows.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .simultaneousGesture(dismissOnTap)
            searchBar
            chapterList
                .simultaneousGesture(dismissOnTap)
            footer
        }
        .background(theme.background.ignoresSafeArea())
    }

    /// 点空白处收键盘。`onTapGesture` 会把章节行的点击吃掉，所以用 simultaneous。
    private var dismissOnTap: some Gesture {
        TapGesture().onEnded { searchFocused = false }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(book.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(missing > 0 ? theme.accent : theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.secondary)
            TextField("搜索章节标题", text: $query)
                .focused($searchFocused)
                .foregroundStyle(theme.foreground)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - 章节列表

    private var chapterList: some View {
        // 目录默认要停在「正在读的这一章」，而不是从头列起 ——
        // 几百章的书从第 1 章翻到第 300 章并不现实。
        ScrollViewReader { proxy in
            listBody
                // 目录一划就收键盘，不然半屏都被键盘占着
                .scrollDismissesKeyboard(.immediately)
                .onAppear { scrollToCurrent(proxy) }
                // 书源目录是异步回来的，合并后行数变了，得再定位一次
                .onChange(of: remoteTitles?.count ?? 0) { _, _ in scrollToCurrent(proxy) }
        }
    }

    /// 把当前章滚进视野。搜索时不动：那时候用户要看的是搜索结果。
    ///
    /// 不用 `.center`：半屏高的抽屉里居中，上下各露半行，顶部那半行还贴着搜索框，
    /// 看起来像渲染错位。改成让当前章落在「上面留 1 章」的位置 ——
    /// 标题允许两行，一屏只放得下四五章，留两行会把当前章挤到页脚底下。
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = max(0, currentIndex - 1)
        // 等一帧让 List 先把行建出来，否则 scrollTo 找不到目标（尤其大目录）
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private var listBody: some View {
        List {
            if filteredRows.isEmpty {
                Text("未找到匹配的章节")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(theme.background)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredRows) { row in
                    Button {
                        if row.isDownloaded {
                            onSelect(row.index)
                            dismiss()
                        } else {
                            // 没下过的章没法阅读，先引导去续传
                            pendingIndex = row.index
                            showUndownloadedAlert = true
                        }
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(row.index == currentIndex ? theme.accent : Color.clear)
                                .frame(width: 3, height: 22)

                            Text("第 \(row.index + 1) 章")
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                                .frame(width: 58, alignment: .leading)

                            Text(row.title)
                                .font(.body)
                                .foregroundStyle(rowTitleColor(row))
                                // 最多两行：章节名往往只差结尾的「（三）」「（四）」，
                                // 单行截断会把区分点截掉，等于没法选章
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 4)

                            if row.index == currentIndex {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.accent)
                            } else if !row.isDownloaded {
                                Text("未下载")
                                    .font(.caption2)
                                    .foregroundStyle(theme.secondary)
                                    .fixedSize()
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    // scrollTo 的锚点：行本身没有 id 就定位不到
                    .id(row.index)
                    .listRowBackground(
                        row.index == currentIndex
                            ? theme.accent.opacity(0.08)
                            : theme.background
                    )
                    .listRowSeparatorTint(theme.secondary.opacity(0.22))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: book.id) {
            // 仅供截图/自测：预置搜索词，用来把某一批章节筛到一屏里
            let args = ProcessInfo.processInfo.arguments
            if let qi = args.firstIndex(of: "--debug-query"), qi + 1 < args.count {
                query = args[qi + 1]
            }
            // 只在有缺口时向书源要一次完整目录；下载器里已有缓存就不会再发请求。
            // 拿不到（网络 / 源挂了）就安静地退回只列本地章节，不打扰阅读。
            guard liveBook.missingChapters > 0 else { return }
            if let detail = await NovelDownloadManager.shared.catalog(for: book.id) {
                remoteTitles = detail.chapters.map(\.title)
            }
            // 仅供截图/自测：直接弹出「这一章还没下载」的提示
            if ProcessInfo.processInfo.arguments.contains("--debug-undownloaded") {
                try? await Task.sleep(nanoseconds: 400_000_000)
                pendingIndex = content.chapterCount
                showUndownloadedAlert = true
            }
        }
        .alert(pendingIndex.map { "第 \($0 + 1) 章还没下载" } ?? "这一章还没下载",
               isPresented: $showUndownloadedAlert) {
            Button("下载剩余 \(missing) 章") {
                downloadManager.continueDownload(book.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            // 不写「本地只有前 N 章」：下载在后台继续，弹窗文案里的 N 一眨眼就过期，
            // 和头部「已下 x/711」对不上反而让人怀疑。只说清行为和后果。
            Text("本地还没有这一章的正文。下载会从已下的位置接着下，不会重下前面的章节。")
        }
    }

    private func rowTitleColor(_ row: CatalogRow) -> Color {
        if !row.isDownloaded { return theme.secondary }
        return row.index == currentIndex ? theme.accent : theme.foreground
    }

    // MARK: - 底部提示

    /// 是否已经把书源目录合进来了（合并后才会有灰色未下载行）
    private var showsRemoteRows: Bool {
        (remoteTitles?.count ?? 0) > content.chapterCount
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if missing > 0 {
                // 目录拿回来了就说明「灰色那几章还没下」；没拿回来也要讲清楚列表为什么不全
                Text(showsRemoteRows
                     ? "灰色章节还没下载，点一下可以继续下载"
                     : "目录只显示已下载的章节，还有 \(missing) 章未下载")
                    .font(.caption)
                    .foregroundStyle(theme.secondary)

                Button {
                    downloadManager.continueDownload(book.id)
                } label: {
                    HStack(spacing: 6) {
                        if isDownloading {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption)
                        }
                        Text(isDownloading ? "正在下载剩余 \(missing) 章" : "继续下载剩余 \(missing) 章")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().stroke(theme.accent, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)
            } else {
                Text("本章起读，进度自动保存")
                    .font(.footnote)
                    .foregroundStyle(theme.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(theme.background)
    }
}
