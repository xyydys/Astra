import Foundation
import Observation
import SwiftUI

/// 片源的本地存储：Kazumi 规则和采集站放在同一个列表里，共用一套优先级顺序
@Observable
@MainActor
final class RuleStore {
    /// 一个片源：Kazumi 规则或采集站二选一（旧版存档只有 rule 字段，可以直接读）
    struct Entry: Codable, Hashable, Identifiable {
        var rule: Rule?
        var cms: CMSSource?
        var enabled: Bool

        var id: String {
            if let rule { return "rule:" + rule.id }
            return "cms:" + (cms?.id ?? "")
        }

        var name: String { rule?.name ?? cms?.name ?? "" }

        var isSupported: Bool {
            if let rule { return rule.isSupported }
            return cms != nil
        }
    }

    /// 采集站检测结果（只在本次运行内保留）
    enum Health: Equatable {
        case testing
        case ok(TimeInterval)
        case failed(String)
    }

    enum ImportError: LocalizedError {
        case invalid
        var errorDescription: String? { "没有识别到有效的规则 JSON 或 kazumi:// 链接" }
    }

    /// 与 Kazumi 相同的规则仓库，GitHub 不通时走 GitCode 镜像
    static let repoBases = [
        "https://raw.githubusercontent.com/Predidit/KazumiRules/main/",
        "https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/",
    ]

    private(set) var entries: [Entry] = []
    private(set) var health: [String: Health] = [:]

    /// 启用的 Kazumi 规则（按优先级）
    var enabledRules: [Rule] {
        entries.compactMap { $0.enabled ? $0.rule : nil }.filter(\.isSupported)
    }

    /// 启用的采集站（按优先级）
    var enabledCMS: [CMSSource] {
        entries.compactMap { $0.enabled ? $0.cms : nil }
    }

    /// 选片源时要搜索的片源：番剧两种都搜，影视只搜采集站（Kazumi 规则都是动漫站）
    func searchableEntries(includeRules: Bool) -> [Entry] {
        entries.filter { $0.enabled && $0.isSupported && (includeRules || $0.cms != nil) }
    }

    init() {
        load()
    }

    /// 从备份恢复后重新读盘
    func reload() {
        entries = []
        health = [:]
        load()
    }

    func rule(named name: String) -> Rule? {
        entries.first { $0.rule?.id == name.lowercased() }?.rule
    }

    func cms(api: String) -> CMSSource? {
        entries.first { $0.cms?.id == api.lowercased() }?.cms
    }

    func installedVersion(of name: String) -> String? {
        entries.first { $0.rule?.id == name.lowercased() }?.rule?.version
    }

