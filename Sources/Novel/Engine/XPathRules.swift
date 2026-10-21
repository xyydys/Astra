import Foundation
import SwiftSoup

/// 在 SwiftSoup 的 DOM 上执行 XPath（对应阅读用的 JsoupXpath），
/// 结果里的元素可以直接交给后面的 JSoup 规则继续解析。
/// 支持常用的 XPath 1.0：轴（child、descendant、parent、ancestor、following-sibling、preceding-sibling、self、attribute）、
/// 谓词、比较运算、常用函数，以及 JsoupXpath 的 text() / allText() / html() / outerHtml()。
struct XPathRules {
    let root: Element

    init(root: Element) {
        self.root = root
    }

    init(content: Any) throws {
        root = try HTMLRules.parse(content)
    }

    /// 选出的节点：元素或字符串（文本、属性值）
    enum Item {
        case element(Element)
        case text(String)

        var string: String {
            switch self {
            case .element(let e): return (try? e.outerHtml()) ?? ""
            case .text(let s): return s
            }
        }
    }

    func items(_ rule: String) -> [Item] {
        let split = RuleSplitter.split(rule, by: ["&&", "||", "%%"])
        var lists: [[Item]] = []
        for part in split.parts {
            let found = evaluate(part.legadoTrimmed)
            lists.append(found)
            if !found.isEmpty, split.type == "||" { break }
        }
        return HTMLRules.combine(lists, type: split.type)
    }

    func elements(_ rule: String) -> [Any] {
        items(rule).map { item -> Any in
            switch item {
            case .element(let e): return e
            case .text(let s): return s
            }
        }
    }

    func stringList(_ rule: String) -> [String] {
        items(rule).map(\.string)
    }

    func string(_ rule: String) -> String? {
        let list = items(rule)
        if list.isEmpty { return nil }
        return list.map(\.string).joined(separator: "\n")
    }

    private func evaluate(_ expression: String) -> [Item] {
        guard !expression.isEmpty else { return [] }
        do {
            var parser = XPathParser(expression)
            let expr = try parser.parse()
            let context = XPathContext(root: root)
            let value = try context.eval(expr, node: .element(root), position: 1, size: 1)
            switch value {
            case .nodes(let nodes):
                return nodes.compactMap { node -> Item? in
                    switch node {
                    case .element(let e): return .element(e)
                    case .text(let s), .attribute(_, let s): return .text(s)
                    }
                }
            case .string(let s): return [.text(s)]
            case .number(let n): return [.text(XPathContext.format(n))]
            case .bool(let b): return [.text(b ? "true" : "false")]
            }
        } catch {
            EngineHooks.debug("XPath 出错 \(expression)：\(error)")
            return []
        }
    }
}

// MARK: - 语法树

indirect enum XPathExpr {
    case path(absolute: Bool, steps: [XPathStep], start: XPathExpr?)
    case binary(String, XPathExpr, XPathExpr)
    case negate(XPathExpr)
    case union(XPathExpr, XPathExpr)
    case literal(String)
    case number(Double)
    case function(String, [XPathExpr])
    case filter(XPathExpr, [XPathExpr])
}

struct XPathStep {
    enum Axis: String {
        case child, descendant, descendantOrSelf = "descendant-or-self", parent, ancestor
        case ancestorOrSelf = "ancestor-or-self", followingSibling = "following-sibling"
        case precedingSibling = "preceding-sibling", following, preceding, attribute, selfAxis = "self"
    }

    enum Test {
        case name(String)
        case any
        case text
        case node
        /// JsoupXpath 的扩展：allText()、html()、outerHtml()、ownText()
        case function(String)
    }

    var axis: Axis
    var test: Test
    var predicates: [XPathExpr]
}

struct XPathError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - 解析

struct XPathParser {
    private let chars: [Character]
    private var pos = 0

    init(_ text: String) {
        chars = Array(text)
    }

    mutating func parse() throws -> XPathExpr {
        let expr = try parseOr()
        skipSpace()
        if pos < chars.count { throw XPathError(description: "多余的内容：\(String(chars[pos...]))") }
        return expr
    }

    private mutating func skipSpace() {
        while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
    }

    private func peek(_ offset: Int = 0) -> Character? {
        pos + offset < chars.count ? chars[pos + offset] : nil
    }

