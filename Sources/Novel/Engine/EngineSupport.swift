import CommonCrypto
import Foundation

// 阅读（Legado）书源引擎的公共部分：错误、取消、存储、编码和加解密工具。
// 引擎全部是同步代码，跑在 BookEngine 的后台队列里（JS 里的 java.ajax 必须同步返回）。

enum BookEngineError: LocalizedError {
    case message(String)
    case cancelled
    case status(Int, String)
    case js(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "已取消"
        case .status(let code, let url): return "服务器返回 \(code)：\(url)"
        case .js(let text): return "JS 出错：\(text)"
        }
    }
}

/// 一次书源操作的取消令牌：取消时连同正在进行的网络请求一起取消
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [Int: URLSessionTask] = [:]

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let running: [URLSessionTask] = lock.withLock {
            cancelled = true
            let list = Array(tasks.values)
            tasks.removeAll()
            return list
        }
        running.forEach { $0.cancel() }
    }

    func register(_ task: URLSessionTask) {
        let isCancelled: Bool = lock.withLock {
            if !cancelled { tasks[task.taskIdentifier] = task }
            return cancelled
        }
        if isCancelled { task.cancel() }
    }

    func unregister(_ task: URLSessionTask) {
        lock.withLock { tasks[task.taskIdentifier] = nil }
    }

    func check() throws {
        if isCancelled { throw BookEngineError.cancelled }
    }
}

final class EngineBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// 引擎和 App 之间的钩子：浏览器加载、日志、提示
protocol EngineWebLoader: AnyObject {
    /// 在后台线程调用，必须阻塞到页面加载完成。js 为空时返回渲染后的 HTML
    func load(url: String, html: String?, headers: [String: String], js: String?, delay: TimeInterval) throws -> String
}

enum EngineHooks {
    nonisolated(unsafe) static var webLoader: EngineWebLoader?
    nonisolated(unsafe) static var log: ((String) -> Void)?
    nonisolated(unsafe) static var toast: ((String) -> Void)?

    static func debug(_ text: String) {
        log?(text)
    }
}

/// 一次书源操作共享的环境：取消令牌、JS 虚拟机
final class EngineEnv: @unchecked Sendable {
    let token: CancelToken
    private let lock = NSLock()
    private var _vm: AnyObject?

    init(token: CancelToken = CancelToken()) {
        self.token = token
    }

    /// 同一次操作里的 JSContext 共用一个虚拟机（不同操作之间互不干扰，可以并行）
    func sharedVM<T: AnyObject>(_ make: () -> T) -> T {
        lock.withLock {
            if let vm = _vm as? T { return vm }
            let vm = make()
            _vm = vm
            return vm
        }
    }
}

// MARK: - 持久化的缓存和变量（对应阅读的 CacheManager、源变量、登录头）

final class EngineStorage: @unchecked Sendable {
    static let shared = EngineStorage()

