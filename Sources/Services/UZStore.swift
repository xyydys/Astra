import Foundation
import SwiftUI

/// uz 影视扩展：订阅、脚本、网盘账号（环境变量）、扩展自己存的数据，以及搜索 / 详情 / 播放地址的转换。
/// 视频源扩展（type 101）在影视模式里和采集站一起当片源用，接口地址记作 uz://<扩展 id>；
/// 详情里的网盘分享链接交给网盘工具扩展（type 300）展开成剧集，播放时再换成真实地址。
@MainActor
final class UZStore: ObservableObject {
    static let shared = UZStore()

    struct Extension: Codable, Hashable, Identifiable {
        /// 也是扩展的 uzTag
        var id: String
        var name: String
        var type: Int
        var version: Int = 0
        var webSite: String = ""
        var remark: String = ""
        var env: String = ""
        var isAV = false
        /// uz 影视私有加密的扩展，只有 uz 影视能运行
        var encrypted = false
        var enabled = true
        /// 脚本来源（订阅地址或脚本地址），更新时用
        var origin: String = ""

        var isVod: Bool { type == 100 || type == 101 }
        var isPan: Bool { type == 300 }
        var usable: Bool { !encrypted && (isVod || isPan) }
    }

    struct Subscription: Codable, Hashable, Identifiable {
        var url: String
        var updatedAt: Date
        var id: String { url }
    }

    /// 网盘账号里用网页登录取 Cookie 的几家
    struct WebLogin: Identifiable, Hashable {
        var name: String
        var envKey: String
        var url: String
        var domains: [String]
        /// 登录后才有的 Cookie（有其中一个才算登录了；没登录时网站也会发一些 Cookie）
        var loginKeys: [String]
        var id: String { envKey }

        func hasLogin(_ cookie: String) -> Bool {
            let names = Set(cookie.components(separatedBy: ";").compactMap { part -> String? in
                let name = part.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
                return name?.isEmpty == false ? name : nil
            })
            return loginKeys.contains { names.contains($0) }
        }
    }

    static let webLogins: [WebLogin] = [
        WebLogin(name: "夸克网盘", envKey: "夸克Cookie", url: "https://pan.quark.cn/", domains: ["quark.cn"], loginKeys: ["__pus", "__puus"]),
        WebLogin(name: "UC 网盘", envKey: "UCCookie", url: "https://drive.uc.cn/", domains: ["uc.cn"], loginKeys: ["__pus", "__puus"]),
        WebLogin(name: "115 网盘", envKey: "115Cookie", url: "https://115.com/", domains: ["115.com"], loginKeys: ["UID", "CID"]),
        WebLogin(name: "百度网盘", envKey: "百度网盘Cookie", url: "https://pan.baidu.com/", domains: ["baidu.com"], loginKeys: ["BDUSS"]),
    ]

    enum LoginState {
        case none
        /// 存了 Cookie 但里面没有登录信息（打开登录页没登录就点了完成之类）
        case incomplete
        case ok
    }

    func loginState(_ login: WebLogin) -> LoginState {
        let cookie = env[login.envKey] ?? ""
        if cookie.isEmpty { return .none }
        return login.hasLogin(cookie) ? .ok : .incomplete
    }

    static let officialSubscription = "https://github.com/YYDS678/uzVideo-extensions/releases/download/uzVideo-Extensions-main/uzAio.zip"

    /// uz 扩展仓库（基础库和未加密的网盘工具从这里下载），GitHub 不通时依次换镜像
    static let repoMirrors = [
        "https://raw.githubusercontent.com/YYDS678/uzVideo-extensions/main/",
        "https://cdn.jsdelivr.net/gh/YYDS678/uzVideo-extensions@main/",
        "https://fastly.jsdelivr.net/gh/YYDS678/uzVideo-extensions@main/",
        "https://ghfast.top/https://raw.githubusercontent.com/YYDS678/uzVideo-extensions/main/",
    ]
    /// 仓库历史里最后一个没有加密的网盘工具（v40「夸克不转存」版，2026-04 之后改成了加密版），按提交固定
    static let panToolsCommit = "49ca13990b0517e096d7e66de09e1a49c17d5a98"
    static let panToolsPath = "panTools/js/panTools3.js"
    static let panToolsID = "uz_panTools3"
    /// 之前用过的公开版本（v39），装了新版后删掉
    static let legacyPanToolsIDs = ["uz_panTools2"]
    static var panToolsMirrors: [String] {
        [
            "https://raw.githubusercontent.com/YYDS678/uzVideo-extensions/\(panToolsCommit)/",
            "https://cdn.jsdelivr.net/gh/YYDS678/uzVideo-extensions@\(panToolsCommit)/",
            "https://fastly.jsdelivr.net/gh/YYDS678/uzVideo-extensions@\(panToolsCommit)/",
            "https://ghfast.top/https://raw.githubusercontent.com/YYDS678/uzVideo-extensions/\(panToolsCommit)/",
        ]
    }
    static let coreFiles = [
        "CryptoJS.min.js", "JSEncrypt.min.js", "JSONbig.js", "buffer.js", "cheerio.js",
        "node-html-parser.js", "uz3lib.js", "uzUtils.js", "uzVideo.js",
    ]

    @Published private(set) var extensions: [Extension] = []
    @Published private(set) var subscriptions: [Subscription] = []
    /// 扩展弹出的提示（toast）
    @Published var notice: String?
    /// 环境变量（网盘 Cookie、账号等），存在钥匙串里
    @Published private(set) var env: [String: String] = [:]
    @Published private(set) var working = false

    private var runtime: UZRuntime?
    private var starting: Task<UZRuntime, Error>?
    private var installing: [String: Task<Void, Error>] = [:]
    private var searchCache: [String: (date: Date, items: [CMSItem])] = [:]
    private var detailCache: [String: (date: Date, item: CMSItem)] = [:]

