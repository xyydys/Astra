import SwiftUI
import SwiftData

// MARK: - 搜索

/// 搜索页跟随首页的模式：番剧搜 Bangumi，影视在采集站里聚合搜索
struct SearchView: View {
    @AppStorage(AppSettings.contentModeKey) private var mode: ContentMode = .anime

    var body: some View {
        switch mode {
        case .anime: AnimeSearchView()
        case .video: VideoSearchView()
        case .comic: ComicSearchView()
        case .novel: NovelSearchView()
        case .music: MusicSearchView()
        }
    }
}

private struct AnimeSearchView: View {
    private let grid = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

    @State private var query = ""
    @State private var results: [BangumiSubject] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchedQuery = ""

    var body: some View {
        // 和首页一样按海报网格顺次排列
        ScrollView {
            LazyVGrid(columns: grid, spacing: 18) {
                ForEach(results) { subject in
                    NavigationLink(value: subject) {
                        PosterCard(subject: subject, subtitle: subject.briefInfo)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if isLoading {
                ProgressView()
            } else if let error {
                ContentUnavailableView("搜索失败", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if results.isEmpty && !searchedQuery.isEmpty {
                ContentUnavailableView.search(text: searchedQuery)
            } else if results.isEmpty {
                ContentUnavailableView("搜索番剧", systemImage: "sparkle.magnifyingglass", description: Text("番剧信息来自 Bangumi 番组计划"))
            }
        }
        .navigationTitle("搜索")
        .searchTab(text: $query, prompt: "番剧名称")
        .onSubmit(of: .search) {
            Task { await run() }
        }
    }

    private func run() async {
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        isLoading = true
        error = nil
        searchedQuery = word
        do {
            results = try await BangumiAPI.search(word)
            PosterTints.shared.prefetch(results)
        } catch {
            self.error = error.localizedDescription
            results = []
        }
        isLoading = false
    }
}

// MARK: - 影视搜索

/// 在所有启用的采集站里并发搜索，同名同年的结果合并成一张卡片（LibreTV 的跨源聚合）
private struct VideoSearchView: View {
    struct ResultGroup: Identifiable {
        let key: String
        var items: [CMSItem]
        /// 提供这个结果的片源里，优先级最高的那个的位置
        var priority: Int

        var id: String { key }
        var first: CMSItem { items[0] }

        var subject: BangumiSubject {
            let cover = items.first { !$0.pic.isEmpty }?.pic ?? ""
            return .video(
                id: BangumiSubject.videoID(title: first.name, year: first.year),
                title: first.name, image: cover, thumb: cover, year: first.year,
                tags: [first.typeName, first.area].filter { !$0.isEmpty }
            )
        }

        var subtitle: String {
            ["\(items.count) 个片源", first.year, first.typeName].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @Environment(RuleStore.self) private var ruleStore
    @State private var query = ""
    @State private var groups: [ResultGroup] = []
    @State private var pending = 0
    @State private var searchedQuery = ""
    @State private var searchTask: Task<Void, Never>?

    private let grid = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

    var body: some View {
        ScrollView {
            if pending > 0, !groups.isEmpty {
                Label("还在搜索 \(pending) 个采集站…", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            LazyVGrid(columns: grid, spacing: 18) {
                ForEach(groups) { group in
                    NavigationLink(value: group.subject) {
                        PosterCard(subject: group.subject, subtitle: group.subtitle)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if ruleStore.enabledCMS.isEmpty {
                ContentUnavailableView {
                    Label("还没有添加采集站", systemImage: "server.rack")
                } description: {
                    Text("影视模式在采集站里搜索。到「我的 → 规则管理」添加采集站或导入订阅")
                }
            } else if groups.isEmpty, pending > 0 {
                ProgressView("正在搜索 \(pending) 个采集站…")
            } else if groups.isEmpty, !searchedQuery.isEmpty {
                ContentUnavailableView.search(text: searchedQuery)
            } else if groups.isEmpty {
                ContentUnavailableView("搜索影视", systemImage: "film", description: Text("在已启用的 \(ruleStore.enabledCMS.count) 个采集站里搜索电影、剧集、综艺和动漫"))
            }
        }
        .navigationTitle("搜索影视")
        .searchTab(text: $query, prompt: "电影、剧集名称")
        .onSubmit(of: .search) { run() }
    }

    private func run() {
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        searchTask?.cancel()
        searchedQuery = word
        groups = []
        let sources = ruleStore.enabledCMS
        pending = sources.count
        searchTask = Task {
            await withTaskGroup(of: (Int, [CMSItem]).self) { taskGroup in
                for (index, source) in sources.enumerated() {
                    taskGroup.addTask {
                        (index, (try? await CMSSearchCache.shared.search(source, keyword: word)) ?? [])
                    }
                }
                for await (priority, items) in taskGroup {
                    guard !Task.isCancelled else { return }
                    merge(items, priority: priority, keyword: word)
                    pending -= 1
                }
            }
        }
    }

    private func merge(_ items: [CMSItem], priority: Int, keyword: String) {
        for item in items {
            let key = CMSClient.normalizeTitle(item.name) + "|" + item.year
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].items.append(item)
                groups[index].priority = min(groups[index].priority, priority)
            } else {
                groups.append(ResultGroup(key: key, items: [item], priority: priority))
            }
        }
        // 片名和搜索词完全一致的排前面，再按片源优先级、片源数量
        let target = CMSClient.normalizeTitle(keyword)
        groups.sort { a, b in
            let ea = CMSClient.normalizeTitle(a.first.name) == target
            let eb = CMSClient.normalizeTitle(b.first.name) == target
            if ea != eb { return ea }
            if a.priority != b.priority { return a.priority < b.priority }
            return a.items.count > b.items.count
        }
        PosterTints.shared.prefetch(groups.prefix(30).map(\.subject))
    }
}

// MARK: - 收藏

struct FavoritesView: View {
    @Query(sort: \FavoriteItem.addedAt, order: .reverse) private var favorites: [FavoriteItem]
    @Environment(\.modelContext) private var modelContext

    private let grid = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: grid, spacing: 18) {
                ForEach(favorites) { item in
                    NavigationLink(value: item.subject) {
                        PosterCard(subject: item.subject)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("取消收藏", systemImage: "heart.slash", role: .destructive) {
                            modelContext.delete(item)
                            try? modelContext.save()
                        }
                    }
                }
            }
            .padding()
        }
        .overlay {
            if favorites.isEmpty {
                ContentUnavailableView("还没有收藏", systemImage: "heart", description: Text("在番剧详情页点 ♡ 收藏"))
            }
        }
        .navigationTitle("收藏")
        .task(id: favorites.map(\.subjectID)) {
            PosterTints.shared.prefetch(favorites.map(\.subject))
        }
    }
}

// MARK: - 历史

struct HistoryView: View {
    @Query(sort: \WatchRecord.updatedAt, order: .reverse) private var records: [WatchRecord]
    @Environment(\.modelContext) private var modelContext
    @State private var confirmClear = false

    var body: some View {
        List {
            ForEach(records) { record in
                // 漫画记录打开详情页（那里有「继续阅读」），影视 / 番剧直接续播
                if record.isComic || record.isNovel {
                    NavigationLink(value: record.subject) {
                        HistoryRow(record: record)
                    }
                } else {
                    NavigationLink(value: record.playRequest) {
                        HistoryRow(record: record)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { modelContext.delete(records[index]) }
                try? modelContext.save()
            }
        }
        .listStyle(.plain)
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("还没有观看记录", systemImage: "clock", description: Text("看过的番剧、影视和漫画会出现在这里，点一下接着看"))
            }
        }
        .navigationTitle("历史")
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("清空", systemImage: "trash") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("清空全部观看记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                for record in records { modelContext.delete(record) }
                try? modelContext.save()
            }
        }
    }
}

private struct HistoryRow: View {
    let record: WatchRecord

    var body: some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 64, height: 90)
                .overlay { PosterImage(url: record.image) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(record.episodeName) · \(record.isNovel ? record.sourceTitle : record.ruleName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if record.duration > 0 {
                    ProgressView(value: record.progress)
                        .tint(.pink)
                    Text(record.isNovel
                        ? "第 \(record.episodeIndex + 1) / \(max(record.roadIndex, record.episodeIndex + 1)) 章"
                        : record.isComic
                        ? "第 \(Int(record.position) + 1) / \(Int(record.duration)) 页"
                        : "\(record.position.clockText) / \(record.duration.clockText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(record.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
