import Foundation
import SwiftUI

/// 书源仓库：内置源随 App 打包（sources_builtin.json），用户导入的源存本地 sources_custom.json。
/// 内置源可禁用不可删除；自定义源可编辑删除；导入时按 id 去重覆盖。
final class SourceStore: ObservableObject {
    static let shared = SourceStore()

    @Published private(set) var sources: [NovelSource] = []
    @Published var lastError: String?

    private let fm = FileManager.default
    private let customURL: URL

    init() {
        let doc = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        customURL = doc.appendingPathComponent("sources_custom.json")
        load()
    }

    var enabledSources: [NovelSource] { sources.filter { $0.enabled } }

    func source(_ id: String) -> NovelSource? { sources.first { $0.id == id } }

    // MARK: - 加载

    private func load() {
        var result: [NovelSource] = []

        // 内置
        if let url = Bundle.main.url(forResource: "sources_builtin", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([NovelSource].self, from: data) {
            result.append(contentsOf: list.map {
                var s = $0
                s.isBuiltin = true
                return s
            })
        }

        // 自定义
        if let data = try? Data(contentsOf: customURL),
           let list = try? JSONDecoder().decode([NovelSource].self, from: data) {
            result.append(contentsOf: list.map {
                var s = $0
                s.isBuiltin = false
                return s
            })
        }

        // 内置兜底源：即使用户导入过自定义源，内置源也要在（按 id 去重，自定义同 id 优先）。
        // 之前只在 result 为空时才加，导致导入任意自定义源后番茄/七猫/殆知阁全部消失。
        let existing = Set(result.map(\.id))
        for builtin in Self.fallbackSources where !existing.contains(builtin.id) {
            var s = builtin
            s.isBuiltin = true
            result.append(s)
        }
        sources = result
    }

    // MARK: - 增删改

    func setEnabled(_ id: String, enabled: Bool) {
        mutate(id) { $0.enabled = enabled }
    }

    func add(_ source: NovelSource) throws {
        var s = source
        s.isBuiltin = false
        if s.id.isEmpty { s.id = "custom-\(UUID().uuidString)" }
        guard !s.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SourceError.invalid("书源名称不能为空")
        }
        guard !s.searchURL.isEmpty else {
            throw SourceError.invalid("搜索地址不能为空")
        }
        sources.removeAll { $0.id == s.id }
        sources.append(s)
        saveCustom()
    }

    func delete(_ source: NovelSource) {
        guard !source.isBuiltin else { return }
        sources.removeAll { $0.id == source.id }
        saveCustom()
    }

    /// 从 JSON 文本导入，支持单个对象或数组。
    @discardableResult
    func importJSON(_ text: String) throws -> Int {
        guard let data = text.data(using: .utf8) else { throw SourceError.invalid("编码错误") }
        let decoder = JSONDecoder()
        var list: [NovelSource]
        if let one = try? decoder.decode(NovelSource.self, from: data) {
            list = [one]
        } else if let many = try? decoder.decode([NovelSource].self, from: data) {
            list = many
        } else {
            throw SourceError.invalid("不是有效的书源 JSON")
        }
        for var s in list {
            s.isBuiltin = false
            if s.id.isEmpty { s.id = "custom-\(UUID().uuidString)" }
            guard !s.searchURL.isEmpty else { continue }
            sources.removeAll { $0.id == s.id }
            sources.append(s)
        }
        saveCustom()
        return list.count
    }

    /// 导出所有自定义源为 JSON 文本。
    func exportJSON() -> String {
        let custom = sources.filter { !$0.isBuiltin }
        guard let data = try? JSONEncoder.pretty.encode(custom),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    enum SourceError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let m): return m }
        }
    }

    private func mutate(_ id: String, _ block: (inout NovelSource) -> Void) {
        guard let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        var s = sources[idx]
        block(&s)
        sources[idx] = s
    }

    private func saveCustom() {
        let custom = sources.filter { !$0.isBuiltin }
        try? JSONEncoder.pretty.encode(custom).write(to: customURL)
    }

    // MARK: - 兜底内置源

    /// 内置公版书源：殆知阁古籍（1.5 万+ 本）。书目随 App 打包，本地即时搜索，
    /// 正文走 jsDelivr/raw CDN，大陆可达、无 GitHub API 限流、版权为公版古籍。
    /// 直接写在代码里，避免 JSON 资源打包方式差异导致搜索页空白。
    static let fallbackSources: [NovelSource] = [
        // 番茄 / 七猫 已在 2026-11-21 按用户要求移除：
        // 七猫网页端只开前若干章（后段要 App 内会员），番茄重复条目多且章节接口常挂，
        // 两个源对「下载全本」帮助都很小，留着只会拖慢搜索和统计。
        // 实现（FanqieSource / QimaoSource）仍保留在代码里，需要时把源加回来即可。
        NovelSource(
            id: "builtin-dzg",
            name: "殆知阁古籍 · 公版",
            baseURL: "garychowcmu/daizhigev20",
            kind: "github",
            isBuiltin: true,
            note: "1.5 万+ 本古代文献：经史子集、四大名著、诗词小说、中医典籍。书目本地搜索，正文来自 CDN。"
        ),
        // 笔趣阁系静态 HTML 源：纯选择器抓取，个人学习自用。
        // 站点域名易变，失效时可在书源管理里编辑 host 或导入新规则。
        NovelSource(
            id: "bqg-92xs",
            name: "就爱文学 · 笔趣阁",
            baseURL: "http://www.92xs.info",
            charset: "utf-8",
            headers: ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"],
            isBuiltin: true,
            note: "经典笔趣阁模板站，静态 HTML 抓取。个人学习自用；站点域名易变，失效可在书源管理编辑。",
            search: RuleSection(
                url: "http://www.92xs.info/modules/article/search.php?searchkey={key}",
                list: "tag(tr)",
                fields: [
                    "title": #"re('href="[^"]*book/\d+\.html"[^>]*>([^<]+)</a>',1)"#,
                    "author": #"re('</a></td>\s*<td[^>]*>\s*<a[^>]*>[^<]*</a>\s*</td>\s*<td[^>]*>([^<]+)</td>',1)"#,
                    // 书籍页 URL 改写成完整目录页 URL（/book/{id}.html → /html/{id}/）
                    "url": #"re('href="([^"]*book/\d+\.html)"',1).replace('book/(\d+)\.html','html/$1/')"#
                ]
            ),
            chapter: RuleSection(
                url: "{url}",
                list: #"re('<a href="/html/\d+/\d+\.html"[^>]*>[^<]+</a>',0)"#,
                fields: [
                    "title": #"re('>([^<]+)</a>',1)"#,
                    "url": #"re('href="([^"]+)"',1)"#
                ]
            ),
            content: RuleSection(
                url: "{url}",
                list: #"id(ccontent).re('([^<>]+)<br\s*/?>',1)"#,
                join: "\n\n",
                cleanTail: #"entity.trim.drop('最新网址')"#
            )
        )
    ]
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}
