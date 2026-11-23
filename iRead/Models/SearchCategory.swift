import Foundation

/// 统一搜索入口下的五个频道。
///
/// 以前「搜书」和「漫画」是两个独立 Tab，音乐/视频再各开一个就没地方放了。
/// 现在只留一个「搜索」，用频道切换；每个频道仍走各自的源与结果视图，
/// 输入框分开 —— 书、图片、音频、视频的检索参数完全不是一回事。
enum SearchCategory: String, CaseIterable, Identifiable, Codable {
    case book
    case comic
    case music
    case anime
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .book: return "书籍"
        case .comic: return "漫画"
        case .music: return "音乐"
        case .anime: return "动漫"
        case .video: return "视频"
        }
    }

    /// 频道切换条上的短名（Tab 已经叫「搜索」，这里不必重复「搜」字）
    var shortTitle: String { title }

    var icon: String {
        switch self {
        case .book: return "book.closed"
        case .comic: return "rectangle.stack"
        case .music: return "music.note"
        case .anime: return "play.rectangle.on.rectangle"
        case .video: return "film"
        }
    }

    var subtitle: String {
        switch self {
        case .book: return "从书源找书，整本下载后离线读"
        case .comic: return "漫画与儿童绘本，按话缓存到本机"
        case .music: return "开源曲库，在线播放并自动留一份"
        case .anime: return "开源动画短片，点开就看"
        case .video: return "公共领域影像与开源视频"
        }
    }
}
