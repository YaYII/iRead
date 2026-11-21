import SwiftUI
import UIKit

/// WiFi 传书：显示局域网地址，电脑浏览器打开即可把 TXT 传进书架。
struct WiFiTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: LibraryStore

    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var server = WiFiTransferServer.shared

    @State private var copied = false

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    statusCard
                    stepsSection
                    recordsSection
                    disclaimer
                }
                .padding(20)
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .onAppear { server.start() }
        .onChange(of: copied) { _, newValue in
            guard newValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WiFi 传书")
                    .font(.largeTitle.bold())
                    .foregroundStyle(settings.theme.foreground)
                Text("同一 WiFi 下，用电脑或另一台手机传小说")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(settings.theme.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(settings.theme.secondary.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
    }

    // MARK: - 地址卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(server.isRunning ? "传书服务已开启" : "服务未开启")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.theme.foreground)
                Spacer()
                if server.isRunning {
                    Button("停止") { server.stop() }
                        .font(.subheadline)
                        .foregroundStyle(settings.theme.secondary)
                } else {
                    Button("开启") { server.start() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(settings.theme.accent)
                }
            }

            if let address = server.address {
                Text("在浏览器中输入这个地址")
                    .font(.caption)
                    .foregroundStyle(settings.theme.secondary)

                HStack(spacing: 8) {
                    Text(address)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(settings.theme.foreground)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = address
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline)
                            .foregroundStyle(settings.theme.accent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(settings.theme.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制地址")
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(settings.theme.foreground.opacity(0.06))
                )

                Text("地址里的 \(server.token) 是本次访问码，换一台设备/重开服务后会变。")
                    .font(.footnote)
                    .foregroundStyle(settings.theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = server.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("正在获取本机地址…")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(settings.theme.foreground.opacity(0.05))
        )
    }

    // MARK: - 步骤

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("怎么用")
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            step(number: "1", text: "手机和电脑连同一个 WiFi。")
            step(number: "2", text: "保持 iRead 打开，别切到后台太久。")
            step(number: "3", text: "电脑浏览器打开上面的地址，选择 TXT 文件，点「上传到 iRead」。")
            step(number: "4", text: "回到书架就能看到新书，之后阅读完全离线。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(settings.theme.foreground.opacity(0.05))
        )
    }

    private func step(number: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(settings.theme.accent))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(settings.theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 上传记录

    @ViewBuilder
    private var recordsSection: some View {
        if !server.records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("上传记录")
                    .font(.headline)
                    .foregroundStyle(settings.theme.foreground)
                ForEach(server.records.prefix(8)) { record in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: record.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(record.ok ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title)
                                .font(.subheadline)
                                .foregroundStyle(settings.theme.foreground)
                            Text(record.message)
                                .font(.caption)
                                .foregroundStyle(settings.theme.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(settings.theme.foreground.opacity(0.05))
            )
        }
    }

    // MARK: - 说明

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(settings.theme.secondary)
                Text("关于安全与隐私")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.theme.foreground)
            }
            Text("服务只在手机本机监听，不连接互联网、不扫描其它设备；地址带一次性访问码，只有拿到地址的人才能传。传上来的文件只保存在手机本机。传完可以点「停止」。")
                .font(.footnote)
                .foregroundStyle(settings.theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(settings.theme.secondary.opacity(0.12))
        )
    }
}
