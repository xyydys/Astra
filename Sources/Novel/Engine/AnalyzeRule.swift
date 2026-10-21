import Foundation
import SwiftSoup

/// 规则结果和内容的通用转换
enum RuleValue {
    static func string(_ value: Any?) -> String {
        guard let value else { return "" }
        switch value {
        case let s as String: return s
        case let e as Element: return (try? e.outerHtml()) ?? ""
        case let list as [Element]: return list.compactMap { try? $0.outerHtml() }.joined(separator: "\n")
        case is NSNull: return ""
        case let n as NSNumber: return number(n)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return number(NSNumber(value: d))
        case let list as [String]: return list.joined(separator: "\n")
        case let item as XPathRules.Item: return item.string
        default:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(value)"
        }
    }

    static func number(_ n: NSNumber) -> String {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        let d = n.doubleValue
        if d.isFinite, d == d.rounded(), abs(d) < 9.0e15 { return String(Int64(d)) }
        return n.stringValue
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// 内容是不是 JSON（决定规则默认按 JSONPath 解析）
    static func isJSON(_ content: Any) -> Bool {
        switch content {
        case let s as String: return s.looksLikeJSON
        case is Element, is [Element]: return false
        case is [String: Any], is [Any]: return true
        default: return false
        }
    }
}

/// 阅读的「书/章节」变量，规则里的 java.put / java.get / @put / @get 都存在这里
final class RuleBook {
    var book: NovelBook
    /// 正在读的章节（正文规则里的 {{book.durChapterTitle}} 会用到）
    var durChapterTitle = ""
    var durChapterIndex = 0
    /// 详情页、目录页已经下载过时可以直接用
    var infoHTML: String?
    var tocHTML: String?

    init(_ book: NovelBook) {
        self.book = book
    }

    func putVariable(_ key: String, _ value: String?) {
        if let value { book.variables[key] = value } else { book.variables[key] = nil }
    }

    func getVariable(_ key: String) -> String {
        book.variables[key] ?? ""
    }
}

final class RuleChapter {
    var chapter: NovelChapter

    init(_ chapter: NovelChapter) {
        self.chapter = chapter
    }
}

/// 规则解析器（AnalyzeRule 的移植）：一份内容 + 一组规则
final class AnalyzeRule: JSHost {
    let source: BookSource?
    let env: EngineEnv
    var book: RuleBook?
    var chapter: RuleChapter?
    var nextChapterUrl: String?

    private(set) var content: Any?
    private(set) var baseUrl: String?
    private(set) var redirectUrl: String?
    private var isJSON = false
    private var cachedRoot: Element?
    private var cachedJSON: Any?
    private var jsEngine: JSEngine?

    init(source: BookSource?, book: RuleBook? = nil, env: EngineEnv) {
        self.source = source
        self.book = book
        self.env = env
    }

    // MARK: 内容

    @discardableResult
    func setContent(_ content: Any?, baseUrl: String? = nil) -> AnalyzeRule {
        self.content = content
        isJSON = content.map { RuleValue.isJSON($0) } ?? false
        cachedRoot = nil
        cachedJSON = nil
        if let baseUrl { setBaseUrl(baseUrl) }
        return self
    }

    func setBaseUrl(_ url: String?) {
        if let url, !url.isEmpty { baseUrl = url }
    }

    @discardableResult
    func setRedirectUrl(_ url: String?) -> String? {
        if let url, !url.isEmpty { redirectUrl = url }
        return redirectUrl
    }

    private var resolveBase: String? { redirectUrl ?? baseUrl }

    private func htmlRules(_ value: Any, original: Bool) -> HTMLRules? {
        if original, let cachedRoot { return HTMLRules(root: cachedRoot) }
        guard let root = try? HTMLRules.parse(value) else { return nil }
        if original { cachedRoot = root }
        return HTMLRules(root: root)
    }

    private func xpathRules(_ value: Any, original: Bool) -> XPathRules? {
        guard let html = htmlRules(value, original: original) else { return nil }
        return XPathRules(root: html.root)
    }

    private func jsonRules(_ value: Any, original: Bool) -> JSONPathRules? {
        if original, let cachedJSON { return JSONPathRules(json: cachedJSON) }
        if value is Element || value is [Element] { return nil }
        guard let rules = try? JSONPathRules(content: value) else { return nil }
        if original { cachedJSON = rules.root }
        return rules
    }

    // MARK: 规则切分

    enum Mode {
        case xpath, json, standard, js, regex
    }

