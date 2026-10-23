import Foundation

/// 全量备份：片源、书源、洛雪音源、书架、收藏、观看 / 阅读历史、音乐收藏和设置，导出成一个 JSON 文件。
/// - Application Support 里的数据文件原样打包（收藏 / 历史库、旧版 SwiftData 数据库和书源引擎的运行缓存除外）
/// - 收藏 / 观看历史逐条导出，导入时按条目合并
/// - 设置取 UserDefaults 里本 App 自己的键
/// 备份文件放在 Documents/备份，开了文件共享，能在「文件」App 里看到。
enum AppBackup {
    static let format = "astra-backup"
    static let version = 1

    struct Archive: Codable, Sendable {
        var format: String
        var version: Int
        var createdAt: Date
        var appVersion: String
        var bundleID: String
        /// Application Support 下的相对路径 → 文件内容
        var files: [String: Data]
        /// UserDefaults（二进制 plist）
        var defaults: Data?
        var favorites: [Favorite]
        var records: [Record]
    }

    struct Favorite: Codable, Sendable {
        var subjectID: Int
        var name: String
        var nameCN: String
        var image: String
        var score: Double
        var addedAt: Date
    }

    struct Record: Codable, Sendable {
        var subjectID: Int
        var title: String
        var name: String
        var image: String
        var ruleName: String
        var sourceURL: String
        var sourceTitle: String
        var roadIndex: Int
        var episodeIndex: Int
        var episodeName: String
        var position: Double
        var duration: Double
        var updatedAt: Date
        var cmsAPI: String
        var vodID: String
        var kind: String
    }

    /// 备份里各类数据的数量（导入前给用户确认）
    struct Summary: Sendable {
        var sources = 0
        var bookSources = 0
        var bookshelf = 0
        var musicSources = 0
        var musicFavorites = 0
        var musicHistory = 0
        var favorites = 0
        var records = 0
        var settings = 0