    private mutating func consume(_ token: String) -> Bool {
        skipSpace()
        let t = Array(token)
        guard pos + t.count <= chars.count, Array(chars[pos..<(pos + t.count)]) == t else { return false }
        // 关键字后面不能紧跟名字字符
        if let last = t.last, last.isLetter, pos + t.count < chars.count, isNameChar(chars[pos + t.count]) {
            return false
        }
        pos += t.count
        return true
    }

    private func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." || c == ":"
    }

    private mutating func parseOr() throws -> XPathExpr {
        var lhs = try parseAnd()
        while consume("or") { lhs = .binary("or", lhs, try parseAnd()) }
        return lhs
    }

    private mutating func parseAnd() throws -> XPathExpr {
        var lhs = try parseEquality()
        while consume("and") { lhs = .binary("and", lhs, try parseEquality()) }
        return lhs
    }

    private mutating func parseEquality() throws -> XPathExpr {
        var lhs = try parseRelational()
        while true {
            if consume("!=") { lhs = .binary("!=", lhs, try parseRelational()) }
            else if consume("=") { lhs = .binary("=", lhs, try parseRelational()) }
            else { return lhs }
        }
    }

    private mutating func parseRelational() throws -> XPathExpr {
        var lhs = try parseAdditive()
        while true {
            if consume("<=") { lhs = .binary("<=", lhs, try parseAdditive()) }
            else if consume(">=") { lhs = .binary(">=", lhs, try parseAdditive()) }
            else if consume("<") { lhs = .binary("<", lhs, try parseAdditive()) }
            else if consume(">") { lhs = .binary(">", lhs, try parseAdditive()) }
            else { return lhs }
        }
    }

    private mutating func parseAdditive() throws -> XPathExpr {
        var lhs = try parseMultiplicative()
        while true {
            if consume("+") { lhs = .binary("+", lhs, try parseMultiplicative()) }
            else if peekMinusOperator(), consume("-") { lhs = .binary("-", lhs, try parseMultiplicative()) }
            else { return lhs }
        }
    }

    private mutating func peekMinusOperator() -> Bool {
        skipSpace()
        return peek() == "-"
    }

    private mutating func parseMultiplicative() throws -> XPathExpr {
        var lhs = try parseUnary()
        while true {
            skipSpace()
            if peek() == "*" { pos += 1; lhs = .binary("*", lhs, try parseUnary()) }
            else if consume("div") { lhs = .binary("div", lhs, try parseUnary()) }
            else if consume("mod") { lhs = .binary("mod", lhs, try parseUnary()) }
            else { return lhs }
        }
    }

    private mutating func parseUnary() throws -> XPathExpr {
        skipSpace()
        if peek() == "-" {
            pos += 1
            return .negate(try parseUnary())
        }
        return try parseUnion()
    }

    private mutating func parseUnion() throws -> XPathExpr {
        var lhs = try parsePath()
        while consume("|") { lhs = .union(lhs, try parsePath()) }
        return lhs
    }

    private mutating func parsePath() throws -> XPathExpr {
        skipSpace()
        guard let c = peek() else { throw XPathError(description: "表达式不完整") }
        if c == "/" {
            pos += 1
            if peek() == "/" {
                pos += 1
                var steps = [XPathStep(axis: .descendantOrSelf, test: .node, predicates: [])]
                steps += try parseRelativeSteps()
                return .path(absolute: true, steps: steps, start: nil)
            }
            skipSpace()
            if let n = peek(), n.isLetter || n == "*" || n == "@" || n == "." || n == "_" {
                return .path(absolute: true, steps: try parseRelativeSteps(), start: nil)
            }
            return .path(absolute: true, steps: [], start: nil)
        }
        if c == "\"" || c == "'" || c.isNumber || c == "(" || (c == "." && (peek(1)?.isNumber ?? false)) || isFunctionCallAhead() {
            var primary = try parsePrimary()
            var predicates: [XPathExpr] = []
            while true {
                skipSpace()
                guard peek() == "[" else { break }
                predicates.append(try parsePredicate())
            }
            if !predicates.isEmpty { primary = .filter(primary, predicates) }
            skipSpace()
            if peek() == "/" {
                pos += 1
                var steps: [XPathStep] = []
                if peek() == "/" {
                    pos += 1
                    steps.append(XPathStep(axis: .descendantOrSelf, test: .node, predicates: []))
                }
                steps += try parseRelativeSteps()
                return .path(absolute: false, steps: steps, start: primary)
            }
            return primary
        }
        return .path(absolute: false, steps: try parseRelativeSteps(), start: nil)
    }

    /// 名字后面跟着 ( 而且不是节点测试（text()、node()）也不是轴，就是函数调用
    private func isFunctionCallAhead() -> Bool {
        var i = pos
        var name = ""
        while i < chars.count, isNameChar(chars[i]) { name.append(chars[i]); i += 1 }
        guard !name.isEmpty else { return false }
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count, chars[i] == "(" else { return false }
        return !["text", "node", "comment", "processing-instruction", "allText", "html", "outerHtml", "ownText"].contains(name)
    }

    private mutating func parseRelativeSteps() throws -> [XPathStep] {
        var steps = [try parseStep()]
        while true {
            skipSpace()
            guard peek() == "/" else { break }
            pos += 1
            if peek() == "/" {
                pos += 1
                steps.append(XPathStep(axis: .descendantOrSelf, test: .node, predicates: []))
            }
            steps.append(try parseStep())
        }
        return steps
    }

    private mutating func parseStep() throws -> XPathStep {
        skipSpace()
        if peek() == ".", peek(1) == "." {
            pos += 2
            return XPathStep(axis: .parent, test: .node, predicates: [])
        }
        if peek() == "." {
            pos += 1
            return XPathStep(axis: .selfAxis, test: .node, predicates: [])
        }
        var axis = XPathStep.Axis.child
        if peek() == "@" {
            pos += 1
            axis = .attribute
        } else {
            let save = pos
            let name = readName()
            skipSpace()
            if !name.isEmpty, peek() == ":", peek(1) == ":", let a = XPathStep.Axis(rawValue: name) {
                pos += 2
                axis = a
            } else {
                pos = save
            }
        }
        skipSpace()
        let test: XPathStep.Test
        if peek() == "*" {
            pos += 1
            test = .any
        } else {
            let name = readName()
            guard !name.isEmpty else { throw XPathError(description: "缺少节点名") }
            skipSpace()
            if peek() == "(" {
                pos += 1
                skipSpace()
                guard peek() == ")" else { throw XPathError(description: "\(name)() 不支持参数") }
                pos += 1
                switch name {
                case "text": test = .text
                case "node": test = .node
                default: test = .function(name)
                }
            } else {
                test = .name(name.lowercased())
            }
        }
        var predicates: [XPathExpr] = []
        while true {
            skipSpace()
            guard peek() == "[" else { break }
            predicates.append(try parsePredicate())
        }
        return XPathStep(axis: axis, test: test, predicates: predicates)
    }

    private mutating func parsePredicate() throws -> XPathExpr {
        pos += 1
        let expr = try parseOr()
        skipSpace()
        guard peek() == "]" else { throw XPathError(description: "缺少 ]") }
        pos += 1
        return expr
    }

    private mutating func readName() -> String {
        var name = ""
        while pos < chars.count, isNameChar(chars[pos]) {
            // 名字里的 :: 是轴分隔符
            if chars[pos] == ":", pos + 1 < chars.count, chars[pos + 1] == ":" { break }
            name.append(chars[pos])
            pos += 1
        }
        return name
    }

    private mutating func parsePrimary() throws -> XPathExpr {
        skipSpace()
        guard let c = peek() else { throw XPathError(description: "表达式不完整") }
        if c == "\"" || c == "'" {
            pos += 1
            var s = ""
            while pos < chars.count, chars[pos] != c { s.append(chars[pos]); pos += 1 }
            pos += 1
            return .literal(s)
        }
        if c.isNumber || c == "." {
            var s = ""
            while pos < chars.count, chars[pos].isNumber || chars[pos] == "." { s.append(chars[pos]); pos += 1 }
            return .number(Double(s) ?? .nan)
        }
        if c == "(" {
            pos += 1
            let expr = try parseOr()
            skipSpace()
            guard peek() == ")" else { throw XPathError(description: "缺少 )") }
            pos += 1
            return expr
        }
        let name = readName()
        skipSpace()
        guard peek() == "(" else { throw XPathError(description: "无法解析 \(name)") }
        pos += 1
        var args: [XPathExpr] = []
        skipSpace()
        if peek() == ")" {
            pos += 1
        } else {
            while true {
                args.append(try parseOr())
                skipSpace()
                if peek() == "," { pos += 1; continue }
                guard peek() == ")" else { throw XPathError(description: "函数参数缺少 )") }
                pos += 1
                break
            }
        }
        return .function(name, args)
    }
}

