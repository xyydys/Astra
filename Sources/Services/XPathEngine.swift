import Foundation
import WebKit

/// 用 WebKit 的 DOMParser + document.evaluate 执行规则里的 XPath。
/// HTML5 解析结果与 Kazumi 用的 Dart html 包一致，XPath 也是完整的 1.0 实现。
@MainActor
final class XPathEngine: NSObject, WKNavigationDelegate {
    static let shared = XPathEngine()

    let webView: WKWebView
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { markReady() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { markReady() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { markReady() }

    private func markReady() {
        guard !ready else { return }
        ready = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func waitReady() async {
        if ready { return }
        await withCheckedContinuation { cont in waiters.append(cont) }
    }

    // MARK: - 公共 API

    struct RawItem: Decodable { let name: String; let href: String }
    struct RawEpisode: Decodable { let name: String; let href: String }

    private struct SearchEnvelope: Decodable { let ok: Bool; let error: String?; let items: [RawItem]? }
    private struct ChapterEnvelope: Decodable { let ok: Bool; let error: String?; let roads: [[RawEpisode]]? }
    private struct HitEnvelope: Decodable { let ok: Bool; let error: String?; let hit: Bool? }

    func search(html: String, list: String, name: String, result: String) async throws -> [RawItem] {
        let env: SearchEnvelope = try await run(Self.searchJS, [
            "html": html,
            "listXP": Self.relativize(list),
            "nameXP": Self.relativize(name),
            "resultXP": Self.relativize(result),
        ])
        if !env.ok { throw RuleError.parse(env.error ?? "XPath 执行失败") }
        return env.items ?? []
    }

    func chapters(html: String, roads: String, episodes: String) async throws -> [[RawEpisode]] {
        let env: ChapterEnvelope = try await run(Self.chapterJS, [
            "html": html,
            "roadsXP": Self.relativize(roads),
            "epXP": Self.relativize(episodes),
        ])
        if !env.ok { throw RuleError.parse(env.error ?? "XPath 执行失败") }
        return env.roads ?? []
    }

    func exists(html: String, xpath: String) async -> Bool {
        do {
            let env: HitEnvelope = try await run(Self.existsJS, [
                "html": html,
                "xp": Self.relativize(xpath),
            ])
            return env.hit ?? false
        } catch {
            return false
        }
    }

    private func run<T: Decodable>(_ body: String, _ args: [String: Any]) async throws -> T {
        await waitReady()
        let result = try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .defaultClient)
        guard let json = result as? String, let data = json.data(using: .utf8) else {
            throw RuleError.parse("XPath 执行没有返回结果")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - 与 xpath_selector 对齐的相对路径处理

    /// Kazumi 里 `//a` 和 `/a` 都是相对当前节点的，标准 XPath 里则是从文档根开始。
    /// 这里把每个并集分支的开头补一个 `.`，得到等价的标准写法。
    static func relativize(_ xpath: String) -> String {
        splitTopLevelUnion(xpath)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("/") ? "." + $0 : $0 }
            .joined(separator: " | ")
    }

    static func splitTopLevelUnion(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for ch in s {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                current.append(ch)
            case "[", "(":
                depth += 1
                current.append(ch)
            case "]", ")":
                depth -= 1
                current.append(ch)
            case "|" where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    // MARK: - JS

    private static let prelude = #"""
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const root = doc.documentElement;
    const all = (ctx, xp) => {
      const r = doc.evaluate(xp, ctx, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      const out = [];
      for (let i = 0; i < r.snapshotLength; i++) out.push(r.snapshotItem(i));
      return out;
    };
    const one = (ctx, xp) => doc.evaluate(xp, ctx, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
    const attr = (n, name) => {
      if (!n) return '';
      if (n.nodeType === 2) return n.value || '';
      return (n.getAttribute && n.getAttribute(name)) || '';
    };
    const text = (n) => (n ? (n.textContent || '') : '');
    """#

    private static let searchJS = #"""
    try {
    """# + prelude + #"""
      const items = [];
      for (const node of all(root, listXP)) {
        try {
          const name = text(one(node, nameXP)).trim();
          const href = attr(one(node, resultXP), 'href').trim();
          if (name && href) items.push({ name: name, href: href });
        } catch (e) {}
      }
      return JSON.stringify({ ok: true, items: items });
    } catch (e) {
      return JSON.stringify({ ok: false, error: String((e && e.message) || e) });
    }
    """#

    private static let chapterJS = #"""
    try {
    """# + prelude + #"""
      const roads = [];
      for (const road of all(root, roadsXP)) {
        const eps = [];
        for (const ep of all(road, epXP)) {
          const href = attr(ep, 'href').trim();
          if (!href) continue;
          eps.push({ name: text(ep).replace(/\s+/g, ''), href: href });
        }
        if (eps.length) roads.push(eps);
      }
      return JSON.stringify({ ok: true, roads: roads });
    } catch (e) {
      return JSON.stringify({ ok: false, error: String((e && e.message) || e) });
    }
    """#

    private static let existsJS = #"""
    try {
    """# + prelude + #"""
      return JSON.stringify({ ok: true, hit: !!one(root, xp) });
    } catch (e) {
      return JSON.stringify({ ok: false, error: String((e && e.message) || e) });
    }
    """#
}
