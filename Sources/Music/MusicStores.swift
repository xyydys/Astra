import Foundation
import Observation

private func musicDirectory(_ name: String? = nil) -> URL {
    var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Music", isDirectory: true)
    if let name { dir = dir.appendingPathComponent(name, isDirectory: true) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - 洛雪音源

struct LXSourceEntry: Codable, Identifiable, Hashable {
    var id: String
    var info: LXSourceRuntime.ScriptInfo
    var sources: [String: LXSourceRuntime.SourceSupport]
    var origin: String
    var importedAt: Date

    var platformNames: String {
        MusicPlatform.allCases.filter { sources[$0.rawValue] != nil }.map(\.short).joined(separator: " · ")
    }
}

@Observable
@MainActor
final class LXSourceStore {
    static let shared = LXSourceStore()
    static let qualityKey = "musicQuality"

    private(set) var entries: [LXSourceEntry] = []
    private(set) var activeID: String?
    private(set) var state: String = ""
    @ObservationIgnored private var runtime: LXSourceRuntime?
    @ObservationIgnored private var runtimeID: String?
    @ObservationIgnored private var starting: Task<LXSourceRuntime, Error>?

    private static var listURL: URL { musicDirectory().appendingPathComponent("lx-sources.json") }
    private static func scriptURL(_ id: String) -> URL { musicDirectory("sources").appendingPathComponent(id + ".js") }

    private init() {
        readFromDisk()
    }

    private func readFromDisk() {
        if let data = try? Data(contentsOf: Self.listURL),
           let list = try? JSONDecoder().decode([LXSourceEntry].self, from: data) {
            entries = list
        } else {
            entries = []
        }
        activeID = UserDefaults.standard.string(forKey: "lxActiveSource") ?? entries.first?.id
    }

    /// 从备份恢复后重新读盘
    func reload() {
        resetRuntime()
        readFromDisk()
    }

    var active: LXSourceEntry? { entries.first { $0.id == activeID } ?? entries.first }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.listURL, options: .atomic)
        }
        UserDefaults.standard.set(activeID, forKey: "lxActiveSource")
    }

    // MARK: 导入

    /// 导入脚本：先跑一遍，能初始化才算成功
    @discardableResult
    func importScript(_ script: String, origin: String = "") async throws -> LXSourceEntry {
        let text = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("lx") else { throw MusicError.message("这不是洛雪音乐的自定义音源脚本") }
        let runtime = LXSourceRuntime(script: text)
        let sources = try await runtime.start()
        runtime.stop()
        let id = UUID().uuidString
        try text.write(to: Self.scriptURL(id), atomically: true, encoding: .utf8)
        let entry = LXSourceEntry(id: id, info: runtime.info, sources: sources, origin: origin, importedAt: Date())
        // 同名音源视为更新
        if let index = entries.firstIndex(where: { $0.info.name == entry.info.name }) {
            try? FileManager.default.removeItem(at: Self.scriptURL(entries[index].id))
            let wasActive = activeID == entries[index].id
            entries[index] = entry
            if wasActive { activeID = id; resetRuntime() }
        } else {
            entries.append(entry)
        }
        if activeID == nil || !entries.contains(where: { $0.id == activeID }) { activeID = id }
        save()
        return entry
    }

    @discardableResult
    func importURL(_ raw: String) async throws -> LXSourceEntry {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL.lenient(text) else { throw MusicError.message("地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(MusicPlatformAPI.pcUA, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let script = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return try await importScript(script, origin: text)
    }

    func delete(_ id: String) {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.scriptURL(id))
        if activeID == id {
            activeID = entries.first?.id
            resetRuntime()
        }
        save()
    }

    func activate(_ id: String) {
        guard activeID != id else { return }
        activeID = id
        resetRuntime()
        save()
    }

    func logs() -> [String] {
        runtime?.recentLogs() ?? []
    }

    private func resetRuntime() {
        runtime?.stop()
        runtime = nil
        runtimeID = nil
        starting = nil
        state = ""
    }

    // MARK: 取播放地址

    private func ensureRuntime() async throws -> LXSourceRuntime {
        guard let entry = active else { throw MusicError.noSource }
        if let runtime, runtimeID == entry.id { return runtime }
        if let starting { return try await starting.value }
        guard let script = try? String(contentsOf: Self.scriptURL(entry.id), encoding: .utf8) else {
            throw MusicError.message("音源文件丢失，请重新导入")
        }
        state = "正在加载音源…"
        let task = Task { () throws -> LXSourceRuntime in
            let runtime = LXSourceRuntime(script: script)
            _ = try await runtime.start()
            return runtime
        }
        starting = task
        do {
            let runtime = try await task.value
            self.runtime = runtime
            runtimeID = entry.id
            starting = nil
            state = ""
            return runtime
        } catch {
            starting = nil
            state = "音源加载失败：\(error.localizedDescription)"
            throw error
        }
    }

    func supports(_ platform: MusicPlatform) -> Bool {
        active?.sources[platform.rawValue] != nil
    }

    /// 按音质偏好挑一个音源和歌曲都支持的音质，失败时退到 128k 再试一次
    func resolveURL(for track: MusicTrack) async throws -> String {
        guard let entry = active else { throw MusicError.noSource }
        guard let support = entry.sources[track.source.rawValue] else { throw MusicError.unsupported(track.source) }
        let runtime = try await ensureRuntime()
        let preferred = UserDefaults.standard.string(forKey: Self.qualityKey) ?? "320k"
        let order = ["128k", "320k", "flac", "flac24bit"]
        let limit = order.firstIndex(of: preferred) ?? 1
        let offered = support.qualitys.isEmpty ? order : support.qualitys
        let available = track.qualities.isEmpty ? order : track.qualities
        let candidates = order.enumerated()
            .filter { $0.offset <= limit && offered.contains($0.element) && available.contains($0.element) }
            .map(\.element)
        let quality = candidates.last ?? "128k"
        do {
            return try await runtime.musicUrl(platform: track.source.rawValue, quality: quality, musicInfo: track.lxMusicInfo)
        } catch {
            guard quality != "128k" else { throw error }
            return try await runtime.musicUrl(platform: track.source.rawValue, quality: "128k", musicInfo: track.lxMusicInfo)
        }
    }
}

