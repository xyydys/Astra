import Foundation
import UIKit
import AVFoundation
import Libmpv

/// 哪些格式交给 mpv：系统播放器放不了的封装（MKV、AVI、RMVB、FLV…）
enum MPVFormats {
    static let formats: Set<String> = [
        "mkv", "mk3d", "avi", "divx", "rmvb", "rm", "flv", "f4v", "wmv", "asf", "webm", "ogv",
        "ts", "m2ts", "mts", "tp", "trp", "mpg", "mpeg", "vob", "iso", "3gp", "dat",
    ]
    /// 系统播放器能放、而且有画中画 / 隔空播放的格式
    static let systemFormats: Set<String> = ["m3u8", "mp4", "m4v", "mov"]

    /// 地址或网盘文件名的扩展名是 mpv 格式
    static func needsMPV(fileName: String, url: URL) -> Bool {
        let urlExt = url.pathExtension.lowercased()
        if systemFormats.contains(urlExt) { return false }
        let nameExt = (fileName as NSString).pathExtension.lowercased()
        return formats.contains(nameExt) || formats.contains(urlExt)
    }

    static func isMPVMedia(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        return formats.contains(parsed.pathExtension.lowercased())
    }
}

/// mpv 播放内核（libmpv，Metal 画面）。系统播放器放不了的格式用它播，
/// 系统播放器播放失败时也会自动换成它再试一次
@MainActor
final class MPVPlayback: ObservableObject {
    struct Track: Identifiable, Equatable, Sendable {
        let id: Int
        let title: String
        let selected: Bool
    }

    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    /// 已经缓冲到的位置
    @Published private(set) var cachedUntil: Double = 0
    @Published private(set) var isPaused = false
    @Published private(set) var isBuffering = true
    @Published private(set) var isLoaded = false
    @Published private(set) var speed: Double = 1
    /// 画面宽高比（全屏时决定要不要转横屏）
    @Published private(set) var videoAspect: Double = 16.0 / 9.0
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var subtitleOff = true
    /// 播放信息（网速、缓冲、码率、解码方式），打开「播放信息」时每秒刷新
    @Published private(set) var stats: MPVStats?
    @Published var showStats = false {
        didSet { showStats ? startStats() : stopStats() }
    }

    var onEnd: (() -> Void)?
    var onFailure: ((String) -> Void)?
    /// 大约每 5 秒一次（保存观看进度）
    var onProgress: (() -> Void)?

