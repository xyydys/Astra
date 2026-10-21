import Foundation

/// Bangumi 条目（只保留界面需要的字段）
struct BangumiSubject: Hashable, Identifiable, Codable {
    var id: Int
    var name: String
    var nameCN: String
    var image: String
    var thumb: String
    var score: Double
    var rank: Int
    var airDate: String
    var summary: String
    var tags: [String]
    var episodes: Int

    var title: String { nameCN.isEmpty ? name : nameCN }

    /// 海报下方的一行简要信息：年份 · 话数
    var briefInfo: String {
        var parts: [String] = []
        if airDate.count >= 4 { parts.append(String(airDate.prefix(4))) }
        if episodes > 0 { parts.append("\(episodes) 话") }
        return parts.joined(separator: " · ")
    }

    var scoreText: String? {
        score > 0 ? String(format: "%.1f", score) : nil
    }

    /// 片源搜索时可选的关键词（中文名、原名去重）
    var searchKeywords: [String] {
        var seen = Set<String>()
        return [nameCN, name]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

extension BangumiSubject {
    /// 兼容 api.bgm.tv/v0、next.bgm.tv/p1 以及旧版 /calendar 的字段命名
    init?(json: [String: Any]) {
        guard let id = JSONValue.int(json["id"]), id > 0 else { return nil }
        let images = json["images"] as? [String: Any] ?? [:]
        let rating = json["rating"] as? [String: Any] ?? [:]

        var large = JSONValue.string(images["large"])
        if large.isEmpty { large = JSONValue.string(json["image"]) }
        if large.isEmpty { large = JSONValue.string(images["common"]) }
        var common = JSONValue.string(images["common"])
        if common.isEmpty { common = JSONValue.string(images["medium"]) }
        if common.isEmpty { common = large }

        var cn = JSONValue.string(json["name_cn"])
        if cn.isEmpty { cn = JSONValue.string(json["nameCN"]) }

        var date = JSONValue.string(json["date"])
        if date.isEmpty, let airtime = json["airtime"] as? [String: Any] {
            date = JSONValue.string(airtime["date"])
        }
        if date.isEmpty { date = JSONValue.string(json["air_date"]) }

        var score = JSONValue.double(rating["score"])
        if score == 0 { score = JSONValue.double(json["score"]) }
        var rank = JSONValue.int(rating["rank"]) ?? 0
        if rank == 0 { rank = JSONValue.int(json["rank"]) ?? 0 }

        let tagList = (json["tags"] as? [[String: Any]] ?? [])
            .map { JSONValue.string($0["name"]) }
            .filter { !$0.isEmpty }

        let eps = JSONValue.int(json["total_episodes"])
            ?? JSONValue.int(json["eps"])
            ?? JSONValue.int(json["eps_count"])
            ?? 0

        self.init(
            id: id,
            name: JSONValue.string(json["name"]),
            nameCN: cn,
            image: JSONValue.httpsImage(large),
            thumb: JSONValue.httpsImage(common),
            score: score,
            rank: rank,
            airDate: date,
            summary: JSONValue.string(json["summary"]),
            tags: tagList,
            episodes: eps
        )
    }

    /// 详情接口回来的字段比列表全，合并时以非空值为准
    func merged(with detail: BangumiSubject) -> BangumiSubject {
        var s = self
        if !detail.name.isEmpty { s.name = detail.name }
        if !detail.nameCN.isEmpty { s.nameCN = detail.nameCN }
        if !detail.image.isEmpty { s.image = detail.image }
        if !detail.thumb.isEmpty { s.thumb = detail.thumb }
        if detail.score > 0 { s.score = detail.score }
        if detail.rank > 0 { s.rank = detail.rank }
        if !detail.airDate.isEmpty { s.airDate = detail.airDate }
        if !detail.summary.isEmpty { s.summary = detail.summary }
        if !detail.tags.isEmpty { s.tags = detail.tags }
        if detail.episodes > 0 { s.episodes = detail.episodes }
        return s
    }
}

enum JSONValue {
    static func string(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    static func int(_ any: Any?) -> Int? {
        switch any {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func double(_ any: Any?) -> Double {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    static func httpsImage(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        return s
    }
}
