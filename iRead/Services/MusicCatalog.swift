import Foundation

/// 开源音乐检索。
///
/// 选源标准只有两条：**中国大陆能直连**、**免注册就能播**。
/// - ccMixter：Creative Commons 混音社区，公开 JSON API，mp3 直链，实测可用；
/// - Jamendo：曲库更大、有封面，但需要免费 client_id；用户填了才启用。
///
/// 没有接 Free Music Archive / Openverse：前者 API 已停、后者在境内连接被重置；
/// Internet Archive 整站在境内不可达。源不在多，能播才行。
enum MusicCatalog {

    enum CatalogError: LocalizedError {
        case badResponse(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "曲库返回 HTTP \(code)"
            case .empty: return "没有找到可播放的曲目"
            }
        }
    }

    /// 推荐：ccMixter 按 rank 排的前 N 首
    static func recommended(limit: Int = 24) async throws -> [MusicTrack] {
        try await ccMixter(query: nil, limit: limit, ranked: true)
    }

    static func search(_ keyword: String, limit: Int = 30) async throws -> [MusicTrack] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await recommended(limit: limit) }

        var tracks = try await ccMixter(query: trimmed, limit: limit, ranked: false)
        // Jamendo 配了 key 就一起搜；失败不影响 ccMixter 的结果
        if let key = jamendoClientID, !key.isEmpty,
           let more = try? await jamendo(query: trimmed, clientID: key, limit: limit) {
            tracks.append(contentsOf: more)
        }
        guard !tracks.isEmpty else { throw CatalogError.empty }
        return tracks
    }

    // MARK: - ccMixter

    private static func ccMixter(query: String?, limit: Int, ranked: Bool) async throws -> [MusicTrack] {
        var components = URLComponents(string: "https://ccmixter.org/api/query")!
        var items = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "search", value: query))
        }
        if ranked {
            items.append(URLQueryItem(name: "sort", value: "rank"))
        }
        components.queryItems = items

        guard let url = components.url else { throw CatalogError.badResponse(0) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("iRead/1.0 (music search)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse(0) }
        guard http.statusCode == 200 else { throw CatalogError.badResponse(http.statusCode) }

        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CatalogError.empty
        }

        var seen = Set<String>()
        var tracks: [MusicTrack] = []
        for item in raw {
            guard let uploadID = item["upload_id"] as? Int else { continue }
            let id = "ccmixter-\(uploadID)"
            guard seen.insert(id).inserted else { continue }

            let files = item["files"] as? [[String: Any]] ?? []
            // 只取 mp3：有些条目只给了 flac/ogg，AVPlayer 播不了
            guard let file = files.first(where: {
                (($0["file_nicname"] as? String)?.lowercased() == "mp3")
                    && (($0["download_url"] as? String)?.hasPrefix("http") == true)
            }), let stream = file["download_url"] as? String else { continue }

            let title = html(clean(item["upload_name"] as? String)) ?? "未命名"
            let realName = html(clean(item["user_real_name"] as? String)) ?? ""
            let userName = html(clean(item["user_name"] as? String)) ?? "ccMixter"
            let artist = realName.isEmpty ? userName : realName

            var duration: Double = 0
            if let info = file["file_format_info"] as? [String: Any],
               let text = info["ps"] as? String {
                duration = seconds(from: text)
            }

            let license = html(clean(item["license_name"] as? String)) ?? "Creative Commons"
            let licenseURL = clean(item["license_url"] as? String) ?? "https://creativecommons.org/licenses/"

            tracks.append(MusicTrack(
                id: id,
                title: title,
                artist: artist,
                duration: duration,
                streamURL: stream,
                license: license,
                licenseURL: licenseURL,
                sourceID: "ccmixter",
                sourceName: "ccMixter",
                hue: MediaArt.hue(for: id)
            ))
        }

        guard !tracks.isEmpty else { throw CatalogError.empty }
        return tracks
    }

    // MARK: - Jamendo（可选）

    static var jamendoClientID: String? {
        let value = UserDefaults.standard.string(forKey: "music.jamendoClientID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func setJamendoClientID(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: "music.jamendoClientID")
    }

    private static func jamendo(query: String, clientID: String, limit: Int) async throws -> [MusicTrack] {
        var components = URLComponents(string: "https://api.jamendo.com/v3.0/tracks/")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "audioformat", value: "mp32"),
            URLQueryItem(name: "include", value: "musicinfo"),
            URLQueryItem(name: "imagesize", value: "300")
        ]
        guard let url = components.url else { throw CatalogError.badResponse(0) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw CatalogError.empty
        }

        var tracks: [MusicTrack] = []
        for item in results {
            guard let trackID = item["id"] as? String,
                  let stream = item["audio"] as? String, !stream.isEmpty else { continue }
            let id = "jamendo-\(trackID)"
            tracks.append(MusicTrack(
                id: id,
                title: html(clean(item["name"] as? String)) ?? "未命名",
                artist: html(clean(item["artist_name"] as? String)) ?? "Jamendo",
                duration: (item["duration"] as? NSNumber)?.doubleValue ?? 0,
                streamURL: stream,
                license: html(clean(item["license_ccurl"] as? String)) == nil ? "Creative Commons" : "Creative Commons",
                licenseURL: clean(item["license_ccurl"] as? String) ?? "https://creativecommons.org/licenses/",
                sourceID: "jamendo",
                sourceName: "Jamendo",
                hue: MediaArt.hue(for: id)
            ))
        }
        guard !tracks.isEmpty else { throw CatalogError.empty }
        return tracks
    }

    // MARK: - 小工具

    private static func seconds(from text: String) -> Double {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 曲库的标题里带 HTML 实体（`&#8217;` / `&amp;`），直接显示会露出一串码
    private static func html(_ value: String?) -> String? {
        guard let value else { return nil }
        var text = value
        let map = [
            "&amp;": "&", "&quot;": "\"", "&#039;": "'", "&#39;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#8217;": "’",
            "&#8216;": "‘", "&#8220;": "“", "&#8221;": "”",
            "&#8211;": "–", "&#8212;": "—", "&hellip;": "…"
        ]
        for (key, replacement) in map {
            text = text.replacingOccurrences(of: key, with: replacement)
        }
        return text
    }
}
