import SwiftUI

/// 影视详情：打开后自动在所有启用的采集站里按片名搜索，按优先级选中第一个找到的片源，直接选集播放
struct VideoDetailView: View {
    @State private var subject: BangumiSubject
    @ObservedObject private var library = WatchLibrary.shared
    @ObservedObject private var tints = PosterTints.shared
    @EnvironmentObject private var ruleStore: RuleStore
    @Environment(\.colorScheme) private var systemScheme

    enum SourceResult: Equatable {
        case loading
        case found(CMSItem)
        case empty
        case failed(String)
    }

    @State private var keyword: String
    @State private var results: [String: SourceResult] = [:]
    @State private var selectedID: String?
    /// 用户手动选过片源后，不再自动切到优先级更高的
    @State private var userSelected = false
    @State private var selectedRoad = 0
    @State private var playRequest: PlayRequest?
    @State private var summaryExpanded = false
    @State private var showKeywordEditor = false
    @State private var keywordDraft = ""
    @State private var directors = ""
    @State private var actors = ""
    @AppStorage("episodeListReversed") private var episodesReversed = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10)]

    init(subject: BangumiSubject) {
        _subject = State(initialValue: subject)
        _keyword = State(initialValue: subject.title)
    }

    private var tint: PosterTint? { tints.tint(for: subject.id) }
    private var isFavorite: Bool { library.isFavorite(subject.id) }
    private var record: WatchRecord? { library.record(subject.id) }
    private var sources: [CMSSource] { ruleStore.enabledCMS }

    private var selectedItem: CMSItem? {
        guard let selectedID, case .found(let item) = results[selectedID] else { return nil }
        return item
    }

    private var isSearching: Bool {
        sources.contains { results["cms:" + $0.id] == nil || results["cms:" + $0.id] == .loading }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actions
                if let item = selectedItem {
                    episodes(of: item)
                }
                sourceList
                info
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: .top)
        .background {
            (tint?.color ?? Color(uiColor: .systemBackground))
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, tint?.colorScheme ?? systemScheme)
        .navigationTitle(subject.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitleHidden()
        .task { await PosterTints.shared.ensure(subject) }
        .task { await loadAbstract() }
        .task(id: keyword + "|" + sources.map(\.id).joined(separator: ",")) { await searchSources() }
        .navigationDestinationCompat(item: $playRequest) { request in
            PlayerScreen(request: request)
        }
        .textFieldAlert(
            "修改搜索词", isPresented: $showKeywordEditor, text: $keywordDraft, placeholder: "片名",
            message: "片源里的名称和豆瓣不一致时，可以换个叫法再搜", confirm: "搜索"
        ) {
            let word = keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, word != keyword {
                userSelected = false
                keyword = word
            }
        }
    }

    // MARK: 头部

    private var meta: String {
        var parts: [String] = []
        if !subject.airDate.isEmpty { parts.append(subject.airDate) }
        parts.append(contentsOf: subject.tags.prefix(4))
        if subject.episodes > 0 { parts.append("\(subject.episodes) 集") }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        Color.clear
            .containerHeight(fraction: 0.66, max: 720)
            .frame(maxWidth: .infinity)
            .overlay {
                PosterImage(url: subject.image, fallback: subject.thumb, showsPlaceholder: false)
                    .mask(PosterFadeMask())
            }
            .clipped()
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    Text(subject.title)
                        .font(.system(size: 30, weight: .heavy))
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let score = subject.scoreText {
                        Label("豆瓣 \(score)", systemImage: "star.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
            }
    }

    // MARK: 按钮

    private var actions: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                primaryButton
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .symbolReplaceTransition()
                }
                .glassButtonStyle()
                .controlSize(.large)
                .selectionFeedback(trigger: isFavorite)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let record, record.isCMSRecord {
            Button {
                playRequest = record.playRequest
            } label: {
                Label("继续 \(record.episodeName)", systemImage: "play.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .glassProminentButtonStyle()
            .controlSize(.large)
        } else if let item = selectedItem {
            Button {
                play(item, episode: 0)
            } label: {
                Label("播放", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .glassProminentButtonStyle()
            .controlSize(.large)
        } else {
            Button {} label: {
                Label(
                    sources.isEmpty ? "还没有添加采集站" : (isSearching ? "正在查找片源…" : "未找到相关资源"),
                    systemImage: isSearching ? "magnifyingglass" : "exclamationmark.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .glassButtonStyle()
            .controlSize(.large)
            .disabled(true)
        }
    }

    // MARK: 选集

    private func episodes(of item: CMSItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.episodeCount > 1 ? "选集 · 共 \(item.episodeCount) 集" : "播放")
                    .font(.headline)
                if !item.remarks.isEmpty {
                    Text(item.remarks)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.episodeCount > 1 {
                    Button {
                        withAnimation(.snappyCompat) { episodesReversed.toggle() }
                    } label: {
                        Label(episodesReversed ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
                            .font(.subheadline)
                    }
                    .glassButtonStyle()
                    .controlSize(.small)
                }
            }

            if item.roads.count > 1 {
                Picker("线路", selection: $selectedRoad) {
                    ForEach(item.roads.indices, id: \.self) { index in
                        Text(item.roads[index].name).tag(index)
                    }
                }
                .pickerStyle(.segmented)
            }

            if item.roads.indices.contains(selectedRoad) {
                let list = item.roads[selectedRoad].episodes
                let current = record.flatMap { $0.isCMSRecord && $0.vodID == item.vodID && $0.roadIndex == selectedRoad ? $0.episodeIndex : nil }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(episodesReversed ? Array(list.indices.reversed()) : Array(list.indices), id: \.self) { index in
                        let isCurrent = current == index
                        Button {
                            play(item, episode: index)
                        } label: {
                            Text(list[index].name)
                                .font(.subheadline.weight(isCurrent ? .bold : .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                                .background(
                                    isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.14)),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: 片源

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("片源")
                    .font(.headline)
                Text("按优先级")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("换个搜索词", icon: "character.cursor.ibeam") {
                    keywordDraft = keyword
                    showKeywordEditor = true
                }
                .font(.subheadline)
                .glassButtonStyle()
                .controlSize(.small)
            }

            if sources.isEmpty {
                NoRulesBanner(title: "还没有添加采集站", message: "点这里添加采集站或导入订阅，之后就能搜片播放")
            }

            VStack(spacing: 0) {
                ForEach(sources) { source in
                    sourceRow(source)
                    if source.id != sources.last?.id {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal)
    }

    private func sourceRow(_ source: CMSSource) -> some View {
        let id = "cms:" + source.id
        let result = results[id] ?? .loading
        let selected = selectedID == id
        return Button {
            guard case .found = result else { return }
            userSelected = true
            selectedRoad = 0
            withAnimation(.snappyCompat) { selectedID = id }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Group {
                        switch result {
                        case .loading:
                            Text("搜索中…")
                        case .found(let item):
                            Text([item.name, item.remarks, item.year].filter { !$0.isEmpty }.joined(separator: " · "))
                        case .empty:
                            Text("没有找到")
                        case .failed(let message):
                            Text(message)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                if result == .loading {
                    ProgressView().controlSize(.small)
                } else if selected {
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

    // MARK: 简介

    @ViewBuilder
    private var info: some View {
        let item = selectedItem
        let summary = item?.content ?? subject.summary
        let director = directors.isEmpty ? (item?.director ?? "") : directors
        let actor = actors.isEmpty ? (item?.actor ?? "") : actors
        if !summary.isEmpty || !director.isEmpty || !actor.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(summaryExpanded ? nil : 5)
                    Button(summaryExpanded ? "收起" : "展开") {
                        withAnimation(.snappyCompat) { summaryExpanded.toggle() }
                    }
                    .font(.callout.weight(.medium))
                }
                if !director.isEmpty {
                    Text("导演：\(director)").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                if !actor.isEmpty {
                    Text("主演：\(actor)").font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: 数据

    private func loadAbstract() async {
        guard let id = subject.doubanID, let info = try? await DoubanAPI.abstract(id: id) else { return }
        if subject.airDate.isEmpty { subject.airDate = info.year }
        if subject.tags.isEmpty { subject.tags = info.tags }
        if subject.episodes == 0 { subject.episodes = info.episodes }
        if subject.score == 0 { subject.score = info.score }
        directors = info.directors
        actors = info.actors
    }

    private func searchSources() async {
        let word = keyword
        let targets = sources
        guard !targets.isEmpty else { return }
        for source in targets { results["cms:" + source.id] = .loading }
        if !userSelected { selectedID = nil }
        let year = subject.airDate.count >= 4 ? String(subject.airDate.prefix(4)) : ""
        await withTaskGroup(of: (String, SourceResult).self) { group in
            for source in targets {
                group.addTask {
                    do {
                        let items = try await CMSSearchCache.shared.search(source, keyword: word)
                        guard let best = Self.bestMatch(items, title: word, year: year) else { return ("cms:" + source.id, .empty) }
                        return ("cms:" + source.id, .found(best))
                    } catch {
                        return ("cms:" + source.id, .failed(error.localizedDescription))
                    }
                }
            }
            for await (id, result) in group {
                results[id] = result
                autoSelect()
            }
        }
    }

    /// 自动选中优先级最高的、已经找到结果的片源（前面的还在搜就先用后面的，搜到了再切过去）
    private func autoSelect() {
        guard !userSelected else { return }
        for source in sources {
            if case .found = results["cms:" + source.id] {
                let id = "cms:" + source.id
                if selectedID != id {
                    selectedRoad = 0
                    withAnimation(.snappyCompat) { selectedID = id }
                }
                return
            }
        }
    }

    /// 片名完全一致的优先，再按年份挑
    nonisolated static func bestMatch(_ items: [CMSItem], title: String, year: String) -> CMSItem? {
        let target = CMSClient.normalizeTitle(title)
        let exact = items.filter { CMSClient.normalizeTitle($0.name) == target }
        let pool = exact.isEmpty ? items : exact
        if !year.isEmpty, let sameYear = pool.first(where: { $0.year == year }) { return sameYear }
        return pool.first
    }

    private func play(_ item: CMSItem, episode: Int) {
        var request = PlayRequest(subject: subject, pick: .cms(item), episodeIndex: episode)
        request.roadIndex = selectedRoad
        if let record, record.isCMSRecord, record.vodID == item.vodID, record.roadIndex == selectedRoad,
           record.episodeIndex == episode {
            request.position = record.position
        }
        playRequest = request
    }

    private func toggleFavorite() {
        library.toggleFavorite(subject)
    }
}

extension WatchRecord {
    var isCMSRecord: Bool { !cmsAPI.isEmpty }
}
