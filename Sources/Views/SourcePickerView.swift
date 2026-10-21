import SwiftUI
import WebKit

/// 选片源时选中的结果
enum SourcePick: Hashable {
    case rule(Rule, SearchItem)
    case cms(CMSItem)
}

extension PlayRequest {
    init(subject: BangumiSubject, pick: SourcePick, episodeIndex: Int = 0) {
        switch pick {
        case let .rule(rule, item):
            self.init(
                subjectID: subject.id, title: subject.title, name: subject.name, image: subject.image,
                ruleName: rule.name, sourceURL: item.url, sourceTitle: item.name,
                roadIndex: 0, episodeIndex: episodeIndex, position: 0
            )
        case let .cms(item):
            self.init(
                subjectID: subject.id, title: subject.title, name: subject.name, image: subject.image,
                ruleName: item.sourceName, sourceURL: "",
                sourceTitle: item.remarks.isEmpty ? item.name : "\(item.name) · \(item.remarks)",
                roadIndex: 0, episodeIndex: episodeIndex, position: 0,
                cmsAPI: item.api, vodID: item.vodID
            )
        }
    }
}

/// 用片名在所有启用的片源（Kazumi 规则 + 采集站）里并发搜索，按优先级排列，选一个开始播放
struct SourcePickerView: View {
    let subject: BangumiSubject
    /// 影视只搜采集站，Kazumi 规则都是动漫站
    var includeRules = true
    let onPick: (SourcePick) -> Void

    @Environment(RuleStore.self) private var ruleStore
    @Environment(\.dismiss) private var dismiss

    enum SourceState: Equatable {
        case loading
        case rule([SearchItem])
        case cms([CMSItem])
        case empty
        case captcha
        case failed(String)

        var count: Int? {
            switch self {
            case .rule(let items): return items.count
            case .cms(let items): return items.count
            default: return nil
            }
        }
    }

    @State private var keyword: String
    @State private var states: [String: SourceState] = [:]
    @State private var generation = 0
    @State private var captchaTarget: CaptchaTarget?

    init(subject: BangumiSubject, includeRules: Bool = true, onPick: @escaping (SourcePick) -> Void) {
        self.subject = subject
        self.includeRules = includeRules
        self.onPick = onPick
        _keyword = State(initialValue: subject.title)
    }

