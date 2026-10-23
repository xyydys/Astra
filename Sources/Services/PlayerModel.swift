import Foundation
import AVFoundation
import UIKit

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
    let player = AVPlayer()
    let sniffer = VideoSniffer()

    @Published var roads: [Road] = []
    /// 正在浏览的线路（选集列表显示哪条线路）
    @Published var selectedRoad = 0
    /// 正在播放的线路 / 集
    @Published var playingRoad = 0
    @Published var playingEpisode: Int?
    @Published var phase: Phase = .loadingChapters
    @Published var isFullscreen = false
    @Published var isPictureInPicture = false
    /// 本集播放列表里去掉的广告分片数
    @Published var adSegmentsRemoved = 0

    private var resolveTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var pendingSeek: Double = 0
    private var started = false
    private var tornDown = false
    private var lastResolvedURL = ""
    /// 去广告的资源加载代理（AVAssetResourceLoader 只弱引用它，要自己持有）
    private var adLoader: HLSAdBlockLoader?
    /// 去广告后播放失败过一次，本次播放不再过滤
    private var adFilterFailed = false

    init(request: PlayRequest, rule: Rule?) {
        self.request = request
        self.rule = rule
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveProgress()
            }
        }
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
        if request.isCMS {
            lines = ["采集站: \(request.ruleName)", "接口: \(request.cmsAPI)", "影片 id: \(request.vodID)"]
        } else {
            lines = ["规则: \(rule?.name ?? request.ruleName)", "详情页: \(request.sourceURL)"]
        }
        if let ep = currentEpisode { lines.append("剧集页: \(ep.url)") }
        if !lastResolvedURL.isEmpty { lines.append("视频: \(lastResolvedURL)") }
        if adSegmentsRemoved > 0 { lines.append("去广告: 移除 \(adSegmentsRemoved) 个分片") }
        if adFilterFailed { lines.append("去广告: 过滤后播放失败，已改为原始播放列表") }
        lines.append(contentsOf: sniffer.logs)
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
            if request.isCMS {
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
            let position = player.currentTime().seconds
            play(road: playingRoad, episode: ep, startAt: position.isFinite ? position : 0)
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        lastResolvedURL = ""
        adSegmentsRemoved = 0
        adFilterFailed = false
        saveRecord(position: startAt, duration: 0)

        let page = roads[road].episodes[episode].url
        let legacy = rule?.useLegacyParser ?? false
        let direct = request.isCMS && CMSClient.isDirectMedia(page)
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 采集站大多直接给 m3u8；给的是网页中转页时和规则片源一样去嗅探
                let url = direct ? page : try await self.sniffer.resolve(pageURL: page, legacy: legacy)
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

    private func attach(urlString: String) {
        guard let url = URL.lenient(urlString) else {
            phase = .failed("视频地址无效：\(urlString)")
            return
        }
        lastResolvedURL = url.absoluteString

        let userAgent = rule?.userAgent ?? ""
        var headers = ["User-Agent": userAgent.isEmpty ? sniffer.userAgent : userAgent]
        if let referer = rule?.referer, !referer.isEmpty { headers["Referer"] = referer }

        let asset: AVURLAsset
        if AppSettings.hlsAdFilter, !adFilterFailed, HLSAdBlockLoader.canHandle(url) {
            let loader = HLSAdBlockLoader(headers: headers)
            loader.onFiltered = { [weak self] count in
                Task { @MainActor in self?.adSegmentsRemoved += count }
            }
            adLoader = loader
            asset = loader.makeAsset(url: url)
        } else {
            adLoader = nil
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        let item = AVPlayerItem(asset: asset)

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                self?.handle(status: status, error: message)
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveProgress()
                self?.playNext()
            }
        }

        player.replaceCurrentItem(with: item)
        phase = .ready
        MusicPlayer.shared.pause()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        player.play()
    }

    private func handle(status: AVPlayerItem.Status, error: String?) {
        switch status {
        case .readyToPlay:
            if pendingSeek > 0 {
                let target = CMTime(seconds: pendingSeek, preferredTimescale: 600)
                pendingSeek = 0
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
            }
        case .failed:
            // 去广告改写过的播放列表放不了：退回原始播放列表再试一次，从当前位置继续
            if adLoader != nil, !adFilterFailed, !lastResolvedURL.isEmpty {
                adFilterFailed = true
                let position = player.currentTime().seconds
                if position.isFinite, position > 5 { pendingSeek = position }
                attach(urlString: lastResolvedURL)
                return
            }
            phase = .failed("播放失败：\(error ?? "未知错误")。可以重试，或者换条线路 / 换个片源")
        default:
            break
        }
    }

    /// 真正离开播放页时调用（进入全屏 / 画中画时不调用）
    func teardown() {
        guard !tornDown else { return }
        saveProgress()
        tornDown = true
        resolveTask?.cancel()
        sniffer.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    // MARK: 观看记录

    func saveProgress() {
        guard !tornDown, playingEpisode != nil, phase == .ready else { return }
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        guard position.isFinite, position > 0 else { return }
        saveRecord(position: position, duration: duration.isFinite ? duration : 0)
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
