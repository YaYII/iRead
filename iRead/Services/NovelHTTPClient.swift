import Foundation

/// 网络书源用的轻量 HTTP 客户端。纯 URLSession，无第三方依赖。
/// 抓取到的正文/网页 Data 交给 WebText.decodeResponse 自动识别编码。
enum NovelHTTPClient {

    struct Response {
        let data: Data
        let text: String
        let finalURL: String
        let statusCode: Int
    }

    enum HTTPError: LocalizedError {
        case badURL(String)
        case httpStatus(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .badURL(let u): return "无效的地址：\(u)"
            case .httpStatus(let c): return "服务器返回 \(c)"
            case .empty: return "返回内容为空"
            }
        }
    }

    static let shared = URLSession(configuration: {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ]
        return config
    }())

    /// GET 请求。allowHTTP 控制是否允许明文 HTTP（书源可配置）。
    static func get(_ urlString: String, headers: [String: String]? = nil) async throws -> Response {
        guard let url = URL(string: urlString) else { throw HTTPError.badURL(urlString) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await perform(request)
    }

    /// POST 请求（部分书源搜索接口需要）。body 为原始字符串，通常是表单或 JSON。
    static func post(_ urlString: String, body: String, headers: [String: String]? = nil) async throws -> Response {
        guard let url = URL(string: urlString) else { throw HTTPError.badURL(urlString) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await perform(request)
    }

    private static func perform(_ request: URLRequest) async throws -> Response {
        var request = request
        // 带上用户自己登录后的 Cookie（Keychain 里按站点存）。书源规则里已显式指定则不覆盖。
        if request.value(forHTTPHeaderField: "Cookie") == nil,
           let host = request.url?.host,
           let cookie = AccountStore.shared.cookie(forHost: host) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            // URLSession 默认会用系统 Cookie 存储覆盖手写的 Cookie 头，
            // 这里关掉自动管理，确保带的就是 Keychain 里那份登录态。
            request.httpShouldHandleCookies = false
            NSLog("[HTTP] %@ 带上登录 Cookie（%d 字符）", host, cookie.count)
        }
        let (data, response) = try await shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 0 || (400..<600).contains(code) {
            throw HTTPError.httpStatus(code)
        }
        guard !data.isEmpty else { throw HTTPError.empty }
        return Response(
            data: data,
            text: WebText.decodeResponse(data),
            finalURL: http?.url?.absoluteString ?? request.url?.absoluteString ?? "",
            statusCode: code
        )
    }
}