        var text: String {
            [
                ("片源", sources), ("书源", bookSources), ("书架", bookshelf), ("音源", musicSources),
                ("收藏", favorites), ("观看 / 阅读历史", records), ("音乐收藏", musicFavorites),
                ("播放历史", musicHistory), ("设置项", settings),
            ]
            .filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: " · ")
        }
    }

    enum BackupError: LocalizedError {
        case invalid
        case newer

        var errorDescription: String? {
            switch self {
            case .invalid: return "这不是 Astra 的备份文件"
            case .newer: return "这个备份来自更新版本的 Astra，请先更新 App 再导入"
            }
        }
    }

    // MARK: 位置

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Documents/备份：「文件」App 里显示为「我的 iPhone → App 名 → 备份」
    static var backupDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("备份", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 启动时建好备份目录，Documents 非空「文件」App 里才会出现本 App 的文件夹
    static func prepareFolder() {
        _ = backupDirectory
    }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Astra"
    }

    static func localBackups() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { modified($0) > modified($1) }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: 范围

    /// 不进备份的文件：收藏 / 历史库和旧版 SwiftData 数据库（收藏 / 历史逐条导出）、书源引擎的运行缓存、隐藏文件
    static func shouldSkip(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first else { return true }
        if parts.contains(where: { $0.hasPrefix(".") || $0 == ".." }) { return true }
        if first == "NovelEngine" || first.hasPrefix("com.apple") { return true }
        if relative.contains(".store") || relative == WatchLibrary.fileName { return true }
        return false
    }

    /// UserDefaults 里系统和框架自己写的键不备份
    private static let systemPrefixes = ["Apple", "NS", "com.apple", "WebKit", "WebDatabase", "AK", "PK", "INNext", "MSV", "UI", "_"]

    static func isSystemKey(_ key: String) -> Bool {
        systemPrefixes.contains { key.hasPrefix($0) }
    }

    private static func appDefaults() -> [String: Any] {
        guard let id = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: id) else { return [:] }
        return domain.filter { !isSystemKey($0.key) }
    }

    private static func collectFiles() throws -> [String: Data] {
        let root = supportDirectory.standardizedFileURL
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return files }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 64 * 1024 * 1024 else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            let relative = String(path.dropFirst(root.path.count + 1))
            guard !shouldSkip(relative) else { continue }
            files[relative] = try Data(contentsOf: url)
        }
        return files
    }

    // MARK: 导出

    /// 导出当前数据，返回 Documents/备份 里的文件
    @MainActor
    static func export(prefix: String? = nil) async throws -> URL {
        let favorites = WatchLibrary.shared.favorites.map { Favorite($0) }
        let records = WatchLibrary.shared.records.map { Record($0) }
        let defaults = try? PropertyListSerialization.data(fromPropertyList: appDefaults(), format: .binary, options: 0)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmmss"
        let name = "\(prefix ?? displayName + " 备份") \(stamp.string(from: Date())).json"

        return try await Task.detached(priority: .userInitiated) {
            let archive = Archive(
                format: format, version: version, createdAt: Date(), appVersion: appVersion, bundleID: bundleID,
                files: try collectFiles(), defaults: defaults, favorites: favorites, records: records
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let url = backupDirectory.appendingPathComponent(name)
            try encoder.encode(archive).write(to: url, options: .atomic)
            return url
        }.value
    }

    // MARK: 导入

    static func read(_ url: URL) async throws -> (Archive, Summary) {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let archive = try? decoder.decode(Archive.self, from: data), archive.format == format else {
                throw BackupError.invalid
            }
            guard archive.version <= version else { throw BackupError.newer }
            return (archive, summary(of: archive))
        }.value
    }

    static func summary(of archive: Archive) -> Summary {
        func json(_ path: String) -> Any? {
            archive.files[path].flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        var summary = Summary()
        summary.sources = (json("rules.json") as? [Any])?.count ?? 0
        summary.bookSources = (json("Novel/book-sources.json") as? [Any])?.count ?? 0
        // 书架是 [Int: NovelBook]，JSONEncoder 编成「键, 值, 键, 值」的数组
        switch json("Novel/library.json") {
        case let list as [Any]: summary.bookshelf = list.count / 2
        case let dict as [String: Any]: summary.bookshelf = dict.count
        default: break
        }
        summary.musicSources = (json("Music/lx-sources.json") as? [Any])?.count ?? 0
        if let music = json("Music/library.json") as? [String: Any] {
            summary.musicFavorites = (music["favorites"] as? [Any])?.count ?? 0
            summary.musicHistory = (music["history"] as? [Any])?.count ?? 0
        }
        summary.favorites = archive.favorites.count
        summary.records = archive.records.count
        if let data = archive.defaults,
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            summary.settings = dict.count
        }
        return summary
    }

    /// 恢复：数据文件和设置以备份为准，收藏 / 历史按条目合并（同一条保留较新的）
    @MainActor
    static func restore(_ archive: Archive, rules: RuleStore) async throws {
        let files = archive.files
        try await Task.detached(priority: .userInitiated) {
            let root = supportDirectory.standardizedFileURL
            for (relative, content) in files {
                guard !relative.hasPrefix("/"), !shouldSkip(relative) else { continue }
                let target = root.appendingPathComponent(relative).standardizedFileURL
                guard target.path.hasPrefix(root.path + "/") else { continue }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target, options: .atomic)
            }
        }.value

        if let data = archive.defaults,
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in dict where !isSystemKey(key) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }

        WatchLibrary.shared.merge(
            favorites: archive.favorites.map(\.model),
            records: archive.records.map(\.model)
        )

        rules.reload()
        await BookSourceStore.shared.reload()
        NovelLibrary.shared.reload()
        LXSourceStore.shared.reload()
        MusicLibrary.shared.reload()
        ReaderSettingsStore.shared.reload()
        ReaderBackground.shared.reload()
    }
}

extension AppBackup.Favorite {
    init(_ item: FavoriteItem) {
        self.init(
            subjectID: item.subjectID, name: item.name, nameCN: item.nameCN,
            image: item.image, score: item.score, addedAt: item.addedAt
        )
    }

    var model: FavoriteItem {
        var model = FavoriteItem(subject: BangumiSubject(
            id: subjectID, name: name, nameCN: nameCN, image: image, thumb: image,
            score: score, rank: 0, airDate: "", summary: "", tags: [], episodes: 0
        ))
        model.addedAt = addedAt
        return model
    }
}

extension AppBackup.Record {
    init(_ record: WatchRecord) {
        self.init(
            subjectID: record.subjectID, title: record.title, name: record.name, image: record.image,
            ruleName: record.ruleName, sourceURL: record.sourceURL, sourceTitle: record.sourceTitle,
            roadIndex: record.roadIndex, episodeIndex: record.episodeIndex, episodeName: record.episodeName,
            position: record.position, duration: record.duration, updatedAt: record.updatedAt,
            cmsAPI: record.cmsAPI, vodID: record.vodID, kind: record.kind
        )
    }

    var model: WatchRecord {
        var record = WatchRecord(subjectID: subjectID)
        record.title = title
        record.name = name
        record.image = image
        record.ruleName = ruleName
        record.sourceURL = sourceURL
        record.sourceTitle = sourceTitle
        record.roadIndex = roadIndex
        record.episodeIndex = episodeIndex
        record.episodeName = episodeName
        record.position = position
        record.duration = duration
        record.updatedAt = updatedAt
        record.cmsAPI = cmsAPI
        record.vodID = vodID
        record.kind = kind
        return record
    }
}
