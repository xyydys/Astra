import SwiftUI
import UIKit

enum ComicReadingMode: String, CaseIterable, Identifiable {
    case vertical
    case leftToRight
    case rightToLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vertical: return "上下滚动（条漫）"
        case .leftToRight: return "左右翻页"
        case .rightToLeft: return "从右往左翻页（日漫）"
        }
    }

    var icon: String {
        switch self {
        case .vertical: return "arrow.up.and.down.text.horizontal"
        case .leftToRight: return "book"
        case .rightToLeft: return "book.closed"
        }
    }
}

/// 漫画阅读器：全屏黑底，点一下显示 / 隐藏工具栏
struct ComicReaderView: View {
    let request: ComicReadRequest

    @Environment(\.dismiss) private var dismiss
    @AppStorage("comicReadingMode") private var mode: ComicReadingMode = .vertical
    @State private var chapterIndex: Int
    @State private var pendingStart: Int
    @State private var pages: [String] = []
    @State private var loading = true
    @State private var error: String?
    /// 上下滚动时顶部的那一页
    @State private var scrolledPage: Int?
    /// 翻页模式当前页（pages.count 表示「本话完」那一页）
    @State private var pagedSelection = 0
    @State private var showBars = true

    init(request: ComicReadRequest) {
        self.request = request
        _chapterIndex = State(initialValue: request.chapterIndex)
        _pendingStart = State(initialValue: request.startPage)
    }

    private var chapter: JMChapter { request.chapters[chapterIndex] }

