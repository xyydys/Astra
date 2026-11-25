import Foundation
import AVFoundation
import Combine

@MainActor
final class PlayerModel: ObservableObject {
    enum Phase: Equatable {
        case loadingChapters
        case resolving
        case ready
        case failed(String)
    }

    let request: PlayRequest
    let rule: Rule?
    let mpv = MPVPlayback()
    let sniffer = VideoSniffer()

    @Published var roads: [Road] = []
    /// 正在浏览的线路（选集列表显示哪条线路）
    @Published var selectedRoad = 0
    /// 正在播放的线路 / 集
    @Published var playingRoad = 0
    @Published var playingEpisode: Int?
    @Published var phase: Phase = .loadingChapters {
        didSet {
            // 猫影视插件的片源出错时取一份插件的运行日志，复制日志时带上
            if case .failed = phase, CatStore.isCat(request.cmsAPI) {
                Task { [weak self] in
                    let logs = await CatStore.shared.nodeLogs()
                    self?.catLogs = logs
                }
            }
        }
    }
    /// 本集播放列表里去掉的广告分片数
    @Published var adSegmentsRemoved = 0
    @Published var isMPVFullscreen = false

    private var resolveTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    private var pendingSeek: Double = 0
    private var started = false
    private var tornDown = false
    private var lastResolvedURL = ""
    /// 当前正在使用的本地 HLS 播放列表路由
    private var hlsFilterSessionID: UUID?
    /// 去广告后播放失败过一次，本次播放不再过滤
    private var adFilterFailed = false
    /// 网盘片源：播放地址需要带的请求头（Cookie 等），以及其他清晰度（播放失败时依次换）
    private var extraHeaders: [String: String] = [:]
    private var alternates: [(url: String, headers: [String: String])] = []
    /// 本集试过的播放地址和结果（复制日志时带上）
    private var attempts: [String] = []
    /// 猫影视插件的运行日志（出错时取一份，复制日志时带上）
    private var catLogs: [String] = []
    /// mpv 播放中途断开后重新连接的次数
    private var mpvReconnects = 0

    init(request: PlayRequest, rule: Rule?) {
        self.request = request
        self.rule = rule
        mpv.onEnd = { [weak self] in self?.mpvEnded() }
        mpv.onFailure = { [weak self] message in self?.mpvFailed(message) }
        mpv.onProgress = { [weak self] in self?.saveProgress() }
    }

    var currentEpisode: Episode? {
        guard let ep = playingEpisode, roads.indices.contains(playingRoad),
              roads[playingRoad].episodes.indices.contains(ep) else { return nil }
        return roads[playingRoad].episodes[ep]
    }

    var hasNextEpisode: Bool {
        guard let ep = playingEpisode, roads.indices.contains(playingRoad) else { return false }
        return ep + 1 < roads[playingRoad].episodes.count
    }

