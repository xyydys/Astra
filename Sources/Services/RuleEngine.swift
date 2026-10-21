import Foundation

enum RuleError: LocalizedError, Equatable {
    case captchaRequired
    case noResult
    case unsupported(String)
    case network(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .captchaRequired: return "需要先完成网页验证"
        case .noResult: return "没有搜到结果"
        case .unsupported(let reason): return reason
        case .network(let msg): return "网络错误：\(msg)"
        case .parse(let msg): return "解析失败：\(msg)"
        }
    }
}

/// 规则执行：请求页面 → XPath 解析。逻辑对齐 Kazumi 的 RuleEngine + XPathRuleStrategy。
@MainActor
enum RuleEngine {
    /// 通过网页验证后，后续搜索沿用验证时的 UA（站点的验证 cookie 往往和 UA 绑定）
    static var verifiedUserAgents: [String: String] = [:]

    // MARK: 搜索

    static func searchRequest(for rule: Rule, keyword: String) throws -> URLRequest {
        let query = rule.searchURL.replacingOccurrences(of: "@keyword", with: keyword.queryComponentEncoded)
        guard let url = URL.lenient(query), url.host != nil else { throw RuleError.parse("搜索地址无效：\(query)") }

        var request: URLRequest
        if rule.usePost, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let body = comps.percentEncodedQuery ?? ""
            comps.percentEncodedQuery = nil
            guard let postURL = comps.url else { throw RuleError.parse("搜索地址无效：\(query)") }
            request = URLRequest(url: postURL)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else {
            request = URLRequest(url: url)
            request.httpMethod = "GET"
        }
        applyHeaders(&request, rule: rule)
        return request
    }

    static func search(_ rule: Rule, keyword: String) async throws -> [SearchItem] {
        if let reason = rule.unsupportedReason { throw RuleError.unsupported(reason) }
        let request = try searchRequest(for: rule, keyword: keyword)

        let response: Net.TextResponse
        do {
            response = try await Net.text(request)
        } catch {
            throw RuleError.network(error.localizedDescription)
        }

        if response.status >= 400 {
            if rule.antiCrawlerConfig.enabled {
                let cf = response.header("cf-mitigated")?.lowercased()
                if cf == "challenge" { throw RuleError.captchaRequired }
                if await detectsCaptcha(response.text, rule: rule) { throw RuleError.captchaRequired }
            }
            throw RuleError.network("HTTP \(response.status)")
        }
        if await detectsCaptcha(response.text, rule: rule) {
            throw RuleError.captchaRequired
        }
        let items = try await parseSearch(html: response.text, rule: rule)
        if items.isEmpty { throw RuleError.noResult }
        return items
    }

    static func parseSearch(html: String, rule: Rule) async throws -> [SearchItem] {
        let raw = try await XPathEngine.shared.search(
            html: html, list: rule.searchList, name: rule.searchName, result: rule.searchResult
        )
        var seen = Set<String>()
        return raw.compactMap { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let href = item.href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !href.isEmpty, seen.insert(href).inserted else { return nil }
            return SearchItem(name: name, url: href)
        }
    }

    // MARK: 选集

    static func chapters(_ rule: Rule, source: String) async throws -> [Road] {
        if let reason = rule.unsupportedReason { throw RuleError.unsupported(reason) }
        let urlString = normalize(base: rule.baseURL, raw: source)
        guard let url = URL.lenient(urlString) else { throw RuleError.parse("详情页地址无效：\(urlString)") }
        var request = URLRequest(url: url)
        applyHeaders(&request, rule: rule)

        let response: Net.TextResponse
        do {
            response = try await Net.text(request)
        } catch {
            throw RuleError.network(error.localizedDescription)
        }
        if response.status >= 400 { throw RuleError.network("HTTP \(response.status)") }

        let raw = try await XPathEngine.shared.chapters(
            html: response.text, roads: rule.chapterRoads, episodes: rule.chapterResult
        )
        var roads: [Road] = []
        for list in raw {
            let episodes = list.enumerated().compactMap { (index, ep) -> Episode? in
                let url = normalize(base: rule.baseURL, raw: ep.href)
                guard !url.isEmpty else { return nil }
                return Episode(name: ep.name.isEmpty ? "第\(index + 1)集" : ep.name, url: url)
            }
            if !episodes.isEmpty {
                roads.append(Road(name: "线路\(roads.count + 1)", episodes: episodes))
            }
        }
        if roads.isEmpty { throw RuleError.parse("没有解析到剧集") }
        return roads
    }

    // MARK: 验证页检测

    static func detectsCaptcha(_ html: String, rule: Rule) async -> Bool {
        let config = rule.antiCrawlerConfig
        guard config.enabled else { return false }
        let value = config.captchaDetectValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            switch config.captchaDetectType {
            case 2:
                return html.contains(value)
            case 3:
                return html.range(of: value, options: [.regularExpression, .caseInsensitive]) != nil
            default:
                return await XPathEngine.shared.exists(html: html, xpath: value)
            }
        }
        for xpath in [config.captchaImage, config.captchaButton] where !xpath.trimmingCharacters(in: .whitespaces).isEmpty {
            if await XPathEngine.shared.exists(html: html, xpath: xpath) { return true }
        }
        return false
    }

    // MARK: 工具

    static func userAgent(for rule: Rule) -> String {
        verifiedUserAgents[rule.id] ?? UserAgents.random()
    }

    private static func applyHeaders(_ request: inout URLRequest, rule: Rule) {
        request.timeoutInterval = 15
        request.setValue(userAgent(for: rule), forHTTPHeaderField: "User-Agent")
        request.setValue(UserAgents.randomLanguage(), forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let base = rule.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            request.setValue(base.hasSuffix("/") ? base : base + "/", forHTTPHeaderField: "Referer")
        }
    }

    /// 对齐 Kazumi 的 normalizeEpisodeUrl：补全相对路径、统一同站协议、去掉尾斜杠
    static func normalize(base: String, raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let baseURL = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines))

        var resolved: URL?
        if let u = URL(string: trimmed), u.scheme != nil, u.host != nil {
            resolved = u
        } else if let b = baseURL, b.scheme != nil {
            resolved = URL(string: trimmed, relativeTo: b)?.absoluteURL
        }
        if resolved == nil, let u = URL.lenient(trimmed), u.host != nil {
            resolved = u
        }
        guard let url = resolved,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
              comps.host != nil else {
            return trimmed
        }

        if let b = baseURL, let bs = b.scheme?.lowercased(), let rs = comps.scheme?.lowercased(),
           ["http", "https"].contains(bs), ["http", "https"].contains(rs),
           bs != rs, comps.host == b.host, comps.port == b.port {
            comps.scheme = bs
        }

        var path = comps.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        comps.percentEncodedPath = path
        if comps.percentEncodedQuery?.isEmpty == true { comps.percentEncodedQuery = nil }
        if comps.percentEncodedFragment?.isEmpty == true { comps.percentEncodedFragment = nil }
        return comps.string ?? trimmed
    }
}
