import SwiftData
import SwiftUI

/// 小说封面：没有封面或加载失败时画一本书
struct BookCover: View {
    let url: String
    let title: String
    var author: String = ""
    var cornerRadius: CGFloat = 10
    @State private var image: UIImage?
    @State private var failed = false

    private var cleanURL: String { NovelCover.url(url) }

    var body: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .task(id: cleanURL) {
                guard !cleanURL.isEmpty else { return }
                if let cached = ImageMemory.shared.image(cleanURL) {
                    image = cached
                    return
                }
                if let loaded = await ImageCache.shared.load(cleanURL), !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                }
            }
    }

    /// 根据书名生成的封面：柔和的渐变 + 竖排书名
    private var placeholder: some View {
        let hue = Double(abs(title.hashValue % 360)) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.32, brightness: 0.72), Color(hue: hue, saturation: 0.45, brightness: 0.45)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                if !author.isEmpty {
                    Text(author)
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.8)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(10)
        }
    }
}

/// 书架 / 搜索结果里的一本书
struct BookCard: View {
    let book: NovelBook
    var subtitle: String?
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BookCover(url: book.coverUrl, title: book.name, author: book.author)
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.white.opacity(0.9))
                                .frame(width: max(proxy.size.width * progress, 4), height: 3)
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text(book.name)
                .font(.footnote.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, -3)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 详情

struct NovelDetailView: View {
    let subjectID: Int
    @State private var book: NovelBook?
    @State private var chapters: [NovelChapter] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var summaryExpanded = false
    @State private var readRequest: NovelReadRequest?
    @State private var showTOC = false
    @State private var showSources = false
    @State private var loadedOrigin: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var systemScheme
    @Query private var favorites: [FavoriteItem]
    @Query private var records: [WatchRecord]

