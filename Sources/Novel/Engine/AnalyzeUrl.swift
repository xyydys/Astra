import Foundation

/// 书源地址解析和请求（AnalyzeUrl 的移植）：
/// `@js:` / `<js>`、`{{key}}` `{{page}}` 模板、`<1,2,3>` 页码、`,{"method":"POST",...}` 选项、GBK 编码
final class AnalyzeUrl: JSHost {
    let source: BookSource?
    let env: EngineEnv
    let key: String?
    let page: Int?
    var book: RuleBook?
    var chapter: RuleChapter?

    private(set) var ruleUrl = ""
    private(set) var url = ""
    private(set) var baseUrl: String
    private(set) var headerMap: [String: String] = [:]
    private(set) var method = "GET"
    private(set) var body: String?
    private(set) var charset: String?
    private(set) var useWebView = false
    private(set) var webJs: String?
    private var webViewDelay: Double = 0
    private var urlNoQuery = ""
    private var encodedQuery: String?
    private var encodedForm: String?
    private var retry = 0
    private var jsEngine: JSEngine?

    private static let pagePattern = try! NSRegularExpression(pattern: "<(.*?)>")
    private static let jsPattern = try! NSRegularExpression(pattern: "<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", options: [.caseInsensitive])

    init(
        _ mUrl: String, key: String? = nil, page: Int? = nil, baseUrl: String = "",
        source: BookSource?, book: RuleBook? = nil, chapter: RuleChapter? = nil,
        headers: [String: String]? = nil, env: EngineEnv
    ) throws {
        self.source = source
        self.env = env
        self.key = key
        self.page = page
        self.book = book
        self.chapter = chapter
        self.baseUrl = EngineURL.splitOption(baseUrl).url
        if mUrl.hasPrefix("data:") {
            url = mUrl
            urlNoQuery = mUrl
            return
        }
        var map = headers ?? AnalyzeUrl.headerMap(for: source, env: env)
        map.removeValue(forKey: "proxy")
        headerMap = map
        ruleUrl = mUrl
        try analyzeJs()
        try replaceKeyPageJs()
        try analyzeUrl()
    }

    // MARK: 请求头

    /// 书源的请求头（header 可以是 JSON，也可以是返回 JSON 的 JS），再加上登录头
    static func headerMap(for source: BookSource?, env: EngineEnv) -> [String: String] {
        var map: [String: String] = ["User-Agent": JSEngine.userAgent]
        guard let source else { return map }
        var header = source.header.trimmingCharacters(in: .whitespacesAndNewlines)
        if !header.isEmpty {
            let lower = header.lowercased()
            if lower.hasPrefix("@js:") || lower.hasPrefix("<js>") {
                let code: String
                if lower.hasPrefix("@js:") {
                    code = String(header.dropFirst(4))
                } else if let end = header.range(of: "<", options: .backwards), end.lowerBound > header.index(header.startIndex, offsetBy: 4) {
                    code = String(header[header.index(header.startIndex, offsetBy: 4)..<end.lowerBound])
                } else {
                    code = String(header.dropFirst(4))
                }
                let engine = JSEngine(env: env, source: source, host: nil)
                header = RuleValue.string((try? engine.eval(code, bindings: ["baseUrl": source.bookSourceUrl])) ?? nil)
            }
            for (k, v) in parseJSONMap(header) {
                if let existing = map.keys.first(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
                    map.removeValue(forKey: existing)
                }
                map[k] = v
            }
        }
        if let login = EngineStorage.shared.loginHeader(source.key) {
            for (k, v) in parseJSONMap(login) { map[k] = v }
        }
        return map
    }

