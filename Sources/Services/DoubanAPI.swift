import Foundation

/// 豆瓣影视推荐。豆瓣直连失败时，回退到 60s API 转发的豆瓣周榜（与 LibreTV 的做法一致）
enum DoubanAPI {
    enum Kind: String, CaseIterable, Identifiable {
        case movie
        case tv

        var id: String { rawValue }
        var title: String { self == .movie ? "电影" : "剧集" }

        var tags: [String] {
            switch self {
            case .movie: return ["热门", "最新", "豆瓣高分", "冷门佳片", "华语", "欧美", "韩国", "日本", "动画", "经典"]
            case .tv: return ["热门", "国产剧", "美剧", "英剧", "韩剧", "日剧", "港剧", "日本动画", "综艺", "纪录片"]
            }
        }

        /// 对应的 60s 周榜分类
        var weeklyCategory: String { self == .movie ? "movie" : "tv_chinese" }
    }

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let weeklyBases = ["https://60s.crystelf.top", "https://60s.viki.moe"]

    /// 分类推荐（豆瓣「选电影 / 选剧集」）
    static func recommend(_ kind: Kind, tag: String, start: Int = 0, limit: Int = 24) async throws -> [BangumiSubject] {
        var comps = URLComponents(string: "https://movie.douban.com/j/search_subjects")!
        comps.queryItems = [
            URLQueryItem(name: "type", value: kind.rawValue),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "sort", value: "recommend"),
            URLQueryItem(name: "page_limit", value: "\(limit)"),
            URLQueryItem(name: "page_start", value: "\(start)"),
        ]
        do {
            let json = try await fetch(comps.url!)
            let subjects = json["subjects"] as? [[String: Any]] ?? []
            return subjects.compactMap { raw in
                let id = JSONValue.string(raw["id"])
                let title = JSONValue.string(raw["title"])
                let cover = JSONValue.string(raw["cover"])
                guard let number = Int(id), !title.isEmpty, !cover.isEmpty else { return nil }
                return .video(
                    id: -number, title: title, image: largeCover(cover), thumb: cover,
                    score: Double(JSONValue.string(raw["rate"])) ?? 0
                )
            }
        } catch {
            // 只有「热门」可以用周榜兜底，其它分类没有对应的数据
            guard start == 0, tag == "热门" else { throw error }
            return try await weekly(kind)
        }
    }

    /// 60s API 的豆瓣周榜
    static func weekly(_ kind: Kind) async throws -> [BangumiSubject] {
        var lastError: Error = NetError.status(0)
        for base in weeklyBases {
            do {
                let json = try await fetch(URL(string: "\(base)/v2/douban/weekly/\(kind.weeklyCategory)")!)
                let list = json["data"] as? [[String: Any]] ?? []
                let items: [BangumiSubject] = list.compactMap { raw in
                    let title = JSONValue.string(raw["title"])
                    let cover = JSONValue.string(raw["cover"]).isEmpty ? JSONValue.string(raw["cover_proxy"]) : JSONValue.string(raw["cover"])
                    guard let number = Int(JSONValue.string(raw["id"])), !title.isEmpty, !cover.isEmpty else { return nil }
                    return .video(id: -number, title: title, image: largeCover(cover), thumb: cover, score: JSONValue.double(raw["rating"]))
                }
                if !items.isEmpty { return items }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    struct Abstract {
        var year: String
        var tags: [String]
        var episodes: Int
        var score: Double
        var directors: String
        var actors: String
    }

    /// 条目简介（年份、类型、地区、集数、导演、主演）
    static func abstract(id: String) async throws -> Abstract {
        let json = try await fetch(URL(string: "https://movie.douban.com/j/subject_abstract?subject_id=\(id)")!)
        guard let subject = json["subject"] as? [String: Any] else { throw NetError.status(0) }
        let types = (subject["types"] as? [Any] ?? []).map { JSONValue.string($0) }.filter { !$0.isEmpty }
        let region = JSONValue.string(subject["region"])
        let names: (Any?) -> String = { value in
            (value as? [Any] ?? []).map { JSONValue.string($0) }.filter { !$0.isEmpty }.prefix(4).joined(separator: " / ")
        }
        return Abstract(
            year: JSONValue.string(subject["release_year"]),
            tags: types + (region.isEmpty ? [] : [region]),
            episodes: JSONValue.int(subject["episodes_count"]) ?? 0,
            score: Double(JSONValue.string(subject["rate"])) ?? 0,
            directors: names(subject["directors"]),
            actors: names(subject["actors"])
        )
    }

    /// 列表里的封面是小图，首页大海报换成大图（加载失败时会退回小图）
    static func largeCover(_ url: String) -> String {
        url.replacingOccurrences(of: "/s_ratio_poster/", with: "/l/")
            .replacingOccurrences(of: "/m_ratio_poster/", with: "/l/")
    }

    private static func fetch(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetError.status(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetError.status(0)
        }
        return json
    }
}