// MARK: - 收藏和播放历史（只给音乐用，不进底栏的收藏 / 历史）

@Observable
@MainActor
final class MusicLibrary {
    static let shared = MusicLibrary()

    private(set) var favorites: [MusicTrack] = []
    private(set) var history: [MusicTrack] = []

    private struct Snapshot: Codable {
        var favorites: [MusicTrack]
        var history: [MusicTrack]
    }

    private static var fileURL: URL { musicDirectory().appendingPathComponent("library.json") }

    private init() {
        reload()
    }

    /// 启动时读盘；从备份恢复后也调用一次
    func reload() {
        let snapshot = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        favorites = snapshot?.favorites ?? []
        history = snapshot?.history ?? []
    }

    private func save() {
        let snapshot = Snapshot(favorites: favorites, history: history)
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func isFavorite(_ track: MusicTrack) -> Bool {
        favorites.contains { $0.id == track.id }
    }

    func toggleFavorite(_ track: MusicTrack) {
        if let index = favorites.firstIndex(where: { $0.id == track.id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(track, at: 0)
        }
        save()
    }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        save()
    }

    func recordPlay(_ track: MusicTrack) {
        history.removeAll { $0.id == track.id }
        history.insert(track, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        save()
    }

    /// 封面是播放时才补全的，顺手更新收藏和历史里的那一条
    func updateCover(_ track: MusicTrack) {
        var changed = false
        if let i = favorites.firstIndex(where: { $0.id == track.id }), favorites[i].cover.isEmpty {
            favorites[i].cover = track.cover
            changed = true
        }
        if let i = history.firstIndex(where: { $0.id == track.id }), history[i].cover.isEmpty {
            history[i].cover = track.cover
            changed = true
        }
        if changed { save() }
    }

    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }
}
