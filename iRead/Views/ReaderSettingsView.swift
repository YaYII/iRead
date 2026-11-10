import SwiftUI
import Foundation
import AVFoundation

/// 阅读排版设置（纯内容视图）。
/// 不自带 NavigationStack /「完成」按钮，外层负责包 sheet 与关闭按钮。
///
/// 设计原则：能用图标就不用文字。参数本身就是自解释的，
/// 多摸索两下就会了，堆说明文字反而显得笨重。
struct ReaderSettingsView: View {
    @EnvironmentObject var settings: ReaderSettings

    /// 被设置页内嵌时不自带 ScrollView，跟随外层一起滚
    var embedded = false

    private var theme: ReadingTheme { settings.theme }

    var body: some View {
        if embedded {
            content
        } else {
            ScrollView { content }
                .background(theme.background.ignoresSafeArea())
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            fontCard
            spacingCard
            themeCard
            brightnessCard
            resetRow
        }
        .padding(embedded ? 0 : 14)
    }

    // MARK: - 字号

    private var fontCard: some View {
        card("textformat.size") {
            HStack(spacing: 14) {
                stepButton("minus") { settings.fontSize = max(14, settings.fontSize - 1) }
                    .disabled(settings.fontSize <= 14)
                Text("\(Int(settings.fontSize))")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.foreground)
                    .frame(minWidth: 30)
                stepButton("plus") { settings.fontSize = min(36, settings.fontSize + 1) }
                    .disabled(settings.fontSize >= 36)

                Spacer()

                iconToggle("bold", on: settings.isBold) { settings.isBold.toggle() }
                iconToggle("text.alignleft", on: settings.firstLineIndent) {
                    settings.firstLineIndent.toggle()
                }
            }

            // 所见即所得的样张，比任何文字说明都直观
            Text("读书足以怡情，足以傅彩，足以长才。")
                .font(.system(size: settings.fontSize, weight: settings.isBold ? .semibold : .regular))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
    }

    // MARK: - 间距

    private var spacingCard: some View {
        card("arrow.up.and.down.and.arrow.left.and.right") {
            iconSlider("text.line.spacing", value: $settings.lineSpacing, in: 0...24)
            iconSlider("text.append", value: $settings.paragraphSpacing, in: 0...28)
            iconSlider("arrow.left.and.right", value: $settings.horizontalMargin, in: 12...48)
            iconSlider("arrow.up.and.down", value: $settings.verticalMargin, in: 12...56)
        }
    }

    // MARK: - 主题

    private var themeCard: some View {
        card("circle.lefthalf.filled") {
            HStack(spacing: 10) {
                ForEach(ReadingTheme.allCases, id: \.self) { t in
                    Button {
                        settings.theme = t
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(t.background)
                            Text("永")
                                .font(.system(size: 20))
                                .foregroundStyle(t.foreground)
                        }
                        .frame(height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    settings.theme == t ? theme.accent : t.secondary.opacity(0.35),
                                    lineWidth: settings.theme == t ? 2 : 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 亮度

    private var brightnessCard: some View {
        card("sun.max") {
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondary)
                Slider(value: $settings.brightness, in: 0.2...1.0, step: 0.05)
                    .tint(theme.accent)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.secondary)
                iconToggle("lock.open", on: settings.keepScreenOn) {
                    settings.keepScreenOn.toggle()
                }
            }
        }
    }

    // MARK: - 恢复默认

    private var resetRow: some View {
        Button {
            settings.reset()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.secondary.opacity(0.3), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 组件

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 34)
                .background(theme.foreground.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func iconToggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(on ? theme.background : theme.secondary)
                .frame(width: 38, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(on ? theme.accent : theme.foreground.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }

    private func iconSlider(
        _ symbol: String,
        value: Binding<CGFloat>,
        in range: ClosedRange<CGFloat>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondary)
                .frame(width: 22)
            Slider(value: value, in: range, step: 1)
                .tint(theme.accent)
        }
    }

    private func card<Content: View>(
        _ symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.foreground.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.secondary.opacity(0.16), lineWidth: 0.5)
        )
    }
}
