import SwiftUI

/// 禁漫的分类和排序
enum JMCatalog {
    struct Option: Hashable {
        let name: String
        let value: String
        init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    static let categories: [Option] = [
        Option("最新", "0"), Option("同人", "doujin"), Option("单本", "single"), Option("短篇", "short"),
        Option("韩漫", "hanman"), Option("美漫", "meiman"),
        Option("Cosplay", "another_cosplay"), Option("3D", "3D"), Option("汉化组", "禁漫漢化組"),
    ]

    static let sorts: [Option] = [
        Option("最新", "mr"), Option("总排行", "mv"), Option("月排行", "mv_m"), Option("周排行", "mv_w"),
        Option("日排行", "mv_t"), Option("最多图片", "mp"), Option("最多喜欢", "tf"),
    ]

    static func sortName(_ value: String) -> String {
        sorts.first { $0.value == value }?.name ?? value
    }
}

/// 分页列表（分类、搜索、标签结果共用），禁漫每页 80 条
@MainActor
final class ComicListModel: ObservableObject {
    @Published var items: [JMComic] = []
    @Published var total = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var redirectID: String?
    @Published private var page = 0
    @Published private var exhausted = false
    private var generation = 0
    var loader: (Int) async throws -> JMPage

    init(loader: @escaping (Int) async throws -> JMPage = { _ in JMPage(comics: [], total: 0) }) {
        self.loader = loader
    }

    func reload() async {
        generation += 1
        items = []
        total = 0
        page = 0
        exhausted = false
        isLoading = false
        error = nil
        redirectID = nil
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !exhausted else { return }
        let current = generation
        isLoading = true
        error = nil
        do {
            let result = try await loader(page + 1)
            guard current == generation else { return }
            page += 1
            total = result.total
            if let id = result.redirectID { redirectID = id }
            let existing = Set(items.map(\.id))
            items += result.comics.filter { !existing.contains($0.id) }
            if result.comics.isEmpty || items.count >= result.total { exhausted = true }
            PosterTints.shared.prefetch(result.comics.prefix(24).map(\.subject))
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

/// 漫画网格 + 自动加载下一页
struct ComicGrid: View {
    @ObservedObject var model: ComicListModel
    private let grid = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: grid, spacing: 18) {
                ForEach(model.items) { comic in
                    NavigationLink(destination: AppDestination(comic.subject)) {
                        PosterCard(subject: comic.subject, subtitle: comic.author.isEmpty ? nil : comic.author)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if comic.id == model.items.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
                }
            }
            if model.isLoading {
                ProgressView()
            } else if let error = model.error {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试", icon: "arrow.clockwise") {
                        Task { await model.loadMore() }
                    }
                    .glassButtonStyle()
                }
            }
        }
        .padding(.horizontal)
    }
}

/// 漫画首页数据：推荐分区 + 轮播
@MainActor
final class ComicHomeModel: ObservableObject {
    @Published var sections: [JMSection] = []
    @Published var hero: [BangumiSubject] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published private var loaded = false

    private struct Snapshot: Codable {
        var sections: [JMSection]
        var hero: [BangumiSubject]
    }

    private static var snapshotURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("comic-home-snapshot.json")
    }

    init() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        sections = snapshot.sections.filter { !JMClient.isHiddenSection($0.title) }
        hero = snapshot.hero
    }

    func load(force: Bool = false) async {
        if loaded && !force { return }
        isLoading = true
        error = nil
        await JMClient.prepare()
        do {
            let result = try await JMClient.promote()
            sections = result
            loaded = true
            let pool = Array(result.prefix(3).flatMap(\.comics).prefix(30)).map(\.subject)
            if hero.isEmpty || force || !pool.contains(where: { $0.id == hero.first?.id }) {
                let prepared = await prepareHero(from: pool, excluding: Set(hero.map(\.id)))
                if !prepared.isEmpty {
                    withAnimation(.easeInOut(duration: 0.5)) { hero = prepared }
                }
            }
            PosterTints.shared.prefetch(result.flatMap(\.comics).prefix(60).map(\.subject))
            saveSnapshot()
        } catch {
            self.error = sections.isEmpty
                ? "连接禁漫失败：\(error.localizedDescription)。可以到设置里换条线路"
                : "连接禁漫失败，显示的是上次的内容"
        }
        isLoading = false
    }

    private func prepareHero(from pool: [BangumiSubject], excluding: Set<Int>) async -> [BangumiSubject] {
        var candidates = pool.filter { !excluding.contains($0.id) }
        if candidates.count < 6 { candidates = pool }
        let picked = Array(candidates.shuffled().prefix(6))
        await withTaskGroup(of: Void.self) { group in
            for subject in picked {
                group.addTask {
                    async let poster = ImageCache.shared.load(subject.image)
                    await PosterTints.shared.ensure(subject)
                    _ = await poster
                }
            }
        }
        return picked
    }

    private func saveSnapshot() {
        guard let data = try? JSONEncoder().encode(Snapshot(sections: sections, hero: hero)) else { return }
        let url = Self.snapshotURL
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }
}

