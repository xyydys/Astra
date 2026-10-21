import Foundation

/// 苹果 CMS v10 采集站（LibreTV 使用的同一种资源站接口）
struct CMSSource: Codable, Hashable, Identifiable {
    var name: String
    /// 接口地址，形如 https://example.com/api.php/provide/vod（不带结尾斜杠）
    var url: String
    /// 订阅里标记为成人内容的源，默认不启用
    var isAdult: Bool = false

    var id: String { url.lowercased() }

    init(name: String, url: String, isAdult: Bool = false) {
        self.url = CMSSource.normalize(url)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isAdult = isAdult
        if self.name.isEmpty { self.name = URL(string: self.url)?.host ?? self.url }
    }

    private enum CodingKeys: String, CodingKey { case name, url, isAdult }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: (try? c.decode(String.self, forKey: .name)) ?? "",
            url: try c.decode(String.self, forKey: .url),
            isAdult: (try? c.decode(Bool.self, forKey: .isAdult)) ?? false
        )
    }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func isValidURL(_ raw: String) -> Bool {
        let s = normalize(raw)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// 采集站里的一部影片（搜索结果和详情共用）
struct CMSItem: Hashable, Identifiable, Sendable {
    var api: String
    var sourceName: String
    var vodID: String
    var name: String
    var pic: String
    var typeName: String
    var year: String
    var area: String
    /// 更新状态，如「更新至12集」「HD」
    var remarks: String
    /// 简介（已去掉 HTML 标签）
    var content: String
    var director: String
    var actor: String
    var roads: [Road]

    var id: String { api + "#" + vodID }

    var episodeCount: Int { roads.map(\.episodes.count).max() ?? 0 }
}

enum CMSError: LocalizedError {
    case badURL
    case status(Int)
    case format
    case timeout
    case notFound

    var errorDescription: String? {
        switch self {
        case .badURL: return "接口地址无效"
        case .status(let code): return "接口返回 \(code)"
        case .format: return "接口返回的不是采集站数据"
        case .timeout: return "请求超时"
        case .notFound: return "没有找到这部影片"
        }
    }
}

// MARK: - 接口

enum CMSClient {
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    /// 搜索：第一页拿到总页数后，最多再并发取两页
    static func search(_ source: CMSSource, keyword: String, maxPages: Int = 3) async throws -> [CMSItem] {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }
        let api = source.url, name = source.name
        return try await withDeadline(12) {
            let first = try await fetch(api, query: ["ac": "videolist", "wd": word, "pg": "1"])
            var items = parseList(first, api: api, sourceName: name)
            let pageCount = min(max(JSONValue.int(first["pagecount"]) ?? 1, 1), maxPages)
            if pageCount > 1 {
                let more = await withTaskGroup(of: (Int, [CMSItem]).self) { group in
                    for page in 2...pageCount {
                        group.addTask {
                            guard let json = try? await fetch(api, query: ["ac": "videolist", "wd": word, "pg": "\(page)"]) else {
                                return (page, [])
                            }
                            return (page, parseList(json, api: api, sourceName: name))
                        }
                    }
                    var pages: [(Int, [CMSItem])] = []
                    for await page in group { pages.append(page) }
                    return pages.sorted { $0.0 < $1.0 }.flatMap(\.1)
                }
                items += more
            }
            var seen = Set<String>()
            items = items.filter { seen.insert($0.vodID).inserted }
            if AppSettings.filterAdult {
                items = items.filter { !isAdult($0.typeName) }
            }
            // 部分站点是分词模糊搜索，只保留真正命中关键词的；全被滤掉时宁可原样返回
            let relevant = items.filter { isRelevant($0.name, keyword: word) }
            return relevant.isEmpty ? items : relevant
        }
    }

    /// 详情（带播放地址）
    static func detail(api: String, vodID: String, sourceName: String) async throws -> CMSItem {
        try await withDeadline(15) {
            let json = try await fetch(api, query: ["ac": "videolist", "ids": vodID])
            guard let item = parseList(json, api: api, sourceName: sourceName).first(where: { $0.vodID == vodID })
                    ?? parseList(json, api: api, sourceName: sourceName).first else {
                throw CMSError.notFound
            }
            return item
        }
    }

    /// 可用性检测，返回耗时（秒）
    static func probe(_ source: CMSSource) async throws -> TimeInterval {
        let start = Date()
        let api = source.url
        _ = try await withDeadline(10) {
            let json = try await fetch(api, query: ["ac": "videolist", "wd": "test"])
            return JSONValue.int(json["code"]) ?? 1
        }
        return Date().timeIntervalSince(start)
    }

    // MARK: 请求

    static func url(_ api: String, query: [String: String]) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = query.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        return URL(string: api + (api.contains("?") ? "&" : "?") + pairs)
    }

    private static func fetch(_ api: String, query: [String: String]) async throws -> [String: Any] {
        guard let url = url(api, query: query) else { throw CMSError.badURL }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await Net.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CMSError.status(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            throw CMSError.format
        }
        return json
    }

    // MARK: 解析

    static func parseList(_ json: [String: Any], api: String, sourceName: String) -> [CMSItem] {
        // 部分站点没有结果时返回 list: null
        let list = json["list"] as? [[String: Any]] ?? []
        return list.compactMap { parseItem($0, api: api, sourceName: sourceName) }
    }

    static func parseItem(_ vod: [String: Any], api: String, sourceName: String) -> CMSItem? {
        let id = JSONValue.string(vod["vod_id"])
        let name = JSONValue.string(vod["vod_name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return CMSItem(
            api: api,
            sourceName: sourceName,
            vodID: id,
            name: name,
            pic: normalizedPic(JSONValue.string(vod["vod_pic"])),
            typeName: JSONValue.string(vod["type_name"]),
            year: JSONValue.string(vod["vod_year"]),
            area: JSONValue.string(vod["vod_area"]),
            remarks: JSONValue.string(vod["vod_remarks"]),
            content: plainText(JSONValue.string(vod["vod_content"])),
            director: plainText(JSONValue.string(vod["vod_director"])),
            actor: plainText(JSONValue.string(vod["vod_actor"])),
            roads: roads(
                playFrom: JSONValue.string(vod["vod_play_from"]),
                playURL: JSONValue.string(vod["vod_play_url"])
            )
        )
    }

    /// 采集站的海报图床很多只支持 http，不强制改成 https（应用允许 http 加载）
    static func normalizedPic(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("//") ? "https:" + s : s
    }

    /// vod_play_url：线路之间用 $$$ 分隔，集之间用 #，每集是「名称$地址」。
    /// 有些站第一条线路是网页中转页，带 m3u8 直链的线路排在前面
    static func roads(playFrom: String, playURL: String) -> [Road] {
        let names = playFrom.components(separatedBy: "$$$")
        var direct: [Road] = []
        var others: [Road] = []
        for (index, group) in playURL.components(separatedBy: "$$$").enumerated() {
            var episodes: [Episode] = []
            for (n, raw) in group.components(separatedBy: "#").enumerated() {
                let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !part.isEmpty else { continue }
                let pieces = part.components(separatedBy: "$")
                let url = (pieces.count > 1 ? pieces[1] : pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
                let title = pieces.count > 1 ? pieces[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                episodes.append(Episode(name: title.isEmpty ? "第\(n + 1)集" : title, url: url))
            }
            guard !episodes.isEmpty else { continue }
            let from = index < names.count ? names[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let road = Road(name: from.isEmpty ? "线路\(index + 1)" : from, episodes: episodes)
            if episodes.contains(where: { isDirectMedia($0.url) }) {
                direct.append(road)
            } else {
                others.append(road)
            }
        }
        return direct + others
    }

    /// 是否是播放器能直接播的地址（不是网页中转页）
    static func isDirectMedia(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".mov") || lower.contains(".m4v")
    }

    // MARK: 过滤

    /// 去掉空白、标点和符号并转小写，「摔跤吧！爸爸」和「摔跤吧!爸爸」视为相同
    static func normalizeTitle(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { !drop.contains($0) }))
    }

    static func isRelevant(_ name: String, keyword: String) -> Bool {
        let n = normalizeTitle(name), k = normalizeTitle(keyword)
        if n.isEmpty || k.isEmpty || n.contains(k) { return true }
        let tokens = keyword.split(whereSeparator: \.isWhitespace).map { normalizeTitle(String($0)) }.filter { !$0.isEmpty }
        return tokens.count > 1 && tokens.allSatisfy { n.contains($0) }
    }

    private static let adultKeywords = [
        "伦理", "倫理", "福利", "擦边", "里番", "门事件", "萝莉少女", "制服诱惑", "国产传媒", "cosplay",
        "黑丝", "无码", "有码", "SWAG", "网红主播", "色情", "同性片", "91视频", "自拍偷拍", "mini传媒",
    ]

    static func isAdult(_ typeName: String) -> Bool {
        !typeName.isEmpty && adultKeywords.contains { typeName.localizedCaseInsensitiveContains($0) }
    }

    static func plainText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var s = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&ldquo;": "“", "&rdquo;": "”", "&hellip;": "…", "&middot;": "·"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: "[ \\t\\u3000]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 采集站搜索结果的短期缓存：搜索页搜过的片名，点进详情页时不用再等一遍
actor CMSSearchCache {
    static let shared = CMSSearchCache()

    private var entries: [String: (date: Date, items: [CMSItem])] = [:]

    func search(_ source: CMSSource, keyword: String) async throws -> [CMSItem] {
        let key = source.id + "|" + CMSClient.normalizeTitle(keyword)
        if let hit = entries[key], Date().timeIntervalSince(hit.date) < 600 { return hit.items }
        // 详情页自动匹配和聚合搜索会同时查所有采集站，只取第一页（按片名搜，第一页已经够用）
        let items = try await CMSClient.search(source, keyword: keyword, maxPages: 1)
        entries[key] = (Date(), items)
        if entries.count > 300 {
            entries = entries.filter { Date().timeIntervalSince($0.value.date) < 600 }
        }
        return items
    }
}

/// 超时控制：到点抛出 CMSError.timeout，并取消还在进行的请求
func withDeadline<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CMSError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CMSError.timeout }
        return result
    }
}

