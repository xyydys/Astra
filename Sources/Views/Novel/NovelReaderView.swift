import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 打开阅读器需要的信息
struct NovelReadRequest: Identifiable {
    let subjectID: Int
    let book: NovelBook
    let chapters: [NovelChapter]
    let chapterIndex: Int
    let offset: Int

    var id: String { "\(subjectID)-\(book.origin)-\(chapterIndex)-\(offset)" }
}

// MARK: - 阅读器数据

@MainActor
final class NovelReaderModel: ObservableObject {
    let subjectID: Int
    let book: NovelBook
    let chapters: [NovelChapter]
    private let source: BookSource?

    @Published private(set) var settings: ReaderSettings
    @Published var systemDark = false {
        didSet { if oldValue != systemDark, settings.followSystemDark { relayout() } }
    }
    @Published var showsMenu = false
    /// 音量键等外部触发的翻页，翻页控件看到 id 变了就翻一页
    @Published private(set) var turnRequest = TurnRequest()

    struct TurnRequest: Equatable {
        var id = 0
        var forward = true
    }

    enum TapAction {
        case previous, next, menu
    }

    func requestTurn(forward: Bool) {
        turnRequest = TurnRequest(id: turnRequest.id + 1, forward: forward)
    }

    /// 点按位置（页面宽度的比例）对应的动作：两侧 30% 按设置翻页，中间呼出菜单
    func tapAction(x: CGFloat) -> TapAction {
        let side: TapAction? = x < 0.3 ? .previous : x > 0.7 ? .next : nil
        switch (settings.tapMode, side) {
        case (.sides, let action?): return action
        case (.forward, _?): return .next
        default: return .menu
        }
    }

    @Published private(set) var metrics = ReaderPaginator.Metrics(size: .zero, insets: .zero)
    @Published private(set) var position: ReaderPosition
    /// 设置变化后重排版、跳章时加 1：翻页控件整页重建
    @Published private(set) var revision = 0
    /// 有章节加载完时加 1：当前是占位页的话换成正文
    @Published private(set) var contentRevision = 0
    @Published private(set) var loading: Set<Int> = []
    @Published private(set) var errors: [Int: String] = [:]
    /// 滚动模式下已经接上的章节
    @Published private(set) var scrollChapters: [Int] = []

    private var texts: [Int: String] = [:]
    private var layouts: [Int: ChapterLayout] = [:]
    /// 排版完成后要恢复到的章内位置
    private var pendingOffset: Int?
    var onProgress: ((NovelReaderModel) -> Void)?
    /// 滚动模式：跳章 / 重排后还没滚到目标位置
    var needsScrollRestore = true

    init(request: NovelReadRequest, settings: ReaderSettings) {
        subjectID = request.subjectID
        book = request.book
        chapters = request.chapters
        source = BookSourceStore.shared.source(for: request.book.origin)
        self.settings = settings
        let index = min(max(request.chapterIndex, 0), max(request.chapters.count - 1, 0))
        position = ReaderPosition(chapter: index, page: 0)
        pendingOffset = request.offset
        scrollChapters = [index]
        // 不在这里开始加载正文（放到阅读器的 onAppear）：@State 的初始值每次创建视图都会重新求值，
        // 在这里改动状态、起加载任务，任务完成时外层视图会被通知重建，又建一个新模型，循环不停
    }

    var theme: ReaderTheme {
        if settings.followSystemDark, systemDark, settings.theme != .image, !settings.theme.isDark { return .night }
        return settings.theme
    }

    var currentChapter: NovelChapter? {
        chapters.indices.contains(position.chapter) ? chapters[position.chapter] : nil
    }

    // MARK: 排版

    private var viewportSize: CGSize = .zero
    private var safe = EdgeInsets()

    func setViewport(size: CGSize, safe: EdgeInsets) {
        guard size.width > 0 else { return }
        viewportSize = size
        self.safe = safe
        updateMetrics()
    }

    func apply(_ new: ReaderSettings) {
        guard new != settings else { return }
        // 只调了背景图蒙层：不用重新排版，重画一下页面就行（拖动滑块时不卡）
        var other = new
        other.imageDim = settings.imageDim
        if other == settings {
            settings = new
            revision += 1
            return
        }
        if new.pageMode != settings.pageMode { scrollChapters = [position.chapter] }
        settings = new
        if !updateMetrics() { relayout() }
    }