    private var entries: [RuleStore.Entry] {
        ruleStore.searchableEntries(includeRules: includeRules)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索关键词", text: $keyword)
                            .submitLabel(.search)
                            .onSubmit { generation += 1 }
                        if !keyword.isEmpty {
                            Button {
                                keyword = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if subject.searchKeywords.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(subject.searchKeywords, id: \.self) { word in
                                    Button(word) {
                                        keyword = word
                                        generation += 1
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                } footer: {
                    Text("搜不到时可以换成原名或缩短关键词再试。片源按「规则管理」里的优先级排列。")
                }

                if entries.isEmpty {
                    ContentUnavailableView(
                        "没有可用的片源",
                        systemImage: "puzzlepiece.extension",
                        description: Text(includeRules
                            ? "先到「我的 → 规则管理」里添加 Kazumi 规则或采集站"
                            : "先到「我的 → 规则管理」里添加采集站")
                    )
                }

                ForEach(entries) { entry in
                    Section {
                        content(for: entry)
                    } header: {
                        HStack(spacing: 6) {
                            Text(entry.name)
                            SourceKindBadge(isCMS: entry.cms != nil)
                            Spacer()
                            if let count = states[entry.id]?.count {
                                Text("\(count) 个结果")
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择片源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("重新搜索", systemImage: "arrow.clockwise") { generation += 1 }
                }
            }
            .task(id: generation) { await runSearch() }
            .sheet(item: $captchaTarget) { target in
                CaptchaView(target: target) { items in
                    let id = "rule:" + target.rule.id
                    if let items, !items.isEmpty {
                        states[id] = .rule(items)
                    } else if let entry = entries.first(where: { $0.id == id }) {
                        Task { await search(entry, keyword: target.keyword) }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func content(for entry: RuleStore.Entry) -> some View {
        switch states[entry.id] ?? .loading {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("搜索中…").foregroundStyle(.secondary)
            }
        case .rule(let items):
            if let rule = entry.rule {
                ForEach(items) { item in
                    resultButton(title: item.name, detail: nil) { onPick(.rule(rule, item)) }
                }
            }
        case .cms(let items):
            ForEach(items) { item in
                let detail = [item.remarks, item.year, item.typeName].filter { !$0.isEmpty }.joined(separator: " · ")
                resultButton(title: item.name, detail: detail.isEmpty ? nil : detail) { onPick(.cms(item)) }
            }
        case .empty:
            Text("没有结果").foregroundStyle(.secondary)
        case .captcha:
            if let rule = entry.rule {
                Button {
                    if let request = try? RuleEngine.searchRequest(for: rule, keyword: keyword),
                       let url = request.url {
                        captchaTarget = CaptchaTarget(rule: rule, url: url, keyword: keyword)
                    }
                } label: {
                    Label("站点要求验证，点此打开网页完成验证", systemImage: "checkmark.shield")
                }
            }
        case .failed(let message):
            HStack {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重试") {
                    Task { await search(entry, keyword: keyword) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func resultButton(title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }

    private func runSearch() async {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let targets = entries
        for entry in targets { states[entry.id] = .loading }
        await withTaskGroup(of: Void.self) { group in
            for entry in targets {
                group.addTask { @MainActor in
                    await search(entry, keyword: word)
                }
            }
        }
    }

    private func search(_ entry: RuleStore.Entry, keyword: String) async {
        states[entry.id] = .loading
        if let rule = entry.rule {
            do {
                let items = try await RuleEngine.search(rule, keyword: keyword)
                states[entry.id] = .rule(items)
            } catch RuleError.captchaRequired {
                states[entry.id] = .captcha
            } catch RuleError.noResult {
                states[entry.id] = .empty
            } catch {
                states[entry.id] = .failed(error.localizedDescription)
            }
        } else if let source = entry.cms {
            do {
                let items = try await CMSClient.search(source, keyword: keyword)
                states[entry.id] = items.isEmpty ? .empty : .cms(items)
            } catch {
                states[entry.id] = .failed(error.localizedDescription)
            }
        }
    }
}

/// 片源类型小标签
struct SourceKindBadge: View {
    let isCMS: Bool

    var body: some View {
        Text(isCMS ? "采集站" : "规则")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(isCMS ? Color.teal : Color.indigo)
            .background((isCMS ? Color.teal : Color.indigo).opacity(0.14), in: Capsule())
    }
}

// MARK: - 网页验证

struct CaptchaTarget: Identifiable {
    let rule: Rule
    let url: URL
    let keyword: String
    var id: String { rule.id }
}

@MainActor
final class CaptchaWebModel {
    let webView: WKWebView
    let userAgent = UserAgents.random()

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = userAgent
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ url: URL) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }

    /// 同步 cookie 到 URLSession，记住验证用的 UA，并尝试直接解析当前页面
    func finish(rule: Rule) async -> [SearchItem]? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        RuleEngine.verifiedUserAgents[rule.id] = userAgent
        guard let html = try? await webView.callAsyncJavaScript(
            "return document.documentElement.outerHTML",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String else { return nil }
        return try? await RuleEngine.parseSearch(html: html, rule: rule)
    }
}

struct CaptchaView: View {
    let target: CaptchaTarget
    let onDone: ([SearchItem]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = CaptchaWebModel()
    @State private var finishing = false

    var body: some View {
        NavigationStack {
            WebViewContainer(webView: model.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("验证 · \(target.rule.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            finishing = true
                            Task {
                                let items = await model.finish(rule: target.rule)
                                onDone(items)
                                dismiss()
                            }
                        } label: {
                            if finishing { ProgressView() } else { Text("完成") }
                        }
                        .disabled(finishing)
                    }
                }
                .safeAreaInset(edge: .top) {
                    Text("在网页里完成验证码后，点右上角「完成」")
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, 6)
                }
                .onAppear { model.load(target.url) }
        }
    }
}