// MARK: - 导入（采集站订阅 / TVBox 配置 / Kazumi 规则）

enum SourceImport {
    struct Result {
        var rules: [Rule] = []
        var sources: [CMSSource] = []
        /// TVBox 配置里跳过的站点（爬虫 / XML 接口等原生无法使用的）
        var skipped = 0

        var isEmpty: Bool { rules.isEmpty && sources.isEmpty }
    }

    enum ImportError: LocalizedError {
        case invalid
        case empty(skipped: Int)

        var errorDescription: String? {
            switch self {
            case .invalid:
                return "没有识别到 Kazumi 规则、kazumi:// 链接、采集站订阅或 TVBox 配置"
            case .empty(let skipped):
                return "配置里没有可用的采集站（跳过了 \(skipped) 个爬虫 / XML 接口）"
            }
        }
    }

    /// 粘贴的文本：JSON、kazumi:// 链接，或一个网址（订阅地址 / 采集站接口）
    static func parse(text: String) async throws -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return try parseJSON(Data(trimmed.utf8))
        }
        // MoonTV / LunaTV 的 Base58 编码订阅
        if let decoded = Base58.decodeIfEncoded(trimmed) {
            return try parseJSON(decoded)
        }
        if trimmed.lowercased().hasPrefix("http"), !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) {
            return try await fetch(url)
        }
        // kazumi:// 分享链接交给规则解析
        let rules = try RuleStore.parseImport(trimmed)
        return Result(rules: rules)
    }

    /// 网址：先当订阅（LibreTV-SourceList / TVBox）解析，不是的话再试是不是采集站接口本身
    static func fetch(_ url: URL) async throws -> Result {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(CMSClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await Net.session.data(for: request)
        if let result = try? parseJSON(data) { return result }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Base58.decodeIfEncoded(text), let result = try? parseJSON(decoded) { return result }

        let api = CMSSource.normalize(url.absoluteString)
        let probe = CMSSource(name: url.host ?? api, url: api)
        if (try? await CMSClient.probe(probe)) != nil {
            return Result(sources: [probe])
        }
        throw ImportError.invalid
    }

    static func parseJSON(_ data: Data) throws -> Result {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed, .fragmentsAllowed]) else {
            throw ImportError.invalid
        }

        if let object = json as? [String: Any] {
            if object["sites"] is [Any] || object["lives"] is [Any] {
                return try tvbox(object)
            }
            if let sites = object["api_site"] as? [String: Any] {
                return try moonTV(sites)
            }
            if let list = object["sources"] as? [[String: Any]] {
                return try cmsList(list)
            }
            if isKazumiRule(object), let rule = try? JSONDecoder().decode(Rule.self, from: Data(text.utf8)) {
                return Result(rules: [rule])
            }
            throw ImportError.invalid
        }

        if let array = json as? [[String: Any]] {
            if array.contains(where: isKazumiRule) {
                let rules = (try? JSONDecoder().decode([Rule].self, from: Data(text.utf8)))?
                    .filter { !$0.name.isEmpty && !$0.searchURL.isEmpty } ?? []
                if !rules.isEmpty { return Result(rules: rules) }
            }
            return try cmsList(array)
        }
        throw ImportError.invalid
    }

    private static func isKazumiRule(_ object: [String: Any]) -> Bool {
        object["searchURL"] != nil && object["searchList"] != nil
    }

    /// LibreTV-SourceList：[{ name, url, isAdult }]
    private static func cmsList(_ list: [[String: Any]]) throws -> Result {
        var seen = Set<String>()
        var sources: [CMSSource] = []
        for item in list {
            let url = JSONValue.string(item["url"] ?? item["api"])
            guard CMSSource.isValidURL(url) else { continue }
            let source = CMSSource(
                name: JSONValue.string(item["name"]),
                url: url,
                isAdult: (item["isAdult"] as? Bool) ?? false
            )
            if seen.insert(source.id).inserted { sources.append(source) }
        }
        guard !sources.isEmpty else { throw ImportError.invalid }
        return Result(sources: sources)
    }

    /// MoonTV / LunaTV 配置：{ "api_site": { key: { name, api, detail, is_adult } } }。
    /// 名称带 🔞 或 is_adult 的标记为成人源，导入后默认不启用
    private static func moonTV(_ sites: [String: Any]) throws -> Result {
        var result = Result()
        var seen = Set<String>()
        for key in sites.keys.sorted() {
            guard let site = sites[key] as? [String: Any] else { continue }
            let api = JSONValue.string(site["api"])
            guard CMSSource.isValidURL(api) else {
                result.skipped += 1
                continue
            }
            let name = JSONValue.string(site["name"])
            let adult = (site["is_adult"] as? Bool) == true || name.contains("🔞")
            let source = CMSSource(name: name.isEmpty ? key : name, url: api, isAdult: adult)
            if seen.insert(source.id).inserted { result.sources.append(source) }
        }
        guard !result.sources.isEmpty else { throw ImportError.invalid }
        return result
    }

    /// TVBox 配置：只取能直接调用的苹果 CMS JSON 接口，爬虫（csp_ / type 3）和 XML 接口跳过
    private static func tvbox(_ object: [String: Any]) throws -> Result {
        let sites = object["sites"] as? [[String: Any]] ?? []
        var result = Result()
        var seen = Set<String>()
        for site in sites {
            let api = JSONValue.string(site["api"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let type = JSONValue.int(site["type"])
            let lower = api.lowercased()
            let looksLikeCMS = lower.contains("/api.php/provide/vod") && !lower.contains("/at/xml")
            let usable = CMSSource.isValidURL(api) && !lower.hasPrefix("csp_") && type != 3
                && (type == 1 || ((type == nil || type == 0 || type == 4) && looksLikeCMS))
            guard usable else {
                result.skipped += 1
                continue
            }
            let source = CMSSource(name: JSONValue.string(site["name"]), url: api)
            if seen.insert(source.id).inserted { result.sources.append(source) }
        }
        if result.sources.isEmpty { throw ImportError.empty(skipped: result.skipped) }
        return result
    }
}

/// Base58（比特币字母表）。MoonTV / LunaTV 的订阅链接是整份 JSON 的 Base58 编码
enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let table: [Int] = {
        var table = Array(repeating: -1, count: 128)
        for (index, char) in alphabet.enumerated() { table[Int(char)] = index }
        return table
    }()

    /// 看起来是 Base58（足够长、只含字母表字符）就解码，否则返回 nil
    static func decodeIfEncoded(_ text: String) -> Data? {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= 32 else { return nil }
        return decode(compact)
    }

    static func decode(_ text: String) -> Data? {
        var digits: [UInt64] = []
        digits.reserveCapacity(text.utf8.count)
        for char in text.utf8 {
            guard char < 128, table[Int(char)] >= 0 else { return nil }
            digits.append(UInt64(table[Int(char)]))
        }
        // 大数用 2^32 进制的小端数组存，一次吃进 5 位（58^5 < 2^30，乘积不会溢出 UInt64）
        var limbs: [UInt32] = []
        var i = 0
        while i < digits.count {
            let chunk = min(5, digits.count - i)
            var multiplier: UInt64 = 1
            var carry: UInt64 = 0
            for k in 0..<chunk {
                multiplier *= 58
                carry = carry * 58 + digits[i + k]
            }
            for j in 0..<limbs.count {
                let value = UInt64(limbs[j]) * multiplier + carry
                limbs[j] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
            }
            while carry > 0 {
                limbs.append(UInt32(truncatingIfNeeded: carry))
                carry >>= 32
            }
            i += chunk
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            bytes.append(UInt8(truncatingIfNeeded: limb >> 24))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 16))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 8))
            bytes.append(UInt8(truncatingIfNeeded: limb))
        }
        let firstNonZero = bytes.firstIndex { $0 != 0 } ?? bytes.count
        let leadingOnes = text.utf8.prefix { $0 == UInt8(ascii: "1") }.count
        return Data(repeating: 0, count: leadingOnes) + Data(bytes[firstNonZero...])
    }
}

/// 应用设置（UserDefaults）
enum AppSettings {
    static let filterAdultKey = "filterAdultContent"
    static let hlsAdFilterKey = "hlsAdFilter"
    static let contentModeKey = "contentMode"

    static var filterAdult: Bool {
        UserDefaults.standard.object(forKey: filterAdultKey) as? Bool ?? true
    }

    static var hlsAdFilter: Bool {
        UserDefaults.standard.object(forKey: hlsAdFilterKey) as? Bool ?? true
    }
}
