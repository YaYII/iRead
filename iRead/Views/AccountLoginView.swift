import SwiftUI
import WebKit

/// 站点登录页：用内置 WKWebView 打开官网，用户自己完成登录（手机号/扫码都可以）。
/// 点「完成」时把该站点的 Cookie **和 localStorage / sessionStorage** 一起存进 Keychain
/// —— 现在很多站点（含七猫桌面站）的登录态只写在 localStorage，光抓 Cookie 抓不到。
struct AccountLoginView: View {
    let site: AccountStore.Site

    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = WebViewHolder()
    @State private var isLoading = true
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var showTip = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if let url = URL(string: site.loginURL) {
                    AccountWebView(url: url, holder: holder, isLoading: $isLoading, progress: $progress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if isLoading {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(ReaderSettings.shared.theme.accent)
                }
                if showTip {
                    Text(site.tip)
                        .font(.caption2)
                        .foregroundStyle(ReaderSettings.shared.theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .transition(.opacity)
                }
            }
            .onAppear {
                // 提示只停留几秒，避免长期挡住网页自己的顶部/底部操作条
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    withAnimation(.easeInOut(duration: 0.3)) { showTip = false }
                }
            }
            .navigationTitle("登录\(site.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        captureSession()
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("完成").bold()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .alert("没有检测到登录状态", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// 同时抓 Cookie 与站点存储，然后交给 AccountStore 存 Keychain。
    private func captureSession() {
        isSaving = true
        let group = DispatchGroup()
        var cookies: [HTTPCookie] = []
        var storage = ""
        var pageText = ""

        group.enter()
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { list in
            cookies = list
            group.leave()
        }

        if let web = holder.webView {
            group.enter()
            web.evaluateJavaScript("JSON.stringify({l:Object.assign({},localStorage),s:Object.assign({},sessionStorage)})") { result, _ in
                storage = (result as? String) ?? ""
                group.leave()
            }
            group.enter()
            web.evaluateJavaScript("(document.body.innerText||'').replace(/\\s+/g,' ').slice(0,240)") { result, _ in
                pageText = (result as? String) ?? ""
                group.leave()
            }
        }

        group.notify(queue: .main) {
            isSaving = false
            let domain = site.domain.lowercased()
            let matched = cookies.filter { cookie in
                let d = cookie.domain.lowercased()
                let hit = d == domain || d == "." + domain || d.hasSuffix("." + domain)
                return hit && !cookie.value.isEmpty
            }
            var seen: Set<String> = []
            let parts = matched
                .filter { seen.insert($0.name).inserted }
                .map { "\($0.name)=\($0.value)" }

            // 只打名字，不打值
            let storageKeys = Self.storageKeyNames(storage)
            NSLog("[Account] %@ 抓取：Cookie %d 个 [%@]，storage 键 [%@]，页面片段：%@",
                  site.name, parts.count,
                  matched.map(\.name).joined(separator: ","),
                  storageKeys.joined(separator: ","),
                  String(pageText.prefix(80)))

            guard !parts.isEmpty || !storageKeys.isEmpty else {
                errorMessage = "还没有在页面里完成登录。请先点右上角登录（或扫码），登录成功后再点「完成」。"
                return
            }
            // 页面还显示「登录」且没有可识别的登录态键，基本就是没登成功
            let looksLoggedOut = pageText.contains("登录") && !pageText.contains("退出")
                && storageKeys.isEmpty && matched.count <= 3
            if looksLoggedOut {
                errorMessage = "页面看起来还没登录成功（仍显示登录入口）。完成短信验证码或扫码后再点「完成」。"
                return
            }

            AccountStore.shared.save(cookie: parts.joined(separator: "; "), for: site, storage: storage)
            NSLog("[Account] %@ 已保存登录态（Cookie %d 个，storage %d 字节）", site.name, parts.count, storage.count)
            dismiss()
        }
    }

    /// 从 {"l":{...},"s":{...}} 里取出键名，便于日志排查（值不打印）。
    private static func storageKeyNames(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var names: [String] = []
        for (scope, value) in obj {
            guard let dict = value as? [String: Any] else { continue }
            names.append(contentsOf: dict.keys.map { "\(scope).\($0)" })
        }
        return names.sorted()
    }
}

/// 让 SwiftUI 层拿到 WKWebView 实例，才能在点「完成」时执行 JS 读存储。
final class WebViewHolder: ObservableObject {
    weak var webView: WKWebView?
}

private struct AccountWebView: UIViewRepresentable {
    let url: URL
    let holder: WebViewHolder
    @Binding var isLoading: Bool
    @Binding var progress: Double

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        // 七猫登录页是桌面版布局（无 viewport），允许双指放大，配合输入框聚焦时的自动放大才够用
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 3
        web.scrollView.bouncesZoom = true
        holder.webView = web
        context.coordinator.observe(web)
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var parent: AccountWebView
        private var observation: NSKeyValueObservation?

        init(_ parent: AccountWebView) { self.parent = parent }

        func observe(_ web: WKWebView) {
            observation = web.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
                DispatchQueue.main.async {
                    self?.parent.progress = web.estimatedProgress
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.progress = 1
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
