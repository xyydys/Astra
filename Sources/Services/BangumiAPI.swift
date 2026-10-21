import Foundation

enum BangumiError: LocalizedError {
    case status(Int)
    case format

    var errorDescription: String? {
        switch self {
        case .status(let code): return "Bangumi 返回 \(code)"
        case .format: return "Bangumi 数据格式异常"
        }
    }
}

/// Bangumi 番组计划公开 API（番剧信息、每日放送、热门、搜索）
enum BangumiAPI {
    /// Bangumi 要求 UA 带上应用标识
    static let userAgent = "xyydys/Astra/0.1 (iOS)"
    static let apiBase = "https://api.bgm.tv"
    static let nextBase = "https://next.bgm.tv"

    private static func json(
        _ urlString: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 15
    ) async throws -> Any {
        guard let url = URL(string: urlString) else { throw NetError.badURL(urlString) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BangumiError.status(http.statusCode)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// 每日放送，下标 0 = 周一 … 6 = 周日
    static func calendar() async throws -> [[BangumiSubject]] {
        if let obj = try? await json(nextBase + "/p1/calendar") as? [String: Any] {
            var days: [[BangumiSubject]] = []
            for day in 1...7 {
                let list = obj["\(day)"] as? [[String: Any]] ?? []
                days.append(list.compactMap { item in
                    let subject = item["subject"] as? [String: Any] ?? item
                    return BangumiSubject(json: subject)
                })
            }
            if days.contains(where: { !$0.isEmpty }) { return days }
        }

        // 回退旧版接口
        guard let list = try await json(apiBase + "/calendar") as? [[String: Any]] else {
            throw BangumiError.format
        }
        var days = Array(repeating: [BangumiSubject](), count: 7)
        for day in list {
            let weekday = (day["weekday"] as? [String: Any]).flatMap { JSONValue.int($0["id"]) } ?? 0
            guard (1...7).contains(weekday) else { continue }
            let items = day["items"] as? [[String: Any]] ?? []
            days[weekday - 1] = items.compactMap { BangumiSubject(json: $0) }
        }
        return days
    }

    static func trending(limit: Int = 30) async throws -> [BangumiSubject] {
        let obj = try await json(nextBase + "/p1/trending/subjects?type=2&limit=\(limit)&offset=0")
        guard let dict = obj as? [String: Any], let data = dict["data"] as? [[String: Any]] else {
            throw BangumiError.format
        }
        return data.compactMap { item in
            let subject = item["subject"] as? [String: Any] ?? item
            return BangumiSubject(json: subject)
        }
    }

    static func search(_ keyword: String, offset: Int = 0, limit: Int = 30) async throws -> [BangumiSubject] {
        let body: [String: Any] = [
            "keyword": keyword,
            "sort": "match",
            "filter": ["type": [2]],
        ]
        let obj = try await json(apiBase + "/v0/search/subjects?limit=\(limit)&offset=\(offset)", method: "POST", body: body)
        guard let dict = obj as? [String: Any], let data = dict["data"] as? [[String: Any]] else {
            throw BangumiError.format
        }
        return data.compactMap { BangumiSubject(json: $0) }
    }

    static func subject(id: Int, timeout: TimeInterval = 15) async throws -> BangumiSubject {
        let obj = try await json(apiBase + "/v0/subjects/\(id)", timeout: timeout)
        guard let dict = obj as? [String: Any], let subject = BangumiSubject(json: dict) else {
            throw BangumiError.format
        }
        return subject
    }

    /// 今天在日历里对应的下标（0 = 周一）
    static var todayIndex: Int {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: Date()) // 1 = 周日
        return (weekday + 5) % 7
    }

    static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
}
