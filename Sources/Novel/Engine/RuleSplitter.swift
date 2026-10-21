import Foundation

/// 规则切分（对应阅读的 RuleAnalyzer）：
/// 按顶层的 && / || / %% / @ 切分，方括号、圆括号和引号里的内容不切
enum RuleSplitter {
    struct Result {
        var parts: [String]
        /// 实际使用的分隔符（第一个出现的那种），没切开时为空
        var type: String
    }

    static func split(_ rule: String, by separators: [String]) -> Result {
        let chars = Array(rule)
        var parts: [String] = []
        var type = ""
        var depth = 0
        var quote: Character?
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                current.append(c)
                if c == "\\", i + 1 < chars.count {
                    current.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == q { quote = nil }
                i += 1
                continue
            }
            if depth > 0, c == "'" || c == "\"" {
                quote = c
                current.append(c)
                i += 1
                continue
            }
            if c == "[" || c == "(" {
                depth += 1
            } else if (c == "]" || c == ")") && depth > 0 {
                depth -= 1
            } else if depth == 0 {
                let candidates = type.isEmpty ? separators : [type]
                if let sep = candidates.first(where: { matches(chars, at: i, $0) }) {
                    type = sep
                    parts.append(current)
                    current = ""
                    i += sep.count
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        if type.isEmpty { return Result(parts: [rule], type: "") }
        return Result(parts: parts, type: type)
    }

    private static func matches(_ chars: [Character], at index: Int, _ token: String) -> Bool {
        var j = index
        for t in token {
            guard j < chars.count, chars[j] == t else { return false }
            j += 1
        }
        return true
    }

    /// 替换所有内嵌的 {{...}}，大括号按代码平衡（JS 对象字面量、字符串里的括号都不影响）。
    /// 没有任何内嵌规则时返回 nil
    static func replaceDoubleBraces(_ text: String, _ transform: (String) throws -> String) rethrows -> String? {
        let chars = Array(text)
        var out = ""
        var found = false
        var i = 0
        while i < chars.count {
            if chars[i] == "{", i + 1 < chars.count, chars[i + 1] == "{",
               let end = closingDoubleBrace(chars, from: i + 2) {
                found = true
                out += try transform(String(chars[(i + 2)..<end]))
                i = end + 2
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return found ? out : nil
    }

    private static func closingDoubleBrace(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var quote: Character?
        var i = start
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\" { i += 2; continue }
                if c == q { quote = nil }
                i += 1
                continue
            }
            switch c {
            case "'", "\"", "`":
                quote = c
            case "{":
                depth += 1
            case "}":
                if depth == 0 {
                    if i + 1 < chars.count, chars[i + 1] == "}" { return i }
                    return nil
                }
                depth -= 1
            default:
                break
            }
            i += 1
        }
        return nil
    }

    /// JSONPath 里的内嵌规则 `{$.a}`：替换成取到的值。没有内嵌规则时返回 nil
    static func replaceInnerJSONRules(_ text: String, _ transform: (String) -> String) -> String? {
        let chars = Array(text)
        var out = ""
        var found = false
        var i = 0
        while i < chars.count {
            if chars[i] == "{", i + 2 < chars.count, chars[i + 1] == "$", chars[i + 2] == "." || chars[i + 2] == "[" {
                var depth = 0
                var j = i + 1
                var quote: Character?
                var end: Int?
                while j < chars.count {
                    let c = chars[j]
                    if let q = quote {
                        if c == q { quote = nil }
                    } else if c == "'" || c == "\"" {
                        quote = c
                    } else if c == "{" || c == "[" || c == "(" {
                        depth += 1
                    } else if c == "]" || c == ")" {
                        depth -= 1
                    } else if c == "}" {
                        if depth == 0 { end = j; break }
                        depth -= 1
                    }
                    j += 1
                }
                if let end {
                    found = true
                    out += transform(String(chars[(i + 1)..<end]))
                    i = end + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return found ? out : nil
    }

    /// 去掉开头的 @ 和空白（RuleAnalyzer.trim）
    static func trimLeading(_ rule: String) -> String {
        var s = Substring(rule)
        while let first = s.first, first == "@" || first.isWhitespace { s = s.dropFirst() }
        return String(s)
    }
}