// MARK: - 求值

enum XPathNode {
    case element(Element)
    case text(String)
    case attribute(Element, String)

    var element: Element? {
        if case .element(let e) = self { return e }
        return nil
    }

    var stringValue: String {
        switch self {
        case .element(let e): return (try? e.text()) ?? ""
        case .text(let s): return s
        case .attribute(_, let v): return v
        }
    }
}

enum XPathValue {
    case nodes([XPathNode])
    case string(String)
    case number(Double)
    case bool(Bool)
}

struct XPathContext {
    let root: Element

    static func format(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }

    func eval(_ expr: XPathExpr, node: XPathNode, position: Int, size: Int) throws -> XPathValue {
        switch expr {
        case .literal(let s):
            return .string(s)
        case .number(let n):
            return .number(n)
        case .negate(let e):
            return .number(-number(try eval(e, node: node, position: position, size: size)))
        case .union(let a, let b):
            let left = nodes(try eval(a, node: node, position: position, size: size))
            let right = nodes(try eval(b, node: node, position: position, size: size))
            return .nodes(unique(left + right))
        case .binary(let op, let a, let b):
            return try binary(op, a, b, node: node, position: position, size: size)
        case .function(let name, let args):
            return try function(name, args, node: node, position: position, size: size)
        case .filter(let primary, let predicates):
            var list = nodes(try eval(primary, node: node, position: position, size: size))
            for predicate in predicates { list = try filter(list, predicate) }
            return .nodes(list)
        case .path(let absolute, let steps, let start):
            var current: [XPathNode]
            if let start {
                current = nodes(try eval(start, node: node, position: position, size: size))
            } else if absolute {
                current = [.element(root)]
            } else {
                current = [node]
            }
            for step in steps {
                if case .function(let name) = step.test {
                    // JsoupXpath 扩展函数作为最后一步，返回字符串
                    current = current.compactMap { n -> XPathNode? in
                        guard let e = n.element else { return nil }
                        switch name {
                        case "allText": return .text((try? e.text()) ?? "")
                        case "html": return .text((try? e.html()) ?? "")
                        case "outerHtml": return .text((try? e.outerHtml()) ?? "")
                        case "ownText": return .text(e.ownText())
                        default: return nil
                        }
                    }
                    continue
                }
                var next: [XPathNode] = []
                for n in current {
                    var selected = select(step, from: n)
                    for predicate in step.predicates { selected = try filter(selected, predicate) }
                    next += selected
                }
                current = unique(next)
            }
            return .nodes(current)
        }
    }

