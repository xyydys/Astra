import CommonCrypto
import CryptoKit
import Foundation
import Security
import UIKit

// MARK: - 数据

/// 禁漫的一部本子（列表和详情共用的基本信息）
struct JMComic: Hashable, Identifiable, Codable, Sendable {
    var id: String
    var title: String
    var author: String
    var description: String
    var tags: [String]

    var cover: String { JMClient.coverURL(id) }

    /// 导航、收藏、历史、取色都复用 BangumiSubject（id 为 -(20 亿 + 禁漫 id)）
    var subject: BangumiSubject {
        .comic(jmID: Int(id) ?? 0, title: title, author: author, tags: tags, description: description)
    }
}

struct JMChapter: Hashable, Identifiable, Codable, Sendable {
    var id: String
    var title: String
}

struct JMAlbum: Sendable {
    var comic: JMComic
    var chapters: [JMChapter]
    var works: [String]
    var actors: [String]
    var likes: String
    var views: String
    var updated: String
    var related: [JMComic]
}

struct JMSection: Hashable, Identifiable, Codable, Sendable {
    var title: String
    var comics: [JMComic]
    var id: String { title }
}

/// 登录后的账号信息
struct JMUser: Codable, Equatable, Sendable {
    var uid: String
    var username: String
    var photo: String
    var level: Int
    var levelName: String
    var coin: String
    var favorites: Int
    var favoritesMax: Int

    var avatarURL: String? {
        photo.isEmpty || photo.hasPrefix("nopic") ? nil : "\(JMClient.imageHost)/media/users/\(photo)"
    }
}

/// 云端收藏夹（folder_id 为 "0" 是「全部」）
struct JMFolder: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

struct JMFavoritesPage: Sendable {
    var comics: [JMComic]
    var folders: [JMFolder]
    var total: Int
}

struct JMPage: Sendable {
    var comics: [JMComic]
    var total: Int
    /// 用本子号搜索时，接口会直接给出对应的本子
    var redirectID: String?
}

enum JMError: LocalizedError {
    case status(Int, String?)
    case invalidData
    case loginRequired

    var errorDescription: String? {
        switch self {
        case .status(let code, let message): return message ?? "禁漫返回 \(code)"
        case .invalidData: return "禁漫返回的数据无法解析，可以在设置里换条线路再试"
        case .loginRequired: return "需要先登录禁漫账号"
        }
    }
}

extension BangumiSubject {
    static let comicIDBase = 2_000_000_000

    var isComic: Bool { id <= -Self.comicIDBase && id > -Self.novelIDBase }

    var jmID: String? { isComic ? String(-id - Self.comicIDBase) : nil }

    static func comic(jmID: Int, title: String, author: String, tags: [String], description: String) -> BangumiSubject {
        let cover = JMClient.coverURL(String(jmID))
        return BangumiSubject(
            id: -(comicIDBase + jmID), name: author, nameCN: title, image: cover, thumb: cover,
            score: 0, rank: 0, airDate: "", summary: description, tags: tags, episodes: 0
        )
    }
}

// MARK: - 接口

/// 禁漫天堂移动端接口。请求头带时间戳签名，返回的 data 字段是 AES-256-ECB 加密的 JSON，
/// 密钥是「时间戳 + 固定串」的 MD5 十六进制。域名和图片服务器会变，启动后从官方分发的列表刷新。
/// 协议细节参考了 Venera 社区的 jm.js 和 JMComic-Crawler-Python 的公开实现，这里是独立的 Swift 实现。
enum JMClient {
    static let appVersion = "2.0.16"
    private static let authKey = "18comicAPPContent"
    private static let dataSecret = "185Hcomic3PAPP7R"
    private static let domainListURL = "https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt"
    private static let domainSecret = "diosfjckwpqpdfjkvnqQjsik"
    static let builtinDomains = ["www.cdntwice.org", "www.cdnsha.org", "www.cdnaspa.cc", "www.cdnntr.cc"]
    static let builtinImageHost = "https://cdn-msp.jmapinodeudzn.net"
    static let userAgent = "Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/130.0.0.0 Mobile Safari/537.36"
    private static let packageName = "com.example.app"

