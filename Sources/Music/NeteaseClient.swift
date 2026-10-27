import Foundation

/// 网易云音乐账号接口：weapi / eapi 加密请求和 Cookie。实现参考 Kumone（LGPL-3.0）的网易云接口层。
/// 登录后的 Cookie（MUSIC_U、__csrf）存在系统钥匙串里。
enum NeteaseError: LocalizedError {
    case http(Int)
    case business(Int, String?)
    case needLogin
    case invalid

    var errorDescription: String? {
        switch self {
        case .http(let status): return "网络错误（\(status)）"
        case .business(let code, let message):
            if let message, !message.isEmpty { return message }
            return "网易云返回错误（\(code)）"
        case .needLogin: return "网易云登录已失效，请重新登录"
        case .invalid: return "网易云返回的数据无法解析"
        }
    }
}

final class NeteaseClient: @unchecked Sendable {
    static let shared = NeteaseClient()

    private static let keychainKey = "netease:cookies"
    /// 只有这几个 Cookie 需要存下来，其他的每次请求都会重新下发
    private static let persistedNames: Set<String> = ["MUSIC_U", "__csrf", "NMTID"]
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    // weapi：先用预置密钥、再用客户端密钥各做一次 AES-CBC。客户端密钥本该每次随机并用网易云的 RSA 公钥加密，
    // 密钥既然由我们选，就固定一个，RSA 的结果提前算好（不用在 App 里实现大数运算）
    private static let presetKey = Data("0CoJUm6Qyw8W8jud".utf8)
    private static let iv = Data("0102030405060708".utf8)
    private static let secretKey = Data("AstraMusic2026nE".utf8)
    private static let encSecKey =
        "63c33aaad4db87423234a2fd0483d6e72c561cc49359ef77ddb464a976f627b9" +
        "ceedd4229e258aa700ca5ce24e4bc070240b5f07fcbe0c6e2a6921d8b3757ee3" +
        "a345b5cffb5894573541e25924fbef477d805327047d6570f8811b2400a64dd4" +
        "36d2146ada18d7e897fa8f604a40c29d5a3b4db2f23912de3eb950814e86aaca"
    private static let eapiKey = Data("e82ckenh8dichen8".utf8)

    private let session: URLSession
    private let lock = NSLock()
    private var cookies: [String: String]

    private init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
        cookies = Keychain.get(Self.keychainKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
    }

    // MARK: Cookie

    var isLoggedIn: Bool { cookie("MUSIC_U") != nil }

    func cookie(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cookies[name]
    }