    private func filter(_ list: [XPathNode], _ predicate: XPathExpr) throws -> [XPathNode] {
        var out: [XPathNode] = []
        let size = list.count
        for (index, n) in list.enumerated() {
            let value = try eval(predicate, node: n, position: index + 1, size: size)
            if case .number(let num) = value {
                let target = num < 0 ? Double(size) + num + 1 : num
                if Double(index + 1) == target { out.append(n) }
            } else if boolean(value) {
                out.append(n)
            }
        }
        return out
    }

    private func select(_ step: XPathStep, from node: XPathNode) -> [XPathNode] {
        guard let e = node.element else {
            if step.axis == .selfAxis { return matches(step.test, node) ? [node] : [] }
            return []
        }
        switch step.axis {
        case .attribute:
            guard let attributes = e.getAttributes() else { return [] }
            return attributes.asList().compactMap { attr -> XPathNode? in
                switch step.test {
                case .any, .node: return .attribute(e, attr.getValue())
                case .name(let name): return attr.getKey().lowercased() == name ? .attribute(e, attr.getValue()) : nil
                default: return nil
                }
            }
        case .child:
            if case .text = step.test {
                // JsoupXpath：text() 取元素自身的文本
                let own = e.ownText()
                return own.isEmpty ? [] : [.text(own)]
            }
            return e.children().array().map { XPathNode.element($0) }.filter { matches(step.test, $0) }
        case .selfAxis:
            return matches(step.test, node) ? [node] : []
        case .descendant, .descendantOrSelf:
            if case .text = step.test {
                var out: [XPathNode] = []
                let base = step.axis == .descendantOrSelf ? [e] : []
                for item in base + descendants(e) {
                    let own = item.ownText()
                    if !own.isEmpty { out.append(.text(own)) }
                }
                return out
            }
            var list = descendants(e).map { XPathNode.element($0) }
            if step.axis == .descendantOrSelf { list.insert(node, at: 0) }
            return list.filter { matches(step.test, $0) }
        case .parent:
            guard e !== root, let parent = e.parent() else { return [] }
            let p = XPathNode.element(parent)
            return matches(step.test, p) ? [p] : []
        case .ancestor, .ancestorOrSelf:
            var out: [XPathNode] = step.axis == .ancestorOrSelf ? [node] : []
            var current = e
            while current !== root, let parent = current.parent() {
                out.append(.element(parent))
                current = parent
            }
            return out.filter { matches(step.test, $0) }
        case .followingSibling, .precedingSibling:
            guard e !== root, let parent = e.parent() else { return [] }
            let siblings = parent.children().array()
            guard let index = siblings.firstIndex(where: { $0 === e }) else { return [] }
            let slice = step.axis == .followingSibling
                ? Array(siblings[(index + 1)...])
                : Array(siblings[..<index].reversed())
            return slice.map { XPathNode.element($0) }.filter { matches(step.test, $0) }
        case .following, .preceding:
            let all = descendants(root)
            guard let index = all.firstIndex(where: { $0 === e }) else { return [] }
            if step.axis == .following {
                let inside = Set(descendants(e).map { ObjectIdentifier($0) })
                return all[(index + 1)...].filter { !inside.contains(ObjectIdentifier($0)) }
                    .map { XPathNode.element($0) }.filter { matches(step.test, $0) }
            }
            var ancestors = Set<ObjectIdentifier>()
            var cur = e
            while let p = cur.parent() { ancestors.insert(ObjectIdentifier(p)); cur = p }
            return all[..<index].reversed().filter { !ancestors.contains(ObjectIdentifier($0)) }
                .map { XPathNode.element($0) }.filter { matches(step.test, $0) }
        }
    }

