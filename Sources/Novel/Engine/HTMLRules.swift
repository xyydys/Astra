import Foundation
import SwiftSoup

/// 阅读的默认规则（JSoup 语法）和 @CSS: 规则，对应 AnalyzeByJSoup
struct HTMLRules {
    let root: Element

    init(root: Element) {
        self.root = root
    }

    init(content: Any) throws {
        root = try HTMLRules.parse(content)
    }

    static func parse(_ content: Any) throws -> Element {
        if let element = content as? Element { return element }
        if let elements = content as? [Element] {
            if elements.count == 1 { return elements[0] }
            let html = elements.compactMap { try? $0.outerHtml() }.joined(separator: "\n")
            return try SwiftSoup.parse(html)
        }
        return try SwiftSoup.parse(RuleValue.string(content))
    }

    // MARK: 取元素

    func elements(_ rule: String) -> [Element] {
        HTMLRules.elements(in: root, rule)
    }

    static func elements(in temp: Element, _ rule: String) -> [Element] {
        guard !rule.isEmpty else { return [] }
        var isCSS = false
        var elementsRule = rule
        if rule.lowercased().hasPrefix("@css:") {
            isCSS = true
            elementsRule = String(rule.dropFirst(5)).legadoTrimmed
        }
        let split = RuleSplitter.split(elementsRule, by: ["&&", "||", "%%"])
        var lists: [[Element]] = []
        for part in split.parts {
            var found: [Element] = []
            if isCSS {
                found = (try? temp.select(part).array()) ?? []
            } else {
                let steps = RuleSplitter.split(RuleSplitter.trimLeading(part), by: ["@"]).parts
                if steps.count > 1 {
                    var current = [temp]
                    for step in steps {
                        var next: [Element] = []
                        for element in current {
                            next += elements(in: element, step)
                        }
                        current = next
                    }
                    found = current
                } else {
                    found = single(temp, part)
                }
            }
            lists.append(found)
            if !found.isEmpty, split.type == "||" { break }
        }
        return combine(lists, type: split.type)
    }

    static func combine<T>(_ lists: [[T]], type: String) -> [T] {
        guard !lists.isEmpty else { return [] }
        if type == "%%" {
            var out: [T] = []
            for i in 0..<lists[0].count {
                for list in lists where i < list.count { out.append(list[i]) }
            }
            return out
        }
        return lists.flatMap { $0 }
    }

    // MARK: 取文本

    func string(_ rule: String) -> String? {
        guard !rule.isEmpty else { return nil }
        let list = stringList(rule)
        if list.isEmpty { return nil }
        return list.count == 1 ? list[0] : list.joined(separator: "\n")
    }

    func stringList(_ rule: String) -> [String] {
        guard !rule.isEmpty else { return [] }
        var isCSS = false
        var elementsRule = rule
        if rule.lowercased().hasPrefix("@css:") {
            isCSS = true
            elementsRule = String(rule.dropFirst(5)).legadoTrimmed
        }
        if elementsRule.isEmpty {
            return [root.data()]
        }
        let split = RuleSplitter.split(elementsRule, by: ["&&", "||", "%%"])
        var results: [[String]] = []
        for part in split.parts {
            var temp: [String] = []
            if isCSS {
                if let at = part.lastIndex(of: "@") {
                    let selector = String(part[..<at])
                    let last = String(part[part.index(after: at)...])
                    let found = (try? root.select(selector).array()) ?? []
                    temp = HTMLRules.lastResult(found, last)
                } else {
                    temp = HTMLRules.lastResult((try? root.select(part).array()) ?? [], "text")
                }
            } else {
                temp = resultList(part)
            }
            if !temp.isEmpty {
                results.append(temp)
                if split.type == "||" { break }
            }
        }
        return HTMLRules.combine(results, type: split.type)
    }

    private func resultList(_ rule: String) -> [String] {
        guard !rule.isEmpty else { return [] }
        let steps = RuleSplitter.split(RuleSplitter.trimLeading(rule), by: ["@"]).parts
        var current = [root]
        for step in steps.dropLast() {
            var next: [Element] = []
            for element in current { next += HTMLRules.single(element, step) }
            current = next
        }
        if current.isEmpty { return [] }
        return HTMLRules.lastResult(current, steps.last ?? "")
    }

    static func lastResult(_ elements: [Element], _ last: String) -> [String] {
        var out: [String] = []
        switch last {
        case "text":
            for e in elements {
                if let t = try? e.text(), !t.isEmpty { out.append(t) }
            }
        case "textNodes":
            for e in elements {
                let lines = e.textNodes().map { $0.text().legadoTrimmed }.filter { !$0.isEmpty }
                if !lines.isEmpty { out.append(lines.joined(separator: "\n")) }
            }
        case "ownText":
            for e in elements {
                let t = e.ownText()
                if !t.isEmpty { out.append(t) }
            }
        case "html":
            for e in elements {
                if let scripts = try? e.select("script") { _ = try? scripts.remove() }
                if let styles = try? e.select("style") { _ = try? styles.remove() }
            }
            let html = elements.compactMap { try? $0.outerHtml() }.joined(separator: "\n")
            if !html.isEmpty { out.append(html) }
        case "all":
            out.append(elements.compactMap { try? $0.outerHtml() }.joined(separator: "\n"))
        default:
            for e in elements {
                guard let value = try? e.attr(last), !value.trimmingCharacters(in: .whitespaces).isEmpty,
                      !out.contains(value) else { continue }
                out.append(value)
            }
        }
        return out
    }