    /// 登录用的 Cookie（退出登录时带着它们通知服务器）
    var authCookies: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return cookies.filter { $0.key == "MUSIC_U" || $0.key == "__csrf" }
    }

    func setCookies(_ new: [String: String]) {
        lock.lock()
        var changed = false
        for (name, value) in new where cookies[name] != value {
            cookies[name] = value
            if Self.persistedNames.contains(name) { changed = true }
        }
        let snapshot = cookies.filter { Self.persistedNames.contains($0.key) }
        lock.unlock()
        if changed { persist(snapshot) }
    }

    func clearLogin() {
        lock.lock()
        cookies["MUSIC_U"] = nil
        cookies["__csrf"] = nil
        let snapshot = cookies.filter { Self.persistedNames.contains($0.key) }
        lock.unlock()
        persist(snapshot)
    }

    /// 粘贴的 Cookie：整段「MUSIC_U=…; __csrf=…」，或者只有 MUSIC_U 的值
    @discardableResult
    func importCookie(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed: [String: String] = [:]
        if text.contains("=") {
            for pair in text.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let name = pair[..<eq].trimmingCharacters(in: .whitespaces)
                let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !value.isEmpty { parsed[name] = value }
            }
        } else if !text.isEmpty {
            parsed["MUSIC_U"] = text
        }
        guard parsed["MUSIC_U"] != nil else { return false }
        setCookies(parsed)
        return true
    }

    private func persist(_ snapshot: [String: String]) {
        if snapshot.isEmpty {
            Keychain.delete(Self.keychainKey)
        } else if let data = try? JSONEncoder().encode(snapshot) {
            Keychain.set(String(decoding: data, as: UTF8.self), for: Self.keychainKey)
        }
    }

    private func cookieHeader(_ jar: [String: String]? = nil) -> String {
        var all: [String: String]
        if let jar {
            all = jar
        } else {
            lock.lock()
            all = cookies
            lock.unlock()
        }
        all["os"] = all["os"] ?? "pc"
        all["appver"] = all["appver"] ?? "3.1.17"
        return all.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func absorbCookies(_ response: HTTPURLResponse) {
        guard let url = response.url, let fields = response.allHeaderFields as? [String: String] else { return }
        var new: [String: String] = [:]
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        where !cookie.value.isEmpty && cookie.value != "\"\"" {
            new[cookie.name] = cookie.value
        }
        if !new.isEmpty { setCookies(new) }
    }

    // MARK: 请求

    /// POST https://music.163.com/weapi{path}。check 为 true 时 code 不是 200 就抛错；
    /// jar 用来指定这次请求带的 Cookie（退出登录时用），这时也不接收返回的 Cookie
    func weapi(_ path: String, _ payload: [String: Any] = [:], check: Bool = true,
               jar: [String: String]? = nil) async throws -> [String: Any] {
        let csrf = jar?["__csrf"] ?? cookie("__csrf") ?? ""
        var body = payload
        body["csrf_token"] = csrf
        let json = try JSONSerialization.data(withJSONObject: body)
        let first = aes(json, key: Self.presetKey, cbc: true).base64EncodedData()
        let params = aes(first, key: Self.secretKey, cbc: true).base64EncodedString()

        var fullPath = path
        if !csrf.isEmpty { fullPath += (path.contains("?") ? "&" : "?") + "csrf_token=" + csrf }
        guard let url = URL(string: "https://music.163.com/weapi" + fullPath) else { throw NeteaseError.invalid }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader(jar), forHTTPHeaderField: "Cookie")
        request.httpBody = Self.form(["params": params, "encSecKey": Self.encSecKey])
        let object = try await send(request, absorb: jar == nil)
        return check ? try Self.check(object) : object
    }

    /// POST https://interface.music.163.com/eapi{path}，签名按对应的 /api{path} 计算
    func eapi(_ path: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        let apiPath = "/api" + path
        var header: [String: String] = [
            "os": "pc", "appver": "3.1.17", "osver": "Version 14.0", "deviceId": "astra",
            "requestId": String(Int.random(in: 20_000_000...30_000_000)), "clientSign": "",
            "versioncode": "140", "buildver": String(Int(Date().timeIntervalSince1970)),
            "resolution": "1920x1080", "channel": "",
        ]
        if let musicU = cookie("MUSIC_U") { header["MUSIC_U"] = musicU }
        if let csrf = cookie("__csrf") { header["__csrf"] = csrf }
        var body = payload
        body["header"] = header
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let digest = EngineCrypto.md5Hex("nobody\(apiPath)use\(text)md5forencrypt")
        let message = "\(apiPath)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        let params = EngineCrypto.hex(aes(Data(message.utf8), key: Self.eapiKey, cbc: false)).uppercased()

        guard let url = URL(string: "https://interface.music.163.com/eapi" + path) else { throw NeteaseError.invalid }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        request.httpBody = Self.form(["params": params])
        return try Self.check(try await send(request, absorb: true))
    }

    private func send(_ request: URLRequest, absorb: Bool) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NeteaseError.http(-1) }
        if absorb { absorbCookies(http) }
        guard (200..<300).contains(http.statusCode) else {
            Diag.log("网易云", "HTTP \(http.statusCode) \(request.url?.path ?? "")")
            throw NeteaseError.http(http.statusCode)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NeteaseError.invalid
        }
        return object
    }

    static func code(_ object: [String: Any]) -> Int {
        (object["code"] as? NSNumber)?.intValue ?? Int(RuleValue.string(object["code"])) ?? 200
    }

    private static func check(_ object: [String: Any]) throws -> [String: Any] {
        let status = Self.code(object)
        guard status == 200 else {
            if status == 301 { throw NeteaseError.needLogin }
            Diag.log("网易云", "接口返回 \(status) \(RuleValue.string(object["message"] ?? object["msg"]))")
            throw NeteaseError.business(status, (object["message"] as? String) ?? (object["msg"] as? String))
        }
        return object
    }

    private func aes(_ data: Data, key: Data, cbc: Bool) -> Data {
        EngineCrypto.symmetric(data, transformation: cbc ? "AES/CBC/PKCS5Padding" : "AES/ECB/PKCS5Padding",
                               key: key, iv: cbc ? Self.iv : nil, encrypt: true) ?? Data()
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }
}

// MARK: - 接口

struct NeteaseProfile: Codable, Hashable, Sendable {
    var userId: Int
    var nickname: String
    var avatarUrl: String
    var signature: String
    var vipType: Int
}

struct NeteasePlaylist: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var cover: String
    var trackCount: Int
    var creatorId: Int
    /// 5 是「我喜欢的音乐」
    var specialType: Int
}