    static func parseJSONMap(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            return [:]
        }
        return object.mapValues { RuleValue.string($0) }
    }

    // MARK: 解析

    private func analyzeJs() throws {
        var start = 0
        let original = ruleUrl
        let ns = original as NSString
        let matches = original.regexMatches(Self.jsPattern)
        guard !matches.isEmpty else { return }
        for match in matches {
            if match.range.location > start {
                let text = ns.substring(with: NSRange(location: start, length: match.range.location - start)).legadoTrimmed
                if !text.isEmpty { ruleUrl = text.replacingOccurrences(of: "@result", with: ruleUrl) }
            }
            let jsRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 1)
            let value = try evalJS(ns.substring(with: jsRange), result: ruleUrl)
            ruleUrl = RuleValue.string(value)
            start = match.range.location + match.range.length
        }
        if ns.length > start {
            let text = ns.substring(from: start).legadoTrimmed
            if !text.isEmpty { ruleUrl = text.replacingOccurrences(of: "@result", with: ruleUrl) }
        }
    }

    private func replaceKeyPageJs() throws {
        if ruleUrl.contains("{{"), ruleUrl.contains("}}") {
            let replaced = try RuleSplitter.replaceDoubleBraces(ruleUrl) { code -> String in
                let value = try self.evalJS(code, result: nil)
                if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return RuleValue.number(n) }
                return RuleValue.string(value)
            }
            if let replaced, !replaced.isEmpty { ruleUrl = replaced }
        }
        if let page {
            while let match = ruleUrl.regexMatches(Self.pagePattern).first {
                let ns = ruleUrl as NSString
                let pages = ns.substring(with: match.range(at: 1)).components(separatedBy: ",")
                let chosen = page >= 1 && page <= pages.count ? pages[page - 1] : (pages.last ?? "")
                ruleUrl = ns.replacingCharacters(in: match.range, with: chosen.legadoTrimmed)
            }
        }
    }

    private func analyzeUrl() throws {
        let (urlNoOption, option) = EngineURL.splitOption(ruleUrl)
        url = EngineURL.absolute(baseUrl, urlNoOption)
        if let base = EngineURL.baseURL(url) { baseUrl = base }
        if let option, let data = option.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed, .fragmentsAllowed]) as? [String: Any] {
            if let m = object["method"] as? String, m.uppercased() == "POST" { method = "POST" }
            if let headers = object["headers"] {
                let map: [String: String]
                if let dict = headers as? [String: Any] {
                    map = dict.mapValues { RuleValue.string($0) }
                } else {
                    map = AnalyzeUrl.parseJSONMap(RuleValue.string(headers))
                }
                for (k, v) in map {
                    if let existing = headerMap.keys.first(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
                        headerMap.removeValue(forKey: existing)
                    }
                    headerMap[k] = v
                }
            }
            if let b = object["body"] {
                body = b is String ? (b as? String) : RuleValue.string(b)
            }
            if let c = object["charset"] as? String, !c.isEmpty { charset = c }
            if let r = RuleValue.double(object["retry"]) { retry = Int(r) }
            if let w = object["webView"] {
                let text = RuleValue.string(w).lowercased()
                useWebView = !text.isEmpty && text != "false" && text != "0" && text != "null"
            }
            if let js = object["webJs"] as? String, !js.isEmpty { webJs = js }
            if let delay = RuleValue.double(object["webViewDelayTime"]) { webViewDelay = max(delay, 0) / 1000 }
            if let js = object["js"] as? String, !js.isEmpty {
                let value = try evalJS(js, result: url)
                let text = RuleValue.string(value)
                if !text.isEmpty { url = text }
            }
        }
        urlNoQuery = url
        if method == "GET" {
            if let q = url.firstIndex(of: "?") {
                encodedQuery = encodeParams(String(url[url.index(after: q)...]), isQuery: true)
                urlNoQuery = String(url[..<q])
            }
        } else if let body {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let isXML = trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
            if !body.looksLikeJSON, !isXML, header("Content-Type") == nil {
                encodedForm = encodeParams(body, isQuery: false)
            }
        }
    }

    private func header(_ name: String) -> String? {
        headerMap.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func encodeParams(_ params: String, isQuery: Bool) -> String {
        let encoding = EngineText.encoding(named: charset) ?? .utf8
        func encode(_ value: Substring) -> String {
            let text = String(value)
            if EngineText.isEncodedQuery(text) { return text }
            return EngineText.urlEncode(text, encoding: encoding)
        }
        return params.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            if let eq = pair.firstIndex(of: "=") {
                return encode(pair[..<eq]) + "=" + encode(pair[pair.index(after: eq)...])
            }
            return encode(pair)
        }.joined(separator: "&")
    }

    /// 带上编码后查询参数的完整地址
    var fullURL: String {
        guard let encodedQuery, !encodedQuery.isEmpty else { return urlNoQuery }
        return urlNoQuery + "?" + encodedQuery
    }

    // MARK: 请求

    func strResponse(jsStr: String? = nil) throws -> StrResponse {
        try env.token.check()
        if url.hasPrefix("data:") {
            let payload = url.components(separatedBy: "base64,").last ?? ""
            let data = EngineCrypto.base64Decode(payload) ?? Data()
            return StrResponse(url: url, body: EngineText.decode(data, charset: charset, response: nil), code: 200, headers: [:])
        }
        if useWebView, let loader = EngineHooks.webLoader {
            var html: String?
            if method == "POST" {
                html = try httpResponse().body
            }
            let rendered = try loader.load(url: fullURL, html: html, headers: headerMap, js: jsStr ?? webJs, delay: webViewDelay)
            return StrResponse(url: fullURL, body: rendered, code: 200, headers: [:])
        }
        return try httpResponse()
    }

    private func httpResponse() throws -> StrResponse {
        var attempt = 0
        while true {
            do {
                let (data, response) = try perform()
                if EngineHooks.log != nil {
                    let preview = EngineText.decode(data.prefix(600), charset: charset, response: response)
                    EngineHooks.debug("→ \(method) \(fullURL) [\(response.statusCode)] \(preview.replacingOccurrences(of: "\n", with: " ").prefix(400))")
                }
                return StrResponse(
                    url: response.url?.absoluteString ?? fullURL,
                    body: EngineText.decode(data, charset: charset, response: response),
                    code: response.statusCode,
                    headers: EngineHTTP.headers(response)
                )
            } catch BookEngineError.cancelled {
                throw BookEngineError.cancelled
            } catch {
                attempt += 1
                if attempt > retry { throw error }
            }
        }
    }

    func dataResponse() throws -> (Data, HTTPURLResponse) {
        try perform()
    }

    private func perform() throws -> (Data, HTTPURLResponse) {
        guard let target = URL.lenient(fullURL) else { throw BookEngineError.message("地址无效：\(fullURL)") }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        var headers = headerMap
        if let custom = headers.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }) {
            headers.removeValue(forKey: custom.key)
            if let merged = CookieJar.merged(fullURL, custom: custom.value) {
                request.setValue(merged, forHTTPHeaderField: "Cookie")
                request.httpShouldHandleCookies = false
            }
        }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        }
        if method == "POST" {
            let encoding = EngineText.encoding(named: charset) ?? .utf8
            if let encodedForm {
                request.httpBody = Data(encodedForm.utf8)
                if header("Content-Type") == nil {
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                }
            } else if let body {
                request.httpBody = body.data(using: encoding, allowLossyConversion: true)
                if header("Content-Type") == nil {
                    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    let type = body.looksLikeJSON ? "application/json; charset=UTF-8"
                        : (trimmed.hasPrefix("<") ? "text/xml; charset=UTF-8" : "application/x-www-form-urlencoded")
                    request.setValue(type, forHTTPHeaderField: "Content-Type")
                }
            }
        }
        return try EngineHTTP.perform(request, token: env.token)
    }

    // MARK: JS

    private func engine() -> JSEngine {
        if let jsEngine { return jsEngine }
        let engine = JSEngine(env: env, source: source, host: self)
        jsEngine = engine
        return engine
    }

    func evalJS(_ code: String, result: Any?) throws -> Any? {
        let bindings: [String: Any?] = [
            "result": result,
            "baseUrl": baseUrl,
            "key": key,
            "page": page,
            "speakText": nil,
            "speakSpeed": nil,
            "book": book.map { JSEngine.BookRef(book: $0) },
            "chapter": chapter.map { JSEngine.ChapterRef(chapter: $0) },
            "title": chapter?.chapter.title,
        ]
        return try engine().eval(code, bindings: bindings)
    }

    // MARK: JSHost

    var hostBaseUrl: String? { baseUrl }
    var hostBook: RuleBook? { book }
    var hostChapter: RuleChapter? { chapter }
    func hostGetString(_ rule: String, content: Any?, isUrl: Bool) -> String { "" }
    func hostGetStringList(_ rule: String, content: Any?, isUrl: Bool) -> [String] { [] }
    func hostGetElements(_ rule: String) -> [Any] { [] }
    func hostGetElement(_ rule: String) -> Any? { nil }
    func hostSetContent(_ content: Any?, baseUrl: String?) {}

    func hostPut(_ key: String, _ value: String) -> String {
        if let chapter {
            chapter.chapter.variables[key] = value
        } else if let book {
            book.putVariable(key, value)
        } else if let source {
            EngineStorage.shared.put("v_" + source.key + "_" + key, value)
        }
        return value
    }

    func hostGet(_ key: String) -> String {
        if let value = chapter?.chapter.variables[key], !value.isEmpty { return value }
        if let value = book?.getVariable(key), !value.isEmpty { return value }
        if let source, let value = EngineStorage.shared.get("v_" + source.key + "_" + key) { return value }
        return ""
    }
}

// MARK: - 同步网络请求

enum EngineHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 45
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    static let noRedirectSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 45
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    /// 阻塞当前线程直到请求完成（只能在引擎的后台队列里调用）
    static func perform(_ request: URLRequest, token: CancelToken?, followRedirects: Bool = true) throws -> (Data, HTTPURLResponse) {
        try token?.check()
        let box = EngineBox<(Data?, URLResponse?, Error?)>((nil, nil, nil))
        let semaphore = DispatchSemaphore(value: 0)
        let task = (followRedirects ? session : noRedirectSession).dataTask(with: request) { data, response, error in
            box.value = (data, response, error)
            semaphore.signal()
        }
        token?.register(task)
        task.resume()
        semaphore.wait()
        token?.unregister(task)
        let (data, response, error) = box.value
        if let error {
            if (error as NSError).code == NSURLErrorCancelled, token?.isCancelled == true { throw BookEngineError.cancelled }
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw BookEngineError.message("没有响应") }
        if !request.httpShouldHandleCookies, let url = http.url {
            let fields = headers(http)
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
        return (data ?? Data(), http)
    }

    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            out["\(k)"] = "\(v)"
        }
        return out
    }
}
