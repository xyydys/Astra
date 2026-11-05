import Foundation

/// 片源的大类
enum SourceKind: String, CaseIterable, Identifiable, Codable {
    case cat, uz, cms, rule

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cat: return "猫影视"
        case .uz: return "网盘"
        case .cms: return "采集站"
        case .rule: return "规则"
        }
    }

    var detail: String {
        switch self {
        case .cat: return "猫影视插件包里的站点"
        case .uz: return "网盘资源站（uz 扩展）搜到的网盘分享"
        case .cms: return "苹果 CMS 采集站"
        case .rule: return "Kazumi 规则（只用于番剧）"
        }
    }
}

/// 片源大类的优先级：片名对得上的结果里，排在前面的大类优先（默认猫影视 → 网盘 → 采集站 → 规则）。
/// 存成逗号分隔的字符串，设置页可以直接用 @AppStorage 读写
enum SourceKindOrder {
    static let key = "source.kindOrder"
    static let defaultOrder: [SourceKind] = [.cat, .uz, .cms, .rule]

    static func parse(_ raw: String) -> [SourceKind] {
        var list: [SourceKind] = []
        for part in raw.split(separator: ",") {
            if let kind = SourceKind(rawValue: String(part)), !list.contains(kind) { list.append(kind) }
        }
        for kind in defaultOrder where !list.contains(kind) { list.append(kind) }
        return list
    }

    static func raw(_ order: [SourceKind]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    static var order: [SourceKind] {
        get { parse(UserDefaults.standard.string(forKey: key) ?? "") }
        set { UserDefaults.standard.set(raw(newValue), forKey: key) }
    }
}

/// 片源和作品的匹配度（影视详情和番剧详情共用）
enum SourceScore {
    /// 搜索词和作品的各种叫法（规整过的）。排一批结果时先算一次，传给下面的函数
    static func targets(_ keyword: String, _ subject: BangumiSubject) -> Set<String> {
        Set(([keyword] + subject.searchKeywords).map(CMSClient.normalizeTitle).filter { !$0.isEmpty })
    }

    /// 片名对得上的程度：一致 2、包含 1、对不上 0
    private static func titleMatch(_ name: String, _ targets: Set<String>) -> Int {
        let title = CMSClient.normalizeTitle(name)
        if targets.contains(title) { return 2 }
        if !title.isEmpty, targets.contains(where: { title.contains($0) || $0.contains(title) }) { return 1 }
        return 0
    }

    static func match(name: String, year: String, episodeCount: Int, keyword: String, subject: BangumiSubject) -> Double {
        match(name: name, year: year, episodeCount: episodeCount, targets: targets(keyword, subject), subject: subject)
    }

    /// 一条搜索结果的匹配度：片名一致 4 分、片名包含 1.5 分；年份一致 +2、差一年 +0.5、对不上 -1.5；
    /// 集数和作品的集数比，齐全最多 +2
    static func match(name: String, year: String, episodeCount: Int, targets: Set<String>, subject: BangumiSubject) -> Double {
        var value = 0.0
        switch titleMatch(name, targets) {
        case 2: value += 4
        case 1: value += 1.5
        default: break
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

    /// 匹配档次：片名一致 2、片名包含 1、对不上 0；年份差两年以上、集数不到找到的最全那个的一半，各降一档。
    /// 同一档里才轮到片源大类的优先级，免得优先的大类里一个对不上的结果排到最前
    static func level(name: String, year: String, episodeCount: Int, maxEpisodes: Int, targets: Set<String>, subject: BangumiSubject) -> Int {
        var value = titleMatch(name, targets)
        if let wanted = Int(subject.airDate.prefix(4)), let found = Int(year.prefix(4)), abs(wanted - found) > 1 {
            value -= 1
        }
        if maxEpisodes > 1, episodeCount * 2 < maxEpisodes {
            value -= 1
        }
        return max(value, 0)
    }

    /// 自己排的优先级：越靠前加分越多（最多 1 分，只在匹配度差不多时起作用）
    static func priority(index: Int, total: Int) -> Double {
        1 - Double(index) / Double(max(total, 1))
    }
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