    // MARK: 单段规则：class.xx.0 / tag.a!0 / [1:3] / CSS

    static func single(_ temp: Element, _ rule: String) -> [Element] {
        let index = IndexRule(rule)
        var elements: [Element]
        if index.beforeRule.isEmpty {
            elements = temp.children().array()
        } else {
            let rules = index.beforeRule.components(separatedBy: ".")
            let arg = rules.count > 1 ? rules[1] : ""
            switch rules[0] {
            case "children":
                elements = temp.children().array()
            case "class":
                elements = (try? temp.getElementsByClass(arg).array()) ?? []
            case "tag":
                elements = (try? temp.getElementsByTag(arg).array()) ?? []
            case "id":
                elements = ((try? temp.select("[id]").array()) ?? []).filter { $0.id() == arg }
            case "text":
                elements = (try? temp.getElementsContainingOwnText(arg).array()) ?? []
            default:
                elements = (try? temp.select(index.beforeRule).array()) ?? []
            }
        }
        return index.apply(elements)
    }

    /// 索引部分的解析（ElementsSingle.findIndexSet 的移植）
    struct IndexRule {
        enum Item {
            case single(Int)
            case range(Int?, Int?, Int)
        }

        var split: Character = "."
        var beforeRule = ""
        var indexDefault: [Int] = []
        var indexes: [Item] = []

        init(_ rule: String) {
            let rus = Array(rule.legadoTrimmed)
            guard !rus.isEmpty else {
                split = " "
                beforeRule = ""
                return
            }
            var len = rus.count
            var number = ""
            var minus = false
            var curList: [Int?] = []

            func current() -> Int? {
                guard !number.isEmpty, let n = Int(number) else { return nil }
                return minus ? -n : n
            }

            if rus.last == "]" {
                len -= 1
                while len > 0 {
                    len -= 1
                    var rl = rus[len]
                    if rl == " " { continue }
                    if rl.isASCII, rl.isNumber {
                        number = String(rl) + number
                    } else if rl == "-" {
                        minus = true
                    } else {
                        let cur = current()
                        if rl == ":" {
                            curList.append(cur)
                        } else {
                            if curList.isEmpty {
                                guard let cur else { break }
                                indexes.append(.single(cur))
                            } else {
                                let step = curList.count == 2 ? (curList.first ?? 1) ?? 1 : 1
                                indexes.append(.range(cur, curList.last ?? nil, step))
                                curList.removeAll()
                            }
                            if rl == "!" {
                                split = "!"
                                repeat {
                                    len -= 1
                                    rl = len >= 0 ? rus[len] : " "
                                } while len > 0 && rl == " "
                            }
                            if rl == "[" {
                                beforeRule = String(rus[0..<max(len, 0)])
                                return
                            }
                            if rl != "," { break }
                        }
                        number = ""
                        minus = false
                    }
                }
            } else {
                while len > 0 {
                    len -= 1
                    let rl = rus[len]
                    if rl == " " { continue }
                    if rl.isASCII, rl.isNumber {
                        number = String(rl) + number
                    } else if rl == "-" {
                        minus = true
                    } else {
                        if rl == "!" || rl == "." || rl == ":" {
                            guard let cur = current() else { break }
                            indexDefault.append(cur)
                            if rl != ":" {
                                split = rl
                                beforeRule = String(rus[0..<len])
                                return
                            }
                        } else {
                            break
                        }
                        number = ""
                        minus = false
                    }
                }
            }
            split = " "
            indexDefault = []
            indexes = []
            beforeRule = String(rus)
        }

        func apply(_ elements: [Element]) -> [Element] {
            guard split == "." || split == "!" else { return elements }
            let count = elements.count
            var picked: [Int] = []
            var seen = Set<Int>()
            func add(_ i: Int) {
                if !seen.contains(i) { seen.insert(i); picked.append(i) }
            }
            if indexes.isEmpty {
                for raw in indexDefault.reversed() {
                    if raw >= 0 && raw < count { add(raw) } else if raw < 0 && count >= -raw { add(raw + count) }
                }
            } else {
                for item in indexes.reversed() {
                    switch item {
                    case .single(let raw):
                        if raw >= 0 && raw < count { add(raw) } else if raw < 0 && count >= -raw { add(raw + count) }
                    case .range(let startX, let endX, let stepX):
                        guard count > 0 else { continue }
                        var start = startX ?? 0
                        if start < 0 { start += count }
                        var end = endX ?? (count - 1)
                        if end < 0 { end += count }
                        if (start < 0 && end < 0) || (start >= count && end >= count) { continue }
                        start = min(max(start, 0), count - 1)
                        end = min(max(end, 0), count - 1)
                        if start == end || stepX >= count {
                            add(start)
                            continue
                        }
                        let step = stepX > 0 ? stepX : (-stepX < count ? stepX + count : 1)
                        if end > start {
                            for i in stride(from: start, through: end, by: max(step, 1)) { add(i) }
                        } else {
                            for i in stride(from: start, through: end, by: -max(step, 1)) { add(i) }
                        }
                    }
                }
            }
            if split == "!" {
                return elements.enumerated().filter { !seen.contains($0.offset) }.map(\.element)
            }
            return picked.map { elements[$0] }
        }
    }
}