    // MARK: 设置（UserDefaults，任何线程都能读）

    private enum Key {
        static let domains = "jmDomains"
        static let domainIndex = "jmDomainIndex"
        static let imageStream = "jmImageStream"
        static let imageHost = "jmImageHost"
        static let refreshedAt = "jmDomainsRefreshedAt"
        static let username = "jmUsername"
        static let user = "jmUser"
    }

    static var domains: [String] {
        let saved = UserDefaults.standard.stringArray(forKey: Key.domains) ?? []
        return saved.isEmpty ? builtinDomains : saved
    }

    /// 当前线路（0 开始）
    static var domainIndex: Int {
        get { min(max(UserDefaults.standard.integer(forKey: Key.domainIndex), 0), max(domains.count - 1, 0)) }
        set { UserDefaults.standard.set(newValue, forKey: Key.domainIndex) }
    }

    /// 图片分流 1...4
    static var imageStream: Int {
        get { min(max(UserDefaults.standard.integer(forKey: Key.imageStream), 1), 4) }
        set { UserDefaults.standard.set(newValue, forKey: Key.imageStream) }
    }

    static var imageHost: String {
        UserDefaults.standard.string(forKey: Key.imageHost) ?? builtinImageHost
    }

    static var username: String? {
        UserDefaults.standard.string(forKey: Key.username)
    }

    /// 上次登录时拿到的账号信息
    static var savedUser: JMUser? {
        UserDefaults.standard.data(forKey: Key.user).flatMap { try? JSONDecoder().decode(JMUser.self, from: $0) }
    }

    static var baseURL: String { "https://" + domains[domainIndex] }

    static func coverURL(_ id: String) -> String { "\(imageHost)/media/albums/\(id)_3x4.jpg" }

    static func pageURL(chapterID: String, name: String) -> String { "\(imageHost)/media/photos/\(chapterID)/\(name)" }

    // MARK: 启动准备

