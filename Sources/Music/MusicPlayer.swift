import AVFoundation
import MediaPlayer
import UIKit

/// 播放进度（见 MusicPlayer.clock）
@MainActor
final class MusicClock: ObservableObject {
    @Published var time: Double = 0
}

/// 音乐播放：队列、AVPlayer、锁屏控制、歌词
@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    enum RepeatMode: String, CaseIterable {
        case list, one, shuffle

        var icon: String {
            switch self {
            case .list: return "repeat"
            case .one: return "repeat.1"
            case .shuffle: return "shuffle"
            }
        }

        var name: String {
            switch self {
            case .list: return "列表循环"
            case .one: return "单曲循环"
            case .shuffle: return "随机播放"
            }
        }
    }

    @Published private(set) var queue: [MusicTrack] = []
    @Published private(set) var index = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var lyric: LyricPayload?
    /// 换歌、换歌词时加 1（歌词特效页据此重新推送）
    @Published private(set) var songRevision = 0
    /// 播放 / 暂停 / 拖动进度时加 1（歌词特效页据此校准时钟）
    @Published private(set) var clockRevision = 0
    @Published var error: String?
    @Published var repeatMode: RepeatMode {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "musicRepeatMode") }
    }

    /// 进度条用的时间（每 0.25 秒更新一次）。放在单独的对象里，只有进度条跟着刷新，
    /// 观察播放器的其他界面（列表、特效菜单等）不会每 0.25 秒重绘一次
    let clock = MusicClock()

    private(set) var displayTime: Double {
        get { clock.time }
        set { clock.time = newValue }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var remoteConfigured = false

    var current: MusicTrack? { queue.indices.contains(index) ? queue[index] : nil }

    /// 精确的当前播放时间（给歌词时钟用）
    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    private init() {
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "musicRepeatMode") ?? "") ?? .list
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.displayTime = seconds }
                if let item = self.player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite, total > 0, abs(total - self.duration) > 0.5 {
                        self.duration = total
                        self.clockRevision += 1
                        self.updateNowPlaying()
                    }
                }
            }
        }
    }

    // MARK: 队列

    /// 播放一首歌；传入列表时用这个列表替换队列
    func play(_ track: MusicTrack, in list: [MusicTrack]? = nil) {
        if let list, !list.isEmpty {
            queue = list
            index = list.firstIndex { $0.id == track.id } ?? 0
            if !queue.indices.contains(index) || queue[index].id != track.id {
                queue.insert(track, at: 0)
                index = 0
            }
        } else if let existing = queue.firstIndex(where: { $0.id == track.id }) {
            index = existing
        } else {
            let insertAt = queue.isEmpty ? 0 : index + 1
            queue.insert(track, at: min(insertAt, queue.count))
            index = min(insertAt, queue.count - 1)
        }
        load()
    }

    func playNext(_ track: MusicTrack) {
        if queue.isEmpty {
            play(track)
            return
        }
        if let existing = queue.firstIndex(where: { $0.id == track.id }) {
            if existing == index { return }
            queue.remove(at: existing)
            if existing < index { index -= 1 }
        }
        queue.insert(track, at: index + 1)
    }

    func removeFromQueue(at offsets: IndexSet) {
        let removingCurrent = offsets.contains(index)
        let before = offsets.filter { $0 < index }.count
        queue.remove(atOffsets: offsets)
        index -= before
        if queue.isEmpty {
            stop()
        } else if removingCurrent {
            index = min(index, queue.count - 1)
            load()
        }
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if auto, repeatMode == .one {
            seek(to: 0)
            player.play()
            return
        }
        if repeatMode == .shuffle, queue.count > 1 {
            var next = index
            while next == index { next = Int.random(in: 0..<queue.count) }
            index = next
        } else {
            index = (index + 1) % queue.count
        }
        load()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 5 {
            seek(to: 0)
            return
        }
        index = (index - 1 + queue.count) % queue.count
        load()
    }

    func togglePlay() {
        guard current != nil else { return }
        if isPlaying {
            pause()
        } else if player.currentItem == nil {
            load()
        } else {
            resume()
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        clockRevision += 1
        updateNowPlaying()
    }

    func resume() {
        activateSession()
        player.play()
        isPlaying = true
        clockRevision += 1
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        displayTime = max(seconds, 0)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.clockRevision += 1
                self?.updateNowPlaying()
            }
        }
        clockRevision += 1
    }

    func stop() {
        loadTask?.cancel()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isLoading = false
        index = -1
        lyric = nil
        duration = 0
        displayTime = 0
        songRevision += 1
        clockRevision += 1
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: 加载

    private func load() {
        guard let track = current else { return }
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isLoading = true
        error = nil
        lyric = nil
        duration = track.duration
        displayTime = 0
        artwork = nil
        songRevision += 1
        clockRevision += 1
        configureRemote()
        updateNowPlaying()
        MusicLibrary.shared.recordPlay(track)

        let trackID = track.id
        let initial = track
        loadTask = Task { [weak self] in
            async let lyricResult = try? MusicPlatformAPI.lyric(initial)
            var working = initial
            if working.cover.isEmpty, let cover = await MusicPlatformAPI.cover(working) {
                working.cover = cover
                self?.updateTrack(working)
            }
            let withCover = working
            Task { [weak self] in await self?.loadArtwork(for: withCover) }
            do {
                let url = try await LXSourceStore.shared.resolveURL(for: withCover)
                guard let self, !Task.isCancelled, self.current?.id == trackID else { return }
                self.startPlayback(url)
            } catch {
                guard let self, !Task.isCancelled, self.current?.id == trackID else { return }
                self.isLoading = false
                self.error = error.localizedDescription
            }
            let lyric = await lyricResult
            guard let self, !Task.isCancelled, self.current?.id == trackID else { return }
            self.lyric = lyric
            self.songRevision += 1
        }
    }

    private func updateTrack(_ track: MusicTrack) {
        guard let i = queue.firstIndex(where: { $0.id == track.id }) else { return }
        queue[i] = track
        MusicLibrary.shared.updateCover(track)
        songRevision += 1
    }

    private func startPlayback(_ url: String) {
        guard let target = URL(string: url) ?? URL.lenient(url) else {
            isLoading = false
            error = "播放地址无效"
            return
        }
        activateSession()
        let asset = AVURLAsset(url: target, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": MusicPlatformAPI.pcUA]])
        let item = AVPlayerItem(asset: asset)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.next(auto: true) }
        }
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.error = "播放中断：\(error?.localizedDescription ?? "未知原因")"
            }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.clockRevision += 1
                case .failed:
                    self.isLoading = false
                    self.isPlaying = false
                    self.error = "无法播放：\(item.error?.localizedDescription ?? "音源返回的地址打不开")"
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        clockRevision += 1
        updateNowPlaying()
    }

    private func activateSession() {
        // 音乐用 .default 模式，视频播放页会切回 moviePlayback
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: 锁屏 / 控制中心

    private func configureRemote() {
        guard !remoteConfigured else { return }
        remoteConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.singer,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for track: MusicTrack) async {
        guard !track.cover.isEmpty, let image = await ImageCache.shared.load(track.cover) else { return }
        guard current?.id == track.id else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        updateNowPlaying()
    }
}
