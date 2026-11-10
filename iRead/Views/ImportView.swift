import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 本地 TXT 导入页。仅从系统文件选择器读取用户自己的文件，不访问网络。
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: LibraryStore

    /// 主题用单例读取，避免 sheet 不继承 environmentObject 时缺失；
    /// @ObservedObject 让主题变更时界面同步刷新。
    @ObservedObject private var settings = ReaderSettings.shared

    @State private var showFileImporter = false
    @State private var importedCount = 0
    @State private var errorMessages: [String] = []
    @State private var hasAttempted = false

    private let capabilities: [(String, String)] = [
        ("doc.text", "TXT 文本，UTF-8 / GBK 编码自动识别"),
        ("list.number", "自动识别「第X章 / 卷X / Chapter N」等目录"),
        ("scissors", "未识别到目录时按固定长度兜底切分章节"),
        ("wifi.slash", "导入后完全离线可读，无需联网"),
        ("internaldrive", "文件仅保存在本机，不上传任何服务器")
    ]

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    importButton
                    resultSection
                    capabilitiesSection
                    disclaimer
                }
                .padding(20)
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [
                UTType.plainText,
                UTType(filenameExtension: "txt") ?? UTType.plainText
            ],
            allowsMultipleSelection: true
        ) { result in
            hasAttempted = true
            importedCount = 0
            var failures: [String] = []
            switch result {
            case .success(let urls):
                for url in urls {
                    do {
                        try store.importBook(from: url)
                        importedCount += 1
                    } catch {
                        failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
            case .failure(let error):
                failures.append("无法选择文件：\(error.localizedDescription)")
            }
            errorMessages = failures
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("导入书籍")
                    .font(.largeTitle.bold())
                    .foregroundStyle(settings.theme.foreground)
                Text("从本机选择 TXT 文件加入书架")
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
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

    // MARK: - 主按钮

    private var importButton: some View {
        Button {
            errorMessages = []
            importedCount = 0
            hasAttempted = false
            showFileImporter = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.plus")
                    .font(.title3)
                Text(hasAttempted ? "继续选择 TXT 文件" : "选择 TXT 文件")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(settings.theme.accent)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 导入结果

    @ViewBuilder
    private var resultSection: some View {
        if hasAttempted {
            VStack(alignment: .leading, spacing: 10) {
                if importedCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(settings.theme.accent)
                        Text("成功导入 \(importedCount) 本")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(settings.theme.foreground)
                    }
                }
                ForEach(errorMessages, id: \.self) { message in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(settings.theme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if importedCount > 0 {
                    Button {
                        dismiss()
                    } label: {
                        Text("完成")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(settings.theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(settings.theme.accent, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(settings.theme.foreground.opacity(0.05))
            )
        }
    }

    // MARK: - 能力说明

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("支持的能力")
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(capabilities.indices, id: \.self) { index in
                    capabilityRow(
                        systemName: capabilities[index].0,
                        text: capabilities[index].1
                    )
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

    private func capabilityRow(systemName: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemName)
                .font(.subheadline)
                .foregroundStyle(settings.theme.accent)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(settings.theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 内容来源声明

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(settings.theme.secondary)
                Text("关于内容来源")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.theme.foreground)
            }
            Text("本 App 不提供网络书源、不内置任何版权作品内容。所有书籍均由你自行导入本机 TXT 文件，阅读过程完全离线。")
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
