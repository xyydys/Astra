import SwiftUI

/// 打开阅读器需要的信息
struct ComicReadRequest: Identifiable, Hashable {
    let subject: BangumiSubject
    let chapters: [JMChapter]
    let chapterIndex: Int
    let startPage: Int

    var id: String { "\(subject.id)-\(chapterIndex)-\(startPage)" }
}

/// 漫画详情：封面取色背景、章节、标签、相关推荐
struct ComicDetailView: View {
    @State private var subject: BangumiSubject
    @State private var album: JMAlbum?
    @State private var error: String?
    @State private var readRequest: ComicReadRequest?
    @State private var summaryExpanded = false
    @ObservedObject private var library = WatchLibrary.shared
    @ObservedObject private var tints = PosterTints.shared
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage("episodeListReversed") private var chaptersReversed = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10)]

    init(subject: BangumiSubject) {
        _subject = State(initialValue: subject)
    }

    private var tint: PosterTint? { tints.tint(for: subject.id) }
    private var isFavorite: Bool { library.isFavorite(subject.id) }
    private var record: WatchRecord? { library.record(subject.id).flatMap { $0.isComic ? $0 : nil } }
    private var chapters: [JMChapter] { album?.chapters ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actions
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                if chapters.count > 1 { chapterGrid }
                if let album {
                    if !subject.summary.isEmpty { summary }
                    tagSection(album)
                    if !album.related.isEmpty { relatedRow(album.related) }
                } else if error == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
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
        .task { await load() }
        .fullScreenCover(item: $readRequest) { request in
            ComicReaderView(request: request)
        }
    }

    // MARK: 头部

    private var meta: String {
        var parts: [String] = []
        if let album {
            if !album.updated.isEmpty { parts.append(album.updated) }
            if chapters.count > 1 { parts.append("\(chapters.count) 话") }
            if !album.likes.isEmpty { parts.append("♥ \(album.likes)") }
            if !album.views.isEmpty { parts.append("\(album.views) 次浏览") }
        }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        Color.clear
            .containerHeight(fraction: 0.62, max: 680)
            .frame(maxWidth: .infinity)
            .overlay {
                PosterImage(url: subject.image, fallback: subject.thumb, showsPlaceholder: false)
                    .mask(PosterFadeMask())
            }
            .clipped()
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    Text(subject.title)
                        .font(.system(size: 26, weight: .heavy))
                        .lineLimit(4)
                        .minimumScaleFactor(0.6)
                    if !subject.name.isEmpty {
                        Text(subject.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let id = subject.jmID {
                        Text(([("JM" + id)] + (meta.isEmpty ? [] : [meta])).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                if let record, !chapters.isEmpty {
                    Button {
                        let index = min(max(record.episodeIndex, 0), chapters.count - 1)
                        open(chapter: index, page: index == record.episodeIndex ? Int(record.position) : 0)
                    } label: {
                        Label("继续 \(record.episodeName) · 第 \(Int(record.position) + 1) 页", systemImage: "book.fill")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .glassProminentButtonStyle()
                    .controlSize(.large)
                } else {
                    Button {
                        open(chapter: 0, page: 0)
                    } label: {
                        Label(album == nil ? "正在加载…" : "开始阅读", systemImage: "book.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .glassProminentButtonStyle()
                    .controlSize(.large)
                    .disabled(chapters.isEmpty)
                }

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

    // MARK: 章节

    private var chapterGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("章节 · 共 \(chapters.count) 话")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.snappyCompat) { chaptersReversed.toggle() }
                } label: {
                    Label(chaptersReversed ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                }
                .glassButtonStyle()
                .controlSize(.small)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(chaptersReversed ? Array(chapters.indices.reversed()) : Array(chapters.indices), id: \.self) { index in
                    let isCurrent = record?.episodeIndex == index
                    Button {
                        open(chapter: index, page: isCurrent ? Int(record?.position ?? 0) : 0)
                    } label: {
                        Text(chapters[index].title)
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
        .padding(.horizontal)
    }

    // MARK: 简介 / 标签 / 推荐

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subject.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(summaryExpanded ? nil : 4)
            Button(summaryExpanded ? "收起" : "展开") {
                withAnimation(.snappyCompat) { summaryExpanded.toggle() }
            }
            .font(.callout.weight(.medium))
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func tagSection(_ album: JMAlbum) -> some View {
        let groups: [(String, [String])] = [
            ("作者", album.comic.author.isEmpty ? [] : album.comic.author.components(separatedBy: " / ")),
            ("标签", album.comic.tags),
            ("作品", album.works),
            ("角色", album.actors),
        ].filter { !$0.1.isEmpty }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups.indices, id: \.self) { index in
                    let group = groups[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.0)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TagFlow(spacing: 8) {
                            ForEach(group.1, id: \.self) { tag in
                                NavigationLink(destination: AppDestination(ComicTagRoute(keyword: tag))) {
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func relatedRow(_ comics: [JMComic]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "相关推荐")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(comics) { comic in
                        NavigationLink(destination: AppDestination(comic.subject)) {
                            PosterCard(subject: comic.subject, width: 104)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .hideScrollIndicators()
        }
    }

    // MARK: 数据

    private func load() async {
        guard album == nil, let id = subject.jmID else { return }
        do {
            let result = try await JMClient.album(id)
            album = result
            // 列表里的信息不全（车号直达时连标题都没有），用详情补齐；封面地址保持不变
            var merged = result.comic.subject
            merged.image = subject.image
            merged.thumb = subject.thumb
            subject = merged
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(chapter: Int, page: Int) {
        guard chapters.indices.contains(chapter) else { return }
        readRequest = ComicReadRequest(subject: subject, chapters: chapters, chapterIndex: chapter, startPage: max(page, 0))
    }

    private func toggleFavorite() {
        library.toggleFavorite(subject)
    }
}

/// 简单的流式布局（标签自动换行）
@available(iOS 16, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