    private struct Entry: Codable {
        var value: String
        var expires: Double
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var memory: [String: String] = [:]
    private var saveScheduled = false
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NovelEngine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cache.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            let now = Date().timeIntervalSince1970
            entries = decoded.filter { $0.value.expires == 0 || $0.value.expires > now }
        }
    }

    func get(_ key: String) -> String? {
        lock.withLock {
            if let value = memory[key] { return value }
            guard let entry = entries[key] else { return nil }
            if entry.expires > 0 && entry.expires < Date().timeIntervalSince1970 {
                entries[key] = nil
                return nil
            }
            return entry.value
        }
    }

    /// seconds <= 0 表示永久
    func put(_ key: String, _ value: String, seconds: Double = 0) {
        lock.withLock {
            entries[key] = Entry(value: value, expires: seconds > 0 ? Date().timeIntervalSince1970 + seconds : 0)
            memory[key] = nil
        }
        scheduleSave()
    }

    func delete(_ key: String) {
        lock.withLock {
            entries[key] = nil
            memory[key] = nil
        }
        scheduleSave()
    }

    func getMemory(_ key: String) -> String? { lock.withLock { memory[key] } }
    func putMemory(_ key: String, _ value: String) { lock.withLock { memory[key] = value } }
    func deleteMemory(_ key: String) { lock.withLock { memory[key] = nil } }

    private func scheduleSave() {
        let shouldSchedule: Bool = lock.withLock {
            if saveScheduled { return false }
            saveScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            let snapshot: [String: Entry] = lock.withLock {
                saveScheduled = false
                return entries
            }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    // 书源相关的几个固定键
    func sourceVariable(_ sourceURL: String) -> String { get("sourceVariable_" + sourceURL) ?? "" }
    func setSourceVariable(_ sourceURL: String, _ value: String?) {
        if let value, !value.isEmpty { put("sourceVariable_" + sourceURL, value) } else { delete("sourceVariable_" + sourceURL) }
    }
    func loginHeader(_ sourceURL: String) -> String? { get("loginHeader_" + sourceURL) }
    func setLoginHeader(_ sourceURL: String, _ value: String?) {
        if let value, !value.isEmpty { put("loginHeader_" + sourceURL, value) } else { delete("loginHeader_" + sourceURL) }
    }
    func loginInfo(_ sourceURL: String) -> String? { get("userInfo_" + sourceURL) }
    func setLoginInfo(_ sourceURL: String, _ value: String?) {
        if let value, !value.isEmpty { put("userInfo_" + sourceURL, value) } else { delete("userInfo_" + sourceURL) }
    }
}

// MARK: - Cookie（按主域名存，和阅读的 CookieStore 一样）

enum CookieJar {
    private static let twoLevelSuffixes: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "com.tw", "com.hk", "co.jp", "co.uk", "com.au",
    ]

    static func url(_ tag: String) -> URL? {
        let raw = EngineURL.splitOption(tag).url
        if let url = URL.lenient(raw), url.host != nil { return url }
        return URL(string: "https://" + raw)
    }

    /// 主域名：www.qidian.com → qidian.com
    static func subDomain(_ host: String) -> String {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return host }
        if parts.allSatisfy({ Int($0) != nil }) { return host }
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoLevelSuffixes.contains(lastTwo) {
            return parts.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    static func cookies(_ tag: String) -> [HTTPCookie] {
        guard let url = url(tag), let host = url.host else { return [] }
        let domain = subDomain(host)
        let all = HTTPCookieStorage.shared.cookies ?? []
        return all.filter { cookie in
            let d = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return d == domain || d.hasSuffix("." + domain) || host == d || host.hasSuffix("." + d)
        }
    }

    static func getCookie(_ tag: String) -> String {
        var map: [(String, String)] = []
        var seen = Set<String>()
        for cookie in cookies(tag) where !seen.contains(cookie.name) {
            seen.insert(cookie.name)
            map.append((cookie.name, cookie.value))
        }
        return map.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    static func getKey(_ tag: String, _ key: String) -> String {
        cookieToMap(getCookie(tag))[key] ?? ""
    }

    static func setCookie(_ tag: String, _ cookie: String?) {
        guard let cookie, !cookie.isEmpty, let url = url(tag), let host = url.host else { return }
        let domain = "." + subDomain(host)
        for (name, value) in cookieToMapOrdered(cookie) {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: "/",
                .expires: Date().addingTimeInterval(365 * 24 * 3600),
            ]
            if let item = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(item)
            }
        }
    }

    static func replaceCookie(_ tag: String, _ cookie: String?) {
        guard let cookie, !cookie.isEmpty else { return }
        let old = cookieToMap(getCookie(tag))
        var merged = old
        for (k, v) in cookieToMapOrdered(cookie) { merged[k] = v }
        removeCookie(tag)
        setCookie(tag, merged.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
    }

    static func removeCookie(_ tag: String) {
        for cookie in cookies(tag) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    static func cookieToMap(_ cookie: String) -> [String: String] {
        var map: [String: String] = [:]
        for (k, v) in cookieToMapOrdered(cookie) { map[k] = v }
        return map
    }

    static func cookieToMapOrdered(_ cookie: String) -> [(String, String)] {
        cookie.split(separator: ";").compactMap { pair in
            let item = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = item.firstIndex(of: "=") else { return nil }
            let key = String(item[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, value)
        }
    }

    /// 自定义 Cookie 头和已存的合并，自定义优先
    static func merged(_ tag: String, custom: String?) -> String? {
        var map: [(String, String)] = []
        var index: [String: Int] = [:]
        func add(_ k: String, _ v: String) {
            if let i = index[k] { map[i].1 = v } else { index[k] = map.count; map.append((k, v)) }
        }
        for (k, v) in cookieToMapOrdered(getCookie(tag)) { add(k, v) }
        if let custom { for (k, v) in cookieToMapOrdered(custom) { add(k, v) } }
        guard !map.isEmpty else { return nil }
        return map.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }
}

// MARK: - 地址

enum EngineURL {
    /// 地址和选项的分隔：`url,{"method":"POST"}`
    static let optionRegex = try! NSRegularExpression(pattern: "\\s*,\\s*(?=\\{)")

    static func splitOption(_ text: String) -> (url: String, option: String?) {
        let ns = text as NSString
        guard let match = optionRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return (text, nil)
        }
        return (ns.substring(to: match.range.location), ns.substring(from: match.range.location + match.range.length))
    }

    static func isAbsolute(_ url: String) -> Bool {
        let lower = url.prefix(8).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// 相对地址转绝对地址，保留后面的 `,{选项}`
    static func absolute(_ base: String?, _ relative: String) -> String {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base, !base.isEmpty else { return trimmed }
        if isAbsolute(trimmed) || trimmed.hasPrefix("data:") { return trimmed }
        if trimmed.lowercased().hasPrefix("javascript") { return "" }
        let (path, option) = splitOption(trimmed)
        guard let baseURL = URL.lenient(splitOption(base).url) else { return trimmed }
        let resolved: String
        if path.isEmpty {
            resolved = baseURL.absoluteString
        } else if let url = URL(string: path, relativeTo: baseURL) {
            resolved = url.absoluteString
        } else if let encoded = path.addingPercentEncoding(withAllowedCharacters: lenientAllowed),
                  let url = URL(string: encoded, relativeTo: baseURL) {
            resolved = url.absoluteString
        } else {
            resolved = trimmed
        }
        if let option { return resolved + "," + option }
        return resolved
    }

    static let lenientAllowed = CharacterSet.urlQueryAllowed
        .union(.urlPathAllowed)
        .union(CharacterSet(charactersIn: "#%"))

    /// scheme://host[:port]
    static func baseURL(_ url: String) -> String? {
        guard let u = URL.lenient(url), let scheme = u.scheme, let host = u.host else { return nil }
        if let port = u.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }
}

// MARK: - 字符串工具

extension String {
    /// 阅读的 isJson：首尾是 {} 或 []
    var looksLikeJSON: Bool {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]"))
    }

    /// Kotlin 的 trim { it <= ' ' }
    var legadoTrimmed: String {
        let scalars = unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, scalars[start].value <= 32 { start = scalars.index(after: start) }
        while end > start, scalars[scalars.index(before: end)].value <= 32 { end = scalars.index(before: end) }
        return String(scalars[start..<end])
    }

    var isLegadoTrue: Bool {
        let t = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !t.isEmpty && !["false", "no", "not", "0", "null", "undefined"].contains(t)
    }

    func regexMatches(_ pattern: NSRegularExpression) -> [NSTextCheckingResult] {
        pattern.matches(in: self, range: NSRange(location: 0, length: (self as NSString).length))
    }
}

enum EngineText {
    /// Java String.replaceAll（正则 + $1 引用），正则无效时按普通文本替换
    static func replaceAll(_ text: String, _ regex: String, _ replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: regex) else {
            return text.replacingOccurrences(of: regex, with: replacement)
        }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: javaTemplate(replacement)
        )
    }

    /// 只替换第一个匹配，并且只返回替换后的这一段（阅读 ### 的行为）
    static func replaceFirstMatchOnly(_ text: String, _ regex: String, _ replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: regex) else { return replacement }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return "" }
        let matched = ns.substring(with: match.range)
        let mns = matched as NSString
        guard let inner = re.firstMatch(in: matched, range: NSRange(location: 0, length: mns.length)) else { return matched }
        let replaced = re.replacementString(for: inner, in: matched, offset: 0, template: javaTemplate(replacement))
        return mns.replacingCharacters(in: inner.range, with: replaced)
    }

    /// Java 的替换串里 `\$` 表示字面量 $，NSRegularExpression 模板语法相同；
    /// 这里只把 Kotlin 字符串里常见的 `$0`..`$99` 保持原样
    static func javaTemplate(_ replacement: String) -> String {
        replacement
    }

    /// 判断字符串是否已经是百分号编码过的查询参数
    static func isEncodedQuery(_ value: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!$&()*+,-./:;=?@[\\]^_`{|}~'".unicodeScalars)
        let scalars = Array(value.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "%" {
                guard i + 2 < scalars.count,
                      scalars[i + 1].properties.isASCIIHexDigit, scalars[i + 2].properties.isASCIIHexDigit else { return false }
                i += 3
                continue
            }
            if !allowed.contains(c) { return false }
            i += 1
        }
        return true
    }

    /// Java URLEncoder.encode：空格变 +，只保留字母数字和 .-*_
    static func urlEncode(_ value: String, encoding: String.Encoding = .utf8) -> String {
        guard let data = value.data(using: encoding, allowLossyConversion: true) else { return value }
        var out = ""
        for byte in data {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E, 0x2D, 0x2A, 0x5F:
                out.append(Character(UnicodeScalar(byte)))
            case 0x20:
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func encoding(named name: String?) -> String.Encoding? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let lower = name.lowercased()
        if lower == "utf-8" || lower == "utf8" { return .utf8 }
        if lower == "gbk" || lower == "gb2312" || lower == "gb18030" { return Net.gb18030 }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != CFStringEncoding(kCFStringEncodingInvalidId) else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// 解码网页：指定字符集优先，其次响应头 / meta，最后 UTF-8 → GB18030
    static func decode(_ data: Data, charset: String?, response: URLResponse?) -> String {
        if let encoding = encoding(named: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let name = response?.textEncodingName, let encoding = encoding(named: name),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if head.contains("charset=gb") || head.contains("charset=\"gb") || head.contains("charset='gb") {
            if let text = String(data: data, encoding: Net.gb18030) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: Net.gb18030) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    static let htmlEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": "　",
        "thinsp": "", "zwnj": "", "zwj": "", "middot": "·", "hellip": "…", "mdash": "—", "ndash": "–",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "copy": "©", "reg": "®", "times": "×",
        "laquo": "«", "raquo": "»", "bull": "•", "deg": "°",
    ]

    /// StringEscapeUtils.unescapeHtml4 的常用子集
    static func unescapeHTML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "&", let semi = text[i...].prefix(12).firstIndex(of: ";") {
                let name = String(text[text.index(after: i)..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    if let code = UInt32(name.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) { replacement = String(Character(scalar)) }
                } else if name.hasPrefix("#") {
                    if let code = UInt32(name.dropFirst()), let scalar = UnicodeScalar(code) { replacement = String(Character(scalar)) }
                } else {
                    replacement = htmlEntities[name]
                }
                if let replacement {
                    out += replacement
                    i = text.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }
}

// MARK: - 正文格式化（HtmlFormatter）

enum HTMLFormatter {
    private static let nbsp = try! NSRegularExpression(pattern: "(&nbsp;)+")
    private static let esp = try! NSRegularExpression(pattern: "(&ensp;|&emsp;)")
    private static let noPrint = try! NSRegularExpression(pattern: "(&thinsp;|&zwnj;|&zwj;|\\u2009|\\u200C|\\u200D)")
    private static let wrap = try! NSRegularExpression(pattern: "</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>", options: [.caseInsensitive])
    private static let comment = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")
    private static let notImg = try! NSRegularExpression(pattern: "</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>")
    private static let other = try! NSRegularExpression(pattern: "</?[a-zA-Z]+(?=[ >])[^<>]*>")
    private static let script = try! NSRegularExpression(pattern: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", options: [.caseInsensitive])
    private static let lines = try! NSRegularExpression(pattern: "\\s*\\n+\\s*")
    private static let leading = try! NSRegularExpression(pattern: "^[\\n\\s]+")
    private static let trailing = try! NSRegularExpression(pattern: "[\\n\\s]+$")
    private static let img = try! NSRegularExpression(pattern: "<img[^>]*?\\ssrc\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>", options: [.caseInsensitive])

    private static func sub(_ re: NSRegularExpression, _ text: String, _ template: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// 简介等：去掉所有标签
    static func format(_ html: String?) -> String {
        guard var text = html, !text.isEmpty else { return "" }
        text = sub(script, text, "")
        text = sub(nbsp, text, " ")
        text = sub(esp, text, " ")
        text = sub(noPrint, text, "")
        text = sub(wrap, text, "\n")
        text = sub(comment, text, "")
        text = sub(other, text, "")
        text = sub(lines, text, "\n　　")
        text = sub(leading, text, "　　")
        text = sub(trailing, text, "")
        return text
    }

    /// 正文：保留图片（转成绝对地址）
    static func formatKeepImage(_ html: String?, baseURL: String?) -> String {
        guard var text = html, !text.isEmpty else { return "" }
        text = sub(script, text, "")
        text = sub(nbsp, text, " ")
        text = sub(esp, text, " ")
        text = sub(noPrint, text, "")
        text = sub(wrap, text, "\n")
        text = sub(comment, text, "")
        text = sub(notImg, text, "")
        // 图片地址补全
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in img.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let src = ns.substring(with: match.range(at: 1))
            result += "<img src=\"\(EngineURL.absolute(baseURL, src))\">"
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        text = sub(lines, result, "\n　　")
        text = sub(leading, text, "　　")
        text = sub(trailing, text, "")
        return text
    }
}

// MARK: - 中文数字（toNumChapter）

enum ChineseNumber {
    private static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        "壹": 1, "贰": 2, "叁": 3, "肆": 4, "伍": 5, "陆": 6, "柒": 7, "捌": 8, "玖": 9,
        "０": 0, "１": 1, "２": 2, "３": 3, "４": 4, "５": 5, "６": 6, "７": 7, "８": 8, "９": 9,
    ]
    private static let units: [Character: Int] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000]
    private static let bigUnits: [Character: Int] = ["万": 10000, "亿": 100_000_000]

    static func parse(_ text: String) -> Int? {
        if let n = Int(text) { return n }
        var total = 0, section = 0, number = 0
        var any = false
        for c in text {
            if let d = digits[c] {
                number = number * 10 + d
                any = true
            } else if let u = units[c] {
                section += (number == 0 ? 1 : number) * u
                number = 0
                any = true
            } else if let b = bigUnits[c] {
                total += (section + number) * b
                section = 0
                number = 0
                any = true
            } else {
                return nil
            }
        }
        return any ? total + section + number : nil
    }

    private static let chapterPattern = try! NSRegularExpression(pattern: "^(.*?第)([\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟０-９]+)([章节回卷集部篇].*)$")

    static func toNumChapter(_ text: String?) -> String? {
        guard let text else { return nil }
        let ns = text as NSString
        guard let m = chapterPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
        let numText = ns.substring(with: m.range(at: 2))
        guard let n = parse(numText) else { return text }
        return ns.substring(with: m.range(at: 1)) + String(n) + ns.substring(with: m.range(at: 3))
    }
}

// MARK: - 编码与加解密

enum EngineCrypto {
    static func md5Hex(_ text: String) -> String {
        hex(digest(Data(text.utf8), algorithm: "md5") ?? Data())
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexValue(chars[i]), let lo = hexValue(chars[i + 1]) else { return nil }
            data.append(hi << 4 | lo)
            i += 2
        }
        return data
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    static func base64Decode(_ text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let rem = s.count % 4
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s)
    }

    static func isHex(_ text: String) -> Bool {
        !text.isEmpty && text.count % 2 == 0 && text.allSatisfy { $0.isHexDigit }
    }

    /// hutool 的 SecureUtil.decode：十六进制优先，否则当 Base64
    static func decodeInput(_ text: String) -> Data {
        if isHex(text), let data = hexDecode(text) { return data }
        return base64Decode(text) ?? Data(text.utf8)
    }

    static func digest(_ data: Data, algorithm: String) -> Data? {
        let name = algorithm.lowercased().replacingOccurrences(of: "-", with: "")
        var out = [UInt8]()
        data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress
            let len = CC_LONG(data.count)
            switch name {
            case "md5":
                out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
                CC_MD5(ptr, len, &out)
            case "sha1":
                out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
                CC_SHA1(ptr, len, &out)
            case "sha224":
                out = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
                CC_SHA224(ptr, len, &out)
            case "sha256":
                out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                CC_SHA256(ptr, len, &out)
            case "sha384":
                out = [UInt8](repeating: 0, count: Int(CC_SHA384_DIGEST_LENGTH))
                CC_SHA384(ptr, len, &out)
            case "sha512":
                out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
                CC_SHA512(ptr, len, &out)
            default:
                out = []
            }
        }
        return out.isEmpty ? nil : Data(out)
    }

    static func hmac(_ data: Data, algorithm: String, key: Data) -> Data? {
        let name = algorithm.lowercased().replacingOccurrences(of: "hmac", with: "").replacingOccurrences(of: "-", with: "")
        let alg: CCHmacAlgorithm
        let length: Int
        switch name {
        case "md5": alg = CCHmacAlgorithm(kCCHmacAlgMD5); length = Int(CC_MD5_DIGEST_LENGTH)
        case "sha1": alg = CCHmacAlgorithm(kCCHmacAlgSHA1); length = Int(CC_SHA1_DIGEST_LENGTH)
        case "sha224": alg = CCHmacAlgorithm(kCCHmacAlgSHA224); length = Int(CC_SHA224_DIGEST_LENGTH)
        case "sha256": alg = CCHmacAlgorithm(kCCHmacAlgSHA256); length = Int(CC_SHA256_DIGEST_LENGTH)
        case "sha384": alg = CCHmacAlgorithm(kCCHmacAlgSHA384); length = Int(CC_SHA384_DIGEST_LENGTH)
        case "sha512": alg = CCHmacAlgorithm(kCCHmacAlgSHA512); length = Int(CC_SHA512_DIGEST_LENGTH)
        default: return nil
        }
        var out = [UInt8](repeating: 0, count: length)
        key.withUnsafeBytes { k in
            data.withUnsafeBytes { d in
                CCHmac(alg, k.baseAddress, key.count, d.baseAddress, data.count, &out)
            }
        }
        return Data(out)
    }

    /// 对称加解密，transformation 形如 AES/CBC/PKCS5Padding、DESede/ECB/NoPadding
    static func symmetric(_ input: Data, transformation: String, key: Data, iv: Data?, encrypt: Bool) -> Data? {
        let parts = transformation.uppercased().split(separator: "/").map(String.init)
        let algName = parts.first ?? "AES"
        let mode = parts.count > 1 ? parts[1] : "ECB"
        let padding = parts.count > 2 ? parts[2] : "PKCS5PADDING"

        let algorithm: CCAlgorithm
        let blockSize: Int
        var keyData = key
        switch algName {
        case "DES":
            algorithm = CCAlgorithm(kCCAlgorithmDES)
            blockSize = kCCBlockSizeDES
            keyData = fit(key, to: kCCKeySizeDES)
        case "DESEDE", "3DES", "TRIPLEDES":
            algorithm = CCAlgorithm(kCCAlgorithm3DES)
            blockSize = kCCBlockSize3DES
            keyData = fit(key, to: kCCKeySize3DES)
        default:
            algorithm = CCAlgorithm(kCCAlgorithmAES)
            blockSize = kCCBlockSizeAES128
            if key.count <= 16 { keyData = fit(key, to: 16) } else if key.count <= 24 { keyData = fit(key, to: 24) } else { keyData = fit(key, to: 32) }
        }

        var options = CCOptions(0)
        if mode == "ECB" { options |= CCOptions(kCCOptionECBMode) }
        let pkcs = padding.contains("PKCS")
        var source = input
        if !pkcs && encrypt && padding.contains("ZERO") {
            let rem = source.count % blockSize
            if rem != 0 { source.append(Data(repeating: 0, count: blockSize - rem)) }
        }
        if pkcs { options |= CCOptions(kCCOptionPKCS7Padding) }
        let ivData = mode == "ECB" ? nil : fit(iv ?? Data(), to: blockSize)

        var out = Data(count: source.count + blockSize)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            source.withUnsafeBytes { inPtr in
                keyData.withUnsafeBytes { keyPtr in
                    if let ivData {
                        return ivData.withUnsafeBytes { ivPtr in
                            CCCrypt(
                                CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), algorithm, options,
                                keyPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                inPtr.baseAddress, source.count, outPtr.baseAddress, outCount, &moved
                            )
                        }
                    }
                    return CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), algorithm, options,
                        keyPtr.baseAddress, keyData.count, nil,
                        inPtr.baseAddress, source.count, outPtr.baseAddress, outCount, &moved
                    )
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        out.count = moved
        if !pkcs && !encrypt && padding.contains("ZERO") {
            while let last = out.last, last == 0 { out.removeLast() }
        }
        return out
    }

    private static func fit(_ data: Data, to length: Int) -> Data {
        if data.count == length { return data }
        if data.count > length { return data.prefix(length) }
        return data + Data(repeating: 0, count: length - data.count)
    }
}
