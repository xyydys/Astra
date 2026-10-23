import SwiftUI
import UIKit

// 最低支持 iOS 15。新系统上的写法（液态玻璃、NavigationStack、ContentUnavailableView 等）都收在这里：
// 新系统照常用系统原生效果，旧系统退回到效果接近的老 API。

// MARK: - 液态玻璃

extension View {
    /// iOS 26 是液态玻璃，旧系统用毛玻璃材质
    @ViewBuilder
    func glass<S: Shape>(interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// 玻璃按钮；旧系统是带底色的胶囊按钮
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// 强调色玻璃按钮；旧系统是实心强调色胶囊按钮
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }
}

/// iOS 26 的 GlassEffectContainer，旧系统原样显示内容
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - 导航

/// iOS 16 起是 NavigationStack，iOS 15 是堆叠式的 NavigationView
struct NavigationStackCompat<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
                .navigationViewStyle(.stack)
        }
    }
}

extension View {
    /// 按状态跳转（navigationDestination(item:)）；iOS 15 用隐藏的 NavigationLink
    @ViewBuilder
    func navigationDestinationCompat<Item, Destination: View>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        let isPresented = Binding<Bool>(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
        if #available(iOS 16, *) {
            navigationDestination(isPresented: isPresented) {
                if let value = item.wrappedValue { destination(value) }
            }
        } else {
            background {
                NavigationLink(isActive: isPresented) {
                    if let value = item.wrappedValue { destination(value) }
                } label: {
                    EmptyView()
                }
                .hidden()
            }
        }
    }

    /// 隐藏导航栏
    @ViewBuilder
    func navigationBarHiddenCompat() -> some View {
        if #available(iOS 16, *) {
            toolbar(.hidden, for: .navigationBar)
        } else {
            navigationBarHidden(true)
        }
    }

    /// 隐藏底栏（iOS 15 不支持，保持显示）
    @ViewBuilder
    func tabBarHiddenCompat() -> some View {
        if #available(iOS 16, *) {
            toolbar(.hidden, for: .tabBar)
        } else {
            self
        }
    }

    /// 底栏用深色（iOS 15 不支持单独设置，跟随页面）
    @ViewBuilder
    func darkTabBarCompat() -> some View {
        if #available(iOS 16, *) {
            toolbarColorScheme(.dark, for: .tabBar)
        } else {
            self
        }
    }
}

// MARK: - 列表、滚动

extension View {
    @ViewBuilder
    func hideScrollIndicators() -> some View {
        if #available(iOS 16, *) {
            scrollIndicators(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func dismissKeyboardOnScroll() -> some View {
        if #available(iOS 16, *) {
            scrollDismissesKeyboard(.immediately)
        } else {
            self
        }
    }
}

// MARK: - 弹出面板

enum SheetDetent: Hashable {
    case medium, large, height(CGFloat)

    @available(iOS 16, *)
    var system: PresentationDetent {
        switch self {
        case .medium: return .medium
        case .large: return .large
        case .height(let value): return .height(value)
        }
    }
}

extension View {
    /// 半屏面板；iOS 15 是全屏高度的普通面板
    @ViewBuilder
    func sheetDetents(_ detents: [SheetDetent], dragIndicator: Bool = false, interactiveUpThrough: SheetDetent? = nil) -> some View {
        if #available(iOS 16.4, *) {
            let base = presentationDetents(Set(detents.map(\.system)))
                .presentationDragIndicator(dragIndicator ? .visible : .automatic)
            if let interactiveUpThrough {
                base.presentationBackgroundInteraction(.enabled(upThrough: interactiveUpThrough.system))
            } else {
                base
            }
        } else if #available(iOS 16, *) {
            presentationDetents(Set(detents.map(\.system)))
                .presentationDragIndicator(dragIndicator ? .visible : .automatic)
        } else {
            self
        }
    }
}

// MARK: - 状态变化

extension View {
    /// onChange(of:initial:) { old, new in }，iOS 17 以前用捕获旧值的写法
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        if #available(iOS 17, *) {
            onChange(of: value, initial: initial, action)
        } else {
            self
                .onAppear { if initial { action(value, value) } }
                .onChange(of: value) { [value] new in action(value, new) }
        }
    }

    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        onChangeCompat(of: value, initial: initial) { _, _ in action() }
    }
}

// MARK: - 动效、触感