    private func descendants(_ e: Element) -> [Element] {
        var out: [Element] = []
        var stack = Array(e.children().array().reversed())
        while let next = stack.popLast() {
            out.append(next)
            stack += next.children().array().reversed()
        }
        return out
    }

    private func matches(_ test: XPathStep.Test, _ node: XPathNode) -> Bool {
        switch test {
        case .node: return true
        case .any: return node.element != nil
        case .text:
            if case .text = node { return true }
            return false
        case .name(let name):
            guard let e = node.element else { return false }
            return e.tagName().lowercased() == name
        case .function:
            return false
        }
    }

    private func unique(_ list: [XPathNode]) -> [XPathNode] {
        var seen = Set<ObjectIdentifier>()
        var out: [XPathNode] = []
        for n in list {
            if let e = n.element {
                let id = ObjectIdentifier(e)
                if seen.contains(id) { continue }
                seen.insert(id)
            }
            out.append(n)
        }
        return out
    }

    // MARK: 类型转换

    private func nodes(_ value: XPathValue) -> [XPathNode] {
        switch value {
        case .nodes(let list): return list
        case .string(let s): return [.text(s)]
        case .number(let n): return [.text(XPathContext.format(n))]
        case .bool(let b): return [.text(b ? "true" : "false")]
        }
    }

