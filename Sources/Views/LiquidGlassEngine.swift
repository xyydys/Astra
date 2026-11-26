import ObjectiveC
import SwiftUI
import UIKit

// MARK: - 玻璃深浅策略（参考 xyydy：高阈值深色通透，极浅页面才切浅色）

/// 液态玻璃的基准深浅倾向：
/// - `dark`：以深色通透玻璃为起点（xyydy 顶栏的高阈值体验，只有背后极亮时才由系统翻浅）
/// - `light`：直接起步为浅色玻璃
/// - `system`：跟随系统浅色/深色模式
enum AstraGlassTone: Equatable, Hashable {
    case dark
    case light
    case system

    func resolvedUIStyle(system: UIUserInterfaceStyle) -> UIUserInterfaceStyle {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return system == .dark ? .dark : .light
        }
    }
}

enum AstraGlassCorner: Equatable {
    case capsule
    case circle
    case roundedRect(CGFloat)
}

// MARK: - iOS 26 滚动边登记（xyydy "登记不画"）

@available(iOS 26.0, *)
@MainActor
enum AstraGlassEdge {
    private static var interactionKey: UInt8 = 0

    /// 构造一条不可交互、透明、隐藏全部四条边缘模糊效果的滚动边。
    /// 边的 `overrideUserInterfaceStyle` 决定 UIKit 亮度口袋的起点与滞回偏向：
    /// 设成 `.dark` 时玻璃默认保持深色通透，只有背后画面极亮（> ~0.7 亮度）才切浅色并自动翻黑字。
    static func makeEdgeScrollView(style: UIUserInterfaceStyle = .dark) -> UIScrollView {
        let scroll = UIScrollView(frame: .zero)
        scroll.isUserInteractionEnabled = false
        scroll.isScrollEnabled = false
        scroll.scrollsToTop = false
        scroll.backgroundColor = .clear
        scroll.isOpaque = false
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.isAccessibilityElement = false
        scroll.accessibilityElementsHidden = true
        scroll.overrideUserInterfaceStyle = style
        hideAllEdgeEffects(of: scroll)
        return scroll
    }

    static func hideAllEdgeEffects(of scrollView: UIScrollView) {
        scrollView.topEdgeEffect.isHidden = true
        scrollView.leftEdgeEffect.isHidden = true
        scrollView.bottomEdgeEffect.isHidden = true
        scrollView.rightEdgeEffect.isHidden = true
    }

    static func hideEdgeEffect(of scrollView: UIScrollView, edge: UIRectEdge) {
        if edge.contains(.top) { scrollView.topEdgeEffect.isHidden = true }
        if edge.contains(.left) { scrollView.leftEdgeEffect.isHidden = true }
        if edge.contains(.bottom) { scrollView.bottomEdgeEffect.isHidden = true }
        if edge.contains(.right) { scrollView.rightEdgeEffect.isHidden = true }
    }

