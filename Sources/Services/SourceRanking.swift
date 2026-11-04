import Foundation

/// 片源和作品的匹配度（影视详情和番剧选片源共用）
enum SourceScore {
    /// 一条搜索结果的匹配度：片名一致 4 分、片名包含 1.5 分；年份一致 +2、差一年 +0.5、对不上 -1.5；
    /// 集数和作品的集数比，齐全最多 +2
    static func match(name: String, year: String, episodeCount: Int, keyword: String, subject: BangumiSubject) -> Double {
        var value = 0.0
        let title = CMSClient.normalizeTitle(name)
        let targets = Set(([keyword] + subject.searchKeywords).map(CMSClient.normalizeTitle).filter { !$0.isEmpty })
        if targets.contains(title) {
            value += 4
        } else if !title.isEmpty, targets.contains(where: { title.contains($0) || $0.contains(title) }) {
            value += 1.5
        }
        if let wanted = Int(subject.airDate.prefix(4)), let found = Int(year.prefix(4)) {
            let diff = abs(wanted - found)
            value += diff == 0 ? 2 : (diff == 1 ? 0.5 : -1.5)
        }
        if subject.episodes > 1, episodeCount > 0 {
            value += 2 * min(Double(episodeCount) / Double(subject.episodes), 1)
        }
        return value
    }

    /// 自己排的优先级：越靠前加分越多（最多 1 分，只在匹配度差不多时起作用）
    static func priority(index: Int, total: Int) -> Double {
        1 - Double(index) / Double(max(total, 1))
    }

    /// 这部作品点过 / 看过的片源
    static let preferredBonus = 8.0
    static let lastWatchedBonus = 6.0
}

/// 每部作品记住的首选片源和上次的片源顺序（打开时先按上次的顺序排，搜索结果陆续回来也不乱跳）。
/// 一部作品只存几十个片源 id，几百部也就几十 KB；最多记 500 部，超出去掉最久没打开的
@MainActor
final class SourceMemory {
    static let shared = SourceMemory()

    private struct Entry: Codable {
        var preferred: String?
        var order: [String] = []
        var updatedAt = Date()
    }

    private var entries: [Int: Entry] = [:]
    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("source-memory.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode([Int: Entry].self, from: data) {
            entries = value
        }
    }

    func preferred(for subject: Int) -> String? { entries[subject]?.preferred }

    func order(for subject: Int) -> [String] { entries[subject]?.order ?? [] }

    func setPreferred(_ id: String, for subject: Int) {
        var entry = entries[subject] ?? Entry()
        entry.preferred = id
        entry.updatedAt = Date()
        entries[subject] = entry
        save()
    }

    func setOrder(_ ids: [String], for subject: Int) {
        var entry = entries[subject] ?? Entry()
        guard entry.order != ids else { return }
        entry.order = ids
        entry.updatedAt = Date()
        entries[subject] = entry
        save()
    }

    private func save() {
        if entries.count > 500 {
            let keep = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(500)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}
