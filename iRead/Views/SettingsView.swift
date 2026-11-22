import SwiftUI
import Foundation

/// 「设置」页：阅读偏好、数据统计、关于与说明。
/// 不再占一个 Tab 位，由书架右上角的齿轮图标以 sheet 形式打开。
/// 页面自带 NavigationStack，作为 sheet 根视图直接可用。
struct SettingsView: View {
    @EnvironmentObject var settings: ReaderSettings
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var ai = AISettings.shared

    /// 以 sheet 呈现：右上角给「完成」，底部也不用给标签栏留那么大的空
    var presentedAsSheet: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var readerExpanded = false
    @State private var testing = false
    @State private var testResult: TestResult?

    private var theme: ReadingTheme { settings.theme }

    private var chapterTotal: Int {
        store.books.reduce(0) { $0 + $1.chapterCount }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    preferenceSection
                    aiSection
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

    // MARK: - B AI 写作

    /// 测试结果：成功也显示正文，用户能一眼确认服务真通了，而不是只看个绿点
    private struct TestResult: Equatable {
        var ok: Bool
        var text: String
    }

    private var aiSection: some View {
        sectionCard("AI 写作") {
            Menu {
                ForEach(AIProvider.all) { provider in
                    Button {
                        ai.apply(provider)
                        testResult = nil
                    } label: {
                        Text(provider.name)
                    }
                }
            } label: {
                HStack {
                    Text("服务商")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondary)
                    Spacer()
                    Text(ai.providerName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.foreground)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(theme.secondary)
                }
            }

            aiField("Base URL", text: $ai.baseURL, keyboard: .URL)
            aiField("模型", text: $ai.model)
            aiField("API Key", text: Binding(
                get: { ai.apiKey },
                set: { ai.setAPIKey($0) }
            ), secure: true)

            HStack(spacing: 10) {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 5) {
                        if testing { ProgressView().controlSize(.mini) }
                        Text(testing ? "测试中" : "测试连接")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(testing ? theme.secondary : theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.accent.opacity(testing ? 0.06 : 0.12)))
                }
                .buttonStyle(.plain)
                .disabled(testing)

                if let testResult {
                    Text(testResult.text)
                        .font(.caption2)
                        .foregroundStyle(testResult.ok ? theme.secondary : .orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(aiHint)
                .font(.caption2)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiHint: String {
        // 本地地址和云服务的注意事项是两回事，不能混在一句里：
        // 前者「不用 Key」，后者「去官网申请 Key」，混着说两句都不可信。
        if !ai.requiresKey {
            return "当前是本机 / 局域网地址，不需要 API Key，正文不会离开你的网络。"
        }
        let provider = AIProvider.all.first { $0.id == ai.providerID } ?? AIProvider.custom
        let base = provider.hint.isEmpty
            ? "任何 OpenAI 兼容服务都可以：地址填到 /v1 为止。"
            : provider.hint
        return "\(base) Key 只存本机 Keychain，不随偏好设置导出。"
    }

    private func aiField(
        _ label: String,
        text: Binding<String>,
        secure: Bool = false,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .frame(width: 62, alignment: .leading)
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .font(.caption)
            .foregroundStyle(theme.foreground)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.foreground.opacity(0.05)))
    }

    private func testConnection() {
        testing = true
        testResult = nil
        Task {
            do {
                let reply = try await AIClient.shared.ping()
                await MainActor.run {
                    testResult = TestResult(ok: true, text: "通了：\(reply.prefix(24))")
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = TestResult(ok: false, text: error.localizedDescription)
                    testing = false
                }
            }
        }
    }

    // MARK: - C 数据

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