    /// 把视图登记为滚动视图的边缘元素容器，同时隐藏该边自身的边缘模糊（登记不画）。
    static func register(_ view: UIView, scrollView: UIScrollView?, edge: UIRectEdge = .left) {
        let existing = objc_getAssociatedObject(view, &interactionKey) as? UIScrollEdgeElementContainerInteraction
        guard let scrollView else {
            if let existing {
                view.removeInteraction(existing)
                objc_setAssociatedObject(view, &interactionKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            return
        }
        hideEdgeEffect(of: scrollView, edge: edge)
        if let existing {
            if existing.scrollView !== scrollView || existing.edge != edge {
                view.removeInteraction(existing)
                let replacement = UIScrollEdgeElementContainerInteraction()
                replacement.scrollView = scrollView
                replacement.edge = edge
                view.addInteraction(replacement)
                objc_setAssociatedObject(view, &interactionKey, replacement, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            return
        }
        let interaction = UIScrollEdgeElementContainerInteraction()
        interaction.scrollView = scrollView
        interaction.edge = edge
        view.addInteraction(interaction)
        objc_setAssociatedObject(view, &interactionKey, interaction, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

// MARK: - iOS 26 导航栏实体玻璃池

/// 从系统原生 UINavigationBar 的玻璃承载视图抓取实体化的 `_UIViewGlass`
///（smoothness 6.0，真正跟随系统「透明 / 着色」档位），分发给播放器 HUD 等面板玻璃。
@available(iOS 26.0, *)
@MainActor
final class AstraGlassMaterialPool {
    static let shared = AstraGlassMaterialPool()
    static let didUpdateNotification = Notification.Name("AstraGlassMaterialPoolDidUpdate")

    private static let backgroundSelector = Selector(("_background"))
    private static let effectWithGlassSelector = Selector(("effectWithGlass:"))
    private static let copyWithZoneSelector = Selector(("copyWithZone:"))
    private static let setInteractiveSelector = Selector(("setInteractive:"))
    private static let addressRegex = try? NSRegularExpression(pattern: "0x[0-9a-fA-F]+")

    private typealias ObjectGetterIMP = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias EffectWithGlassIMP = @convention(c) (AnyClass, Selector, AnyObject) -> Unmanaged<AnyObject>?

    private var navGlass: AnyObject?
    private var navGlassKey = ""
    private var generation: Int = 0
    private var observersInstalled = false

    private init() {
        installObserversIfNeeded()
    }

    var currentGeneration: Int { generation }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        for name in [
            UIApplication.didBecomeActiveNotification,
            UIAccessibility.reduceTransparencyStatusDidChangeNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.invalidate()
                }
            }
        }
    }

    /// 刷新时保留上一份有效材质，直到导航栏重新采样。
    /// 否则回前台的这一帧会把可见控件改回 regular，并可能一直停留在那里。
    private func invalidate() {
        navGlassKey = ""
    }

    /// 从可见的 UINavigationBar 栏按钮抓取玻璃。
    func captureFromNavigationBar(_ bar: UINavigationBar) {
        guard bar.window != nil else { return }
        var queue: [UIView] = [bar]
        var bestGlass: AnyObject?
        var bestArea: CGFloat = 0
        var index = 0
        while index < queue.count && index < 200 {
            let view = queue[index]
            index += 1
            let name = NSStringFromClass(type(of: view))
            if Self.isLensClassName(name) { continue }
            if (name.contains("Platter") || name.contains("Glass")),
               !view.isHidden, view.alpha >= 0.01, view.window != nil {
                let area = view.bounds.width * view.bounds.height
                if area > bestArea, let glass = Self.realizedGlass(from: view) {
                    bestGlass = glass
                    bestArea = area
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        guard let bestGlass else { return }
        let key = Self.glassSignature(bestGlass)
        if navGlassKey != key {
            navGlass = Self.copyGlass(bestGlass)
            navGlassKey = key
            bumpGeneration()
        }
    }

    /// 使用导航栏材质；没有样本时用系统常规 UIGlassEffect(.regular)。
    func makeBarMatchedEffect(interactive: Bool) -> UIVisualEffect {
        if let source = navGlass,
           let method = class_getClassMethod(UIGlassEffect.self, Self.effectWithGlassSelector),
           method_getNumberOfArguments(method) == 3,
           Self.returnsObject(method) {
            let copied = Self.copyGlass(source)
            let imp = unsafeBitCast(method_getImplementation(method), to: EffectWithGlassIMP.self)
            if let effect = imp(UIGlassEffect.self, Self.effectWithGlassSelector, copied)?.takeUnretainedValue() as? UIVisualEffect {
                if interactive,
                   let glassEffect = effect as? UIGlassEffect,
                   glassEffect.responds(to: Self.setInteractiveSelector) {
                    glassEffect.isInteractive = true
                }
                return effect
            }
        }
        let fallback = UIGlassEffect(style: .regular)
        fallback.isInteractive = interactive
        return fallback
    }

    private func bumpGeneration() {
        generation += 1
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    private static func isLensClassName(_ name: String) -> Bool {
        name.contains("Lens")
            || name.contains("SelectedContent")
            || name.contains("Selection")
            || name.contains("DestOut")
            || name.contains("Portal")
            || name.contains("Lifted")
    }

    private static func returnsObject(_ method: Method) -> Bool {
        var returnType = [CChar](repeating: 0, count: 8)
        method_getReturnType(method, &returnType, returnType.count)
        return returnType[0] == CChar(UInt8(ascii: "@"))
    }

    private static func realizedGlass(from view: UIView) -> AnyObject? {
        guard let cls: AnyClass = object_getClass(view),
              let method = class_getInstanceMethod(cls, backgroundSelector),
              method_getNumberOfArguments(method) == 2,
              returnsObject(method)
        else { return nil }
        let imp = unsafeBitCast(method_getImplementation(method), to: ObjectGetterIMP.self)
        guard let raw = imp(view, backgroundSelector)?.takeUnretainedValue() else { return nil }
        let name = NSStringFromClass(type(of: raw))
        guard name.contains("ViewGlass"), !name.contains("Group") else { return nil }
        return raw
    }

    /// 参考 xyydy ALBGlassCopy：必须检查 `copyWithZone:`（所有 NSObject 都响应 `copy`，但 `_UIViewGlass` 未实现 `NSCopying`）
    private static func copyGlass(_ glass: AnyObject) -> AnyObject {
        guard let copying = glass as? NSCopying,
              let object = glass as? NSObject,
              object.responds(to: copyWithZoneSelector)
        else { return glass }
        return copying.copy(with: nil) as AnyObject
    }

    private static func glassSignature(_ glass: AnyObject) -> String {
        let raw = String(describing: glass)
        guard let regex = addressRegex else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "0x?")
    }
}

// MARK: - iOS 26 单项导航栏玻璃按钮（xyydy ALB3BarGlassButton 完整移植）

@available(iOS 26.0, *)
private func astraClearNavigationBar(_ bar: UINavigationBar) {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = .clear
    appearance.backgroundEffect = nil
    appearance.shadowColor = .clear
    bar.standardAppearance = appearance
    bar.compactAppearance = appearance
    bar.scrollEdgeAppearance = appearance
    bar.compactScrollEdgeAppearance = appearance
    bar.setBackgroundImage(UIImage(), for: .default)
    bar.shadowImage = UIImage()
    bar.barTintColor = nil
    bar.isTranslucent = true
    bar.backgroundColor = .clear
}

@available(iOS 26.0, *)
private final class AstraItemOnlyNavigationBar: UINavigationBar {
    override init(frame: CGRect) {
        super.init(frame: frame)
        astraClearNavigationBar(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { astraClearNavigationBar(self) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

@available(iOS 26.0, *)
private enum AstraBarGlassMeasure {
    static let nominalGlass: CGFloat = 44
    /// UIKit 原生栏按钮胶囊在图片左右自带约 8.5pt 视觉内边距（按目标高度缩放后）
    static let nativePillSideInset: CGFloat = 8.5

    static func controls(in root: UIView) -> [UIView] {
        var result: [UIView] = []
        var queue: [UIView] = [root]
        var index = 0
        while index < queue.count && index < 240 && result.count < 4 {
            let view = queue[index]
            index += 1
            if view !== root,
               view is UIControl,
               !view.bounds.isEmpty,
               view.bounds.width < root.bounds.width * 0.9 {
                result.append(view)
                continue
            }
            queue.append(contentsOf: view.subviews)
        }
        return result
    }

    static func glassFrame(around control: UIView, in bar: UIView) -> (frame: CGRect, isEstimated: Bool) {
        let controlFrame = control.convert(control.bounds, to: bar)
        var best = CGRect.null
        var ownBest = CGRect.null
        var queue: [UIView] = [bar]
        var index = 0
        while index < queue.count && index < 320 {
            let view = queue[index]
            index += 1
            queue.append(contentsOf: view.subviews)
            if view === bar || view === control || view.isHidden || view.alpha < 0.01 { continue }
            let name = NSStringFromClass(type(of: view))
            guard view is UIVisualEffectView || name.contains("Glass") || name.contains("Platter"),
                  !name.contains("Shadow")
            else { continue }
            let frame = view.convert(view.bounds, to: bar)
            guard frame.width >= controlFrame.width + 1, frame.height >= controlFrame.height + 1,
                  frame.width <= controlFrame.width + 28, frame.height <= controlFrame.height + 28,
                  abs(frame.midX - controlFrame.midX) < 3, abs(frame.midY - controlFrame.midY) < 3
            else { continue }
            if best.isNull || frame.width * frame.height > best.width * best.height {
                best = frame
            }
            if name.contains("PlatterGlassView"),
               ownBest.isNull || frame.width * frame.height > ownBest.width * ownBest.height {
                ownBest = frame
            }
        }
        if !ownBest.isNull { return (ownBest, false) }
        if !best.isNull { return (best, false) }
        let outset = max(0, (nominalGlass - controlFrame.height) / 2)
        return (controlFrame.insetBy(dx: -outset, dy: -outset), true)
    }

    /// 渲染 [图标] 文字 [小箭头] 胶囊模板图，左右补足到原版 SwiftUI 胶囊的舒展水平内边距；
    /// 模板图由 UIKit 栏按钮按背后深浅自动着色（深色玻璃白字、极亮翻浅时黑字）。
    static func renderPillGlyph(
        symbol: String?,
        title: String,
        showsChevron: Bool,
        fontSize: CGFloat,
        iconPointSize: CGFloat,
        horizontalPadding: CGFloat,
        layoutScale: CGFloat,
        renderScale: CGFloat,
        displayScale: CGFloat,
        monospacedDigits: Bool
    ) -> UIImage {
        let scale = max(0.3, layoutScale)
        let render = max(0.3, renderScale)
        let baseFont = UIFont.systemFont(ofSize: fontSize / scale, weight: .semibold)
        let font: UIFont
        if monospacedDigits {
            let desc = baseFont.fontDescriptor.addingAttributes([
                .featureSettings: [[
                    UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector
                ]]
            ])
            font = UIFont(descriptor: desc, size: baseFont.pointSize)
        } else {
            font = baseFont
        }
        let spacing = 6.0 / scale
        let chevronSpacing = 5.0 / scale
        // UIKit 自带约 8.5pt 左右留白；补足到原版胶囊的 horizontalPadding（如 14pt），还原修长胶囊比例
        let extraSide = max(0, horizontalPadding - nativePillSideInset) / scale

        let leadingImage: UIImage? = symbol.flatMap { name in
            let config = UIImage.SymbolConfiguration(pointSize: iconPointSize / scale, weight: .semibold)
            return AstraGlyph.image(name, pointSize: iconPointSize / scale, withConfiguration: config)?
                .withTintColor(.black, renderingMode: .alwaysOriginal)
        }
        let chevronImage: UIImage? = showsChevron ? {
            let config = UIImage.SymbolConfiguration(pointSize: (fontSize * 0.62) / scale, weight: .bold)
            return AstraGlyph.image("chevron.down", pointSize: (fontSize * 0.62) / scale, withConfiguration: config)?
                .withTintColor(.black, renderingMode: .alwaysOriginal)
        }() : nil

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        let rawTextSize = title.isEmpty ? .zero : text.size(withAttributes: attributes)
        let maxTextWidth = 200.0 / scale
        let textSize = CGSize(width: min(rawTextSize.width, maxTextWidth), height: rawTextSize.height)

        var contentWidth: CGFloat = 0
        var maxHeight: CGFloat = textSize.height
        if let leadingImage {
            contentWidth += leadingImage.size.width
            maxHeight = max(maxHeight, leadingImage.size.height)
            if !title.isEmpty { contentWidth += spacing }
        }
        contentWidth += textSize.width
        if let chevronImage {
            if contentWidth > 0 { contentWidth += chevronSpacing }
            contentWidth += chevronImage.size.width
            maxHeight = max(maxHeight, chevronImage.size.height)
        }

        let sidePad = extraSide + 1
        let size = CGSize(width: max(1, ceil(contentWidth + sidePad * 2)), height: max(1, ceil(maxHeight) + 2))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = max(1, displayScale * render)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            var x = sidePad
            let midY = size.height / 2
            if let leadingImage {
                let y = midY - leadingImage.size.height / 2
                leadingImage.draw(at: CGPoint(x: x, y: y))
                x += leadingImage.size.width + (title.isEmpty ? 0 : spacing)
            }
            if !title.isEmpty {
                let y = midY - textSize.height / 2
                let rect = CGRect(x: x, y: y, width: ceil(textSize.width), height: ceil(textSize.height))
                text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
                x += textSize.width
            }
            if let chevronImage {
                if x > sidePad { x += chevronSpacing }
                let y = midY - chevronImage.size.height / 2 + (0.5 / scale)
                chevronImage.draw(at: CGPoint(x: x, y: y))
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// 真正的 iOS 26 导航栏单项玻璃按钮容器（移植自 xyydy `ALB3BarGlassButton`）：
/// - 底层一条同 frame 的暗色透明 UIScrollView 滚动边（登记不画），赋予 xyydy 同款极高变浅阈值
/// - 上层独立透明 UINavigationBar + 单个 UIBarButtonItem，渲染原生 `_UINavigationBarPlatterGlassView`
/// - 圆形按钮带 xyydy 同款 `shrink` 收敛循环，确保宽 SF Symbol 不会把正圆拉成椭圆
/// - 胶囊按钮按目标高度与水平内边距精准还原原版修长比例
@available(iOS 26.0, *)
final class AstraBarGlassButtonView: UIView {
    enum Content: Equatable {
        case icon(systemName: String, pointSize: CGFloat, weight: UIImage.SymbolWeight, diameter: CGFloat)
        case pill(
            symbol: String?,
            title: String,
            showsChevron: Bool,
            fontSize: CGFloat,
            iconSize: CGFloat,
            height: CGFloat,
            horizontalPadding: CGFloat,
            monospacedDigits: Bool
        )

        var targetHeight: CGFloat {
            switch self {
            case .icon(_, _, _, let diameter): return diameter
            case .pill(_, _, _, _, _, let height, _, _): return height
            }
        }

        var isCircle: Bool {
            if case .icon = self { return true }
            return false
        }
    }

    private final class FaceContainerView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }

    private let edgeScrollView: UIScrollView
    private let faceContainer = FaceContainerView()
    private let bar = AstraItemOnlyNavigationBar()
    private let item = UIBarButtonItem(image: nil, style: .plain, target: nil, action: nil)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var content: Content = .icon(systemName: "circle", pointSize: 18, weight: .semibold, diameter: 44)
    private var baseStyle: UIUserInterfaceStyle = .dark
    private var customTint: UIColor?
    private var isLoadingState = false
    private var isDisabledState = false

    private var primaryHandler: (() -> Void)?
    private var menuProvider: (() -> [UIMenuElement])?
    private var menuTitle = ""
    private var hasConfiguredAction = false
    private var configuredHasMenu = false
    private var configuredHasPrimary = false
    private var configuredMenuTitle = ""

    private var contentKey = ""
    private var measuredKey = ""
    private var measuredGlass = CGRect.null
    private var measuredIsEstimated = true
    private var renderScale: CGFloat = 0
    private var shrink: CGFloat = 1
    private var contentFrame = CGRect.zero
    private var reportedSize = CGSize(width: 44, height: 44)
    private weak var measuredControl: UIView?
    var visualCenterOffsetChanged: ((CGFloat) -> Void)?
    private var reportedVisualCenterOffset: CGFloat?

    override init(frame: CGRect) {
        edgeScrollView = AstraGlassEdge.makeEdgeScrollView(style: .dark)
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        overrideUserInterfaceStyle = .dark

        faceContainer.backgroundColor = .clear
        faceContainer.clipsToBounds = false
        faceContainer.overrideUserInterfaceStyle = .dark

        bar.tintColor = .label
        bar.directionalLayoutMargins = .zero
        let navItem = UINavigationItem(title: "")
        navItem.leftBarButtonItem = item
        bar.setItems([navItem], animated: false)

        faceContainer.addSubview(bar)
        addSubview(edgeScrollView)
        addSubview(faceContainer)

        AstraGlassEdge.register(faceContainer, scrollView: edgeScrollView, edge: .left)

        spinner.hidesWhenStopped = true
        spinner.isUserInteractionEnabled = false
        spinner.color = .white
        addSubview(spinner)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        content: Content,
        style: UIUserInterfaceStyle,
        tint: UIColor?,
        isLoading: Bool,
        isDisabled: Bool,
        accessibilityLabel: String?,
        primaryHandler: (() -> Void)?,
        menuTitle: String,
        menuProvider: (() -> [UIMenuElement])?
    ) {
        let styleChanged = baseStyle != style
        let contentChanged = self.content != content
        let tintChanged = (customTint == nil) != (tint == nil)
            || (customTint != nil && tint != nil && !customTint!.isEqual(tint!))
        let loadingChanged = isLoadingState != isLoading
        let disabledChanged = isDisabledState != isDisabled

        self.content = content
        self.baseStyle = style
        self.customTint = tint
        self.isLoadingState = isLoading
        self.isDisabledState = isDisabled
        self.primaryHandler = primaryHandler
        self.menuTitle = menuTitle
        self.menuProvider = menuProvider
        item.accessibilityLabel = accessibilityLabel
        self.accessibilityLabel = accessibilityLabel

        if styleChanged {
            overrideUserInterfaceStyle = style
            edgeScrollView.overrideUserInterfaceStyle = style
            faceContainer.overrideUserInterfaceStyle = style
        }
        if disabledChanged {
            item.isEnabled = !isDisabled
        }

        let wantsMenu = menuProvider != nil
        let wantsPrimary = primaryHandler != nil && !wantsMenu
        let actionChanged = !hasConfiguredAction
            || configuredHasMenu != wantsMenu
            || configuredHasPrimary != wantsPrimary
            || (wantsMenu && configuredMenuTitle != menuTitle)

        if actionChanged {
            hasConfiguredAction = true
            configuredHasMenu = wantsMenu
            configuredHasPrimary = wantsPrimary
            configuredMenuTitle = menuTitle
            if wantsMenu {
                item.primaryAction = nil
                let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.menuProvider?() ?? [])
                }
                item.menu = UIMenu(title: menuTitle, children: [deferred])
            } else if wantsPrimary {
                item.menu = nil
                item.primaryAction = UIAction { [weak self] _ in
                    self?.primaryHandler?()
                }
            } else {
                item.menu = nil
                item.primaryAction = nil
            }
            invalidateContent()
        }

        if contentChanged || tintChanged || loadingChanged {
            invalidateContent()
        }

        if loadingChanged {
            if isLoading {
                spinner.startAnimating()
            } else {
                spinner.stopAnimating()
            }
        }
        spinner.color = style == .light ? .label : .white

        let estimated = estimatedIntrinsicSize()
        if measuredGlass.isNull,
           abs(estimated.width - reportedSize.width) > 0.5 || abs(estimated.height - reportedSize.height) > 0.5 {
            reportedSize = estimated
            invalidateIntrinsicContentSize()
        }
    }

    private func invalidateContent() {
        contentKey = ""
        measuredKey = ""
        measuredGlass = .null
        measuredIsEstimated = true
        shrink = 1
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        reportedSize
    }

    func preferredSize() -> CGSize {
        if !measuredGlass.isNull && !measuredIsEstimated && contentFrame.width > 1 && contentFrame.height > 1 {
            return contentFrame.size
        }
        return estimatedIntrinsicSize()
    }

    private func estimatedIntrinsicSize() -> CGSize {
        switch content {
        case .icon(_, _, _, let diameter):
            return CGSize(width: diameter, height: diameter)
        case .pill(let symbol, let title, let showsChevron, let fontSize, let iconSize, let height, let horizontalPadding, let monospaced):
            let scale = max(0.3, height / AstraBarGlassMeasure.nominalGlass)
            let glyph = AstraBarGlassMeasure.renderPillGlyph(
                symbol: symbol,
                title: title,
                showsChevron: showsChevron,
                fontSize: fontSize,
                iconPointSize: iconSize,
                horizontalPadding: horizontalPadding,
                layoutScale: scale,
                renderScale: scale,
                displayScale: traitCollection.displayScale > 0 ? traitCollection.displayScale : 3,
                monospacedDigits: monospaced
            )
            let rawWidth = max(
                AstraBarGlassMeasure.nominalGlass,
                glyph.size.width + (AstraBarGlassMeasure.nativePillSideInset * 2) / scale
            )
            return CGSize(width: ceil(rawWidth * scale), height: height)
        }
    }

    private func liveControl() -> UIView? {
        if let control = measuredControl, control.isDescendant(of: bar) { return control }
        guard let control = AstraBarGlassMeasure.controls(in: bar).first else { return nil }
        measuredControl = control
        return control
    }

    private var isInteracting: Bool {
        guard let control = liveControl() as? UIControl else { return false }
        return control.isTracking || control.isHighlighted
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            measuredKey = ""
            setNeedsLayout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.window != nil else { return }
                AstraGlassMaterialPool.shared.captureFromNavigationBar(self.bar)
                self.reportVisualCenterIfNeeded()
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else {
            return nil
        }
        let hit = super.hitTest(point, with: event)
        if let control = liveControl() {
            if let hit, hit === control || hit.isDescendant(of: control) { return hit }
            return insideGlass(point) ? control : nil
        }
        return hit === self || hit === faceContainer ? nil : hit
    }

    private func insideGlass(_ point: CGPoint) -> Bool {
        let frame = contentFrame.isEmpty ? bounds : contentFrame
        guard frame.width > 0, frame.height > 0 else { return false }
        let radius = frame.height / 2
        let clampedX = min(max(point.x, frame.minX + radius), frame.maxX - radius)
        let dx = point.x - clampedX
        let dy = point.y - frame.midY
        return dx * dx + dy * dy <= radius * radius
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        if edgeScrollView.frame != bounds {
            edgeScrollView.frame = bounds
        }
        if faceContainer.frame != bounds {
            faceContainer.frame = bounds
        }
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)

        // 按住或展开菜单变形期间不动 bar 几何，防止打断系统液态拉伸与菜单形变动画
        if isInteracting { return }

        let target = content.isCircle ? min(bounds.width, bounds.height) : content.targetHeight
        let reference = max(0.3, target / AstraBarGlassMeasure.nominalGlass)
        let estimated = estimatedIntrinsicSize()
        let barWidth: CGFloat = content.isCircle ? 160 : max(280, estimated.width / reference + 120)

        bar.transform = .identity
        let barHeight = max(44, bar.sizeThatFits(CGSize(width: barWidth, height: 200)).height)
        if bar.bounds.size != CGSize(width: barWidth, height: barHeight) {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
            measuredKey = ""
        }
        bar.center = CGPoint(x: bounds.midX, y: bounds.midY)

        if let control = measuredControl, !control.isDescendant(of: bar) { measuredKey = "" }
        if measuredControl == nil { measuredKey = "" }

        let glass = measureGlass(reference: reference)
        guard !glass.isNull, glass.height > 0 else { return }

        let scale = target / glass.height
        if renderScale <= 0 || abs(scale - renderScale) > 0.01 {
            renderScale = scale
            updateContent(reference: reference)
            bar.layoutIfNeeded()
        }

        let offset = CGPoint(x: glass.midX - bar.bounds.midX, y: glass.midY - bar.bounds.midY)
        let glassWidth = glass.width * scale
        bar.transform = CGAffineTransform(scaleX: scale, y: scale)
        bar.center = CGPoint(x: bounds.midX - offset.x * scale, y: bounds.midY - offset.y * scale)
        contentFrame = CGRect(
            x: bounds.midX - glassWidth / 2,
            y: bounds.midY - target / 2,
            width: glassWidth,
            height: target
        )

        reportVisualCenterIfNeeded()

        let measuredSize = content.isCircle
            ? CGSize(width: target, height: target)
            : CGSize(width: ceil(glassWidth), height: target)
        if !measuredIsEstimated,
           abs(measuredSize.width - reportedSize.width) > 0.8 || abs(measuredSize.height - reportedSize.height) > 0.8 {
            reportedSize = measuredSize
            DispatchQueue.main.async { [weak self] in
                self?.invalidateIntrinsicContentSize()
            }
        }
    }

    private func reportVisualCenterIfNeeded() {
        guard visualCenterOffsetChanged != nil, window != nil, !isInteracting,
              let control = liveControl() else { return }
        // 读最终变换之后实际玻璃的位置，而不是拿 SwiftUI 预留框当视觉中心。
        let glass = AstraBarGlassMeasure.glassFrame(around: control, in: bar).frame
        let offset = bar.convert(glass, to: self).midX - bounds.midX
        guard offset.isFinite, abs(offset) <= bounds.width,
              reportedVisualCenterOffset.map({ abs($0 - offset) > 0.25 }) ?? true
        else { return }
        reportedVisualCenterOffset = offset
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedVisualCenterOffset == offset, self.window != nil else { return }
            self.visualCenterOffsetChanged?(offset)
        }
    }

    private var contentSignature: String {
        "\(content)|\(isLoadingState)|\(customTint?.description ?? "label")"
    }

    /// 移植自 xyydy `ALB3BarGlassButton.measureGlass`：
    /// 圆形图标按钮若被宽 SF Symbol（如快进 10 秒、字幕图标）撑成椭圆，自动收敛 `shrink` 直至还原正圆。
    private func measureGlass(reference: CGFloat) -> CGRect {
        let key = "\(contentSignature)|\(Int((reference * 1000).rounded()))|\(Int(bar.bounds.width))x\(Int(bar.bounds.height))|\(window == nil ? 0 : 1)"
        if key == measuredKey, !measuredGlass.isNull {
            return measuredGlass
        }
        shrink = 1
        var result = CGRect.null
        var bestShrink: CGFloat = 1
        var isEstimated = true
        let maxPasses = content.isCircle ? 6 : 1

        for _ in 0..<maxPasses {
            updateContent(reference: reference)
            bar.setNeedsLayout()
            bar.layoutIfNeeded()

            guard let control = AstraBarGlassMeasure.controls(in: bar).first,
                  control.bounds.width > 0, control.bounds.height > 0
            else {
                break
            }
            let found = AstraBarGlassMeasure.glassFrame(around: control, in: bar)
            if !result.isNull && found.frame.width >= result.width - 0.25 {
                break
            }
            result = found.frame
            bestShrink = shrink
            isEstimated = found.isEstimated
            measuredControl = control
            if !content.isCircle || isLoadingState || found.frame.width <= found.frame.height + 0.5 || shrink < 0.5 {
                break
            }
            shrink *= max(0.75, min(0.97, found.frame.height / found.frame.width))
        }

        if shrink != bestShrink {
            shrink = bestShrink
            updateContent(reference: reference)
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            measuredControl = AstraBarGlassMeasure.controls(in: bar).first ?? measuredControl
        }

        measuredGlass = result
        measuredIsEstimated = isEstimated
        measuredKey = (result.isNull || (isEstimated && window == nil)) ? "" : key
        return result
    }

    private func updateContent(reference: CGFloat) {
        let scale = max(0.3, reference)
        let render = max(0.3, renderScale > 0 ? renderScale : reference)
        let displayScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let key = "\(contentSignature)|\(Int(scale * 1000))|\(Int(render * 1000))|\(Int(shrink * 1000))"
        guard key != contentKey else { return }
        contentKey = key

        item.title = nil
        if isLoadingState {
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = 1
            item.image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format)
                .image { _ in }
                .withRenderingMode(.alwaysOriginal)
            return
        }

        var image: UIImage?
        switch content {
        case .icon(let systemName, let pointSize, let weight, _):
            let config = UIImage.SymbolConfiguration(pointSize: pointSize / scale * shrink, weight: weight)
            image = AstraGlyph.image(systemName, pointSize: pointSize / scale * shrink, withConfiguration: config)?
                .withRenderingMode(.alwaysTemplate)
        case .pill(let symbol, let title, let showsChevron, let fontSize, let iconSize, _, let horizontalPadding, let monospaced):
            image = AstraBarGlassMeasure.renderPillGlyph(
                symbol: symbol,
                title: title,
                showsChevron: showsChevron,
                fontSize: fontSize,
                iconPointSize: iconSize,
                horizontalPadding: horizontalPadding,
                layoutScale: scale,
                renderScale: render,
                displayScale: displayScale,
                monospacedDigits: monospaced
            )
        }

        if let current = image, let tint = customTint {
            image = current.withTintColor(tint, renderingMode: .alwaysOriginal)
        }
        item.image = image
    }
}

// MARK: - SwiftUI 桥接：真导航栏液态玻璃按钮与菜单

@available(iOS 26.0, *)
private struct AstraBarGlassRepresentable: UIViewRepresentable {
    let content: AstraBarGlassButtonView.Content
    let tone: AstraGlassTone
    let tint: UIColor?
    let isLoading: Bool
    let isDisabled: Bool
    let accessibilityLabel: String?
    let primaryHandler: (() -> Void)?
    let menuTitle: String
    let menuProvider: (() -> [UIMenuElement])?
    var onVisualCenterOffsetChange: ((CGFloat) -> Void)? = nil

    @Environment(\.colorScheme) private var systemScheme

    private var resolvedStyle: UIUserInterfaceStyle {
        tone.resolvedUIStyle(system: systemScheme == .dark ? .dark : .light)
    }

    func makeUIView(context: Context) -> AstraBarGlassButtonView {
        let view = AstraBarGlassButtonView()
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        apply(to: view)
        return view
    }

    func updateUIView(_ view: AstraBarGlassButtonView, context: Context) {
        apply(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AstraBarGlassButtonView, context: Context) -> CGSize? {
        uiView.preferredSize()
    }

    private func apply(to view: AstraBarGlassButtonView) {
        view.visualCenterOffsetChanged = onVisualCenterOffsetChange
        view.configure(
            content: content,
            style: resolvedStyle,
            tint: tint,
            isLoading: isLoading,
            isDisabled: isDisabled,
            accessibilityLabel: accessibilityLabel,
            primaryHandler: primaryHandler,
            menuTitle: menuTitle,
            menuProvider: menuProvider
        )
    }
}

/// 圆形真导航栏玻璃按钮（iOS 26 走 `AstraBarGlassButtonView`，低系统回退毛玻璃按钮）
struct BarGlassIconButton: View {
    let systemImage: String
    var pointSize: CGFloat = 18
    var weight: UIImage.SymbolWeight = .semibold
    var diameter: CGFloat = 44
    var tint: UIColor? = nil
    var tone: AstraGlassTone = .dark
    var isLoading = false
    var isDisabled = false
    var accessibilityLabel: String? = nil
    var onVisualCenterOffsetChange: ((CGFloat) -> Void)? = nil
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            AstraBarGlassRepresentable(
                content: .icon(systemName: systemImage, pointSize: pointSize, weight: weight, diameter: diameter),
                tone: tone,
                tint: tint,
                isLoading: isLoading,
                isDisabled: isDisabled,
                accessibilityLabel: accessibilityLabel,
                primaryHandler: action,
                menuTitle: "",
                menuProvider: nil,
                onVisualCenterOffsetChange: onVisualCenterOffsetChange
            )
            .frame(width: diameter, height: diameter)
        } else {
            Button(action: action) {
                ZStack {
                    if isLoading {
                        ProgressView()
                    } else {
                        AstraIcon(systemImage, pointSize: pointSize)
                            .font(.system(size: pointSize, weight: weight.swiftUI))
                            .foregroundStyle(tint.map { Color(uiColor: $0) } ?? .primary)
                    }
                }
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .background(.ultraThinMaterial, in: Circle())
            .accessibilityLabel(accessibilityLabel ?? "")
        }
    }
}

/// 胶囊真导航栏玻璃按钮（iOS 26 走 `AstraBarGlassButtonView`，低系统回退毛玻璃胶囊）
struct BarGlassPillButton: View {
    let title: String
    var systemImage: String? = nil
    var fontSize: CGFloat = 14
    var iconSize: CGFloat = 13
    var height: CGFloat = 36
    var horizontalPadding: CGFloat = 13
    var tint: UIColor? = nil
    var tone: AstraGlassTone = .dark
    var monospacedDigits = false
    var isDisabled = false
    var accessibilityLabel: String? = nil
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            AstraBarGlassRepresentable(
                content: .pill(
                    symbol: systemImage,
                    title: title,
                    showsChevron: false,
                    fontSize: fontSize,
                    iconSize: iconSize,
                    height: height,
                    horizontalPadding: horizontalPadding,
                    monospacedDigits: monospacedDigits
                ),
                tone: tone,
                tint: tint,
                isLoading: false,
                isDisabled: isDisabled,
                accessibilityLabel: accessibilityLabel ?? title,
                primaryHandler: action,
                menuTitle: "",
                menuProvider: nil
            )
            .fixedSize()
        } else {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let systemImage {
                        AstraIcon(systemImage, pointSize: iconSize)
                            .font(.system(size: iconSize, weight: .semibold))
                    }
                    Text(title)
                        .font(.system(size: fontSize, weight: .semibold))
                }
                .foregroundStyle(tint.map { Color(uiColor: $0) } ?? .primary)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel(accessibilityLabel ?? title)
        }
    }
}

/// 圆形真导航栏玻璃菜单按钮（iOS 26 用 `UIBarButtonItem(menu:)`，展开/收起与按钮材质完全同步无卡顿）
struct BarGlassIconMenuButton: View {
    let systemImage: String
    var pointSize: CGFloat = 18
    var weight: UIImage.SymbolWeight = .semibold
    var diameter: CGFloat = 44
    var tint: UIColor? = nil
    var tone: AstraGlassTone = .dark
    var menuTitle: String = ""
    var accessibilityLabel: String? = nil
    let menuElements: () -> [UIMenuElement]

    var body: some View {
        if #available(iOS 26.0, *) {
            AstraBarGlassRepresentable(
                content: .icon(systemName: systemImage, pointSize: pointSize, weight: weight, diameter: diameter),
                tone: tone,
                tint: tint,
                isLoading: false,
                isDisabled: false,
                accessibilityLabel: accessibilityLabel,
                primaryHandler: nil,
                menuTitle: menuTitle,
                menuProvider: menuElements
            )
            .frame(width: diameter, height: diameter)
        } else {
            LegacyIconMenuButton(
                systemImage: systemImage,
                pointSize: pointSize,
                weight: weight,
                diameter: diameter,
                tint: tint,
                menuTitle: menuTitle,
                menuElements: menuElements
            )
            .frame(width: diameter, height: diameter)
            .background(.ultraThinMaterial, in: Circle())
            .accessibilityLabel(accessibilityLabel ?? "")
        }
    }
}

// MARK: - 首页原生导航栏玻璃菜单

// 首页胶囊的可见高度与标签尺寸分开定：保留早期的字重、图文间距和左右留白。
enum AstraHomePillMetrics {
    static let height: CGFloat = 31
    static let font: CGFloat = 14.5
    static let icon: CGFloat = 13.5
    static let sidePadding: CGFloat = 14
}

@available(iOS 26.0, *)
struct AstraHomeGlassMenuBar: UIViewRepresentable {
    struct Menu {
        let title: String
        let systemImage: String
        var menuTitle = ""
        let accessibilityLabel: String
        let elements: @MainActor () -> [UIMenuElement]
    }

    // UIKit 仍负责整块玻璃和原生菜单过场。标签按可见尺寸单独绘制。
    static let height = AstraHomePillMetrics.height
    private static let layoutScale = height / AstraBarGlassMeasure.nominalGlass
    private static let sideMargin: CGFloat = 16

    let leading: Menu
    var trailing: Menu?
    var darkBackground: Bool

    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> ChromeView {
        ChromeView(frame: .zero)
    }

    func updateUIView(_ view: ChromeView, context: Context) {
        let edgeStyle: UIUserInterfaceStyle = darkBackground || colorScheme == .dark ? .dark : .light
        view.configure(leading: leading, trailing: trailing, edgeStyle: edgeStyle)
    }

    /// 透明导航栏只拦截栏按钮，不挡住两颗按钮之间的首页内容。
    private final class MenuNavigationBar: UINavigationBar {
        override init(frame: CGRect) {
            super.init(frame: frame)
            astraClearNavigationBar(self)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { astraClearNavigationBar(self) }
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let hit = super.hitTest(point, with: event), hit !== self,
                  hit.convert(hit.bounds, to: self).width < bounds.width * 0.9
            else { return nil }
            return hit
        }
    }

    final class ChromeView: UIView {
        @MainActor
        private final class Slot {
            private let menuTitle: String
            private var elements: @MainActor () -> [UIMenuElement]
            private var label: (title: String, symbol: String, scale: CGFloat)?

            init(menu: Menu) {
                menuTitle = menu.menuTitle
                elements = menu.elements
            }

            private(set) lazy var item: UIBarButtonItem = {
                let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.elements() ?? [])
                }
                // 栏按钮自己画玻璃、显示图标和文字，也是系统展开和收回菜单的源视图。
                return UIBarButtonItem(title: nil, image: nil, primaryAction: nil,
                                       menu: UIMenu(title: menuTitle, children: [deferred]))
            }()

            func matches(_ menu: Menu) -> Bool { menu.menuTitle == menuTitle }

            func update(_ menu: Menu, displayScale: CGFloat) {
                elements = menu.elements
                item.accessibilityLabel = menu.accessibilityLabel
                guard label?.title != menu.title ||
                        label?.symbol != menu.systemImage ||
                        label?.scale != displayScale
                else { return }
                label = (menu.title, menu.systemImage, displayScale)
                // 文字只作为系统栏按钮的模板图内容，不能单独承担按钮或菜单。
                item.image = AstraBarGlassMeasure.renderPillGlyph(
                    symbol: menu.systemImage, title: menu.title, showsChevron: true,
                    fontSize: AstraHomePillMetrics.font, iconPointSize: AstraHomePillMetrics.icon,
                    horizontalPadding: AstraHomePillMetrics.sidePadding,
                    layoutScale: AstraHomeGlassMenuBar.layoutScale, renderScale: AstraHomeGlassMenuBar.layoutScale,
                    displayScale: displayScale, monospacedDigits: false
                )
            }
        }

        private let edge = AstraGlassEdge.makeEdgeScrollView()
        private let bar = MenuNavigationBar()
        private let navigationItem = UINavigationItem(title: "")
        private var leadingSlot: Slot?
        private var trailingSlot: Slot?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            clipsToBounds = false
            overrideUserInterfaceStyle = .dark
            bar.tintColor = .label
            let nativeMargin = AstraHomeGlassMenuBar.sideMargin / AstraHomeGlassMenuBar.layoutScale
            bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: nativeMargin, bottom: 0, trailing: nativeMargin)
            let scale = AstraHomeGlassMenuBar.layoutScale
            bar.transform = CGAffineTransform(scaleX: scale, y: scale)
            bar.setItems([navigationItem], animated: false)
            addSubview(edge)
            addSubview(bar)
            // 对应独立顶栏的隐藏顶部滚动边；不触碰页面滚动视图或 TabBar。
            AstraGlassEdge.register(self, scrollView: edge, edge: .top)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        fileprivate func configure(leading: Menu, trailing: Menu?, edgeStyle: UIUserInterfaceStyle) {
            if edge.overrideUserInterfaceStyle != edgeStyle {
                edge.overrideUserInterfaceStyle = edgeStyle
            }
            let scale = max(1, traitCollection.displayScale)
            if leadingSlot?.matches(leading) != true {
                leadingSlot = Slot(menu: leading)
            }
            leadingSlot?.update(leading, displayScale: scale)
            if navigationItem.leftBarButtonItem !== leadingSlot?.item {
                navigationItem.leftBarButtonItem = leadingSlot?.item
            }

            if let trailing {
                if trailingSlot?.matches(trailing) != true {
                    trailingSlot = Slot(menu: trailing)
                }
                trailingSlot?.update(trailing, displayScale: scale)
            } else {
                trailingSlot = nil
            }
            if navigationItem.rightBarButtonItem !== trailingSlot?.item {
                navigationItem.rightBarButtonItem = trailingSlot?.item
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            setNeedsLayout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.window != nil else { return }
                // 用真正可见的系统栏按钮给播放器采样，不再创建隐藏的样本导航栏。
                AstraGlassMaterialPool.shared.captureFromNavigationBar(self.bar)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0 else { return }
            // 只为顶栏提供滚动边。不要将不可滚动的材质辅助视图扩展到底栏背后。
            if edge.frame != bounds { edge.frame = bounds }

            // 按固定比例反算布局宽度；按压和展开时不重新量玻璃，也不修改比例。
            let nativeWidth = bounds.width / AstraHomeGlassMenuBar.layoutScale
            let size = bar.sizeThatFits(CGSize(width: nativeWidth, height: 200))
            let barBounds = CGRect(x: 0, y: 0, width: nativeWidth, height: max(44, size.height))
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            if bar.bounds != barBounds { bar.bounds = barBounds }
            if bar.center != center { bar.center = center }
            bar.layoutIfNeeded()
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
            return bar.hitTest(convert(point, to: bar), with: event)
        }
    }
}

/// 胶囊真导航栏玻璃菜单按钮（用于首页顶部模式菜单、音乐首页右上角特效菜单、播放器倍速菜单）
struct BarGlassPillMenuButton: View {
    let title: String
    var systemImage: String? = nil
    var showsChevron: Bool = true
    var fontSize: CGFloat = 14.5
    var iconSize: CGFloat = 13.5
    var height: CGFloat = 35
    var horizontalPadding: CGFloat = 14
    var tint: UIColor? = nil
    var tone: AstraGlassTone = .dark
    var monospacedDigits = false
    var menuTitle: String = ""
    var accessibilityLabel: String? = nil
    let menuElements: () -> [UIMenuElement]

    var body: some View {
        if #available(iOS 26.0, *) {
            AstraBarGlassRepresentable(
                content: .pill(
                    symbol: systemImage,
                    title: title,
                    showsChevron: showsChevron,
                    fontSize: fontSize,
                    iconSize: iconSize,
                    height: height,
                    horizontalPadding: horizontalPadding,
                    monospacedDigits: monospacedDigits
                ),
                tone: tone,
                tint: tint,
                isLoading: false,
                isDisabled: false,
                accessibilityLabel: accessibilityLabel ?? title,
                primaryHandler: nil,
                menuTitle: menuTitle,
                menuProvider: menuElements
            )
            .fixedSize()
        } else {
            MenuButton(
                title: title,
                systemImage: systemImage ?? "",
                showsChevron: showsChevron,
                fontSize: fontSize,
                tint: tint,
                menuKey: title,
                menu: { UIMenu(title: menuTitle, children: menuElements()) }
            )
            .fixedSize()
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel(accessibilityLabel ?? title)
        }
    }
}

/// iOS 15–18 圆形 UIKit 菜单按钮回退实现
private struct LegacyIconMenuButton: UIViewRepresentable {
    let systemImage: String
    let pointSize: CGFloat
    let weight: UIImage.SymbolWeight
    let diameter: CGFloat
    let tint: UIColor?
    let menuTitle: String
    let menuElements: () -> [UIMenuElement]

