import CoreText
import SwiftUI
import UIKit

// MARK: - 阅读设置

enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case white, paper, green, gray, night, black
    /// 自定义背景图（ReaderBackground），文字颜色按图片明暗自动选
    case image

    var id: String { rawValue }

    var name: String {
        switch self {
        case .white: return "素白"
        case .paper: return "宣纸"
        case .green: return "竹青"
        case .gray: return "烟灰"
        case .night: return "夜读"
        case .black: return "墨黑"
        case .image: return "图片"
        }
    }

    var background: UIColor {
        switch self {
        case .white: return UIColor(red: 0.99, green: 0.99, blue: 0.98, alpha: 1)
        case .paper: return UIColor(red: 0.957, green: 0.925, blue: 0.851, alpha: 1)
        case .green: return UIColor(red: 0.812, green: 0.890, blue: 0.808, alpha: 1)
        case .gray: return UIColor(red: 0.886, green: 0.886, blue: 0.894, alpha: 1)
        case .night: return UIColor(red: 0.110, green: 0.114, blue: 0.125, alpha: 1)
        case .black: return .black
        case .image: return ReaderBackground.shared.baseColor
        }
    }

    var text: UIColor {
        switch self {
        case .white: return UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        case .paper: return UIColor(red: 0.247, green: 0.208, blue: 0.157, alpha: 1)
        case .green: return UIColor(red: 0.137, green: 0.212, blue: 0.137, alpha: 1)
        case .gray: return UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1)
        case .night: return UIColor(red: 0.62, green: 0.62, blue: 0.60, alpha: 1)
        case .black: return UIColor(red: 0.45, green: 0.45, blue: 0.44, alpha: 1)
        case .image: return isDark ? UIColor(white: 0.93, alpha: 1) : UIColor(white: 0.1, alpha: 1)
        }
    }

    var secondary: UIColor { text.withAlphaComponent(isDark ? 0.62 : 0.5) }

    var isDark: Bool {
        switch self {
        case .night, .black: return true
        case .image: return ReaderBackground.shared.isDark
        default: return false
        }
    }

    /// 内置的纯色主题（设置里的色块）
    static var solid: [ReaderTheme] { allCases.filter { $0 != .image } }

    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

enum ReaderFont: String, Codable, CaseIterable, Identifiable {
    case system, songti, kaiti

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "苹方"
        case .songti: return "宋体"
        case .kaiti: return "楷体"
        }
    }

    /// 宋体、楷体是系统的可下载字体
    var postScriptName: String? {
        switch self {
        case .system: return nil
        case .songti: return "STSongti-SC-Regular"
        case .kaiti: return "STKaitiSC-Regular"
        }
    }

    var isAvailable: Bool {
        guard let name = postScriptName else { return true }
        return UIFont(name: name, size: 12) != nil
    }

    func font(size: CGFloat, bold: Bool = false) -> UIFont {
        if let name = postScriptName, let font = UIFont(name: name, size: size) {
            if bold, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return font
        }
        return UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// 下载系统字体（第一次选择宋体 / 楷体时）
    func download(progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Bool) -> Void) {
        guard let name = postScriptName else { return completion(true) }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute as String: name] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { state, info in
            switch state {
            case .didFinish:
                completion(true)
            case .didFailWithError:
                completion(false)
            case .downloading:
                let dict = info as NSDictionary
                if let value = dict[kCTFontDescriptorMatchingPercentage as String] as? Double { progress(value / 100) }
            default:
                break
            }
            return true
        }
    }
}

enum ReaderPageMode: String, Codable, CaseIterable, Identifiable {
    case curl, slide, scroll

    var id: String { rawValue }

    var name: String {
        switch self {
        case .curl: return "仿真"
        case .slide: return "平移"
        case .scroll: return "滚动"
        }
    }
}

/// 点按屏幕左右两侧时怎么翻页（中间始终是呼出菜单）
enum ReaderTapMode: String, Codable, CaseIterable, Identifiable {
    /// 左边上一页，右边下一页
    case sides
    /// 两边都是下一页（单手阅读）
    case forward
    /// 不翻页，点哪里都是呼出菜单
    case off

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sides: return "左上右下"
        case .forward: return "都下一页"
        case .off: return "关闭"
        }
    }
}

