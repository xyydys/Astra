import Foundation
import WebKit

enum SnifferError: LocalizedError {
    case badURL
    case timeout

    var errorDescription: String? {
        switch self {
        case .badURL: return "剧集页面地址无效"
        case .timeout: return "解析超时，没有找到视频地址"
        }
    }
}

/// 在隐藏 WebView 里打开剧集页，拦截真实的 m3u8 / mp4 地址。
/// 注入脚本移植自 Kazumi 的 VideoWebviewAppleImpl：
/// - 普通模式：hook fetch / XHR 识别 #EXTM3U，外加 <video> 的 src
/// - 旧版解析（useLegacyParser）：读取 iframe 的 src，从参数里取出视频地址
@MainActor
final class VideoSniffer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let userAgent: String
    private(set) var logs: [String] = []

    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var legacy = false

    override init() {
        userAgent = UserAgents.random()

        let handler = WeakScriptHandler()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Scripts.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Scripts.lazyIframe, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Scripts.videoTag, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Scripts.iframeScan, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        for name in ["kgVideo", "kgIframe", "kgLog"] {
            controller.add(handler, name: name)
        }

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.websiteDataStore = .default()

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        super.init()

        handler.target = self
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self

        let userContent = webView.configuration.userContentController
        Task { await ContentBlocker.apply(to: userContent) }
    }

    /// 解析一集的视频地址
    func resolve(pageURL: String, legacy: Bool, timeout: TimeInterval = 25) async throws -> String {
        cancel()
        guard let url = URL.lenient(pageURL) else { throw SnifferError.badURL }
        self.legacy = legacy
        logs.removeAll()
        log("加载 \(url.absoluteString)\(legacy ? "（旧版解析）" : "")")

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.webView.load(URLRequest(url: url))
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(SnifferError.timeout))
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let cont = continuation else { return }
        continuation = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        if case .success(let url) = result { log("找到视频 \(url)") }
        cont.resume(with: result)
    }

    private func log(_ message: String) {
        logs.append(message)
        if logs.count > 60 { logs.removeFirst(logs.count - 60) }
    }

    fileprivate func receive(name: String, body: Any) {
        let message = (body as? String) ?? String(describing: body)
        if name == "kgLog" {
            log(message)
            return
        }
        guard continuation != nil else { return }
        switch name {
        case "kgVideo":
            guard !legacy, message.contains("http") else { return }
            finish(.success(message))
        case "kgIframe":
            guard legacy else { return }
            log("iframe \(message)")
            if let video = Self.decodeVideoSource(message) {
                finish(.success(video))
            }
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.code != NSURLErrorCancelled { log("页面加载失败：\(error.localizedDescription)") }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.code != NSURLErrorCancelled { log("页面加载失败：\(error.localizedDescription)") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if continuation != nil { log("页面加载完成 \(webView.url?.absoluteString ?? "")") }
    }

    // MARK: 旧版解析：从 iframe 参数里取视频地址（对应 Kazumi 的 decodeVideoSource）

    static func decodeVideoSource(_ iframeURL: String) -> String? {
        let decoded = iframeURL.removingPercentEncoding ?? iframeURL
        let comps = URLComponents(string: decoded)
            ?? decoded.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap { URLComponents(string: $0) }
        guard let items = comps?.queryItems else { return nil }
        for item in items {
            guard let value = item.value else { continue }
            if value.range(of: #"https?://.*?\.(m3u8|mp4)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return value
            }
        }
        return nil
    }
}

/// 避免 WKUserContentController 强引用 VideoSniffer 造成循环引用
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: VideoSniffer?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(name: message.name, body: message.body)
    }
}

@MainActor
enum ContentBlocker {
    private static var compiled: WKContentRuleList?

