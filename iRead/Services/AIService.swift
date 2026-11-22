import Foundation
import Security

// MARK: - 服务商预设

/// 一个 OpenAI 兼容的对话补全服务。国内几家都提供 `/chat/completions` 兼容口，
/// 所以不接 SDK、不绑一家：换服务商只是换 baseURL + model。
struct AIProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let hint: String

    static let custom = AIProvider(
        id: "custom",
        name: "自定义",
        baseURL: "",
        model: "",
        hint: "任何 OpenAI 兼容服务：填到 /v1 为止，路径由 App 补 /chat/completions"
    )

    static let all: [AIProvider] = [
        AIProvider(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            hint: "中文网文手感好、价格低。到 platform.deepseek.com 生成 API Key"
        ),
        AIProvider(
            id: "dashscope",
            name: "通义千问",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus",
            hint: "阿里云百炼的 OpenAI 兼容模式，qwen-plus 足够写小说"
        ),
        AIProvider(
            id: "moonshot",
            name: "Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            model: "moonshot-v1-32k",
            hint: "月之暗面，长上下文适合整章改写"
        ),
        AIProvider(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            hint: "需要能直连 api.openai.com 的网络环境"
        ),
        AIProvider(
            id: "local",
            name: "本机 / 局域网模型",
            baseURL: "http://127.0.0.1:11434/v1",
            model: "qwen2.5:7b",
            hint: "Ollama、LM Studio 这类本地模型，不需要 API Key，正文不出本机"
        )
    ]
}

// MARK: - API Key 存储

/// API Key 走 Keychain，不进 UserDefaults：
/// 它比其他阅读设置敏感得多，不该跟着偏好设置一起被备份、导出。
enum AIKeychain {
    private static let service = "com.yingyang.iread.ai"
    private static let account = "api-key"

    static var value: String {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
        set {
            let data = Data(newValue.utf8)
            if newValue.isEmpty {
                SecItemDelete(baseQuery as CFDictionary)
                return
            }
            let updated = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updated == errSecItemNotFound {
                var add = baseQuery
                add[kSecValueData as String] = data
                SecItemAdd(add as CFDictionary, nil)
            }
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

// MARK: - 设置

final class AISettings: ObservableObject {
    static let shared = AISettings()

    private enum Key {
        static let provider = "iRead.ai.provider"
        static let baseURL = "iRead.ai.baseURL"
        static let model = "iRead.ai.model"
        static let temperature = "iRead.ai.temperature"
    }

    @Published var providerID: String {
        didSet { defaults.set(providerID, forKey: Key.provider) }
    }
    @Published var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Key.baseURL) }
    }
    @Published var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }
    @Published var temperature: Double {
        didSet { defaults.set(temperature, forKey: Key.temperature) }
    }
    /// Keychain 读比 UserDefaults 慢，启动时读一次缓存在内存里
    @Published private(set) var apiKey: String

    private let defaults = UserDefaults.standard

    private init() {
        // 初始化阶段不能通过 self 读属性（didSet 里的 defaults 也不行），先拿局部变量
        let d = UserDefaults.standard
        let savedID = d.string(forKey: Key.provider)
        let saved = AIProvider.all.first { $0.id == savedID }
        providerID = savedID ?? "deepseek"
        baseURL = d.string(forKey: Key.baseURL) ?? (saved ?? AIProvider.all[0]).baseURL
        model = d.string(forKey: Key.model) ?? (saved ?? AIProvider.all[0]).model
        temperature = d.object(forKey: Key.temperature) as? Double ?? 0.85
        apiKey = AIKeychain.value
    }

    var providerName: String {
        AIProvider.all.first { $0.id == providerID }?.name ?? AIProvider.custom.name
    }

    /// 本地地址不要求 Key：Ollama / LM Studio 默认就没有鉴权
    var requiresKey: Bool {
        let host = URL(string: baseURL)?.host ?? ""
        return !(host == "127.0.0.1" || host == "localhost" || host.hasPrefix("192.168.")
                 || host.hasPrefix("10.") || host.hasPrefix("172."))
    }

    var isConfigured: Bool {
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !requiresKey || !apiKey.isEmpty
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed
        AIKeychain.value = trimmed
    }

    func apply(_ provider: AIProvider) {
        providerID = provider.id
        if provider.id != AIProvider.custom.id {
            baseURL = provider.baseURL
            model = provider.model
        }
    }
}

// MARK: - 请求

struct AIMessage {
    let role: String
    let content: String

    static func system(_ text: String) -> AIMessage { AIMessage(role: "system", content: text) }
    static func user(_ text: String) -> AIMessage { AIMessage(role: "user", content: text) }
}

enum AIError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有配置 AI 服务。到「设置 → AI 写作」选一个服务商、填上 API Key。"
        case .badURL:
            return "服务地址填错了，检查一下「设置 → AI 写作」里的 Base URL。"
        case .http(let code, let body):
            if code == 401 || code == 403 {
                return "鉴权失败（\(code)）：API Key 不对或已过期。"
            }
            if code == 429 {
                return "请求太频繁或额度用完了（429）。"
            }
            let brief = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "服务返回 \(code)\(brief.isEmpty ? "" : "：\(brief.prefix(120))")"
        case .empty:
            return "服务没有返回内容，换个模型或稍后重试。"
        }
    }
}

/// OpenAI 兼容的流式客户端。
///
/// 用流式而不是等整段返回：一章两三千字，非流式要干等十几秒、中途没有任何反馈，
/// 看起来像卡死。边生成边显示，用户随时能停。
final class AIClient {
    static let shared = AIClient()

    private init() {}

    func stream(
        messages: [AIMessage],
        temperature: Double? = nil,
        onDelta: @escaping (String) -> Void,
        onReasoning: ((Int) -> Void)? = nil
    ) async throws -> String {
        let settings = AISettings.shared
        guard settings.isConfigured else { throw AIError.notConfigured }

        let base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else { throw AIError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": settings.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature ?? settings.temperature,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.http(0, "没有拿到 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            // 错误响应通常是 JSON 或 HTML，读一小段就够判断原因了
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 400 { break }
            }
            throw AIError.http(http.statusCode, body)
        }

        var full = ""
        var reasoning = 0
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }

            // 推理模型的思维链：不显示给用户（写小说的思路会剧透、也没有阅读价值），
            // 但要拿来判断「它还在干活」，否则前几十秒界面一片静止。
            if let thought = delta["reasoning_content"] as? String, !thought.isEmpty {
                reasoning += thought.count
                let count = reasoning
                await MainActor.run { onReasoning?(count) }
                continue
            }

            guard let piece = delta["content"] as? String, !piece.isEmpty else { continue }
            full += piece
            let snapshot = full
            await MainActor.run { onDelta(snapshot) }
        }

        let result = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AIError.empty }
        return result
    }

    /// 设置页那个「测试连接」：发一句最短的话，能拿到内容就算通
    func ping() async throws -> String {
        try await stream(
            messages: [
                .system("你是一个测试助手，只回答两个字。"),
                .user("请回复：可用")
            ],
            temperature: 0
        ) { _ in }
    }
}