    struct SourceRule {
        var mode: Mode
        var rule: String
        var putMap: [String: String] = [:]
        /// 类型：-2 @get，-1 {{}}，0 普通文本，>0 正则分组 $n
        var params: [(Int, String)] = []

        private static let getPattern = try! NSRegularExpression(pattern: "@get:\\{[^}]+?\\}|\\{\\{[\\w\\W]*?\\}\\}", options: [.caseInsensitive])
        private static let groupPattern = try! NSRegularExpression(pattern: "\\$\\d{1,2}")
        private static let putPattern = try! NSRegularExpression(pattern: "@put:(\\{[^}]+?\\})", options: [.caseInsensitive])

        init(_ ruleStr: String, mode initialMode: Mode = .standard, isJSON: Bool) {
            var mode = initialMode
            var rule: String
            let lower = ruleStr.prefix(7).lowercased()
            if mode == .js || mode == .regex {
                rule = ruleStr
            } else if lower.hasPrefix("@css:") {
                mode = .standard
                rule = ruleStr
            } else if ruleStr.hasPrefix("@@") {
                mode = .standard
                rule = String(ruleStr.dropFirst(2))
            } else if lower.hasPrefix("@xpath:") {
                mode = .xpath
                rule = String(ruleStr.dropFirst(7))
            } else if lower.hasPrefix("@json:") {
                mode = .json
                rule = String(ruleStr.dropFirst(6))
            } else if isJSON || ruleStr.hasPrefix("$.") || ruleStr.hasPrefix("$[") {
                mode = .json
                rule = ruleStr
            } else if ruleStr.hasPrefix("/") {
                mode = .xpath
                rule = ruleStr
            } else {
                rule = ruleStr
            }

            // 分离 @put
            var putMap: [String: String] = [:]
            for match in rule.regexMatches(Self.putPattern).reversed() {
                let ns = rule as NSString
                let json = ns.substring(with: match.range(at: 1))
                for (k, v) in LenientMap.parse(json) { putMap[k] = v }
                rule = ns.replacingCharacters(in: match.range, with: "")
            }

            // 拆出 @get、{{ }}
            var params: [(Int, String)] = []
            let ns = rule as NSString
            let matches = rule.regexMatches(Self.getPattern)
            var start = 0
            if let first = matches.first {
                let before = ns.substring(to: first.range.location)
                if mode != .js && mode != .regex && (first.range.location == 0 || !before.contains("##")) {
                    mode = .regex
                }
                for match in matches {
                    if match.range.location > start {
                        Self.splitRegex(ns.substring(with: NSRange(location: start, length: match.range.location - start)), &mode, &params)
                    }
                    let token = ns.substring(with: match.range)
                    if token.lowercased().hasPrefix("@get:") {
                        params.append((-2, String(token.dropFirst(6).dropLast())))
                    } else if token.hasPrefix("{{") {
                        params.append((-1, String(token.dropFirst(2).dropLast(2))))
                    } else {
                        Self.splitRegex(token, &mode, &params)
                    }
                    start = match.range.location + match.range.length
                }
            }
            if ns.length > start {
                Self.splitRegex(ns.substring(from: start), &mode, &params)
            }

            self.mode = mode
            self.rule = rule
            self.putMap = putMap
            self.params = params
        }

        private static func splitRegex(_ text: String, _ mode: inout Mode, _ params: inout [(Int, String)]) {
            let ns = text as NSString
            let head = text.components(separatedBy: "##")[0]
            let matches = head.regexMatches(groupPattern)
            var start = 0
            if !matches.isEmpty {
                if mode != .js && mode != .regex { mode = .regex }
                for match in matches {
                    if match.range.location > start {
                        params.append((0, ns.substring(with: NSRange(location: start, length: match.range.location - start))))
                    }
                    let token = ns.substring(with: match.range)
                    params.append((Int(token.dropFirst()) ?? 0, token))
                    start = match.range.location + match.range.length
                }
            }
            if ns.length > start {
                params.append((0, ns.substring(from: start)))
            }
        }
    }

    /// 替换完 {{}}、@get、$n 之后的规则
    struct ResolvedRule {
        var rule: String
        var replaceRegex = ""
        var replacement = ""
        var replaceFirst = false
    }

    private static let jsPattern = try! NSRegularExpression(pattern: "<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", options: [.caseInsensitive])

