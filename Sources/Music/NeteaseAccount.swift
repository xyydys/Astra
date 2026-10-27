import Foundation

/// 网易云账号：登录状态、红心同步、用账号取播放地址
@MainActor
final class NeteaseAccount: ObservableObject {
    static let shared = NeteaseAccount()

    /// 收藏 / 取消收藏网易云的歌时同步红心
    static let syncLikesKey = "neteaseSyncLikes"
    /// 网易云的歌优先用账号取播放地址
    static let accountPlaybackKey = "neteaseAccountPlayback"
    static let qualityKey = "neteaseQuality"
    private static let profileKey = "neteaseProfile"

    static let qualities: [(level: String, name: String)] = [
        ("standard", "标准"), ("higher", "较高"), ("exhigh", "极高"), ("lossless", "无损"), ("hires", "Hi-Res"),
    ]

    @Published private(set) var profile: NeteaseProfile?
    @Published private(set) var likedIDs: Set<Int> = []
    @Published private(set) var syncing = false

    var isLoggedIn: Bool { profile != nil }

    static var syncLikes: Bool { UserDefaults.standard.object(forKey: syncLikesKey) as? Bool ?? true }
    static var accountPlayback: Bool { UserDefaults.standard.object(forKey: accountPlaybackKey) as? Bool ?? true }
    static var quality: String { UserDefaults.standard.string(forKey: qualityKey) ?? "lossless" }

    private init() {
        if NeteaseClient.shared.isLoggedIn,
           let data = UserDefaults.standard.data(forKey: Self.profileKey) {
            profile = try? JSONDecoder().decode(NeteaseProfile.self, from: data)
        }
    }

    // MARK: 登录

    /// 验证码 / 扫码 / Cookie 登录拿到 Cookie 之后，读一次账号信息确认登录有效
    func finishLogin() async throws {
        do {
            let profile = try await NeteaseAPI.account()
            setProfile(profile)
            Diag.log("网易云", "已登录 uid=\(profile.userId)")
            likedIDs = Set((try? await NeteaseAPI.likedIDs(uid: profile.userId)) ?? [])
        } catch {
            NeteaseClient.shared.clearLogin()
            setProfile(nil)
            throw error
        }
    }

    func login(cookie: String) async throws {
        guard NeteaseClient.shared.importCookie(cookie) else {
            throw NeteaseError.business(-1, "没找到 MUSIC_U，请粘贴 MUSIC_U 的值或整段 Cookie")
        }
        try await finishLogin()
    }

    /// 续期登录并刷新昵称、会员、红心列表
    func refresh() async throws {
        await NeteaseAPI.refreshToken()
        try await finishLogin()
    }

    func logout() {
        let jar = NeteaseClient.shared.authCookies
        NeteaseClient.shared.clearLogin()
        setProfile(nil)
        likedIDs = []
        Task.detached { await NeteaseAPI.logout(jar) }
    }

    private func setProfile(_ profile: NeteaseProfile?) {
        self.profile = profile
        if let profile, let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.profileKey)
        }
    }

    // MARK: 红心同步

    /// 云端红心 → 本地音乐收藏（只补本地没有的）。返回新加的数量和云端总数
    func pullLikes() async throws -> (added: Int, total: Int) {
        guard let profile else { throw NeteaseError.needLogin }
        syncing = true
        defer { syncing = false }
        let ids = try await NeteaseAPI.likedIDs(uid: profile.userId)
        likedIDs = Set(ids)
        let tracks = try await NeteaseAPI.songs(ids)
        let added = MusicLibrary.shared.mergeFavorites(tracks)
        return (added, ids.count)
    }

    /// 本地收藏里网易云的歌 → 云端红心（只补云端没有的）。返回新加的数量
    func pushLikes() async throws -> Int {
        guard let profile else { throw NeteaseError.needLogin }
        syncing = true
        defer { syncing = false }
        likedIDs = Set(try await NeteaseAPI.likedIDs(uid: profile.userId))
        let pending = MusicLibrary.shared.favorites
            .filter { $0.source == .wy }
            .compactMap { Int($0.songmid) }
            .filter { !likedIDs.contains($0) }
        var count = 0
        for id in pending.reversed() {
            try await NeteaseAPI.like(id, true)
            likedIDs.insert(id)
            count += 1
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        return count
    }

    /// 收藏 / 取消收藏一首网易云的歌时同步红心（打开了「收藏时同步红心」才会同步）
    func mirror(_ track: MusicTrack, liked: Bool) {
        guard isLoggedIn, Self.syncLikes, track.source == .wy, let id = Int(track.songmid) else { return }
        guard likedIDs.contains(id) != liked else { return }
        Task {
            do {
                try await NeteaseAPI.like(id, liked)
                if liked { likedIDs.insert(id) } else { likedIDs.remove(id) }
                Diag.log("网易云", "\(liked ? "红心" : "取消红心") \(id)")
            } catch {
                Diag.log("网易云", "同步红心失败 \(id)：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 播放

    /// 网易云的歌用账号取播放地址；没登录、关掉了、只有试听片段或者出错时返回 nil，交给音源
    func playbackURL(for track: MusicTrack) async -> String? {
        guard isLoggedIn, Self.accountPlayback, track.source == .wy, let id = Int(track.songmid) else { return nil }
        do {
            let url = try await NeteaseAPI.songURL(id, level: Self.quality)
            Diag.log("网易云", url == nil ? "账号取不到完整地址 \(id)，改用音源" : "用账号播放 \(id)")
            return url
        } catch {
            Diag.log("网易云", "账号取地址失败 \(id)：\(error.localizedDescription)")
            return nil
        }
    }
}