    func string(_ value: XPathValue) -> String {
        switch value {
        case .nodes(let list): return list.first?.stringValue ?? ""
        case .string(let s): return s
        case .number(let n): return XPathContext.format(n)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    func number(_ value: XPathValue) -> Double {
        switch value {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        default: return Double(string(value).trimmingCharacters(in: .whitespaces)) ?? .nan
        }
    }

    func boolean(_ value: XPathValue) -> Bool {
        switch value {
        case .nodes(let list): return !list.isEmpty
        case .string(let s): return !s.isEmpty
        case .number(let n): return n != 0 && !n.isNaN
        case .bool(let b): return b
        }
    }

    // MARK: 运算

    private func binary(_ op: String, _ a: XPathExpr, _ b: XPathExpr, node: XPathNode, position: Int, size: Int) throws -> XPathValue {
        if op == "or" {
            if boolean(try eval(a, node: node, position: position, size: size)) { return .bool(true) }
            return .bool(boolean(try eval(b, node: node, position: position, size: size)))
        }
        if op == "and" {
            if !boolean(try eval(a, node: node, position: position, size: size)) { return .bool(false) }
            return .bool(boolean(try eval(b, node: node, position: position, size: size)))
        }
        let left = try eval(a, node: node, position: position, size: size)
        let right = try eval(b, node: node, position: position, size: size)
        switch op {
        case "+": return .number(number(left) + number(right))
        case "-": return .number(number(left) - number(right))
        case "*": return .number(number(left) * number(right))
        case "div": return .number(number(left) / number(right))
        case "mod": return .number(number(left).truncatingRemainder(dividingBy: number(right)))
        default: return .bool(compare(op, left, right))
        }
    }

    private func compare(_ op: String, _ left: XPathValue, _ right: XPathValue) -> Bool {
        // 节点集合：只要有一个满足即为真
        if case .nodes(let list) = left {
            return list.contains { compare(op, .string($0.stringValue), right) }
        }
        if case .nodes(let list) = right {
            return list.contains { compare(op, left, .string($0.stringValue)) }
        }
        if op == "=" || op == "!=" {
            let equal: Bool
            switch (left, right) {
            case (.bool, _), (_, .bool): equal = boolean(left) == boolean(right)
            case (.number, _), (_, .number): equal = number(left) == number(right)
            default: equal = string(left) == string(right)
            }
            return op == "=" ? equal : !equal
        }
        let l = number(left), r = number(right)
        switch op {
        case "<": return l < r
        case "<=": return l <= r
        case ">": return l > r
        case ">=": return l >= r
        default: return false
        }
    }

    private func function(_ name: String, _ args: [XPathExpr], node: XPathNode, position: Int, size: Int) throws -> XPathValue {
        func arg(_ i: Int) throws -> XPathValue {
            guard i < args.count else { return .nodes([node]) }
            return try eval(args[i], node: node, position: position, size: size)
        }
        func str(_ i: Int) throws -> String {
            if i >= args.count {
                // 无参数时取当前节点：JsoupXpath 中 text 比较用自身文本
                return node.stringValue
            }
            return string(try arg(i))
        }
        switch name {
        case "last": return .number(Double(size))
        case "position": return .number(Double(position))
        case "count": return .number(Double(nodes(try arg(0)).count))
        case "not": return .bool(!boolean(try arg(0)))
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "boolean": return .bool(boolean(try arg(0)))
        case "number": return .number(number(try arg(0)))
        case "string": return .string(try str(0))
        case "contains": return .bool(try str(0).contains(try str(1)))
        case "starts-with": return .bool(try str(0).hasPrefix(try str(1)))
        case "ends-with": return .bool(try str(0).hasSuffix(try str(1)))
        case "concat": return .string(try (0..<args.count).map { try str($0) }.joined())
        case "string-length": return .number(Double(try str(0).count))
        case "normalize-space":
            let s = try str(0)
            return .string(s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        case "substring":
            let s = Array(try str(0))
            let start = Int((number(try arg(1))).rounded()) - 1
            let length = args.count > 2 ? Int(number(try arg(2)).rounded()) : s.count
            let from = max(start, 0)
            let to = min(start + length, s.count)
            return .string(from < to ? String(s[from..<to]) : "")
        case "substring-before":
            let s = try str(0), t = try str(1)
            if let r = s.range(of: t) { return .string(String(s[..<r.lowerBound])) }
            return .string("")
        case "substring-after":
            let s = try str(0), t = try str(1)
            if let r = s.range(of: t) { return .string(String(s[r.upperBound...])) }
            return .string("")
        case "translate":
            let s = try str(0), from = Array(try str(1)), to = Array(try str(2))
            var out = ""
            for c in s {
                if let i = from.firstIndex(of: c) {
                    if i < to.count { out.append(to[i]) }
                } else {
                    out.append(c)
                }
            }
            return .string(out)
        case "name", "local-name":
            let list = args.isEmpty ? [node] : nodes(try arg(0))
            return .string(list.first?.element?.tagName() ?? "")
        case "sum": return .number(nodes(try arg(0)).reduce(0) { $0 + (Double($1.stringValue) ?? .nan) })
        case "floor": return .number(number(try arg(0)).rounded(.down))
        case "ceiling": return .number(number(try arg(0)).rounded(.up))
        case "round": return .number(number(try arg(0)).rounded())
        case "text":
            return .string(node.element?.ownText() ?? node.stringValue)
        case "allText":
            return .string(node.stringValue)
        default:
            throw XPathError(description: "不支持的函数 \(name)()")
        }
    }
}