struct ReaderSettings: Codable, Equatable {
    var fontSize: Double = 19
    /// 行间距、段间距都按字号的倍数
    var lineSpacing: Double = 0.65
    var paragraphSpacing: Double = 0.5
    var margin: Double = 24
    var theme: ReaderTheme = .paper
    var font: ReaderFont = .system
    var pageMode: ReaderPageMode = .curl
    var indent = true
    var justify = true

    /// 跟着系统深色模式切到夜读
    var followSystemDark = true
    /// 背景图上蒙一层（0 不蒙 ~ 0.8），让文字更清楚
    var imageDim: Double = 0.25
    /// 换了背景图时加 1，用来触发重排（文字颜色可能变）
    var imageVersion = 0
    /// 点按两侧翻页
    var tapMode: ReaderTapMode = .sides
    /// 音量键翻页（加大上一页、减小下一页）
    var volumeKeys = false

    init() {}

    /// 逐项读取：以后加了新设置项，旧版本存的设置也能读出来，不会整个重置
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderSettings()
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
        lineSpacing = (try? c.decodeIfPresent(Double.self, forKey: .lineSpacing)) ?? d.lineSpacing
        paragraphSpacing = (try? c.decodeIfPresent(Double.self, forKey: .paragraphSpacing)) ?? d.paragraphSpacing
        margin = (try? c.decodeIfPresent(Double.self, forKey: .margin)) ?? d.margin
        theme = (try? c.decodeIfPresent(ReaderTheme.self, forKey: .theme)) ?? d.theme
        font = (try? c.decodeIfPresent(ReaderFont.self, forKey: .font)) ?? d.font
        pageMode = (try? c.decodeIfPresent(ReaderPageMode.self, forKey: .pageMode)) ?? d.pageMode
        indent = (try? c.decodeIfPresent(Bool.self, forKey: .indent)) ?? d.indent
        justify = (try? c.decodeIfPresent(Bool.self, forKey: .justify)) ?? d.justify
        followSystemDark = (try? c.decodeIfPresent(Bool.self, forKey: .followSystemDark)) ?? d.followSystemDark
        imageDim = (try? c.decodeIfPresent(Double.self, forKey: .imageDim)) ?? d.imageDim
        imageVersion = (try? c.decodeIfPresent(Int.self, forKey: .imageVersion)) ?? d.imageVersion
        tapMode = (try? c.decodeIfPresent(ReaderTapMode.self, forKey: .tapMode)) ?? d.tapMode
        volumeKeys = (try? c.decodeIfPresent(Bool.self, forKey: .volumeKeys)) ?? d.volumeKeys
    }
}

/// 阅读器自定义背景图：存在 Application Support/Novel/reader-background.jpg（会进备份）。
/// 按图片平均亮度和蒙层决定文字用深色还是浅色
final class ReaderBackground {
    static let shared = ReaderBackground()

    private(set) var image: UIImage?
    /// 图片的平均色（翻页控件的底色、图片没铺到的地方）
    private(set) var averageColor = UIColor(white: 0.5, alpha: 1)
    private var averageIsDark = false
    /// 蒙层浓度（来自阅读设置）
    var dim: Double = 0.25

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Novel", isDirectory: true)
            .appendingPathComponent("reader-background.jpg")
    }

    private init() {
        reload()
    }

    var hasImage: Bool { image != nil }

    /// 蒙层颜色：暗图蒙黑、亮图蒙白，越蒙文字越清楚
    var dimColor: UIColor {
        (averageIsDark ? UIColor.black : UIColor.white).withAlphaComponent(CGFloat(min(max(dim, 0), 0.85)))
    }

    var isDark: Bool { image == nil ? false : averageIsDark }

    /// 平均色叠上蒙层后的颜色
    var baseColor: UIColor {
        guard image != nil else { return ReaderTheme.paper.background }
        return averageColor.mixed(with: averageIsDark ? .black : .white, CGFloat(min(max(dim, 0), 0.85)))
    }

    func reload() {
        guard let data = try? Data(contentsOf: Self.fileURL), let loaded = UIImage(data: data) else {
            image = nil
            return
        }
        image = loaded
        averageColor = Self.average(of: loaded)
        var white: CGFloat = 0
        averageColor.getWhite(&white, alpha: nil)
        averageIsDark = white < 0.5
    }

    /// 保存：长边缩到 2400 像素以内，存成 JPEG
    func save(_ source: UIImage) throws {
        let maxSide: CGFloat = 2400
        let size = source.size
        let scale = min(1, maxSide / max(size.width * source.scale, size.height * source.scale))
        let target = CGSize(width: (size.width * source.scale * scale).rounded(), height: (size.height * source.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.86) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.fileURL, options: .atomic)
        reload()
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        reload()
    }

    /// 铺满（按比例裁切）画到矩形里，再蒙一层
    func draw(in rect: CGRect) {
        guard let image else { return }
        let size = image.size
        let scale = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        UIGraphicsGetCurrentContext()?.saveGState()
        UIRectClip(rect)
        image.draw(in: CGRect(origin: origin, size: drawSize))
        dimColor.setFill()
        UIRectFillUsingBlendMode(rect, .normal)
        UIGraphicsGetCurrentContext()?.restoreGState()
    }

    private static func average(of image: UIImage) -> UIColor {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard let cg = pixel.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return UIColor(white: 0.5, alpha: 1)
        }
        let isBGRA = cg.bitmapInfo.contains(.byteOrder32Little)
        let r = CGFloat(bytes[isBGRA ? 2 : 0]) / 255, g = CGFloat(bytes[1]) / 255, b = CGFloat(bytes[isBGRA ? 0 : 2]) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}