    /// 尺寸或边距变化时重排版，返回是否重排了
    @discardableResult
    private func updateMetrics() -> Bool {
        let margin = CGFloat(settings.margin)
        let insets = UIEdgeInsets(
            top: safe.top + 34, left: safe.leading + margin,
            bottom: safe.bottom + 30, right: safe.trailing + margin
        )
        let new = ReaderPaginator.Metrics(size: viewportSize, insets: insets)
        guard new != metrics, viewportSize.width > 0 else { return false }
        metrics = new
        relayout()
        return true
    }

    private func relayout() {
        if pendingOffset == nil { pendingOffset = currentOffset }
        layouts.removeAll()
        _ = layout(position.chapter)
        needsScrollRestore = true
        revision += 1
    }

    /// 已排版的章节（文字已加载、尺寸已知时按需排版）
    func layout(_ chapter: Int) -> ChapterLayout? {
        if let cached = layouts[chapter] { return cached }
        guard metrics.size.width > 0, let text = texts[chapter], chapters.indices.contains(chapter) else { return nil }
        let layout = ReaderPaginator.layout(
            chapter: chapter, title: chapters[chapter].title, text: text,
            metrics: metrics, settings: settings, theme: theme
        )
        layouts[chapter] = layout
        if chapter == position.chapter, let offset = pendingOffset {
            position.page = layout.page(containing: offset)
            pendingOffset = nil
        }
        // 只缓存附近几章
        if layouts.count > 6 {
            for key in layouts.keys where abs(key - position.chapter) > 2 { layouts[key] = nil }
        }
        return layout
    }

    var currentOffset: Int {
        if let layout = layouts[position.chapter], layout.pages.indices.contains(position.page) {
            return layout.pages[position.page].charRange.location
        }
        return pendingOffset ?? 0
    }

    var currentLength: Int {
        layouts[position.chapter]?.length ?? texts[position.chapter]?.count ?? 0
    }

    var chapterProgress: Double {
        guard let layout = layouts[position.chapter], layout.pages.count > 0 else { return 0 }
        return Double(position.page + 1) / Double(layout.pages.count)
    }

    var bookProgress: Double {
        guard !chapters.isEmpty else { return 0 }
        return (Double(position.chapter) + chapterProgress) / Double(chapters.count)
    }

    // MARK: 翻页

    func resolve(_ p: ReaderPosition) -> ReaderPosition {
        guard let layout = layout(p.chapter), !layout.pages.isEmpty else { return p }
        var page = p.page < 0 ? layout.pages.count - 1 : p.page
        page = min(max(page, 0), layout.pages.count - 1)
        return ReaderPosition(chapter: p.chapter, page: page)
    }

    func position(after p: ReaderPosition) -> ReaderPosition? {
        let current = resolve(p)
        if let layout = layout(current.chapter), current.page >= 0, current.page + 1 < layout.pages.count {
            return ReaderPosition(chapter: current.chapter, page: current.page + 1)
        }
        guard current.chapter + 1 < chapters.count else { return nil }
        return ReaderPosition(chapter: current.chapter + 1, page: 0)
    }

    func position(before p: ReaderPosition) -> ReaderPosition? {
        let current = resolve(p)
        if layout(current.chapter) != nil, current.page > 0 {
            return ReaderPosition(chapter: current.chapter, page: current.page - 1)
        }
        guard current.chapter > 0 else { return nil }
        return ReaderPosition(chapter: current.chapter - 1, page: -1)
    }

    func didShow(_ p: ReaderPosition) {
        let resolved = resolve(p)
        guard resolved != position || pendingOffset != nil else { return }
        position = resolved
        if layouts[resolved.chapter] != nil { pendingOffset = nil }
        ensureLoaded(resolved.chapter)
        ensureLoaded(resolved.chapter + 1)
        if resolved.page == 0 { ensureLoaded(resolved.chapter - 1) }
        onProgress?(self)
    }

    func jump(to chapter: Int, offset: Int = 0) {
        guard chapters.indices.contains(chapter) else { return }
        position = ReaderPosition(chapter: chapter, page: 0)
        pendingOffset = offset
        scrollChapters = [chapter]
        _ = layout(chapter)
        ensureLoaded(chapter)
        needsScrollRestore = true
        revision += 1
        onProgress?(self)
    }

