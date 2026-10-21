import Foundation

/// 阅读的 JSON 规则（Jayway JsonPath 语法），对应 AnalyzeByJSonPath
struct JSONPathRules {
    let root: Any

    init(content: Any) throws {
        if let text = content as? String {
            guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .json5Allowed]) else {
                throw BookEngineError.message("不是有效的 JSON")
            }
            root = json
        } else {
            root = content
        }
    }

    init(json: Any) {
        root = json
    }

    func string(_ rule: String) -> String? {
        guard !rule.isEmpty else { return nil }
        let split = RuleSplitter.split(rule, by: ["&&", "||"])
        if split.parts.count == 1 {
            if let inner = RuleSplitter.replaceInnerJSONRules(rule, { string($0) ?? "" }), !inner.isEmpty {
                return inner
            }
            guard let value = JSONPath.read(rule, in: root) else { return "" }
            if let list = value as? [Any] {
                return list.map { RuleValue.string($0) }.joined(separator: "\n")
            }
            return RuleValue.string(value)
        }
        var texts: [String] = []
        for part in split.parts {
            if let text = string(part), !text.isEmpty {
                texts.append(text)
                if split.type == "||" { break }
            }
        }
        return texts.joined(separator: "\n")
    }

    func stringList(_ rule: String) -> [String] {
        guard !rule.isEmpty else { return [] }
        let split = RuleSplitter.split(rule, by: ["&&", "||", "%%"])
        if split.parts.count == 1 {
            if let inner = RuleSplitter.replaceInnerJSONRules(rule, { string($0) ?? "" }), !inner.isEmpty {
                return [inner]
            }
            guard let value = JSONPath.read(rule, in: root) else { return [] }
            if let list = value as? [Any] { return list.map { RuleValue.string($0) } }
            if value is NSNull { return [] }
            return [RuleValue.string(value)]
        }
        var results: [[String]] = []
        for part in split.parts {
            let list = stringList(part)
            if !list.isEmpty {
                results.append(list)
                if split.type == "||" { break }
            }
        }
        return HTMLRules.combine(results, type: split.type)
    }

    func object(_ rule: String) -> Any? {
        JSONPath.read(rule, in: root)
    }

    func list(_ rule: String) -> [Any] {
        guard !rule.isEmpty else { return [] }
        let split = RuleSplitter.split(rule, by: ["&&", "||", "%%"])
        if split.parts.count == 1 {
            guard let value = JSONPath.read(rule, in: root) else { return [] }
            if let list = value as? [Any] { return list }
            if value is NSNull { return [] }
            return [value]
        }
        var results: [[Any]] = []
        for part in split.parts {
            let found = list(part)
            if !found.isEmpty {
                results.append(found)
                if split.type == "||" { break }
            }
        }
        return HTMLRules.combine(results, type: split.type)
    }
}

// MARK: - JSONPath 求值

enum JSONPath {
    indirect enum Segment {
        case child([String])
        case wildcard
        case recursive(Segment)
        case index([Int])
        case slice(Int?, Int?, Int?)
        case filter(Filter)
        case function(String)
    }

