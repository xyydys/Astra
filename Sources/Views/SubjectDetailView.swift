import SwiftUI

struct SubjectDetailView: View {
    @State private var subject: BangumiSubject
    @ObservedObject private var library = WatchLibrary.shared
    @ObservedObject private var tints = PosterTints.shared

    @State private var showSources = false
    @State private var pendingRequest: PlayRequest?
    @State private var playRequest: PlayRequest?
    @State private var summaryExpanded = false
    @Environment(\.colorScheme) private var systemScheme

    init(subject: BangumiSubject) {
        _subject = State(initialValue: subject)
    }

    /// 海报主色：首页列表会提前取色，大多数情况下打开时第一帧就是对的
    private var tint: PosterTint? { tints.tint(for: subject.id) }

    private var isFavorite: Bool { library.isFavorite(subject.id) }
    private var record: WatchRecord? { library.record(subject.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actions
                if !subject.summary.isEmpty { summary }
                if !subject.tags.isEmpty { tags }
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: .top)
        // 海报底部取色，延伸成整页背景
        .background {
            (tint?.color ?? Color(uiColor: .systemBackground))
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, tint?.colorScheme ?? systemScheme)
        .navigationTitle(subject.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitleHidden()
        .task { await loadDetail() }
        .task { await PosterTints.shared.ensure(subject) }
        .sheet(isPresented: $showSources, onDismiss: {
            if let pendingRequest {
                playRequest = pendingRequest
                self.pendingRequest = nil
            }
        }) {
            SourcePickerView(subject: subject) { pick in
                pendingRequest = PlayRequest(subject: subject, pick: pick, episodeIndex: record?.episodeIndex ?? 0)
                showSources = false
            }
        }
        .navigationDestinationCompat(item: $playRequest) { request in
            PlayerScreen(request: request)
        }
    }

    // MARK: 头部

    private var meta: String {
        var parts: [String] = []
        if !subject.airDate.isEmpty { parts.append(subject.airDate) }
        if subject.episodes > 0 { parts.append("全 \(subject.episodes) 话") }
        return parts.joined(separator: " · ")
    }

    /// 整幅海报，底部渐变到海报主色，标题和信息居中叠在渐变上
    private var header: some View {
        Color.clear
            .containerHeight(fraction: 0.66, max: 720)
            .frame(maxWidth: .infinity)
            .overlay {
                // 先显示列表里已经加载过的缩略图，大图到了再淡入；底部渐隐露出同色背景
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
                    if subject.name != subject.title, !subject.name.isEmpty {
                        Text(subject.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if subject.scoreText != nil || subject.rank > 0 {
                        HStack(spacing: 12) {
                            if let score = subject.scoreText {
                                Label(score, systemImage: "star.fill")
                                    .foregroundStyle(.orange)
                            }
                            if subject.rank > 0 {
                                Text("排名 #\(subject.rank)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
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
                if let record {
                    Button {
                        playRequest = record.playRequest
                    } label: {
                        Label("继续 \(record.episodeName)", systemImage: "play.fill")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .glassProminentButtonStyle()
                    .controlSize(.large)

                    Button {
                        showSources = true
                    } label: {
                        Label("换源", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .glassButtonStyle()
                    .controlSize(.large)
                } else {
                    Button {
                        showSources = true
                    } label: {
                        Label("开始观看", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .glassProminentButtonStyle()
                    .controlSize(.large)
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

    private var tags: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(subject.tags.prefix(12), id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal)
        }
        .hideScrollIndicators()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subject.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(summaryExpanded ? nil : 5)
            Button(summaryExpanded ? "收起" : "展开") {
                withAnimation(.snappyCompat) { summaryExpanded.toggle() }
            }
            .font(.callout.weight(.medium))
        }
        .padding(.horizontal)
    }

    // MARK: 数据

    private func loadDetail() async {
        guard subject.summary.isEmpty || subject.tags.isEmpty else { return }
        if let detail = try? await BangumiAPI.subject(id: subject.id) {
            var merged = subject.merged(with: detail)
            // 海报地址保持列表里的那张，避免重新加载和重新取色造成闪烁
            if !subject.image.isEmpty {
                merged.image = subject.image
                merged.thumb = subject.thumb
            }
            subject = merged
        }
    }

    private func toggleFavorite() {
        library.toggleFavorite(subject)
    }
}