    let surface = MPVSurfaceView()
    private var core: MPVCore?
    private var finalLogs: [String] = []
    private var waitingForPlayback = true
    private var waitingForCache = false
    private var progressTick = -1
    private var resumeAfterBackground = false
    private var observers: [NSObjectProtocol] = []
    private var statsTimer: Timer?

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterForeground() }
        })
    }

    /// mpv 的警告和错误（复制日志时带上）
    var logs: [String] { core?.logSnapshot ?? finalLogs }

    // MARK: 控制

    func load(url: String, headers: [String: String], start: Double) {
        if core == nil {
            let sink: @Sendable (MPVUpdate) -> Void = { [weak self] update in
                guard let owner = self else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { owner.apply(update) }
                }
            }
            core = MPVCore(layer: surface.metalLayer, sink: sink)
            guard core != nil else {
                onFailure?("mpv 初始化失败")
                return
            }
        }
        position = max(start, 0)
        duration = 0
        cachedUntil = 0
        isPaused = false
        isLoaded = false
        waitingForPlayback = true
        waitingForCache = false
        isBuffering = true
        audioTracks = []
        subtitleTracks = []
        subtitleOff = true
        progressTick = -1
        core?.load(url: url, headers: headers, start: start)
    }

    func stop() {
        guard let core else { return }
        core.command(["stop"])
        isLoaded = false
    }

    func togglePause() { setPaused(!isPaused) }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        core?.set("pause", paused ? "yes" : "no")
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        position = target
        core?.command(["seek", String(format: "%.3f", target), "absolute"])
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func selectAudio(_ id: Int) { core?.set("aid", String(id)) }

    func selectSubtitle(_ id: Int?) { core?.set("sid", id.map(String.init) ?? "no") }

    func setSpeed(_ value: Double) {
        speed = value
        core?.set("speed", String(format: "%.2f", value))
    }

    /// 离开播放页时调用，之后不能再用
    func destroy() {
        stopStats()
        finalLogs = core?.logSnapshot ?? finalLogs
        core?.destroy()
        core = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    // MARK: 播放信息

    private func startStats() {
        statsTimer?.invalidate()
        refreshStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
    }

    private func stopStats() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func refreshStats() {
        core?.readStats { [weak self] stats in
            guard let owner = self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard owner.showStats else { return }
                    owner.stats = stats
                }
            }
        }
    }

    // MARK: 前后台

    /// 后台不能用 GPU 画画面：关掉视频轨，回到前台再打开（不然回来是黑屏）
    private func enterBackground() {
        guard let core else { return }
        resumeAfterBackground = isLoaded && !isPaused
        if resumeAfterBackground { setPaused(true) }
        core.set("vid", "no")
    }

    private func enterForeground() {
        guard let core else { return }
        core.set("vid", "auto")
        if resumeAfterBackground { setPaused(false) }
        resumeAfterBackground = false
    }

    // MARK: 状态

    private func apply(_ update: MPVUpdate) {
        guard core != nil else { return }
        switch update {
        case .time(let value):
            position = value
            let tick = Int(value / 5)
            if tick != progressTick {
                progressTick = tick
                onProgress?()
            }
        case .duration(let value):
            // 播完以后 duration 会变成没有值，留着最后一次的
            if value > 0 { duration = value }
        case .cache(let value):
            cachedUntil = value
        case .paused(let value):
            isPaused = value
        case .waitingForCache(let value):
            waitingForCache = value
        case .speed(let value):
            speed = value
        case .aspect(let value):
            if value > 0 { videoAspect = value }
        case .loaded:
            isLoaded = true
        case .playbackRestart:
            waitingForPlayback = false
        case .seeking:
            waitingForPlayback = true
        case .tracks(let audio, let subtitles, let off):
            audioTracks = audio
            subtitleTracks = subtitles
            subtitleOff = off
        case .ended:
            onEnd?()
        case .failed(let message):
            onFailure?(message)
        }
        let buffering = waitingForPlayback || waitingForCache
        if buffering != isBuffering {
            isBuffering = buffering
            // 播放中途卡住：记下当时的网速和码率，复制日志时能看出是网速不够还是解码跟不上
            if buffering, waitingForCache, isLoaded { core?.noteStall(at: position) }
        }
    }
}

// MARK: - 画面

/// MoltenVK 交换链有时会把 drawableSize 设成 1x1 来强制结束显示，会闪烁甚至一直停在 1x1：忽略这种尺寸
/// （mpv 的做法：https://github.com/mpv-player/mpv/pull/13651）
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }
}

final class MPVSurfaceView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }

    var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        if contentScaleFactor != scale { contentScaleFactor = scale }
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

// MARK: - libmpv

struct MPVStats: Sendable, Equatable {
    /// 网络读取速度（字节 / 秒）
    var speed: Double = 0
    /// 已经缓冲的秒数
    var buffered: Double = 0
    /// 平均码率（比特 / 秒，文件大小 ÷ 时长）
    var bitrate: Double = 0
    var hwdec = ""
    var codec = ""
    var width = 0
    var height = 0
    var dropped = 0

    var speedText: String { String(format: "%.1f MB/s", speed / 1_048_576) }
    /// 流畅播放需要的网速
    var neededText: String { bitrate > 0 ? String(format: "%.1f MB/s", bitrate / 8 / 1_048_576) : "未知" }
    var bitrateText: String { bitrate > 0 ? String(format: "%.1f Mbps", bitrate / 1_000_000) : "未知" }
    var decoderText: String {
        hwdec.isEmpty || hwdec == "no" ? "软件解码" : "硬件解码（\(hwdec)）"
    }

