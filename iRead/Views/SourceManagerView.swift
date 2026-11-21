import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 书源管理页：启用/禁用、左滑删除自定义源、粘贴或文件导入 JSON、导出自定义源。
struct SourceManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var sourceStore = SourceStore.shared

    @State private var showFileImporter = false
    @State private var jsonText = ""
    @State private var showImportAlert = false
    @State private var importMessage = ""
    @State private var shareItem: ShareSourceText?
    @ObservedObject private var accounts = AccountStore.shared
    @State private var loginSite: AccountStore.Site?

    var body: some View {
        ZStack(alignment: .top) {
            settings.theme.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                if let error = sourceStore.lastError {
                    errorBanner(error)
                }
                List {
                    Section {
                        notice
                            .listRowBackground(Color.clear)
                    }
                    if !AccountStore.sites.isEmpty {
                        Section {
                            ForEach(AccountStore.sites) { site in
                                accountRow(site)
                                    .listRowBackground(Color.clear)
                            }
                        } header: {
                            Text("账号登录（可选）")
                                .foregroundStyle(settings.theme.secondary)
                        } footer: {
                            Text("只对「你账号里已经买过/解锁过」的章节有用，不能把未购章节变成可下载。Cookie 存本机 Keychain、不上传，也不保存账号密码，随时可退出清除。")
                                .font(.caption2)
                                .foregroundStyle(settings.theme.secondary)
                        }
                    }
                    Section {
                        ForEach(sourceStore.sources) { source in
                            sourceRow(source)
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if !source.isBuiltin {
                                        Button(role: .destructive) {
                                            sourceStore.delete(source)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("书源列表")
                            Spacer()
                            Text("已启用 \(sourceStore.enabledSources.count)/\(sourceStore.sources.count)")
                        }
                        .foregroundStyle(settings.theme.secondary)
                    }
                    Section {
                        importSection
                            .listRowBackground(Color.clear)
                    } header: {
                        Text("从 JSON 文本导入")
                            .foregroundStyle(settings.theme.secondary)
                    }
                    Section {
                        exportSection
                            .listRowBackground(Color.clear)
                    } header: {
                        Text("导出自定义书源")
                            .foregroundStyle(settings.theme.secondary)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType.json, UTType.text],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("导入结果", isPresented: $showImportAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text(importMessage)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.text])
        }
        .sheet(item: $loginSite) { site in
            AccountLoginView(site: site)
        }
    }

    /// 账号登录入口：显示登录状态，登录走内置网页（不碰账号密码），可一键退出。
    private func accountRow(_ site: AccountStore.Site) -> some View {
        let account = accounts.account(forKey: site.key)
        return HStack(spacing: 12) {
            Image(systemName: account == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                .font(.title3)
                .foregroundStyle(account == nil ? settings.theme.secondary : settings.theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(site.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(settings.theme.foreground)
                Text(account == nil ? "未登录 · 只读公开内容" : "已登录 · Cookie 仅存本机")
                    .font(.caption2)
                    .foregroundStyle(settings.theme.secondary)
            }
            Spacer(minLength: 8)
            if account == nil {
                Button("登录") { loginSite = site }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(settings.theme.accent)
                    .buttonStyle(.plain)
            } else {
                Button("退出") { accounts.remove(site.key) }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(settings.theme.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("书源管理")
                    .font(.largeTitle.bold())
                    .foregroundStyle(settings.theme.foreground)
                Text("内置源随 App 更新，自定义源存本机")
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
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(settings.theme.accent)
            Text(message)
                .font(.footnote)
                .foregroundStyle(settings.theme.foreground)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                sourceStore.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(settings.theme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.theme.accent.opacity(0.12))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var notice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondary)
            Text("内置书源随 App 更新，不可删除但可禁用；自定义书源仅保存在本机。请尊重版权，仅添加公版或授权来源。")
                .font(.footnote)
                .foregroundStyle(settings.theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.theme.secondary.opacity(0.12))
        )
    }

    // MARK: - 书源列表

    private func sourceRow(_ source: NovelSource) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(source.enabled ? settings.theme.foreground : settings.theme.secondary)
                        .lineLimit(1)
                    Text(source.isBuiltin ? "内置" : "自定义")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(source.isBuiltin ? settings.theme.secondary : settings.theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                (source.isBuiltin ? settings.theme.secondary : settings.theme.accent).opacity(0.14)
                            )
                        )
                }
                Text(domain(of: source.baseURL))
                    .font(.caption)
                    .foregroundStyle(settings.theme.secondary)
                    .lineLimit(1)
                if !source.note.isEmpty {
                    Text(source.note)
                        .font(.caption2)
                        .foregroundStyle(settings.theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { sourceStore.setEnabled(source.id, enabled: $0) }
            ))
            .labelsHidden()
            .tint(settings.theme.accent)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 导入 / 导出

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $jsonText)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(settings.theme.foreground)
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(settings.theme.secondary.opacity(0.14))
                )
            HStack(spacing: 12) {
                Button {
                    importPastedJSON()
                } label: {
                    Text("导入粘贴的 JSON")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(settings.theme.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    showFileImporter = true
                } label: {
                    Text("从文件导入")
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
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                shareItem = ShareSourceText(text: sourceStore.exportJSON())
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                    Text("导出自定义书源")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(settings.theme.accent)
                )
            }
            .buttonStyle(.plain)
            Text("仅导出自定义书源；内置源随 App 更新，无需导出。")
                .font(.caption2)
                .foregroundStyle(settings.theme.secondary)
        }
    }

    // MARK: - 行为

    private func domain(of raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return raw.isEmpty ? "未填写网址" : raw
        }
        return host
    }

    private func importPastedJSON() {
        applyImport(jsonText)
        jsonText = ""
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                applyImport(text)
            } catch {
                importMessage = "读取文件失败：\(error.localizedDescription)"
                showImportAlert = true
            }
        case .failure(let error):
            importMessage = "无法选择文件：\(error.localizedDescription)"
            showImportAlert = true
        }
    }

    private func applyImport(_ text: String) {
        do {
            let count = try sourceStore.importJSON(text)
            importMessage = "成功导入 \(count) 个书源。"
        } catch {
            importMessage = "导入失败：\(error.localizedDescription)"
        }
        showImportAlert = true
    }
}

// MARK: - UIKit 分享桥接

private struct ShareSourceText: Identifiable {
    let id = UUID()
    let text: String
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