    private var currentPage: Int {
        let page = mode == .vertical ? (scrolledPage ?? 0) : pagedSelection
        return min(max(page, 0), max(pages.count - 1, 0))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载 \(chapter.title)").font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.8))
            } else if let error {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                    Button("重试", icon: "arrow.clockwise") {
                        Task { await loadChapter() }
                    }
                    .glassButtonStyle()
                }
            } else if mode == .vertical {
                verticalReader
            } else {
                pagedReader
            }
        }
        .overlay(alignment: .top) {
            if showBars { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if showBars, !pages.isEmpty { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .statusBarHidden(!showBars)
        .homeIndicatorHiddenCompat(!showBars)
        .environment(\.colorScheme, .dark)
        .task(id: chapterIndex) { await loadChapter() }
        .onChangeCompat(of: currentPage) { _, page in
            saveProgress(page)
            prefetch(after: page)
        }
        .onChangeCompat(of: mode) { old, new in
            // 切换阅读方式时停在同一页
            let page = old == .vertical ? (scrolledPage ?? 0) : min(pagedSelection, max(pages.count - 1, 0))
            if new == .vertical { scrolledPage = page } else { pagedSelection = page }
        }
        .onDisappear { saveProgress(currentPage) }
    }

    // MARK: 上下滚动

    private var verticalReader: some View {
        PositionedScrollView(position: $scrolledPage) {
            LazyVStack(spacing: 0) {
                ForEach(pages.indices, id: \.self) { index in
                    ComicPageView(url: pages[index], chapterID: chapter.id, index: index)
                        .scrollItem(index)
                }
                chapterEnd
                    .padding(.vertical, 48)
            }
        }
        .hideScrollIndicators()
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { toggleBars() }
    }

    // MARK: 翻页

    private var pagedReader: some View {
        TabView(selection: $pagedSelection) {
            ForEach(pages.indices, id: \.self) { index in
                ComicZoomPage(url: pages[index], chapterID: chapter.id, index: index)
                    .tag(index)
            }
            chapterEnd
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(pages.count)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, mode == .rightToLeft ? .rightToLeft : .leftToRight)
        .ignoresSafeArea()
        .onTapGesture { toggleBars() }
    }

    private var chapterEnd: some View {
        VStack(spacing: 16) {
            Text("\(chapter.title) 完")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
            if chapterIndex + 1 < request.chapters.count {
                Button {
                    go(to: chapterIndex + 1)
                } label: {
                    Label("下一话：\(request.chapters[chapterIndex + 1].title)", systemImage: "chevron.forward.2")
                        .lineLimit(1)
                }
                .glassProminentButtonStyle()
            } else {
                Text("已经是最后一话")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                Button("返回详情", icon: "xmark") { dismiss() }
                    .glassButtonStyle()
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 工具栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                saveProgress(currentPage)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .glassButtonStyle()
            .circleButtonShape()

            VStack(alignment: .leading, spacing: 2) {
                Text(request.subject.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(chapter.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Picker("阅读方式", selection: $mode) {
                    ForEach(ComicReadingMode.allCases) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
            } label: {
                Image(systemName: mode.icon)
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .glassButtonStyle()
            .circleButtonShape()
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    go(to: chapterIndex - 1)
                } label: {
                    Label("上一话", systemImage: "chevron.backward.2")
                }
                .disabled(chapterIndex == 0)
                Spacer()
                Text("\(currentPage + 1) / \(pages.count)")
                    .font(.subheadline.monospacedDigit())
                Spacer()
                Button {
                    go(to: chapterIndex + 1)
                } label: {
                    Label("下一话", systemImage: "chevron.forward.2")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(chapterIndex + 1 >= request.chapters.count)
            }
            .font(.subheadline)
            if pages.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(currentPage) },
                        set: { jump(to: Int($0.rounded())) }
                    ),
                    in: 0...Double(pages.count - 1),
                    step: 1
                )
                .environment(\.layoutDirection, mode == .rightToLeft ? .rightToLeft : .leftToRight)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: 操作

    private func toggleBars() {
        withAnimation(.snappyCompat) { showBars.toggle() }
    }

    private func jump(to page: Int) {
        let target = min(max(page, 0), max(pages.count - 1, 0))
        if mode == .vertical {
            scrolledPage = target
        } else {
            pagedSelection = target
        }
    }

    private func go(to index: Int) {
        guard request.chapters.indices.contains(index), index != chapterIndex else { return }
        saveProgress(currentPage)
        pendingStart = 0
        chapterIndex = index
    }

    private func loadChapter() async {
        loading = true
        error = nil
        pages = []
        do {
            let urls = try await JMClient.chapterImages(chapter.id)
            let start = min(max(pendingStart, 0), urls.count - 1)
            pendingStart = 0
            pages = urls
            pagedSelection = start
            scrolledPage = nil
            loading = false
            prefetch(after: start - 1)
            if start > 0 {
                // 等列表排好版再滚到上次的位置
                try? await Task.sleep(nanoseconds: 80_000_000)
                scrolledPage = start
            }
            saveProgress(start)
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func prefetch(after page: Int) {
        guard !pages.isEmpty else { return }
        let lower = max(page + 1, 0)
        let upper = min(page + 5, pages.count)
        guard lower < upper else { return }
        let urls = Array(pages[lower..<upper])
        let id = chapter.id
        Task { await JMPageLoader.shared.prefetch(urls, chapterID: id) }
    }

    /// 阅读进度写进观看历史：第几话 + 第几页 / 总页数
    private func saveProgress(_ page: Int) {
        guard !pages.isEmpty else { return }
        let sid = request.subject.id
        WatchLibrary.shared.updateRecord(sid) { record in
            record.kind = "comic"
            record.title = request.subject.title
            record.name = request.subject.name
            record.image = request.subject.image
            record.ruleName = "禁漫天堂"
            record.sourceURL = request.subject.jmID ?? ""
            record.sourceTitle = chapter.title
            record.vodID = chapter.id
            record.roadIndex = 0
            record.episodeIndex = chapterIndex
            record.episodeName = chapter.title
            record.position = Double(min(max(page, 0), pages.count - 1))
            record.duration = Double(pages.count)
            record.updatedAt = Date()
        }
    }
}

// MARK: - 单页

/// 上下滚动模式的一页：没加载出来前按常见比例占位，避免跳动
struct ComicPageView: View {
    let url: String
    let chapterID: String
    let index: Int
    @State private var image: UIImage?
    @State private var failed = false

    init(url: String, chapterID: String, index: Int) {
        self.url = url
        self.chapterID = chapterID
        self.index = index
        _image = State(initialValue: ImageMemory.shared.image(url + "#jm"))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                ComicPagePlaceholder(index: index, failed: failed) {
                    failed = false
                    Task { await load() }
                }
                .aspectRatio(0.7, contentMode: .fit)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: url) {
            if image == nil { await load() }
        }
    }

    private func load() async {
        if let loaded = await JMPageLoader.shared.image(url, chapterID: chapterID) {
            image = loaded
        } else {
            failed = true
        }
    }
}

/// 翻页模式的一页：可以双指缩放、双击放大
struct ComicZoomPage: View {
    let url: String
    let chapterID: String
    let index: Int
    @State private var image: UIImage?
    @State private var failed = false

    init(url: String, chapterID: String, index: Int) {
        self.url = url
        self.chapterID = chapterID
        self.index = index
        _image = State(initialValue: ImageMemory.shared.image(url + "#jm"))
    }

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image)
            } else {
                ComicPagePlaceholder(index: index, failed: failed) {
                    failed = false
                    Task { await load() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            if image == nil { await load() }
        }
    }

    private func load() async {
        if let loaded = await JMPageLoader.shared.image(url, chapterID: chapterID) {
            image = loaded
        } else {
            failed = true
        }
    }
}

private struct ComicPagePlaceholder: View {
    let index: Int
    let failed: Bool
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.white.opacity(0.04)
            if failed {
                Button("第 \(index + 1) 页加载失败，点此重试", icon: "arrow.clockwise", action: retry)
                    .font(.footnote)
                    .glassButtonStyle()
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}

/// UIScrollView 实现的缩放图片：双指缩放、双击放大 / 还原
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator
        scroll.imageView.image = image
        context.coordinator.imageView = scroll.imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        if scroll.imageView.image !== image { scroll.imageView.image = image }
    }

    final class ZoomScrollView: UIScrollView {
        let imageView: UIImageView = {
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            return view
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(imageView)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1 {
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