    var debugLog: String {
        var lines: [String]
        if CatStore.isCat(request.cmsAPI) {
            lines = ["猫影视插件: \(request.ruleName)", "影片 id: \(request.vodID)"]
        } else if UZStore.isUZ(request.cmsAPI) {
            lines = ["网盘片源: \(request.ruleName)", "影片 id: \(request.vodID)"]
        } else if request.isCMS {
            lines = ["采集站: \(request.ruleName)", "接口: \(request.cmsAPI)", "影片 id: \(request.vodID)"]
        } else {
            lines = ["规则: \(rule?.name ?? request.ruleName)", "详情页: \(request.sourceURL)"]
        }
        if let ep = currentEpisode { lines.append("剧集页: \(ep.url)") }
        if case .failed(let message) = phase { lines.append("错误: \(message)") }
        if !lastResolvedURL.isEmpty { lines.append("视频: \(lastResolvedURL)") }
        if !lastResolvedURL.isEmpty { lines.append("播放内核: mpv") }
        lines.append(contentsOf: attempts)
        if adSegmentsRemoved > 0 { lines.append("去广告: 移除 \(adSegmentsRemoved) 个分片") }
        if adFilterFailed { lines.append("去广告: 过滤后播放失败，已改为原始播放列表") }
        lines.append(contentsOf: sniffer.logs)
        let mpvLogs = mpv.logs.suffix(60)
        if !mpvLogs.isEmpty {
            lines.append("—— mpv 日志 ——")
            lines.append(contentsOf: mpvLogs)
        }
        let proxyLogs = NetdiskProxy.shared.logs
        if UZStore.isUZ(request.cmsAPI), !proxyLogs.isEmpty {
            lines.append("—— 网盘代理 ——")
            lines.append(contentsOf: proxyLogs)
        }
        if UZStore.isUZ(request.cmsAPI) {
            let logs = UZStore.shared.runtimeLogs.suffix(60)
            if !logs.isEmpty {
                lines.append("—— 网盘扩展日志 ——")
                lines.append(contentsOf: logs)
            }
        }
        if CatStore.isCat(request.cmsAPI) {
            lines.append("—— 猫影视插件 ——")
            lines.append(contentsOf: CatStore.shared.diagnostics.suffix(20))
            lines.append(contentsOf: catLogs.suffix(40))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 生命周期

    func start() {
        guard !started else { return }
        started = true
        Task { await loadChapters() }
    }

    func loadChapters() async {
        if !request.isCMS, rule == nil {
            phase = .failed("找不到规则「\(request.ruleName)」，可能已经被删除")
            return
        }
        phase = .loadingChapters
        do {
            let result: [Road]
            if CatStore.isCat(request.cmsAPI) {
                // 猫影视插件：插件包里取详情
                let item = try await CatStore.shared.detail(api: request.cmsAPI, vodID: request.vodID)
                result = item.roads
                if result.isEmpty { throw RuleError.parse("这个片源没有可播放的剧集，换个片源试试") }
            } else if UZStore.isUZ(request.cmsAPI) {
                // 网盘片源：资源站详情 + 网盘分享展开成剧集
                let item = try await UZStore.shared.detail(api: request.cmsAPI, vodID: request.vodID)
                result = item.roads
                if result.isEmpty { throw RuleError.parse("这个片源没有可播放的剧集，换个片源试试") }
            } else if request.isCMS {
                // 采集站的详情里直接带每集的播放地址
                let item = try await CMSClient.detail(api: request.cmsAPI, vodID: request.vodID, sourceName: request.ruleName)
                result = item.roads
                if result.isEmpty { throw RuleError.parse("这个片源没有可播放的剧集，换个片源试试") }
            } else if let rule {
                result = try await RuleEngine.chapters(rule, source: request.sourceURL)
            } else {
                return
            }
            guard !tornDown else { return }
            roads = result
            let road = min(max(request.roadIndex, 0), result.count - 1)
            let episodes = result[road].episodes
            let episode = min(max(request.episodeIndex, 0), episodes.count - 1)
            selectedRoad = road
            play(road: road, episode: episode, startAt: request.position)
        } catch {
            guard !tornDown else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() {
        if roads.isEmpty {
            Task { await loadChapters() }
        } else if let ep = playingEpisode {
            play(road: playingRoad, episode: ep, startAt: lastResolvedURL.isEmpty ? pendingSeek : mpv.position)
        }
    }

    func play(road: Int, episode: Int, startAt: Double = 0) {
        guard request.isCMS || rule != nil,
              roads.indices.contains(road), roads[road].episodes.indices.contains(episode) else { return }
        if playingEpisode != nil { saveProgress() }

        playingRoad = road
        playingEpisode = episode
        phase = .resolving
        pendingSeek = startAt > 5 ? startAt : 0
        resolveTask?.cancel()
        sniffer.cancel()
        attachTask?.cancel()
        mpv.stop()
        clearHLSFilter()
        lastResolvedURL = ""
        adSegmentsRemoved = 0
        adFilterFailed = false
        extraHeaders = [:]
        alternates = []
        attempts = []
        mpvReconnects = 0
        saveRecord(position: startAt, duration: 0)

        let page = roads[road].episodes[episode].url
        if UZStore.isEpisodeURL(page) || CatStore.isEpisodeURL(page) {
            resolveTask = Task { [weak self] in
                guard let self else { return }
                do {
                    // 网盘：转存到自己网盘后取播放地址（带 Cookie 请求头）
                    let info = CatStore.isEpisodeURL(page)
                        ? try await CatStore.shared.resolve(page)
                        : try await UZStore.shared.resolve(page)
                    try Task.checkCancellation()
                    var url = info.url
                    if info.needsSniff, !CMSClient.isDirectMedia(url) {
                        url = try await self.sniffer.resolve(
                            pageURL: url, legacy: false,
                            userAgent: Self.header(named: "User-Agent", in: info.headers)
                        )
                    }
                    guard !Task.isCancelled, !self.tornDown else { return }
                    guard !url.isEmpty else { throw RuleError.parse("没有取到播放地址") }
                    self.alternates = info.alternates
                    // 网盘原文件走本地多线程代理（网盘按连接限速）；转码的 m3u8 直接播
                    // 插件包给的本机地址（它自己已经是多线程代理）不再套一层
                    let isLocal = URL(string: url)?.host == "127.0.0.1"
                    if !info.needsSniff, !isLocal, !url.lowercased().contains(".m3u8"), !info.headers.isEmpty || url.hasPrefix("http") {
                        do {
                            let proxied = try await NetdiskProxy.shared.register(url: url, headers: info.headers, fileName: info.fileName, mimeType: info.mimeType)
                            guard !Task.isCancelled, !self.tornDown else { return }
                            self.attempts.append("多线程代理: \(URL(string: url)?.host ?? "")")
                            self.alternates.insert((url, info.headers), at: 0)
                            self.attach(urlString: proxied.absoluteString, headers: [:])
                            return
                        } catch {
                            // 换集 / 退出时这个任务被取消了：不要再接着播
                            guard !Task.isCancelled, !self.tornDown else { return }
                            self.attempts.append("多线程代理不可用（\(error.localizedDescription)），直接播放")
                        }
                    }
                    self.attach(urlString: url, headers: info.headers)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, !self.tornDown else { return }
                    self.phase = .failed(error.localizedDescription)
                }
            }
            return
        }
        let legacy = rule?.useLegacyParser ?? false
        let direct = request.isCMS && CMSClient.isDirectMedia(page)
        resolveTask = Task { [weak self] in
            guard let self, !Task.isCancelled, !self.tornDown else { return }
            do {
                // 采集站大多直接给 m3u8；给的是网页中转页时和规则片源一样去嗅探
                let url = direct ? page : try await self.sniffer.resolve(
                    pageURL: page, legacy: legacy, userAgent: self.rule?.userAgent
                )
                guard !Task.isCancelled, !self.tornDown else { return }
                self.attach(urlString: url)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !self.tornDown else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func playNext() {
        guard hasNextEpisode, let ep = playingEpisode else { return }
        play(road: playingRoad, episode: ep + 1)
    }

    private func attach(urlString: String, headers extra: [String: String]? = nil) {
        guard let url = URL.lenient(urlString) else {
            phase = .failed("视频地址无效：\(urlString)")
            return
        }
        attachTask?.cancel()
        clearHLSFilter()
        lastResolvedURL = url.absoluteString
        if let extra { extraHeaders = extra }
        attempts.append("尝试播放（mpv）: \(url.host ?? "")\(url.path.suffix(60))\(extraHeaders.isEmpty ? "" : "（带 \(extraHeaders.keys.sorted().joined(separator: "/")) 请求头）")")

        let userAgent = rule?.userAgent ?? ""
        var headers = ["User-Agent": userAgent.isEmpty ? sniffer.userAgent : userAgent]
        if let referer = rule?.referer, !referer.isEmpty { headers["Referer"] = referer }
        for (key, value) in extraHeaders {
            if let previous = headers.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                headers.removeValue(forKey: previous)
            }
            headers[key] = value
        }

        // 需要 Cookie / 额外鉴权头的地址照旧直连；普通 HLS 播放列表保留去广告。
        guard extraHeaders.isEmpty, AppSettings.hlsAdFilter, !adFilterFailed,
              HLSAdBlockSession.canHandle(url) else {
            startMPV(url: url, headers: headers)
            return
        }

        attachTask = Task { [weak self] in
            do {
                let session = try await NetdiskProxy.shared.registerHLS(url: url, headers: headers) { [weak self] id, count in
                    Task { @MainActor [weak self] in
                        guard let self, self.hlsFilterSessionID == id else { return }
                        self.adSegmentsRemoved += count
                    }
                }
                guard let self, !Task.isCancelled, !self.tornDown else {
                    NetdiskProxy.shared.unregisterHLS(session.id)
                    return
                }
                self.hlsFilterSessionID = session.id
                self.startMPV(url: session.url, headers: headers)
            } catch {
                guard let self, !Task.isCancelled, !self.tornDown else { return }
                self.attempts.append("m3u8 去广告代理不可用，直接播放")
                self.startMPV(url: url, headers: headers)
            }
        }
    }

    private static func header(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func clearHLSFilter() {
        if let id = hlsFilterSessionID {
            NetdiskProxy.shared.unregisterHLS(id)
            hlsFilterSessionID = nil
        }
    }

    private func startMPV(url: URL, headers: [String: String]) {
        phase = .ready
        MusicPlayer.shared.pause()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let start = pendingSeek
        pendingSeek = 0
        mpv.load(url: url.absoluteString, headers: headers, start: start)
    }

    private func mpvFailed(_ message: String) {
        guard !tornDown, phase == .ready else { return }
        attempts.append("mpv 播放失败: \(message)")
        if hlsFilterSessionID != nil, !adFilterFailed, !lastResolvedURL.isEmpty {
            adFilterFailed = true
            adSegmentsRemoved = 0
            pendingSeek = mpv.position > 5 ? mpv.position : 0
            attach(urlString: lastResolvedURL)
            return
        }
        // 网盘：换下一个地址（直连 / 其他清晰度）
        if !alternates.isEmpty {
            let next = alternates.removeFirst()
            if mpv.position > 5 { pendingSeek = mpv.position }
            attach(urlString: next.url, headers: next.headers)
            return
        }
        phase = .failed("播放失败：\(message)。可以重试，或者换条线路 / 换个片源")
    }

    private func mpvEnded() {
        guard !tornDown, phase == .ready else { return }
        let position = mpv.position
        let duration = mpv.duration
        // 网络断开时 mpv 也会当成播完：离结尾还远，就从断开的地方重新连
        if duration > 60, position < duration - 30, mpvReconnects < 3, !lastResolvedURL.isEmpty {
            mpvReconnects += 1
            attempts.append("播放在 \(Int(position)) 秒处中断，重新连接")
            pendingSeek = position
            attach(urlString: lastResolvedURL)
            return
        }
        saveProgress()
        playNext()
    }

    func setMPVFullscreen(_ on: Bool) {
        if on {
            guard !isMPVFullscreen else { return }
            isMPVFullscreen = true
            MPVFullscreenManager.shared.present(model: self)
        } else {
            guard isMPVFullscreen else { return }
            MPVFullscreenManager.shared.dismiss(model: self)
        }
    }

    func finishMPVFullscreenExit() {
        if isMPVFullscreen {
            isMPVFullscreen = false
        }
    }

    /// 真正离开播放页时调用（打开播放器全屏时保留当前播放）
    func teardown() {
        guard !tornDown else { return }
        saveProgress()
        tornDown = true
        resolveTask?.cancel()
        attachTask?.cancel()
        sniffer.cancel()
        clearHLSFilter()
        mpv.destroy()
        if isMPVFullscreen {
            MPVFullscreenManager.shared.dismiss(model: self)
        }
        isMPVFullscreen = false
        ScreenOrientation.set(.portrait)
    }

    // MARK: 观看记录

    func saveProgress() {
        guard !tornDown, playingEpisode != nil, phase == .ready else { return }
        let position = mpv.position
        guard position > 0 else { return }
        saveRecord(position: position, duration: mpv.duration)
    }

    private func saveRecord(position: Double, duration: Double) {
        guard let episode = currentEpisode else { return }
        let ruleName = request.isCMS ? request.ruleName : (rule?.name ?? request.ruleName)
        WatchLibrary.shared.updateRecord(request.subjectID) { record in
            record.title = request.title
            record.name = request.name
            record.image = request.image
            record.ruleName = ruleName
            record.cmsAPI = request.cmsAPI
            record.vodID = request.vodID
            record.sourceURL = request.sourceURL
            record.sourceTitle = request.sourceTitle
            record.roadIndex = playingRoad
            record.episodeIndex = playingEpisode ?? 0
            record.episodeName = episode.name
            record.position = position
            if duration > 0 { record.duration = duration } else if position == 0 { record.duration = 0 }
            record.updatedAt = Date()
        }
    }
}
