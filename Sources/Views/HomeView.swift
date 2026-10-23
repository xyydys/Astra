import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var calendar: [[BangumiSubject]] = []
    @Published var trending: [BangumiSubject] = []
    @Published var hero: [BangumiSubject] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published private var loaded = false
    /// 下次启动要展示的一组轮播（详情、取色、大图都已提前缓存好）
    private var upcomingHero: [BangumiSubject] = []

    /// 上次的首页数据。冷启动先用它把页面完整画出来，再在后台刷新
    private struct Snapshot: Codable {
        var calendar: [[BangumiSubject]]
        var trending: [BangumiSubject]
        var hero: [BangumiSubject]
        var upcomingHero: [BangumiSubject]
    }

    private static var snapshotURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("home-snapshot.json")
    }

    init() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        calendar = snapshot.calendar
        trending = snapshot.trending
        hero = snapshot.upcomingHero.isEmpty ? snapshot.hero : snapshot.upcomingHero
    }

    var today: [BangumiSubject] {
        let index = BangumiAPI.todayIndex
        return calendar.indices.contains(index) ? calendar[index] : []
    }

    func load(force: Bool = false) async {
        if loaded && !force { return }
        isLoading = true
        error = nil
        let calendarTask = Task { try? await BangumiAPI.calendar() }
        let trendingTask = Task { try? await BangumiAPI.trending() }
        let cal = await calendarTask.value
        let trend = await trendingTask.value
        calendar = cal ?? calendar
        trending = trend ?? trending

        // 随机海报：优先热门，热门拿不到就用今日放送
        let pool = (trending.isEmpty ? today : trending).filter { !$0.image.isEmpty }
        if hero.isEmpty || force {
            // 一组海报全部准备好（简介、取色、大图）再一起换上，不会一块一块地冒出来
            let prepared = await prepareHero(from: pool, excluding: Set(hero.map(\.id)))
            if !prepared.isEmpty {
                withAnimation(.easeInOut(duration: 0.5)) { hero = prepared }
            }
        }
        if cal == nil && trend == nil {
            error = hero.isEmpty ? "Bangumi 连接失败，下拉重试" : "Bangumi 连接失败，显示的是上次的内容"
        } else {
            loaded = true
        }
        isLoading = false
        saveSnapshot()

        PosterTints.shared.prefetch(today + trending)
        // 后台准备下次启动的一组
        if !pool.isEmpty {
            upcomingHero = await prepareHero(from: pool, excluding: Set(hero.map(\.id)))
            saveSnapshot()
        }
    }

    private func prepareHero(from pool: [BangumiSubject], excluding: Set<Int>) async -> [BangumiSubject] {
        var candidates = pool.filter { !excluding.contains($0.id) }
        if candidates.count < 6 { candidates = pool }
        let picked = Array(candidates.shuffled().prefix(6))
        guard !picked.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, BangumiSubject).self) { group in
            for (index, subject) in picked.enumerated() {
                group.addTask {
                    var item = subject
                    // 列表接口没有简介和标签；海报地址保持列表里的那张
                    if item.summary.isEmpty, let detail = try? await BangumiAPI.subject(id: item.id, timeout: 6) {
                        let image = item.image, thumb = item.thumb
                        item = item.merged(with: detail)
                        item.image = image
                        item.thumb = thumb
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
        let snapshot = Snapshot(calendar: calendar, trending: trending, hero: hero, upcomingHero: upcomingHero)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = Self.snapshotURL
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }
}

/// 轮播的滚动位置（以页为单位，可以是小数）。单独放一个对象里，
/// 滑动时只有背景层重绘，整个首页不会每帧重新计算
@MainActor
final class HeroScrollState: ObservableObject {
    @Published var position: Double = 0
}

struct HomeView: View {
    @ObservedObject private var tints = PosterTints.shared
    @StateObject private var model = HomeModel()
    /// 用 @State 持有、不订阅：滑动时只有背景层（HomeBackground）重绘，整页不跟着每帧刷新
    @State private var scroll = HeroScrollState()
    /// 背景偏亮 / 偏暗时切换文字配色，只在跨过阈值时才变
    @State private var contentScheme: ColorScheme?
    @EnvironmentObject private var ruleStore: RuleStore
    @Environment(\.colorScheme) private var systemScheme

    private let grid = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

    /// 背景层回报配色之前（第一帧），先按第一张海报的颜色决定文字配色
    private var firstHeroScheme: ColorScheme? {
        model.hero.first.flatMap { PosterTints.shared.tint(for: $0.id)?.colorScheme }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HeroCarousel(items: model.hero, scroll: scroll)

                if ruleStore.entries.isEmpty {
                    NoRulesBanner()
                        .padding(.horizontal)
                }

                if let error = model.error {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                if !model.today.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "今日放送", subtitle: BangumiAPI.weekdayNames[BangumiAPI.todayIndex])
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(model.today) { subject in
                                    NavigationLink(destination: AppDestination(subject)) {
                                        PosterCard(subject: subject, width: 116)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .hideScrollIndicators()
                    }
                }

                if !model.trending.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "热门番剧")
                        LazyVGrid(columns: grid, spacing: 18) {
                            ForEach(model.trending) { subject in
                                NavigationLink(destination: AppDestination(subject)) {
                                    PosterCard(subject: subject)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background {
            HomeBackground(hero: model.hero, scroll: scroll) { contentScheme = $0 }
        }
        .environment(\.colorScheme, contentScheme ?? firstHeroScheme ?? systemScheme)
        .ignoresSafeArea(edges: .top)
        .navigationBarHiddenCompat()
        .refreshable { await model.load(force: true) }
        .task { await model.load() }
    }
}

/// 整页背景：跟着轮播滑动实时在相邻两张海报的主色之间混色。
/// 海报底部是渐隐到透明的，露出来的就是这一层，所以不会有分界线
struct HomeBackground: View {
    let hero: [BangumiSubject]
    @ObservedObject var scroll: HeroScrollState
    @ObservedObject private var tints = PosterTints.shared
    let onSchemeChange: (ColorScheme?) -> Void

    private var tint: PosterTint? {
        let tints = HeroCarousel.pages(of: hero).map { self.tints.tint(for: $0.id) }
        guard !tints.isEmpty else { return nil }
        let position = min(max(scroll.position, 0), Double(tints.count - 1))
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, tints.count - 1)
        let fraction = position - Double(lower)
        switch (tints[lower], tints[upper]) {
        case let (a?, b?): return a.mixed(with: b, fraction)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    var body: some View {
        let tint = tint
        (tint?.color ?? Color(uiColor: .systemBackground))
            .ignoresSafeArea()
            .onChangeCompat(of: tint?.colorScheme, initial: true) { _, scheme in
                onSchemeChange(scheme)
            }
    }
}

struct NoRulesBanner: View {
    var title = "还没有安装片源规则"
    var message = "点这里从规则仓库添加，之后才能搜片播放"

    var body: some View {
        NavigationLink {
            RulesView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .glass(interactive: true, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 首页随机海报轮播

struct HeroCarousel: View {
    let items: [BangumiSubject]
    let scroll: HeroScrollState
    @State private var current: Int?
    @State private var userInteracting = false

    /// 末尾接一张第一页的副本：从最后一页往后翻到副本，再无动画跳回第一页，
    /// 看起来是无限循环，背景也只在相邻两张之间过渡，不会倒着把所有颜色扫一遍
    static func pages(of items: [BangumiSubject]) -> [BangumiSubject] {
        items.count > 1 ? items + [items[0]] : items
    }

    private var pages: [BangumiSubject] { Self.pages(of: items) }

    var body: some View {
        Group {
            if items.isEmpty {
                // 冷启动且没有缓存时：和整页同一个底色，只有一个加载指示
                Color.clear
                    .overlay { ProgressView() }
            } else {
                Group {
                    if #available(iOS 18, *) {
                        scrollingPages
                    } else {
                        pagedTabs
                    }
                }
                .overlay(alignment: .bottom) {
                    let active = (current ?? 0) % items.count
                    HStack(spacing: 7) {
                        ForEach(items.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == active ? Color.primary : Color.primary.opacity(0.3))
                                .frame(width: index == active ? 16 : 6, height: 6)
                        }
                    }
                    .padding(.bottom, 12)
                    .animation(.snappyCompat, value: active)
                }
                .task(id: items.map(\.id)) {
                    jump(to: 0)
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        guard !Task.isCancelled, !userInteracting, items.count > 1 else { continue }
                        withAnimation(.smoothCompat(duration: 0.6)) {
                            current = min((current ?? 0) + 1, pages.count - 1)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        // 海报占屏幕高度的大约三分之二，和竖版海报的比例接近
        .containerHeight(fraction: 0.68, max: 760)
    }

    /// iOS 18 起：分页滚动，滑动时实时回报位置，背景跟着手指混色
    @available(iOS 18, *)
    private var scrollingPages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, subject in
                    NavigationLink(destination: AppDestination(subject)) {
                        HeroPage(subject: subject)
                    }
                    .buttonStyle(.plain)
                    .containerRelativeFrame(.horizontal)
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .hideScrollIndicators()
        .scrollPosition(id: $current)
        .onScrollGeometryChange(for: Double.self) { geometry in
            let width = geometry.containerSize.width
            return width > 0 ? geometry.contentOffset.x / width : 0
        } action: { _, value in
            scroll.position = value
        }
        .onScrollPhaseChange { _, phase in
            userInteracting = phase == .interacting || phase == .tracking
            if phase == .idle { wrapIfNeeded() }
        }
    }

    /// iOS 15 – 17：分页的 TabView，翻页后背景渐变到新的颜色
    private var pagedTabs: some View {
        TabView(selection: Binding(get: { current ?? 0 }, set: { current = $0 })) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, subject in
                NavigationLink(destination: AppDestination(subject)) {
                    HeroPage(subject: subject)
                }
                .buttonStyle(.plain)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: current) { value in
            withAnimation(.easeInOut(duration: 0.5)) { scroll.position = Double(value ?? 0) }
            guard items.count > 1, value == pages.count - 1 else { return }
            // 翻到末尾的第一页副本：等翻页动画结束再无动画跳回第一页
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                if current == pages.count - 1 { jump(to: 0) }
            }
        }
    }

    private func wrapIfNeeded() {
        guard items.count > 1, current == pages.count - 1 else { return }
        jump(to: 0)
    }

    private func jump(to index: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            current = index
            scroll.position = Double(index)
        }
    }
}

/// 一页轮播：整幅海报，底部渐隐成透明（露出整页背景），信息居中叠在上面
struct HeroPage: View {
    let subject: BangumiSubject
    @ObservedObject private var tints = PosterTints.shared
    @Environment(\.colorScheme) private var scheme

    private var meta: String {
        var parts: [String] = []
        if subject.airDate.count >= 4 { parts.append(String(subject.airDate.prefix(4))) }
        parts.append(contentsOf: subject.tags.prefix(3))
        if subject.episodes > 0 { parts.append("\(subject.episodes) 集") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .overlay {
                    PosterImage(url: subject.image, fallback: subject.thumb, showsPlaceholder: false)
                        .mask(PosterFadeMask())
                }
                .clipped()

            VStack(spacing: 8) {
                Text(subject.title)
                    .font(.system(size: 32, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !subject.summary.isEmpty {
                    Text(subject.summary.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let score = subject.scoreText {
                    HStack(spacing: 10) {
                        Label(score, systemImage: "star.fill")
                            .foregroundStyle(.orange)
                        if subject.rank > 0 {
                            Text("排名 #\(subject.rank)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)
            .padding(.horizontal, 28)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // 文字颜色跟这一页自己的海报色走
        .environment(\.colorScheme, tints.tint(for: subject.id)?.colorScheme ?? scheme)
    }
}
