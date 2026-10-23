import Foundation
import SwiftUI
#if canImport(SwiftData)
import SwiftData
#endif

/// 收藏的条目（番剧 / 影视 / 漫画 / 小说共用）
struct FavoriteItem: Codable, Hashable, Identifiable {
    var subjectID: Int
    var name: String = ""
    var nameCN: String = ""
    var image: String = ""
    var score: Double = 0
    var addedAt: Date = Date()

    var id: Int { subjectID }

    init(subject: BangumiSubject) {
        subjectID = subject.id
        name = subject.name
        nameCN = subject.nameCN
        image = subject.image
        score = subject.score
        addedAt = Date()
    }

    var title: String { nameCN.isEmpty ? name : nameCN }

    var subject: BangumiSubject {
        BangumiSubject(
            id: subjectID, name: name, nameCN: nameCN, image: image, thumb: image,
            score: score, rank: 0, airDate: "", summary: "", tags: [], episodes: 0
        )
    }
}

/// 每部番只保留最后一次观看位置
struct WatchRecord: Codable, Hashable, Identifiable {
    var subjectID: Int
    var title: String = ""
    var name: String = ""
    var image: String = ""
    var ruleName: String = ""
    var sourceURL: String = ""
    var sourceTitle: String = ""
    var roadIndex: Int = 0
    var episodeIndex: Int = 0
    var episodeName: String = ""
    var position: Double = 0
    var duration: Double = 0
    var updatedAt: Date = Date()
    /// 采集站片源：接口地址和影片 id（Kazumi 规则片源时为空）
    var cmsAPI: String = ""
    var vodID: String = ""
    /// "comic" 表示漫画阅读记录：episodeIndex 是第几话，position / duration 是第几页 / 总页数
    var kind: String = ""

    var id: Int { subjectID }
    var isComic: Bool { kind == "comic" }
    /// "novel"：小说阅读记录，episodeIndex 是第几章，position / duration 是章内字符位置 / 章节长度
    var isNovel: Bool { kind == "novel" }

    init(subjectID: Int) {
        self.subjectID = subjectID
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var playRequest: PlayRequest {
        PlayRequest(
            subjectID: subjectID, title: title, name: name, image: image,
            ruleName: ruleName, sourceURL: sourceURL, sourceTitle: sourceTitle,
            roadIndex: roadIndex, episodeIndex: episodeIndex, position: position,
            cmsAPI: cmsAPI, vodID: vodID
        )
    }

    var subject: BangumiSubject {
        BangumiSubject(
            id: subjectID, name: name, nameCN: title, image: image, thumb: image,
            score: 0, rank: 0, airDate: "", summary: "", tags: [], episodes: 0
        )
    }
}

/// 收藏和观看 / 阅读历史，存在 Application Support/watch-library.json。
/// 以前的版本用 SwiftData（iOS 17 起才有），第一次启动时把旧数据搬过来
@MainActor
final class WatchLibrary: ObservableObject {
    static let shared = WatchLibrary()

    /// 最新收藏的在前
    @Published private(set) var favorites: [FavoriteItem] = []
    /// 最近看过的在前
    @Published private(set) var records: [WatchRecord] = []

    private struct Stored: Codable {
        var favorites: [FavoriteItem]
        var records: [WatchRecord]
    }

