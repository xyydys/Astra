import Foundation
import CryptoKit

/// 猫影视插件包（index.js / index.js.md5 订阅）：下载插件包交给内置的 Node 运行，
/// 插件包里的影视站点当片源用（搜索 / 详情 / 播放都通过插件包的本机接口）
@MainActor
final class CatStore: ObservableObject {
    static let shared = CatStore()
    static let scheme = "cat://"

    struct Site: Codable, Hashable, Identifiable {
        var key: String
        var name: String
        var api: String
        var searchable: Bool
        var id: String { key }
    }

    struct Saved: Codable {
        var url = ""
        var md5 = ""
        var updatedAt: Date?
        var sites: [Site] = []
        var disabled: Set<String> = []
        /// 默认不搜的站点（音乐、课堂之类）里手动打开的
        var enabled: Set<String> = []
        /// 插件里没有搜索接口的站点（下次启动起不再搜）
        var noSearch: Set<String> = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = (try? c.decode(String.self, forKey: .url)) ?? ""
            md5 = (try? c.decode(String.self, forKey: .md5)) ?? ""
            updatedAt = try? c.decode(Date.self, forKey: .updatedAt)
            sites = (try? c.decode([Site].self, forKey: .sites)) ?? []
            disabled = (try? c.decode(Set<String>.self, forKey: .disabled)) ?? []
            enabled = (try? c.decode(Set<String>.self, forKey: .enabled)) ?? []
            noSearch = (try? c.decode(Set<String>.self, forKey: .noSearch)) ?? []
        }
    }

    enum Status: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var saved = Saved()
    @Published private(set) var status: Status = .idle
    @Published private(set) var working = false
    @Published var notice: String?

    /// 插件包实际用的端口
    private(set) var port = CatNode.catPort
    private var startTask: Task<Void, Error>?
    private var checkedUpdate = false
    /// App 这边的请求记录（复制日志时带上）
    private(set) var callLog: [String] = []
    private let searchLimiter = AsyncLimiter(8)
    private var detailCache: [String: (date: Date, item: CMSItem)] = [:]

    /// 不当片源的站点：首页推荐、设置、推送、更新日期
    private static let hiddenKeys: Set<String> = ["nodejs_push", "nodejs_baseset", "nodejs_gengxin", "nodejs_douban"]
    /// 直播、音乐、课堂之类的站点搜不到影视，默认不参与搜索（可以在设置里手动打开）
    private static let nonVideoWords = ["直播", "电台", "听书", "舞曲", "体育", "音乐", "歌曲", "戏曲", "课堂", "教育", "舞蹈", "合集"]
    /// 启动时就知道没有搜索接口的站点（这次启动里新发现的下次才去掉，免得正在进行的搜索被打断重来）
    private var noSearchAtLaunch: Set<String> = []

    private init() {
        if let data = try? Data(contentsOf: Self.stateURL), let value = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = value
        }
        noSearchAtLaunch = saved.noSearch
    }

    // MARK: 文件

    private nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Cat", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static var packageDir: URL {
        let url = root.appendingPathComponent("package", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static var dataDir: URL {
        let url = root.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static var stateURL: URL { root.appendingPathComponent("state.json") }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.stateURL, options: .atomic) }
    }

    var hasPackage: Bool { FileManager.default.fileExists(atPath: Self.packageDir.appendingPathComponent("index.js").path) }

    // MARK: 片源

    nonisolated static func isCat(_ api: String) -> Bool { api.hasPrefix(scheme) }

    nonisolated static func isEpisodeURL(_ url: String) -> Bool { url.hasPrefix("catplay:") }

    /// 能搜索的站点（设置里列出来的）
    var videoSites: [Site] {
        saved.sites.filter { site in
            site.searchable && !Self.hiddenKeys.contains(site.key) && !noSearchAtLaunch.contains(site.key)
        }
    }

    /// 音乐、课堂、直播之类默认不搜
    static func isNonVideo(_ site: Site) -> Bool { nonVideoWords.contains { site.name.contains($0) } }

    func isEnabled(_ site: Site) -> Bool {
        if saved.disabled.contains(site.key) { return false }
        return !Self.isNonVideo(site) || saved.enabled.contains(site.key)
    }

    var vodSources: [CMSSource] {
        guard hasPackage else { return [] }
        return videoSites
            .filter { isEnabled($0) }
            .map { CMSSource(name: $0.name, url: Self.scheme + $0.key) }
    }

    func setEnabled(_ key: String, _ enabled: Bool) {
        if enabled {
            saved.disabled.remove(key)
            saved.enabled.insert(key)
        } else {
            saved.disabled.insert(key)
            saved.enabled.remove(key)
        }
        save()
    }

    private func site(forAPI api: String) throws -> Site {
        let key = String(api.dropFirst(Self.scheme.count))
        guard let site = saved.sites.first(where: { $0.key.lowercased() == key.lowercased() }) else {
            throw UZError.message("插件包里没有这个站点了，到「我的 → 片源 → 猫影视插件」更新一下")
        }
        return site
    }

    // MARK: 订阅

    /// 添加 / 更换订阅：支持 index.js.md5、index.js 或者插件包目录，地址里可以带账号密码（http://用户:密码@域名/…）
    func subscribe(_ input: String) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let package = try await Self.download(text)
            try install(package)
            saved.url = text
            save()
            try await reload()
            notice = "已载入 \(videoSites.count) 个影视站点"
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 检查更新：MD5 变了才重新下载
    func update(force: Bool = false) async {
        guard !saved.url.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            if !force, let remote = try? await Self.remoteMD5(saved.url), remote == saved.md5 {
                notice = "已经是最新的插件包"
                return
            }
            let package = try await Self.download(saved.url)
            try install(package)
            try await reload()
            notice = "已更新，\(videoSites.count) 个影视站点"
        } catch {
            notice = error.localizedDescription
        }
    }

    func remove() async {
        try? FileManager.default.removeItem(at: Self.packageDir)
        saved = Saved()
        save()
        detailCache = [:]
        if CatNode.shared.isStarted { _ = try? await CatHTTP.get(controlURL("/reload"), timeout: 30) }
        status = .idle
    }

    private func install(_ package: Package) throws {
        let dir = Self.packageDir
        try package.script.write(to: dir.appendingPathComponent("index.js"), options: .atomic)
        let configURL = dir.appendingPathComponent("index.config.js")
        if let config = package.config {
            try config.write(to: configURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: configURL)
        }
        saved.md5 = package.md5
        saved.updatedAt = Date()
        detailCache = [:]
        save()
    }

    struct Package {
        var script: Data
        var config: Data?
        var md5: String
    }

    /// 地址里的账号密码拿出来做 Basic 认证（URLSession 不会自动用地址里的账号密码）
    private nonisolated static func request(_ raw: String) throws -> URLRequest {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UZError.message("订阅地址无效")
        }
        let user = components.percentEncodedUser.flatMap { $0.removingPercentEncoding } ?? ""
        let password = components.percentEncodedPassword.flatMap { $0.removingPercentEncoding } ?? ""
        components.user = nil
        components.password = nil
        guard let url = components.url else { throw UZError.message("订阅地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("okhttp/4.12.0", forHTTPHeaderField: "User-Agent")
        if !user.isEmpty {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 订阅地址 → index.js、index.js.md5、index.config.js 的地址
    private nonisolated static func addresses(_ raw: String) -> (script: String, md5: String, config: String) {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = base.range(of: "?") { base = String(base[..<range.lowerBound]) }
        if base.lowercased().hasSuffix(".md5") { base = String(base.dropLast(4)) }
        if base.hasSuffix("/") { base += "index.js" }
        if !base.lowercased().hasSuffix(".js") { base += "/index.js" }
        let folder = base.components(separatedBy: "/").dropLast().joined(separator: "/")
        return (base, base + ".md5", folder + "/index.config.js")
    }

    private nonisolated static func fetch(_ url: String) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private nonisolated static func remoteMD5(_ raw: String) async throws -> String? {
        let (data, status) = try await fetch(addresses(raw).md5)
        guard status == 200 else { return nil }
        return parseMD5(String(decoding: data, as: UTF8.self))
    }

    private nonisolated static func parseMD5(_ text: String) -> String? {
        let pattern = try? NSRegularExpression(pattern: "[0-9a-fA-F]{32}")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern?.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) else { return nil }
        return text[swiftRange].lowercased()
    }

    private nonisolated static func download(_ raw: String) async throws -> Package {
        let urls = addresses(raw)
        let expected: String? = (try? await remoteMD5(raw)) ?? nil
        let (script, status) = try await fetch(urls.script)
        guard status == 200, script.count > 1000 else {
            throw UZError.message(status == 401 || status == 403 ? "订阅需要账号密码（地址里的 用户:密码@ 部分）" : "插件包下载失败（\(status)）")
        }
        let text = String(decoding: script.prefix(4096), as: UTF8.self)
        guard !text.lowercased().contains("<html") else { throw UZError.message("订阅地址返回的是网页，不是插件包") }
        let md5 = Insecure.MD5.hash(data: script).map { String(format: "%02x", $0) }.joined()
        if let expected, expected != md5 {
            throw UZError.message("插件包校验没通过（MD5 不一致），稍后再试")
        }
        var config: Data?
        if let fetched = try? await fetch(urls.config), fetched.1 == 200, !fetched.0.isEmpty,
           !String(decoding: fetched.0.prefix(512), as: UTF8.self).lowercased().contains("<html") {
            config = fetched.0
        }
        return Package(script: script, config: config, md5: md5)
    }

    // MARK: 运行

    private func controlURL(_ path: String) -> String { "http://127.0.0.1:\(CatNode.controlPort)\(path)" }
    private func serviceURL(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    /// 确保插件包在运行（第一次用时启动 Node，之后检查一下服务还在不在）
    func ensureRunning() async throws {
        guard hasPackage else { throw UZError.message("还没有添加猫影视插件：我的 → 片源 → 猫影视插件") }
        if CatNode.shared.hasExited { throw UZError.message("插件运行环境退出了，重启 App 再试") }
        // 运行中就直接用：不在每次请求前探测（几十个站点同时搜时插件回得慢，探测超时会被误判成挂了、触发重新载入，
        // 把正在进行的请求全断掉）；真连不上了由 call() 发现后再重新载入
        if status == .running { return }
        if let startTask { return try await startTask.value }
        let task = Task<Void, Error> { @MainActor in
            defer { self.startTask = nil }
            self.status = .starting
            do {
                if !CatNode.shared.isStarted {
                    let boot = Self.root.appendingPathComponent("boot.js")
                    try Data(CatNode.bootScript.utf8).write(to: boot, options: .atomic)
                    CatNode.shared.start(boot: boot, dataDir: Self.dataDir, packageDir: Self.packageDir)
                    try await self.waitUntilLoaded(timeout: 90)
                } else {
                    // 退到后台久了监听可能失效：让启动脚本重新加载一次
                    let result = try await CatHTTP.get(self.controlURL("/reload"), timeout: 90)
                    try self.apply(result)
                }
                try await self.refreshSites()
                self.status = .running
                self.checkForUpdateOnce()
            } catch {
                self.status = .failed(error.localizedDescription)
                self.note("启动失败：\(error.localizedDescription)")
                throw error
            }
        }
        startTask = task
        try await task.value
    }

    /// 重新加载插件包（更新订阅后）
    func reload() async throws {
        if !CatNode.shared.isStarted {
            status = .idle
            try await ensureRunning()
            return
        }
        status = .starting
        do {
            let result = try await CatHTTP.get(controlURL("/reload"), timeout: 90)
            try apply(result)
            try await refreshSites()
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    private func waitUntilLoaded(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CatNode.shared.hasExited { throw UZError.message("插件运行环境退出了，重启 App 再试") }
            if let result = try? await CatHTTP.get(controlURL("/status"), timeout: 3) {
                let state = RuleValue.string(result["state"])
                if state == "running" || state == "failed" || state == "empty" {
                    try apply(result)
                    return
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw UZError.message("插件启动超时")
    }

    private func apply(_ result: [String: Any]) throws {
        let state = RuleValue.string(result["state"])
        if let value = (result["port"] as? NSNumber)?.intValue, value > 0 { port = value }
        if state == "failed" {
            let error = RuleValue.string(result["error"])
            throw UZError.message("插件包运行出错：\(error.components(separatedBy: "\n").first ?? error)")
        }
        if state == "empty" { throw UZError.message("还没有插件包") }
    }

    private func refreshSites() async throws {
        let config = try await CatHTTP.get(serviceURL("/config"), timeout: 20)
        let video = config["video"] as? [String: Any] ?? [:]
        let list = video["sites"] as? [[String: Any]] ?? []
        let sites = list.compactMap { item -> Site? in
            let key = RuleValue.string(item["key"])
            let api = RuleValue.string(item["api"])
            guard !key.isEmpty, !api.isEmpty else { return nil }
            let searchable = (item["searchable"] as? NSNumber)?.intValue ?? 1
            return Site(key: key, name: RuleValue.string(item["name"]), api: api, searchable: searchable != 0)
        }
        if !sites.isEmpty {
            saved.sites = sites
            save()
        }
    }

    private func checkForUpdateOnce() {
        guard !checkedUpdate, !saved.url.isEmpty else { return }
        checkedUpdate = true
        let url = saved.url
        let current = saved.md5
        Task { @MainActor in
            guard let remote = try? await Self.remoteMD5(url), remote != current else { return }
            await self.update(force: true)
        }
    }

    /// 插件包自己的配置页（网盘扫码登录、站点设置等）
    var websiteURL: String { serviceURL("/website") }

    func nodeLogs() async -> [String] {
        guard CatNode.shared.isStarted, let result = try? await CatHTTP.get(controlURL("/logs"), timeout: 5) else { return [] }
        return (result["logs"] as? [Any] ?? []).map { RuleValue.string($0) }
    }

    private func note(_ line: String) {
        callLog.append(line)
        if callLog.count > 40 { callLog.removeFirst(callLog.count - 40) }
    }

    // MARK: 接口

    private func call(_ site: Site, _ action: String, _ body: [String: Any], timeout: TimeInterval = 40) async throws -> [String: Any] {
        try await ensureRunning()
        do {
            let result: [String: Any]
            do {
                result = try await CatHTTP.post(serviceURL(site.api + "/" + action), body: body, timeout: timeout)
            } catch let error as URLError where error.code == .cannotConnectToHost {
                // 插件服务没在监听了（比如退到后台久了）：重新载入后再试一次
                if status == .running { status = .idle }
                try await ensureRunning()
                result = try await CatHTTP.post(serviceURL(site.api + "/" + action), body: body, timeout: timeout)
            } catch let error as URLError where error.code == .networkConnectionLost {
                // 复用的连接刚好被插件关掉：重发一次
                result = try await CatHTTP.post(serviceURL(site.api + "/" + action), body: body, timeout: timeout)
            }
            note("\(site.name) \(action)：\((result["list"] as? [Any])?.count.description ?? (result["url"] != nil ? "有地址" : "完成"))")
            return result
        } catch {
            let message = error.localizedDescription
            // 插件里这个站点没有这个接口（比如没有搜索）：下次启动起不再搜
            if message.contains("Route"), message.contains("not found") {
                saved.noSearch.insert(site.key)
                save()
            }
            note("\(site.name) \(action) 失败：\(message)")
            throw error
        }
    }

    func search(_ source: CMSSource, keyword: String) async throws -> [CMSItem] {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }
        let site = try site(forAPI: source.url)
        await searchLimiter.wait()
        defer { searchLimiter.signal() }
        let result = try await call(site, "search", ["wd": word, "page": 1, "quick": false], timeout: 30)
        // 插件的搜索很宽泛（短剧、音乐站会返回不相干的结果）：只留片名里有搜索词的
        return CMSClient.parseList(result, api: source.url, sourceName: site.name)
            .filter { CMSClient.isRelevant($0.name, keyword: word) }
    }

    func searchBest(_ source: CMSSource, keyword: String, year: String) async throws -> CMSItem? {
        let items = try await search(source, keyword: keyword)
        guard let best = SourceSearch.bestMatch(items, title: keyword, year: year) else { return nil }
        let full = try await detail(api: source.url, vodID: best.vodID, base: best)
        return full.roads.isEmpty ? nil : full
    }

    func detail(api: String, vodID: String, base: CMSItem? = nil) async throws -> CMSItem {
        let key = api + "#" + vodID
        if let hit = detailCache[key], Date().timeIntervalSince(hit.date) < 600 { return hit.item }
        let site = try site(forAPI: api)
        let result = try await call(site, "detail", ["id": vodID], timeout: 60)
        guard let vod = (result["list"] as? [[String: Any]])?.first else {
            throw UZError.message("没有取到详情")
        }
        var item = CMSClient.parseItem(vod, api: api, sourceName: site.name) ?? base ?? CMSItem(
            api: api, sourceName: site.name, vodID: vodID, name: "", pic: "", typeName: "", year: "", area: "",
            remarks: "", content: "", director: "", actor: "", roads: []
        )
        item.vodID = vodID
        if let base {
            if item.name.isEmpty { item.name = base.name }
            if item.pic.isEmpty { item.pic = base.pic }
            if item.year.isEmpty { item.year = base.year }
        }
        item.roads = Self.roads(vod, site: site.key)
        if !item.roads.isEmpty { detailCache[key] = (Date(), item) }
        return item
    }

    /// 剧集地址是插件包的 id（不是网址），包成 catplay: 交给播放页
    private nonisolated static func roads(_ vod: [String: Any], site: String) -> [Road] {
        let froms = RuleValue.string(vod["vod_play_from"]).components(separatedBy: "$$$")
        let urls = RuleValue.string(vod["vod_play_url"]).components(separatedBy: "$$$")
        var roads: [Road] = []
        for (index, list) in urls.enumerated() where !list.trimmingCharacters(in: .whitespaces).isEmpty {
            let flag = index < froms.count ? froms[index] : ""
            var episodes: [Episode] = []
            for (number, part) in list.components(separatedBy: "#").enumerated() where !part.isEmpty {
                let pieces = part.components(separatedBy: "$")
                let name = pieces.count > 1 ? pieces[0] : "第\(number + 1)集"
                let id = pieces.count > 1 ? pieces.dropFirst().joined(separator: "$") : part
                episodes.append(Episode(name: name, url: "catplay:" + encode(["site": site, "flag": flag, "id": id, "name": name])))
            }
            if !episodes.isEmpty { roads.append(Road(name: flag.isEmpty ? "线路\(index + 1)" : flag, episodes: episodes)) }
        }
        return roads
    }

    /// 剧集 → 播放地址和请求头
    func resolve(_ episodeURL: String) async throws -> UZStore.PlayInfo {
        let payload = Self.decode(String(episodeURL.dropFirst("catplay:".count)))
        let siteKey = RuleValue.string(payload["site"])
        guard let site = saved.sites.first(where: { $0.key == siteKey }) else {
            throw UZError.message("插件包里没有这个站点了")
        }
        let result = try await call(site, "play", ["flag": RuleValue.string(payload["flag"]), "id": RuleValue.string(payload["id"])], timeout: 60)
        var urls: [String] = []
        if let list = result["url"] as? [Any] {
            // 多清晰度：["名称", "地址", "名称", "地址", …]
            urls = list.map { RuleValue.string($0) }.filter { $0.lowercased().hasPrefix("http") }
        } else {
            let url = RuleValue.string(result["url"])
            if !url.isEmpty { urls = [url] }
        }
        guard let first = urls.first else {
            let error = RuleValue.string(result["msg"]).isEmpty ? RuleValue.string(result["error"]) : RuleValue.string(result["msg"])
            throw UZError.message(error.isEmpty ? "插件没有返回播放地址" : error)
        }
        var headers: [String: String] = [:]
        for (key, value) in (result["header"] as? [String: Any]) ?? (result["headers"] as? [String: Any]) ?? [:] {
            let text = RuleValue.string(value)
            if !text.isEmpty { headers[key] = text }
        }
        let parse = (result["parse"] as? NSNumber)?.intValue ?? 0
        let jx = (result["jx"] as? NSNumber)?.intValue ?? 0
        var info = UZStore.PlayInfo(url: first, headers: headers, alternates: urls.dropFirst().map { ($0, headers) })
        info.needsSniff = parse == 1 || jx == 1
        info.fileName = RuleValue.string(payload["name"])
        return info
    }

    var diagnostics: [String] { callLog }

    // MARK: 编码

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

    /// 是不是猫影视插件包（uz 订阅里导入时识别出来，引导到这里）
    nonisolated static func looksLikePackage(_ text: String) -> Bool {
        text.contains("catServerFactory") || text.contains("CatVodSpider")
    }
}