@MainActor
final class ReaderSettingsStore: ObservableObject {
    static let shared = ReaderSettingsStore()
    private static let key = "novelReaderSettings"

    @Published var settings: ReaderSettings {
        didSet {
            ReaderBackground.shared.dim = settings.imageDim
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let value = try? JSONDecoder().decode(ReaderSettings.self, from: data) {
            settings = value
        } else {
            settings = ReaderSettings()
        }
        ReaderBackground.shared.dim = settings.imageDim
    }

    /// 从备份恢复后重新读设置
    func reload() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let value = try? JSONDecoder().decode(ReaderSettings.self, from: data), value != settings {
            settings = value
        }
    }
}

// MARK: - 排版

/// 一章排好的版：同一个 NSLayoutManager，每页一个 NSTextContainer（TextKit 负责断行、两端对齐、避头尾）
final class ChapterLayout {
    struct Page {
        let index: Int
        let container: NSTextContainer
        let glyphRange: NSRange
        let charRange: NSRange
        let usedHeight: CGFloat
    }

    let chapter: Int
    let title: String
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let pages: [Page]
    let length: Int

    init(chapter: Int, title: String, storage: NSTextStorage, manager: NSLayoutManager, pages: [Page]) {
        self.chapter = chapter
        self.title = title
        self.storage = storage
        self.manager = manager
        self.pages = pages
        length = storage.length
    }

    func page(containing offset: Int) -> Int {
        guard let index = pages.lastIndex(where: { $0.charRange.location <= offset }) else { return 0 }
        return index
    }

    func draw(page index: Int, at origin: CGPoint) {
        guard pages.indices.contains(index) else { return }
        let range = pages[index].glyphRange
        manager.drawBackground(forGlyphRange: range, at: origin)
        manager.drawGlyphs(forGlyphRange: range, at: origin)
    }
}

enum ReaderPaginator {
    struct Metrics: Equatable {
        var size: CGSize
        var insets: UIEdgeInsets

        var textSize: CGSize {
            CGSize(width: max(size.width - insets.left - insets.right, 100),
                   height: max(size.height - insets.top - insets.bottom, 100))
        }
    }

    static func attributed(title: String, text: String, settings: ReaderSettings, theme: ReaderTheme) -> NSAttributedString {
        let size = CGFloat(settings.fontSize)
        let body = settings.font.font(size: size)
        let titleFont = settings.font.font(size: (size * 1.32).rounded(), bold: true)

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineSpacing = size * 0.35
        titleStyle.paragraphSpacing = size * 1.5
        titleStyle.alignment = .natural
        titleStyle.lineBreakMode = .byWordWrapping

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = size * CGFloat(settings.lineSpacing)
        bodyStyle.paragraphSpacing = size * CGFloat(settings.paragraphSpacing)
        bodyStyle.firstLineHeadIndent = settings.indent ? size * 2 : 0
        bodyStyle.alignment = settings.justify ? .justified : .natural
        bodyStyle.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString(string: title + "\n", attributes: [
            .font: titleFont, .foregroundColor: theme.text, .paragraphStyle: titleStyle,
        ])
        result.append(NSAttributedString(string: text, attributes: [
            .font: body, .foregroundColor: theme.text, .paragraphStyle: bodyStyle,
            .kern: size * 0.02,
        ]))
        return result
    }

