import SwiftUI

/// 听书组件里的「边听边读」。
///
/// 读的是**正在听的那本书**的正文，跟阅读页打开的是哪一本完全无关；
/// 朗读到哪一句就高亮到哪一句，并自动滚过去。用户手动一滑就停止跟随，
/// 点「回到朗读位置」再贴回去 —— 不跟用户抢滚动。
///
/// 这不是第二个阅读器：没有排版设置、不写阅读进度、不参与 UITextView 的滚动容器，
/// 只消费 ListeningCenter 暴露出来的 `spokenRange` / `spokenChapter`。
struct ListeningReadAlongView: View {
    var onBack: () -> Void

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @ObservedObject private var listening = ListeningCenter.shared

    /// 是否让视口贴着朗读走。用户一拖动正文就置 false
    @State private var following = true
    @State private var lines: [Line] = []
    @State private var loadedBookID: String?
    @State private var loadedChapter = -1

    private var theme: ReadingTheme { settings.theme }

    /// 一句正文。`range` 是**章内坐标**，用来和朗读区间求交集做高亮
    struct Line: Identifiable {
        let id: Int
        let text: String
        let range: NSRange
        let paragraphEnd: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !following {
                backToReadingBanner
            }

            scrollBody

            footer
        }
        .background(theme.background.ignoresSafeArea())
        .preferredColorScheme(theme.colorScheme)
        .onAppear { reload() }
        .onChange(of: listening.bookID) { _, _ in reload() }
        .onChange(of: listening.spokenChapter) { _, _ in reload() }
        .onChange(of: listening.chapterIndex) { _, _ in reload() }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回播放器")

            VStack(alignment: .leading, spacing: 1) {
                Text("边听边读")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                Text("\(listening.bookTitle) · \(listening.chapterTitle)")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                following.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: following ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 12))
                    Text(following ? "跟随中" : "回到朗读")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(following ? theme.accent : theme.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.foreground.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.foreground.opacity(0.08)).frame(height: 0.5)
        }
    }

    private var backToReadingBanner: some View {
        Button {
            following = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11))
                Text("已离开朗读位置 · 点此回到正在朗读的句子")
                    .font(.caption2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(theme.accent.opacity(0.10))
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - 正文

    private var scrollBody: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(size: settings.fontSize))
                            .foregroundStyle(
                                isCurrent(line) ? theme.foreground : theme.foreground.opacity(0.80)
                            )
                            .lineSpacing(settings.lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isCurrent(line) ? theme.accent.opacity(0.18) : Color.clear)
                            )
                            .id(line.id)
                            .padding(.bottom, line.paragraphEnd ? 11 : 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            // 用户一拖正文就交还控制权，不再把视口拽回朗读位置
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { _ in
                    if following { following = false }
                }
            )
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard following, let id = currentLineID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: listening.spokenRange) { _, _ in
                guard following, let id = currentLineID else { return }
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: following) { _, on in
                guard on, let id = currentLineID else { return }
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: loadedChapter) { _, _ in
                guard following else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard let id = currentLineID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - 底部播放控制

    private var footer: some View {
        VStack(spacing: 6) {
            Text(footerStatus)
                .font(.caption2)
                .foregroundStyle(theme.secondary)

            HStack(spacing: 0) {
                Button {
                    listening.previousChapter()
                } label: {
                    controlLabel("上一章", "backward.end.fill")
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    listening.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 48, height: 48)
                        if listening.isPreparingModel {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: showsPlay ? "play.fill" : "pause.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white)
                                .offset(x: showsPlay ? 1.5 : 0)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(listening.isPreparingModel)
                .accessibilityLabel(showsPlay ? "开始朗读" : "暂停朗读")

                Spacer()

                Button {
                    listening.nextChapter()
                } label: {
                    controlLabel("下一章", "forward.end.fill")
                }
                .buttonStyle(.plain)
                .disabled(listening.chapterIndex + 1 >= listening.chapterCount)
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(theme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.foreground.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func controlLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium))
            Text(title).font(.caption2)
        }
        .foregroundStyle(theme.foreground.opacity(0.85))
        .frame(minWidth: 62)
    }

    private var showsPlay: Bool { listening.isIdle || listening.isPaused }

    private var footerStatus: String {
        if listening.isPreparingModel { return "正在加载语音模型…" }
        if listening.isIdle { return "待播放" }
        if listening.isPaused { return "已暂停" }
        return "正在朗读 · 第 \(listening.chapterIndex + 1) 章"
    }

    // MARK: - 数据

    /// 当前正在念的句子 id。跨章时句子还没重建，返回 nil 让视口保持原位
    private var currentLineID: Int? {
        guard let r = listening.spokenRange,
              listening.bookID == loadedBookID,
              listening.spokenChapter == loadedChapter else { return nil }
        if let hit = lines.first(where: { NSIntersectionRange($0.range, r).length > 0 }) {
            return hit.id
        }
        return lines.last(where: { $0.range.location <= r.location })?.id
    }

    private func isCurrent(_ line: Line) -> Bool { line.id == currentLineID }

    private func reload() {
        guard let id = listening.bookID,
              let content = store.content(for: id),
              content.chapters.indices.contains(listening.chapterIndex) else {
            lines = []
            return
        }
        let chapter = listening.chapterIndex
        if loadedBookID == id, loadedChapter == chapter { return }
        // 换书才重置跟随；朗读自己跨章时保留用户「滑开自己看」的选择
        if loadedBookID != id { following = true }
        loadedBookID = id
        loadedChapter = chapter
        lines = Self.buildLines(content.chapterText(at: chapter))
    }

    /// 按句末标点 / 换行切成一行一行，保留每句在章内的 NSRange 以便高亮。
    /// 用 UTF-16 坐标（NSString 的 length 语义），和 `spokenRange` 完全一致。
    static func buildLines(_ text: NSString) -> [Line] {
        var result: [Line] = []
        let terminators: Set<Character> = ["。", "！", "？", "；", "…", "\n"]
        var start = 0
        var i = 0
        while i < text.length {
            let unit = text.substring(with: NSRange(location: i, length: 1))
            let ch = unit.first ?? " "
            if terminators.contains(ch) {
                let length = i + 1 - start
                let raw = text.substring(with: NSRange(location: start, length: length))
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(Line(
                        id: start,
                        text: trimmed,
                        range: NSRange(location: start, length: length),
                        paragraphEnd: ch == "\n"
                    ))
                }
                start = i + 1
            }
            i += 1
        }
        if start < text.length {
            let length = text.length - start
            let raw = text.substring(with: NSRange(location: start, length: length))
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(Line(
                    id: start,
                    text: trimmed,
                    range: NSRange(location: start, length: length),
                    paragraphEnd: true
                ))
            }
        }
        return result
    }
}