    func appendScrollChapter() {
        guard let last = scrollChapters.last, last + 1 < chapters.count else { return }
        guard texts[last] != nil else { return }
        scrollChapters.append(last + 1)
        ensureLoaded(last + 1)
        ensureLoaded(last + 2)
    }

    func prependScrollChapter() {
        guard let first = scrollChapters.first, first > 0 else { return }
        scrollChapters.insert(first - 1, at: 0)
        ensureLoaded(first - 1)
    }

    // MARK: 页面内容

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    func content(for p: ReaderPosition) -> ReaderPageView.Content {
        let title = chapters.indices.contains(p.chapter) ? chapters[p.chapter].title : ""
        if let layout = layout(p.chapter), layout.pages.indices.contains(p.page) {
            let progress = (Double(p.chapter) + Double(p.page + 1) / Double(layout.pages.count)) / Double(max(chapters.count, 1))
            return ReaderPageView.Content(
                layout: layout, page: p.page,
                header: p.page == 0 ? book.name : title,
                footerLeft: Self.clock.string(from: Date()) + "   " + String(format: "%.1f%%", progress * 100),
                footerRight: "\(p.page + 1) / \(layout.pages.count)"
            )
        }
        if let error = errors[p.chapter] {
            return ReaderPageView.Content(
                layout: nil, page: 0, header: title, footerLeft: "", footerRight: "",
                message: "\(title)\n加载失败：\(error)\n点屏幕中间打开菜单，可以重试或换源"
            )
        }
        Task { self.ensureLoaded(p.chapter) }
        return ReaderPageView.Content(layout: nil, page: 0, header: title, footerLeft: "", footerRight: "",
                                      message: title, loading: true)
    }

    // MARK: 正文加载