    private static let envKeychainKey = "uz:env"
    private nonisolated static let storageLock = NSLock()
    private nonisolated(unsafe) static var storageCache: [String: String]?
    private nonisolated(unsafe) static var verifyCookies: [String: String] = [:]
    private nonisolated(unsafe) static var envSnapshot: [String: String] = [:]

    private init() {
        load()
    }

    // MARK: 文件

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("uz", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static func folder(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static func scriptURL(_ id: String) -> URL {
        folder("scripts").appendingPathComponent(id + ".js")
    }

    private struct Snapshot: Codable {
        var extensions: [Extension]
        var subscriptions: [Subscription]
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.directory.appendingPathComponent("extensions.json")),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            extensions = snapshot.extensions
            subscriptions = snapshot.subscriptions
        }
        if let raw = Keychain.get(Self.envKeychainKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) {
            env = dict
        }
        Self.replaceEnvSnapshot(env)
    }

    private func save() {
        let snapshot = Snapshot(extensions: extensions, subscriptions: subscriptions)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.directory.appendingPathComponent("extensions.json"), options: .atomic)
        }
    }

    // MARK: 环境变量 / 存储

    /// fromScript：扩展自己写的（比如刷新 Cookie）；不是的话说明账号变了，网盘工具里缓存的 Cookie / Token 要重新读
    func setEnv(_ key: String, _ value: String, fromScript: Bool = false) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard env[key] != (trimmed.isEmpty ? nil : trimmed) else { return }
        if trimmed.isEmpty { env[key] = nil } else { env[key] = trimmed }
        if !fromScript, runtime != nil || starting != nil { resetRuntime() }
        Self.replaceEnvSnapshot(env)
        if let data = try? JSONEncoder().encode(env) {
            Keychain.set(String(decoding: data, as: UTF8.self), for: Self.envKeychainKey)
        }
    }

    /// 已安装扩展声明的环境变量（名称 → 说明），按出现顺序
    var declaredEnv: [(key: String, desc: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for ext in extensions where ext.usable {
            for item in ext.env.components(separatedBy: "&&") {
                let parts = item.components(separatedBy: "##")
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                result.append((key, parts.count > 1 ? parts[1] : ""))
            }
        }
        return result
    }

    private nonisolated static var storageURL: URL { directory.appendingPathComponent("storage.json") }

    nonisolated static func storage(_ key: String) -> String {
        storageLock.lock()
        defer { storageLock.unlock() }
        if storageCache == nil {
            storageCache = (try? Data(contentsOf: storageURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        }
        return storageCache?[key] ?? ""
    }

    nonisolated static func setStorage(_ key: String, _ value: String) {
        storageLock.lock()
        if storageCache == nil {
            storageCache = (try? Data(contentsOf: storageURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        }
        storageCache?[key] = value
        let snapshot = storageCache ?? [:]
        storageLock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// 网页验证（goToVerify）后拿到的 Cookie，之后请求这个站点时自动带上
    nonisolated static func setVerifyCookie(host: String, cookie: String) {
        storageLock.lock()
        verifyCookies[host] = cookie
        storageLock.unlock()
    }

    private nonisolated static func verifyCookie(host: String) -> String? {
        storageLock.lock()
        defer { storageLock.unlock() }
        return verifyCookies[host]
    }

    private nonisolated static func envValue(_ key: String) -> String {
        storageLock.lock()
        defer { storageLock.unlock() }
        return envSnapshot[key] ?? ""
    }

    private nonisolated static func replaceEnvSnapshot(_ env: [String: String]) {
        storageLock.lock()
        envSnapshot = env
        storageLock.unlock()
    }

    /// 扩展写环境变量：先改快照（紧接着的读取能读到），再回主线程保存
    private nonisolated static func scriptSetEnv(_ key: String, _ value: String) {
        storageLock.lock()
        envSnapshot[key] = value.isEmpty ? nil : value
        storageLock.unlock()
        Task { @MainActor in UZStore.shared.setEnv(key, value, fromScript: true) }
    }

    // MARK: 运行环境

    private func ensureRuntime() async throws -> UZRuntime {
        if let runtime { return runtime }
        if let starting { return try await starting.value }
        let task = Task<UZRuntime, Error> {
            let core = try await Self.loadCore()
            let host = UZRuntime.Host(
                getEnv: { key in UZStore.envValue(key) },
                setEnv: { key, value in UZStore.scriptSetEnv(key, value) },
                getStorage: { key in UZStore.storage(key) },
                setStorage: { key, value in UZStore.setStorage(key, value) },
                cookie: { host in UZStore.verifyCookie(host: host) },
                toast: { message in Task { @MainActor in UZStore.shared.notice = message } },
                verify: { url, _ in Task { @MainActor in UZStore.shared.verifyRequest = url } }
            )
            let runtime = UZRuntime(core: core, host: host)
            try await runtime.start()
            return runtime
        }
        starting = task
        do {
            let runtime = try await task.value
            self.runtime = runtime
            starting = nil
            return runtime
        } catch {
            starting = nil
            throw error
        }
    }

    /// 扩展请求网页验证时要打开的地址（界面上弹出网页）
    @Published var verifyRequest: String?

    var runtimeLogs: [String] { runtime?.recentLogs ?? [] }

    /// 更新扩展后丢掉旧的运行环境，下次用到时重新载入
    private func resetRuntime() {
        runtime = nil
        starting = nil
        installing = [:]
        searchCache = [:]
        detailCache = [:]
    }

    /// 载入扩展脚本到运行环境（每个扩展只载入一次）
    private func prepare(_ ext: Extension) async throws -> UZRuntime {
        let runtime = try await ensureRuntime()
        if let task = installing[ext.id] {
            try await task.value
            return runtime
        }
        let task = Task<Void, Error> {
            guard let raw = try? String(contentsOf: Self.scriptURL(ext.id), encoding: .utf8) else {
                throw UZError.message("「\(ext.name)」的脚本不见了，重新导入一下订阅")
            }
            try await runtime.install(tag: ext.id, name: ext.name, script: UZPrelude.strip(Self.patchScript(raw)))
        }
        installing[ext.id] = task
        do {
            try await task.value
        } catch {
            installing[ext.id] = nil
            throw error
        }
        return runtime
    }

    /// 给网盘工具打的补丁（找不到对应代码就原样不动）
    nonisolated static func patchScript(_ raw: String) -> String {
        var script = raw
        // 百度原画直链：每个分享要用自己的 BDCLND（提取码验证后得到）。原脚本用的是 Cookie 里最后一次验证的那个，
        // 搜索时验证过好几个百度分享，播放前面那个分享的文件就会返回 errno -9
        let baiduAnchor = "const response = await this.api(apiPath, {}, headers, 'get')"
        if script.contains("getDirectPlayUrl(uk, shareid, fsid, randsk)"), script.components(separatedBy: baiduAnchor).count == 2 {
            script = script.replacingOccurrences(of: baiduAnchor, with: """
            const shareCookie = (this.cookie || '').replace(/BDCLND=[^;]*;?\\s*/g, '').replace(/[;\\s]+$/, '') + (randsk ? '; BDCLND=' + randsk : '')
                        const response = (await axios.get(this.apiUrl + apiPath, { headers: { ...this.baseHeader, ...headers, Cookie: shareCookie } })).data
            """)
        }
        return script
    }

    /// 基础库：第一次用时从 uz 扩展仓库下载，之后用缓存
    private nonisolated static func loadCore() async throws -> String {
        let folder = folder("core")
        var parts: [String] = []
        for file in coreFiles {
            let local = folder.appendingPathComponent(file)
            if let cached = try? String(contentsOf: local, encoding: .utf8), !cached.isEmpty {
                parts.append(UZPrelude.strip(cached))
                continue
            }
            let data = try await downloadFromRepo("core/core/" + file)
            try? data.write(to: local, options: .atomic)
            parts.append(UZPrelude.strip(String(decoding: data, as: UTF8.self)))
        }
        return parts.joined(separator: "\n;\n")
    }

    /// 重新下载基础库（仓库更新了或者缓存损坏时）
    func refreshCore() async throws {
        let folder = Self.folder("core")
        for file in Self.coreFiles {
            let data = try await Self.downloadFromRepo("core/core/" + file)
            try data.write(to: folder.appendingPathComponent(file), options: .atomic)
        }
        resetRuntime()
    }

    private nonisolated static func downloadFromRepo(_ path: String, mirrors: [String] = repoMirrors) async throws -> Data {
        var lastError: Error = UZError.message("下载失败")
        for mirror in mirrors {
            do {
                return try await download(mirror + path)
            } catch {
                lastError = error
            }
        }
        throw UZError.message("下载 \(path) 失败：\(lastError.localizedDescription)")
    }

    private nonisolated static func download(_ url: String) async throws -> Data {
        guard let target = URL.lenient(url) else { throw UZError.message("地址无效：\(url)") }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue(UZRuntime.defaultUA, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UZError.message("服务器返回 \(http.statusCode)")
        }
        return data
    }

    // MARK: 订阅

    struct ImportResult {
        var added = 0
        var updated = 0
        var encrypted = 0
        var cms: [CMSSource] = []
    }

    /// 导入订阅：uz 的 uzAio.zip、uzAio.json / local.json，或者单个扩展脚本的地址 / 内容
    func importSubscription(_ input: String) async throws -> ImportResult {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw UZError.message("请输入订阅地址") }
        working = true
        defer { working = false }
        let isURL = text.lowercased().hasPrefix("http")
        let data: Data
        if isURL {
            data = try await Self.download(text)
        } else {
            data = Data(text.utf8)
        }
        let origin = isURL ? text : ""
        var result: ImportResult

        if let zip = ZipArchive(data) {
            result = try await importZip(zip, origin: origin)
        } else if let json = try? JSONSerialization.jsonObject(with: data) {
            result = try await importJSON(json, base: isURL ? text : "", origin: origin)
        } else {
            let script = String(decoding: data, as: UTF8.self)
            guard script.contains("function") || script.contains("class ") else {
                throw UZError.message("没有识别到 uz 订阅或扩展脚本")
            }
            let name = isURL ? (URL(string: text)?.deletingPathExtension().lastPathComponent ?? "扩展") : "扩展"
            let entry = Self.entry(fromScript: script, fallbackName: name, api: text)
            result = ImportResult()
            install(entry, script: script, origin: text, into: &result)
        }
        if !origin.isEmpty {
            subscriptions.removeAll { $0.url == origin }
            subscriptions.append(Subscription(url: origin, updatedAt: Date()))
        }
        try await ensurePanTools()
        // 网盘工具转存文件用的文件夹，默认叫 Astra（不设的话网盘工具会用「uz影视」）
        if env["转存文件夹名称"] == nil { setEnv("转存文件夹名称", "Astra") }
        save()
        resetRuntime()
        return result
    }

    func updateSubscriptions() async throws -> ImportResult {
        var total = ImportResult()
        for subscription in subscriptions {
            let result = try await importSubscription(subscription.url)
            total.added += result.added
            total.updated += result.updated
            total.encrypted += result.encrypted
            total.cms += result.cms
        }
        return total
    }

    func removeSubscription(_ url: String) {
        subscriptions.removeAll { $0.url == url }
        let removed = extensions.filter { $0.origin == url }
        extensions.removeAll { $0.origin == url }
        for ext in removed { try? FileManager.default.removeItem(at: Self.scriptURL(ext.id)) }
        save()
        resetRuntime()
    }

    private func importZip(_ zip: ZipArchive, origin: String) async throws -> ImportResult {
        guard let listData = zip.file("local.json") ?? zip.file("uzAio_raw.json") ?? zip.file("uzAio.json"),
              let list = try? JSONSerialization.jsonObject(with: listData) else {
            throw UZError.message("压缩包里没有 local.json")
        }
        var result = ImportResult()
        for item in Self.flatten(list) {
            let api = RuleValue.string(item["api"])
            let type = JSONValue.int(item["type"]) ?? 0
            if type == 0, CMSSource.isValidURL(api) {
                result.cms.append(CMSSource(name: RuleValue.string(item["name"]), url: api))
                continue
            }
            guard [100, 101, 300].contains(type) else { continue }
            let entry = Self.entry(fromMeta: item)
            if entry.encrypted {
                install(entry, script: nil, origin: origin, into: &result)
                continue
            }
            if let local = zip.file(api) {
                let script = String(decoding: local, as: UTF8.self)
                install(entry, script: script, origin: origin, into: &result)
            } else if api.lowercased().hasPrefix("http"), let remote = try? await Self.download(api) {
                install(entry, script: String(decoding: remote, as: UTF8.self), origin: origin, into: &result)
            } else {
                Diag.log("网盘扩展", "订阅里找不到 \(api)")
            }
        }
        return result
    }

    private func importJSON(_ json: Any, base: String, origin: String) async throws -> ImportResult {
        var result = ImportResult()
        let items = Self.flatten(json)
        guard !items.isEmpty else { throw UZError.message("订阅里没有扩展") }
        for item in items {
            var api = RuleValue.string(item["api"])
            let type = JSONValue.int(item["type"]) ?? 0
            if type == 0, CMSSource.isValidURL(api) {
                result.cms.append(CMSSource(name: RuleValue.string(item["name"]), url: api))
                continue
            }
            guard [100, 101, 300].contains(type) else { continue }
            let entry = Self.entry(fromMeta: item)
            if entry.encrypted {
                install(entry, script: nil, origin: origin, into: &result)
                continue
            }
            if !api.lowercased().hasPrefix("http"), let baseURL = URL(string: base) {
                api = URL(string: api, relativeTo: baseURL)?.absoluteString ?? api
            }
            guard let data = try? await Self.download(api) else {
                Diag.log("网盘扩展", "下载失败 \(api)")
                continue
            }
            install(entry, script: String(decoding: data, as: UTF8.self), origin: origin, into: &result)
        }
        return result
    }

    /// uzAio.json 是 {panTools: [...], vod: [...]}；local.json 是数组
    private nonisolated static func flatten(_ json: Any) -> [[String: Any]] {
        if let array = json as? [[String: Any]] { return array }
        if let object = json as? [String: Any] {
            return ["panTools", "vod", "danMu", "recommend", "live"].flatMap { object[$0] as? [[String: Any]] ?? [] }
        }
        return []
    }

    private nonisolated static func entry(fromMeta item: [String: Any]) -> Extension {
        let api = RuleValue.string(item["api"])
        let name = RuleValue.string(item["name"])
        let codeID = RuleValue.string(item["codeID"])
        return Extension(
            id: extensionID(api: api, name: name),
            name: name.isEmpty ? (URL(string: api)?.deletingPathExtension().lastPathComponent ?? "扩展") : name,
            type: JSONValue.int(item["type"]) ?? 101,
            version: JSONValue.int(item["version"]) ?? 0,
            webSite: RuleValue.string(item["webSite"]),
            remark: RuleValue.string(item["remark"]),
            env: RuleValue.string(item["env"]),
            isAV: (JSONValue.int(item["isAV"]) ?? 0) == 1 || (item["isAV"] as? Bool) == true,
            encrypted: !codeID.isEmpty
        )
    }

    /// 单个脚本：读开头 //@name: 之类的注释
    private nonisolated static func entry(fromScript script: String, fallbackName: String, api: String) -> Extension {
        var meta: [String: String] = [:]
        for line in script.split(separator: "\n").prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//@"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<colon])
            meta[key] = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let isPan = script.contains("uzPanToolsInstance")
        let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return Extension(
            id: extensionID(api: api, name: name), name: name, type: isPan ? 300 : 101,
            version: Int(meta["version"] ?? "") ?? 0, webSite: meta["webSite"] ?? "", remark: meta["remark"] ?? "",
            env: meta["env"] ?? "", isAV: meta["isAV"] == "1", encrypted: !(meta["codeID"] ?? "").isEmpty
        )
    }

    /// 扩展 id：用脚本文件名（Pan_wogg），同一个扩展更新后 id 不变
    private nonisolated static func extensionID(api: String, name: String) -> String {
        let file = URL(string: api)?.deletingPathExtension().lastPathComponent ?? ""
        let base = file.isEmpty ? name : file
        let cleaned = base.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" ? String($0) : "_" }.joined()
        let stable = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return "uz_" + (cleaned.isEmpty ? String(stable) : cleaned)
    }

    private func install(_ entry: Extension, script: String?, origin: String, into result: inout ImportResult) {
        var entry = entry
        entry.origin = origin.isEmpty ? entry.origin : origin
        // 文件里是 uz 加密过的内容（不是 JS）也算加密
        if let script, !Self.looksLikeScript(script) { entry.encrypted = true }
        if entry.encrypted { result.encrypted += 1 }
        if let script, !entry.encrypted {
            try? script.write(to: Self.scriptURL(entry.id), atomically: true, encoding: .utf8)
        }
        if let index = extensions.firstIndex(where: { $0.id == entry.id }) {
            entry.enabled = extensions[index].enabled && !entry.encrypted
            extensions[index] = entry
            result.updated += 1
        } else {
            entry.enabled = !entry.encrypted && !entry.isAV
            extensions.append(entry)
            result.added += 1
        }
    }

    private nonisolated static func looksLikeScript(_ text: String) -> Bool {
        text.contains("function") || text.contains("class ") || text.contains("=>")
    }

    /// 没有可用的网盘工具时（订阅里的是加密版），或者装的还是旧的公开版，换成最后一个公开版本
    private func ensurePanTools() async throws {
        let usable = extensions.filter { $0.isPan && !$0.encrypted }
        if !usable.isEmpty, !usable.allSatisfy({ Self.legacyPanToolsIDs.contains($0.id) }) { return }
        try await updatePanTools()
    }

    func updatePanTools() async throws {
        let data = try await Self.downloadFromRepo(Self.panToolsPath, mirrors: Self.panToolsMirrors)
        let script = String(decoding: data, as: UTF8.self)
        var entry = Self.entry(fromScript: script, fallbackName: "网盘工具", api: Self.panToolsPath)
        entry.id = Self.panToolsID
        entry.type = 300
        entry.origin = Self.panToolsMirrors[0] + Self.panToolsPath
        var result = ImportResult()
        install(entry, script: script, origin: entry.origin, into: &result)
        for id in Self.legacyPanToolsIDs {
            extensions.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: Self.scriptURL(id))
        }
        save()
        resetRuntime()
    }

    /// 已经装了旧公开版（v39）的，第一次用到网盘时自动换成 v40
    private func upgradeLegacyPanTools() async {
        guard extensions.contains(where: { Self.legacyPanToolsIDs.contains($0.id) }),
              !extensions.contains(where: { $0.id == Self.panToolsID }) else { return }
        do {
            try await updatePanTools()
        } catch {
            Diag.log("网盘扩展", "升级网盘工具失败：\(error.localizedDescription)")
        }
    }

    // MARK: 管理

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = extensions.firstIndex(where: { $0.id == id }), extensions[index].usable else { return }
        extensions[index].enabled = enabled
        save()
    }

    func remove(_ id: String) {
        extensions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.scriptURL(id))
        save()
        resetRuntime()
    }

    func move(from source: IndexSet, to destination: Int, in ids: [String]) {
        var ordered = ids
        ordered.move(fromOffsets: source, toOffset: destination)
        let rest = extensions.filter { !ordered.contains($0.id) }
        extensions = ordered.compactMap { id in extensions.first { $0.id == id } } + rest
        save()
    }

    var vodExtensions: [Extension] { extensions.filter(\.isVod) }

    /// 用版本最新的可用网盘工具
    var panTools: Extension? {
        extensions.filter { $0.isPan && $0.usable && $0.enabled }.max { $0.version < $1.version }
    }

    /// 影视模式里当片源用的扩展（接口地址 uz://id）
    var vodSources: [CMSSource] {
        extensions
            .filter { $0.isVod && $0.usable && $0.enabled && !(AppSettings.filterAdult && $0.isAV) }
            .map { source(for: $0) }
    }

    private func source(for ext: Extension) -> CMSSource {
        var source = CMSSource(name: ext.name, url: "https://uz.local")
        source.url = Self.scheme + ext.id
        return source
    }

    static let scheme = "uz://"

    nonisolated static func isUZ(_ api: String) -> Bool { api.hasPrefix(scheme) }

    nonisolated static func extensionID(fromAPI api: String) -> String {
        String(api.dropFirst(scheme.count))
    }

    private func findExtension(_ id: String) throws -> Extension {
        guard let ext = extensions.first(where: { $0.id == id }) else {
            throw UZError.message("这个网盘片源已经被删除")
        }
        return ext
    }

    // MARK: 搜索 / 详情

    /// 搜索（结果不带剧集，打开详情时再取）
    func search(_ source: CMSSource, keyword: String) async throws -> [CMSItem] {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }
        let key = source.url + "|" + CMSClient.normalizeTitle(word)
        if let hit = searchCache[key], Date().timeIntervalSince(hit.date) < 600 { return hit.items }
        let ext = try findExtension(Self.extensionID(fromAPI: source.url))
        let runtime = try await prepare(ext)
        let raw = try await runtime.call(tag: ext.id, function: "searchVideo", args: ["searchWord": word, "page": 1, "url": ""], webSite: ext.webSite)
        let object = Self.json(raw)
        var items = (object["data"] as? [[String: Any]] ?? []).compactMap { Self.item($0, ext: ext) }
        if items.isEmpty, let error = object["error"] as? String, !error.isEmpty {
            throw UZError.message(error)
        }
        // 网盘站的搜索很宽泛，只留片名里有搜索词的
        let target = CMSClient.normalizeTitle(word)
        let matched = items.filter { CMSClient.normalizeTitle($0.name).contains(target) }
        if !matched.isEmpty { items = matched }
        searchCache[key] = (Date(), items)
        return items
    }

    /// 详情页自动找片源：搜索 → 挑最匹配的 → 取剧集（网盘分享展开成文件列表）。
    /// 十几个资源站同时搜，展开分享会打很多网盘接口：同时最多展开 4 个站，每个站最多 3 个分享
    func searchBest(_ source: CMSSource, keyword: String, year: String) async throws -> CMSItem? {
        let items = try await search(source, keyword: keyword)
        guard let best = VideoDetailView.bestMatch(items, title: keyword, year: year) else { return nil }
        await detailLimiter.wait()
        defer { detailLimiter.signal() }
        let full = try await detail(api: source.url, vodID: best.vodID, base: best, maxShares: 3)
        return full.roads.isEmpty ? nil : full
    }

    private let detailLimiter = AsyncLimiter(4)

    func detail(api: String, vodID: String, base: CMSItem? = nil, maxShares: Int = 8) async throws -> CMSItem {
        let key = api + "#" + vodID
        if let hit = detailCache[key], Date().timeIntervalSince(hit.date) < 600 { return hit.item }
        let ext = try findExtension(Self.extensionID(fromAPI: api))
        let runtime = try await prepare(ext)
        let raw = try await runtime.call(tag: ext.id, function: "getVideoDetail", args: ["url": vodID, "page": 1], webSite: ext.webSite)
        let object = Self.json(raw)
        guard let data = object["data"] as? [String: Any] else {
            let error = RuleValue.string(object["error"])
            throw UZError.message(error.isEmpty ? "没有取到详情" : error)
        }
        var item = Self.item(data, ext: ext) ?? base ?? CMSItem(
            api: api, sourceName: ext.name, vodID: vodID, name: "", pic: "", typeName: "", year: "", area: "",
            remarks: "", content: "", director: "", actor: "", roads: []
        )
        item.vodID = vodID
        if let base {
            if item.name.isEmpty { item.name = base.name }
            if item.pic.isEmpty { item.pic = base.pic }
            if item.year.isEmpty { item.year = base.year }
            if item.remarks.isEmpty { item.remarks = base.remarks }
        }
        var roads = Self.directRoads(data, ext: ext)
        let shares = (data["panUrls"] as? [Any] ?? []).map { RuleValue.string($0) }.filter { !$0.isEmpty }
        if !shares.isEmpty {
            roads += try await panRoads(Array(shares.prefix(maxShares)))
        }
        item.roads = roads
        if !roads.isEmpty { detailCache[key] = (Date(), item) }
        return item
    }

    private nonisolated static func directRoads(_ data: [String: Any], ext: Extension) -> [Road] {
        let froms = RuleValue.string(data["vod_play_from"]).components(separatedBy: "$$$")
        let urls = RuleValue.string(data["vod_play_url"]).components(separatedBy: "$$$")
        var roads: [Road] = []
        for (index, list) in urls.enumerated() where !list.trimmingCharacters(in: .whitespaces).isEmpty {
            let flag = index < froms.count ? froms[index] : ""
            var episodes: [Episode] = []
            for (number, part) in list.components(separatedBy: "#").enumerated() where !part.isEmpty {
                let pieces = part.components(separatedBy: "$")
                let name = pieces.count > 1 ? pieces[0] : "第\(number + 1)集"
                let url = pieces.count > 1 ? pieces.dropFirst().joined(separator: "$") : part
                episodes.append(Episode(name: name, url: "uzplay:" + encode(["ext": ext.id, "flag": flag, "url": url])))
            }
            if !episodes.isEmpty { roads.append(Road(name: flag.isEmpty ? "线路\(index + 1)" : flag, episodes: episodes)) }
        }
        return roads
    }

    /// 网盘分享链接 → 每个分享一条线路，文件是剧集
    private func panRoads(_ shares: [String]) async throws -> [Road] {
        await upgradeLegacyPanTools()
        guard let pan = panTools else {
            throw UZError.message("还没有网盘工具，到「我的 → 网盘资源」导入订阅")
        }
        let runtime = try await prepare(pan)
        let panID = pan.id
        let raws = await withTaskGroup(of: (Int, String).self) { group in
            for (index, share) in shares.enumerated() {
                group.addTask {
                    (index, (try? await runtime.callPan(tag: panID, method: "getShareVideos", args: share, timeout: 40)) ?? "")
                }
            }
            var collected: [(Int, String)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let lists = raws.map { Self.json($0) }
        var roads: [Road] = []
        var counts: [String: Int] = [:]
        for list in lists {
            let videos = list["videos"] as? [[String: Any]] ?? []
            guard !videos.isEmpty else {
                let error = RuleValue.string(list["error"])
                if !error.isEmpty { Diag.log("网盘扩展", "分享解析失败：\(error)") }
                continue
            }
            // 同一个分享里可能有多个文件夹（fromName），各成一条线路
            var groups: [(String, [[String: Any]])] = []
            for video in videos {
                let from = RuleValue.string(video["fromName"])
                if let index = groups.firstIndex(where: { $0.0 == from }) {
                    groups[index].1.append(video)
                } else {
                    groups.append((from, [video]))
                }
            }
            for (from, items) in groups {
                let panType = RuleValue.string(items.first?["panType"])
                counts[panType, default: 0] += 1
                var name = panType.isEmpty ? "网盘" : panType
                if !from.isEmpty { name += " · " + from } else if counts[panType, default: 0] > 1 { name += " \(counts[panType, default: 0])" }
                let episodes = items.map { video in
                    Episode(
                        name: Self.cleanFileName(RuleValue.string(video["name"])),
                        url: "uzpan:" + Self.encode(["pan": panID, "item": video])
                    )
                }
                roads.append(Road(name: name, episodes: episodes))
            }
        }
        return roads
    }

    /// 文件名去掉扩展名，剧集按钮里放得下
    nonisolated static func cleanFileName(_ name: String) -> String {
        let lower = name.lowercased()
        for ext in [".mp4", ".mkv", ".ts", ".flv", ".avi", ".rmvb", ".mov", ".m4v", ".wmv", ".iso", ".m2ts", ".webm"] where lower.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    private nonisolated static func item(_ data: [String: Any], ext: Extension) -> CMSItem? {
        let vodID = RuleValue.string(data["vod_id"])
        let name = RuleValue.string(data["vod_name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vodID.isEmpty || !name.isEmpty else { return nil }
        var pic = RuleValue.string(data["vod_pic"])
        if let range = pic.range(of: "#headers#") { pic = String(pic[..<range.lowerBound]) }
        return CMSItem(
            api: scheme + ext.id, sourceName: ext.name, vodID: vodID, name: name, pic: pic,
            typeName: RuleValue.string(data["type_name"]), year: RuleValue.string(data["vod_year"]),
            area: RuleValue.string(data["vod_area"]), remarks: RuleValue.string(data["vod_remarks"]),
            content: CMSClient.plainText(RuleValue.string(data["vod_content"])),
            director: RuleValue.string(data["vod_director"]), actor: RuleValue.string(data["vod_actor"]), roads: []
        )
    }

    // MARK: 播放

    struct PlayInfo: Sendable {
        var url: String
        var headers: [String: String]
        /// 其他清晰度 / 线路（播放失败时依次换）
        var alternates: [(url: String, headers: [String: String])]
        /// 给的是网页，需要嗅探
        var needsSniff = false
        /// 只有原文件（没有网盘转码的清晰度）
        var onlyOriginal = false
        /// 网盘里的文件名（本地代理按扩展名告诉播放器格式）
        var fileName = ""
        /// 网盘标的文件类型（有的 MKV 文件名写的是 .mp4）
        var mimeType = ""
    }

    /// 夸克 / UC / 115 / 百度至少登录了一个
    var hasNetdiskLogin: Bool {
        Self.webLogins.contains { loginState($0) == .ok }
    }

    private func webLogin(_ panType: String) -> WebLogin? {
        Self.webLogins.first { $0.envKey.hasPrefix(panType) || $0.name.hasPrefix(panType) }
    }

    private func isLoggedIn(_ panType: String) -> Bool {
        guard let login = webLogin(panType) else { return true }
        return loginState(login) == .ok
    }

    /// 网盘工具的报错换成 Astra 里的说法
    private nonisolated static func friendlyError(_ error: String, panType: String, loggedIn: Bool) -> String {
        if error.contains("环境变量") || (!loggedIn && (error.contains("cookie") || error.contains("转存失败"))) {
            let name = panType.isEmpty ? "网盘" : panType
            return "这个资源需要先登录\(name)：我的 → 片源 → 网盘资源 → 网盘账号"
        }
        return error.isEmpty ? "没有取到播放地址" : error
    }

    nonisolated static func isEpisodeURL(_ url: String) -> Bool {
        url.hasPrefix("uzpan:") || url.hasPrefix("uzplay:")
    }

    /// 剧集地址（uzpan: / uzplay:）→ 真实播放地址和请求头
    func resolve(_ episodeURL: String) async throws -> PlayInfo {
        if episodeURL.hasPrefix("uzpan:") {
            let payload = Self.decode(String(episodeURL.dropFirst(6)))
            let panID = RuleValue.string(payload["pan"])
            await upgradeLegacyPanTools()
            guard let pan = panTools ?? extensions.first(where: { $0.id == panID }) else {
                throw UZError.message("网盘工具不见了，到「我的 → 片源 → 网盘资源」重新导入")
            }
            let item = payload["item"] as? [String: Any] ?? [:]
            let panType = RuleValue.string(item["panType"])
            // 夸克 / UC / 115 / 百度都要用自己的账号：没登录直接提示，不去试
            if let login = webLogin(panType) {
                switch loginState(login) {
                case .none:
                    throw UZError.message("播放\(panType)网盘的资源需要先登录：我的 → 片源 → 网盘资源 → 网盘账号")
                case .incomplete:
                    throw UZError.message("\(login.name)的 Cookie 里没有登录信息（像是没登录成功），到 我的 → 片源 → 网盘资源 → 网盘账号 重新登录")
                case .ok:
                    break
                }
            }
            if panType == "UC" { await NetdiskQRLogin.refreshUCTokenIfNeeded() }
            let runtime = try await prepare(pan)
            // 原画优先：MKV、AVI 之类系统播放器放不了的交给 mpv，不用再退到网盘转码的低清晰度
            let fileName = RuleValue.string(item["name"])
            runtime.note("取播放地址：\(panType) \(fileName) \(RuleValue.string(item["remark"]))")
            let raw = try await runtime.callPan(tag: pan.id, method: "getPlayInfo", args: item, timeout: 60)
            let object = Self.json(raw)
            let mimeType = RuleValue.string((item["data"] as? [String: Any])?["formatType"])
            var info = try? Self.playInfo(object, headerKey: "playHeaders")
            info?.fileName = fileName
            info?.mimeType = mimeType
            runtime.note("网盘工具返回：\(info.map { "\($0.alternates.count + 1) 个地址\($0.onlyOriginal ? "（只有原画）" : "")" } ?? "没有地址") \(RuleValue.string(object["error"]))")
            if var info, !info.url.isEmpty {
                if panType == "百度" {
                    // 百度直链：只带网盘客户端的 UA（不带 Referer），先把跳转解析出来再播（猫影视源包的做法）
                    let agent = info.headers.first { $0.key.lowercased() == "user-agent" }?.value ?? BaiduLink.userAgent
                    let probe = await BaiduLink.resolve(info.url, userAgent: agent)
                    runtime.note("百度直链：\(probe.summary)")
                    info.alternates = [(info.url, info.headers)] + info.alternates
                    info.headers = ["User-Agent": agent]
                    if let location = probe.location { info.url = location }
                }
                return info
            }
            // 没取到原画地址：夸克 / UC 再试一下转存后用网盘转码播放
            if ["夸克", "UC"].contains(panType) {
                runtime.note("没有原画地址，改用网盘转码")
                let transcoded = Self.json(try await runtime.transcode(tag: pan.id, item: item))
                runtime.note("转码返回：\(RuleValue.string(transcoded["error"]).isEmpty ? "\((transcoded["urls"] as? [Any])?.count ?? 0) 个清晰度" : RuleValue.string(transcoded["error"]))")
                if var result = try? Self.playInfo(transcoded, headerKey: "playHeaders"), !result.url.isEmpty {
                    result.fileName = fileName
                    result.mimeType = mimeType
                    return result
                }
            }
            throw UZError.message(Self.friendlyError(RuleValue.string(object["error"]), panType: panType, loggedIn: isLoggedIn(panType)))
        }
        let payload = Self.decode(String(episodeURL.dropFirst(7)))
        let ext = try findExtension(RuleValue.string(payload["ext"]))
        let runtime = try await prepare(ext)
        let raw = try await runtime.call(
            tag: ext.id, function: "getVideoPlayUrl",
            args: ["url": RuleValue.string(payload["url"]), "flag": RuleValue.string(payload["flag"]), "page": 1],
            webSite: ext.webSite
        )
        let object = Self.json(raw)
        var info = try Self.playInfo(object, headerKey: "headers", urlKey: "data")
        if info.url.isEmpty, let sniffer = object["sniffer"] as? [String: Any], !RuleValue.string(sniffer["url"]).isEmpty {
            info.url = RuleValue.string(sniffer["url"])
            info.needsSniff = true
        }
        if info.url.isEmpty {
            // 有的扩展直接把网页地址当播放地址：交给嗅探
            info.url = RuleValue.string(payload["url"])
            info.needsSniff = true
        }
        return info
    }

    private nonisolated static func playInfo(
        _ object: [String: Any], headerKey: String, urlKey: String = "url"
    ) throws -> PlayInfo {
        let baseHeaders = headers(object[headerKey])
        var candidates: [(url: String, headers: [String: String], original: Bool)] = []
        let main = RuleValue.string(object[urlKey])
        let list = (object["urls"] as? [[String: Any]] ?? []).sorted {
            (($0["priority"] as? NSNumber)?.doubleValue ?? 0) > (($1["priority"] as? NSNumber)?.doubleValue ?? 0)
        }
        func isOriginal(_ entry: [String: Any]?) -> Bool {
            RuleValue.string(entry?["name"]).contains("原画")
        }
        if !main.isEmpty {
            let match = list.first { RuleValue.string($0["url"]) == main }
            candidates.append((main, baseHeaders.merging(headers(match?["headers"])) { _, new in new }, isOriginal(match)))
        }
        for entry in list {
            let url = RuleValue.string(entry["url"])
            guard !url.isEmpty, !candidates.contains(where: { $0.url == url }) else { continue }
            candidates.append((url, baseHeaders.merging(headers(entry["headers"])) { _, new in new }, isOriginal(entry)))
        }
        // 原画放最前面（mpv 什么格式都能放），网盘转码的清晰度留着播放失败时换
        candidates = candidates.filter(\.original) + candidates.filter { !$0.original }
        guard let first = candidates.first else {
            let error = RuleValue.string(object["error"])
            if !error.isEmpty { throw UZError.message(error) }
            return PlayInfo(url: "", headers: baseHeaders, alternates: [])
        }
        return PlayInfo(
            url: first.url, headers: first.headers, alternates: candidates.dropFirst().map { ($0.url, $0.headers) },
            onlyOriginal: candidates.allSatisfy(\.original)
        )
    }

    private nonisolated static func headers(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dict {
            let text = RuleValue.string(value)
            // 空的 User-Agent 之类的不要带，让播放器用默认值
            if !text.isEmpty { result[key] = text }
        }
        return result
    }

    // MARK: 工具

    private nonisolated static func json(_ raw: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
    }

    private nonisolated static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func decode(_ text: String) -> [String: Any] {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// 简单的并发上限（主线程上用）
@MainActor
final class AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) {
        available = limit
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - 百度直链

enum BaiduLink {
    static let userAgent = "netdisk;P2SP;2.2.91.136;android-android;"

    struct Probe {
        var status = 0
        var location: String?
        var host = ""
        var body = ""

        var summary: String {
            if let location { return "\(host) \(status) → \(URL(string: location)?.host ?? String(location.prefix(40)))" }
            return "\(host) \(status) \(body)"
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    /// 请求一次直链但不跟随跳转：拿到跳转后的地址；失败时记下状态码和返回的开头
    static func resolve(_ url: String, userAgent: String) async -> Probe {
        var probe = Probe()
        guard let target = URL.lenient(url) else {
            probe.body = "地址无效"
            return probe
        }
        probe.host = target.host ?? ""
        var request = URLRequest(url: target, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return probe }
            probe.status = http.statusCode
            if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), !location.isEmpty {
                // 跳转地址原样用（带签名，交给 URL 解析可能被重新编码）；只有相对地址才拼上域名
                probe.location = location.lowercased().hasPrefix("http") ? location : (URL(string: location, relativeTo: target)?.absoluteString ?? location)
            } else if http.statusCode >= 400 {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 240 { break }
                }
                probe.body = String(decoding: data, as: UTF8.self)
            }
        } catch {
            probe.body = error.localizedDescription
        }
        return probe
    }
}

// MARK: - ZIP

/// 只读的 ZIP 解包（uz 订阅是 zip）：支持不压缩和 deflate 两种
struct ZipArchive {
    private var entries: [String: Data] = [:]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 22, bytes[0] == 0x50, bytes[1] == 0x4B else { return nil }
        func u16(_ offset: Int) -> Int {
            guard offset + 1 < bytes.count else { return 0 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int {
            guard offset + 3 < bytes.count else { return 0 }
            return u16(offset) | u16(offset + 2) << 16
        }
        // 从文件尾找中央目录结束记录
        var end = -1
        var index = bytes.count - 22
        while index >= max(0, bytes.count - 65_557) {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                end = index
                break
            }
            index -= 1
        }
        guard end >= 0 else { return nil }
        let count = u16(end + 10)
        var offset = u32(end + 16)
        for _ in 0..<count {
            guard u32(offset) == 0x02014B50 else { break }
            let method = u16(offset + 10)
            let compressed = u32(offset + 20)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            let nameBytes = Array(bytes[(offset + 46)..<min(offset + 46 + nameLength, bytes.count)])
            let name = String(decoding: nameBytes, as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength
            guard !name.hasSuffix("/"), u32(local) == 0x04034B50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { continue }
            let body = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: entries[name] = body
            case 8: if let inflated = Zlib.rawInflate(body) { entries[name] = inflated }
            default: continue
            }
        }
        guard !entries.isEmpty else { return nil }
    }

    func file(_ path: String) -> Data? {
        var key = path
        while key.hasPrefix("./") || key.hasPrefix("/") { key.removeFirst(key.hasPrefix("./") ? 2 : 1) }
        return entries[key]
    }
}
