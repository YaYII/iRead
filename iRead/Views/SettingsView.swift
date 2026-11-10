import SwiftUI
import Foundation

/// App 的「设置」Tab 页：阅读偏好、数据统计、关于与说明。
/// 自带 NavigationStack，作为 Tab 的根视图使用。
struct SettingsView: View {
    @EnvironmentObject var settings: ReaderSettings
    @EnvironmentObject var store: LibraryStore

    @State private var readerExpanded = false

    private var theme: ReadingTheme { settings.theme }

    private var chapterTotal: Int {
        store.books.reduce(0) { $0 + $1.chapterCount }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    preferenceSection
                    dataSection
                    aboutSection
                    footnote
                }
                .padding(16)
                // 给 iOS 26 浮动 Tab 栏留出空间，避免最后一张卡片被压住
                .padding(.bottom, 84)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .onAppear {
                // 仅供自动化截图：展开阅读偏好面板
                if ProcessInfo.processInfo.arguments.contains("--expand-prefs") {
                    readerExpanded = true
                }
            }
        }
    }

    // MARK: - A 阅读偏好（inline 展开复用 ReaderSettingsView）

    private var preferenceSection: some View {
        sectionCard("阅读偏好") {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    readerExpanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前排版")
                            .font(.subheadline)
                            .foregroundStyle(theme.foreground)
                        Text("\(settings.theme.name) · 字号 \(Int(settings.fontSize))")
                            .font(.caption)
                            .foregroundStyle(theme.secondary)
                    }
                    Spacer()
                    Image(systemName: readerExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if readerExpanded {
                ReaderSettingsView(embedded: true)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - B 数据

    private var dataSection: some View {
        sectionCard("数据") {
            HStack(spacing: 0) {
                statItem(value: "\(store.books.count)", label: "藏书")
                Rectangle()
                    .fill(theme.secondary.opacity(0.25))
                    .frame(width: 1, height: 34)
                statItem(value: "\(chapterTotal)", label: "章节")
                Rectangle()
                    .fill(theme.secondary.opacity(0.25))
                    .frame(width: 1, height: 34)
                statItem(value: "\(store.bookmarks.count)", label: "书签")
            }
            Text("所有书籍与阅读记录仅保存在本机，不上传")
                .font(.caption)
                .foregroundStyle(theme.secondary)
        }
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.foreground)
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - C 关于

    private var aboutSection: some View {
        sectionCard("关于") {
            infoRow(title: "应用名称", value: "iRead")
            infoRow(title: "版本", value: "1.0")
            HStack(spacing: 12) {
                ForEach(["textformat", "book.pages", "speaker.wave.2", "wifi.slash"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 2)
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(theme.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(theme.foreground)
        }
    }

    // MARK: - D 页脚

    private var footnote: some View {
        Text("本地阅读器 · 无网络书源")
            .font(.caption2)
            .foregroundStyle(theme.secondary.opacity(0.8))
            .frame(maxWidth: .infinity)
    }

    // MARK: - 分区卡片

    private func sectionCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.foreground.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }
}
