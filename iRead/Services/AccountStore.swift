import Foundation
import Security

/// 书源账号登录态。
///
/// 设计约束（重要）：
/// - **不保存账号密码**，只保存登录成功后浏览器侧的 Cookie；
/// - Cookie 存 Keychain（本机、系统加密），不写日志、不上传任何服务器；
/// - 随时可在书源管理页「退出登录」清除。
///
/// 用途：让请求带上用户自己的登录态，读到「登录后才可见」的章节。
/// 不做任何解密或绕过权限的事 —— 接口返回什么就用什么，加密内容一律跳过。
final class AccountStore: ObservableObject {

    static let shared = AccountStore()

    /// 一个站点的登录态
    struct Account: Codable, Equatable {
        var key: String          // 站点标识，如 "fanqie"
        var cookie: String       // "name=value; name2=value2"
        var savedAt: Date
        /// 站点的 localStorage / sessionStorage 快照（部分站点登录态不写 Cookie，只写这里）
        var storage: String?
    }

    /// 支持登录的内置站点
    struct Site: Identifiable {
        let key: String
        let name: String
        /// 用于匹配请求 host 的根域（Cookie 存在这个域下）
        let domain: String
        let loginURL: String
        let tip: String

        var id: String { key }
    }

    /// 当前没有启用的内置站点：番茄与七猫已在 2026-11-21 按用户要求从书源里移除，
    /// 登录入口随之收起（书源管理页在 `sites` 为空时不显示这一块）。
    /// 登录能力本身保留：以后接入需要登录的源，往这里加一条 `Site` 就能用。
    static let sites: [Site] = []

    static func site(forKey key: String) -> Site? {
        sites.first { $0.key == key }
    }

    @Published private(set) var accounts: [String: Account] = [:]

    private let service = "com.yingyang.iread.accounts"
    /// cache 会被后台请求线程读取，用锁保护；accounts 只用于 UI，始终在主线程更新
    private let lock = NSLock()
    private var cache: [String: Account] = [:]

    private init() {
        reload()
    }

    // MARK: - 查询

    func hasAccount(forKey key: String) -> Bool {
        cookie(forKey: key) != nil
    }

    func cookie(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let account = cache[key], !account.cookie.isEmpty else { return nil }
        return account.cookie
    }

    /// 按请求 host 取 Cookie：`m.qimao.com` 命中 `qimao.com` 的登录态。
    func cookie(forHost host: String) -> String? {
        let lower = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        for account in cache.values where !account.cookie.isEmpty {
            guard let site = Self.site(forKey: account.key) else { continue }
            if lower == site.domain || lower.hasSuffix("." + site.domain) {
                return account.cookie
            }
        }
        return nil
    }

    func account(forKey key: String) -> Account? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    // MARK: - 写入

    func save(cookie: String, for site: Site, storage: String? = nil) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let blob = storage?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !(blob ?? "").isEmpty else { return }
        let account = Account(key: site.key, cookie: trimmed, savedAt: Date(), storage: blob)
        write(account)
        lock.lock()
        cache[site.key] = account
        lock.unlock()
        publish()
    }

    /// 站点存储快照（原始 JSON 字符串），没有则为 nil。
    func storage(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]?.storage
    }

    func remove(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        lock.lock()
        cache.removeValue(forKey: key)
        lock.unlock()
        publish()
    }

    /// 登录态是否还“新鲜”：Cookie 一般能撑很久，这里只做过期提示用。
    func isStale(_ account: Account, days: Int = 30) -> Bool {
        Date().timeIntervalSince(account.savedAt) > Double(days) * 86_400
    }

    // MARK: - Keychain

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private func write(_ account: Account) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        var query = baseQuery(account.key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private func reload() {
        var loaded: [String: Account] = [:]
        for site in Self.sites {
            var query = baseQuery(site.key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let account = try? JSONDecoder().decode(Account.self, from: data) else { continue }
            loaded[site.key] = account
            // 只打名字不打值：排查「登录了但接口不认」时先确认关键 Cookie 有没有抓到
            let names = account.cookie.split(separator: ";").compactMap {
                $0.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) }
            }
            NSLog("[Account] %@ 已存 Cookie：%@", site.name, names.joined(separator: ","))
        }
        lock.lock()
        cache = loaded
        lock.unlock()
        publish()
    }

    private func publish() {
        let snapshot: [String: Account] = {
            lock.lock()
            defer { lock.unlock() }
            return cache
        }()
        if Thread.isMainThread {
            accounts = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in self?.accounts = snapshot }
        }
    }
}
