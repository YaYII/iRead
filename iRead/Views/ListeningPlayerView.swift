import SwiftUI

/// 听书悬浮组件：右下角同一个位置，「听」与「播放」互斥显示。
///
/// 没在播（含刚选好书、待播放）→ 只显示「听」球，点开听书界面；
/// 一旦出声 / 暂停中 → 「听」隐藏，原地换成播放控制胶囊，点胶囊主体同样能进界面。
/// 两者永远不同时出现，位置也不跳。
struct ListeningFloatingDock: View {
    var onOpen: () -> Void
    /// 距容器底部的距离：书架要避开标签栏，阅读页要避开底部工具栏
    var bottomInset: CGFloat = 12

    @ObservedObject private var listening = ListeningCenter.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Spacer(minLength: 0)
            if listening.isActive {
                ListeningBubble(onOpen: onOpen)
                    .frame(maxWidth: 244)
                    .transition(.scale(scale: 0.86, anchor: .bottomTrailing).combined(with: .opacity))
            } else {
                ListeningEntryButton(onOpen: onOpen)
                    .transition(.scale(scale: 0.86, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, bottomInset)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: listening.isActive)
    }
}

/// 右下角的「听」悬浮球：永远在，点开听书组件，不会直接出声
private struct ListeningEntryButton: View {
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Circle()
                    .fill(Color(white: 0.24).opacity(0.92))
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
}

/// 左下角的悬浮胶囊：圆形封面 + 状态 + 播放/暂停 + 关闭
private struct ListeningBubble: View {
    var onOpen: () -> Void

    @ObservedObject private var listening = ListeningCenter.shared

    var body: some View {
        HStack(spacing: 9) {
            ListeningDisc(hue: listening.coverHue, title: listening.bookTitle, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(listening.bookTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                listening.toggle()
            } label: {
                Image(systemName: playIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsPlay ? "开始朗读" : "暂停朗读")

            Button {
                listening.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出听书")
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(white: 0.24).opacity(0.92)))
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: max(0, geo.size.width * listening.chapterProgress), height: 1.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(Capsule())
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onOpen)
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }

    /// 待播放 / 已暂停都显示「播放」，只有真的在出声才显示「暂停」
    private var showsPlay: Bool { listening.isIdle || listening.isPaused }
    private var playIcon: String { showsPlay ? "play.fill" : "pause.fill" }

    private var subtitle: String {
        if listening.isPreparingModel { return "正在加载语音模型…" }
        if listening.isIdle { return "待播放 · \(listening.chapterTitle)" }
        if listening.isPaused { return "已暂停 · \(listening.chapterTitle)" }
        return "正在朗读 · \(listening.chapterTitle)"
    }
}

/// 胶囊里的圆形封面
private struct ListeningDisc: View {
    let hue: Double
    let title: String
    let size: CGFloat

    var body: some View {
        let h = min(1, max(0, hue))
        let top = Color(hue: h, saturation: 0.58, brightness: 0.72)
        let bottom = Color(hue: h, saturation: 0.68, brightness: 0.40)
        return ZStack {
            Circle()
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            Text(String(title.prefix(1)))
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: size, height: size)
    }
}

/// 播放器用的封面：和书架同一套渐变，尺寸可变
struct ListeningCover: View {
    let hue: Double
    let title: String
    var size: CGFloat = 220
    var corner: CGFloat = 18

