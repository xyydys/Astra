import SwiftUI
import UIKit

/// 音乐首页：上方整块是 Folia 歌词动画，下方是进度条和切歌。收藏 / 播放历史在底栏对应的标签里。
///
/// 播放时进度每 0.25 秒刷新一次。读进度的部分（歌词动画、控制区）各自是独立的视图，
/// 这一层只依赖封面取色，特效菜单展开时不会被反复重建（否则点按、按住滑选都会失灵）
struct MusicHomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var player = MusicPlayer.shared
    @AppStorage("foliaMode") private var modeRaw = FoliaMode.classic.rawValue
    @AppStorage("foliaBackground") private var backgroundRaw = FoliaBackground.latent.rawValue
    @State private var tint: PosterTint?
    @State private var showQueue = false

    private var theme: FoliaTheme { FoliaTheme(tint: tint) }
    private var usesLightPlaybackArea: Bool { colorScheme == .light }

    private var playbackAccent: UIColor {
        // Folia 的封面色本来是调亮给深色画布用的。浅底时压深，保留封面色相。
        usesLightPlaybackArea ? theme.accent.mixed(with: .black, 0.52) : theme.accent
    }

    var body: some View {
        ZStack {
            if usesLightPlaybackArea {
                // 同一层白色衬在歌词画布、控制区和底栏后方，不在两块视图的接缝另画遮罩。
                playbackBackgroundColor
                    .ignoresSafeArea()
            } else {
                lyricsBackdrop
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                MusicLyricsArea(
                    mode: FoliaMode(rawValue: modeRaw) ?? .classic,
                    background: FoliaBackground(rawValue: backgroundRaw) ?? .latent,
                    theme: theme
                )
                .environment(\.colorScheme, .dark)
                .background {
                    if usesLightPlaybackArea { lyricsBackdrop }
                }
                .mask { lyricsSceneMask }
                MusicControls(accent: playbackAccent) { showQueue = true }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
                    .environment(\.colorScheme, usesLightPlaybackArea ? .light : .dark)
            }
            // 让画布本身覆盖状态栏，菜单仍在外层并遵循原来的安全区。
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .topTrailing) {
            FoliaEffectMenu()
                .padding(.trailing, 16)
                .padding(.top, 4)
        }
        .navigationBarHiddenCompat()
        .task(id: player.current?.cover) {
            guard let cover = player.current?.cover, !cover.isEmpty else {
                withAnimation { tint = nil }
                return
            }
            let value = await ImageCache.shared.tint(cover)
            withAnimation(.easeInOut(duration: 0.6)) { tint = value }
        }
        .sheet(isPresented: $showQueue) {
            MusicQueueSheet()
                .environment(\.colorScheme, .dark)
        }
        .onAppear {
            Diag.log("音乐", "音乐首页出现")
        }
        .onDisappear { Diag.log("音乐", "音乐首页消失") }
    }

    private var playbackBackgroundColor: Color { Color(uiColor: .systemBackground) }

    private var lyricsBackdrop: some View {
        Color(uiColor: theme.background)
            .animation(.easeInOut(duration: 0.6), value: theme)
    }

    @ViewBuilder
    private var lyricsSceneMask: some View {
        if usesLightPlaybackArea {
            GeometryReader { proxy in
                let fadeHeight = min(104, proxy.size.height)
                VStack(spacing: 0) {
                    Color.black
                    if fadeHeight > 0, proxy.size.width > 0 {
                        let pixelWidth = max(1, Int((proxy.size.width * displayScale).rounded()))
                        let pixelHeight = max(1, Int((fadeHeight * displayScale).rounded()))
                        if let mask = MusicFadeMask.image(width: pixelWidth, height: pixelHeight) {
                            Image(decorative: mask, scale: displayScale, orientation: .up)
                                .resizable()
                                .interpolation(.none)
                                .frame(height: fadeHeight)
                        } else {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: fadeHeight)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// 直接按物理像素绘制一条连续的透明度曲线。静态有序抖动把小数透明度分给相邻像素，
/// 避免 8-bit 合成时一整行一起跳一级；上下两端分别准确接到画布和白底。
@MainActor
private enum MusicFadeMask {
    private static let cache = NSCache<NSString, UIImage>()
    private static let thresholds = [
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    static func image(width: Int, height: Int) -> CGImage? {
        let key = "\(width)x\(height)" as NSString
        if let cached = cache.object(forKey: key)?.cgImage { return cached }
        cache.countLimit = 4
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let t = Double(y) / Double(max(1, height - 1))
            let alpha = 255 * (1 - t * t * (3 - 2 * t))
            let base = Int(alpha)
            let fraction = alpha - Double(base)
            for x in 0..<width {
                let threshold = (Double(thresholds[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
                bytes[(y * width + x) * 4 + 3] = UInt8(base + (fraction > threshold ? 1 : 0))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        cache.setObject(UIImage(cgImage: image), forKey: key)
        return image
    }
}

// MARK: 歌词动画

private struct MusicLyricsArea: View {
    // This switch belongs to the device diagnostic build only.
    @AppStorage("astraDeviceProbeStaticLyrics") private var useStaticLyrics = false
    let mode: FoliaMode
    let background: FoliaBackground
    let theme: FoliaTheme
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var sources = LXSourceStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if useStaticLyrics {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { emptyHint }
                .overlay(alignment: .bottom) {
                    Text("底栏测试：静态画布")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 24)
                        .allowsHitTesting(false)
                }
        } else if FoliaSchemeHandler.isAvailable {
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
}

// MARK: 播放控制

private struct MusicControls: View {
    let accent: UIColor
    let onQueue: () -> Void
    @ObservedObject private var player = MusicPlayer.shared
    /// 进度每 0.25 秒更新，只有这一块跟着刷新
    @ObservedObject private var clock = MusicPlayer.shared.clock
    @ObservedObject private var library = MusicLibrary.shared
    @ObservedObject private var sources = LXSourceStore.shared
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
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
                            .symbolReplaceTransition()
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .selectionFeedback(trigger: library.isFavorite(track))
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
                .tint(Color(uiColor: accent))
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
                                .symbolReplaceTransition()
                        }
                    }
                    .frame(width: 72, height: 72)
                    .contentShape(Circle())
                }
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                Spacer()
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title2).frame(width: 54, height: 54)
                }
                Spacer()
                Button(action: onQueue) {
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
}

// MARK: 特效切换（右上角，和左上角的模式切换一样是原生下拉菜单）

/// iOS 26 用真导航栏玻璃按钮（UINavigationBar + UIBarButtonItem(menu:)），展开菜单与按钮深浅完美互通；
/// 播放时菜单独立于 SwiftUI 刷新，点按和滑选始终稳定
private struct FoliaEffectMenu: View {
    @AppStorage("astraDeviceProbeStaticLyrics") private var useStaticLyrics = false
    @AppStorage("foliaMode") private var modeRaw = FoliaMode.classic.rawValue
    @AppStorage("foliaBackground") private var backgroundRaw = FoliaBackground.latent.rawValue

    private var mode: FoliaMode { FoliaMode(rawValue: modeRaw) ?? .classic }
    private var background: FoliaBackground { FoliaBackground(rawValue: backgroundRaw) ?? .latent }

    var body: some View {
        BarGlassPillMenuButton(
            title: mode.name,
            systemImage: "wand.and.sparkles",
            showsChevron: true,
            fontSize: AstraHomePillMetrics.font,
            iconSize: AstraHomePillMetrics.icon,
            height: AstraHomePillMetrics.height,
            horizontalPadding: AstraHomePillMetrics.sidePadding,
            tone: .dark,
            menuTitle: "歌词特效",
            accessibilityLabel: "切换歌词特效：当前\(mode.name)"
        ) {
            func option(_ mode: FoliaMode) -> MenuOption<String> {
                MenuOption(value: mode.rawValue, title: mode.name, systemImage: mode.icon)
            }
            let modes = UIMenu.picker(options: FoliaMode.folia.map(option), selected: modeRaw) { modeRaw = $0 }
            // 仿 Apple Music 直接放一项；Mineradio 的特效多，收进二级菜单
            let amll = UIMenu.picker(options: [option(.amll)], selected: modeRaw) { modeRaw = $0 }
            let mineradio = UIMenu.picker(
                title: mode.isMineradio ? "Mineradio：\(mode.name)" : "Mineradio 粒子",
                image: UIImage(systemName: "circle.hexagongrid"),
                inline: false,
                options: FoliaMode.mineradio.map(option),
                selected: modeRaw
            ) { modeRaw = $0 }
            var children: [UIMenuElement] = [modes, UIMenu(options: .displayInline, children: amll.children + [mineradio])]
            if mode.isFolia {
                children.append(UIMenu.picker(
                    title: "背景：\(background.name)",
                    image: UIImage(systemName: "circle.lefthalf.filled"),
                    inline: false,
                    options: FoliaBackground.allCases.map { MenuOption(value: $0.rawValue, title: $0.name) },
                    selected: backgroundRaw
                ) { backgroundRaw = $0 })
            }
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(
                    title: "底栏对照：静态画布",
                    image: UIImage(systemName: "rectangle"),
                    state: useStaticLyrics ? .on : .off
                ) { _ in useStaticLyrics.toggle() }
            ]))
            return children
        }
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

/// 音乐模式下底栏「收藏」「历史」标签的内容
struct MusicTrackListView: View {
    enum Kind { case favorites, history }
    let kind: Kind
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var library = MusicLibrary.shared
    @State private var confirmClear = false

    private var tracks: [MusicTrack] { kind == .favorites ? library.favorites : library.history }

    var body: some View {
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
            .onDelete { offsets in
                if kind == .favorites { library.removeFavorites(at: offsets) } else { library.removeHistory(at: offsets) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if tracks.isEmpty {
                if kind == .favorites {
                    EmptyStateView("还没有收藏", systemImage: "heart", description: Text("在音乐页点 ♡ 收藏正在播放的歌"))
                } else {
                    EmptyStateView("还没有播放记录", systemImage: "clock", description: Text("听过的歌会出现在这里"))
                }
            }
        }
        .navigationTitle(kind == .favorites ? "音乐收藏" : "播放历史")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if kind == .history, !tracks.isEmpty {
                    Button("清空", icon: "trash") { confirmClear = true }
                        .confirmationDialog("清空播放历史？", isPresented: $confirmClear) {
                            Button("清空", role: .destructive) { library.clearHistory() }
                        }
                }
                if !tracks.isEmpty {
                    Button("全部播放", icon: "play.fill") {
                        if let first = tracks.first { player.play(first, in: tracks) }
                    }
                }
            }
        }
    }
}

struct MusicQueueSheet: View {
    @ObservedObject private var player = MusicPlayer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStackCompat {
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
                    EmptyStateView("播放列表是空的", systemImage: "music.note.list")
                }
            }
            .navigationTitle("播放列表 · \(player.queue.count) 首")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭", icon: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
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
        .sheetDetents([.medium, .large])
    }
}

/// 长按菜单：下一首播放、收藏
struct MusicTrackMenu: View {
    let track: MusicTrack
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var library = MusicLibrary.shared

    var body: some View {
        Button("下一首播放", icon: "text.line.first.and.arrowtriangle.forward") { player.playNext(track) }
        Button(library.isFavorite(track) ? "取消收藏" : "收藏", icon: library.isFavorite(track) ? "heart.slash" : "heart") {
            library.toggleFavorite(track)
        }
    }
}
