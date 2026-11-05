import SwiftUI
import WebKit

/// 选中的片源结果
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

// MARK: - 片源列表

/// 详情页的「片源」区（影视和番剧共用）：找到的按排序列出，点一下切换；还在搜的合成一行；没找到 / 出错的收起，点开看原因
struct SourceListSection: View {
    @ObservedObject var search: SourceSearch
    /// 有没有启用的片源（没有时显示添加入口）
    let hasSources: Bool
    var emptyTitle = "还没有添加片源"
    var emptyMessage = "点这里添加规则或采集站，之后就能搜片播放"
    var reportTitle = "片源搜索报告"

    @ObservedObject private var uz = UZStore.shared
    @State private var showKeywordEditor = false
    @State private var keywordDraft = ""
    @State private var foundExpanded = false
    @State private var problemCandidate: SourceSearch.Candidate?
    @State private var captchaTarget: CaptchaTarget?

    /// 找到的片源很多时先显示前几个
    private let foldLimit = 8

    private enum Row: Identifiable {
        case found(SourceSearch.Ranked, best: Bool)
        case fold(Int)
        case captcha(SourceSearch.Candidate)
        case pending([SourceSearch.Candidate])
        case problem(SourceSearch.Candidate)

        var id: String {
            switch self {
            case .found(let entry, _): return "found:" + entry.id
            case .fold: return "fold"
            case .captcha(let candidate): return "captcha:" + candidate.id
            case .pending: return "pending"
            case .problem(let candidate): return "problem:" + candidate.id
            }
        }
    }

