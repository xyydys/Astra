import SwiftUI

/// 影视首页数据：豆瓣热门电影 / 剧集、轮播海报、分类浏览
@Observable
@MainActor
final class VideoHomeModel {
    var hero: [BangumiSubject] = []
    var hotMovies: [BangumiSubject] = []
    var hotTV: [BangumiSubject] = []
    var isLoading = false
    var error: String?

    var browseKind: DoubanAPI.Kind = .movie
    var browseTag = "热门"
    var browse: [BangumiSubject] = []
    var browseLoading = false
    var browseError: String?
    private var browseExhausted = false
    @ObservationIgnored private var browseGeneration = 0

    private var loaded = false
    @ObservationIgnored private var upcomingHero: [BangumiSubject] = []

    private struct Snapshot: Codable {
        var hero: [BangumiSubject]
        var hotMovies: [BangumiSubject]
        var hotTV: [BangumiSubject]
        var upcomingHero: [BangumiSubject]
    }

    private static var snapshotURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("video-home-snapshot.json")
    }

    init() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        hotMovies = snapshot.hotMovies
        hotTV = snapshot.hotTV
        hero = snapshot.upcomingHero.isEmpty ? snapshot.hero : snapshot.upcomingHero
    }

    func load(force: Bool = false) async {
        if loaded && !force { return }
        isLoading = true
        error = nil
        async let movies = try? DoubanAPI.recommend(.movie, tag: "热门")
        async let shows = try? DoubanAPI.recommend(.tv, tag: "热门")
        let (m, t) = await (movies, shows)
        hotMovies = m ?? hotMovies
        hotTV = t ?? hotTV

        let pool = interleave(hotMovies, hotTV)
        if hero.isEmpty || force {
            let prepared = await prepareHero(from: pool, excluding: Set(hero.map(\.id)))
            if !prepared.isEmpty {
                withAnimation(.easeInOut(duration: 0.5)) { hero = prepared }
            }
        }
        if m == nil && t == nil {
            error = hero.isEmpty ? "豆瓣推荐获取失败，下拉重试" : "豆瓣推荐获取失败，显示的是上次的内容"
        } else {
            loaded = true
        }
        isLoading = false
        saveSnapshot()

        PosterTints.shared.prefetch(hotMovies + hotTV)
        if browse.isEmpty || force { await reloadBrowse() }
        if !pool.isEmpty {
            upcomingHero = await prepareHero(from: pool, excluding: Set(hero.map(\.id)))
            saveSnapshot()
        }
    }

    func selectBrowse(kind: DoubanAPI.Kind, tag: String) async {
        guard kind != browseKind || tag != browseTag else { return }
        browseKind = kind
        browseTag = tag
        await reloadBrowse()
    }

    func reloadBrowse() async {
        browseGeneration += 1
        browse = []
        browseExhausted = false
        browseLoading = false
        await loadMoreBrowse()
    }

    func loadMoreBrowse() async {
        guard !browseLoading, !browseExhausted else { return }
        let generation = browseGeneration
        browseLoading = true
        browseError = nil
        do {
            let page = try await DoubanAPI.recommend(browseKind, tag: browseTag, start: browse.count, limit: 24)
            // 加载期间切换了分类：丢掉旧结果
            guard generation == browseGeneration else { return }
            let existing = Set(browse.map(\.id))
            browse += page.filter { !existing.contains($0.id) }
            if page.count < 24 { browseExhausted = true }
            PosterTints.shared.prefetch(page)
        } catch {
            guard generation == browseGeneration else { return }
            browseError = error.localizedDescription
        }
        browseLoading = false
    }

    /// 电影和剧集交替排列，轮播里两种都有
    private func interleave(_ a: [BangumiSubject], _ b: [BangumiSubject]) -> [BangumiSubject] {
        var result: [BangumiSubject] = []
        for i in 0..<max(a.count, b.count) {
            if i < a.count { result.append(a[i]) }
            if i < b.count { result.append(b[i]) }
        }
        return result
    }

    /// 和番剧首页一样：一组海报的简介、取色、大图都准备好再一起换上
    private func prepareHero(from pool: [BangumiSubject], excluding: Set<Int>) async -> [BangumiSubject] {
        let top = Array(pool.prefix(16))
        var candidates = top.filter { !excluding.contains($0.id) }
        if candidates.count < 6 { candidates = top }
        let picked = Array(candidates.shuffled().prefix(6))
        guard !picked.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, BangumiSubject).self) { group in
            for (index, subject) in picked.enumerated() {
                group.addTask {
                    var item = subject
                    if item.airDate.isEmpty, let id = item.doubanID,
                       let info = try? await withDeadline(6, { try await DoubanAPI.abstract(id: id) }) {
                        item.airDate = info.year
                        item.tags = info.tags
                        item.episodes = info.episodes
                    }
                    let ready = item
                    async let poster = ImageCache.shared.load(ready.image)
                    await PosterTints.shared.ensure(ready)
                    _ = await poster
                    return (index, ready)
                }
            }
            var result = picked
            for await (index, item) in group { result[index] = item }
            return result
        }
    }

    private func saveSnapshot() {
        let snapshot = Snapshot(hero: hero, hotMovies: hotMovies, hotTV: hotTV, upcomingHero: upcomingHero)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = Self.snapshotURL
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }
}

