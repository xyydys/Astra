import Foundation
import Observation
import SwiftUI
import WebKit

/// 封面地址里可能带 `,{"headers":...}` 选项，图片加载只要前面的地址
enum NovelCover {
    static func url(_ raw: String) -> String {
        EngineURL.splitOption(raw).url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 书源

@Observable
@MainActor
final class BookSourceStore {
    static let shared = BookSourceStore()

    private(set) var sources: [BookSource] = []
    private(set) var isLoaded = false
    @ObservationIgnored private var loading: Task<Void, Never>?

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Novel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var fileURL: URL { directory.appendingPathComponent("book-sources.json") }

    private init() {}

    /// 书源可能有几千个，放到后台解码
    func load() async {
        if isLoaded { return }
        if let loading { return await loading.value }
        let url = Self.fileURL
        let task = Task {
            let list = await Task.detached(priority: .userInitiated) { () -> [BookSource] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return BookSource.decodeList(data)
            }.value
            sources = list
            isLoaded = true
        }
        loading = task
        await task.value
    }

    /// 从备份恢复后重新读盘
    func reload() async {
        loading = nil
        isLoaded = false
        sources = []
        await load()
    }

    private func save() {
        let snapshot = sources
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 能搜索的书源（按排序）
    var searchable: [BookSource] {
        sources.filter { $0.enabled && $0.isText && !$0.searchUrl.isEmpty }
    }

    var explorable: [BookSource] {
        sources.filter { $0.enabled && $0.enabledExplore && $0.isText && $0.hasExplore }
    }

    var groups: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for source in sources {
            for group in source.groups where !seen.contains(group) {
                seen.insert(group)
                out.append(group)
            }
        }
        return out
    }

    func source(for url: String) -> BookSource? {
        sources.first { $0.bookSourceUrl == url }
    }

    // MARK: 修改

    @discardableResult
    func install(_ list: [BookSource]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        var index: [String: Int] = [:]
        for (i, source) in sources.enumerated() { index[source.bookSourceUrl] = i }
        for source in list where source.isText {
            if let i = index[source.bookSourceUrl] {
                var replaced = source
                replaced.enabled = sources[i].enabled
                sources[i] = replaced
                updated += 1
            } else {
                index[source.bookSourceUrl] = sources.count
                sources.append(source)
                added += 1
            }
        }
        save()
        return (added, updated)
    }

    func setEnabled(_ ids: Set<String>, _ enabled: Bool) {
        for i in sources.indices where ids.contains(sources[i].id) {
            sources[i].enabled = enabled
        }
        save()
    }

    func toggle(_ id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].enabled.toggle()
        save()
    }

    func delete(_ ids: Set<String>) {
        sources.removeAll { ids.contains($0.id) }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        sources.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func moveToTop(_ id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        let item = sources.remove(at: i)
        sources.insert(item, at: 0)
        save()
    }

    // MARK: 导入

    enum ImportError: LocalizedError {
        case empty
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .empty: return "没有内容"
            case .nothingFound: return "没有找到阅读格式的文字书源"
            }
        }
    }

    /// 支持：书源 JSON（数组或单个）、JSON 地址、legado:// 一键导入链接，多行地址
    func importText(_ raw: String) async throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.empty }
        var datas: [Data] = []
        if text.hasPrefix("[") || text.hasPrefix("{") {
            datas = [Data(text.utf8)]
        } else {
            let urls = text.components(separatedBy: .newlines)
                .map { Self.extractSource($0.trimmingCharacters(in: .whitespaces)) }
                .filter { EngineURL.isAbsolute($0) }
            guard !urls.isEmpty else { throw ImportError.nothingFound }
            for url in urls {
                guard let target = URL.lenient(url) else { continue }
                var request = URLRequest(url: target, timeoutInterval: 30)
                request.setValue(JSEngine.userAgent, forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                datas.append(data)
            }
        }
        let payload = datas
        let list = await Task.detached(priority: .userInitiated) { () -> [BookSource] in
            payload.flatMap { BookSource.decodeList($0) }
        }.value
        let text0 = list.filter(\.isText)
        guard !text0.isEmpty else { throw ImportError.nothingFound }
        let result = install(text0)
        let skipped = list.count - text0.count
        var message = "导入 \(text0.count) 个书源：新增 \(result.added)，更新 \(result.updated)"
        if skipped > 0 { message += "；跳过 \(skipped) 个音频 / 漫画书源" }
        return message
    }

    /// legado://import/bookSource?src=…、yuedu://booksource/importonline?src=…
    static func extractSource(_ text: String) -> String {
        guard !EngineURL.isAbsolute(text), let components = URLComponents(string: text),
              let src = components.queryItems?.first(where: { $0.name == "src" })?.value else { return text }
        return src
    }
}

// MARK: - 书架上的书（当前用的书源）和缓存

@Observable
@MainActor
final class NovelLibrary {
    static let shared = NovelLibrary()