    var summary: String {
        var parts = ["网速 \(speedText)", "需要 \(neededText)", String(format: "缓冲 %.0f 秒", buffered), decoderText]
        if width > 0 { parts.append("\(codec.uppercased()) \(width)×\(height)") }
        if dropped > 0 { parts.append("丢帧 \(dropped)") }
        return parts.joined(separator: "，")
    }
}

enum MPVUpdate: Sendable {
    case time(Double)
    case duration(Double)
    case cache(Double)
    case paused(Bool)
    case waitingForCache(Bool)
    case speed(Double)
    case aspect(Double)
    case loaded
    case playbackRestart
    case seeking
    case tracks([MPVPlayback.Track], [MPVPlayback.Track], Bool)
    case ended
    case failed(String)
}

/// libmpv 句柄：所有调用都在自己的串行队列上做，事件也在这个队列上读
private final class MPVCore: @unchecked Sendable {
    private enum Observed: UInt64 {
        case time = 1, duration, pause, pausedForCache, cacheTime, speed, aspect, trackCount, audio, subtitle
    }

    private static let defaultAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private let queue = DispatchQueue(label: "astra.mpv", qos: .userInitiated)
    private var handle: OpaquePointer?
    /// mpv 往这个图层上画，要保证它比 mpv 活得久
    private let layer: CAMetalLayer
    private let sink: @Sendable (MPVUpdate) -> Void
    private let logLock = NSLock()
    private var logLines: [String] = []
    private var lastError = ""
    private var lastTime = -1.0
    private var lastCache = -1.0