    func ensureLoaded(_ index: Int) {
        guard chapters.indices.contains(index), texts[index] == nil, !loading.contains(index) else { return }
        loading.insert(index)
        errors[index] = nil
        let chapter = chapters[index]
        let next = chapters.indices.contains(index + 1) ? chapters[index + 1].absoluteURL : nil
        let book = book
        let source = source
        let id = subjectID
        Task {
            do {
                var raw = NovelLibrary.cachedContent(id: id, origin: book.origin, chapter: chapter)
                if raw == nil {
                    guard let source else { throw BookEngineError.message("书源「\(book.originName)」已删除或停用，请换源") }
                    let fetched = try await BookEngine.run { env in
                        try WebBook.content(source, book: book, chapter: chapter, nextChapterUrl: next, env: env)
                    }
                    if !fetched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        NovelLibrary.saveContent(fetched, id: id, origin: book.origin, chapter: chapter)
                    }
                    raw = fetched
                }
                let text = Self.clean(raw ?? "", title: chapter.title)
                texts[index] = text.isEmpty ? "（本章没有内容）" : text
            } catch {
                errors[index] = error.localizedDescription
            }
            loading.remove(index)
            layouts[index] = nil
            _ = layout(index)
            contentRevision += 1
        }
    }

    func reloadCurrent() {
        let index = position.chapter
        guard chapters.indices.contains(index) else { return }
        NovelLibrary.clearContent(id: subjectID, origin: book.origin, chapter: chapters[index])
        texts[index] = nil
        layouts[index] = nil
        errors[index] = nil
        pendingOffset = 0
        ensureLoaded(index)
        revision += 1
    }

    /// 正文整理：去掉空行、全角空格缩进、和章节名重复的首行
    static func clean(_ raw: String, title: String) -> String {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3000}\u{00A0}\u{200B}"))
        var lines = raw.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<img") }
        let compactTitle = title.filter { !$0.isWhitespace }
        if let first = lines.first, first.filter({ !$0.isWhitespace }) == compactTitle {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 阅读器

struct NovelReaderView: View {
    @StateObject private var model: NovelReaderModel
    @ObservedObject private var store = ReaderSettingsStore.shared
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var saveTask: Task<Void, Never>?
    @State private var sliderValue: Double = 0
    @State private var sliding = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.openURL) private var openURL
    /// 顶栏中间胶囊的高度，左右两个按钮跟它一样高
    @State private var titleHeight: CGFloat = 52
    @State private var volumePager = VolumeKeyPager()

    init(request: NovelReadRequest) {
        _model = StateObject(wrappedValue: NovelReaderModel(request: request, settings: ReaderSettingsStore.shared.settings))
    }

    private struct Viewport: Equatable {
        var size: CGSize
        var insets: EdgeInsets
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let full = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                              height: proxy.size.height + insets.top + insets.bottom)
            ZStack {
                ReaderBackdrop(theme: model.theme, version: model.settings.imageVersion, dim: model.settings.imageDim)
                switch model.settings.pageMode {
                case .curl, .slide:
                    ReaderPager(model: model, mode: model.settings.pageMode)
                        .id(model.settings.pageMode)
                        .ignoresSafeArea()
                case .scroll:
                    ReaderScrollView(model: model)
                }
            }
            .onChangeCompat(of: Viewport(size: full, insets: insets), initial: true) { _, viewport in
                model.setViewport(size: viewport.size, safe: viewport.insets)
            }
        }
        .overlay {
            if model.showsMenu {
                menu.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showsMenu)
        .statusBarHidden(!model.showsMenu)
        .homeIndicatorHiddenCompat()
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(store: store)
                // 不开背景交互：点面板外面就关掉面板
                .sheetDetents([.height(430), .large])
                // 面板跟着阅读主题的深浅走（夜读时面板也是深色），不跟系统
                .readerColorScheme(model.theme.colorScheme)
        }
        .sheet(isPresented: $showTOC) {
            NovelTOCSheet(chapters: model.chapters, current: model.position.chapter) { index in
                showTOC = false
                model.showsMenu = false
                model.jump(to: index)
            }
            .readerColorScheme(model.theme.colorScheme)
        }
        .onChangeCompat(of: store.settings.volumeKeys, initial: true) { _, enabled in updateVolumeKeys(enabled) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.ensureLoaded(model.position.chapter)
            model.onProgress = { model in scheduleSave(model) }
            sliderValue = Double(model.position.chapter)
        }
        .onDisappear {
            volumePager.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            saveTask?.cancel()
            saveRecord(model)
        }
        .onChangeCompat(of: store.settings) { _, new in model.apply(new) }
        .onChangeCompat(of: systemScheme, initial: true) { _, scheme in model.systemDark = scheme == .dark }
        .onChangeCompat(of: model.position.chapter) { _, chapter in
            if !sliding { sliderValue = Double(chapter) }
        }
    }

    private func updateVolumeKeys(_ enabled: Bool) {
        if enabled {
            let model = model
            volumePager.onPress = { up in model.requestTurn(forward: !up) }
            volumePager.start()
        } else {
            volumePager.stop()
        }
    }

    // MARK: 菜单

    private var menu: some View {
        VStack(spacing: 0) {
            topBar
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.showsMenu = false }
            bottomBar
        }
        .environment(\.colorScheme, model.theme.colorScheme)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: titleHeight, height: titleHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glass(interactive: true, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(model.book.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.currentChapter?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(in: Capsule())
            .readHeight { titleHeight = $0 }

            Menu {
                Button("刷新本章", icon: "arrow.clockwise") {
                    model.reloadCurrent()
                    model.showsMenu = false
                }
                if let chapter = model.currentChapter, let url = URL.lenient(EngineURL.splitOption(chapter.absoluteURL).url) {
                    Button("打开原网页", icon: "safari") { openURL(url) }
                }
                Text("书源：\(model.book.originName)")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: titleHeight, height: titleHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glass(interactive: true, in: Circle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if sliding, model.chapters.indices.contains(Int(sliderValue)) {
                Text(model.chapters[Int(sliderValue)].title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glass(in: Capsule())
            }
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Button {
                        model.jump(to: model.position.chapter - 1)
                    } label: {
                        Text("上一章").font(.subheadline)
                    }
                    .disabled(model.position.chapter <= 0)
                    Slider(
                        value: $sliderValue,
                        in: 0...Double(max(model.chapters.count - 1, 1)),
                        step: 1,
                        onEditingChanged: { editing in
                            sliding = editing
                            if !editing { model.jump(to: Int(sliderValue)) }
                        }
                    )
                    Button {
                        model.jump(to: model.position.chapter + 1)
                    } label: {
                        Text("下一章").font(.subheadline)
                    }
                    .disabled(model.position.chapter + 1 >= model.chapters.count)
                }
                .buttonStyle(.plain)

                HStack {
                    menuButton("目录", "list.bullet") { showTOC = true }
                    menuButton(model.theme.isDark ? "日间" : "夜间", model.theme.isDark ? "sun.max" : "moon") {
                        toggleNight()
                    }
                    menuButton("设置", "textformat.size") { showSettings = true }
                    menuButton(String(format: "%.1f%%", model.bookProgress * 100), "chart.bar.doc.horizontal") {}
                        .disabled(true)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .glass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func menuButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(height: 24)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleNight() {
        var settings = store.settings
        if model.theme.isDark {
            settings.followSystemDark = false
            if settings.theme.isDark { settings.theme = .paper }
        } else {
            settings.theme = .night
        }
        store.settings = settings
    }

    // MARK: 进度

    private func scheduleSave(_ model: NovelReaderModel) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            saveRecord(model)
        }
    }

    private func saveRecord(_ model: NovelReaderModel) {
        guard let chapter = model.currentChapter else { return }
        let id = model.subjectID
        let book = model.book
        WatchLibrary.shared.updateRecord(id) { record in
            record.kind = "novel"
            record.title = book.name
            record.name = book.author
            record.image = NovelCover.url(book.coverUrl)
            record.ruleName = book.origin
            record.sourceTitle = book.originName
            record.sourceURL = book.bookUrl
            record.episodeIndex = model.position.chapter
            record.episodeName = chapter.title
            record.position = Double(model.currentOffset)
            record.duration = Double(max(model.currentLength, 1))
            record.roadIndex = model.chapters.count
            record.updatedAt = Date()
        }
    }
}

// MARK: - 滚动模式

struct ReaderScrollView: View {
    @ObservedObject var model: NovelReaderModel
    @State private var scrolled: ReaderPosition?

    var body: some View {
        PositionedScrollView(position: $scrolled) {
            pages
        }
        .hideScrollIndicators()
        .onChangeCompat(of: scrolled) { _, position in
            if let position { model.didShow(position) }
        }
        .onChangeCompat(of: model.revision, initial: true) { restore() }
        .onChangeCompat(of: model.contentRevision) { restore() }
        .onChangeCompat(of: model.turnRequest) { _, request in turn(forward: request.forward) }
    }

    /// 正文页上的点按（页面里用 UIKit 识别，拿得到位置）
    private func tap(_ x: CGFloat) {
        if model.showsMenu {
            model.showsMenu = false
            return
        }
        switch model.tapAction(x: x) {
        case .previous: turn(forward: false)
        case .next: turn(forward: true)
        case .menu: model.showsMenu = true
        }
    }

    /// 滚动模式的「翻一页」：滚到下一页 / 上一页的顶部
    private func turn(forward: Bool) {
        let current = scrolled ?? model.position
        guard let target = forward ? model.position(after: current) : model.position(before: current) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { scrolled = target }
    }

    private var pages: some View {
        LazyVStack(spacing: 0) {
            if let first = model.scrollChapters.first, first > 0 {
                Button("上一章") { model.prependScrollChapter() }
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: model.theme.secondary))
                    .padding(.vertical, 20)
            }
            ForEach(model.scrollChapters, id: \.self) { chapter in
                chapterView(chapter)
            }
            if let last = model.scrollChapters.last, last + 1 < model.chapters.count {
                ProgressView()
                    .tint(Color(uiColor: model.theme.secondary))
                    .padding(.vertical, 40)
                    .onAppear { model.appendScrollChapter() }
            }
        }
    }

    /// 跳章、重排版后滚到保存的位置（只做一次，之后加载别的章节不再跳动）
    private func restore() {
        guard model.needsScrollRestore else { return }
        scrolled = model.position
        if model.layout(model.position.chapter) != nil { model.needsScrollRestore = false }
    }

    @ViewBuilder
    private func chapterView(_ chapter: Int) -> some View {
        if let layout = model.layout(chapter) {
            ForEach(layout.pages.indices, id: \.self) { index in
                ReaderScrollPage(layout: layout, page: index, theme: model.theme, margin: CGFloat(model.settings.margin), onTap: tap)
                    .frame(height: layout.pages[index].usedHeight)
                    .scrollItem(ReaderPosition(chapter: chapter, page: index))
            }
            Color.clear
                .frame(height: 48)
                .contentShape(Rectangle())
                .onTapGesture { model.showsMenu.toggle() }
        } else {
            VStack(spacing: 12) {
                Text(model.chapters[chapter].title)
                    .font(.headline)
                if let error = model.errors[chapter] {
                    Text(error)
                        .font(.footnote)
                    Button("重试") { model.ensureLoaded(chapter) }
                } else {
                    ProgressView()
                }
            }
            .foregroundStyle(Color(uiColor: model.theme.secondary))
            .frame(maxWidth: .infinity, minHeight: 320)
            .contentShape(Rectangle())
            .onTapGesture { model.showsMenu.toggle() }
            .scrollItem(ReaderPosition(chapter: chapter, page: 0))
            .onAppear { model.ensureLoaded(chapter) }
        }
    }
}