extension Animation {
    static var snappyCompat: Animation {
        if #available(iOS 17, *) { return .snappy }
        return .spring(response: 0.3, dampingFraction: 0.86)
    }

    static var smoothCompat: Animation {
        if #available(iOS 17, *) { return .smooth }
        return .spring(response: 0.5, dampingFraction: 1)
    }

    static func smoothCompat(duration: Double) -> Animation {
        if #available(iOS 17, *) { return .smooth(duration: duration) }
        return .spring(response: duration, dampingFraction: 1)
    }
}

extension View {
    /// 值变化时轻触反馈（sensoryFeedback(.selection)）
    @ViewBuilder
    func selectionFeedback<T: Equatable>(trigger: T) -> some View {
        if #available(iOS 17, *) {
            sensoryFeedback(.selection, trigger: trigger)
        } else {
            onChange(of: trigger) { _ in UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    /// SF Symbol 切换时的替换动画（iOS 17 起）
    @ViewBuilder
    func symbolReplaceTransition() -> some View {
        if #available(iOS 17, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }
}

// MARK: - 按钮

extension Button where Label == SwiftUI.Label<Text, Image> {
    /// 带图标的按钮（Button(_:systemImage:) 要 iOS 17）
    init(_ title: LocalizedStringKey, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, systemImage: icon) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, systemImage: icon) }
    }
}

// MARK: - 空状态

/// ContentUnavailableView 的兼容版：iOS 17 起用系统的，旧系统画一个样式接近的
struct EmptyStateView<Actions: View>: View {
    let title: Text
    let systemImage: String
    var description: Text?
    @ViewBuilder var actions: Actions

    var body: some View {
        if #available(iOS 17, *) {
            ContentUnavailableView {
                SwiftUI.Label { title } icon: { Image(systemName: systemImage) }
            } description: {
                description
            } actions: {
                actions
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                title
                    .font(.title2.weight(.bold))
                if let description {
                    description
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                actions
                    .padding(.top, 6)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init(title: Text(title), systemImage: systemImage, description: description) { EmptyView() }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, systemImage: String, description: Text? = nil) {
        self.init(title: Text(title), systemImage: systemImage, description: description) { EmptyView() }
    }

    /// 搜索没有结果
    static func search(text: String) -> EmptyStateView {
        EmptyStateView(
            title: Text("没有“\(text)”的结果"),
            systemImage: "magnifyingglass",
            description: Text("检查拼写或换个关键词试试")
        ) { EmptyView() }
    }
}

extension EmptyStateView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil, @ViewBuilder actions: () -> Actions) {
        self.init(title: Text(title), systemImage: systemImage, description: description, actions: actions)
    }
}

// MARK: - 表单

/// LabeledContent（iOS 16）的兼容版
struct LabeledRow<Label: View, Content: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label

    var body: some View {
        if #available(iOS 16, *) {
            LabeledContent { content } label: { label }
        } else {
            HStack {
                label
                Spacer(minLength: 12)
                content
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

extension LabeledRow where Label == Text, Content == Text {
    init(_ title: LocalizedStringKey, value: String) {
        self.init { Text(value) } label: { Text(title) }
    }
}

// MARK: - 尺寸

extension View {
    /// 高度取容器（屏幕）高度的一定比例，有上限。iOS 17 起用 containerRelativeFrame
    @ViewBuilder
    func containerHeight(fraction: CGFloat, max maximum: CGFloat) -> some View {
        if #available(iOS 17, *) {
            containerRelativeFrame(.vertical) { length, _ in min(length * fraction, maximum) }
        } else {
            frame(height: min(UIScreen.main.bounds.height * fraction, maximum))
        }
    }

    /// 宽度等于容器宽度（横向分页滚动里的一页）
    @ViewBuilder
    func containerWidth() -> some View {
        if #available(iOS 17, *) {
            containerRelativeFrame(.horizontal)
        } else {
            frame(width: UIScreen.main.bounds.width)
        }
    }

    /// 导航栏不显示标题（标题仍用于返回按钮和多任务）
    @ViewBuilder
    func navigationTitleHidden() -> some View {
        if #available(iOS 18, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

extension View {
    /// 隐藏 Home 指示条（iOS 16 起）
    @ViewBuilder
    func homeIndicatorHiddenCompat(_ hidden: Bool = true) -> some View {
        if #available(iOS 16, *) {
            persistentSystemOverlays(hidden ? .hidden : .automatic)
        } else {
            self
        }
    }

    /// 回报视图高度（onGeometryChange 的兼容写法）
    func readHeight(_ action: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { action(proxy.size.height) }
                    .onChange(of: proxy.size.height) { action($0) }
            }
        }
    }
}