    func install(_ rule: Rule) {
        guard !rule.name.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.rule?.id == rule.id }) {
            entries[index].rule = rule
        } else {
            entries.append(Entry(rule: rule, cms: nil, enabled: rule.isSupported))
        }
        save()
    }

    /// 添加采集站：已有的只更新名称，新的排在最后（成人源默认不启用）
    @discardableResult
    func install(_ sources: [CMSSource]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for source in sources where CMSSource.isValidURL(source.url) {
            if let index = entries.firstIndex(where: { $0.cms?.id == source.id }) {
                entries[index].cms?.name = source.name
                updated += 1
            } else {
                entries.append(Entry(rule: nil, cms: source, enabled: !source.isAdult))
                added += 1
            }
        }
        save()
        return (added, updated)
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = entries.firstIndex(where: { $0.id == id }), entries[index].cms != nil else { return }
        entries[index].cms?.name = trimmed
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where entries.indices.contains(index) {
            entries.remove(at: index)
        }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// 排在前面的规则优先：搜片源时按这个顺序展示
    func moveToTop(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), index > 0 else { return }
        entries.insert(entries.remove(at: index), at: 0)
        save()
    }

    func moveToBottom(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), index < entries.count - 1 else { return }
        entries.append(entries.remove(at: index))
        save()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].enabled = enabled
        save()
    }

    /// 并发检测所有采集站的可用性和响应速度
    func testAllCMS() async {
        let sources = entries.compactMap(\.cms)
        for source in sources { health["cms:" + source.id] = .testing }
        await withTaskGroup(of: (String, Health).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return ("cms:" + source.id, .ok(try await CMSClient.probe(source)))
                    } catch {
                        return ("cms:" + source.id, .failed(error.localizedDescription))
                    }
                }
            }
            for await (id, result) in group { health[id] = result }
        }
    }

    // MARK: 导入

    /// 导入解析结果（规则和采集站都可能有）
    func install(_ result: SourceImport.Result) -> String {
        for rule in result.rules { install(rule) }
        var parts: [String] = []
        if !result.rules.isEmpty {
            parts.append("规则：" + result.rules.map(\.name).joined(separator: "、"))
        }
        if !result.sources.isEmpty {
            let counts = install(result.sources)
            parts.append("采集站：新增 \(counts.added) 个" + (counts.updated > 0 ? "，更新 \(counts.updated) 个" : ""))
        }
        if result.skipped > 0 {
            parts.append("跳过 \(result.skipped) 个无法使用的接口（爬虫 / XML）")
        }
        return parts.joined(separator: "\n")
    }

    nonisolated static func parseImport(_ text: String) throws -> [Rule] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoder = JSONDecoder()
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let data = Data(trimmed.utf8)
            if let one = try? decoder.decode(Rule.self, from: data), !one.name.isEmpty, !one.searchURL.isEmpty { return [one] }
            if let many = try? decoder.decode([Rule].self, from: data) {
                let valid = many.filter { !$0.name.isEmpty && !$0.searchURL.isEmpty }
                if !valid.isEmpty { return valid }
            }
            throw ImportError.invalid
        }

        var rules: [Rule] = []
        let pattern = #"kazumi:(?://)?([A-Za-z0-9+/=_%\-]+(?:[ \t\r\n]+[A-Za-z0-9+/=_%\-]+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            throw ImportError.invalid
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in regex.matches(in: trimmed, range: range) {
            guard let r = Range(match.range(at: 1), in: trimmed) else { continue }
            if let rule = decodeLinkPayload(String(trimmed[r]), decoder: decoder) {
                rules.append(rule)
            }
        }
        if rules.isEmpty { throw ImportError.invalid }
        return rules
    }

    /// 聊天软件常把链接折行或在后面接文字：先试完整内容，再逐段从空白处截短
    nonisolated private static func decodeLinkPayload(_ raw: String, decoder: JSONDecoder) -> Rule? {
        var candidates = [raw]
        var cursor = raw
        while let ws = cursor.lastIndex(where: { $0.isWhitespace }) {
            cursor = String(cursor[..<ws]).trimmingCharacters(in: .whitespacesAndNewlines)
            if cursor.isEmpty { break }
            candidates.append(cursor)
        }
        for candidate in candidates {
            var payload = candidate.removingPercentEncoding ?? candidate
            payload = payload.filter { !$0.isWhitespace }
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while payload.count % 4 != 0 { payload += "=" }
            if let data = Data(base64Encoded: payload),
               let rule = try? decoder.decode(Rule.self, from: data),
               !rule.name.isEmpty {
                return rule
            }
        }
        return nil
    }

    // MARK: 规则仓库

    func fetchIndex() async throws -> [RepoEntry] {
        var lastError: Error = NetError.status(0)
        for base in Self.repoBases {
            do {
                let data = try await Self.fetch(base + "index.json")
                let list = try JSONDecoder().decode([RepoEntry].self, from: data)
                return list.sorted { $0.lastUpdate > $1.lastUpdate }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func fetchRule(named name: String) async throws -> Rule {
        var lastError: Error = NetError.status(0)
        let file = (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name) + ".json"
        for base in Self.repoBases {
            do {
                let data = try await Self.fetch(base + file)
                let rule = try JSONDecoder().decode(Rule.self, from: data)
                if rule.name.isEmpty { throw ImportError.invalid }
                return rule
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetch(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw NetError.badURL(urlString) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Astra", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetError.status(http.statusCode)
        }
        return data
    }

    // MARK: 持久化

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rules.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = list
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
