import SwiftUI

/// 小说首页：继续阅读、书架、最近读过、发现（书源自带的分类）
struct NovelHomeView: View {
    @ObservedObject private var watchLibrary = WatchLibrary.shared
    @ObservedObject private var tints = PosterTints.shared
    @ObservedObject private var store = BookSourceStore.shared
    @ObservedObject private var library = NovelLibrary.shared
    @Environment(\.colorScheme) private var systemScheme

    private let grid = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 14)]

    private var novelRecords: [WatchRecord] { watchLibrary.records.filter(\.isNovel) }
    private var shelf: [FavoriteItem] { watchLibrary.favorites.filter { $0.subject.isNovel } }
    private var hero: WatchRecord? { novelRecords.first }
    private var heroTint: PosterTint? { hero.flatMap { tints.tint(for: $0.subjectID) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Color.clear.frame(height: 44)

                if store.isLoaded, store.sources.isEmpty {
                    NoBookSourcesBanner()
                        .padding(.horizontal)
                }

                if let hero {
                    continueCard(hero)
                        .padding(.horizontal)
                }

                shelfSection

                let recent = novelRecords.dropFirst().filter { record in !shelf.contains { $0.subjectID == record.subjectID } }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "最近读过")
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(Array(recent.prefix(12))) { record in
                                    NavigationLink(destination: AppDestination(record.subject)) {
                                        BookCard(book: book(for: record), subtitle: record.episodeName, progress: progress(record))
                                            .frame(width: 96)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .hideScrollIndicators()
                    }
                }

                NovelExploreSection()
            }
            .padding(.bottom, 24)
        }
        .background {
            (heroTint?.color ?? Color(uiColor: .systemBackground)).ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: heroTint)
        }
        .environment(\.colorScheme, heroTint?.colorScheme ?? systemScheme)
        .navigationBarHiddenCompat()
        .task { await store.load() }
        .task(id: hero?.subjectID) {
            if let hero, !hero.image.isEmpty { await PosterTints.shared.ensure(hero.subject) }
        }
    }

    // MARK: 继续阅读

    private func continueCard(_ record: WatchRecord) -> some View {
        NavigationLink(destination: AppDestination(record.subject)) {
            HStack(spacing: 16) {
                BookCover(url: record.image, title: record.title, author: record.name)
                    .frame(width: 86)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text("继续阅读")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(record.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    Text(record.episodeName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ProgressView(value: progress(record) ?? 0)
                        .tint(.primary.opacity(0.7))
                    Text(progressText(record))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .glass(interactive: true, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 书架

    @ViewBuilder
    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "书架", subtitle: shelf.isEmpty ? nil : "\(shelf.count) 本")
            if shelf.isEmpty {
                Text("在书籍详情页点 \(Image(systemName: "books.vertical")) 把书放上书架")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                LazyVGrid(columns: grid, spacing: 18) {
                    ForEach(shelf) { item in
                        let record = novelRecords.first { $0.subjectID == item.subjectID }
                        NavigationLink(destination: AppDestination(item.subject)) {
                            BookCard(
                                book: book(for: item),
                                subtitle: record.map { "读到 " + $0.episodeName } ?? "未读",
                                progress: record.flatMap(progress)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("移出书架", icon: "books.vertical", role: .destructive) {
                                removeFromShelf(item)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func removeFromShelf(_ item: FavoriteItem) {
        watchLibrary.removeFavorite(item.subjectID)
    }

    private func book(for item: FavoriteItem) -> NovelBook {
        library.book(for: item.subjectID) ?? NovelBook(name: item.nameCN, author: item.name, coverUrl: item.image)
    }

    private func book(for record: WatchRecord) -> NovelBook {
        library.book(for: record.subjectID) ?? NovelBook(name: record.title, author: record.name, coverUrl: record.image)
    }

    private func progress(_ record: WatchRecord) -> Double? {
        let total = record.roadIndex
        guard total > 0 else { return nil }
        return min((Double(record.episodeIndex) + record.progress) / Double(total), 1)
    }

    private func progressText(_ record: WatchRecord) -> String {
        guard record.roadIndex > 0 else { return "第 \(record.episodeIndex + 1) 章" }
        let left = record.roadIndex - record.episodeIndex - 1
        let percent = String(format: "%.1f%%", (progress(record) ?? 0) * 100)
        return left > 0 ? "已读 \(percent) · 还有 \(left) 章" : "已读 \(percent)"
    }
}

struct NoBookSourcesBanner: View {
    var body: some View {
        NavigationLink {
            BookSourcesView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("还没有书源")
                        .font(.headline)
                    Text("导入「阅读」格式的书源后才能搜书、看书")
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

// MARK: - 发现

@MainActor
final class NovelExploreModel: ObservableObject {
    @Published var kinds: [ExploreKind] = []
    @Published var books: [NovelBook] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published private var page = 0
    @Published private var exhausted = false
    @Published private var generation = 0
    @Published private(set) var source: BookSource?
    @Published private(set) var kind: ExploreKind?

    func select(source: BookSource) async {
        guard self.source?.id != source.id || kinds.isEmpty else { return }
        self.source = source
        generation += 1
        let current = generation
        kinds = []
        books = []
        kind = nil
        error = nil
        let list = (try? await BookEngine.run { env in WebBook.exploreKinds(source, env: env) }) ?? []
        guard current == generation else { return }
        kinds = list.filter { $0.url != nil }
        if let first = kinds.first {
            await select(kind: first)
        } else {
            error = "这个书源的发现页没有分类"
        }
    }

    func select(kind: ExploreKind) async {
        self.kind = kind
        generation += 1
        books = []
        page = 0
        exhausted = false
        error = nil
        isLoading = false
        await loadMore()
    }

    func loadMore() async {
        guard let source, let url = kind?.url, !isLoading, !exhausted else { return }
        let current = generation
        isLoading = true
        let next = page + 1
        do {
            let result = try await BookEngine.run { env in
                try WebBook.explore(source, url: url, page: next, env: env)
            }
            guard current == generation else { return }
            page = next
            let existing = Set(books.map(\.bookUrl))
            let fresh = result.filter { !existing.contains($0.bookUrl) }
            books += fresh
            // 地址里没有页码变量时只有一页
            if fresh.isEmpty || !url.contains("page") { exhausted = true }
        } catch {
            guard current == generation else { return }
            self.error = books.isEmpty ? error.localizedDescription : nil
            exhausted = true
        }
        isLoading = false
    }
}

struct NovelExploreSection: View {
    @ObservedObject private var store = BookSourceStore.shared
    @StateObject private var model = NovelExploreModel()
    @AppStorage("novelExploreSource") private var sourceID = ""

    private let grid = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 14)]

    private var sources: [BookSource] { store.explorable }
    private var selected: BookSource? { sources.first { $0.id == sourceID } ?? sources.first }

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("发现")
                        .font(.title2.weight(.bold))
                    Spacer()
                    Menu {
                        Picker("书源", selection: Binding(get: { selected?.id ?? "" }, set: { sourceID = $0 })) {
                            ForEach(sources) { source in
                                Text(source.bookSourceName).tag(source.id)
                            }
                        }
                    } label: {
                        Label(selected?.bookSourceName ?? "书源", systemImage: "chevron.up.chevron.down")
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    .glassButtonStyle()
                    .controlSize(.small)
                }
                .padding(.horizontal)

                if !model.kinds.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(model.kinds) { kind in
                                TagChip(title: kind.title, selected: kind == model.kind) {
                                    Task { await model.select(kind: kind) }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .hideScrollIndicators()
                }

                LazyVGrid(columns: grid, spacing: 18) {
                    ForEach(model.books) { book in
                        let subject = NovelLibrary.shared.prepare(book, candidates: [])
                        NavigationLink(destination: AppDestination(subject)) {
                            BookCard(book: book, subtitle: book.author)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if book.id == model.books.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                    }
                }
                .padding(.horizontal)

                Group {
                    if model.isLoading {
                        ProgressView()
                    } else if let error = model.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .task(id: selected?.id) {
                if let selected { await model.select(source: selected) }
            }
        }
    }
}