/// 影视首页：和番剧首页同样的海报取色背景，内容换成豆瓣推荐
struct VideoHomeView: View {
    @State private var model = VideoHomeModel()
    @State private var scroll = HeroScrollState()
    @State private var contentScheme: ColorScheme?
    @Environment(RuleStore.self) private var ruleStore
    @Environment(\.colorScheme) private var systemScheme

    private let grid = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

    private var firstHeroScheme: ColorScheme? {
        model.hero.first.flatMap { PosterTints.shared.tint(for: $0.id)?.colorScheme }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HeroCarousel(items: model.hero, scroll: scroll)

                if ruleStore.enabledCMS.isEmpty {
                    NoRulesBanner(
                        title: "还没有添加采集站",
                        message: "影视模式通过采集站搜片播放，点这里添加或导入订阅"
                    )
                    .padding(.horizontal)
                }

                if let error = model.error {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                posterRow("热门电影", items: model.hotMovies)
                posterRow("热门剧集", items: model.hotTV)
                browseSection
            }
            .padding(.bottom, 24)
        }
        .background {
            HomeBackground(hero: model.hero, scroll: scroll) { contentScheme = $0 }
        }
        .environment(\.colorScheme, contentScheme ?? firstHeroScheme ?? systemScheme)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.load(force: true) }
        .task { await model.load() }
    }

    @ViewBuilder
    private func posterRow(_ title: String, items: [BangumiSubject]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title, subtitle: "豆瓣")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { subject in
                            NavigationLink(value: subject) {
                                PosterCard(subject: subject, width: 116)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("分类浏览")
                    .font(.title2.weight(.bold))
                Spacer()
                Picker("类型", selection: Binding(
                    get: { model.browseKind },
                    set: { kind in Task { await model.selectBrowse(kind: kind, tag: "热门") } }
                )) {
                    ForEach(DoubanAPI.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.browseKind.tags, id: \.self) { tag in
                        TagChip(title: tag, selected: tag == model.browseTag) {
                            Task { await model.selectBrowse(kind: model.browseKind, tag: tag) }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)

            LazyVGrid(columns: grid, spacing: 18) {
                ForEach(model.browse) { subject in
                    NavigationLink(value: subject) {
                        PosterCard(subject: subject)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if subject.id == model.browse.last?.id {
                            Task { await model.loadMoreBrowse() }
                        }
                    }
                }
            }
            .padding(.horizontal)

            Group {
                if model.browseLoading {
                    ProgressView()
                } else if let error = model.browseError {
                    Button("加载失败，点击重试", systemImage: "arrow.clockwise") {
                        Task { await model.loadMoreBrowse() }
                    }
                    .font(.subheadline)
                    .help(error)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