    static func layout(chapter: Int, title: String, text: String, metrics: Metrics, settings: ReaderSettings, theme: ReaderTheme) -> ChapterLayout {
        let storage = NSTextStorage(attributedString: attributed(title: title, text: text, settings: settings, theme: theme))
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        storage.addLayoutManager(manager)
        var pages: [ChapterLayout.Page] = []
        let size = metrics.textSize
        while pages.count < 2000 {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let glyphRange = manager.glyphRange(for: container)
            if glyphRange.length == 0 { break }
            let charRange = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let used = manager.usedRect(for: container).height
            pages.append(ChapterLayout.Page(index: pages.count, container: container, glyphRange: glyphRange, charRange: charRange, usedHeight: used))
            if NSMaxRange(glyphRange) >= manager.numberOfGlyphs { break }
        }
        return ChapterLayout(chapter: chapter, title: title, storage: storage, manager: manager, pages: pages)
    }
}

// MARK: - 单页

/// 页面内容：页眉（章节名）、正文、页脚（页码 / 时间 / 进度）
final class ReaderPageView: UIView {
    struct Content {
        var layout: ChapterLayout?
        var page: Int
        var header: String
        var footerLeft: String
        var footerRight: String
        var message: String?
        var loading = false
    }

    var content: Content? { didSet { setNeedsDisplay(); updateSpinner() } }
    var theme: ReaderTheme = .paper { didSet { updateBackground(); setNeedsDisplay() } }
    var insets: UIEdgeInsets = .zero { didSet { setNeedsDisplay() } }
    /// 滚动模式下不画页眉页脚
    var showsChrome = true
    /// 滚动模式下页面透明，背景（颜色或图片）由外层统一铺，不然图片会一页一页重复
    var drawsBackground = true { didSet { updateBackground(); setNeedsDisplay() } }

    private func updateBackground() {
        isOpaque = drawsBackground
        backgroundColor = drawsBackground ? theme.background : .clear
    }

    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        spinner.hidesWhenStopped = true
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY + 30)
    }

    private func updateSpinner() {
        spinner.color = theme.secondary
        if content?.loading == true { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    override func draw(_ rect: CGRect) {
        if drawsBackground {
            theme.background.setFill()
            UIRectFill(bounds)
            if theme == .image { ReaderBackground.shared.draw(in: bounds) }
        }
        guard let content else { return }
        let small: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: theme.secondary,
        ]
        if showsChrome {
            let headerRect = CGRect(x: insets.left, y: max(insets.top - 30, 8), width: bounds.width - insets.left - insets.right, height: 16)
            (content.header as NSString).draw(with: headerRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: small, context: nil)
            let footerY = bounds.height - insets.bottom + 10
            (content.footerLeft as NSString).draw(at: CGPoint(x: insets.left, y: footerY), withAttributes: small)
            let right = content.footerRight as NSString
            let width = right.size(withAttributes: small).width
            right.draw(at: CGPoint(x: bounds.width - insets.right - width, y: footerY), withAttributes: small)
        }
        if let layout = content.layout {
            layout.draw(page: content.page, at: CGPoint(x: insets.left, y: showsChrome ? insets.top : 0))
        } else if let message = content.message {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineSpacing = 6
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 15), .foregroundColor: theme.secondary, .paragraphStyle: style,
            ]
            let box = CGRect(x: insets.left, y: bounds.midY - 60, width: bounds.width - insets.left - insets.right, height: 80)
            (message as NSString).draw(with: box, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        }
    }
}

final class ReaderPageController: UIViewController {
    let position: ReaderPosition
    let pageView = ReaderPageView()

    init(position: ReaderPosition) {
        self.position = position
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = pageView
    }
}

/// 阅读位置：第几章第几页；page = -1 表示「这一章的最后一页」（章节还没排版时用）
struct ReaderPosition: Equatable, Hashable {
    var chapter: Int
    var page: Int
}

// MARK: - 翻页（仿真 / 平移）

