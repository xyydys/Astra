import Foundation

/// 首页左上角切换的内容模式
enum ContentMode: String, CaseIterable, Identifiable {
    /// 番剧：Kazumi 规则 + Bangumi
    case anime
    /// 影视：采集站 + 豆瓣（LibreTV 的思路）
    case video
    /// 漫画：禁漫天堂（Jasmine 的资源）
    case comic
    /// 小说：阅读（Legado）格式的书源
    case novel
    /// 音乐：洛雪音乐（LX Music）自定义音源 + Folia 歌词特效
    case music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anime: return "番剧"
        case .video: return "影视"
        case .comic: return "漫画"
        case .novel: return "小说"
        case .music: return "音乐"
        }
    }

    var subtitle: String {
        switch self {
        case .anime: return "Kazumi · Bangumi 番组"
        case .video: return "LibreTV · 电影剧集"
        case .comic: return "Jasmine · 禁漫天堂"
        case .novel: return "Legado · 书源"
        case .music: return "LX Music · 洛雪音源"
        }
    }

    var icon: String {
        switch self {
        case .anime: return "sparkles"
        case .video: return "film"
        case .comic: return "book"
        case .novel: return "text.book.closed"
        case .music: return "music.note"
        }
    }
}

/// 影视条目和番剧共用 BangumiSubject 结构，id 用负数区分：
/// 收藏、观看历史、海报取色、导航都能直接复用。
/// - 豆瓣条目：id = -豆瓣 id
/// - 只在采集站搜到的条目：id = -(10 亿 + 片名哈希)，不会和豆瓣 id 冲突
extension BangumiSubject {
    var isVideo: Bool { id < 0 && id > -Self.comicIDBase }

    var doubanID: String? {
        guard id < 0, -id < 1_000_000_000 else { return nil }
        return String(-id)
    }

    static func video(
        id: Int, title: String, image: String, thumb: String? = nil,
        score: Double = 0, year: String = "", tags: [String] = [], episodes: Int = 0, summary: String = ""
    ) -> BangumiSubject {
        BangumiSubject(
            id: id, name: "", nameCN: title, image: image, thumb: thumb ?? image,
            score: score, rank: 0, airDate: year, summary: summary, tags: tags, episodes: episodes
        )
    }

    /// 没有豆瓣 id 时，用「片名 + 年份」生成稳定的 id（FNV-1a，不能用每次启动都会变的 hashValue）
    static func videoID(title: String, year: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (CMSClient.normalizeTitle(title) + "|" + year).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return -(1_000_000_000 + Int(hash % 1_000_000_000))
    }
}

/// 小说条目：id = -(30 亿 + 书名作者哈希)，同一本书换源后 id 不变，收藏和阅读进度跟着书走
extension BangumiSubject {
    static let novelIDBase = 3_000_000_000

    var isNovel: Bool { id <= -Self.novelIDBase }

    static func novelID(name: String, author: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in NovelBook.identity(name: name, author: author).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return -(novelIDBase + Int(hash % 1_000_000_000))
    }

    static func novel(_ book: NovelBook) -> BangumiSubject {
        let cover = NovelCover.url(book.coverUrl)
        return BangumiSubject(
            id: novelID(name: book.name, author: book.author), name: book.author, nameCN: book.name,
            image: cover, thumb: cover, score: 0, rank: 0, airDate: "", summary: book.intro,
            tags: book.kinds, episodes: 0
        )
    }
}
