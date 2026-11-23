import Foundation
import Combine

/// 通用媒体下载器：音乐自动缓存、视频离线下载共用一条通道。
///
/// 用 `URLSessionDownloadTask` 而不是 `Data(contentsOf:)`：音频几十 MB、
/// 视频可能几百 MB，整段读进内存会在老设备上直接被系统杀掉。
/// 进度按 id 暴露给界面（`music:<trackID>` / `video:<itemID>`）。
///
/// 两个坑值得记一笔：
/// 1. 有的源校验 `Referer`（ccMixter 不带就是 403），所以下载要能带请求头；
/// 2. 403 的响应体是 10 字节 HTML，`URLSession` 照样「下载成功」，
///    必须校验 HTTP 状态码 + 文件头，否则会把错误页当 mp3 存进缓存。
final class MediaDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = MediaDownloader()

    /// 下载内容的可播特征。校验不通过就当失败，绝不落盘。
    enum PayloadKind {
        case audio
        case video
        /// 不校验（m3u8 播放列表这类文本资源）
        case any
    }

    enum DownloadError: LocalizedError {
        case http(Int)
        case htmlBody
        case badPayload(PayloadKind)
        case empty

        var errorDescription: String? {
            switch self {
            case .http(let code):
                switch code {
                case 401, 403: return "服务器拒绝访问（HTTP \(code)），可能需要来源页授权"
                case 404: return "文件不存在（HTTP 404）"
                default: return "下载失败（HTTP \(code)）"
                }
            case .htmlBody:
                return "返回的是网页而不是媒体文件，可能被防盗链拦截"
            case .badPayload(.audio):
                return "下载到的不是有效的音频文件"
            case .badPayload(.video):
                return "下载到的不是有效的视频文件"
            case .badPayload(.any):
                return "下载内容无效"
            case .empty:
                return "下载到的文件为空"
            }
        }
    }

    struct DownloadState: Equatable {
        var progress: Double = 0
        var received: Int64 = 0
        var total: Int64 = 0
        var failed: String? = nil
        var finished: Bool = false

        var isActive: Bool { !finished && failed == nil }
    }

    @Published private(set) var states: [String: DownloadState] = [:]

    private lazy var session: URLSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )

    private struct Job {
        let id: String
        let destination: URL
        let kind: PayloadKind
        let completion: (Result<URL, Error>) -> Void
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]

    private override init() {
        super.init()
    }

    func state(for id: String) -> DownloadState? { states[id] }

    /// 目标文件已存在时直接成功 —— 「自动保存」的幂等入口：
    /// 同一首歌点多少次播放都不会重复下载。
    ///
    /// 但旧版本可能已经存进了错误页（403 的 10 字节 HTML），
    /// 所以命中已有文件也要过一遍校验，不合格就删掉重下。
    func download(
        id: String,
        url: URL,
        destination: URL,
        kind: PayloadKind = .any,
        headers: [String: String] = [:],
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            if Self.inspect(file: destination, kind: kind) == nil {
                update(id) {
                    $0.progress = 1
                    $0.finished = true
                    $0.failed = nil
                }
                completion?(.success(destination))
                return
            }
            try? fm.removeItem(at: destination)
        }

        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        lock.lock()
        if jobs.values.contains(where: { $0.id == id }) {
            lock.unlock()
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let task = session.downloadTask(with: request)
        jobs[task.taskIdentifier] = Job(
            id: id,
            destination: destination,
            kind: kind,
            completion: completion ?? { _ in }
        )
        lock.unlock()

        update(id) { $0 = DownloadState() }
        task.resume()
    }

    /// 已经在下载同一 id 时不重复发起，但调用方仍需要拿到最终结果。
    /// 简化处理：直接返回当前状态，界面靠 `states` 驱动即可。
    func isDownloading(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values.contains { $0.id == id }
    }

    func cancel(id: String) {
        lock.lock()
        let identifiers = jobs.filter { $0.value.id == id }.map(\.key)
        lock.unlock()
        for identifier in identifiers {
            session.getTasksWithCompletionHandler { _, _, tasks in
                tasks.first { $0.taskIdentifier == identifier }?.cancel()
            }
        }
    }

    // MARK: - 状态

    private func update(_ id: String, _ body: @escaping (inout DownloadState) -> Void) {
        DispatchQueue.main.async {
            var state = self.states[id] ?? DownloadState()
            body(&state)
            // 兜底：任何路径写进来的 nan/inf 都不许流到界面（进度环会直接消失）
            if !state.progress.isFinite { state.progress = 0 }
            self.states[id] = state
        }
    }

    private func job(for task: URLSessionTask) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[task.taskIdentifier]
    }

    private func takeJob(_ task: URLSessionTask) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return jobs.removeValue(forKey: task.taskIdentifier)
    }

    // MARK: - 校验

    /// 同时看响应头与文件头。返回 nil 表示可以落盘。
    private static func inspect(response: URLResponse?, file: URL, kind: PayloadKind) -> DownloadError? {
        if let http = response as? HTTPURLResponse {
            if http.statusCode >= 400 { return .http(http.statusCode) }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.contains("text/html") { return .htmlBody }
            // 有的源用 200 + 空 body 表示拒绝
            let length = http.expectedContentLength
            if length == 0 { return .empty }
        }
        return inspect(file: file, kind: kind)
    }

    private static func inspect(file: URL, kind: PayloadKind) -> DownloadError? {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return .empty }
        guard kind != .any else { return nil }
        // 一首歌几 MB、一段视频几十 MB；小于 8KB 的一定不是媒体
        guard size >= 8 * 1024 else { return .badPayload(kind) }

        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return .badPayload(kind)
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        guard head.count >= 4 else { return .badPayload(kind) }

        func matches(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            guard head.count >= offset + bytes.count else { return false }
            let slice = [UInt8](head.subdata(in: offset..<(offset + bytes.count)))
            return slice == bytes
        }

        switch kind {
        case .any:
            return nil
        case .audio:
            // ID3 标签 / MPEG 帧同步（0xFF 0xEx）/ ADTS AAC / MP4 容器里的 m4a
            let id3 = matches([0x49, 0x44, 0x33])
            let frameSync = head[0] == 0xFF && (head[1] & 0xE0) == 0xE0
            let mp4 = matches([0x66, 0x74, 0x79, 0x70], at: 4)
            let flac = matches([0x66, 0x4C, 0x61, 0x43])
            return (id3 || frameSync || mp4 || flac) ? nil : .badPayload(.audio)
        case .video:
            let mp4 = matches([0x66, 0x74, 0x79, 0x70], at: 4)
            let matroska = matches([0x1A, 0x45, 0xDF, 0xA3])
            let riff = matches([0x52, 0x49, 0x46, 0x46])
            let mpegTS = head[0] == 0x47
            return (mp4 || matroska || riff || mpegTS) ? nil : .badPayload(.video)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let job = job(for: downloadTask) else { return }
        var progress: Double = 0
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
        // 有的源不给 Content-Length，除法会算出 nan，界面进度环会直接消失
        guard progress.isFinite else { return }
        update(job.id) {
            $0.progress = min(max(progress, 0), 0.999)
            $0.received = totalBytesWritten
            $0.total = totalBytesExpectedToWrite
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let job = takeJob(downloadTask) else { return }

        if let error = Self.inspect(response: downloadTask.response, file: location, kind: job.kind) {
            try? FileManager.default.removeItem(at: location)
            update(job.id) {
                $0.failed = error.localizedDescription
                $0.finished = false
            }
            DispatchQueue.main.async { job.completion(.failure(error)) }
            return
        }

        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: job.destination.path) {
                try fm.removeItem(at: job.destination)
            }
            try fm.moveItem(at: location, to: job.destination)
            update(job.id) {
                $0.progress = 1
                $0.finished = true
                $0.failed = nil
            }
            DispatchQueue.main.async { job.completion(.success(job.destination)) }
        } catch {
            update(job.id) { $0.failed = error.localizedDescription }
            DispatchQueue.main.async { job.completion(.failure(error)) }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        guard let job = takeJob(task) else { return }
        update(job.id) { $0.failed = error.localizedDescription }
        DispatchQueue.main.async { job.completion(.failure(error)) }
    }
}
