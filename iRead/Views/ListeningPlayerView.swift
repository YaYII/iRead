import SwiftUI

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

                    // 音乐还在等着：点一下原地换成音乐播放器（同一个播放体系）。
                    // 位置和音乐播放器一致——都在控制区正下方，不能沉到「音色」下面去，
                    // 否则默认一屏看不到这个切换入口。
                    PlaybackSwitchChip()

                    readAlongRow

                    speedRow

                    voiceRow

                    Button {
                        // 先收起再停：停掉后播放体系会交回音乐（如果还有），
                        // 在同一帧里换内容会闪一下音乐播放器
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                            listening.stop()
                        }
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

    /// 语速：一条 0.4x～4.0x 的滑杆 + 刻度，像番茄那样拖到哪儿是哪儿。
    ///
    /// 以前是四颗固定档位按钮（0.8/1.0/1.2/1.4），想听 2 倍速根本没有。
    /// 滑杆的好处是连续可调，而且拖动时 `ListeningCenter` 已经做了 350ms 防抖，
    /// 不会一路掐断音频。
    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("语速 · \(Self.speedLabel(settings.speechSpeed))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground.opacity(0.9))
                    .monospacedDigit()
                Spacer()
                Button("重置") {
                    settings.speechSpeed = 1.0
                }
                .font(.system(size: 13))
                .foregroundStyle(abs(settings.speechSpeed - 1.0) > 0.001
                                 ? theme.accent
                                 : theme.secondary.opacity(0.35))
                .disabled(abs(settings.speechSpeed - 1.0) <= 0.001)
            }

            SpeedSlider(
                value: $settings.speechSpeed,
                range: Self.speedRange,
                ticks: Self.speedTicks,
                theme: theme
            )
            .padding(.top, 2)
        }
    }

    /// 语速范围与刻度：0.4x 起步，0.5 一格一直到 4.0x
    private static let speedRange: ClosedRange<Double> = 0.4...4.0
    private static let speedTicks: [Double] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]

    /// 1.0 显示成「1.0x」，1.7 显示成「1.7x」
    static func speedLabel(_ speed: Double) -> String {
        String(format: "%.1fx", speed)
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

// MARK: - 语速滑杆

/// 0.4x～4.0x 的语速滑杆 + 刻度，番茄那种「拖到哪儿是哪儿」的手感。
///
/// 为什么自己画而不用系统 `Slider`：系统滑杆的拇指会占掉轨道两端（各半个拇指宽），
/// 值域被压在 `[拇指半径, 宽度-拇指半径]` 里，而刻度是按整个宽度摆的 —— 结果就是
/// 「1.4x」的拇指会落在 1.5 的刻度上。自己画以后，拇指、已选段、刻度共用一套坐标，
/// 数值和刻度永远对得上。
///
/// 刻度没有画在轨道上：轨道只有 4pt 高，刻度线横切过去会把轨道切成一段段虚线，
/// 看着像进度条碎掉。改成轨道下面单独一行细刻度，轨道保持连续。
private struct SpeedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let ticks: [Double]
    let theme: ReadingTheme

    /// 拖动时每 0.1 一档
    private let step: Double = 0.1
    private let trackHeight: CGFloat = 30
    private let thumbSize: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let width = geo.size.width
                let span = range.upperBound - range.lowerBound
                // 两端各留半个拇指，否则拉到 0.4x / 4.0x 时拇指会被裁掉一半
                let inset = thumbSize / 2
                let track = max(1, width - thumbSize)
                let pct = min(max((value - range.lowerBound) / span, 0), 1)
                let thumbX = inset + track * pct

                ZStack {
                    Capsule()
                        .fill(theme.foreground.opacity(0.16))
                        .frame(width: track, height: 4)
                        .position(x: inset + track / 2, y: trackHeight / 2)

                    Capsule()
                        .fill(theme.accent)
                        .frame(width: max(0, thumbX - inset), height: 4)
                        .position(x: inset + max(0, thumbX - inset) / 2, y: trackHeight / 2)

                    // 橙色实心 + 一圈背景色描边，深浅主题下都跳得出来
                    Circle()
                        .fill(theme.accent)
                        .overlay(Circle().strokeBorder(theme.background, lineWidth: 2.5))
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
                        .position(x: thumbX, y: trackHeight / 2)
                }
                .contentShape(Rectangle())
                // 播放器正文在 ScrollView 里，普通 gesture 会被竖向滚动抢走；
                // 滑杆是全宽控件，用高优先级手势接管这一条区域才拖得动。
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let raw = range.lowerBound
                                + ((gesture.location.x - inset) / track) * span
                            let snapped = (raw / step).rounded() * step
                            let clamped = min(max(snapped, range.lowerBound), range.upperBound)
                            // 浮点误差会让 1.7000000000000002 这种值落进界面，先修一下
                            value = (clamped * 10).rounded() / 10
                        }
                )
            }
            .frame(height: trackHeight)

            // 刻度线 + 数字：与滑杆共用 inset / track，所以永远对得齐
            GeometryReader { geo in
                let width = geo.size.width
                let span = range.upperBound - range.lowerBound
                let inset = thumbSize / 2
                let track = max(1, width - thumbSize)
                ForEach(ticks, id: \.self) { tick in
                    let x = inset + track * (tick - range.lowerBound) / span
                    VStack(spacing: 1) {
                        Capsule()
                            .fill(theme.foreground.opacity(0.22))
                            .frame(width: 1, height: 3)
                        Text(String(format: "%.1f", tick))
                            .font(.system(size: 9))
                            .foregroundStyle(theme.secondary.opacity(0.65))
                            .monospacedDigit()
                    }
                    // 首尾两个数字往里收，否则会被裁掉半个
                    .position(x: min(max(x, 11), width - 11), y: 7)
                }
            }
            .frame(height: 16)
            .allowsHitTesting(false)
        }
        .accessibilityElement()
        .accessibilityLabel("语速")
        .accessibilityValue(String(format: "%.1f 倍", value))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? step : -step
            let next = min(max(value + delta, range.lowerBound), range.upperBound)
            value = (next * 10).rounded() / 10
        }
    }
}
