import Foundation
import Network

/// WiFi 传书：在 App 内开一个只监听局域网的 HTTP 服务。
/// 同一 WiFi 下用浏览器打开显示的地址，把 TXT 直接传到书架。
/// 不访问外网、不提供书源；访问需要页面里带的 6 位随机码，防止同一 WiFi 下别人误传。
final class WiFiTransferServer: ObservableObject {
    static let shared = WiFiTransferServer()

    private static let port: UInt16 = 8787
    private static let maxUpload = 60 * 1024 * 1024

    struct Record: Identifiable {
        let id = UUID()
        let title: String
        let ok: Bool
        let message: String
        let at = Date()
    }

    @Published private(set) var isRunning = false
    @Published private(set) var address: String?
    @Published private(set) var token = ""
    @Published private(set) var lastError: String?
    @Published private(set) var records: [Record] = []

    private var listener: NWListener?
    /// 每个连接的处理器要强引用住，否则 receive 回调还没回来就被释放
    private var handlers = Set<ConnectionHandler>()
    private let queue = DispatchQueue(label: "com.yingyang.iread.wifi", qos: .userInitiated, attributes: .concurrent)

    private init() {}

    // MARK: - 生命周期

    func start() {
        guard !isRunning, listener == nil else { return }
        lastError = nil
        let newToken = String(format: "%06d", Int.random(in: 0..<1_000_000))

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let handler = ConnectionHandler(connection: connection, server: self, queue: self.queue)
                self.handlers.insert(handler)
                handler.onDone = { [weak self] in
                    guard let self else { return }
                    self.handlers.remove(handler)
                }
                handler.start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let ip = Self.localIPv4() ?? "127.0.0.1"
                    DispatchQueue.main.async {
                        self?.token = newToken
                        self?.address = "http://\(ip):\(Self.port)/?t=\(newToken)"
                        self?.isRunning = true
                        self?.lastError = nil
                    }
                case .failed(let error):
                    DispatchQueue.main.async {
                        self?.isRunning = false
                        self?.address = nil
                        self?.lastError = "无法启动传书服务（端口 \(Self.port)）：\(error.localizedDescription)"
                    }
                case .waiting(let error):
                    DispatchQueue.main.async {
                        self?.lastError = "网络不可用：\(error.localizedDescription)"
                    }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lastError = "无法启动传书服务：\(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for handler in handlers { handler.cancel() }
        handlers.removeAll()
        isRunning = false
        address = nil
        lastError = nil
    }

    deinit { listener?.cancel() }

    // MARK: - 本机局域网 IP