    func splitSourceRule(_ ruleStr: String?, allInOne: Bool = false) -> [SourceRule] {
        guard let ruleStr, !ruleStr.isEmpty else { return [] }
        var list: [SourceRule] = []
        var mode: Mode = .standard
        var start = 0
        let ns = ruleStr as NSString
        if allInOne, ruleStr.hasPrefix(":") {
            mode = .regex
            start = 1
        }
        for match in ruleStr.regexMatches(Self.jsPattern) {
            if match.range.location > start {
                let text = ns.substring(with: NSRange(location: start, length: match.range.location - start)).legadoTrimmed
                if !text.isEmpty { list.append(SourceRule(text, mode: mode, isJSON: isJSON)) }
            }
            let jsRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 1)
            list.append(SourceRule(ns.substring(with: jsRange), mode: .js, isJSON: isJSON))
            start = match.range.location + match.range.length
        }
        if ns.length > start {
            let text = ns.substring(from: start).legadoTrimmed
            if !text.isEmpty { list.append(SourceRule(text, mode: mode, isJSON: isJSON)) }
        }
        return list
    }

    private func isInnerRule(_ text: String) -> Bool {
        text.hasPrefix("@") || text.hasPrefix("$.") || text.hasPrefix("$[") || text.hasPrefix("//")
    }

    private func resolve(_ rule: SourceRule, result: Any?) -> ResolvedRule {
        var text = rule.rule
        if !rule.params.isEmpty {
            var out = ""
            for (type, value) in rule.params {
                if type > 0 {
                    if let list = result as? [Any] {
                        if list.count > type { out += RuleValue.string(list[type]) }
                    } else {
                        out += value
                    }
                } else if type == -1 {
                    if isInnerRule(value) {
                        out += getString([SourceRule(value, isJSON: isJSON)])
                    } else {
                        out += jsText(try? evalJS(value, result: result))
                    }
                } else if type == -2 {
                    out += get(value)
                } else {
                    out += value
                }
            }
            text = out
        }
        let parts = text.components(separatedBy: "##")
        var resolved = ResolvedRule(rule: parts[0].legadoTrimmed)
        if parts.count > 1 { resolved.replaceRegex = parts[1] }
        if parts.count > 2 { resolved.replacement = parts[2] }
        if parts.count > 3 { resolved.replaceFirst = true }
        return resolved
    }