    init?(layer: CAMetalLayer, sink: @escaping @Sendable (MPVUpdate) -> Void) {
        guard let created = mpv_create() else { return nil }
        handle = created
        self.layer = layer
        self.sink = sink

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(created, "wid", MPV_FORMAT_INT64, &wid)
        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            // 硬件解码；画面直通不了时退到硬件解码后拷贝，不至于变成纯软件解码
            ("hwdec", "videotoolbox,videotoolbox-copy"),
            ("video-rotate", "no"),
            ("idle", "yes"),
            ("keep-open", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("ytdl", "no"),
            ("load-scripts", "no"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "200MiB"),
            ("demuxer-max-back-bytes", "50MiB"),
            // 缓冲不够时先攒 4 秒再播（默认 1 秒，网速勉强够的时候会播一下停一下）
            ("cache-pause-wait", "4"),
            ("cache-pause-initial", "yes"),
            ("network-timeout", "30"),
            ("tls-verify", "no"),
            // 字幕：优先简体中文，没有就用文件里标成默认的那条
            ("slang", "chs,sc,zh-hans,zh-cn,chi,zho,zh,cht,tc,zh-hant"),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("sub-font", "PingFang SC"),
        ]
        for (name, value) in options { mpv_set_option_string(created, name, value) }
        mpv_request_log_messages(created, "warn")
        guard mpv_initialize(created) >= 0 else {
            mpv_terminate_destroy(created)
            handle = nil
            return nil
        }

        mpv_observe_property(created, Observed.time.rawValue, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(created, Observed.duration.rawValue, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(created, Observed.pause.rawValue, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(created, Observed.pausedForCache.rawValue, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(created, Observed.cacheTime.rawValue, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(created, Observed.speed.rawValue, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(created, Observed.aspect.rawValue, "video-params/aspect", MPV_FORMAT_DOUBLE)
        mpv_observe_property(created, Observed.trackCount.rawValue, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(created, Observed.audio.rawValue, "aid", MPV_FORMAT_STRING)
        mpv_observe_property(created, Observed.subtitle.rawValue, "sid", MPV_FORMAT_STRING)

        // 回调在 mpv 的线程上，里面不能调 mpv 的接口：转到自己的队列去读事件
        mpv_set_wakeup_callback(created, { context in
            guard let context else { return }
            Unmanaged<MPVCore>.fromOpaque(context).takeUnretainedValue().wake()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        // 正常情况下 destroy() 已经销毁了，这里兜底
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
    }

    var logSnapshot: [String] {
        logLock.lock()
        defer { logLock.unlock() }
        return logLines
    }

    // MARK: 命令

    func load(url: String, headers: [String: String], start: Double) {
        queue.async { [self] in
            guard let handle else { return }
            lastTime = -1
            lastCache = -1
            lastError = ""
            var agent = ""
            mpv_set_property_string(handle, "http-header-fields", "")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                if key.lowercased() == "user-agent" {
                    agent = value
                    continue
                }
                // append 是整条加进去，Cookie 里的逗号不会被拆开
                run(["change-list", "http-header-fields", "append", "\(key): \(value)"])
            }
            mpv_set_property_string(handle, "user-agent", agent.isEmpty ? Self.defaultAgent : agent)
            mpv_set_property_string(handle, "start", start > 1 ? String(format: "%.1f", start) : "none")
            run(["loadfile", url, "replace"])
        }
    }

    func command(_ args: [String]) {
        queue.async { [self] in run(args) }
    }

    func set(_ name: String, _ value: String) {
        queue.async { [self] in
            guard let handle else { return }
            mpv_set_property_string(handle, name, value)
        }
    }

    func readStats(_ completion: @escaping @Sendable (MPVStats) -> Void) {
        queue.async { [self] in
            guard handle != nil else { return }
            completion(currentStats())
        }
    }

    func noteStall(at position: Double) {
        queue.async { [self] in
            guard handle != nil else { return }
            appendLog(String(format: "卡顿（%.0f 秒处）：", position) + currentStats().summary)
        }
    }

    private func currentStats() -> MPVStats {
        var stats = MPVStats()
        stats.speed = Double(string("cache-speed") ?? "") ?? 0
        stats.buffered = Double(string("demuxer-cache-duration") ?? "") ?? 0
        let size = Double(string("file-size") ?? "") ?? 0
        let duration = Double(string("duration") ?? "") ?? 0
        if size > 0, duration > 0 { stats.bitrate = size * 8 / duration }
        stats.hwdec = string("hwdec-current") ?? ""
        stats.codec = string("video-format") ?? ""
        stats.width = Int(string("video-params/w") ?? "") ?? 0
        stats.height = Int(string("video-params/h") ?? "") ?? 0
        stats.dropped = (Int(string("frame-drop-count") ?? "") ?? 0) + (Int(string("decoder-frame-drop-count") ?? "") ?? 0)
        return stats
    }

    func destroy() {
        queue.async { [self] in
            guard let handle else { return }
            mpv_set_wakeup_callback(handle, nil, nil)
            self.handle = nil
            mpv_terminate_destroy(handle)
        }
    }

    private func run(_ args: [String]) {
        guard let handle else { return }
        var pointers: [UnsafePointer<CChar>?] = args.map { arg -> UnsafePointer<CChar>? in
            guard let copy = strdup(arg) else { return nil }
            return UnsafePointer(copy)
        }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                if let pointer { free(UnsafeMutablePointer(mutating: pointer)) }
            }
        }
        let status = pointers.withUnsafeMutableBufferPointer { buffer in
            mpv_command(handle, buffer.baseAddress)
        }
        if status < 0 {
            appendLog("命令 \(args.first ?? "") 失败：\(String(cString: mpv_error_string(status)))")
        }
    }

    private func string(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    // MARK: 事件

    private func wake() {
        queue.async { [self] in drain() }
    }

    private func drain() {
        while let handle {
            guard let event = mpv_wait_event(handle, 0) else { break }
            if event.pointee.event_id == MPV_EVENT_NONE { break }
            process(event.pointee)
        }
    }

    private func process(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            property(event.reply_userdata, data.assumingMemoryBound(to: mpv_event_property.self).pointee)
        case MPV_EVENT_FILE_LOADED:
            sink(.loaded)
            sendTracks()
        case MPV_EVENT_PLAYBACK_RESTART:
            sink(.playbackRestart)
        case MPV_EVENT_SEEK:
            sink(.seeking)
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if end.reason == MPV_END_FILE_REASON_EOF {
                sink(.ended)
            } else if end.reason == MPV_END_FILE_REASON_ERROR {
                let reason = String(cString: mpv_error_string(end.error))
                sink(.failed(lastError.isEmpty ? "mpv：\(reason)" : "mpv：\(reason)（\(lastError)）"))
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = message.prefix.map { String(cString: $0) } ?? ""
            let text = (message.text.map { String(cString: $0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if message.log_level.rawValue <= MPV_LOG_LEVEL_ERROR.rawValue { lastError = String(text.prefix(160)) }
            appendLog("[\(prefix)] \(text)")
        default:
            break
        }
    }

    private func property(_ id: UInt64, _ property: mpv_event_property) {
        func double() -> Double? {
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data else { return nil }
            return data.assumingMemoryBound(to: Double.self).pointee
        }
        func flag() -> Bool? {
            guard property.format == MPV_FORMAT_FLAG, let data = property.data else { return nil }
            return data.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        guard let key = Observed(rawValue: id) else { return }
        switch key {
        case .time:
            // 每帧都会变，0.25 秒以上才往主线程发
            if let value = double(), abs(value - lastTime) >= 0.25 {
                lastTime = value
                sink(.time(value))
            }
        case .duration:
            sink(.duration(double() ?? 0))
        case .pause:
            if let value = flag() { sink(.paused(value)) }
        case .pausedForCache:
            sink(.waitingForCache(flag() ?? false))
        case .cacheTime:
            if let value = double(), abs(value - lastCache) >= 1 {
                lastCache = value
                sink(.cache(value))
            }
        case .speed:
            if let value = double() { sink(.speed(value)) }
        case .aspect:
            if let value = double() { sink(.aspect(value)) }
        case .trackCount, .audio, .subtitle:
            sendTracks()
        }
    }

    private func sendTracks() {
        let count = Int(string("track-list/count") ?? "") ?? 0
        var audio: [MPVPlayback.Track] = []
        var subtitles: [MPVPlayback.Track] = []
        var subtitleSelected = false
        for index in 0..<count {
            let prefix = "track-list/\(index)/"
            let type = string(prefix + "type") ?? ""
            guard type == "audio" || type == "sub", let id = Int(string(prefix + "id") ?? "") else { continue }
            let isAudio = type == "audio"
            let selected = string(prefix + "selected") == "yes"
            let title = Self.trackName(
                title: string(prefix + "title"), language: string(prefix + "lang"),
                codec: isAudio ? string(prefix + "codec") : nil,
                fallback: (isAudio ? "音轨 " : "字幕 ") + String((isAudio ? audio.count : subtitles.count) + 1)
            )
            let track = MPVPlayback.Track(id: id, title: title, selected: selected)
            if isAudio {
                audio.append(track)
            } else {
                subtitles.append(track)
                if selected { subtitleSelected = true }
            }
        }
        sink(.tracks(audio, subtitles, !subtitleSelected))
    }

    private static func trackName(title: String?, language: String?, codec: String?, fallback: String) -> String {
        let languageName = language.flatMap(Self.languageName)
        var name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = languageName ?? (language ?? "")
        } else if let languageName, !name.contains(languageName) {
            name += " · \(languageName)"
        }
        if name.isEmpty || name == "und" { name = fallback }
        if let codec, !codec.isEmpty { name += "（\(codec.uppercased())）" }
        return name
    }

    private static func languageName(_ code: String) -> String? {
        switch code.lowercased() {
        case "chi", "zho", "zh": return "中文"
        case "chs", "sc", "zh-hans", "zh-cn", "zh-sg": return "简体中文"
        case "cht", "tc", "zh-hant", "zh-tw", "zh-hk": return "繁体中文"
        case "cmn": return "国语"
        case "yue", "can": return "粤语"
        case "eng", "en": return "英语"
        case "jpn", "ja": return "日语"
        case "kor", "ko": return "韩语"
        case "fre", "fra", "fr": return "法语"
        case "ger", "deu", "de": return "德语"
        case "spa", "es": return "西班牙语"
        case "rus", "ru": return "俄语"
        case "tha", "th": return "泰语"
        default: return nil
        }
    }

    private func appendLog(_ line: String) {
        logLock.lock()
        logLines.append(line)
        if logLines.count > 60 { logLines.removeFirst(logLines.count - 60) }
        logLock.unlock()
    }
}