/// 漫画首页（禁漫天堂）：推荐分区 + 分类浏览，背景和其它首页一样跟着海报取色
struct ComicHomeView: View {
    @ObservedObject private var tints = PosterTints.shared
    @StateObject private var model = ComicHomeModel()
    /// 用 @State 持有、不订阅：滑动时只有背景层（HomeBackground）重绘，整页不跟着每帧刷新
    @State private var scroll = HeroScrollState()
    @State private var contentScheme: ColorScheme?
    @StateObject private var browse = ComicListModel()
    @State private var category = "0"
    @State private var sort = "mr"
    @Environment(\.colorScheme) private var systemScheme

    private var firstHeroScheme: ColorScheme? {
        model.hero.first.flatMap { PosterTints.shared.tint(for: $0.id)?.colorScheme }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HeroCarousel(items: model.hero, scroll: scroll)

                if let error = model.error {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: section.title)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(section.comics) { comic in
                                    NavigationLink(destination: AppDestination(comic.subject)) {
                                        PosterCard(subject: comic.subject, width: 116)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .hideScrollIndicators()
                    }
                }

                browseSection
            }
            .padding(.bottom, 24)
        }
        .background {
            HomeBackground(hero: model.hero, scroll: scroll) { contentScheme = $0 }
        }
        .environment(\.colorScheme, contentScheme ?? firstHeroScheme ?? systemScheme)
        .ignoresSafeArea(edges: .top)
        .navigationBarHiddenCompat()
        .refreshable {
            await model.load(force: true)
            await browse.reload()
        }
        .task {
            await model.load()
            if browse.items.isEmpty { await reloadBrowse() }
        }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("分类浏览")
                    .font(.title2.weight(.bold))
                Spacer()
                Menu {
                    Picker("排序", selection: Binding(get: { sort }, set: { value in
                        sort = value
                        Task { await reloadBrowse() }
                    })) {
                        ForEach(JMCatalog.sorts, id: \.value) { item in
                            Text(item.name).tag(item.value)
                        }
                    }
                } label: {
                    Label(JMCatalog.sortName(sort), systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                }
                .glassButtonStyle()
                .controlSize(.small)
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(JMCatalog.categories, id: \.value) { item in
                        let selected = item.value == category
                        TagChip(title: item.name, selected: selected) {
                            guard !selected else { return }
                            category = item.value
                            Task { await reloadBrowse() }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .hideScrollIndicators()

            ComicGrid(model: browse)
        }
    }

    private func reloadBrowse() async {
        let slug = category, order = sort
        browse.loader = { page in try await JMClient.category(slug, sort: order, page: page) }
        await browse.reload()
    }
}

/// 漫画搜索：关键词、作者、标签或车号（JM123456）
struct ComicSearchView: View {
    @State private var query = ""
    @State private var searched = ""
    @State private var sort = "mr"
    @StateObject private var model = ComicListModel()

    /// 输入的是车号时，直接给出打开入口
    private var directID: String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = text.hasPrefix("jm") ? String(text.dropFirst(2)) : text
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) ? digits : nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let id = directID ?? model.redirectID {
                    NavigationLink(destination: AppDestination(BangumiSubject.comic(jmID: Int(id) ?? 0, title: "JM\(id)", author: "", tags: [], description: ""))) {
                        Label("打开 JM\(id)", systemImage: "book.pages")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .glassButtonStyle()
                    .padding(.horizontal)
                }
                if !searched.isEmpty, model.total > 0 {
                    Text("共 \(model.total) 个结果 · \(JMCatalog.sortName(sort))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                ComicGrid(model: model)
            }
            .padding(.vertical)
        }
        .dismissKeyboardOnScroll()
        .overlay {
            if model.items.isEmpty, !model.isLoading, model.error == nil {
                if searched.isEmpty {
                    EmptyStateView("搜索漫画", systemImage: "book", description: Text("禁漫天堂：本子名、作者、标签，或者直接输入车号"))
                } else if directID == nil, model.redirectID == nil {
                    EmptyStateView.search(text: searched)
                }
            }
        }
        .navigationTitle("搜索漫画")
        .searchTab(text: $query, prompt: "本子名、作者、标签或车号")
        .onSubmit(of: .search) { run() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("排序", selection: Binding(get: { sort }, set: { value in
                        sort = value
                        if !searched.isEmpty { run() }
                    })) {
                        ForEach(JMCatalog.sorts, id: \.value) { item in
                            Text(item.name).tag(item.value)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
    }

    private func run() {
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        searched = word
        let order = sort
        model.loader = { page in try await JMClient.search(word, sort: order, page: page) }
        Task { await model.reload() }
    }
}

/// 点标签 / 作者后的结果页
struct ComicTagRoute: Hashable {
    let keyword: String
}

struct ComicTagResultsView: View {
    let keyword: String
    @StateObject private var model = ComicListModel()
    @State private var sort = "mr"

    var body: some View {
        ScrollView {
            ComicGrid(model: model)
                .padding(.vertical)
        }
        .navigationTitle(keyword)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("排序", selection: Binding(get: { sort }, set: { value in
                        sort = value
                        Task { await reload() }
                    })) {
                        ForEach(JMCatalog.sorts, id: \.value) { item in
                            Text(item.name).tag(item.value)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .task { if model.items.isEmpty { await reload() } }
    }

    private func reload() async {
        let word = keyword, order = sort
        model.loader = { page in try await JMClient.search(word, sort: order, page: page) }
        await model.reload()
    }
}