    final class Coordinator {
        var provider: () -> [UIMenuElement]
        init(provider: @escaping () -> [UIMenuElement]) { self.provider = provider }
    }

    func makeCoordinator() -> Coordinator { Coordinator(provider: menuElements) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        let deferred = UIDeferredMenuElement.uncached { [weak coord = context.coordinator] completion in
            completion(coord?.provider() ?? [])
        }
        button.menu = UIMenu(title: menuTitle, children: [deferred])
        apply(to: button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.provider = menuElements
        apply(to: button)
    }

    private func apply(to button: UIButton) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        button.setImage(AstraGlyph.image(systemImage, pointSize: pointSize, withConfiguration: config), for: .normal)
        button.tintColor = tint ?? .label
    }
}

private extension UIImage.SymbolWeight {
    var swiftUI: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

// MARK: - iOS 26 播放器 HUD 面板底板：复用底栏实体玻璃 + 独立暗色滚动边

@available(iOS 26.0, *)
final class AstraBarMatchedGlassContainerView: UIView {
    private let edgeScrollView: UIScrollView
    private let effectView = UIVisualEffectView(effect: nil)
    private var interactive = false
    private var corner: AstraGlassCorner = .capsule
    private var targetStyle: UIUserInterfaceStyle = .dark
    private var appliedSignature = ""
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        edgeScrollView = AstraGlassEdge.makeEdgeScrollView(style: .dark)
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = false

