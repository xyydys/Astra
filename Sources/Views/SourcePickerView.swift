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

/// 用片名在所有启用的片源（Kazumi 规则、采集站、网盘资源站、猫影视插件）里并发搜索，
/// 按匹配度排列（和影视详情一样：片名、年份、集数，这部作品上次选的 / 看的片源排最前），选一个开始播放
struct SourcePickerView: View {
    let subject: BangumiSubject
    /// 影视只搜采集站，Kazumi 规则都是动漫站
    var includeRules = true
    let onPick: (SourcePick) -> Void

    @EnvironmentObject private var ruleStore: RuleStore
    @ObservedObject private var uz = UZStore.shared
    @ObservedObject private var cat = CatStore.shared
    @ObservedObject private var library = WatchLibrary.shared
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

    /// 一个片源：Kazumi 规则、采集站、uz 网盘资源站、猫影视插件里的站点
    struct PickerSource: Identifiable {
        enum Kind { case rule, cms, uz, cat }
        let id: String
        let name: String
        let kind: Kind
        let rule: Rule?
        let cms: CMSSource?
    }

    @State private var keyword: String
    @State private var states: [String: SourceState] = [:]
    @State private var timings: [String: TimeInterval] = [:]
    @State private var generation = 0
    @State private var captchaTarget: CaptchaTarget?
    @State private var problemSource: PickerSource?
    @State private var othersExpanded = false
    @State private var reportCopied = false
    /// 这部作品上次搜完时的片源顺序：打开时先按这个排，结果陆续回来也不乱跳
    @State private var rememberedOrder: [String]

    init(subject: BangumiSubject, includeRules: Bool = true, onPick: @escaping (SourcePick) -> Void) {
        self.subject = subject
        self.includeRules = includeRules
        self.onPick = onPick
        _keyword = State(initialValue: subject.title)
        _rememberedOrder = State(initialValue: SourceMemory.shared.order(for: subject.id))
    }

    private var sources: [PickerSource] {
        var list = ruleStore.searchableEntries(includeRules: includeRules).map { entry in
            PickerSource(id: entry.id, name: entry.name, kind: entry.rule != nil ? .rule : .cms, rule: entry.rule, cms: entry.cms)
        }
        list += uz.vodSources.map { PickerSource(id: "cms:" + $0.id, name: $0.name, kind: .uz, rule: nil, cms: $0) }
        list += cat.vodSources.map { PickerSource(id: "cms:" + $0.id, name: $0.name, kind: .cat, rule: nil, cms: $0) }
        return list
    }

