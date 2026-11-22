import SwiftUI
import Foundation

/// 「设置」页：阅读偏好、数据统计、关于与说明。
/// 不再占一个 Tab 位，由书架右上角的齿轮图标以 sheet 形式打开。
/// 页面自带 NavigationStack，作为 sheet 根视图直接可用。
struct SettingsView: View {
    @EnvironmentObject var settings: ReaderSettings
    @EnvironmentObject var store: LibraryStore

    /// 以 sheet 呈现：右上角给「完成」，底部也不用给标签栏留那么大的空
    var presentedAsSheet: Bool = false

    @Environment(\.dismiss) private var dismiss
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
                    noticeSection
                    footnote
                }
                .padding(16)
                // 作为 sheet 时不被标签栏遮挡，留一点呼吸即可
                .padding(.bottom, presentedAsSheet ? 24 : 84)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .toolbar {
                if presentedAsSheet {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                }
            }
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
            signingRow
            if SigningHealth.current().needsAttention {
                Text("签名快到期了：打开 SideStore → My Apps → Refresh All；或连电脑跑 ./scripts/install-device.sh。覆盖安装不会丢书架和进度。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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

    /// 真机自签的剩余天数。普通 App 不能给自己续签，这里只负责让用户看得见、来得及刷新
    private var signingRow: some View {
        let status = SigningHealth.current()
        return HStack(alignment: .firstTextBaseline) {
            Text("签名有效期")
                .font(.subheadline)
                .foregroundStyle(theme.secondary)
            Spacer(minLength: 8)
            Text(status.summary)
                .font(.subheadline.weight(status.needsAttention ? .semibold : .regular))
                .foregroundStyle(status.needsAttention ? Color.orange : theme.foreground)
                .multilineTextAlignment(.trailing)
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

    // MARK: - D 使用声明

    private var noticeSection: some View {
        sectionCard("使用声明") {
            Text(UsageNotice.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(UsageNotice.items, id: \.self) { item in
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accent.opacity(0.12)))
                }
            }
            Text("搜书与下载功能仅用于个人学习；第三方书源的内容来源由使用者自行判断，阅读后请及时删除本地文件。")
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - E 页脚

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
