import SwiftUI

/// 音乐首页：上方整块是 Folia 歌词动画，中间是进度条和切歌，底栏上方是收藏 / 播放历史卡片
struct MusicHomeView: View {
    @State private var player = MusicPlayer.shared
    @State private var library = MusicLibrary.shared
    @State private var sources = LXSourceStore.shared
    @AppStorage("foliaMode") private var modeRaw = FoliaMode.classic.rawValue
    @AppStorage("foliaBackground") private var backgroundRaw = FoliaBackground.latent.rawValue
    @State private var tint: PosterTint?
    @State private var sheet: MusicSheet?
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @Environment(\.scenePhase) private var scenePhase

    enum MusicSheet: String, Identifiable {
        case favorites, history, queue
        var id: String { rawValue }
    }

    private var mode: FoliaMode { FoliaMode(rawValue: modeRaw) ?? .classic }
    private var background: FoliaBackground { FoliaBackground(rawValue: backgroundRaw) ?? .latent }
    private var theme: FoliaTheme { FoliaTheme(tint: tint) }

    var body: some View {
        ZStack {
            Color(uiColor: theme.background)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: theme)
            VStack(spacing: 0) {
                lyricsArea
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    )
                    .ignoresSafeArea(edges: .top)
                controls
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
                libraryCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .overlay(alignment: .topTrailing) {
            effectMenu
                .padding(.trailing, 16)
                .padding(.top, 4)
        }
        .environment(\.colorScheme, .dark)
        // 这一页始终是深色，底栏也明确用深色：交给系统按背景判断时，切换页面后底栏常常保持上一页的浅色
        .toolbarColorScheme(.dark, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: player.current?.cover) {
            guard let cover = player.current?.cover, !cover.isEmpty else {
                withAnimation { tint = nil }
                return
            }
            let value = await ImageCache.shared.tint(cover)
            withAnimation(.easeInOut(duration: 0.6)) { tint = value }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .favorites:
                MusicTrackListSheet(title: "我的收藏", tracks: library.favorites,
                                    onDelete: { library.removeFavorites(at: $0) }, onClear: nil)
            case .history:
                MusicTrackListSheet(title: "播放历史", tracks: library.history,
                                    onDelete: { library.removeHistory(at: $0) }, onClear: { library.clearHistory() })
            case .queue:
                MusicQueueSheet()
            }
        }
    }

    // MARK: 歌词动画

    @ViewBuilder
    private var lyricsArea: some View {
        if FoliaSchemeHandler.isAvailable {
            FoliaLyricsView(
                player: player, mode: mode, background: background, theme: theme,
                songRevision: player.songRevision, clockRevision: player.clockRevision,
                active: scenePhase == .active
            )
            .overlay { emptyHint }
        } else {
            ZStack {
                Text(player.current?.name ?? "歌词动画资源没有打包进来")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding()
                emptyHint
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var emptyHint: some View {
        if player.current == nil {
            VStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 34, weight: .light))
                Text(sources.entries.isEmpty ? "先在「我的 → 音乐 → 音源管理」导入洛雪音源" : "在底栏的搜索里找一首歌开始播放")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 40)
            .allowsHitTesting(false)
        }
    }

    // MARK: 播放控制

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.current?.name ?? "未在播放")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let track = player.current {
                    Button {
                        library.toggleFavorite(track)
                    } label: {
                        Image(systemName: library.isFavorite(track) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(library.isFavorite(track) ? Color.pink : Color.primary)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: library.isFavorite(track))
                }
            }

            if let error = player.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubValue : min(player.displayTime, max(player.duration, 1)) },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            scrubValue = player.displayTime
                            scrubbing = true
                        } else {
                            player.seek(to: scrubValue)
                            scrubbing = false
                        }
                    }
                )
                .tint(Color(uiColor: theme.accent))
                .disabled(player.current == nil)
                HStack {
                    Text((scrubbing ? scrubValue : player.displayTime).clockText)
                    Spacer()
                    Text(player.duration.clockText)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    let all = MusicPlayer.RepeatMode.allCases
                    player.repeatMode = all[((all.firstIndex(of: player.repeatMode) ?? 0) + 1) % all.count]
                } label: {
                    Image(systemName: player.repeatMode.icon)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title2).frame(width: 54, height: 54)
                }
                Spacer()
                Button { player.togglePlay() } label: {
                    ZStack {
                        if player.isLoading {
                            ProgressView().controlSize(.large)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 72, height: 72)
                    .glassEffect(.regular.interactive(), in: Circle())
                }
                Spacer()
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title2).frame(width: 54, height: 54)
                }
                Spacer()
                Button { sheet = .queue } label: {
                    Image(systemName: "list.bullet")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
            }
            .buttonStyle(.plain)
            .disabled(player.current == nil)
        }
        .foregroundStyle(.primary)
    }

    private var subtitle: String {
        guard let track = player.current else {
            return sources.active.map { "音源：\($0.info.name)" } ?? "还没有导入音源"
        }
        return "\(track.singer) · \(track.source.short)"
    }

    // MARK: 收藏 / 历史卡片

    private var libraryCard: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                cardButton("我的收藏", icon: "heart.fill", count: library.favorites.count) { sheet = .favorites }
                cardButton("播放历史", icon: "clock.arrow.circlepath", count: library.history.count) { sheet = .history }
            }
        }
    }

    private func cardButton(_ title: String, icon: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color(uiColor: theme.accent))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text("\(count) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 特效切换（右上角，和左上角的模式切换一样是原生下拉菜单）

    private var effectMenu: some View {
        Menu {
            Picker("歌词特效", selection: $modeRaw) {
                ForEach(FoliaMode.allCases) { item in
                    Label(item.name, systemImage: item.icon).tag(item.rawValue)
                }
            }
            .pickerStyle(.inline)
            Menu {
                Picker("背景", selection: $backgroundRaw) {
                    ForEach(FoliaBackground.allCases) { item in
                        Text(item.name).tag(item.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("背景：\(background.name)", systemImage: "circle.lefthalf.filled")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.sparkles")
                Text(mode.name)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("切换歌词特效：当前\(mode.name)")
    }
}

// MARK: - 列表

struct MusicTrackRow: View {
    let track: MusicTrack
    var isCurrent = false

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 46, height: 46)
                .overlay {
                    if track.cover.isEmpty {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.secondary.opacity(0.15))
                    } else {
                        PosterImage(url: track.cover)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(track.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(track.source.short)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                if !track.durationText.isEmpty {
                    Text(track.durationText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct MusicTrackListSheet: View {
    let title: String
    let tracks: [MusicTrack]
    let onDelete: (IndexSet) -> Void
    let onClear: (() -> Void)?
    @State private var player = MusicPlayer.shared
    @State private var library = MusicLibrary.shared
    @State private var confirmClear = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(tracks) { track in
                    Button {
                        player.play(track, in: tracks)
                    } label: {
                        MusicTrackRow(track: track, isCurrent: player.current?.id == track.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { MusicTrackMenu(track: track) }
                }
                .onDelete(perform: onDelete)
            }
            .listStyle(.plain)
            .overlay {
                if tracks.isEmpty {
                    ContentUnavailableView(title == "我的收藏" ? "还没有收藏" : "还没有播放记录",
                                           systemImage: title == "我的收藏" ? "heart" : "clock")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let onClear, !tracks.isEmpty {
                        Button("清空", systemImage: "trash") { confirmClear = true }
                            .confirmationDialog("清空播放历史？", isPresented: $confirmClear) {
                                Button("清空", role: .destructive) { onClear() }
                            }
                    }
                    if !tracks.isEmpty {
                        Button("全部播放", systemImage: "play.fill") {
                            if let first = tracks.first { player.play(first, in: tracks) }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MusicQueueSheet: View {
    @State private var player = MusicPlayer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { offset, track in
                    Button {
                        player.play(track)
                    } label: {
                        MusicTrackRow(track: track, isCurrent: offset == player.index)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { MusicTrackMenu(track: track) }
                }
                .onDelete { player.removeFromQueue(at: $0) }
            }
            .listStyle(.plain)
            .overlay {
                if player.queue.isEmpty {
                    ContentUnavailableView("播放列表是空的", systemImage: "music.note.list")
                }
            }
            .navigationTitle("播放列表 · \(player.queue.count) 首")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("播放顺序", selection: $player.repeatMode) {
                            ForEach(MusicPlayer.RepeatMode.allCases, id: \.self) { mode in
                                Label(mode.name, systemImage: mode.icon).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: player.repeatMode.icon)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 长按菜单：下一首播放、收藏
struct MusicTrackMenu: View {
    let track: MusicTrack
    @State private var player = MusicPlayer.shared
    @State private var library = MusicLibrary.shared

    var body: some View {
        Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(track) }
        Button(library.isFavorite(track) ? "取消收藏" : "收藏", systemImage: library.isFavorite(track) ? "heart.slash" : "heart") {
            library.toggleFavorite(track)
        }
    }
}