    var body: some View {
        let ranked = search.ranked
        let candidates = search.candidates
        let pending = search.ordered(candidates.filter { search.result(of: $0) == .loading })
        let captcha = candidates.filter { search.result(of: $0) == .captcha }
        let failed = search.ordered(candidates.filter { candidate in
            if case .failed = search.result(of: candidate) { return true }
            return false
        })
        let empty = search.ordered(candidates.filter { search.result(of: $0) == .empty })
        let showOthers = search.problemsExpanded ?? (ranked.isEmpty && pending.isEmpty && captcha.isEmpty)

        let foldable = ranked.count > foldLimit + 2
        var shown = foldable && !foundExpanded ? Array(ranked.prefix(foldLimit)) : ranked
        if let selected = ranked.first(where: { $0.id == search.selectedID }), !shown.contains(where: { $0.id == selected.id }) {
            shown.append(selected)
        }
        var mainRows: [Row] = shown.map { Row.found($0, best: $0.id == ranked.first?.id) }
        if foldable { mainRows.append(.fold(ranked.count - foldLimit)) }
        mainRows += captcha.map { Row.captcha($0) }
        if !pending.isEmpty { mainRows.append(.pending(pending)) }
        let problemRows = (failed + empty).map { Row.problem($0) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("片源")
                    .font(.headline)
                Text("按匹配度")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("换个搜索词", icon: "character.cursor.ibeam") {
                    keywordDraft = search.keyword
                    showKeywordEditor = true
                }
                .font(.subheadline)
                .glassButtonStyle()
                .controlSize(.small)
            }

            if search.keyword != search.subject.title {
                Text("搜索词：\(search.keyword)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !hasSources {
                NoRulesBanner(title: emptyTitle, message: emptyMessage)
            }

            if candidates.contains(where: { $0.kind == .uz }), !uz.hasNetdiskLogin {
                NavigationLink {
                    UZSettingsView()
                } label: {
                    Label("网盘片源要先登录网盘（夸克、UC 等）才能播放，没登录时排在最后", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if !mainRows.isEmpty {
                card(mainRows)
            }

            // 都找到了也能复制报告（排序不对时发给开发者看）
            if !problemRows.isEmpty || !ranked.isEmpty {
                HStack(spacing: 10) {
                    if !problemRows.isEmpty {
                        Button {
                            withAnimation(.snappyCompat) { search.problemsExpanded = !showOthers }
                        } label: {
                            Label(
                                [failed.isEmpty ? "" : "\(failed.count) 个出错", empty.isEmpty ? "" : "\(empty.count) 个没找到"]
                                    .filter { !$0.isEmpty }.joined(separator: " · "),
                                systemImage: showOthers ? "chevron.up" : "chevron.down"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button(search.reportCopied ? "已复制" : "复制报告", icon: search.reportCopied ? "checkmark" : "doc.on.doc") {
                        copyReport()
                    }
                    .font(.subheadline)
                    .glassButtonStyle()
                    .controlSize(.small)
                    .accessibilityHint("复制每个片源的搜索结果和出错原因，可以发给开发者排查")
                }
                if showOthers, !problemRows.isEmpty {
                    card(problemRows)
                }
            }
        }
        .padding(.horizontal)
        .alert(
            problemCandidate?.name ?? "",
            isPresented: Binding(get: { problemCandidate != nil }, set: { if !$0 { problemCandidate = nil } }),
            presenting: problemCandidate
        ) { candidate in
            Button("重试") { Task { await search.retry(candidate) } }
            Button("复制") { UIPasteboard.general.string = search.problemText(candidate) }
            Button("好", role: .cancel) {}
        } message: { candidate in
            Text(search.problemText(candidate))
        }
        .sheet(item: $captchaTarget) { target in
            CaptchaView(target: target) { items in
                guard let candidate = search.candidates.first(where: { $0.id == "rule:" + target.rule.id }) else { return }
                Task { await search.retry(candidate, items: items) }
            }
        }
        .textFieldAlert(
            "修改搜索词", isPresented: $showKeywordEditor, text: $keywordDraft, placeholder: "片名",
            message: "片源里的名称和这里的不一致时，可以换个叫法（原名、缩短）再搜", confirm: "搜索"
        ) {
            search.setKeyword(keywordDraft)
        }
    }

    private func card(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                if row.id != rows.first?.id {
                    Divider().padding(.leading, 14)
                }
                rowView(row)
            }
        }
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case let .found(entry, best: best):
            foundRow(entry, best: best)
        case .fold(let hidden):
            Button {
                withAnimation(.snappyCompat) { foundExpanded.toggle() }
            } label: {
                Label(foundExpanded ? "收起" : "再显示 \(hidden) 个片源", systemImage: foundExpanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        case .captcha(let candidate):
            HStack(spacing: 8) {
                Text(candidate.name)
                    .font(.subheadline)
                SourceKindBadge(kind: candidate.kind)
                Spacer()
                Button("需要验证") { openCaptcha(candidate) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        case .pending(let list):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(pendingText(list))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        case .problem(let candidate):
            problemRow(candidate)
        }
    }

    private func foundRow(_ entry: SourceSearch.Ranked, best: Bool) -> some View {
        let selected = search.selectedID == entry.id
        let tag: String? = search.isPreferred(entry.candidate)
            ? "上次选的" : (search.isLastWatched(entry.candidate) ? "上次看的" : (best ? "最匹配" : nil))
        return Button {
            withAnimation(.snappyCompat) { search.select(entry.id) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.candidate.name)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        SourceKindBadge(kind: entry.candidate.kind)
                        if let tag {
                            Text(tag)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(summary(entry.hit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func problemRow(_ candidate: SourceSearch.Candidate) -> some View {
        Button {
            problemCandidate = candidate
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        SourceKindBadge(kind: candidate.kind)
                    }
                    problemLine(candidate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func problemLine(_ candidate: SourceSearch.Candidate) -> Text {
        if case .failed(let message) = search.result(of: candidate) {
            return Text(SourceSearch.problem(message).label).foregroundColor(.orange) + Text(" · " + message)
        }
        return Text("没有找到")
    }

    private func summary(_ hit: SourceSearch.Hit) -> String {
        var parts = [hit.name]
        if !hit.year.isEmpty { parts.append(hit.year) }
        if !hit.remarks.isEmpty {
            parts.append(hit.remarks)
        } else if hit.episodeCount > 1 {
            parts.append("\(hit.episodeCount) 集")
        }
        return parts.joined(separator: " · ")
    }

    private func pendingText(_ list: [SourceSearch.Candidate]) -> String {
        let names = list.prefix(3).map(\.name).joined(separator: "、")
        return list.count > 3 ? "还在搜 \(list.count) 个片源：\(names) 等" : "还在搜：\(names)"
    }

    private func openCaptcha(_ candidate: SourceSearch.Candidate) {
        guard let rule = candidate.rule,
              let request = try? RuleEngine.searchRequest(for: rule, keyword: search.keyword),
              let url = request.url else { return }
        captchaTarget = CaptchaTarget(rule: rule, url: url, keyword: search.keyword)
    }

    private func copyReport() {
        Task {
            let text = await search.report(title: reportTitle)
            UIPasteboard.general.string = text
            search.reportCopied = true
            Haptics.success()
        }
    }
}

// MARK: - 选集

/// 选中片源的选集：线路切换、正序 / 倒序，集数多时先显示前几行
struct EpisodePanel: View {
    let hit: SourceSearch.Hit
    @Binding var road: Int
    /// 播放记录停在这条线路的第几集
    let current: Int?
    let onPlay: (Int) -> Void

    @State private var expanded = false
    @AppStorage("episodeListReversed") private var reversed = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(hit.episodeCount > 1 ? "选集 · 共 \(hit.episodeCount) 集" : "播放")
                    .font(.headline)
                if !hit.remarks.isEmpty {
                    Text(hit.remarks)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if hit.episodeCount > 1 {
                    Button {
                        withAnimation(.snappyCompat) { reversed.toggle() }
                    } label: {
                        Label(reversed ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
                            .font(.subheadline)
                    }
                    .glassButtonStyle()
                    .controlSize(.small)
                }
            }

            if hit.roads.count > 1 {
                // 网盘分享的线路名比较长：放不下时改成菜单
                if hit.roads.count > 3 || hit.roads.contains(where: { $0.name.count > 6 }) {
                    Picker(selection: $road) {
                        ForEach(hit.roads.indices, id: \.self) { index in
                            Text("\(hit.roads[index].name)（\(hit.roads[index].episodes.count)）").tag(index)
                        }
                    } label: {
                        Text("线路")
                    }
                    .pickerStyle(.menu)
                } else {
                    Picker("线路", selection: $road) {
                        ForEach(hit.roads.indices, id: \.self) { index in
                            Text(hit.roads[index].name).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if hit.roads.indices.contains(road) {
                let list = hit.roads[road].episodes
                // 网盘文件名比较长：一行一个
                let wide = list.prefix(30).contains { $0.name.count > 8 }
                let order = reversed ? Array(list.indices.reversed()) : Array(list.indices)
                // 集数多时先显示前几行（页面短一些，下面的片源不用划很久；搜索中切换片源时页面也不会大幅跳动）
                let limit = wide ? 6 : 20
                let foldable = order.count > limit + 4
                let shown = foldable && !expanded ? Array(order.prefix(limit)) : order
                LazyVGrid(columns: wide ? [GridItem(.flexible())] : columns, spacing: 10) {
                    ForEach(shown, id: \.self) { index in
                        let isCurrent = current == index
                        Button {
                            onPlay(index)
                        } label: {
                            Text(list[index].name)
                                .font(.subheadline.weight(isCurrent ? .bold : .regular))
                                .lineLimit(wide ? 2 : 1)
                                .minimumScaleFactor(wide ? 0.85 : 0.7)
                                .multilineTextAlignment(wide ? .leading : .center)
                                .padding(.horizontal, wide ? 12 : 4)
                                // 高度固定：格子高度不一时，快速滚动会让懒加载的网格估错高度、页面跳动
                                .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                                .frame(height: wide ? 54 : 40)
                                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                                .background(
                                    isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.14)),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                if foldable {
                    Button {
                        withAnimation(.snappyCompat) { expanded.toggle() }
                    } label: {
                        Label(expanded ? "收起" : "展开全部 \(list.count) 集", systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .glassButtonStyle()
                }
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - 片源大类

/// 片源类型小标签
struct SourceKindBadge: View {
    let kind: SourceKind

    init(kind: SourceKind) {
        self.kind = kind
    }

    init(isCMS: Bool) {
        kind = isCMS ? .cms : .rule
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
        Text(kind.label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// 设置：片源大类的先后顺序
struct SourceKindOrderView: View {
    @AppStorage(SourceKindOrder.key) private var raw = ""

    private var order: [SourceKind] { SourceKindOrder.parse(raw) }

    var body: some View {
        List {
            Section {
                ForEach(order) { kind in
                    HStack(spacing: 10) {
                        SourceKindBadge(kind: kind)
                        Text(kind.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .onMove { from, to in
                    var list = order
                    list.move(fromOffsets: from, toOffset: to)
                    raw = SourceKindOrder.raw(list)
                }
            } header: {
                Text("拖动调整先后")
            } footer: {
                Text("详情页找到的片源先看片名对不对得上（片名一致 → 片名包含 → 对不上，年份差太多或集数明显不全的往后放），同一档里按这里的大类顺序，再按匹配度和「规则管理」里的顺序。点选过、看过的片源始终排最前。没登录网盘时，网盘片源自动放到最后（搜到了也播放不了）。")
            }

            if order != SourceKindOrder.defaultOrder {
                Section {
                    Button("恢复默认（猫影视 → 网盘 → 采集站 → 规则）") {
                        raw = SourceKindOrder.raw(SourceKindOrder.defaultOrder)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("片源大类顺序")
        .navigationBarTitleDisplayMode(.inline)
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
