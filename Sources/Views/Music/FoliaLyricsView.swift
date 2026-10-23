import SwiftUI
import UIKit
import WebKit

/// Folia 的歌词动画模式（名称和 folia-major 的中文界面一致）。
/// 心象（cadenza）、群唱（cappella）、静止（still）没有放进来：菜单项太多会超出一屏要滚动，按住拖选就失效了
enum FoliaMode: String, CaseIterable, Identifiable {
    case classic, lumiere, tempera, sonnet, partita, fume, tilt, claddagh, monet, pendolo, diorama

    var id: String { rawValue }

    var name: String {
        switch self {
        case .classic: return "流光"
        case .lumiere: return "绘光"
        case .tempera: return "凝彩"
        case .sonnet: return "商籁"
        case .partita: return "云阶"
        case .fume: return "浮名"
        case .tilt: return "倾诉"
        case .claddagh: return "回环"
        case .monet: return "莫奈"
        case .pendolo: return "时计"
        case .diorama: return "镜台"
        }
    }

    var icon: String {
        switch self {
        case .classic: return "sparkles"
        case .lumiere: return "light.max"
        case .tempera: return "paintpalette"
        case .sonnet: return "text.quote"
        case .partita: return "stairs"
        case .fume: return "smoke"
        case .tilt: return "text.line.first.and.arrowtriangle.forward"
        case .claddagh: return "circle.circle"
        case .monet: return "photo.artframe"
        case .pendolo: return "clock"
        case .diorama: return "cube.transparent"
        }
    }
}

enum FoliaBackground: String, CaseIterable, Identifiable {
    case latent, nomand, sora, common, monet

    var id: String { rawValue }

    var name: String {
        switch self {
        case .latent: return "隐现"
        case .nomand: return "漫游"
        case .sora: return "空"
        case .common: return "几何"
        case .monet: return "莫奈"
        }
    }
}

/// Folia 主题：从封面取色生成深色背景、浅色文字
struct FoliaTheme: Equatable {
    var background: UIColor
    var primary: UIColor
    var accent: UIColor
    var secondary: UIColor

    static let `default` = FoliaTheme(
        background: UIColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1),
        primary: UIColor(red: 0.957, green: 0.957, blue: 0.961, alpha: 1),
        accent: UIColor(red: 0.957, green: 0.957, blue: 0.961, alpha: 1),
        secondary: UIColor(red: 0.443, green: 0.443, blue: 0.478, alpha: 1)
    )

    init(background: UIColor, primary: UIColor, accent: UIColor, secondary: UIColor) {
        self.background = background
        self.primary = primary
        self.accent = accent
        self.secondary = secondary
    }

    init(tint: PosterTint?) {
        guard let tint else {
            self = .default
            return
        }
        let base = UIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
        background = base.mixed(with: .black, 0.55)
        primary = UIColor(white: 0.97, alpha: 1)
        accent = base.mixed(with: .white, 0.55)
        secondary = base.mixed(with: UIColor(white: 0.7, alpha: 1), 0.6)
    }

    var json: [String: Any] {
        [
            "name": "Astra",
            "backgroundColor": background.hexString,
            "primaryColor": primary.hexString,
            "accentColor": accent.hexString,
            "secondaryColor": secondary.hexString,
            "fontStyle": "sans",
            "animationIntensity": "normal",
        ]
    }
}

extension UIColor {
    func mixed(with other: UIColor, _ amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
    }
}

// MARK: - 本地资源

/// 用自定义 scheme 提供打包进 App 的 Folia 页面（ES module 不能从 file:// 加载）
final class FoliaSchemeHandler: NSObject, WKURLSchemeHandler {
    static let root: URL? = Bundle.main.url(forResource: "folia", withExtension: nil)
    static var isAvailable: Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("folia-embed.html").path)
    }

    private static let mimeTypes: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "png": "image/png", "jpg": "image/jpeg", "svg": "image/svg+xml",
        "wasm": "application/wasm", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf",
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root = Self.root else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/folia-embed.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        }
        let mime = Self.mimeTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

// MARK: - 歌词动画视图

struct FoliaLyricsView: UIViewRepresentable {
    let player: MusicPlayer
    let mode: FoliaMode
    let background: FoliaBackground
    let theme: FoliaTheme
    let songRevision: Int
    let clockRevision: Int
    var active = true