struct ReaderPager: UIViewControllerRepresentable {
    @ObservedObject var model: NovelReaderModel
    let mode: ReaderPageMode

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: mode == .curl ? .pageCurl : .scroll,
            navigationOrientation: .horizontal,
            options: mode == .slide ? [.interPageSpacing: 0] : nil
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.isDoubleSided = false
        pager.view.backgroundColor = model.theme.background
        // 仿真翻页自带的点按翻页关掉，统一用自己的点按区域
        for recognizer in pager.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.isEnabled = false
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        pager.view.addGestureRecognizer(tap)
        context.coordinator.pager = pager
        context.coordinator.reset()
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        pager.view.backgroundColor = model.theme.background
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let model: NovelReaderModel
        weak var pager: UIPageViewController?
        private var revision = -1
        private var contentRevision = -1
        private var turnID = 0

        init(model: NovelReaderModel) {
            self.model = model
        }

        func controller(for position: ReaderPosition) -> ReaderPageController {
            let resolved = model.resolve(position)
            let controller = ReaderPageController(position: resolved)
            controller.pageView.theme = model.theme
            controller.pageView.insets = model.metrics.insets
            controller.pageView.content = model.content(for: resolved)
            return controller
        }

        func reset() {
            turnID = model.turnRequest.id
            revision = model.revision
            contentRevision = model.contentRevision
            pager?.setViewControllers([controller(for: model.position)], direction: .forward, animated: false)
        }

        /// 设置变化重排版时整页重建；当前页是占位页（章节还在加载）时，加载完换成正文
        func sync() {
            guard let pager else { return }
            if turnID != model.turnRequest.id {
                turnID = model.turnRequest.id
                turn(forward: model.turnRequest.forward)
            }
            if revision != model.revision {
                reset()
                return
            }
            if contentRevision != model.contentRevision {
                contentRevision = model.contentRevision
                if let current = pager.viewControllers?.first as? ReaderPageController {
                    let resolved = model.resolve(current.position)
                    if resolved != current.position || current.pageView.content?.layout == nil {
                        pager.setViewControllers([controller(for: resolved)], direction: .forward, animated: false)
                        let model = model
                        DispatchQueue.main.async { model.didShow(resolved) }
                    } else {
                        current.pageView.content = model.content(for: resolved)
                    }
                }
            }
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? ReaderPageController,
                  let target = model.position(before: current.position) else { return nil }
            return controller(for: target)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? ReaderPageController,
                  let target = model.position(after: current.position) else { return nil }
            return controller(for: target)
        }

        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            if model.showsMenu { model.showsMenu = false }
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pageViewController.viewControllers?.first as? ReaderPageController else { return }
            model.didShow(current.position)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            if model.showsMenu {
                model.showsMenu = false
                return
            }
            switch model.tapAction(x: recognizer.location(in: view).x / max(view.bounds.width, 1)) {
            case .previous: turn(forward: false)
            case .next: turn(forward: true)
            case .menu: model.showsMenu = true
            }
        }

        func turn(forward: Bool) {
            guard let pager, let current = pager.viewControllers?.first as? ReaderPageController else { return }
            let target = forward ? model.position(after: current.position) : model.position(before: current.position)
            guard let target else { return }
            let next = controller(for: target)
            let isScroll = pager.transitionStyle == .scroll
            pager.setViewControllers([next], direction: forward ? .forward : .reverse, animated: true) { [weak self, weak pager] done in
                guard let self else { return }
                if isScroll, done {
                    // UIPageViewController 滚动模式的缓存问题：动画结束后再无动画设置一次
                    DispatchQueue.main.async {
                        pager?.setViewControllers([next], direction: .forward, animated: false)
                    }
                }
                self.model.didShow(next.position)
            }
        }
    }
}

// MARK: - 滚动模式的一页

struct ReaderScrollPage: UIViewRepresentable {
    let layout: ChapterLayout
    let page: Int
    let theme: ReaderTheme
    let margin: CGFloat
    /// 点按：参数是点按位置在页面宽度上的比例（0 左 ~ 1 右）
    var onTap: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ReaderPageView {
        let view = ReaderPageView()
        view.showsChrome = false
        view.drawsBackground = false
        // 用 UIKit 的点按识别：和滚动不冲突，还能拿到点按位置（iOS 15 的 SwiftUI 点按拿不到）
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        return view
    }

    final class Coordinator: NSObject {
        var onTap: (CGFloat) -> Void = { _ in }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            onTap(recognizer.location(in: view).x / max(view.bounds.width, 1))
        }
    }

    func updateUIView(_ view: ReaderPageView, context: Context) {
        context.coordinator.onTap = onTap
        view.theme = theme
        view.insets = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
        view.content = ReaderPageView.Content(layout: layout, page: page, header: "", footerLeft: "", footerRight: "")
    }
}