    private func jsText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return RuleValue.number(n)
        }
        return RuleValue.string(value)
    }

    private func applyRegex(_ text: String, _ rule: ResolvedRule) -> String {
        guard !rule.replaceRegex.isEmpty else { return text }
        if rule.replaceFirst {
            return EngineText.replaceFirstMatchOnly(text, rule.replaceRegex, rule.replacement)
        }
        return EngineText.replaceAll(text, rule.replaceRegex, rule.replacement)
    }

    /// JS 返回的对象（字典）和 JSONPath 取出的对象：没写前缀的规则按 JSON 解析
    private func effectiveMode(_ mode: Mode, _ value: Any) -> Mode {
        if mode == .standard, value is [String: Any] { return .json }
        return mode
    }

    private func putRule(_ map: [String: String]) {
        for (key, rule) in map {
            _ = put(key, getString(rule))
        }
    }

    // MARK: 取值

    func getString(_ ruleStr: String?, content: Any? = nil, isUrl: Bool = false, unescape: Bool = true) -> String {
        guard let ruleStr, !ruleStr.isEmpty else { return "" }
        return getString(splitSourceRule(ruleStr), content: content, isUrl: isUrl, unescape: unescape)
    }

    func getString(_ rules: [SourceRule], content explicit: Any? = nil, isUrl: Bool = false, unescape: Bool = true) -> String {
        var result: Any? = rules.isEmpty ? nil : (explicit ?? content)
        if result != nil {
            var original = explicit == nil
            for rule in rules {
                guard let current = result else { break }
                putRule(rule.putMap)
                let resolved = resolve(rule, result: current)
                if !resolved.rule.isEmpty || resolved.replaceRegex.isEmpty {
                    switch effectiveMode(rule.mode, current) {
                    case .js:
                        result = evalLogged(resolved.rule, result: current)
                    case .json:
                        result = jsonRules(current, original: original)?.string(resolved.rule)
                    case .xpath:
                        result = xpathRules(current, original: original)?.string(resolved.rule)
                    case .standard:
                        result = htmlRules(current, original: original)?.string(resolved.rule)
                    case .regex:
                        result = resolved.rule
                    }
                }
                if let value = result, !resolved.replaceRegex.isEmpty {
                    result = applyRegex(RuleValue.string(value), resolved)
                }
                original = false
            }
        }
        var text = RuleValue.string(result)
        if unescape { text = EngineText.unescapeHTML(text) }
        if isUrl {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return baseUrl ?? "" }
            return EngineURL.absolute(resolveBase, text)
        }
        return text
    }

    func getStringList(_ ruleStr: String?, content: Any? = nil, isUrl: Bool = false) -> [String]? {
        guard let ruleStr, !ruleStr.isEmpty else { return nil }
        return getStringList(splitSourceRule(ruleStr), content: content, isUrl: isUrl)
    }

    func getStringList(_ rules: [SourceRule], content explicit: Any? = nil, isUrl: Bool = false) -> [String]? {
        guard !rules.isEmpty else { return nil }
        var result: Any? = explicit ?? content
        if result != nil {
            var original = explicit == nil
            for rule in rules {
                guard let current = result else { break }
                putRule(rule.putMap)
                let resolved = resolve(rule, result: current)
                if !resolved.rule.isEmpty {
                    switch effectiveMode(rule.mode, current) {
                    case .js:
                        result = evalLogged(resolved.rule, result: current)
                    case .json:
                        result = jsonRules(current, original: original)?.stringList(resolved.rule)
                    case .xpath:
                        result = xpathRules(current, original: original)?.stringList(resolved.rule)
                    case .standard:
                        result = htmlRules(current, original: original)?.stringList(resolved.rule)
                    case .regex:
                        result = resolved.rule
                    }
                }
                if !resolved.replaceRegex.isEmpty, let value = result {
                    if let list = value as? [Any] {
                        result = list.map { applyRegex(RuleValue.string($0), resolved) }
                    } else {
                        result = applyRegex(RuleValue.string(value), resolved)
                    }
                }
                original = false
            }
        }
        guard let result else { return nil }
        var list: [String]
        if let text = result as? String {
            list = text.components(separatedBy: "\n")
        } else if let items = result as? [Any] {
            list = items.map { RuleValue.string($0) }
        } else {
            list = [RuleValue.string(result)]
        }
        if isUrl {
            var urls: [String] = []
            for item in list {
                let url = EngineURL.absolute(resolveBase, item)
                if !url.isEmpty, !urls.contains(url) { urls.append(url) }
            }
            return urls
        }
        return list
    }

    /// 列表规则：书籍列表、目录列表
    func getElements(_ ruleStr: String) -> [Any] {
        let rules = splitSourceRule(ruleStr, allInOne: true)
        var result: Any? = content
        guard result != nil, !rules.isEmpty else { return [] }
        var original = true
        for rule in rules {
            guard let current = result else { break }
            putRule(rule.putMap)
            let resolved = resolve(rule, result: current)
            switch effectiveMode(rule.mode, current) {
            case .regex:
                let regs = resolved.rule.components(separatedBy: "&&").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                result = RegexRules.elements(RuleValue.string(current), regs)
            case .js:
                result = evalLogged(resolved.rule, result: current)
            case .json:
                result = jsonRules(current, original: original)?.list(resolved.rule)
            case .xpath:
                result = xpathRules(current, original: original)?.elements(resolved.rule)
            case .standard:
                result = htmlRules(current, original: original)?.elements(resolved.rule)
            }
            if !resolved.replaceRegex.isEmpty, let value = result {
                result = applyRegex(RuleValue.string(value), resolved)
            }
            original = false
        }
        if let elements = result as? [Element] { return elements }
        if let list = result as? [Any] { return list }
        return []
    }

    /// 单个元素（详情页的 init 规则）
    func getElement(_ ruleStr: String) -> Any? {
        let rules = splitSourceRule(ruleStr, allInOne: true)
        var result: Any? = content
        guard result != nil, !rules.isEmpty else { return nil }
        var original = true
        for rule in rules {
            guard let current = result else { break }
            putRule(rule.putMap)
            let resolved = resolve(rule, result: current)
            switch effectiveMode(rule.mode, current) {
            case .regex:
                let regs = resolved.rule.components(separatedBy: "&&").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                result = RegexRules.element(RuleValue.string(current), regs)
            case .js:
                result = evalLogged(resolved.rule, result: current)
            case .json:
                result = jsonRules(current, original: original)?.object(resolved.rule)
            case .xpath:
                result = xpathRules(current, original: original)?.elements(resolved.rule)
            case .standard:
                result = htmlRules(current, original: original)?.elements(resolved.rule)
            }
            if !resolved.replaceRegex.isEmpty, let value = result {
                result = applyRegex(RuleValue.string(value), resolved)
            }
            original = false
        }
        return result
    }

    // MARK: 变量

    func put(_ key: String, _ value: String) -> String {
        if let chapter {
            chapter.chapter.variables[key] = value
        } else if let book {
            book.putVariable(key, value)
        } else if let source {
            EngineStorage.shared.put("v_" + source.key + "_" + key, value)
        }
        return value
    }

    func get(_ key: String) -> String {
        if key == "bookName", let book { return book.book.name }
        if key == "title", let chapter { return chapter.chapter.title }
        if let value = chapter?.chapter.variables[key], !value.isEmpty { return value }
        if let value = book?.getVariable(key), !value.isEmpty { return value }
        if let source, let value = EngineStorage.shared.get("v_" + source.key + "_" + key), !value.isEmpty { return value }
        return ""
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
            "src": content,
            "nextChapterUrl": nextChapterUrl,
            "title": chapter?.chapter.title,
            "book": book.map { JSEngine.BookRef(book: $0) },
            "chapter": chapter.map { JSEngine.ChapterRef(chapter: $0) },
        ]
        return try engine().eval(code, bindings: bindings)
    }

    private func evalLogged(_ code: String, result: Any?) -> Any? {
        do {
            return try evalJS(code, result: result)
        } catch {
            EngineHooks.debug("[\(source?.bookSourceName ?? "")] \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: JSHost

    var hostBaseUrl: String? { baseUrl }
    var hostBook: RuleBook? { book }
    var hostChapter: RuleChapter? { chapter }

    func hostGetString(_ rule: String, content: Any?, isUrl: Bool) -> String {
        getString(rule, content: content, isUrl: isUrl)
    }

    func hostGetStringList(_ rule: String, content: Any?, isUrl: Bool) -> [String] {
        getStringList(rule, content: content, isUrl: isUrl) ?? []
    }

    func hostGetElements(_ rule: String) -> [Any] {
        getElements(rule)
    }

    func hostGetElement(_ rule: String) -> Any? {
        getElement(rule)
    }

    func hostSetContent(_ content: Any?, baseUrl: String?) {
        setContent(content, baseUrl: baseUrl)
    }

    func hostPut(_ key: String, _ value: String) -> String {
        put(key, value)
    }

    func hostGet(_ key: String) -> String {
        get(key)
    }
}

/// 正则 AllInOne 规则（列表规则以 : 开头）
enum RegexRules {
    static func elements(_ text: String, _ regs: [String], index: Int = 0) -> [[String]] {
        guard index < regs.count, let re = try? NSRegularExpression(pattern: regs[index]) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return [] }
        if index + 1 == regs.count {
            return matches.map { m in
                (0..<m.numberOfRanges).map { g in
                    let r = m.range(at: g)
                    return r.location == NSNotFound ? "" : ns.substring(with: r)
                }
            }
        }
        let joined = matches.map { ns.substring(with: $0.range) }.joined()
        return elements(joined, regs, index: index + 1)
    }

    static func element(_ text: String, _ regs: [String], index: Int = 0) -> [String]? {
        guard index < regs.count, let re = try? NSRegularExpression(pattern: regs[index]) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first else { return nil }
        if index + 1 == regs.count {
            return (0..<first.numberOfRanges).map { g in
                let r = first.range(at: g)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
        let joined = matches.map { ns.substring(with: $0.range) }.joined()
        return element(joined, regs, index: index + 1)
    }
}

/// GSON 宽松模式那样解析 `{key:value}`：键和值都可以不带引号
enum LenientMap {
    static func parse(_ text: String) -> [String: String] {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] {
            return object.mapValues { RuleValue.string($0) }
        }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("{") { body.removeFirst() }
        if body.hasSuffix("}") { body.removeLast() }
        var out: [String: String] = [:]
        for pair in splitTopLevel(body, separator: ",") {
            guard let colon = firstTopLevel(pair, ":") else { continue }
            let key = unquote(String(pair[..<colon]))
            let value = unquote(String(pair[pair.index(after: colon)...]))
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private static func unquote(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let first = s.first, first == "\"" || first == "'", s.last == first {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func firstTopLevel(_ text: String, _ char: Character) -> String.Index? {
        var quote: Character?
        var depth = 0
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "[" || c == "(" || c == "{" {
                depth += 1
            } else if c == "]" || c == ")" || c == "}" {
                depth -= 1
            } else if c == char, depth == 0 {
                return i
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for c in text {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if "[({".contains(c) {
                depth += 1
            } else if "])}".contains(c) {
                depth -= 1
            } else if c == separator, depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(c)
        }
        parts.append(current)
        return parts
    }
}
