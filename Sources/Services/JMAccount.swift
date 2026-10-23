import Foundation

/// 禁漫账号：登录状态、云端收藏同步
@MainActor
final class JMAccount: ObservableObject {
    static let shared = JMAccount()

    /// 收藏 / 取消收藏漫画时同步到禁漫账号
    static let syncFavoritesKey = "jmSyncFavorites"

    @Published var user: JMUser?
    @Published private(set) var syncing = false

    var isLoggedIn: Bool { user != nil }

    static var syncFavorites: Bool {
        UserDefaults.standard.object(forKey: syncFavoritesKey) as? Bool ?? true
    }

    private init() {
        user = JMClient.username == nil ? nil : JMClient.savedUser
    }

    func login(username: String, password: String) async throws {
        user = try await JMClient.login(username: username, password: password)
    }

    func logout() {
        JMClient.logout()
        user = nil
    }

    /// 用保存的账号重新登录一次，刷新等级、金币、收藏数
    func refresh() async throws {
        guard let username = JMClient.username, let password = Keychain.get("jm:" + username) else {
            throw JMError.loginRequired
        }
        user = try await JMClient.login(username: username, password: password)
    }

    // MARK: 收藏同步

    /// 云端「全部」收藏夹里的所有本子（最新收藏的在前）
    func cloudFavorites() async throws -> [JMComic] {
        var result: [JMComic] = []
        var seen = Set<String>()
        var page = 1
        while page <= 100 {
            let batch = try await JMClient.favorites(page: page)
            let fresh = batch.comics.filter { seen.insert($0.id).inserted }
            result += fresh
            if fresh.isEmpty || result.count >= batch.total { break }
            page += 1
        }
        return result
    }

    /// 云端收藏 → 本地收藏（只补本地没有的，不删本地的）。返回新加的数量和云端总数
    func pullFavorites() async throws -> (added: Int, total: Int) {
        syncing = true
        defer { syncing = false }
        let comics = try await cloudFavorites()
        let library = WatchLibrary.shared
        // 云端列表最新的在前：时间从现在往前排，保持原来的先后顺序
        let now = Date()
        var items: [FavoriteItem] = []
        for (index, comic) in comics.enumerated() {
            var item = FavoriteItem(subject: comic.subject)
            item.addedAt = now.addingTimeInterval(-Double(index))
            items.append(item)
        }
        let before = library.favorites.count
        library.merge(favorites: items, records: [])
        PosterTints.shared.prefetch(comics.prefix(24).map(\.subject))
        return (library.favorites.count - before, comics.count)
    }

    /// 本地漫画收藏 → 云端（只补云端没有的）。返回上传的数量
    func pushFavorites() async throws -> Int {
        syncing = true
        defer { syncing = false }
        let cloud = Set(try await cloudFavorites().map(\.id))
        let local = WatchLibrary.shared.favorites.compactMap { $0.subject.jmID }
        var uploaded = 0
        for id in local where !cloud.contains(id) {
            try await JMClient.setFavorite(id, true)
            uploaded += 1
        }
        return uploaded
    }

    /// 详情页点收藏时顺手同步到云端（失败不打扰用户）
    func mirrorFavorite(_ subject: BangumiSubject, favorite: Bool) {
        guard isLoggedIn, Self.syncFavorites, let id = subject.jmID else { return }
        Task { try? await JMClient.setFavorite(id, favorite) }
    }
}
