import Foundation
import Security

// MARK: - 推理强度

/// 要不要让模型「先想再写」，以及想多久。
///
/// 这个参数**不是 App 发明的能力**：想不想、想多久，最终由模型和服务商决定。
/// 我们只做两件事：默认一个参数都不发（`follow`，谁也别被我们的猜测影响），
/// 用户明确选了才在请求里带 `reasoning_effort`。
///
/// 只给「低 / 高」两档，不给「中 / 最高」：各家认的值不一样
/// （OpenAI 是 low/medium/high，OpenCode Go 是 low/high/max），
/// 只取交集就不会出现「选了中档结果 400」。
enum AIReasoning: String, CaseIterable, Identifiable {
    case follow
    case low
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .follow: return "跟随模型"
        case .low: return "低"
        case .high: return "高"
        }
    }

    var detail: String {
        switch self {
        case .follow: return "请求里不带这个参数，想不想、想多久按模型自己的默认来"
        case .low: return "想得少、落笔快；赶进度或用量紧张时选它"
        case .high: return "想得细，前后矛盾、时间线这类硬伤拦得更准，但更慢也更贵"
        }
    }

    /// nil 表示请求里不带这个字段 —— 有些服务商对多余字段是直接 400 的
    var apiValue: String? {
        switch self {
        case .follow: return nil
        case .low: return "low"
        case .high: return "high"
        }
    }
}

// MARK: - 服务商预设

/// 一个 OpenAI 兼容的对话补全服务。国内几家都提供 `/chat/completions` 兼容口，
/// 所以不接 SDK、不绑一家：换服务商只是换 baseURL + model。
struct AIProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let hint: String
    /// 少数服务除了 `Authorization` 还要求一个固定的路由头。
    /// 目前只有 OpenCode Go（`x-opencode-session`），值本身无所谓、只用于路由。
    var sessionHeader: Bool = false

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
            id: "opencode-go",
            name: "OpenCode Go 套餐",
            baseURL: "https://opencode.ai/zen/go/v1",
            model: "deepseek-v4.1-flash",
            hint: "填 Go 套餐的 Key。地址必须是 /zen/go/v1 —— 写成 /zen/v1 扣的是 Zen 余额，余额为 0 会报 402",
            sessionHeader: true
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
///
/// **按服务商分开存**：一个人手上常有「DeepSeek 一个 Key、OpenCode Go 一个 Key」，
/// 只留一个槽位的话每次切服务商都要重新粘贴，粘错还很难看出来。
enum AIKeychain {
    private static let service = "com.yingyang.iread.ai"
    /// 老版本的单一槽位，读的时候当兜底，避免升级后 Key 突然没了
    private static let legacyAccount = "api-key"

    static func value(for providerID: String) -> String {
        read(account: "api-key.\(providerID)")
    }

    static func set(_ key: String, for providerID: String) {
        write(key, account: "api-key.\(providerID)")
    }

    /// 老版本只有一个槽位。升级时把它搬给「当时选中的服务商」，搬完就清掉。
    ///
    /// 注意别做成「谁读不到自己的就去读老槽位」的兜底 —— 那样 A 家的 Key 会被发给 B 家。
    /// 实测：把 OpenCode 的 Key 发给 api.deepseek.com，回 401，看着像 Key 失效，
    /// 实际上是把自己的 Key 交给了另一个厂商。
    static var legacy: String { read(account: legacyAccount) }

    static func clearLegacy() { write("", account: legacyAccount) }