    init(subject: BangumiSubject) {
        subjectID = subject.id
        _book = State(initialValue: NovelLibrary.shared.book(for: subject.id))
        let sid = subject.id
        _favorites = Query(filter: #Predicate<FavoriteItem> { $0.subjectID == sid })
        _records = Query(filter: #Predicate<WatchRecord> { $0.subjectID == sid })
    }

    private var subject: BangumiSubject? { book.map { BangumiSubject.novel($0) } }
    private var tint: PosterTint? { PosterTints.shared.tint(for: subjectID) }
    private var isFavorite: Bool { !favorites.isEmpty }
    private var record: WatchRecord? { records.first { $0.isNovel } }

    var body: some View {
        Group {
            if let book {
                content(book)
            } else {
                ContentUnavailableView("找不到这本书", systemImage: "book.closed",
                                       description: Text("书源信息丢失了，可以到搜索里重新找这本书"))
            }
        }
        .background {
            (tint?.color ?? Color(uiColor: .systemBackground)).ignoresSafeArea()
        }
        .environment(\.colorScheme, tint?.colorScheme ?? systemScheme)
        .navigationTitle(book?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .task {
            if let subject, !subject.image.isEmpty { await PosterTints.shared.ensure(subject) }
        }
        .task { await load() }
        .fullScreenCover(item: $readRequest) { request in
            NovelReaderView(request: request)
        }
        .sheet(isPresented: $showTOC) {
            NovelTOCSheet(chapters: chapters, current: currentChapterIndex) { index in
                showTOC = false
                open(chapter: index, offset: 0)
            }
        }
        .sheet(isPresented: $showSources) {
            if let book {
                NovelSourceSheet(subjectID: subjectID, book: book) { picked in
                    showSources = false
                    switchSource(picked)
                }
            }
        }
    }

    private func content(_ book: NovelBook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(book)
                actions
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                tocRow(book)
                if !book.intro.isEmpty { summary(book.intro) }
                if !book.kinds.isEmpty { tags(book.kinds) }
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: 头部

    private func header(_ book: NovelBook) -> some View {
        VStack(spacing: 14) {
            BookCover(url: book.coverUrl, title: book.name, author: book.author, cornerRadius: 12)
                .frame(width: 138)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                .padding(.top, 16)
            VStack(spacing: 6) {
                Text(book.name)
                    .font(.system(size: 24, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text([book.wordCount, chapters.isEmpty ? "" : "\(chapters.count) 章", book.originName]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 按钮

    private var currentChapterIndex: Int {
        guard let record else { return 0 }
        if chapters.indices.contains(record.episodeIndex), chapters[record.episodeIndex].title == record.episodeName {
            return record.episodeIndex
        }
        // 换过源：按章节名找回位置
        if let match = chapters.firstIndex(where: { $0.title == record.episodeName }) { return match }
        return min(max(record.episodeIndex, 0), max(chapters.count - 1, 0))
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    if let record {
                        let index = currentChapterIndex
                        open(chapter: index, offset: index == record.episodeIndex || chapters[safe: index]?.title == record.episodeName ? Int(record.position) : 0)
                    } else {
                        open(chapter: 0, offset: 0)
                    }
                } label: {
                    Group {
                        if let record, !chapters.isEmpty {
                            Label("继续 \(record.episodeName)", systemImage: "book.fill")
                        } else {
                            Label(chapters.isEmpty ? (isLoading ? "正在获取目录…" : "开始阅读") : "开始阅读", systemImage: "book.fill")
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(chapters.isEmpty)

                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "books.vertical.fill" : "books.vertical")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .sensoryFeedback(.selection, trigger: isFavorite)

                Button {
                    showSources = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding(.horizontal)
    }

    // MARK: 目录 / 简介

    private func tocRow(_ book: NovelBook) -> some View {
        Button {
            showTOC = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(chapters.isEmpty ? "目录" : "目录 · 共 \(chapters.count) 章")
                        .font(.headline)
                    let latest = chapters.last?.title ?? book.latestChapterTitle
                    if !latest.isEmpty {
                        Text("最新：\(latest)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(chapters.isEmpty)
        .padding(.horizontal)
    }

    private func summary(_ intro: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("简介")
                .font(.headline)
            Text(intro.replacingOccurrences(of: "\u{3000}", with: ""))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .lineLimit(summaryExpanded ? nil : 5)
            Button(summaryExpanded ? "收起" : "展开") {
                withAnimation(.snappy) { summaryExpanded.toggle() }
            }
            .font(.callout.weight(.medium))
        }
        .padding(.horizontal)
    }

    private func tags(_ kinds: [String]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(kinds, id: \.self) { kind in
                Text(kind)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal)
    }

    // MARK: 数据

    private func load(force: Bool = false) async {
        guard let current = book else { return }
        await BookSourceStore.shared.load()
        if chapters.isEmpty, let cached = NovelLibrary.cachedChapters(id: subjectID, origin: current.origin) {
            chapters = cached
        }
        if !force, loadedOrigin == current.origin { return }
        guard let source = BookSourceStore.shared.source(for: current.origin) else {
            error = "书源「\(current.originName)」已删除或停用，点右上角的换源按钮换一个"
            return
        }
        isLoading = true
        error = nil
        do {
            let result = try await BookEngine.run { env -> (NovelBook, [NovelChapter]) in
                let ruleBook = RuleBook(current)
                let info = try WebBook.bookInfo(source, book: current, env: env, ruleBook: ruleBook)
                let list = try WebBook.chapters(source, book: info.book, tocHTML: info.tocHTML, env: env, ruleBook: ruleBook)
                return (ruleBook.book, list)
            }
            guard book?.origin == current.origin else { return }
            var updated = result.0
            // 详情页没有书名作者时沿用搜索结果
            if updated.name.isEmpty { updated.name = current.name }
            if updated.author.isEmpty { updated.author = current.author }
            book = updated
            chapters = result.1
            loadedOrigin = current.origin
            NovelLibrary.shared.update(updated, for: subjectID)
            NovelLibrary.saveChapters(result.1, id: subjectID, origin: current.origin)
        } catch {
            if book?.origin == current.origin {
                self.error = chapters.isEmpty ? "获取目录失败：\(error.localizedDescription)" : "更新目录失败，显示的是上次的目录"
            }
        }
        isLoading = false
    }

    private func switchSource(_ picked: NovelBook) {
        var next = picked
        if next.coverUrl.isEmpty { next.coverUrl = book?.coverUrl ?? "" }
        if next.intro.isEmpty { next.intro = book?.intro ?? "" }
        book = next
        chapters = []
        loadedOrigin = nil
        NovelLibrary.shared.update(next, for: subjectID)
        Task { await load(force: true) }
    }

    private func open(chapter: Int, offset: Int) {
        guard let book, chapters.indices.contains(chapter) else { return }
        NovelLibrary.shared.update(book, for: subjectID)
        readRequest = NovelReadRequest(subjectID: subjectID, book: book, chapters: chapters, chapterIndex: chapter, offset: offset)
    }

    private func toggleFavorite() {
        guard let subject else { return }
        if let existing = favorites.first {
            modelContext.delete(existing)
        } else {
            if let book { NovelLibrary.shared.update(book, for: subjectID) }
            modelContext.insert(FavoriteItem(subject: subject))
        }
        try? modelContext.save()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 换源

struct NovelSourceSheet: View {
    let subjectID: Int
    let book: NovelBook
    let onSelect: (NovelBook) -> Void
    @State private var candidates: [NovelBook] = []
    @State private var searching = false
    @State private var progress = (done: 0, total: 0)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates, id: \.origin) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.originName)
                                        .font(.body.weight(item.origin == book.origin ? .semibold : .regular))
                                    if !item.latestChapterTitle.isEmpty {
                                        Text(item.latestChapterTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if item.origin == book.origin {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } footer: {
                    if searching {
                        Text("正在搜索 \(progress.done)/\(progress.total) 个书源…")
                    } else if candidates.count <= 1 {
                        Text("点右上角在所有书源里搜索这本书")
                    }
                }
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if searching {
                        ProgressView()
                    } else {
                        Button("搜索全部书源", systemImage: "magnifyingglass") {
                            Task { await searchAll() }
                        }
                    }
                }
            }
        }
        .onAppear {
            var list = [book]
            for item in NovelLibrary.shared.otherSources(for: subjectID) where !list.contains(where: { $0.origin == item.origin }) {
                list.append(item)
            }
            candidates = list
        }
    }

    private func searchAll() async {
        await BookSourceStore.shared.load()
        let sources = BookSourceStore.shared.searchable.filter { source in !candidates.contains { $0.origin == source.bookSourceUrl } }
        searching = true
        progress = (0, sources.count)
        let name = book.name, author = book.author
        await withTaskGroup(of: [NovelBook]?.self) { group in
            var index = 0
            while index < min(12, sources.count) {
                let source = sources[index]
                index += 1
                group.addTask { await NovelSearchModel.searchOne(source, name) }
            }
            while let result = await group.next() {
                progress.done += 1
                let matches = (result ?? []).filter { $0.name == name && (author.isEmpty || $0.author.isEmpty || $0.author == author) }
                if let first = matches.first, !candidates.contains(where: { $0.origin == first.origin }) {
                    candidates.append(first)
                    NovelLibrary.shared.addCandidates([first], for: subjectID)
                }
                if index < sources.count {
                    let source = sources[index]
                    index += 1
                    group.addTask { await NovelSearchModel.searchOne(source, name) }
                }
            }
        }
        searching = false
    }
}