        effectView.isUserInteractionEnabled = false
        effectView.backgroundColor = .clear
        effectView.frame = bounds

        addSubview(edgeScrollView)
        addSubview(effectView)
        AstraGlassEdge.register(effectView, scrollView: edgeScrollView, edge: .left)

        observer = NotificationCenter.default.addObserver(
            forName: AstraGlassMaterialPool.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMaterial(force: true)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if edgeScrollView.frame != bounds { edgeScrollView.frame = bounds }
        if effectView.frame != bounds { effectView.frame = bounds }
    }

    func configure(interactive: Bool, corner: AstraGlassCorner, style: UIUserInterfaceStyle) {
        let changed = self.interactive != interactive || self.corner != corner || self.targetStyle != style
        self.interactive = interactive
        self.corner = corner
        self.targetStyle = style
        if changed || appliedSignature.isEmpty {
            refreshMaterial(force: false)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            refreshMaterial(force: false)
        }
    }

    private func refreshMaterial(force: Bool) {
        if overrideUserInterfaceStyle != targetStyle {
            overrideUserInterfaceStyle = targetStyle
        }
        if edgeScrollView.overrideUserInterfaceStyle != targetStyle {
            edgeScrollView.overrideUserInterfaceStyle = targetStyle
        }
        if effectView.overrideUserInterfaceStyle != targetStyle {
            effectView.overrideUserInterfaceStyle = targetStyle
        }
        switch corner {
        case .capsule, .circle:
            effectView.cornerConfiguration = .capsule()
        case .roundedRect(let radius):
            effectView.cornerConfiguration = .corners(radius: .fixed(radius))
        }

        let gen = AstraGlassMaterialPool.shared.currentGeneration
        let signature = "\(gen)|\(targetStyle.rawValue)|\(interactive)"
        guard force || signature != appliedSignature else { return }
        appliedSignature = signature
        effectView.effect = AstraGlassMaterialPool.shared.makeBarMatchedEffect(interactive: interactive)
    }
}

@available(iOS 26.0, *)
struct AstraBarMatchedGlassBackground: UIViewRepresentable {
    let interactive: Bool
    let corner: AstraGlassCorner
    let tone: AstraGlassTone

    @Environment(\.colorScheme) private var systemScheme

    private var uiStyle: UIUserInterfaceStyle {
        tone.resolvedUIStyle(system: systemScheme == .dark ? .dark : .light)
    }

    func makeUIView(context: Context) -> AstraBarMatchedGlassContainerView {
        let view = AstraBarMatchedGlassContainerView()
        view.configure(interactive: interactive, corner: corner, style: uiStyle)
        return view
    }

    func updateUIView(_ view: AstraBarMatchedGlassContainerView, context: Context) {
        view.configure(interactive: interactive, corner: corner, style: uiStyle)
    }
}