    private static func read(account: String) -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static func write(_ key: String, account: String) {
        let data = Data(key.utf8)
        if key.isEmpty {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
            return
        }
        let updated = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecItemNotFound {
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
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
        static let reasoning = "iRead.ai.reasoning"
        static let session = "iRead.ai.session"
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
    /// 推理强度。默认 `follow` = 请求里不带 `reasoning_effort`，
    /// 模型想不想、想多久全按它自己的默认来 —— 老用户升级后行为不变。
    @Published var reasoning: AIReasoning {
        didSet { defaults.set(reasoning.rawValue, forKey: Key.reasoning) }
    }
    /// Keychain 读比 UserDefaults 慢，启动时读一次缓存在内存里
    @Published private(set) var apiKey: String
    /// OpenCode Go 要求带 `x-opencode-session`。值没有语义、只用于路由，
    /// 但要稳定：每次请求都换一个，在服务端等于每次都是新连接。
    let sessionID: String

    private let defaults = UserDefaults.standard

    private init() {
        // 初始化阶段不能通过 self 读属性（didSet 里的 defaults 也不行），先拿局部变量
        let d = UserDefaults.standard
        let savedID = d.string(forKey: Key.provider)
        let saved = AIProvider.all.first { $0.id == savedID }
        let initialID = savedID ?? "deepseek"
        providerID = initialID
        baseURL = d.string(forKey: Key.baseURL) ?? (saved ?? AIProvider.all[0]).baseURL
        model = d.string(forKey: Key.model) ?? (saved ?? AIProvider.all[0]).model
        temperature = d.object(forKey: Key.temperature) as? Double ?? 0.85
        reasoning = AIReasoning(rawValue: d.string(forKey: Key.reasoning) ?? "") ?? .follow
        // 每家的 Key 分开存，切换服务商时下面 apply() 会重新读。
        // 老版本的单一槽位在这里一次性搬到当前服务商名下，搬完删掉。
        let legacy = AIKeychain.legacy
        if !legacy.isEmpty {
            if AIKeychain.value(for: initialID).isEmpty {
                AIKeychain.set(legacy, for: initialID)
            }
            AIKeychain.clearLegacy()
        }
        apiKey = AIKeychain.value(for: initialID)

        if let existing = d.string(forKey: Key.session), !existing.isEmpty {
            sessionID = existing
        } else {
            let fresh = "iread-" + UUID().uuidString.lowercased()
            d.set(fresh, forKey: Key.session)
            sessionID = fresh
        }
    }

    var provider: AIProvider {
        AIProvider.all.first { $0.id == providerID } ?? AIProvider.custom
    }

    var providerName: String { provider.name }

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
        AIKeychain.set(trimmed, for: providerID)
    }

    func apply(_ provider: AIProvider) {
        providerID = provider.id
        if provider.id != AIProvider.custom.id {
            baseURL = provider.baseURL
            model = provider.model
        }
        // 换了一家就把那家的 Key 换上来：DeepSeek 和 OpenCode Go 用的是两个 Key，
        // 只留一个槽位时用户每次切换都得重粘
        apiKey = AIKeychain.value(for: provider.id)
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
            if code == 402 {
                return "余额不足（402）。用的是 OpenCode 的话，检查地址是 /zen/go/v1 而不是 /zen/v1"
                    + " —— 后者扣的是 Zen 余额，不是 Go 套餐。"
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
        // 必须自报家门：OpenCode 前面那层 Cloudflare 会拦掉「通用库」UA（返回 403 + error code 1010），
        // 官方的 Go 套餐条款也要求客户端带自己的 UA。默认的 CFNetwork UA 虽然多半能过，
        // 但写明 App 更符合要求，出问题时也容易在服务端日志里认出来。
        request.setValue("iRead/1.0 (iOS; AI writing)", forHTTPHeaderField: "User-Agent")
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        // OpenCode Go 的路由头。按 host 兜一层：用户把地址贴在「自定义」里也能跑通，
        // 否则会收到 400 MissingSessionID，看着像 Key 不对。
        if settings.provider.sessionHeader || (url.host?.contains("opencode.ai") ?? false) {
            request.setValue(settings.sessionID, forHTTPHeaderField: "x-opencode-session")
        }

        var payload: [String: Any] = [
            "model": settings.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature ?? settings.temperature,
            "stream": true
        ]
        // 「跟随模型」时一个字都不加：多余字段在有些服务商那儿是 400，
        // 不能因为我们想“帮上忙”就把原本能跑的请求弄挂。
        if let effort = settings.reasoning.apiValue {
            payload["reasoning_effort"] = effort
        }
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