    nonisolated static let fileName = "watch-library.json"

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            favorites = stored.favorites
            records = stored.records
        } else if #available(iOS 17, *), let legacy = LegacySwiftDataStore.load() {
            favorites = legacy.favorites
            records = legacy.records
            writeNow()
        }
        sort()
    }

    // MARK: 收藏

    func favorite(_ subjectID: Int) -> FavoriteItem? {
        favorites.first { $0.subjectID == subjectID }
    }

    func isFavorite(_ subjectID: Int) -> Bool {
        favorites.contains { $0.subjectID == subjectID }
    }

    func toggleFavorite(_ subject: BangumiSubject) {
        if isFavorite(subject.id) {
            removeFavorite(subject.id)
        } else {
            favorites.insert(FavoriteItem(subject: subject), at: 0)
            save()
        }
    }

    func removeFavorite(_ subjectID: Int) {
        favorites.removeAll { $0.subjectID == subjectID }
        save()
    }

    // MARK: 历史

    func record(_ subjectID: Int) -> WatchRecord? {
        records.first { $0.subjectID == subjectID }
    }

    /// 修改（没有就新建）一条记录，更新时间由调用方设置
    func updateRecord(_ subjectID: Int, _ change: (inout WatchRecord) -> Void) {
        var record = record(subjectID) ?? WatchRecord(subjectID: subjectID)
        change(&record)
        records.removeAll { $0.subjectID == subjectID }
        records.append(record)
        sort()
        save()
    }

    func removeRecords(_ subjectIDs: Set<Int>) {
        records.removeAll { subjectIDs.contains($0.subjectID) }
        save()
    }

    func clearRecords() {
        records.removeAll()
        save()
    }

    // MARK: 恢复备份

    /// 收藏按条目补齐，历史同一条保留较新的
    func merge(favorites incoming: [FavoriteItem], records incomingRecords: [WatchRecord]) {
        let existing = Set(favorites.map(\.subjectID))
        favorites += incoming.filter { !existing.contains($0.subjectID) }
        var byID = Dictionary(records.map { ($0.subjectID, $0) }, uniquingKeysWith: { first, _ in first })
        for item in incomingRecords {
            if let current = byID[item.subjectID], current.updatedAt >= item.updatedAt { continue }
            byID[item.subjectID] = item
        }
        records = Array(byID.values)
        sort()
        writeNow()
    }

    // MARK: 存储

    private func sort() {
        favorites.sort { $0.addedAt > $1.addedAt }
        records.sort { $0.updatedAt > $1.updatedAt }
    }

    /// 播放进度每几秒写一次，合并成一次磁盘写入
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    private func writeNow() {
        let stored = Stored(favorites: favorites, records: records)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 旧版 SwiftData 数据

/// 旧版本的 SwiftData 模型，只用来迁移。类型名（实体名）必须和旧版一致
@available(iOS 17, *)
enum LegacySwiftDataStore {
    @Model
    final class FavoriteItem {
        @Attribute(.unique) var subjectID: Int
        var name: String = ""
        var nameCN: String = ""
        var image: String = ""
        var score: Double = 0
        var addedAt: Date = Date()

        init(subjectID: Int) {
            self.subjectID = subjectID
        }
    }

    @Model
    final class WatchRecord {
        @Attribute(.unique) var subjectID: Int
        var title: String = ""
        var name: String = ""
        var image: String = ""
        var ruleName: String = ""
        var sourceURL: String = ""
        var sourceTitle: String = ""
        var roadIndex: Int = 0
        var episodeIndex: Int = 0
        var episodeName: String = ""
        var position: Double = 0
        var duration: Double = 0
        var updatedAt: Date = Date()
        var cmsAPI: String = ""
        var vodID: String = ""
        var kind: String = ""

        init(subjectID: Int) {
            self.subjectID = subjectID
        }
    }

    /// 旧版默认数据库：Application Support/default.store
    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("default.store")
    }

    @MainActor
    static func load() -> (favorites: [Astra.FavoriteItem], records: [Astra.WatchRecord])? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        let configuration = ModelConfiguration(url: storeURL)
        guard let container = try? ModelContainer(for: FavoriteItem.self, WatchRecord.self, configurations: configuration) else {
            return nil
        }
        let context = container.mainContext
        let favorites = ((try? context.fetch(FetchDescriptor<FavoriteItem>())) ?? []).map { item in
            var value = Astra.FavoriteItem(subject: BangumiSubject(
                id: item.subjectID, name: item.name, nameCN: item.nameCN, image: item.image, thumb: item.image,
                score: item.score, rank: 0, airDate: "", summary: "", tags: [], episodes: 0
            ))
            value.addedAt = item.addedAt
            return value
        }
        let records = ((try? context.fetch(FetchDescriptor<WatchRecord>())) ?? []).map { item in
            var value = Astra.WatchRecord(subjectID: item.subjectID)
            value.title = item.title
            value.name = item.name
            value.image = item.image
            value.ruleName = item.ruleName
            value.sourceURL = item.sourceURL
            value.sourceTitle = item.sourceTitle
            value.roadIndex = item.roadIndex
            value.episodeIndex = item.episodeIndex
            value.episodeName = item.episodeName
            value.position = item.position
            value.duration = item.duration
            value.updatedAt = item.updatedAt
            value.cmsAPI = item.cmsAPI
            value.vodID = item.vodID
            value.kind = item.kind
            return value
        }
        return (favorites, records)
    }
}

/// 打开播放页需要的全部信息
struct PlayRequest: Hashable {
    var subjectID: Int
    var title: String
    var name: String
    var image: String
    var ruleName: String
    var sourceURL: String
    var sourceTitle: String
    var roadIndex: Int = 0
    var episodeIndex: Int = 0
    var position: Double = 0
    /// 采集站片源：接口地址和影片 id；为空时是 Kazumi 规则片源（ruleName + sourceURL）
    var cmsAPI: String = ""
    var vodID: String = ""

    var isCMS: Bool { !cmsAPI.isEmpty }
}

extension TimeInterval {
    var clockText: String {
        guard isFinite, self > 0 else { return "00:00" }
        let total = Int(self)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