    indirect enum Filter {
        case path(Bool, [Segment])   // true = 从 @ 开始，false = 从 $ 开始
        case literal(Any)
        case regex(NSRegularExpression)
        case not(Filter)
        case and(Filter, Filter)
        case or(Filter, Filter)
        case compare(String, Filter, Filter)
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Segment]] = [:]

    static func normalized(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("$") || p.hasPrefix("@") { return p }
        if p.hasPrefix("[") { return "$" + p }
        return "$." + p
    }

    static func segments(_ path: String) -> [Segment]? {
        let key = normalized(path)
        if let cached = cacheLock.withLock({ cache[key] }) { return cached }
        var parser = PathParser(Array(key))
        guard let segments = try? parser.parsePath() else { return nil }
        cacheLock.withLock {
            if cache.count > 500 { cache.removeAll() }
            cache[key] = segments
        }
        return segments
    }

    static func isIndefinite(_ path: String) -> Bool {
        guard let segments = segments(path) else { return false }
        return segments.contains { !isDefinite($0) }
    }

    private static func isDefinite(_ segment: Segment) -> Bool {
        switch segment {
        case .child(let names): return names.count == 1
        case .index(let list): return list.count == 1
        case .function: return true
        default: return false
        }
    }

    /// 读取：确定路径返回单个值（找不到为 nil），不确定路径返回数组
    static func read(_ path: String, in root: Any) -> Any? {
        guard let segments = segments(path) else { return nil }
        let values = evaluate(segments, on: root, root: root)
        if segments.contains(where: { !isDefinite($0) }) { return values }
        return values.first
    }

    static func evaluate(_ segments: [Segment], on start: Any, root: Any) -> [Any] {
        var current: [Any] = [start]
        for segment in segments {
            var next: [Any] = []
            for value in current { next += apply(segment, to: value, root: root) }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    private static func apply(_ segment: Segment, to value: Any, root: Any) -> [Any] {
        switch segment {
        case .child(let names):
            if let dict = value as? [String: Any] {
                return names.compactMap { dict[$0] }
            }
            if let array = value as? [Any] {
                // 宽松处理：数组上取属性时对每个元素取
                return array.flatMap { item -> [Any] in
                    guard let dict = item as? [String: Any] else { return [] }
                    return names.compactMap { dict[$0] }
                }
            }
            return []
        case .wildcard:
            if let array = value as? [Any] { return array }
            if let dict = value as? NSDictionary { return dict.allValues }
            return []
        case .recursive(let inner):
            var out: [Any] = []
            for node in descendants(value) { out += apply(inner, to: node, root: root) }
            return out
        case .index(let indexes):
            guard let array = value as? [Any] else { return [] }
            return indexes.compactMap { raw in
                let i = raw < 0 ? array.count + raw : raw
                return i >= 0 && i < array.count ? array[i] : nil
            }
        case .slice(let startX, let endX, let stepX):
            guard let array = value as? [Any], !array.isEmpty else { return [] }
            let count = array.count
            var start = startX ?? 0
            var end = endX ?? count
            if start < 0 { start = max(count + start, 0) }
            if end < 0 { end = max(count + end, 0) }
            start = min(start, count)
            end = min(end, count)
            let step = max(stepX ?? 1, 1)
            guard start < end else { return [] }
            return stride(from: start, to: end, by: step).map { array[$0] }
        case .filter(let filter):
            if let array = value as? [Any] {
                return array.filter { truthy(evaluate(filter, item: $0, root: root)) }
            }
            if value is [String: Any] {
                return truthy(evaluate(filter, item: value, root: root)) ? [value] : []
            }
            return []
        case .function(let name):
            switch name {
            case "length", "size":
                if let array = value as? [Any] { return [array.count] }
                if let dict = value as? [String: Any] { return [dict.count] }
                if let s = value as? String { return [s.count] }
                return []
            case "keys":
                if let dict = value as? NSDictionary { return [dict.allKeys] }
                return []
            case "first":
                return (value as? [Any])?.first.map { [$0] } ?? []
            case "last":
                return (value as? [Any])?.last.map { [$0] } ?? []
            case "min", "max", "sum", "avg":
                guard let array = value as? [Any] else { return [] }
                let numbers = array.compactMap { RuleValue.double($0) }
                guard !numbers.isEmpty else { return [] }
                switch name {
                case "min": return [numbers.min()!]
                case "max": return [numbers.max()!]
                case "sum": return [numbers.reduce(0, +)]
                default: return [numbers.reduce(0, +) / Double(numbers.count)]
                }
            default:
                return []
            }
        }
    }

    private static func descendants(_ value: Any) -> [Any] {
        var out: [Any] = [value]
        if let array = value as? [Any] {
            for item in array { out += descendants(item) }
        } else if let dict = value as? NSDictionary {
            for item in dict.allValues { out += descendants(item) }
        }
        return out
    }

    // MARK: 过滤表达式

    /// 求值结果：路径返回 [Any]（可能为空表示不存在），其它返回单值
    private static func evaluate(_ filter: Filter, item: Any, root: Any) -> Any? {
        switch filter {
        case .literal(let value):
            return value
        case .regex(let re):
            return re
        case .path(let relative, let segments):
            let values = evaluate(segments, on: relative ? item : root, root: root)
            if segments.contains(where: { !isDefinite($0) }) { return values }
            return values.first ?? Missing()
        case .not(let inner):
            return !truthy(evaluate(inner, item: item, root: root))
        case .and(let a, let b):
            return truthy(evaluate(a, item: item, root: root)) && truthy(evaluate(b, item: item, root: root))
        case .or(let a, let b):
            return truthy(evaluate(a, item: item, root: root)) || truthy(evaluate(b, item: item, root: root))
        case .compare(let op, let a, let b):
            let left = evaluate(a, item: item, root: root)
            let right = evaluate(b, item: item, root: root)
            return compare(op, left, right)
        }
    }

    private struct Missing {}

    private static func truthy(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is Missing || value is NSNull { return false }
        if let b = value as? Bool { return b }
        if let list = value as? [Any] { return !list.isEmpty }
        return true
    }

    private static func compare(_ op: String, _ left: Any?, _ right: Any?) -> Bool {
        guard let left, let right, !(left is Missing), !(right is Missing) else {
            return op == "!=" || op == "nin"
        }
        switch op {
        case "=~":
            guard let re = right as? NSRegularExpression else { return false }
            let s = RuleValue.string(left)
            return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        case "in", "nin":
            let list = (right as? [Any]) ?? [right]
            let found = list.contains { equal(left, $0) }
            return op == "in" ? found : !found
        case "contains":
            if let list = left as? [Any] { return list.contains { equal($0, right) } }
            return RuleValue.string(left).contains(RuleValue.string(right))
        case "==": return equal(left, right)
        case "!=": return !equal(left, right)
        default:
            if let l = RuleValue.double(left), let r = RuleValue.double(right), !(left is String && right is String) {
                switch op {
                case "<": return l < r
                case "<=": return l <= r
                case ">": return l > r
                case ">=": return l >= r
                default: return false
                }
            }
            let l = RuleValue.string(left), r = RuleValue.string(right)
            switch op {
            case "<": return l < r
            case "<=": return l <= r
            case ">": return l > r
            case ">=": return l >= r
            default: return false
            }
        }
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull || b is NSNull { return a is NSNull && b is NSNull }
        let aIsString = a is String, bIsString = b is String
        if !aIsString || !bIsString, let l = RuleValue.double(a), let r = RuleValue.double(b) {
            return l == r
        }
        return RuleValue.string(a) == RuleValue.string(b)
    }

    // MARK: 解析

    struct PathParser {
        let chars: [Character]
        var pos = 0

        init(_ chars: [Character]) {
            self.chars = chars
        }

        mutating func parsePath() throws -> [Segment] {
            var segments: [Segment] = []
            if pos < chars.count, chars[pos] == "$" || chars[pos] == "@" { pos += 1 }
            while pos < chars.count {
                let c = chars[pos]
                if c == "." {
                    if pos + 1 < chars.count, chars[pos + 1] == "." {
                        pos += 2
                        if pos < chars.count, chars[pos] == "[" {
                            segments.append(.recursive(try parseBracket()))
                        } else if pos < chars.count, chars[pos] == "*" {
                            pos += 1
                            segments.append(.recursive(.wildcard))
                        } else {
                            segments.append(.recursive(.child([readName()])))
                        }
                        continue
                    }
                    pos += 1
                    if pos < chars.count, chars[pos] == "*" {
                        pos += 1
                        segments.append(.wildcard)
                        continue
                    }
                    let name = readName()
                    if pos + 1 < chars.count, chars[pos] == "(", chars[pos + 1] == ")" {
                        pos += 2
                        segments.append(.function(name))
                    } else if !name.isEmpty {
                        segments.append(.child([name]))
                    }
                } else if c == "[" {
                    segments.append(try parseBracket())
                } else if c == " " {
                    pos += 1
                } else {
                    // 过滤表达式里的路径遇到运算符时结束
                    break
                }
            }
            return segments
        }

        private mutating func readName() -> String {
            var name = ""
            while pos < chars.count {
                let c = chars[pos]
                if c == "." || c == "[" || c == "(" || c == ")" || c == " " || c == "=" || c == "!" || c == "<" || c == ">"
                    || c == "&" || c == "|" || c == "," || c == "]" {
                    break
                }
                name.append(c)
                pos += 1
            }
            return name
        }

        /// 读取到配对的 ]
        private mutating func bracketContent() throws -> String {
            pos += 1
            var depth = 0
            var quote: Character?
            var content = ""
            while pos < chars.count {
                let c = chars[pos]
                if let q = quote {
                    if c == "\\", pos + 1 < chars.count {
                        content.append(c)
                        content.append(chars[pos + 1])
                        pos += 2
                        continue
                    }
                    if c == q { quote = nil }
                } else if c == "'" || c == "\"" {
                    quote = c
                } else if c == "[" || c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                } else if c == "]" {
                    if depth == 0 {
                        pos += 1
                        return content
                    }
                    depth -= 1
                }
                content.append(c)
                pos += 1
            }
            throw BookEngineError.message("JSONPath 缺少 ]")
        }

        private mutating func parseBracket() throws -> Segment {
            let content = try bracketContent().trimmingCharacters(in: .whitespaces)
            if content == "*" { return .wildcard }
            if content.hasPrefix("?") {
                var inner = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
                if inner.hasPrefix("("), inner.hasSuffix(")") { inner = String(inner.dropFirst().dropLast()) }
                var parser = FilterParser(Array(inner))
                return .filter(try parser.parse())
            }
            if content.hasPrefix("(") {
                // (@.length-1) 之类的脚本索引
                let script = content.replacingOccurrences(of: " ", with: "")
                if script.hasPrefix("(@.length-"), let n = Int(script.dropFirst(10).dropLast()) {
                    return .index([-n])
                }
                throw BookEngineError.message("不支持的 JSONPath 脚本 \(content)")
            }
            if content.first == "'" || content.first == "\"" {
                let names = splitTopLevel(content).map { item -> String in
                    var s = item.trimmingCharacters(in: .whitespaces)
                    if s.count >= 2, let f = s.first, f == "'" || f == "\"" { s = String(s.dropFirst().dropLast()) }
                    return s
                }
                return .child(names)
            }
            if content.contains(":") {
                let parts = content.split(separator: ":", omittingEmptySubsequences: false).map {
                    Int($0.trimmingCharacters(in: .whitespaces))
                }
                return .slice(parts.first ?? nil, parts.count > 1 ? parts[1] : nil, parts.count > 2 ? parts[2] : nil)
            }
            let indexes = content.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if indexes.isEmpty { return .child([content]) }
            return .index(indexes)
        }

        private func splitTopLevel(_ text: String) -> [String] {
            var out: [String] = []
            var current = ""
            var quote: Character?
            for c in text {
                if let q = quote {
                    if c == q { quote = nil }
                    current.append(c)
                } else if c == "'" || c == "\"" {
                    quote = c
                    current.append(c)
                } else if c == "," {
                    out.append(current)
                    current = ""
                } else {
                    current.append(c)
                }
            }
            out.append(current)
            return out
        }
    }

    struct FilterParser {
        let chars: [Character]
        var pos = 0

        init(_ chars: [Character]) {
            self.chars = chars
        }

        mutating func parse() throws -> Filter {
            try parseOr()
        }

        private mutating func skip() {
            while pos < chars.count, chars[pos] == " " { pos += 1 }
        }

        private mutating func take(_ token: String) -> Bool {
            skip()
            let t = Array(token)
            guard pos + t.count <= chars.count, Array(chars[pos..<(pos + t.count)]) == t else { return false }
            pos += t.count
            return true
        }

        private mutating func parseOr() throws -> Filter {
            var lhs = try parseAnd()
            while take("||") { lhs = .or(lhs, try parseAnd()) }
            return lhs
        }

        private mutating func parseAnd() throws -> Filter {
            var lhs = try parseUnary()
            while take("&&") { lhs = .and(lhs, try parseUnary()) }
            return lhs
        }

        private mutating func parseUnary() throws -> Filter {
            skip()
            if pos < chars.count, chars[pos] == "!", !(pos + 1 < chars.count && chars[pos + 1] == "=") {
                pos += 1
                return .not(try parseUnary())
            }
            return try parseComparison()
        }

        private mutating func parseComparison() throws -> Filter {
            let lhs = try parseOperand()
            skip()
            for op in ["==", "!=", "<=", ">=", "=~", "<", ">", " nin ", " in ", " contains "] {
                let trimmed = op.trimmingCharacters(in: .whitespaces)
                let save = pos
                if op.hasPrefix(" ") {
                    // 关键字运算符
                    if take(trimmed), pos < chars.count, chars[pos] == " " {
                        return .compare(trimmed, lhs, try parseOperand())
                    }
                    pos = save
                } else if take(op) {
                    return .compare(op, lhs, try parseOperand())
                }
            }
            return lhs
        }

        private mutating func parseOperand() throws -> Filter {
            skip()
            guard pos < chars.count else { throw BookEngineError.message("JSONPath 过滤表达式不完整") }
            let c = chars[pos]
            if c == "(" {
                pos += 1
                let inner = try parseOr()
                skip()
                if pos < chars.count, chars[pos] == ")" { pos += 1 }
                return inner
            }
            if c == "@" || c == "$" {
                let start = pos
                var parser = PathParser(Array(chars[start...]))
                let segments = try parser.parsePath()
                pos = start + parser.pos
                return .path(c == "@", segments)
            }
            if c == "'" || c == "\"" {
                pos += 1
                var s = ""
                while pos < chars.count, chars[pos] != c {
                    if chars[pos] == "\\", pos + 1 < chars.count { pos += 1 }
                    s.append(chars[pos])
                    pos += 1
                }
                pos += 1
                return .literal(s)
            }
            if c == "/" {
                pos += 1
                var pattern = ""
                while pos < chars.count, chars[pos] != "/" {
                    if chars[pos] == "\\", pos + 1 < chars.count {
                        pattern.append(chars[pos])
                        pos += 1
                    }
                    pattern.append(chars[pos])
                    pos += 1
                }
                pos += 1
                var options: NSRegularExpression.Options = []
                while pos < chars.count, chars[pos].isLetter {
                    if chars[pos] == "i" { options.insert(.caseInsensitive) }
                    pos += 1
                }
                guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
                    throw BookEngineError.message("JSONPath 正则无效 \(pattern)")
                }
                return .regex(re)
            }
            if c == "[" {
                pos += 1
                var items: [Any] = []
                while pos < chars.count, chars[pos] != "]" {
                    skip()
                    if chars[pos] == "," { pos += 1; continue }
                    if case .literal(let v) = try parseOperand() { items.append(v) }
                    skip()
                }
                pos += 1
                return .literal(items)
            }
            var word = ""
            while pos < chars.count, !" )=!<>&|,]".contains(chars[pos]) {
                word.append(chars[pos])
                pos += 1
            }
            switch word {
            case "true": return .literal(true)
            case "false": return .literal(false)
            case "null": return .literal(NSNull())
            default:
                if let n = Double(word) { return .literal(n) }
                return .literal(word)
            }
        }
    }
}
