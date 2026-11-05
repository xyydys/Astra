import Foundation

/// 详情页的片源搜索（影视和番剧共用）：在所有启用的片源里按片名并发搜索，每个片源挑出最匹配的一条（连同选集），
/// 按「上次选的 / 看的 → 片名对不对得上 → 片源大类顺序 → 匹配度 → 规则管理里的顺序」排好，自动选中最前面的
@MainActor
final class SourceSearch: ObservableObject {
    /// 一个片源：Kazumi 规则、采集站、网盘资源站（uz）、猫影视插件里的站点
    struct Candidate: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: SourceKind
        let rule: Rule?
        let cms: CMSSource?
    }

    /// 一个片源里挑出来的那条结果
    struct Hit: Equatable {
        var name: String
        var year: String
        var remarks: String
        var roads: [Road]
        /// 采集站 / 网盘 / 猫影视的结果
        var cms: CMSItem?
        /// Kazumi 规则的结果
        var ruleItem: SearchItem?
        /// 这个片源一共搜到几条
        var total: Int

        var episodeCount: Int { roads.map(\.episodes.count).max() ?? 0 }

        init(_ item: CMSItem, total: Int = 1) {
            name = item.name
            year = item.year
            remarks = item.remarks
            roads = item.roads
            cms = item
            ruleItem = nil
            self.total = total
        }

        init(_ item: SearchItem, roads: [Road], total: Int) {
            name = item.name
            year = ""
            remarks = ""
            self.roads = roads
            cms = nil
            ruleItem = item
            self.total = total
        }
    }

    enum Result: Equatable {
        case loading
        case found(Hit)
        case empty
        case captcha
        case failed(String)
    }

    struct Ranked: Identifiable {
        let candidate: Candidate
        let hit: Hit
        let value: Double
        var id: String { candidate.id }
    }

    // 下面几项一变，排序缓存就作废
    @Published var subject: BangumiSubject { didSet { version += 1 } }
    @Published private(set) var keyword: String { didSet { version += 1 } }
    @Published private(set) var candidates: [Candidate] = [] { didSet { version += 1 } }
    @Published private(set) var results: [String: Result] = [:] { didSet { version += 1 } }
    @Published private(set) var selectedID: String?
    @Published var selectedRoad = 0
    /// 每个片源这次搜索用了多久（复制报告时带上；不触发页面刷新）
    private(set) var timings: [String: TimeInterval] = [:]
    /// 刚搜完、还没交给页面的结果：攒 0.25 秒一起刷新，几十个片源陆续返回时页面不会每个都重排一次（滑动不卡）
    private var inbox: [String: Result] = [:]
    private var flushScheduled = false
    private var version = 0
    private var rankedCache: (key: RankKey, value: [Ranked])?
    /// 没找到 / 出错的片源列表展开（nil：没有找到任何结果时自动展开）
    @Published var problemsExpanded: Bool?
    @Published var reportCopied = false
    /// 用户手动选过片源后，不再自动切到排序更靠前的
    private(set) var userSelected = false
    /// 已经开始搜的关键词（nil：还没搜过）
    private var searchedKeyword: String?
    /// 正在搜的片源（搜索任务归这个对象管，离开页面、去播放都不会打断）
    private var inFlight: Set<String> = []
    private var started = Date()
    /// 这部作品上次搜完时的片源顺序：还在搜的、没找到的按这个排，列表不乱跳
    private let rememberedOrder: [String: Int]

    private init(subject: BangumiSubject) {
        self.subject = subject
        keyword = subject.title
        let order = SourceMemory.shared.order(for: subject.id)
        rememberedOrder = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: 暂存

    /// 最近打开过的作品的搜索（只在内存里，最多 12 部）：去播放再回来、退回列表再点进同一部，
    /// 都直接用上次的结果，没搜完的接着搜；搜了 30 分钟以上的再打开时重新搜
    private static var recent: [Int: SourceSearch] = [:]
    private static let keepSeconds: TimeInterval = 30 * 60
    private var lastOpened = Date()

    static func shared(for subject: BangumiSubject) -> SourceSearch {
        let now = Date()
        if let search = recent[subject.id], now.timeIntervalSince(search.started) < keepSeconds {
            search.lastOpened = now
            return search
        }
        let search = SourceSearch(subject: subject)
        recent[subject.id] = search
        if recent.count > 12, let oldest = recent.min(by: { $0.value.lastOpened < $1.value.lastOpened }) {
            recent[oldest.key] = nil
        }
        return search
    }

    /// 片源列表：规则管理里的顺序（Kazumi 规则、采集站），然后是网盘资源站、猫影视插件
    static func candidates(entries: [RuleStore.Entry], uz: [CMSSource], cat: [CMSSource]) -> [Candidate] {
        var seen = Set<String>()
        var list: [Candidate] = []
        for entry in entries {
            let kind: SourceKind = entry.rule != nil ? .rule : .cms
            list.append(Candidate(id: entry.id, name: entry.name, kind: kind, rule: entry.rule, cms: entry.cms))
        }
        list += uz.map { Candidate(id: "cms:" + $0.id, name: $0.name, kind: .uz, rule: nil, cms: $0) }
        list += cat.map { Candidate(id: "cms:" + $0.id, name: $0.name, kind: .cat, rule: nil, cms: $0) }
        return list.filter { seen.insert($0.id).inserted }
    }

    // MARK: 状态

    func result(of candidate: Candidate) -> Result { results[candidate.id] ?? .loading }

    /// 还没开始搜（页面刚打开）也算在搜，免得按钮先闪一下「未找到」
    var isSearching: Bool {
        searchedKeyword == nil || candidates.contains { result(of: $0) == .loading }
    }

    var selected: Ranked? {
        guard let selectedID else { return nil }
        return ranked.first { $0.id == selectedID }
    }

    /// 还没出结果的片源按上次的顺序排
    func ordered(_ list: [Candidate]) -> [Candidate] {
        list.enumerated().sorted { a, b in
            let p = rememberedOrder[a.element.id] ?? Int.max, q = rememberedOrder[b.element.id] ?? Int.max
            return p != q ? p < q : a.offset < b.offset
        }.map(\.element)
    }

    func isPreferred(_ candidate: Candidate) -> Bool {
        SourceMemory.shared.preferred(for: subject.id) == candidate.id
    }

    func isLastWatched(_ candidate: Candidate) -> Bool {
        isLastWatched(candidate, record: WatchLibrary.shared.record(subject.id))
    }

    private func isLastWatched(_ candidate: Candidate, record: WatchRecord?) -> Bool {
        guard let record, !record.isComic, !record.isNovel else { return false }
        if let rule = candidate.rule { return !record.isCMSRecord && record.ruleName == rule.name }
        if let cms = candidate.cms { return record.isCMSRecord && record.cmsAPI.lowercased() == cms.url.lowercased() }
        return false
    }

    /// 当前片源大类顺序：没登录网盘时网盘片源放到最后（搜到了也播放不了）
    private var kindOrder: [SourceKind] {
        var order = SourceKindOrder.order
        if !UZStore.shared.hasNetdiskLogin, let index = order.firstIndex(of: .uz) {
            order.remove(at: index)
            order.append(.uz)
        }
        return order
    }

    private struct RankKey: Equatable {
        var version: Int
        var order: [SourceKind]
        var preferred: String?
        var record: String
    }

    /// 找到结果的片源，排好序。排序值分几段叠加，前一段永远压过后一段：
    /// 上次选的（2000）/ 上次看的（1000）→ 匹配档次（每档 100）→ 大类顺序（每类 20）→ 匹配度（-1.5…8）+ 自己排的顺序（0…1）。
    /// 页面一次刷新里会读好几遍，结果没变就用缓存
    var ranked: [Ranked] {
        let order = kindOrder
        let preferred = SourceMemory.shared.preferred(for: subject.id)
        let record = WatchLibrary.shared.record(subject.id)
        let key = RankKey(
            version: version, order: order, preferred: preferred,
            record: record.map { "\($0.ruleName)|\($0.cmsAPI)|\($0.vodID)|\($0.sourceURL)" } ?? ""
        )
        if let cache = rankedCache, cache.key == key { return cache.value }
        let value = computeRanked(order: order, preferred: preferred, record: record)
        rankedCache = (key, value)
        return value
    }

    private func computeRanked(order: [SourceKind], preferred: String?, record: WatchRecord?) -> [Ranked] {
        let list = candidates
        let targets = SourceScore.targets(keyword, subject)
        var found: [(index: Int, candidate: Candidate, hit: Hit)] = []
        for (index, candidate) in list.enumerated() {
            if case .found(let hit) = results[candidate.id] { found.append((index, candidate, hit)) }
        }
        let maxEpisodes = found.map { $0.hit.episodeCount }.max() ?? 0
        return found.map { entry -> Ranked in
            let hit = entry.hit
            var value = 0.0
            if entry.candidate.id == preferred { value += 2000 }
            if isLastWatched(entry.candidate, record: record) { value += 1000 }
            value += 100 * Double(SourceScore.level(
                name: hit.name, year: hit.year, episodeCount: hit.episodeCount, maxEpisodes: maxEpisodes,
                targets: targets, subject: subject
            ))
            let rank = order.firstIndex(of: entry.candidate.kind) ?? order.count
            value += 20 * Double(order.count - rank)
            value += SourceScore.match(name: hit.name, year: hit.year, episodeCount: hit.episodeCount, targets: targets, subject: subject)
            value += SourceScore.priority(index: entry.index, total: list.count)
            return Ranked(candidate: entry.candidate, hit: hit, value: value)
        }
        .sorted { $0.value > $1.value }
    }

    // MARK: 操作

    func setKeyword(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word != keyword else { return }
        userSelected = false
        keyword = word
    }

    /// 手动选一个片源：记住，这部作品下次打开排在最前面、默认选中
    func select(_ id: String) {
        userSelected = true
        SourceMemory.shared.setPreferred(id, for: subject.id)
        guard selectedID != id else { return }
        selectedRoad = initialRoad(for: id)
        selectedID = id
    }

    /// 选中片源时，上次在这个片源看到哪条线路就停在哪条
    private func initialRoad(for id: String) -> Int {
        guard let entry = ranked.first(where: { $0.id == id }) else { return 0 }
        guard let record = WatchLibrary.shared.record(subject.id), record.roadIndex < entry.hit.roads.count,
              matchesRecord(entry.candidate, entry.hit, record) else { return 0 }
        return record.roadIndex
    }

    private func matchesRecord(_ candidate: Candidate, _ hit: Hit, _ record: WatchRecord) -> Bool {
        if let item = hit.cms {
            return record.isCMSRecord && record.vodID == item.vodID && record.cmsAPI.lowercased() == item.api.lowercased()
        }
        if let item = hit.ruleItem, let rule = candidate.rule {
            return !record.isCMSRecord && record.ruleName == rule.name && record.sourceURL == item.url
        }
        return false
    }

    /// 播放记录停在选中片源的哪一集（当前线路）
    var recordEpisode: Int? {
        guard let selected, let record = WatchLibrary.shared.record(subject.id), record.roadIndex == selectedRoad,
              matchesRecord(selected.candidate, selected.hit, record) else { return nil }
        return record.episodeIndex
    }

    func playRequest(episode: Int) -> PlayRequest? {
        guard let selected else { return nil }
        var request: PlayRequest
        if let item = selected.hit.cms {
            request = PlayRequest(subject: subject, pick: .cms(item), episodeIndex: episode)
        } else if let rule = selected.candidate.rule, let item = selected.hit.ruleItem {
            request = PlayRequest(subject: subject, pick: .rule(rule, item), episodeIndex: episode)
        } else {
            return nil
        }
        request.roadIndex = selectedRoad
        if recordEpisode == episode, let record = WatchLibrary.shared.record(subject.id) {
            request.position = record.position
        }
        return request
    }

    /// 自动选中排最前的片源。结果陆续回来时，新的明显更靠前才换，免得来回跳
    private func autoSelect() {
        guard !userSelected else { return }
        let list = ranked
        guard let best = list.first, selectedID != best.id else { return }
        if let current = list.first(where: { $0.id == selectedID }), best.value < current.value + 0.5 { return }
        selectedID = best.id
        selectedRoad = initialRoad(for: best.id)
    }

    // MARK: 搜索

    /// 搜索所有片源：关键词变了从头搜；片源列表变了（增减片源）只补搜新加的，已有的结果留着。
    /// 搜索任务不跟页面走，去播放、离开页面都接着搜，回来直接看到结果
    func start(_ list: [Candidate]) {
        if searchedKeyword != keyword {
            searchedKeyword = keyword
            results = [:]
            timings = [:]
            inbox = [:]
            inFlight = []
            problemsExpanded = nil
            reportCopied = false
            if !userSelected { selectedID = nil }
            started = Date()
        }
        if candidates != list { candidates = list }
        let word = keyword
        let subject = subject
        let year = subject.airDate.count >= 4 ? String(subject.airDate.prefix(4)) : ""
        for candidate in list where results[candidate.id] == nil && !inFlight.contains(candidate.id) {
            inFlight.insert(candidate.id)
            Task { [weak self] in
                let result = await SourceSearch.fetch(candidate, keyword: word, year: year, subject: subject)
                self?.finish(candidate.id, result, keyword: word)
            }
        }
    }

    /// 全部重新搜一遍
    func refresh() {
        searchedKeyword = nil
        start(candidates)
    }

    private func finish(_ id: String, _ result: Result, keyword word: String) {
        guard word == searchedKeyword else { return }
        inFlight.remove(id)
        inbox[id] = result
        timings[id] = Date().timeIntervalSince(started)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.flush()
        }
    }

    /// 把攒下的结果一次交给页面：只刷新一次、只重排一次
    private func flush() {
        flushScheduled = false
        guard !inbox.isEmpty else { return }
        var merged = results
        for (id, result) in inbox { merged[id] = result }
        inbox = [:]
        results = merged
        autoSelect()
        // 搜完记住这次的顺序，下次打开先按它排
        if !isSearching {
            let found = ranked.map(\.id)
            let rest = ordered(candidates).map(\.id).filter { !found.contains($0) }
            SourceMemory.shared.setOrder(found + rest, for: subject.id)
        }
    }

    /// 重搜一个片源（出错后重试、网页验证完成后）
    func retry(_ candidate: Candidate, items: [SearchItem]? = nil) async {
        guard !inFlight.contains(candidate.id) else { return }
        let word = keyword
        inFlight.insert(candidate.id)
        results[candidate.id] = .loading
        let subject = subject
        let year = subject.airDate.count >= 4 ? String(subject.airDate.prefix(4)) : ""
        let result: Result
        if let items, !items.isEmpty, let rule = candidate.rule {
            result = await Self.ruleHit(rule, items: items, keyword: word, subject: subject)
        } else {
            result = await Self.fetch(candidate, keyword: word, year: year, subject: subject)
        }
        finish(candidate.id, result, keyword: word)
    }

    nonisolated static func fetch(_ candidate: Candidate, keyword: String, year: String, subject: BangumiSubject) async -> Result {
        if let rule = candidate.rule {
            do {
                let items = try await RuleEngine.search(rule, keyword: keyword)
                return await ruleHit(rule, items: items, keyword: keyword, subject: subject)
            } catch RuleError.captchaRequired {
                return .captcha
            } catch RuleError.noResult {
                return .empty
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        guard let cms = candidate.cms else { return .empty }
        do {
            switch candidate.kind {
            case .cat:
                // 猫影视插件的站点：插件包里搜索、取详情
                guard let item = try await CatStore.shared.searchBest(cms, keyword: keyword, year: year) else { return .empty }
                return .found(Hit(item))
            case .uz:
                // 网盘资源站：搜到后还要取详情、把分享链接展开成剧集
                guard let item = try await UZStore.shared.searchBest(cms, keyword: keyword, year: year) else { return .empty }
                return .found(Hit(item))
            default:
                let items = try await CMSSearchCache.shared.search(cms, keyword: keyword)
                guard let best = best(items, keyword: keyword, subject: subject) else { return .empty }
                return .found(Hit(best, total: items.count))
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Kazumi 规则：挑匹配度最高的一条，取它的选集
    nonisolated static func ruleHit(_ rule: Rule, items: [SearchItem], keyword: String, subject: BangumiSubject) async -> Result {
        let targets = SourceScore.targets(keyword, subject)
        let scored = items.enumerated().map { entry in
            (item: entry.element, offset: entry.offset,
             score: SourceScore.match(name: entry.element.name, year: "", episodeCount: 0, targets: targets, subject: subject))
        }
        guard let best = scored.max(by: { a, b in a.score != b.score ? a.score < b.score : a.offset > b.offset })?.item else {
            return .empty
        }
        do {
            let roads = try await RuleEngine.chapters(rule, source: best.url)
            return .found(Hit(best, roads: roads, total: items.count))
        } catch RuleError.captchaRequired {
            return .captcha
        } catch {
            return .failed("取选集失败：" + error.localizedDescription)
        }
    }

    /// 采集站：挑匹配度最高的一条（片名、年份、集数），一样高的取靠前的
    nonisolated static func best(_ items: [CMSItem], keyword: String, subject: BangumiSubject) -> CMSItem? {
        let targets = SourceScore.targets(keyword, subject)
        let scored = items.enumerated().map { entry in
            (item: entry.element, offset: entry.offset,
             score: SourceScore.match(name: entry.element.name, year: entry.element.year,
                                      episodeCount: entry.element.episodeCount, targets: targets, subject: subject))
        }
        return scored.max(by: { a, b in a.score != b.score ? a.score < b.score : a.offset > b.offset })?.item
    }

    /// 片名完全一致的优先，再按年份挑（网盘资源站、猫影视取详情前先挑一条）
    nonisolated static func bestMatch(_ items: [CMSItem], title: String, year: String) -> CMSItem? {
        let target = CMSClient.normalizeTitle(title)
        let exact = items.filter { CMSClient.normalizeTitle($0.name) == target }
        let pool = exact.isEmpty ? items : exact
        if !year.isEmpty, let sameYear = pool.first(where: { $0.year == year }) { return sameYear }
        return pool.first
    }

    // MARK: 出错原因

    struct Problem {
        let label: String
        let hint: String
    }

    /// 把各种报错归成几类：分得清是站点连不上、要登录、插件没运行，还是站点 / 扩展本身坏了
    nonisolated static func problem(_ message: String) -> Problem {
        let text = message.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["没有实现"]) || (has(["route"]) && has(["not found"])) {
            return Problem(label: "不支持搜索", hint: "这个扩展 / 插件站点只能浏览，不能按片名搜索，下次启动起不再参与搜索。")
        }
        if has(["登录", "bduss", "未授权"]) {
            return Problem(label: "需要登录", hint: "网盘没登录或者登录过期了。网盘资源的账号在「我的 → 片源 → 网盘资源 → 网盘账号」，猫影视插件的站点在插件的配置中心登录。")
        }
        if has(["插件运行环境", "插件启动", "还没有添加猫影视插件", "插件包里没有这个站点", "插件包运行出错"]) {
            return Problem(label: "插件没运行", hint: "到「我的 → 片源 → 猫影视插件」看运行状态和运行日志。")
        }
        if has([
            "timed out", "timeout", "超时", "could not connect", "无法连接", "connection was lost", "network connection",
            "tls", "ssl", "certificate", "证书", "offline", "hostname", "could not be found", "dns",
            "econnrefused", "econnreset", "etimedout", "enotfound", "eai_again", "socket hang up",
            "接口返回", "status code", "http error", "http 4", "http 5", "网络错误", "app transport security",
            "cloudflare", "turnstile", "429",
        ]) {
            return Problem(label: "站点连不上", hint: "网站打不开、太慢或者拦了请求（超时、证书、404 之类），和有没有这部片无关。过段时间再试，一直这样可以在设置里关掉这个片源。")
        }
        return Problem(label: "解析出错", hint: "网站改版了，或者扩展 / 插件 / 规则本身有问题，要等更新。点「复制报告」发给开发者可以帮忙定位。")
    }

    func problemText(_ candidate: Candidate) -> String {
        switch result(of: candidate) {
        case .failed(let message):
            let problem = Self.problem(message)
            return "\(problem.label)：\(problem.hint)\n\n原始信息：\(message)"
        case .empty:
            return "这个片源搜「\(keyword)」没有结果（或者结果的片名对不上）。片名叫法不一样的话，可以点「换个搜索词」。"
        case .captcha:
            return "这个站点要先在网页里完成验证，点「需要验证」打开网页。"
        default:
            return ""
        }
    }

    // MARK: 搜索报告

    /// 每个片源的搜索结果、出错原因和耗时，加上扩展 / 插件的日志，复制出来发给开发者排查
    func report(title: String) async -> String {
        var lines = [
            title,
            "片名：\(subject.title)　搜索词：\(keyword)　年份：\(subject.airDate)　集数：\(subject.episodes)",
            "大类顺序：\(kindOrder.map(\.label).joined(separator: " → "))",
            "",
        ]
        let rankedList = ranked
        let found = Set(rankedList.map(\.id))
        let rest = ordered(candidates.filter { !found.contains($0.id) })
        for (index, entry) in rankedList.enumerated() {
            let hit = entry.hit
            let time = timings[entry.id].map { String(format: "%.1f 秒", $0) } ?? ""
            let mark = entry.id == selectedID ? "（选中）" : ""
            lines.append(
                "✅ \(index + 1). \(entry.candidate.name)（\(entry.candidate.kind.label)）\(time)\(mark)：\(hit.name) \(hit.year) \(hit.remarks)，"
                    + "\(hit.roads.count) 条线路 \(hit.episodeCount) 集，共 \(hit.total) 个结果，排序值 \(String(format: "%.1f", entry.value))"
            )
        }
        for candidate in rest {
            let kind = candidate.kind.label
            let time = timings[candidate.id].map { String(format: "%.1f 秒", $0) } ?? ""
            switch result(of: candidate) {
            case .empty:
                lines.append("➖ \(candidate.name)（\(kind)）\(time)：没找到")
            case .loading:
                lines.append("⏳ \(candidate.name)（\(kind)）：还在搜")
            case .captcha:
                lines.append("🔒 \(candidate.name)（\(kind)）：需要网页验证")
            case .failed(let message):
                lines.append("❌ \(candidate.name)（\(kind)）\(time)：\(Self.problem(message).label)｜\(message)")
            case .found:
                break
            }
        }
        let uzLogs = Array(UZStore.shared.runtimeLogs.suffix(40))
        let catLines = Array(CatStore.shared.diagnostics.suffix(30))
        if !uzLogs.isEmpty { lines += ["", "—— uz 扩展日志 ——"] + uzLogs }
        if !catLines.isEmpty { lines += ["", "—— 猫影视插件 ——"] + catLines }
        if CatStore.shared.hasPackage {
            let node = await CatStore.shared.nodeLogs()
            if !node.isEmpty { lines += ["", "—— 插件输出 ——"] + node.suffix(60) }
        }
        return lines.joined(separator: "\n")
    }
}

extension WatchRecord {
    var isCMSRecord: Bool { !cmsAPI.isEmpty }
}
