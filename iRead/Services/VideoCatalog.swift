import Foundation

/// 开源影像检索。
///
/// 选源同样只看两条：境内直连、授权清楚。
/// - Blender 开源电影：CC BY，直链 mp4/mov，适合「动漫」频道；
/// - NASA 影像库：公共领域，公开检索 API，mp4 直链，适合「视频」频道。
///
/// 没接 Internet Archive（境内不可达）和 Wikimedia Commons（境内超时）。
/// 用户还可以在视频频道手动添加任意 mp4 / m3u8 直链 —— 开源站找不到的片子，
/// 自己手里有地址就能看，不必等 App 支持某个站。
enum VideoCatalog {

    enum CatalogError: LocalizedError {
        case badResponse(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "片库返回 HTTP \(code)"
            case .empty: return "没有找到可播放的片子"
            }
        }
    }

    // MARK: - 动漫：Blender 开源电影

    /// 这几部都是 CC BY，可在线播也可下载。
    /// 用 W3C 的镜像而不是 download.blender.org 的原始档：后者多为 mkv/zip，
    /// AVPlayer 播不了，镜像提供的是 mp4。
    static let openMovies: [VideoItem] = [
        VideoItem(
            id: "blender-bbb",
            title: "Big Buck Bunny",
            summary: "Blender 基金会开源动画。一只大兔子的森林复仇记，开源动画里最出名的一部。",
            coverURL: "https://media.w3.org/2010/05/bunny/poster.png",
            streamURL: "https://media.w3.org/2010/05/bunny/movie.mp4",
            license: "CC BY 3.0",
            sourceName: "Blender 开源电影",
            kind: .anime,
            hue: 0.28
        ),
        VideoItem(
            id: "blender-bbb-trailer",
            title: "Big Buck Bunny · 预告",
            summary: "正片的短版，网络慢时可以先看这个。",
            coverURL: "https://media.w3.org/2010/05/bunny/poster.png",
            streamURL: "https://media.w3.org/2010/05/bunny/trailer.mp4",
            license: "CC BY 3.0",
            sourceName: "Blender 开源电影",
            kind: .anime,
            hue: 0.30
        ),
        VideoItem(
            id: "blender-sintel",
            title: "Sintel · 预告",
            summary: "Blender 基金会的奇幻短片，少女与幼龙的旅程。这是官方预告片。",
            coverURL: "https://media.w3.org/2010/05/sintel/poster.png",
            streamURL: "https://media.w3.org/2010/05/sintel/trailer.mp4",
            license: "CC BY 3.0",
            sourceName: "Blender 开源电影",
            kind: .anime,
            hue: 0.55
        ),
        VideoItem(
            id: "blender-tos",
            title: "Tears of Steel",
            summary: "Blender 的真人 + 特效开源电影，720p 完整版。",
            coverURL: nil,
            streamURL: "https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov",
            license: "CC BY 3.0",
            sourceName: "Blender 开源电影",
            kind: .anime,
            hue: 0.62
        )
    ]

    // MARK: - 检索

    static func search(_ keyword: String, kind: VideoKind) async throws -> [VideoItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .anime:
            let list = trimmed.isEmpty
                ? openMovies
                : openMovies.filter {
                    $0.title.localizedCaseInsensitiveContains(trimmed)
                        || $0.summary.localizedCaseInsensitiveContains(trimmed)
                }
            guard !list.isEmpty else { throw CatalogError.empty }
            return list
        case .video:
            return try await nasaSearch(query: trimmed.isEmpty ? "earth" : trimmed)
        }
    }

    // MARK: - NASA

    private static func nasaSearch(query: String) async throws -> [VideoItem] {
        var components = URLComponents(string: "https://images-api.nasa.gov/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "media_type", value: "video"),
            URLQueryItem(name: "page_size", value: "24")
        ]
        guard let url = components.url else { throw CatalogError.badResponse(0) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse(0) }
        guard http.statusCode == 200 else { throw CatalogError.badResponse(http.statusCode) }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let collection = root["collection"] as? [String: Any],
              let items = collection["items"] as? [[String: Any]] else {
            throw CatalogError.empty
        }

        var result: [VideoItem] = []
        for item in items {
            guard let dataList = item["data"] as? [[String: Any]],
                  let first = dataList.first,
                  let nasaID = first["nasa_id"] as? String, !nasaID.isEmpty else { continue }

            // nasa_id 里有空格和斜杠，逐个转义；~mobile.mp4 是 NASA 自己转好的小码率版本
            let encoded = nasaID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nasaID
            let stream = "https://images-assets.nasa.gov/video/\(encoded)/\(encoded)~mobile.mp4"

            let cover = coverURL(from: item["links"] as? [[String: Any]] ?? [])
            let title = (first["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "NASA 影像"
            let summary = (first["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ") ?? ""

            result.append(VideoItem(
                id: "nasa-\(nasaID)",
                title: title,
                summary: String(summary.prefix(220)),
                coverURL: cover,
                streamURL: stream,
                license: "公共领域（NASA）",
                sourceName: "NASA 影像库",
                kind: .video
            ))
        }

        guard !result.isEmpty else { throw CatalogError.empty }
        return result
    }

    private static func coverURL(from links: [[String: Any]]) -> String? {
        let preferred = ["~medium.jpg", "~large.jpg", "~small.jpg", "~thumb.jpg"]
        for suffix in preferred {
            if let href = links.compactMap({ $0["href"] as? String })
                .first(where: { $0.hasSuffix(suffix) }) {
                return href
            }
        }
        return links.first { ($0["render"] as? String) == "image" }?["href"] as? String
    }
}