    /// 拦截图片和常见广告/反调试脚本，加快解析（同 Kazumi 的 contentBlockers）
    private static let rules = #"""
    [
      {"trigger": {"url-filter": ".*", "resource-type": ["image"]}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "devtools-detector\\.js"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "googleads"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "googlesyndication\\.com"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "prestrain\\.html"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "prestrain%2Ehtml"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "adtrafficquality"}, "action": {"type": "block"}}
    ]
    """#

    static func apply(to controller: WKUserContentController) async {
        if compiled == nil {
            compiled = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "astra-sniffer", encodedContentRuleList: rules
            )
        }
        if let compiled { controller.add(compiled) }
    }
}

private enum Scripts {
    static let hook = #"""
    (function () {
      if (window.__kgHooked) return;
      window.__kgHooked = true;
      var post = function (name, msg) {
        try { window.webkit.messageHandlers[name].postMessage(String(msg)); } catch (e) {}
      };
      var abs = function (u) {
        try { return new URL(u, location.href).href; } catch (e) { return String(u); }
      };
      var isM3U8 = function (t) { return typeof t === 'string' && t.trim().indexOf('#EXTM3U') === 0; };
      post('kgLog', 'hook loaded: ' + location.href);
      try {
        var _text = Response.prototype.text;
        Response.prototype.text = function () {
          var resp = this;
          return _text.call(this).then(function (t) {
            try {
              if (isM3U8(t)) {
                post('kgLog', 'M3U8 (fetch): ' + resp.url);
                post('kgVideo', abs(resp.url));
              }
            } catch (e) {}
            return t;
          });
        };
      } catch (e) {}
      try {
        var _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function () {
          var args = arguments;
          var xhr = this;
          xhr.addEventListener('load', function () {
            try {
              if (isM3U8(xhr.responseText)) {
                var u = xhr.responseURL || abs(args[1]);
                post('kgLog', 'M3U8 (xhr): ' + u);
                post('kgVideo', u);
              }
            } catch (e) {}
          });
          return _open.apply(this, args);
        };
      } catch (e) {}
    })();
    """#

    static let videoTag = #"""
    (function () {
      var post = function (name, msg) {
        try { window.webkit.messageHandlers[name].postMessage(String(msg)); } catch (e) {}
      };
      var abs = function (u) {
        try { return new URL(u, location.href).href; } catch (e) { return String(u); }
      };
      var usable = function (s) {
        return s && s.trim() !== '' && s.indexOf('blob:') !== 0 && s.indexOf('googleads') === -1;
      };
      var check = function (video) {
        var src = video.getAttribute('src');
        if (usable(src)) { post('kgLog', 'video src: ' + src); post('kgVideo', abs(src)); return; }
        var sources = video.getElementsByTagName('source');
        for (var i = 0; i < sources.length; i++) {
          src = sources[i].getAttribute('src');
          if (usable(src)) { post('kgLog', 'source src: ' + src); post('kgVideo', abs(src)); return; }
        }
      };
      document.querySelectorAll('video').forEach(check);
      if (!document.body) return;
      new MutationObserver(function (mutations) {
        mutations.forEach(function (m) {
          if (m.type === 'attributes' && m.target.nodeName === 'VIDEO') check(m.target);
          m.addedNodes.forEach(function (n) {
            if (n.nodeName === 'VIDEO') check(n);
            if (n.querySelectorAll) n.querySelectorAll('video').forEach(check);
          });
        });
      }).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
    })();
    """#

    static let iframeScan = #"""
    (function () {
      var frames = document.getElementsByTagName('iframe');
      for (var i = 0; i < frames.length; i++) {
        var src = frames[i].getAttribute('src');
        if (src) {
          try { window.webkit.messageHandlers.kgIframe.postMessage(String(src)); } catch (e) {}
        }
      }
    })();
    """#

    static let lazyIframe = #"""
    (function () {
      var run = function () {
        document.querySelectorAll('iframe[loading="lazy"]').forEach(function (f) { f.removeAttribute('loading'); });
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run); else run();
    })();
    """#
}
