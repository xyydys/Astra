import SwiftUI
import WebKit
import AVKit

// MARK: - 导航

extension View {
    /// 各个 Tab 的 NavigationStack 共用的跳转目标
    func appDestinations() -> some View {
        self
            .navigationDestination(for: BangumiSubject.self) { subject in
                // 漫画、影视条目（负数 id）各走各的详情页
                if subject.isNovel {
                    NovelDetailView(subject: subject)
                } else if subject.isComic {
                    ComicDetailView(subject: subject)
                } else if subject.isVideo {
                    VideoDetailView(subject: subject)
                } else {
                    SubjectDetailView(subject: subject)
                }
            }
            .navigationDestination(for: PlayRequest.self) { request in
                PlayerScreen(request: request)
            }
            .navigationDestination(for: ComicTagRoute.self) { route in
                ComicTagResultsView(keyword: route.keyword)
            }
    }
}

// MARK: - 图片

struct PosterImage: View {
    let url: String
    /// 大图还没加载时先显示的小图（通常是列表里已经加载过的缩略图）
    var fallback: String? = nil
    var showsPlaceholder = true
    @State private var image: UIImage?

    init(url: String, fallback: String? = nil, showsPlaceholder: Bool = true) {
        self.url = url
        self.fallback = fallback
        self.showsPlaceholder = showsPlaceholder
        _image = State(initialValue: Self.memoryImage(url: url, fallback: fallback))
    }

    private static func memoryImage(url: String, fallback: String?) -> UIImage? {
        ImageMemory.shared.image(url) ?? fallback.flatMap { ImageMemory.shared.image($0) }
    }

    var body: some View {
        ZStack {
            if showsPlaceholder {
                Rectangle().fill(Color.secondary.opacity(0.15))
                if image == nil {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            if let cached = ImageMemory.shared.image(url) {
                if image !== cached { image = cached }
                return
            }
            // 地址变了（同一位置换了海报）：先换成缩略图或空白，别继续显示上一张
            let interim = fallback.flatMap { ImageMemory.shared.image($0) }
            if image !== interim { image = interim }
            // 大图加载失败（比如豆瓣大图地址不可用）时退回小图
            guard let loaded = await ImageCache.shared.load(url),
                  !Task.isCancelled else {
                if image == nil, let fallback, let small = await ImageCache.shared.load(fallback), !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.25)) { image = small }
                }
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}

/// 竖版海报卡片（2:3）
struct PosterCard: View {
    let subject: BangumiSubject
    var width: CGFloat? = nil
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { PosterImage(url: subject.thumb.isEmpty ? subject.image : subject.thumb) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let score = subject.scoreText {
                        Text(score)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .glassEffect(.regular, in: Capsule())
                            .padding(6)
                    }
                }
            Text(subject.title)
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
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.weight(.bold))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
    }
}

/// 横向滚动里的分类标签。不用玻璃按钮：玻璃按钮放进横向 ScrollView 后，
/// 遇到浅色背景会在整行后面采样出一条半透明的底带
struct TagChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: selected)
    }
}

// MARK: - WebView 承载

/// 解析用 WebView 需要挂在窗口上才不会被系统节流，这里用一个 2pt 的透明容器承载
struct HiddenWebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        webView.removeFromSuperview()
        webView.frame = container.bounds
        container.addSubview(webView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if webView.superview !== uiView {
            webView.removeFromSuperview()
            webView.frame = uiView.bounds
            uiView.addSubview(webView)
        }
    }
}

/// 可见的 WebView（网页验证用）
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 播放器

struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var onFullscreenChange: (Bool) -> Void = { _ in }
    var onPictureInPictureChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        if controller.player !== player { controller.player = player }
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var parent: VideoPlayerView

        init(parent: VideoPlayerView) { self.parent = parent }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            parent.onFullscreenChange(true)
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            let callback = parent.onFullscreenChange
            _ = coordinator.animate(alongsideTransition: nil) { context in
                if !context.isCancelled { callback(false) }
            }
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            parent.onPictureInPictureChange(true)
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            parent.onPictureInPictureChange(false)
        }
    }
}