    /// 歌词动画的网页整个 App 只建一次：每次进音乐页都新建 WebView、重新加载十几 MB 的脚本和 WebGL，
    /// 打开音乐页会明显卡一下。离开页面时只是把它从界面上拿下来（不在窗口里时动画自动暂停）
    func makeCoordinator() -> Coordinator { Coordinator.shared }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        context.coordinator.attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.update(
            mode: mode, background: background, theme: theme,
            songRevision: songRevision, clockRevision: clockRevision, active: active
        )
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        coordinator.detach(from: container)
    }

    /// WKUserContentController 会强引用消息处理者，中间隔一层避免循环引用
    final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?

        init(_ target: Coordinator) {
            self.target = target
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.receive(message.body)
        }
    }

    @MainActor
    final class Coordinator {
        static let shared = Coordinator(player: .shared)

        let player: MusicPlayer
        private(set) var webView: WKWebView?
        private var createdAt = Date()
        private var ready = false
        private var mode: FoliaMode?
        private var background: FoliaBackground?
        private var theme: FoliaTheme?
        private var songRevision = -1
        private var clockRevision = -1
        private var timer: Timer?
        private var songTask: Task<Void, Never>?
        private var active = true

        init(player: MusicPlayer) {
            self.player = player
        }

        func attach(to container: UIView) {
            let started = Date()
            let webView = self.webView ?? makeWebView()
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(webView)
            if ready {
                // 离开期间歌曲、进度可能都变了，重新推一遍
                pushAll()
                startTimer()
            }
            Diag.log("音乐", "歌词动画挂上界面（\(ready ? "复用已加载的网页" : "等待网页加载")）用时 \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }

        func detach(from container: UIView) {
            guard let webView, webView.superview === container || webView.superview == nil else { return }
            webView.removeFromSuperview()
            stop()
            Diag.log("音乐", "歌词动画离开界面")
        }

        private func makeWebView() -> WKWebView {
            createdAt = Date()
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(FoliaSchemeHandler(), forURLScheme: "folia")
            config.userContentController.add(WeakMessageHandler(self), name: "folia")
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.scrollView.bounces = false
            #if DEBUG
            if #available(iOS 16.4, *) { webView.isInspectable = true }
            #endif
            self.webView = webView
            if let url = URL(string: "folia://app/folia-embed.html") {
                webView.load(URLRequest(url: url))
            }
            Diag.log("音乐", "新建歌词动画 WebView，开始加载 Folia")
            return webView
        }

        func receive(_ body: Any) {
            guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                Diag.log("音乐", "Folia 网页就绪，加载用时 \(Int(Date().timeIntervalSince(createdAt) * 1000))ms")
                pushAll()
                if webView?.window != nil { startTimer() }
            case "seek":
                if let time = message["time"] as? Double { player.seek(to: time) }
            case "log":
                #if DEBUG
                print("[Folia] \(message["message"] ?? "")")
                #endif
            default:
                break
            }
        }

        func update(mode: FoliaMode, background: FoliaBackground, theme: FoliaTheme, songRevision: Int, clockRevision: Int, active: Bool) {
            let wasActive = self.active
            self.active = active
            guard ready else {
                self.mode = mode
                self.background = background
                self.theme = theme
                return
            }
            if mode != self.mode {
                self.mode = mode
                call("setMode", mode.rawValue)
            }
            if background != self.background {
                self.background = background
                call("setBackground", background.rawValue)
            }
            if theme != self.theme {
                self.theme = theme
                callRaw("setTheme(\(Self.json(theme.json)), false)")
            }
            if songRevision != self.songRevision {
                self.songRevision = songRevision
                pushSong()
            }
            if clockRevision != self.clockRevision || active != wasActive {
                self.clockRevision = clockRevision
                pushClock()
            }
        }

        private func pushAll() {
            if let mode { call("setMode", mode.rawValue) }
            if let background { call("setBackground", background.rawValue) }
            callRaw("setTheme(\(Self.json((theme ?? .default).json)), false)")
            songRevision = player.songRevision
            clockRevision = player.clockRevision
            pushSong()
            pushClock()
        }

        private func pushSong() {
            songTask?.cancel()
            guard let track = player.current else {
                callRaw("setSong(null)")
                return
            }
            var song: [String: Any] = [
                "id": track.id, "title": track.name, "artist": track.singer, "album": track.album,
            ]
            if let lyric = player.lyric, !lyric.isEmpty {
                song["lyric"] = ["format": lyric.format, "content": lyric.content, "translation": lyric.translation]
            } else {
                // 没有歌词时显示歌名，让动画不至于空着
                song["lyric"] = ["format": "lrc", "content": "[00:00.00]\(track.name)\n[00:03.00]\(track.singer)"]
            }
            let base = song
            callRaw("setSong(\(Self.json(base)))")
            // 封面转成 data URL 再补上（远程图片在 WebGL 里会有跨域问题）
            let cover = track.cover
            guard !cover.isEmpty else { return }
            songTask = Task { [weak self] in
                guard let image = await ImageCache.shared.load(cover), !Task.isCancelled,
                      let dataURL = Self.dataURL(image) else { return }
                guard let self, self.player.current?.id == track.id else { return }
                var withCover = base
                withCover["cover"] = dataURL
                self.callRaw("setSong(\(Self.json(withCover)))")
            }
        }

        private func pushClock() {
            let clock: [String: Any] = [
                "time": player.currentTime,
                "duration": player.duration,
                "playing": player.isPlaying && active,
                "rate": 1,
            ]
            callRaw("setClock(\(Self.json(clock)))")
        }

        /// 定时校准一次时钟，防止网页里插值出来的时间慢慢漂移
        private func startTimer() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.player.isPlaying, self.active else { return }
                    self.pushClock()
                }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            songTask?.cancel()
        }

        private func call(_ function: String, _ argument: String) {
            callRaw("\(function)(\(Self.json(argument)))")
        }

        private func callRaw(_ expression: String) {
            webView?.evaluateJavaScript("window.kazumi && window.kazumi.\(expression); void 0", completionHandler: nil)
        }

        static func json(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
            return String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }

        private static func dataURL(_ image: UIImage) -> String? {
            let side: CGFloat = 480
            let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = resized.jpegData(compressionQuality: 0.82) else { return nil }
            return "data:image/jpeg;base64," + data.base64EncodedString()
        }
    }
}
