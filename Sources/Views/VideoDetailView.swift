import SwiftUI

/// 影视详情：打开后自动在所有启用的片源里按片名搜索，按匹配度和片源大类顺序选中最合适的片源，直接选集播放
struct VideoDetailView: View {
    @State private var subject: BangumiSubject
    @StateObject private var search: SourceSearch
    @ObservedObject private var library = WatchLibrary.shared
    @ObservedObject private var tints = PosterTints.shared
    @ObservedObject private var uz = UZStore.shared
    @ObservedObject private var cat = CatStore.shared
    @EnvironmentObject private var ruleStore: RuleStore
    @Environment(\.colorScheme) private var systemScheme

    @State private var playRequest: PlayRequest?
    @State private var summaryExpanded = false
    @State private var directors = ""
    @State private var actors = ""

    init(subject: BangumiSubject) {
        _subject = State(initialValue: subject)
        // 同一部作品最近搜过就直接用上次的结果（去播放再回来、退回列表再点进来都不重搜）
        _search = StateObject(wrappedValue: SourceSearch.shared(for: subject))
    }

    private var tint: PosterTint? { tints.tint(for: subject.id) }
    private var isFavorite: Bool { library.isFavorite(subject.id) }
    private var record: WatchRecord? { library.record(subject.id) }

    /// 影视只搜采集站、网盘资源站和猫影视插件（Kazumi 规则都是动漫站）
    private var candidates: [SourceSearch.Candidate] {
        SourceSearch.candidates(entries: ruleStore.searchableEntries(includeRules: false), uz: uz.vodSources, cat: cat.vodSources)
    }

    var body: some View {
        let list = candidates
        let selected = search.selected
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actions
                if let selected, !selected.hit.roads.isEmpty {
                    EpisodePanel(hit: selected.hit, road: $search.selectedRoad, current: search.recordEpisode) { episode in
                        play(episode)
                    }
                }
                SourceListSection(
                    search: search, hasSources: !list.isEmpty,
                    emptyTitle: "还没有添加采集站", emptyMessage: "点这里添加采集站或导入订阅，之后就能搜片播放"
                )
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
        .task(id: search.keyword + "|" + list.map(\.id).joined(separator: ",")) { await search.start(list) }
        .navigationDestinationCompat(item: $playRequest) { request in
            PlayerScreen(request: request)
        }
        .toast($uz.notice)
        .sheet(item: Binding(
            get: { uz.verifyRequest.map(UZVerifyRequest.init) },
            set: { uz.verifyRequest = $0?.url }
        )) { request in
            UZVerifySheet(url: request.url)
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
        } else if search.selected != nil {
            Button {
                play(0)
            } label: {
                Label("播放", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .glassProminentButtonStyle()
            .controlSize(.large)
        } else {
            Button {} label: {
                Label(
                    candidates.isEmpty ? "还没有添加采集站" : (search.isSearching ? "正在查找片源…" : "未找到相关资源"),
                    systemImage: search.isSearching ? "magnifyingglass" : "exclamationmark.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .glassButtonStyle()
            .controlSize(.large)
            .disabled(true)
        }
    }

    // MARK: 简介

    @ViewBuilder
    private var info: some View {
        let item = search.selected?.hit.cms
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
        // 年份、集数参与片源排序
        search.subject = subject
    }

    private func play(_ episode: Int) {
        if let request = search.playRequest(episode: episode) { playRequest = request }
    }

    private func toggleFavorite() {
        library.toggleFavorite(subject)
    }
}
