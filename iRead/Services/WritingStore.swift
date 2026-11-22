import Foundation

/// 写作草稿仓库：一本一份 JSON，放在 Documents/Writing/ 下。
///
/// 为什么不塞进 `library.json`：草稿是高频小改（敲几行就存一次），
/// 和书架元数据放一起会把整张书架表反复重写；两者生命周期也完全不同 ——
/// 删掉底本不该连着自己写的东西一起没。
final class WritingStore: ObservableObject {
    static let shared = WritingStore()

    @Published private(set) var projects: [WritingProject] = []

    private let fm = FileManager.default
    private let dir: URL

    init() {
        let doc = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = doc.appendingPathComponent("Writing", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private func url(for id: String) -> URL {
        dir.appendingPathComponent("\(id).json")
    }

    private func load() {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        projects = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(WritingProject.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func project(_ id: String) -> WritingProject? {
        projects.first { $0.id == id }
    }

    @discardableResult
    func create(
        title: String,
        mode: WritingMode,
        brief: String,
        sourceBookID: String? = nil,
        sourceBookTitle: String? = nil,
        sourceChapterIndex: Int? = nil
    ) -> WritingProject {
        var project = WritingProject(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "未命名作品" : title.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode
        )
        project.brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        project.sourceBookID = sourceBookID
        project.sourceBookTitle = sourceBookTitle
        project.sourceChapterIndex = sourceChapterIndex
        projects.insert(project, at: 0)
        write(project)
        return project
    }

    func update(_ project: WritingProject) {
        var next = project
        next.updatedAt = Date()
        if let index = projects.firstIndex(where: { $0.id == next.id }) {
            projects[index] = next
        } else {
            projects.insert(next, at: 0)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
        write(next)
    }

    func delete(_ id: String) {
        projects.removeAll { $0.id == id }
        try? fm.removeItem(at: url(for: id))
    }

    private func write(_ project: WritingProject) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(project) else { return }
        try? data.write(to: url(for: project.id))
    }

    // MARK: - 导出

    /// 导出成平台能直接吃的 TXT。
    ///
    /// 只写「章节标题 + 正文」：起点、番茄、知乎这些后台上传时要的是一个 txt，
    /// 书名是单独填的字段，写进正文反而要用户自己删一遍。
    func exportTXT(_ project: WritingProject) throws -> URL {
        var text = ""
        for segment in project.segments {
            let title = segment.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { text += title + "\n\n" }
            text += segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            text += "\n\n\n"
        }
        let safe = project.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (safe.isEmpty ? "未命名作品" : safe) + ".txt"
        let url = fm.temporaryDirectory.appendingPathComponent(name)
        try (text.data(using: .utf8) ?? Data()).write(to: url)
        return url
    }
}