    /// 刷新线路列表（半天一次）和图片服务器
    static func prepare(force: Bool = false) async {
        let last = UserDefaults.standard.double(forKey: Key.refreshedAt)
        if force || Date().timeIntervalSince1970 - last > 12 * 3600 {
            if let servers = try? await fetchDomainList(), !servers.isEmpty {
                UserDefaults.standard.set(servers, forKey: Key.domains)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.refreshedAt)
            }
        }
        await refreshImageHost()
    }

    static func fetchDomainList() async throws -> [String] {
        var request = URLRequest(url: URL(string: domainListURL)!, timeoutInterval: 10)
        for (key, value) in baseHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let (data, _) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try decryptJSON(text, secret: domainSecret)
        let servers = (json as? [String: Any])?["Server"] as? [Any] ?? []
        return servers.map { JSONValue.string($0) }.filter { !$0.isEmpty }.prefix(4).map { $0 }
    }

    // MARK: 测速

    /// API 线路延迟（毫秒）：请求一次 /setting，连不上返回 nil
    static func latency(domain: String) async -> Int? {
        let start = Date()
        guard (try? await request(domain: domain, path: "/setting", query: [:], form: nil)) != nil else { return nil }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    /// 某个图片分流对应的图片服务器
    static func imageHost(stream: Int) async -> String? {
        guard let json = try? await get("/setting", query: ["app_img_shunt": "\(stream)", "express": ""]) as? [String: Any] else { return nil }
        let host = JSONValue.string(json["img_host"])
        return host.hasPrefix("http") ? host : nil
    }

    /// 图片服务器延迟（毫秒）：对服务器发一个 HEAD 请求，有响应就算通
    static func latency(imageHost host: String) async -> Int? {
        guard let url = URL(string: host + "/media/albums/blank.jpg") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        for (key, value) in imageHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let start = Date()
        guard (try? await URLSession.shared.data(for: request)) != nil else { return nil }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    static func refreshImageHost() async {
        guard let json = try? await get("/setting", query: ["app_img_shunt": "\(imageStream)", "express": ""]) as? [String: Any] else { return }
        let host = JSONValue.string(json["img_host"])
        if host.hasPrefix("http") {
            UserDefaults.standard.set(host, forKey: Key.imageHost)
        }
    }

    // MARK: 接口

    /// 首页推荐分区
    static func promote() async throws -> [JMSection] {
        let json = try await get("/promote", query: ["page": "0"])
        guard let list = json as? [[String: Any]] else { throw JMError.invalidData }
        return list.compactMap { section in
            let type = JSONValue.string(section["type"])
            if type == "library" || type == "novels" { return nil }
            let title = JSONValue.string(section["title"])
            if isHiddenSection(title) { return nil }
            let comics = (section["content"] as? [[String: Any]] ?? []).compactMap(parseComic)
            guard !comics.isEmpty else { return nil }
            return JMSection(title: title, comics: comics)
        }
    }

    /// 首页不展示的分区（「其他更新」之类，内容太猎奇）
    static func isHiddenSection(_ title: String) -> Bool {
        title.contains("其他") || title.contains("其它")
    }

    /// 分类 / 排行。sort：mr 最新、mv 总排行、mv_m 月、mv_w 周、mv_t 日、mp 最多图片、tf 最多喜欢
    static func category(_ slug: String, sort: String, page: Int) async throws -> JMPage {
        let json = try await get("/categories/filter", query: ["o": sort, "c": slug, "page": "\(page)"])
        return parsePage(json)
    }

    static func search(_ keyword: String, sort: String, page: Int) async throws -> JMPage {
        var query = ["search_query": keyword.trimmingCharacters(in: .whitespacesAndNewlines), "o": sort]
        if page > 1 { query["page"] = "\(page)" }
        let json = try await get("/search", query: query)
        var result = parsePage(json)
        if let dict = json as? [String: Any] {
            let redirect = JSONValue.string(dict["redirect_aid"])
            if !redirect.isEmpty { result.redirectID = redirect }
        }
        return result
    }

    static func album(_ id: String) async throws -> JMAlbum {
        let numeric = id.lowercased().hasPrefix("jm") ? String(id.dropFirst(2)) : id
        guard let json = try await get("/album", query: ["id": numeric]) as? [String: Any] else { throw JMError.invalidData }
        let strings: (Any?) -> [String] = { value in
            (value as? [Any] ?? []).map { JSONValue.string($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let series = (json["series"] as? [[String: Any]] ?? [])
            .sorted { (JSONValue.int($0["sort"]) ?? 0) < (JSONValue.int($1["sort"]) ?? 0) }
        var chapters = series.compactMap { item -> JMChapter? in
            let chapterID = JSONValue.string(item["id"])
            guard !chapterID.isEmpty else { return nil }
            var title = JSONValue.string(item["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { title = "第\(JSONValue.string(item["sort"]))話" }
            return JMChapter(id: chapterID, title: title)
        }
        // 单本没有分话，本子号本身就是唯一的一话
        if chapters.isEmpty { chapters = [JMChapter(id: numeric, title: "第1話")] }

        let comic = JMComic(
            id: numeric,
            title: JSONValue.string(json["name"]),
            author: strings(json["author"]).joined(separator: " / "),
            description: JSONValue.string(json["description"]).trimmingCharacters(in: .whitespacesAndNewlines),
            tags: strings(json["tags"])
        )
        var updated = ""
        if let time = JSONValue.int(json["addtime"]), time > 0 {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            updated = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(time)))
        }
        return JMAlbum(
            comic: comic,
            chapters: chapters,
            works: strings(json["works"]),
            actors: strings(json["actors"]),
            likes: JSONValue.string(json["likes"]),
            views: JSONValue.string(json["total_views"]),
            updated: updated,
            related: (json["related_list"] as? [[String: Any]] ?? []).compactMap(parseComic)
        )
    }

    /// 一话的所有图片地址
    static func chapterImages(_ chapterID: String) async throws -> [String] {
        guard let json = try await get("/chapter", query: ["id": chapterID]) as? [String: Any] else { throw JMError.invalidData }
        let names = (json["images"] as? [Any] ?? []).map { JSONValue.string($0) }.filter { !$0.isEmpty }
        if names.isEmpty { throw JMError.invalidData }
        return names.map { pageURL(chapterID: chapterID, name: $0) }
    }

    /// 登录：账号密码存钥匙串；返回的 s 是会话 cookie（AVS），之后的请求都要带上
    @discardableResult
    static func login(username: String, password: String) async throws -> JMUser {
        let json = try await post("/login", form: ["username": username, "password": password], allowRelogin: false)
        guard let dict = json as? [String: Any] else { throw JMError.invalidData }
        let session = JSONValue.string(dict["s"])
        if !session.isEmpty { setSessionCookie(session) }
        let user = JMUser(
            uid: JSONValue.string(dict["uid"]),
            username: JSONValue.string(dict["username"]).isEmpty ? username : JSONValue.string(dict["username"]),
            photo: JSONValue.string(dict["photo"]),
            level: JSONValue.int(dict["level"]) ?? 0,
            levelName: JSONValue.string(dict["level_name"]),
            coin: JSONValue.string(dict["coin"]),
            favorites: JSONValue.int(dict["album_favorites"]) ?? 0,
            favoritesMax: JSONValue.int(dict["album_favorites_max"]) ?? 0
        )
        UserDefaults.standard.set(username, forKey: Key.username)
        UserDefaults.standard.set(try? JSONEncoder().encode(user), forKey: Key.user)
        Keychain.set(password, for: "jm:" + username)
        return user
    }

    /// 所有线路都带上会话 cookie（换线路后不用重新登录）
    private static func setSessionCookie(_ value: String) {
        for domain in domains {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain, .path: "/", .name: "AVS", .value: value, .secure: "TRUE",
                .expires: Date().addingTimeInterval(30 * 24 * 3600),
            ]
            if let cookie = HTTPCookie(properties: properties) { HTTPCookieStorage.shared.setCookie(cookie) }
        }
    }

    static func logout() {
        if let username { Keychain.delete("jm:" + username) }
        UserDefaults.standard.removeObject(forKey: Key.username)
        UserDefaults.standard.removeObject(forKey: Key.user)
        for domain in domains {
            for cookie in HTTPCookieStorage.shared.cookies(for: URL(string: "https://" + domain)!) ?? [] {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    // MARK: 云端收藏

    /// 收藏夹里的本子。sort：mr 收藏时间、mp 更新时间
    static func favorites(page: Int, folderID: String = "0", sort: String = "mr") async throws -> JMFavoritesPage {
        let json = try await get("/favorite", query: ["page": "\(page)", "folder_id": folderID, "o": sort])
        let dict = json as? [String: Any] ?? [:]
        let comics = (dict["list"] as? [[String: Any]] ?? []).compactMap(parseComic)
        let folders = (dict["folder_list"] as? [[String: Any]] ?? []).compactMap { item -> JMFolder? in
            let id = JSONValue.string(item["FID"])
            guard !id.isEmpty else { return nil }
            return JMFolder(id: id, name: JSONValue.string(item["name"]))
        }
        return JMFavoritesPage(comics: comics, folders: folders, total: JSONValue.int(dict["total"]) ?? comics.count)
    }

    /// 收藏 / 取消收藏。接口本身是切换，返回 type 说明这次是加入还是移除，和想要的不一致就再切一次
    static func setFavorite(_ id: String, _ favorite: Bool) async throws {
        func toggle() async throws -> Bool? {
            let json = try await post("/favorite", form: ["aid": id], allowRelogin: true)
            let dict = json as? [String: Any] ?? [:]
            let type = JSONValue.string(dict["type"]).lowercased()
            if type == "add" { return true }
            if type == "remove" { return false }
            let message = JSONValue.string(dict["msg"])
            if message.contains("移除") || message.contains("取消") { return false }
            if message.contains("加入") || message.contains("成功") { return true }
            return nil
        }
        let result = try await toggle()
        if let result, result != favorite { _ = try await toggle() }
    }

    /// 接口提示要登录时，用保存的账号重新登录一次
    private static func relogin() async -> Bool {
        guard let username, let password = Keychain.get("jm:" + username) else { return false }
        guard let user = try? await login(username: username, password: password) else { return false }
        await MainActor.run { JMAccount.shared.user = user }
        return true
    }

    // MARK: 请求

    private static var baseHeaders: [String: String] {
        [
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7",
            "Origin": "https://localhost",
            "Referer": "https://localhost/",
            "X-Requested-With": packageName,
        ]
    }

    /// 图片请求头（封面和内页都需要）
    static var imageHeaders: [String: String] {
        [
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            "Referer": "https://localhost/",
            "User-Agent": userAgent,
            "X-Requested-With": packageName,
        ]
    }

    static func isJMImage(_ url: URL) -> Bool {
        url.path.contains("/media/albums/") || url.path.contains("/media/photos/") || url.path.contains("/media/users/")
    }

    private static func get(_ path: String, query: [String: String]) async throws -> Any {
        try await send(path: path, query: query, form: nil, allowRelogin: true)
    }

    private static func post(_ path: String, form: [String: String], allowRelogin: Bool) async throws -> Any {
        try await send(path: path, query: [:], form: form, allowRelogin: allowRelogin)
    }

    private static func encode(_ pairs: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return pairs.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    /// 当前线路连不上时，依次换其它线路再试（成功的线路记下来）
    private static func send(path: String, query: [String: String], form: [String: String]?, allowRelogin: Bool) async throws -> Any {
        let all = domains
        let start = domainIndex
        var lastError: Error = JMError.invalidData
        for offset in 0..<all.count {
            let index = (start + offset) % all.count
            do {
                let result = try await request(domain: all[index], path: path, query: query, form: form)
                if offset > 0 { domainIndex = index }
                return result
            } catch JMError.loginRequired {
                if allowRelogin, await relogin() {
                    return try await send(path: path, query: query, form: form, allowRelogin: false)
                }
                throw JMError.loginRequired
            } catch let error as JMError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func request(domain: String, path: String, query: [String: String], form: [String: String]?) async throws -> Any {
        var urlString = "https://\(domain)\(path)"
        if !query.isEmpty { urlString += "?" + encode(query) }
        guard let url = URL(string: urlString) else { throw JMError.invalidData }
        let time = Int(Date().timeIntervalSince1970)
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (key, value) in baseHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("Bearer", forHTTPHeaderField: "Authorization")
        request.setValue(md5Hex("\(time)\(authKey)"), forHTTPHeaderField: "token")
        request.setValue("\(time),\(appVersion)", forHTTPHeaderField: "tokenparam")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let form {
            request.httpMethod = "POST"
            request.httpBody = Data(encode(form).utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await Net.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if status != 200 {
            let message = body.map { JSONValue.string($0["errorMsg"]) }
            if status == 401, message == "請先登入會員" { throw JMError.loginRequired }
            throw JMError.status(status, message?.isEmpty == false ? message : nil)
        }
        guard let encrypted = body?["data"] as? String else {
            if let message = body.map({ JSONValue.string($0["errorMsg"]) }), !message.isEmpty {
                throw JMError.status(status, message)
            }
            throw JMError.invalidData
        }
        return try decryptJSON(encrypted, secret: "\(time)\(dataSecret)")
    }

    // MARK: 加解密

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// base64 → AES-256-ECB 解密（密钥是 secret 的 MD5 十六进制串）→ 截取第一个 { / [ 到最后一个 } / ]
    static func decryptJSON(_ base64: String, secret: String) throws -> Any {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let plain = aesECBDecrypt(data, key: Data(md5Hex(secret).utf8)) else { throw JMError.invalidData }
        let text = String(decoding: plain, as: UTF8.self)
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }), start <= end else { throw JMError.invalidData }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) else { throw JMError.invalidData }
        return json
    }

    static func aesECBDecrypt(_ data: Data, key: Data) -> Data? {
        guard data.count % kCCBlockSizeAES128 == 0, key.count == kCCKeySizeAES256 else { return nil }
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count, nil,
                        input.baseAddress, data.count,
                        out.baseAddress, data.count, &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(moved)
    }

    // MARK: 解析

    static func parseComic(_ json: [String: Any]) -> JMComic? {
        let id = JSONValue.string(json["id"])
        guard !id.isEmpty else { return nil }
        var tags: [String] = []
        for key in ["category", "category_sub"] {
            let title = JSONValue.string((json[key] as? [String: Any])?["title"])
            if !title.isEmpty { tags.append(title) }
        }
        return JMComic(
            id: id,
            title: JSONValue.string(json["name"]),
            author: JSONValue.string(json["author"]),
            description: JSONValue.string(json["description"]),
            tags: tags
        )
    }

    private static func parsePage(_ json: Any) -> JMPage {
        let dict = json as? [String: Any] ?? [:]
        let list = (dict["content"] as? [[String: Any]]) ?? (dict["list"] as? [[String: Any]]) ?? []
        return JMPage(comics: list.compactMap(parseComic), total: JSONValue.int(dict["total"]) ?? 0, redirectID: nil)
    }

    // MARK: 内页图片还原

    /// 新一些的本子，内页图片被横向切成若干条并倒序排列，需要按本子号和文件名算出条数再拼回去
    static func sliceCount(chapterID: String, imageURL: String) -> Int {
        guard let id = Int(chapterID) else { return 0 }
        let fileName = (URL(string: imageURL)?.lastPathComponent ?? imageURL)
        if fileName.lowercased().hasSuffix(".gif") { return 0 }
        let name = (fileName as NSString).deletingPathExtension
        if id < 220_980 { return 0 }
        if id < 268_850 { return 10 }
        let hash = md5Hex("\(id)\(name)")
        let code = Int(hash.unicodeScalars.last?.value ?? 0)
        return id > 421_926 ? (code % 8) * 2 + 2 : (code % 10) * 2 + 2
    }

    static func descramble(_ image: UIImage, slices: Int) -> UIImage {
        guard slices > 1, let cg = image.cgImage else { return image }
        let width = cg.width, height = cg.height
        let block = height / slices, remainder = height % slices
        guard block > 0 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { _ in
            var y = 0
            for i in stride(from: slices - 1, through: 0, by: -1) {
                let start = i * block
                let sliceHeight = block + (i == slices - 1 ? remainder : 0)
                guard let piece = cg.cropping(to: CGRect(x: 0, y: start, width: width, height: sliceHeight)) else { continue }
                UIImage(cgImage: piece).draw(in: CGRect(x: 0, y: y, width: width, height: sliceHeight))
                y += sliceHeight
            }
        }
    }
}

/// 漫画内页加载：下载（URLCache 磁盘缓存）→ 按需还原切片 → 内存缓存
actor JMPageLoader {
    static let shared = JMPageLoader()

    private var inflight: [String: Task<UIImage?, Never>] = [:]

    func image(_ url: String, chapterID: String) async -> UIImage? {
        let key = url + "#jm"
        if let cached = ImageMemory.shared.image(key) { return cached }
        if let task = inflight[key] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let requestURL = URL(string: url) else { return nil }
            var request = URLRequest(url: requestURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            for (k, v) in JMClient.imageHeaders { request.setValue(v, forHTTPHeaderField: k) }
            guard let result = try? await URLSession.shared.data(for: request) else { return nil }
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 200
            guard status < 400, let raw = UIImage(data: result.0) else { return nil }
            let fixed = JMClient.descramble(raw, slices: JMClient.sliceCount(chapterID: chapterID, imageURL: url))
            return await fixed.byPreparingForDisplay() ?? fixed
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { ImageMemory.shared.store(image, for: key) }
        return image
    }

    func prefetch(_ urls: [String], chapterID: String) {
        for url in urls {
            Task { _ = await self.image(url, chapterID: chapterID) }
        }
    }
}

/// 极简钥匙串封装，只用来存禁漫账号密码
enum Keychain {
    static func set(_ value: String, for account: String) {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Astra",
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Astra",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Astra",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