private extension View {
    /// 弹出面板的深浅色：SwiftUI 内容和面板本身（系统材质背景）都改
    func readerColorScheme(_ scheme: ColorScheme) -> some View {
        environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
    }
}

/// 阅读器底层背景：纯色，或者铺满的背景图加蒙层（滚动模式下页面透明，看到的就是这一层）
private struct ReaderBackdrop: View {
    let theme: ReaderTheme
    /// 换图后变化，用来刷新
    let version: Int
    let dim: Double

    var body: some View {
        ZStack {
            Color(uiColor: theme.background)
            if theme == .image, let image = ReaderBackground.shared.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(Color(uiColor: ReaderBackground.shared.dimColor))
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 排版设置

struct ReaderSettingsSheet: View {
    @ObservedObject var store: ReaderSettingsStore
    @State private var downloading: ReaderFont?
    @State private var downloadProgress = 0.0
    @State private var downloadFailed = false
    @State private var showPhotoPicker = false
    @State private var showImageFile = false
    @State private var imageError: String?

    private let spacingPresets: [(String, Double, Double)] = [("紧凑", 0.4, 0.3), ("适中", 0.65, 0.5), ("宽松", 0.95, 0.8)]
    private let marginPresets: [(String, Double)] = [("窄", 16), ("中", 24), ("宽", 34)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    stepButton("textformat.size.smaller") { store.settings.fontSize = max(store.settings.fontSize - 1, 13) }
                    Text("\(Int(store.settings.fontSize))")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 40)
                    stepButton("textformat.size.larger") { store.settings.fontSize = min(store.settings.fontSize + 1, 34) }
                    Spacer()
                    Picker("字体", selection: Binding(get: { store.settings.font }, set: { select($0) })) {
                        ForEach(ReaderFont.allCases) { font in
                            Text(font.name).tag(font)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
                if let downloading {
                    ProgressView(value: downloadProgress) {
                        Text("正在下载\(downloading.name)…").font(.caption)
                    }
                } else if downloadFailed {
                    Text("字体下载失败，请检查网络后再试").font(.caption).foregroundStyle(.secondary)
                }

                row("间距") {
                    Picker("间距", selection: Binding(
                        get: { spacingPresets.firstIndex { abs($0.1 - store.settings.lineSpacing) < 0.01 } ?? 1 },
                        set: { i in
                            store.settings.lineSpacing = spacingPresets[i].1
                            store.settings.paragraphSpacing = spacingPresets[i].2
                        }
                    )) {
                        ForEach(spacingPresets.indices, id: \.self) { Text(spacingPresets[$0].0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                row("边距") {
                    Picker("边距", selection: Binding(
                        get: { marginPresets.firstIndex { $0.1 == store.settings.margin } ?? 1 },
                        set: { store.settings.margin = marginPresets[$0].1 }
                    )) {
                        ForEach(marginPresets.indices, id: \.self) { Text(marginPresets[$0].0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                row("翻页") {
                    Picker("翻页", selection: $store.settings.pageMode) {
                        ForEach(ReaderPageMode.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("背景").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        ForEach(ReaderTheme.solid) { theme in
                            Button {
                                store.settings.theme = theme
                            } label: {
                                themeSwatch(theme.name, selected: store.settings.theme == theme) {
                                    Circle()
                                        .fill(Color(uiColor: theme.background))
                                        .overlay(Text("文").font(.callout).foregroundStyle(Color(uiColor: theme.text)))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            if ReaderBackground.shared.hasImage {
                                store.settings.theme = .image
                            } else {
                                showPhotoPicker = true
                            }
                        } label: {
                            themeSwatch("图片", selected: store.settings.theme == .image) {
                                if let image = ReaderBackground.shared.image {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(Color.secondary.opacity(0.12))
                                        .overlay(Image(systemName: "photo.badge.plus").font(.callout).foregroundStyle(.secondary))
                                }
                            }
                            .id(store.settings.imageVersion)
                        }
                        .buttonStyle(.plain)
                    }

                    if store.settings.theme == .image {
                        HStack(spacing: 10) {
                            Button("相册选图", icon: "photo") { showPhotoPicker = true }
                                .glassButtonStyle()
                            Button("文件选图", icon: "folder") { showImageFile = true }
                                .glassButtonStyle()
                            Spacer(minLength: 0)
                        }
                        .controlSize(.small)
                        row("蒙层") {
                            Slider(value: $store.settings.imageDim, in: 0...0.8)
                        }
                        if let imageError {
                            Text(imageError).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .sheet(isPresented: $showPhotoPicker) {
                    PhotoPicker { useImage($0) }
                        .ignoresSafeArea()
                }
                .filePicker(isPresented: $showImageFile, types: [.image]) { data, _ in
                    if let image = UIImage(data: data) {
                        useImage(image)
                    } else {
                        imageError = "这个文件不是能识别的图片"
                    }
                }

                row("点按") {
                    Picker("点按翻页", selection: $store.settings.tapMode) {
                        ForEach(ReaderTapMode.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("音量键翻页（加上一页，减下一页）", isOn: $store.settings.volumeKeys)
                    .selectionFeedback(trigger: store.settings.volumeKeys)
                Toggle("首行缩进", isOn: $store.settings.indent)
                    .selectionFeedback(trigger: store.settings.indent)
                Toggle("两端对齐", isOn: $store.settings.justify)
                    .selectionFeedback(trigger: store.settings.justify)
                Toggle("深色模式时自动切到夜读", isOn: $store.settings.followSystemDark)
            }
            .padding(22)
        }
    }

    private func themeSwatch(_ name: String, selected: Bool, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 6) {
            content()
                .frame(width: 42, height: 42)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 1))
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 换背景图：保存后切到图片主题，并触发重排（文字深浅可能变）
    private func useImage(_ image: UIImage) {
        do {
            try ReaderBackground.shared.save(image)
            imageError = nil
            store.settings.imageVersion += 1
            store.settings.theme = .image
        } catch {
            imageError = "保存图片失败：\(error.localizedDescription)"
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            content()
        }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(width: 44, height: 36)
        }
        .glassButtonStyle()
    }

    private func select(_ font: ReaderFont) {
        downloadFailed = false
        if font.isAvailable {
            store.settings.font = font
            return
        }
        downloading = font
        downloadProgress = 0
        font.download { value in
            Task { @MainActor in downloadProgress = value }
        } completion: { ok in
            Task { @MainActor in
                downloading = nil
                if ok, font.isAvailable { store.settings.font = font } else { downloadFailed = true }
            }
        }
    }
}

// MARK: - 目录

struct NovelTOCSheet: View {
    let chapters: [NovelChapter]
    let current: Int
    let onSelect: (Int) -> Void
    @State private var query = ""
    @State private var reversed = false
    @Environment(\.dismiss) private var dismiss

    private var filtered: [NovelChapter] {
        let list = query.isEmpty ? chapters : chapters.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return reversed ? list.reversed() : list
    }

    var body: some View {
        NavigationStackCompat {
            ScrollViewReader { proxy in
                List(filtered) { chapter in
                    Button {
                        onSelect(chapter.index)
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .font(chapter.isVolume ? .subheadline.weight(.semibold) : .subheadline)
                                .foregroundStyle(chapter.index == current ? Color.accentColor : chapter.isVolume ? Color.secondary : Color.primary)
                                .lineLimit(1)
                            Spacer()
                            if chapter.isVip || chapter.isPay {
                                Image(systemName: "lock").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .id(chapter.index)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .searchable(text: $query, prompt: "搜索章节")
            .navigationTitle("目录 · \(chapters.count) 章")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭", icon: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(reversed ? "正序" : "倒序", icon: "arrow.up.arrow.down") { reversed.toggle() }
                }
            }
        }
    }
}