    var body: some View {
        let ranked = ranking
        let found = ranked.filter { isFound($0) }
        let pending = ranked.filter { state($0) == .loading || state($0) == .captcha }
        let others = ranked.filter { state($0) == .empty || isFailed($0) }
        return NavigationStackCompat {
            List {
                searchSection

                if sources.isEmpty {
                    EmptyStateView(
                        "没有可用的片源",
                        systemImage: "puzzlepiece.extension",
                        description: Text("先到「我的 → 规则管理」里添加 Kazumi 规则或采集站，或者在「我的 → 片源」里导入网盘资源、猫影视插件")
                    )
                }

                ForEach(Array(found.enumerated()), id: \.element.id) { index, source in
                    Section {
                        results(for: source)
                    } header: {
                        sourceHeader(source, best: index == 0)
                    }
                }

                if !pending.isEmpty {
                    Section {
                        ForEach(pending) { source in
                            pendingRow(source)
                        }
                    } header: {
                        Text("搜索中 · \(pending.count)")
                    }
                }

                if !others.isEmpty {
                    Section {
                        Button {
                            withAnimation(.snappyCompat) { othersExpanded.toggle() }
                        } label: {
                            HStack {
                                Text(othersSummary(others))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: othersExpanded ? "chevron.up" : "chevron.down")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if othersExpanded {
                            ForEach(others) { source in
                                otherRow(source)
                            }
                        }
                    } footer: {
                        Text("点一行看出错原因。「复制报告」能把每个片源的结果和出错原因复制出来，发给开发者排查。")
                    }
                }
            }
            .navigationTitle("选择片源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", icon: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("重新搜索", icon: "arrow.clockwise") { generation += 1 }
                        Button(reportCopied ? "已复制报告" : "复制搜索报告", icon: "doc.on.doc") { copyReport() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task(id: generation) { await runSearch() }
            .sheet(item: $captchaTarget) { target in
                CaptchaView(target: target) { items in
                    let id = "rule:" + target.rule.id
                    if let items, !items.isEmpty {
                        states[id] = .rule(items)
                    } else if let source = sources.first(where: { $0.id == id }) {
                        Task { await search(source, keyword: target.keyword) }
                    }
                }
            }
            .alert(
                problemSource?.name ?? "",
                isPresented: Binding(get: { problemSource != nil }, set: { if !$0 { problemSource = nil } }),
                presenting: problemSource
            ) { source in
                Button("重试") { Task { await search(source, keyword: keyword) } }
                Button("复制") { UIPasteboard.general.string = problemText(source) }
                Button("好", role: .cancel) {}
            } message: { source in
                Text(problemText(source))
            }
        }
        .sheetDetents([.medium, .large], dragIndicator: true)
    }

    private var searchSection: some View {
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
                .hideScrollIndicators()
            }
        } footer: {
            Text("按匹配度排列：片名、年份对得上的在前，这部作品上次选过的片源排最前面。搜不到时可以换成原名或缩短关键词。")
        }
    }

    // MARK: 行

    private func state(_ source: PickerSource) -> SourceState { states[source.id] ?? .loading }

    private func isFound(_ source: PickerSource) -> Bool {
        switch state(source) {
        case .rule, .cms: return true
        default: return false
        }
    }

    private func isFailed(_ source: PickerSource) -> Bool {
        if case .failed = state(source) { return true }
        return false
    }

    private func sourceHeader(_ source: PickerSource, best: Bool) -> some View {
        HStack(spacing: 6) {
            Text(source.name)
            SourceKindBadge(kind: source.kind)
            if isPreferred(source) {
                Text("上次选的").foregroundStyle(.tint)
            } else if lastWatched(source) {
                Text("上次看的").foregroundStyle(.tint)
            } else if best {
                Text("最匹配").foregroundStyle(.tint)
            }
            Spacer()
            if let count = state(source).count {
                Text("\(count) 个结果")
            }
        }
    }

    @ViewBuilder
    private func results(for source: PickerSource) -> some View {
        switch state(source) {
        case .rule(let items):
            if let rule = source.rule {
                ForEach(sortedRuleItems(items)) { item in
                    resultButton(title: item.name, detail: nil) { pick(source, .rule(rule, item)) }
                }
            }
        case .cms(let items):
            ForEach(sortedCMSItems(items)) { item in
                let detail = [item.remarks, item.year, item.typeName].filter { !$0.isEmpty }.joined(separator: " · ")
                resultButton(title: item.name, detail: detail.isEmpty ? nil : detail) { pick(source, .cms(item)) }
            }
        default:
            EmptyView()
        }
    }

    private func pendingRow(_ source: PickerSource) -> some View {
        HStack(spacing: 10) {
            Text(source.name)
            SourceKindBadge(kind: source.kind)
            Spacer()
            if state(source) == .captcha, let rule = source.rule {
                Button("需要验证") {
                    if let request = try? RuleEngine.searchRequest(for: rule, keyword: keyword), let url = request.url {
                        captchaTarget = CaptchaTarget(rule: rule, url: url, keyword: keyword)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                ProgressView()
            }
        }
    }

    private func otherRow(_ source: PickerSource) -> some View {
        Button {
            problemSource = source
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.name).foregroundStyle(.primary)
                        SourceKindBadge(kind: source.kind)
                    }
                    switch state(source) {
                    case .failed(let message):
                        (Text(VideoDetailView.problem(message).label).foregroundColor(.orange) + Text(" · " + message))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    default:
                        Text("没有结果").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "info.circle").foregroundStyle(.secondary)
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

    private func othersSummary(_ list: [PickerSource]) -> String {
        let failed = list.filter { isFailed($0) }.count
        let empty = list.count - failed
        return [failed > 0 ? "\(failed) 个出错" : "", empty > 0 ? "\(empty) 个没找到" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func problemText(_ source: PickerSource) -> String {
        switch state(source) {
        case .failed(let message):
            let problem = VideoDetailView.problem(message)
            return "\(problem.label)：\(problem.hint)\n\n原始信息：\(message)"
        case .empty:
            return "这个片源搜「\(keyword)」没有结果。片名叫法不一样的话，可以换成原名或缩短关键词再搜。"
        default:
            return ""
        }
    }

    /// 选了就记住：这部作品下次打开时这个片源排最前面
    private func pick(_ source: PickerSource, _ pick: SourcePick) {
        SourceMemory.shared.setPreferred(source.id, for: subject.id)
        onPick(pick)
    }

    // MARK: 排序

    private func isPreferred(_ source: PickerSource) -> Bool {
        SourceMemory.shared.preferred(for: subject.id) == source.id
    }

    private func lastWatched(_ source: PickerSource) -> Bool {
        guard let record = library.record(subject.id) else { return false }
        if let rule = source.rule { return !record.isCMSRecord && record.ruleName == rule.name }
        if let cms = source.cms { return record.cmsAPI == cms.url }
        return false
    }

    private func itemScore(_ item: SearchItem) -> Double {
        SourceScore.match(name: item.name, year: "", episodeCount: 0, keyword: keyword, subject: subject)
    }

    private func itemScore(_ item: CMSItem) -> Double {
        SourceScore.match(name: item.name, year: item.year, episodeCount: item.episodeCount, keyword: keyword, subject: subject)
    }

    private func sortedRuleItems(_ items: [SearchItem]) -> [SearchItem] {
        items.enumerated().sorted { a, b in
            let x = itemScore(a.element), y = itemScore(b.element)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    private func sortedCMSItems(_ items: [CMSItem]) -> [CMSItem] {
        items.enumerated().sorted { a, b in
            let x = itemScore(a.element), y = itemScore(b.element)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// 找到的按匹配度（最好的一条结果 + 上次选的 / 看的 + 自己排的优先级），其余的按上次的顺序
    private var ranking: [PickerSource] {
        let list = sources
        let remembered = Dictionary(rememberedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var scores: [String: Double] = [:]
        for (index, source) in list.enumerated() {
            let best: Double?
            switch state(source) {
            case .rule(let items): best = items.map { itemScore($0) }.max()
            case .cms(let items): best = items.map { itemScore($0) }.max()
            default: best = nil
            }
            guard var value = best else { continue }
            if isPreferred(source) { value += SourceScore.preferredBonus }
            if lastWatched(source) { value += SourceScore.lastWatchedBonus }
            scores[source.id] = value + SourceScore.priority(index: index, total: list.count)
        }
        return list.enumerated().sorted { a, b in
            let x = scores[a.element.id], y = scores[b.element.id]
            if (x != nil) != (y != nil) { return x != nil }
            if let x, let y, x != y { return x > y }
            let p = remembered[a.element.id] ?? Int.max, q = remembered[b.element.id] ?? Int.max
            return p != q ? p < q : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: 搜索

    private func runSearch() async {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let targets = sources
        for source in targets { states[source.id] = .loading }
        timings = [:]
        reportCopied = false
        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            for source in targets {
                group.addTask { @MainActor in
                    await search(source, keyword: word)
                    timings[source.id] = Date().timeIntervalSince(started)
                }
            }
        }
        // 记住这次的顺序，下次打开先按它排
        SourceMemory.shared.setOrder(ranking.map(\.id), for: subject.id)
    }

    private func search(_ source: PickerSource, keyword: String) async {
        states[source.id] = .loading
        if let rule = source.rule {
            do {
                let items = try await RuleEngine.search(rule, keyword: keyword)
                states[source.id] = .rule(items)
            } catch RuleError.captchaRequired {
                states[source.id] = .captcha
            } catch RuleError.noResult {
                states[source.id] = .empty
            } catch {
                states[source.id] = .failed(error.localizedDescription)
            }
        } else if let cms = source.cms {
            do {
                let items: [CMSItem]
                switch source.kind {
                case .uz: items = try await UZStore.shared.search(cms, keyword: keyword)
                case .cat: items = try await CatStore.shared.search(cms, keyword: keyword)
                default: items = try await CMSClient.search(cms, keyword: keyword)
                }
                states[source.id] = items.isEmpty ? .empty : .cms(items)
            } catch {
                states[source.id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: 报告

    private func copyReport() {
        var lines = [
            "片源搜索报告（番剧）",
            "片名：\(subject.title)　搜索词：\(keyword)　年份：\(subject.airDate)　集数：\(subject.episodes)",
            "",
        ]
        for source in ranking {
            let kind: String
            switch source.kind {
            case .rule: kind = "规则"
            case .cms: kind = "采集站"
            case .uz: kind = "uz"
            case .cat: kind = "猫影视"
            }
            let time = timings[source.id].map { String(format: "%.1f 秒", $0) } ?? ""
            switch state(source) {
            case .rule(let items):
                lines.append("✅ \(source.name)（\(kind)）\(time)：\(items.count) 个结果，第一个「\(sortedRuleItems(items).first?.name ?? "")」")
            case .cms(let items):
                let first = sortedCMSItems(items).first
                lines.append("✅ \(source.name)（\(kind)）\(time)：\(items.count) 个结果，第一个「\(first?.name ?? "") \(first?.year ?? "")」")
            case .empty:
                lines.append("➖ \(source.name)（\(kind)）\(time)：没找到")
            case .loading:
                lines.append("⏳ \(source.name)（\(kind)）：还在搜")
            case .captcha:
                lines.append("🔒 \(source.name)（\(kind)）：需要网页验证")
            case .failed(let message):
                lines.append("❌ \(source.name)（\(kind)）\(time)：\(VideoDetailView.problem(message).label)｜\(message)")
            }
        }
        let uzLogs = Array(UZStore.shared.runtimeLogs.suffix(40))
        let catLines = Array(CatStore.shared.diagnostics.suffix(30))
        Task {
            var text = lines
            if !uzLogs.isEmpty { text += ["", "—— uz 扩展日志 ——"] + uzLogs }
            if !catLines.isEmpty { text += ["", "—— 猫影视插件 ——"] + catLines }
            if CatStore.shared.hasPackage {
                let node = await CatStore.shared.nodeLogs()
                if !node.isEmpty { text += ["", "—— 插件输出 ——"] + node.suffix(60) }
            }
            UIPasteboard.general.string = text.joined(separator: "\n")
            reportCopied = true
            Haptics.success()
        }
    }
}

/// 片源类型小标签
struct SourceKindBadge: View {
    let kind: SourcePickerView.PickerSource.Kind

    init(kind: SourcePickerView.PickerSource.Kind) {
        self.kind = kind
    }

    init(isCMS: Bool) {
        kind = isCMS ? .cms : .rule
    }

    private var text: String {
        switch kind {
        case .rule: return "规则"
        case .cms: return "采集站"
        case .uz: return "网盘"
        case .cat: return "猫影视"
        }
    }

    private var color: Color {
        switch kind {
        case .rule: return .indigo
        case .cms: return .teal
        case .uz: return .orange
        case .cat: return .pink
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
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
        NavigationStackCompat {
            WebViewContainer(webView: model.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("验证 · \(target.rule.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", icon: "xmark") { dismiss() }
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
                        .glass(in: Capsule())
                        .padding(.top, 6)
                }
                .onAppear { model.load(target.url) }
        }
    }
}