// MARK: - 滚动位置

/// 竖向滚动 + 双向绑定「顶部是哪一项」（scrollPosition(id:anchor: .top)）。
/// iOS 17 起用系统的；旧系统用 ScrollViewReader 跳转，各项回报自己的位置来判断顶部是哪一项。
/// 内容里的每一项用 `.scrollItem(id)` 标记
struct PositionedScrollView<ID: Hashable, Content: View>: View {
    @Binding var position: ID?
    @ViewBuilder var content: Content
    @State private var reported: ID?

    var body: some View {
        if #available(iOS 17, *) {
            ScrollView {
                content.scrollTargetLayout()
            }
            .scrollPosition(id: $position, anchor: .top)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .onPreferenceChange(ScrollItemOffsetKey.self) { offsets in
                            let visible = offsets.compactMap { key, value in (key.base as? ID).map { ($0, value) } }
                            let top = visible.filter { $0.1 <= 1 }.max { $0.1 < $1.1 } ?? visible.min { $0.1 < $1.1 }
                            guard let top, top.0 != position else { return }
                            reported = top.0
                            position = top.0
                        }
                }
                .coordinateSpace(name: ScrollItemOffsetKey.space)
                .onAppear {
                    if let position { DispatchQueue.main.async { proxy.scrollTo(position, anchor: .top) } }
                }
                .onChange(of: position) { value in
                    // 用户滚动时回报的位置不用再跳
                    guard let value, value != reported else { return }
                    reported = value
                    DispatchQueue.main.async { proxy.scrollTo(value, anchor: .top) }
                }
            }
        }
    }
}

struct ScrollItemOffsetKey: PreferenceKey {
    static let space = "positionedScroll"
    static var defaultValue: [AnyHashable: CGFloat] = [:]
    static func reduce(value: inout [AnyHashable: CGFloat], nextValue: () -> [AnyHashable: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// PositionedScrollView 里的一项
    @ViewBuilder
    func scrollItem<ID: Hashable>(_ id: ID) -> some View {
        if #available(iOS 17, *) {
            self.id(id)
        } else {
            self
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ScrollItemOffsetKey.self,
                            value: [AnyHashable(id): proxy.frame(in: .named(ScrollItemOffsetKey.space)).minY]
                        )
                    }
                }
                .id(id)
        }
    }
}

// MARK: - 分享

/// ShareLink（iOS 16）的兼容版：旧系统弹系统分享面板
struct ShareLinkCompat<Label: View>: View {
    let url: URL
    @ViewBuilder var label: Label

    var body: some View {
        if #available(iOS 16, *) {
            ShareLink(item: url) { label }
        } else {
            Button {
                Self.present(url)
            } label: {
                label
            }
        }
    }

    private static func present(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = window
        controller.popoverPresentationController?.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
        top.present(controller, animated: true)
    }
}

// MARK: - 流式排列

/// 标签自动换行（iOS 16 起的 Layout）；iOS 15 改成横向滚动的一行
struct TagFlow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 16, *) {
            FlowLayout(spacing: spacing) { content }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) { content }
            }
        }
    }
}

// MARK: - 文本

extension View {
    /// lineLimit(n, reservesSpace: true)：iOS 15 不预留空行
    @ViewBuilder
    func lineLimitReservingSpace(_ lines: Int) -> some View {
        if #available(iOS 16, *) {
            lineLimit(lines, reservesSpace: true)
        } else {
            lineLimit(lines)
        }
    }

    @ViewBuilder
    func fontWeightCompat(_ weight: Font.Weight) -> some View {
        if #available(iOS 16, *) {
            fontWeight(weight)
        } else {
            self
        }
    }

    /// 圆形按钮（iOS 17 起），旧系统是胶囊
    @ViewBuilder
    func circleButtonShape() -> some View {
        if #available(iOS 17, *) {
            buttonBorderShape(.circle)
        } else {
            buttonBorderShape(.capsule)
        }
    }
}

/// 可以自动换行变高的输入框（iOS 16 起），旧系统是单行
struct GrowingTextField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        if #available(iOS 16, *) {
            TextField(title, text: $text, axis: .vertical)
        } else {
            TextField(title, text: $text)
        }
    }
}