    private(set) var books: [Int: NovelBook] = [:]
    /// 搜索结果里同一本书的其它书源，换源时用（不保存）
    @ObservationIgnored private(set) var candidates: [Int: [NovelBook]] = [:]
    @ObservationIgnored private var transient: [Int: NovelBook] = [:]

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Novel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Novel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var fileURL: URL { directory.appendingPathComponent("library.json") }

    private init() {
        books = Self.read()
    }

    private static func read() -> [Int: NovelBook] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Int: NovelBook].self, from: data) else { return [:] }
        return decoded
    }

    /// 从备份恢复后重新读盘
    func reload() {
        books = Self.read()
        transient = [:]
        candidates = [:]
    }

    private func save() {
        let snapshot = books
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func book(for id: Int) -> NovelBook? {
        books[id] ?? transient[id]
    }

    /// 搜索结果先临时登记，打开详情时再保存
    @discardableResult
    func prepare(_ book: NovelBook, candidates list: [NovelBook]) -> BangumiSubject {
        let subject = BangumiSubject.novel(book)
        if books[subject.id] == nil { transient[subject.id] = book }
        if !list.isEmpty { candidates[subject.id] = list }
        return subject
    }

    func update(_ book: NovelBook, for id: Int) {
        books[id] = book
        transient[id] = nil
        save()
    }

    func otherSources(for id: Int) -> [NovelBook] {
        candidates[id] ?? []
    }

    func addCandidates(_ list: [NovelBook], for id: Int) {
        var existing = candidates[id] ?? []
        for book in list where !existing.contains(where: { $0.origin == book.origin }) {
            existing.append(book)
        }
        candidates[id] = existing
    }

    // MARK: 目录 / 正文缓存（按书和书源分目录）

    nonisolated static func folder(id: Int, origin: String) -> URL {
        let dir = cacheDirectory
            .appendingPathComponent(String(-id), isDirectory: true)
            .appendingPathComponent(EngineCrypto.md5Hex(origin), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func cachedChapters(id: Int, origin: String) -> [NovelChapter]? {
        let url = folder(id: id, origin: origin).appendingPathComponent("toc.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([NovelChapter].self, from: data)
    }

    nonisolated static func saveChapters(_ chapters: [NovelChapter], id: Int, origin: String) {
        let url = folder(id: id, origin: origin).appendingPathComponent("toc.json")
        if let data = try? JSONEncoder().encode(chapters) {
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func cachedContent(id: Int, origin: String, chapter: NovelChapter) -> String? {
        let url = folder(id: id, origin: origin).appendingPathComponent(EngineCrypto.md5Hex(chapter.url) + ".txt")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    nonisolated static func saveContent(_ text: String, id: Int, origin: String, chapter: NovelChapter) {
        let url = folder(id: id, origin: origin).appendingPathComponent(EngineCrypto.md5Hex(chapter.url) + ".txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated static func clearContent(id: Int, origin: String, chapter: NovelChapter) {
        let url = folder(id: id, origin: origin).appendingPathComponent(EngineCrypto.md5Hex(chapter.url) + ".txt")
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func cacheSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    nonisolated static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

// MARK: - 多书源搜索

@Observable
@MainActor
final class NovelSearchModel {
    struct Group: Identifiable {
        let id: String
        var books: [NovelBook]
        var order: Int

        var primary: NovelBook { books[0] }
        var cover: String { books.first { !$0.coverUrl.isEmpty }?.coverUrl ?? "" }
        var intro: String { books.map(\.intro).max { $0.count < $1.count } ?? "" }
        var latest: String { books.first { !$0.latestChapterTitle.isEmpty }?.latestChapterTitle ?? "" }
        var kind: String { books.first { !$0.kind.isEmpty }?.kind ?? "" }
        var author: String { books.first { !$0.author.isEmpty }?.author ?? "" }

        /// 合成一本封面、简介最完整的书
        var display: NovelBook {
            var book = primary
            if book.coverUrl.isEmpty { book.coverUrl = cover }
            if book.intro.isEmpty { book.intro = intro }
            if book.kind.isEmpty { book.kind = kind }
            if book.latestChapterTitle.isEmpty { book.latestChapterTitle = latest }
            return book
        }
    }

    private(set) var groups: [Group] = []
    private(set) var keyword = ""
    private(set) var isSearching = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var failed = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sourceOrder: [String: Int] = [:]

    func search(_ keyword: String, sources: [BookSource]) {
        task?.cancel()
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyword = key
        groups = []
        done = 0
        failed = 0
        total = sources.count
        guard !key.isEmpty, !sources.isEmpty else {
            isSearching = false
            return
        }
        sourceOrder = Dictionary(sources.enumerated().map { ($1.bookSourceUrl, $0) }, uniquingKeysWith: { first, _ in first })
        isSearching = true
        task = Task { [weak self] in
            await self?.run(key, sources)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }

    private func run(_ key: String, _ sources: [BookSource]) async {
        await withTaskGroup(of: [NovelBook]?.self) { group in
            var index = 0
            let width = min(12, sources.count)
            while index < width {
                let source = sources[index]
                index += 1
                group.addTask { await Self.searchOne(source, key) }
            }
            while let result = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                done += 1
                if let books = result { merge(books, key: key) } else { failed += 1 }
                if index < sources.count {
                    let source = sources[index]
                    index += 1
                    group.addTask { await Self.searchOne(source, key) }
                }
            }
        }
        if !Task.isCancelled { isSearching = false }
    }

    nonisolated static func searchOne(_ source: BookSource, _ key: String, timeout: Double = 20) async -> [NovelBook]? {
        let env = EngineEnv()
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            env.token.cancel()
        }
        defer { timer.cancel() }
        return try? await BookEngine.run(env) { env in
            try WebBook.search(source, key: key, env: env)
        }
    }

    private func merge(_ books: [NovelBook], key: String) {
        for book in books {
            let identity = book.identity
            if let i = groups.firstIndex(where: { $0.id == identity }) {
                guard !groups[i].books.contains(where: { $0.origin == book.origin }) else { continue }
                groups[i].books.append(book)
                groups[i].books.sort { (sourceOrder[$0.origin] ?? .max) < (sourceOrder[$1.origin] ?? .max) }
            } else {
                groups.append(Group(id: identity, books: [book], order: groups.count))
            }
        }
        groups.sort { a, b in
            let sa = Self.relevance(a, key), sb = Self.relevance(b, key)
            if sa != sb { return sa > sb }
            if a.books.count != b.books.count { return a.books.count > b.books.count }
            return a.order < b.order
        }
    }

    private static func relevance(_ group: Group, _ key: String) -> Int {
        let name = group.primary.name
        if name == key { return 4 }
        if name.hasPrefix(key) { return 3 }
        if name.contains(key) { return 2 }
        if group.author.contains(key) { return 1 }
        return 0
    }
}

// MARK: - 浏览器加载（书源的 webView 选项）

/// 用 WKWebView 加载页面并执行 JS，供书源的 `webView: true`、java.webView 使用
final class NovelWebLoader: EngineWebLoader, @unchecked Sendable {
    static let shared = NovelWebLoader()

    func load(url: String, html: String?, headers: [String: String], js: String?, delay: TimeInterval) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let box = EngineBox<Result<String, Error>?>(nil)
        DispatchQueue.main.async {
            _ = MainActor.assumeIsolated {
                let session = WebLoadSession(url: url, html: html, headers: headers, js: js, delay: delay) { result in
                    box.value = result
                    semaphore.signal()
                }
                session.start()
            }
        }
        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            throw BookEngineError.message("网页加载超时")
        }
        return try box.value?.get() ?? ""
    }
}

@MainActor
private final class WebLoadSession: NSObject, WKNavigationDelegate {
    private static var active: Set<WebLoadSession> = []

    private let url: String
    private let html: String?
    private let headers: [String: String]
    private let js: String?
    private let delay: TimeInterval
    private let completion: (Result<String, Error>) -> Void
    private var webView: WKWebView?
    private var finished = false

    init(url: String, html: String?, headers: [String: String], js: String?, delay: TimeInterval,
         completion: @escaping (Result<String, Error>) -> Void) {
        self.url = url
        self.html = html
        self.headers = headers
        self.js = js
        self.delay = delay
        self.completion = completion
    }

    func start() {
        Self.active.insert(self)
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value ?? JSEngine.userAgent
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        self.webView = webView
        // 挂到窗口上，避免后台节流
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            webView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
            window.addSubview(webView)
        }
        Task {
            // 把已有的 Cookie 带进网页
            if let target = URL.lenient(url) {
                for cookie in HTTPCookieStorage.shared.cookies(for: target) ?? [] {
                    await config.websiteDataStore.httpCookieStore.setCookie(cookie)
                }
            }
            guard let target = URL.lenient(url) else {
                finish(.failure(BookEngineError.message("地址无效")))
                return
            }
            if let html {
                webView.loadHTMLString(html, baseURL: target)
            } else {
                var request = URLRequest(url: target)
                for (k, v) in headers where k.caseInsensitiveCompare("User-Agent") != .orderedSame {
                    request.setValue(v, forHTTPHeaderField: k)
                }
                webView.load(request)
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(30))
            finish(.failure(BookEngineError.message("网页加载超时")))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            Task {
                try? await Task.sleep(for: .seconds(max(delay, 0.6)))
                await evaluate()
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    private func evaluate() async {
        guard let webView, !finished else { return }
        let script = (js?.isEmpty == false) ? js! : "document.documentElement.outerHTML"
        do {
            let value = try await webView.evaluateJavaScript(script)
            // 网页里拿到的 Cookie（比如人机验证通过后的）同步回请求用的 Cookie 库
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
            finish(.success(RuleValue.string(value)))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        completion(result)
        Self.active.remove(self)
    }
}

/// App 启动时把浏览器加载器接到引擎上
enum NovelEngineSetup {
    @MainActor static func install() {
        EngineHooks.webLoader = NovelWebLoader.shared
        #if DEBUG
        EngineHooks.log = { print("[书源] " + $0) }
        #endif
    }
}