    /// 优先取 Wi-Fi（en*）的 IPv4；模拟器上没有 en 口时退回任意非回环地址。
    private static func localIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("127.") else { continue }
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("en") || name.hasPrefix("bridge") { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    // MARK: - 上传记录

    fileprivate func addRecord(title: String, ok: Bool, message: String) {
        DispatchQueue.main.async {
            self.records.insert(Record(title: title, ok: ok, message: message), at: 0)
            if self.records.count > 20 { self.records.removeLast(self.records.count - 20) }
        }
    }

    // MARK: - 单条连接：极简 HTTP/1.1

    fileprivate final class ConnectionHandler: Hashable {
        private let connection: NWConnection
        private weak var server: WiFiTransferServer?
        private let queue: DispatchQueue
        private var buffer = Data()
        private var headerEnd: Int?
        private var method = ""
        private var path = ""
        private var headers: [String: String] = [:]
        private var expectedBody = 0
        private var finished = false

        var onDone: (() -> Void)?

        init(connection: NWConnection, server: WiFiTransferServer, queue: DispatchQueue) {
            self.connection = connection
            self.server = server
            self.queue = queue
        }

        static func == (lhs: ConnectionHandler, rhs: ConnectionHandler) -> Bool { lhs === rhs }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.cancel() }
            }
            connection.start(queue: queue)
            receive()
        }

        func cancel() { finish() }

        private func finish() {
            guard !finished else { return }
            finished = true
            connection.cancel()
            let done = onDone
            DispatchQueue.global().async { done?() }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
                guard let self, !self.finished else { return }
                if let content { self.buffer.append(content) }
                if error != nil { self.finish(); return }
                self.process()
                if !self.finished && !isComplete { self.receive() }
            }
        }

        private func process() {
            if headerEnd == nil {
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 32 * 1024 { respond(431, json: ["ok": false, "error": "请求头过大"]) }
                    return
                }
                headerEnd = range.upperBound
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
                guard let requestLine = lines.first else { return respond(400, json: ["ok": false, "error": "请求格式错误"]) }
                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2 else { return respond(400, json: ["ok": false, "error": "请求格式错误"]) }
                method = String(parts[0])
                path = String(parts[1])
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
                expectedBody = Int(headers["content-length"] ?? "") ?? 0
                if expectedBody > WiFiTransferServer.maxUpload {
                    return respond(413, json: ["ok": false, "error": "文件超过 60 MB，请先拆分"])
                }
                if buffer.count - range.upperBound > WiFiTransferServer.maxUpload + 64 * 1024 {
                    return respond(413, json: ["ok": false, "error": "请求体过大"])
                }
            }

            guard let bodyStart = headerEnd else { return }
            guard buffer.count - bodyStart >= expectedBody else { return }

            let body = Data(buffer[bodyStart..<(bodyStart + expectedBody)])
            route(path: path, method: method, body: body)
        }

        private func route(path: String, method: String, body: Data) {
            let query = path.split(separator: "?", maxSplits: 1)
            let endpoint = query.first.map(String.init) ?? path
            let params = query.count > 1 ? query[1].split(separator: "&") : []
            var token: String?
            for param in params {
                let pair = param.split(separator: "=", maxSplits: 1)
                if pair.count == 2, pair[0] == "t" { token = String(pair[1]) }
            }

            guard token == server?.token else {
                return respond(403, html: "<h1>访问码不正确</h1><p>请回到 iRead 的「WiFi 传书」页面，用显示的完整地址重新打开。</p>")
            }

            switch (method, endpoint) {
            case ("GET", "/"), ("GET", "/index.html"):
                respond(200, html: Self.page(token: token ?? ""))
            case ("GET", "/ping"):
                respond(200, json: ["ok": true])
            case ("POST", "/upload"):
                upload(body: body)
            default:
                respond(404, html: "<h1>404</h1><p>页面不存在。请回到 iRead 重新打开传书地址。</p>")
            }
        }

        private func upload(body: Data) {
            let rawName = (headers["x-file-name"] ?? "").removingPercentEncoding ?? "上传书籍.txt"
            let name = (rawName as NSString).lastPathComponent
            let title = (name as NSString).deletingPathExtension

            // 导入会改写 @Published 书架，必须回到主线程
            DispatchQueue.main.async { [weak self] in
                guard let self, let server = self.server else { return }
                do {
                    let book = try LibraryStore.shared.importBook(data: body, title: title)
                    server.addRecord(title: book.title, ok: true, message: "\(book.chapterCount) 章 · \(book.fileSize / 1024) KB")
                    self.respond(200, json: [
                        "ok": true,
                        "title": book.title,
                        "chapters": book.chapterCount
                    ])
                } catch {
                    server.addRecord(title: name, ok: false, message: error.localizedDescription)
                    self.respond(400, json: ["ok": false, "error": error.localizedDescription])
                }
            }
        }

        // MARK: 响应

        private func respond(_ status: Int, json: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{\"ok\":false}".utf8)
            send(status: status, contentType: "application/json; charset=utf-8", body: data)
        }

        private func respond(_ status: Int, html: String) {
            let page = """
            <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>iRead WiFi 传书</title></head><body>
            <meta name="theme-color" content="#f7f3ea">
            <div style="font:16px/1.7 system-ui;max-width:560px;margin:8vh auto;padding:0 20px;color:#3a3228">
            \(html)</div></body></html>
            """
            send(status: status, contentType: "text/html; charset=utf-8", body: Data(page.utf8))
        }

        private func send(status: Int, contentType: String, body: Data) {
            let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                          413: "Payload Too Large", 431: "Request Header Fields Too Large"][status] ?? "Error"
            let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            var packet = Data(head.utf8)
            packet.append(body)
            connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
        }

        // MARK: 上传网页

        private static func page(token: String) -> String {
            """
            <style>
              body{background:#f7f3ea;color:#3a3228;font:16px/1.7 -apple-system,BlinkMacSystemFont,"PingFang SC",system-ui,sans-serif}
              h1{font-size:24px;margin:0 0 6px} .sub{color:#8a7f6d;margin:0 0 24px;font-size:14px}
              .card{background:#fff;border-radius:16px;padding:22px;box-shadow:0 4px 20px #0000000d}
              input[type=file]{width:100%;padding:12px;border:1px dashed #c9bda8;border-radius:10px;background:#fffdf8;margin:12px 0}
              button{width:100%;padding:13px;border:0;border-radius:10px;background:#b4653d;color:#fff;font-size:16px;font-weight:600;cursor:pointer}
              button:disabled{background:#c9bda8;cursor:default}
              #log{margin-top:18px;font-size:14px;white-space:pre-wrap;line-height:1.9}
              .ok{color:#2e7d4f}.bad{color:#b13c3c}
              .tip{font-size:13px;color:#8a7f6d;margin-top:20px;line-height:1.8}
            </style>
            <h1>iRead · WiFi 传书</h1>
            <p class="sub">选好 TXT，点上传，书会自动出现在手机书架里</p>
            <div class="card">
              <input type="file" id="file" accept=".txt,text/plain" multiple>
              <button id="go" onclick="send()">上传到 iRead</button>
              <div id="log"></div>
            </div>
            <div class="tip">
              · 手机需和本设备在同一个 WiFi，且 iRead 保持打开<br>
              · 支持 UTF-8 / GBK / UTF-16 编码的 TXT，单本不超过 60 MB<br>
              · 文件只保存在手机本机，不经过任何外部服务器
            </div>
            <script>
            const TOKEN = "\(token)";
            const log = document.getElementById('log');
            function line(text, cls){ const d=document.createElement('div'); d.textContent=text; if(cls)d.className=cls; log.appendChild(d); }
            async function send(){
              const files = document.getElementById('file').files;
              if(!files.length){ line('请先选择 TXT 文件','bad'); return; }
              const btn = document.getElementById('go'); btn.disabled = true;
              for(const f of files){
                line('正在上传：' + f.name);
                try{
                  const res = await fetch('/upload?t=' + encodeURIComponent(TOKEN), {
                    method:'POST',
                    headers:{'Content-Type':'application/octet-stream','X-File-Name':encodeURIComponent(f.name)},
                    body: await f.arrayBuffer()
                  });
                  const j = await res.json();
                  if(j.ok) line('✓ 《' + j.title + '》已加入书架（' + j.chapters + ' 章）','ok');
                  else line('✗ ' + (j.error || '上传失败'),'bad');
                }catch(e){ line('✗ 上传失败：' + e.message,'bad'); }
              }
              btn.disabled = false;
            }
            </script>
            """
        }
    }
}