    var body: some View {
        let h = min(1, max(0, hue))
        let top = Color(hue: h, saturation: 0.58, brightness: 0.72)
        let bottom = Color(hue: h, saturation: 0.68, brightness: 0.40)
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            HStack {
                Rectangle()
                    .fill(Color.black.opacity(0.14))
                    .frame(width: max(3, size * 0.032))
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            Text(title)
                .font(.system(size: max(9, size * 0.075), weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
                .multilineTextAlignment(.center)
                .lineLimit(size < 60 ? 2 : 3)
                .padding(.horizontal, size * 0.12)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .frame(width: size, height: size * 4 / 3)
    }
}

/// 完整的听书播放器。
///
/// 它是一个**独立的播放器**：可以听这本、看另一本；退出阅读页也照样播。
/// 因此这里自带切章与音色/语速，不依赖任何阅读界面。
struct ListeningPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var listening = ListeningCenter.shared

    @State private var showBooks = false
    @State private var showChapters = false

    private var theme: ReadingTheme { settings.theme }

    private let speeds: [(rate: Double, label: String)] = [
        (0.40, "0.8x"), (0.50, "1.0x"), (0.60, "1.2x"), (0.70, "1.4x")
    ]

    var body: some View {
        ZStack {
            background
            if listening.bookID == nil {
                emptyState
            } else {
                content
            }
        }
        .presentationDragIndicator(.visible)
        .preferredColorScheme(theme.colorScheme)
        .sheet(isPresented: $showBooks) {
            ListeningBookPicker()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showChapters) {
            chapterSheet
                .environmentObject(store)
                .environmentObject(settings)
        }
    }

    // MARK: - 背景

    private var background: some View {
        let h = min(1, max(0, listening.coverHue))
        return ZStack {
            theme.background
            LinearGradient(
                colors: [
                    Color(hue: h, saturation: 0.45, brightness: theme == .night ? 0.28 : 0.92)
                        .opacity(theme == .night ? 0.55 : 0.55),
                    theme.background.opacity(0)
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 主体

    private var content: some View {
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    ListeningCover(hue: listening.coverHue, title: listening.bookTitle, size: 186)
                        .shadow(color: .black.opacity(theme == .night ? 0.5 : 0.22), radius: 22, y: 12)
                        .padding(.top, 6)

                    titleBlock

                    progressBlock

                    controls

                    readAlongRow

                    speedRow

                    voiceRow

                    Button {
                        listening.stop()
                        dismiss()
                    } label: {
                        Text("退出听书")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(theme.secondary)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 9)
                            .background(
                                Capsule().strokeBorder(theme.foreground.opacity(0.16), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .padding(.bottom, 26)
                }
                .padding(.horizontal, 26)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 1) {
                Text(listening.isIdle ? "听书 · 待播放" : "正在听")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
                Text(listening.engineName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.secondary.opacity(0.8))
            }

            Spacer()

            // 换书在听书组件内部完成，不经过阅读页
            Button {
                showBooks = true
            } label: {
                Image(systemName: "books.vertical")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换听书")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(listening.bookTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.foreground)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(listening.author)
                .font(.footnote)
                .foregroundStyle(theme.secondary)
            Button {
                showChapters = true
            } label: {
                HStack(spacing: 4) {
                    Text("第 \(listening.chapterIndex + 1) / \(max(1, listening.chapterCount)) 章 · \(listening.chapterTitle)")
                        .lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.foreground.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.foreground.opacity(0.10))
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: max(0, geo.size.width * listening.chapterProgress))
                }
            }
            .frame(height: 4)
            .clipShape(Capsule())

            HStack {
                Text("本章 \(Int(listening.chapterProgress * 100))%")
                Spacer()
                Text("全书 \(Int(listening.overallProgress * 100))%")
            }
            .font(.caption2)
            .foregroundStyle(theme.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button {
                listening.previousChapter()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 20, weight: .medium))
                    Text("上一章").font(.caption2)
                }
                .foregroundStyle(theme.foreground.opacity(0.85))
            }
            .buttonStyle(.plain)

            Button {
                listening.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 68, height: 68)
                        .shadow(color: theme.accent.opacity(0.32), radius: 12, y: 5)
                    if listening.isPreparingModel {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: showsPlay ? "play.fill" : "pause.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: showsPlay ? 2 : 0)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(listening.isPreparingModel)
            .accessibilityLabel(listening.isIdle ? "开始朗读" : (listening.isPaused ? "继续朗读" : "暂停朗读"))

            Button {
                listening.nextChapter()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 20, weight: .medium))
                    Text("下一章").font(.caption2)
                }
                .foregroundStyle(theme.foreground.opacity(listening.chapterIndex + 1 < listening.chapterCount ? 0.85 : 0.3))
            }
            .buttonStyle(.plain)
            .disabled(listening.chapterIndex + 1 >= listening.chapterCount)
        }
        .padding(.top, 2)
    }

    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            rowTitle("语速")
            HStack(spacing: 8) {
                ForEach(speeds, id: \.rate) { item in
                    chip(
                        item.label,
                        active: abs(settings.speechRate - item.rate) < 0.001
                    ) {
                        settings.speechRate = item.rate
                    }
                }
            }
        }
    }

    private var voiceRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            rowTitle("音色")
            HStack(spacing: 8) {
                ForEach(VoiceProfile.allCases) { profile in
                    chip(
                        profile.name,
                        active: settings.voiceProfile == profile,
                        warning: !SpeechService.isAvailable(profile)
                    ) {
                        settings.voiceProfile = profile
                    }
                }
            }
        }
    }

    /// 边听边读入口：打开**真正的阅读界面**，不是听书组件里的第二个正文视图。
    /// 阅读页会从朗读位置开始跟读，滑走了还能一键回到朗读位置。
    private var readAlongRow: some View {
        Button {
            guard let id = listening.bookID else { return }
            dismiss()
            ListeningCenter.shared.requestFollowAlong(bookID: id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.pages")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("边听边读")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.foreground)
                    Text("跟随朗读，滑到别处也能一键回到朗读位置")
                        .font(.caption2)
                        .foregroundStyle(theme.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.foreground.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    /// 待播放 / 已暂停 → 播放；真的在出声 → 暂停
    private var showsPlay: Bool { listening.isIdle || listening.isPaused }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.secondary)
    }

    private func chip(
        _ title: String,
        active: Bool,
        warning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(active ? theme.background : theme.foreground.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? theme.accent : theme.foreground.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "headphones")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.secondary)
            Text("还没有选要听的书")
                .font(.subheadline)
                .foregroundStyle(theme.secondary)
            // 选书在听书组件内部完成，不用退回书架
            Button("选择要听的书") { showBooks = true }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
    }

    /// 播放器自己的目录：选章只影响听书，不动阅读进度
    @ViewBuilder
    private var chapterSheet: some View {
        if let id = listening.bookID,
           let book = store.book(id),
           let content = store.content(for: id) {
            NavigationStack {
                ChapterListView(
                    book: book,
                    content: content,
                    currentIndex: listening.chapterIndex
                ) { index in
                    // 正在播才切；待播放时只挪位置，等用户按播放
                    listening.seekTo(chapter: index, char: 0)
                    showChapters = false
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { showChapters = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// 听书组件内部的选书页：不用回书架就能换一本听，看得见的书和听的书互不影响。
private struct ListeningBookPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @ObservedObject private var listening = ListeningCenter.shared

    private var theme: ReadingTheme { settings.theme }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.books) { book in
                        Button {
                            // 只选书、不发声；回到播放器按中间的播放键才开始
                            ListeningCenter.shared.prepare(bookID: book.id)
                            dismiss()
                        } label: {
                            row(book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("选择要听的书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .preferredColorScheme(theme.colorScheme)
        .presentationDetents([.medium, .large])
    }

    private func row(_ book: Book) -> some View {
        let current = book.id == listening.bookID
        return HStack(spacing: 12) {
            ListeningCover(hue: book.coverHue, title: book.title, size: 40, corner: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text("\(book.displayAuthor) · 共 \(book.chapterCount) 章")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if current {
                HStack(spacing: 3) {
                    Image(systemName: "waveform")
                    Text("正在听")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.accent)
            } else {
                Image(systemName: "play.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.secondary.opacity(0.7))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(current ? theme.accent.opacity(0.10) : theme.foreground.opacity(0.05))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
