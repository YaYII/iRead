import SwiftUI

/// 阅读页内嵌的排版面板（参照番茄/起点的底部抽屉）。
///
/// 设计要点：
/// - 不是 sheet，而是覆盖在正文之上的浮层 —— 调字号时上半屏的正文仍在，
///   能立刻看到效果，这是和「弹出整页设置」最大的体验差别。
/// - 没有卡片、没有分区标题，控件一行一行平铺，像实体遥控器。
/// - 每行左侧固定标签宽度，右侧控件对齐，扫视成本低。
struct ReaderPanel: View {
    @EnvironmentObject var settings: ReaderSettings

    /// 面板高度上限（由外层按屏幕高度算，展开态也不至于顶到状态栏）
    var maxHeight: CGFloat = 520

    /// 点「间距设置」展开更多排版项（截图时可用 --panel-advanced 直接展开）
    @State private var showAdvanced = ProcessInfo.processInfo.arguments.contains("--panel-advanced")

    /// 内容实测高度 —— ScrollView 会贪婪撑满父容器，必须自己量一遍再夹紧，
    /// 否则面板收起时底部会多出一大片空白。
    @State private var contentHeight: CGFloat = 330

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                brightnessRow
                divider
                fontRow
                divider
                backgroundRow
                divider
                otherRow

                if showAdvanced { advancedBlock }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: PanelHeightKey.self, value: g.size.height)
                }
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 260), maxHeight))
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
        .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
    }

    private var divider: some View {
        Divider().opacity(0.35)
    }

    // MARK: - 亮度 + 护眼

    private var brightnessRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min")
                .font(.system(size: 13))
                .foregroundStyle(theme.secondary)
            Slider(value: $settings.brightness, in: 0.2...1.0, step: 0.05)
                .tint(theme.accent)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { settings.eyeCare.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.eyeCare ? "eye.fill" : "eye")
                        .font(.system(size: 12))
                    Text("护眼模式")
                        .font(.system(size: 12))
                }
                .foregroundStyle(settings.eyeCare ? theme.accent : theme.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(settings.eyeCare ? theme.accent.opacity(0.16) : Color.clear)
                )
                .overlay(
                    Capsule().stroke(theme.secondary.opacity(0.28), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(height: 44)
    }

    // MARK: - 字号

    private var fontRow: some View {
        HStack(spacing: 10) {
            Text("字体")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondary)
                .frame(width: 30, alignment: .leading)

            // A⁻
            Button {
                settings.fontSize = max(12, settings.fontSize - 1)
            } label: {
                fontStepLabel(size: 14, symbol: "minus", dim: settings.fontSize <= 12)
            }
            .buttonStyle(.plain)
            .disabled(settings.fontSize <= 12)

            Text("\(Int(settings.fontSize))")
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.foreground)
                .frame(width: 26)

            // A⁺
            Button {
                settings.fontSize = min(36, settings.fontSize + 1)
            } label: {
                fontStepLabel(size: 20, symbol: "plus", dim: settings.fontSize >= 36)
            }
            .buttonStyle(.plain)
            .disabled(settings.fontSize >= 36)

            Spacer(minLength: 8)

            Button {
                settings.isBold.toggle()
            } label: {
                Text("粗体")
                    .font(.system(size: 12, weight: settings.isBold ? .bold : .regular))
                    .foregroundStyle(settings.isBold ? theme.accent : theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(settings.isBold ? theme.accent.opacity(0.16) : Color.clear)
                    )
                    .overlay(Capsule().stroke(theme.secondary.opacity(0.28), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 44)
    }

    private func fontStepLabel(size: CGFloat, symbol: String, dim: Bool) -> some View {
        HStack(spacing: 1) {
            Text("A").font(.system(size: size, weight: .regular))
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(dim ? theme.secondary.opacity(0.35) : theme.foreground)
        .frame(width: 52, height: 32)
        .background(Capsule().fill(theme.foreground.opacity(0.07)))
    }

    // MARK: - 背景

    private var backgroundRow: some View {
        HStack(spacing: 10) {
            Text("背景")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondary)
                .frame(width: 30, alignment: .leading)

            ForEach(ReadingTheme.allCases) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { settings.theme = t }
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(t.background)
                        .frame(width: 44, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(
                                    settings.theme == t ? theme.accent : theme.secondary.opacity(0.3),
                                    lineWidth: settings.theme == t ? 2 : 0.5
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 44)
    }

    // MARK: - 其他

    private var otherRow: some View {
        HStack(spacing: 10) {
            Text("其他")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondary)
                .frame(width: 30, alignment: .leading)

            pill("间距设置", active: showAdvanced) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAdvanced.toggle()
                }
            }
            Spacer(minLength: 0)

            // 听书相关的音色/语速已搬到独立播放器，这里只留阅读本身的开关
            Text("常亮")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondary)
            Toggle("", isOn: $settings.keepScreenOn)
                .labelsHidden()
                .tint(theme.accent)
                .scaleEffect(0.85)
        }
        .frame(height: 44)
    }

    private func pill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(active ? theme.foreground : theme.foreground.opacity(0.7))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.foreground.opacity(active ? 0.12 : 0.07))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 展开：间距

    private var advancedBlock: some View {
        VStack(spacing: 10) {
            compactSlider("行距", $settings.lineSpacing, 0...24)
            compactSlider("段间距", $settings.paragraphSpacing, 0...28)
            compactSlider("左右边距", $settings.horizontalMargin, 8...48)
            compactSlider("上下边距", $settings.verticalMargin, 8...56)
            HStack {
                Toggle("首行缩进", isOn: $settings.firstLineIndent)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondary)
                    .tint(theme.accent)
            }
        }
        .padding(.vertical, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func compactSlider(_ title: String, _ value: Binding<CGFloat>, _ range: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondary)
                .frame(width: 52, alignment: .leading)
            Slider(value: value, in: range, step: 1)
                .tint(theme.accent)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.secondary)
                .frame(width: 22, alignment: .trailing)
        }
    }

    private var theme: ReadingTheme { settings.theme }
}

/// 量取面板内容的真实高度，供外层夹紧用。
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