enum NeteaseAPI {
    private static var client: NeteaseClient { .shared }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? Int(RuleValue.string(value)) ?? 0
    }

    private static func https(_ url: String) -> String {
        url.replacingOccurrences(of: "http://", with: "https://")
    }

    // MARK: 登录

    static func qrKey() async throws -> String {
        let result = try await client.weapi("/login/qrcode/unikey", ["type": 1])
        let key = RuleValue.string(result["unikey"])
        guard !key.isEmpty else { throw NeteaseError.invalid }
        return key
    }

    static func qrURL(_ key: String) -> String {
        "https://music.163.com/login?codekey=" + key
    }

    /// 800 二维码过期 · 801 等待扫码 · 802 已扫码待确认 · 803 登录成功（Cookie 在返回头里，已经收下）
    static func qrCheck(_ key: String) async throws -> (code: Int, message: String) {
        let result = try await client.weapi("/login/qrcode/client/login", ["key": key, "type": 1], check: false)
        return (NeteaseClient.code(result), RuleValue.string(result["message"]))
    }

    static func sendCode(phone: String, country: String) async throws {
        _ = try await client.weapi("/sms/captcha/sent", [
            "ctcode": country, "cellphone": phone, "secrete": "music_middleuser_pclogin",
        ])
    }

    static func login(phone: String, code: String, country: String) async throws {
        _ = try await client.weapi("/w/login/cellphone", [
            "type": "1", "https": "true", "phone": phone, "countrycode": country,
            "captcha": code, "remember": "true", "secureCaptcha": "",
        ])
        guard client.isLoggedIn else { throw NeteaseError.business(-1, "登录失败，请重试") }
    }

    static func logout(_ jar: [String: String]) async {
        _ = try? await client.weapi("/logout", jar: jar)
    }

    static func refreshToken() async {
        _ = try? await client.weapi("/login/token/refresh")
    }

    static func account() async throws -> NeteaseProfile {
        let result = try await client.weapi("/w/nuser/account/get")
        guard let profile = result["profile"] as? [String: Any], int(profile["userId"]) > 0 else {
            throw NeteaseError.needLogin
        }
        return NeteaseProfile(
            userId: int(profile["userId"]),
            nickname: RuleValue.string(profile["nickname"]),
            avatarUrl: https(RuleValue.string(profile["avatarUrl"])),
            signature: RuleValue.string(profile["signature"]),
            vipType: int(profile["vipType"])
        )
    }

    // MARK: 曲库

    static func playlists(uid: Int) async throws -> [NeteasePlaylist] {
        let result = try await client.weapi("/user/playlist", ["uid": uid, "limit": 1000, "offset": 0, "includeVideo": true])
        return (result["playlist"] as? [[String: Any]] ?? []).map { item in
            let creator = item["creator"] as? [String: Any]
            return NeteasePlaylist(
                id: int(item["id"]),
                name: RuleValue.string(item["name"]),
                cover: https(RuleValue.string(item["coverImgUrl"] ?? item["picUrl"])),
                trackCount: int(item["trackCount"]),
                creatorId: int(creator?["userId"] ?? item["userId"]),
                specialType: int(item["specialType"])
            )
        }
    }

    static func likedIDs(uid: Int) async throws -> [Int] {
        let result = try await client.weapi("/song/like/get", ["uid": uid])
        return (result["ids"] as? [Any] ?? []).map { int($0) }.filter { $0 > 0 }
    }

    static func like(_ id: Int, _ like: Bool) async throws {
        _ = try await client.weapi("/radio/like?alg=itembased&trackId=\(id)&time=3", ["trackId": id, "like": like])
    }

    /// 按 id 取歌曲详情（每次最多 500 首），顺序和传入的一致
    static func songs(_ ids: [Int]) async throws -> [MusicTrack] {
        var tracks: [Int: MusicTrack] = [:]
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + 500, ids.count)])
            start += 500
            let c = "[" + batch.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
            let result = try await client.weapi("/v3/song/detail", ["c": c])
            var privileges: [Int: [String: Any]] = [:]
            for privilege in result["privileges"] as? [[String: Any]] ?? [] {
                privileges[int(privilege["id"])] = privilege
            }
            for var song in result["songs"] as? [[String: Any]] ?? [] {
                let id = int(song["id"])
                if song["privilege"] == nil, let privilege = privileges[id] { song["privilege"] = privilege }
                if let track = MusicPlatformAPI.wyTrack(song) { tracks[id] = track }
            }
        }
        return ids.compactMap { tracks[$0] }
    }

    static func playlistTracks(_ id: Int) async throws -> [MusicTrack] {
        let result = try await client.weapi("/v6/playlist/detail", ["id": id, "n": 100_000, "s": 8])
        let playlist = result["playlist"] as? [String: Any] ?? [:]
        let ids = (playlist["trackIds"] as? [[String: Any]] ?? []).map { int($0["id"]) }.filter { $0 > 0 }
        if ids.isEmpty {
            return (playlist["tracks"] as? [[String: Any]] ?? []).compactMap(MusicPlatformAPI.wyTrack)
        }
        return try await songs(ids)
    }

    static func dailySongs() async throws -> [MusicTrack] {
        let result = try await client.weapi("/v3/discovery/recommend/songs")
        let data = result["data"] as? [String: Any]
        return (data?["dailySongs"] as? [[String: Any]] ?? []).compactMap(MusicPlatformAPI.wyTrack)
    }

    /// 用账号取播放地址。只给试听片段（没有版权或需要单曲购买）时返回 nil
    static func songURL(_ id: Int, level: String) async throws -> String? {
        var payload: [String: Any] = ["ids": "[\(id)]", "level": level, "encodeType": "flac"]
        if level == "sky" { payload["immerseType"] = "c51" }
        let result = try await client.eapi("/song/enhance/player/url/v1", payload)
        guard let item = (result["data"] as? [[String: Any]])?.first else { return nil }
        let url = RuleValue.string(item["url"])
        if url.isEmpty { return nil }
        if let trial = item["freeTrialInfo"], !(trial is NSNull) { return nil }
        return url
    }
}
