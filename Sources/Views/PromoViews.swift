import SwiftUI

// MARK: - 数据

/// 推广页的一张图：示例先用代码画的图，正式使用时换成图片地址
enum PromoImage: Hashable {
    case art(PromoArt)
    case remote(String)
}

/// 代码生成的示例图：渐变底 + 模糊光斑 + 不同风格的装饰，可以带一行标题（截图上的说明文字）
struct PromoArt: Hashable {
    enum Style: Hashable { case aurora, waves, stars, grid, lyrics, cards, rings }

    var palette: [String]
    var style: Style
    var seed: UInt64
    var caption = ""
}

/// 一个插件的介绍
struct PromoPlugin: Identifiable {
    let id: String
    let name: String
    /// 卡片上的一句话简介
    let tagline: String
    let category: String
    /// 「即将推出」「测试中」之类
    let status: String
    let symbol: String
    let palette: [String]
    let shots: [PromoImage]
    let summary: String
    let features: [String]
    let tags: [String]
    var link: URL? = nil
}

enum PromoCatalog {
    static func color(_ hex: String) -> Color {
        Color(uiColor: UIColor(hex: hex) ?? .systemGray)
    }

    private static func shot(_ palette: [String], _ style: PromoArt.Style, _ seed: UInt64, _ caption: String) -> PromoImage {
        .art(PromoArt(palette: palette, style: style, seed: seed, caption: caption))
    }

    /// 示例内容（图片都是代码画的），之后换成真实的插件介绍和截图地址
    static let demo: [PromoPlugin] = {
        let lumen = ["#7C3AED", "#EC4899", "#F59E0B"]
        let tide = ["#0EA5E9", "#14B8A6", "#1E3A8A"]
        let atlas = ["#1E1B4B", "#4338CA", "#22D3EE"]
        let glimmer = ["#F97316", "#FB7185", "#FDE68A"]
        return [
            PromoPlugin(
                id: "lumen-lyrics", name: "流光歌词", tagline: "逐字高亮、背景跟着封面变色的歌词插件",
                category: "音乐", status: "即将推出", symbol: "music.quarternote.3", palette: lumen,
                shots: [
                    PromoCatalog.shot(lumen, .lyrics, 11, "逐字高亮"),
                    PromoCatalog.shot(lumen, .aurora, 12, "封面取色背景"),
                    PromoCatalog.shot(lumen, .waves, 13, "跟着节拍律动"),
                    PromoCatalog.shot(lumen, .rings, 14, "专注模式"),
                ],
                summary: "把正在播放的歌词做成会呼吸的画面：当前这句逐字点亮，背景从专辑封面取色、缓慢流动。支持翻译和罗马音对照，锁屏和画中画也能看。\n\n（示例介绍，正式内容之后替换）",
                features: ["逐字 / 逐行两种高亮", "封面取色的流动背景", "翻译、罗马音对照", "画中画歌词"],
                tags: ["歌词", "动效", "音乐"]
            ),
            PromoPlugin(
                id: "tide-download", name: "潮汐下载", tagline: "多线程分片下载，断点续传，切到后台也不停",
                category: "工具", status: "测试中", symbol: "arrow.down.circle.fill", palette: tide,
                shots: [
                    PromoCatalog.shot(tide, .waves, 21, "分片并行下载"),
                    PromoCatalog.shot(tide, .cards, 22, "任务队列"),
                    PromoCatalog.shot(tide, .grid, 23, "实时速度曲线"),
                    PromoCatalog.shot(tide, .rings, 24, "后台不中断"),
                ],
                summary: "大文件拆成多段同时下载，网络断了从断点接着下。任务排队、限速、只在 Wi-Fi 下载都可以设置。\n\n（示例介绍，正式内容之后替换）",
                features: ["多线程分片", "断点续传", "后台下载", "任务队列与限速"],
                tags: ["下载", "效率"]
            ),
            PromoPlugin(
                id: "star-atlas", name: "星图书签", tagline: "把网页、视频和漫画进度收进同一张星图",
                category: "效率", status: "即将推出", symbol: "star.circle.fill", palette: atlas,
                shots: [
                    PromoCatalog.shot(atlas, .stars, 31, "星图视图"),
                    PromoCatalog.shot(atlas, .cards, 32, "分组卡片"),
                    PromoCatalog.shot(atlas, .aurora, 33, "多设备同步"),
                    PromoCatalog.shot(atlas, .grid, 34, "时间线"),
                    PromoCatalog.shot(atlas, .rings, 35, "相关推荐"),
                ],
                summary: "收藏过的网页、看到一半的视频、追到第几话的漫画，都变成星图上的一颗星，按主题自动连成星座，换设备也能接着看。\n\n（示例介绍，正式内容之后替换）",
                features: ["自动按主题分组", "进度同步", "时间线回看", "相关内容推荐"],
                tags: ["书签", "同步", "效率"]
            ),
            PromoPlugin(
                id: "glimmer-album", name: "拾光相册", tagline: "按日子翻看的回忆卡片，那年今日自动提醒",
                category: "生活", status: "构思中", symbol: "photo.on.rectangle.angled", palette: glimmer,
                shots: [
                    PromoCatalog.shot(glimmer, .cards, 41, "回忆卡片"),
                    PromoCatalog.shot(glimmer, .aurora, 42, "胶片色调"),
                    PromoCatalog.shot(glimmer, .rings, 43, "那年今日"),
                    PromoCatalog.shot(glimmer, .waves, 44, "慢慢回看"),
                ],
                summary: "把相册按日子整理成一张张卡片，配上当天的天气和地点。每年的这一天，会把以前的照片轻轻推到你面前。\n\n（示例介绍，正式内容之后替换）",
                features: ["回忆卡片", "那年今日", "胶片滤镜", "只在本机处理"],
                tags: ["相册", "回忆", "生活"]
            ),
        ]
    }()
}

// MARK: - 列表页

/// 「更多插件」：App Store 风格的卡片列表，卡片背景轮播这个插件的截图
struct PromoListView: View {
    private let plugins = PromoCatalog.demo

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这个 App 免费、不放广告。觉得好用的话，可以看看作者做的其他插件。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label("目前是示例内容", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)

                ForEach(Array(plugins.enumerated()), id: \.element.id) { index, plugin in
                    NavigationLink(destination: PromoDetailView(plugin: plugin)) {
                        PromoCard(plugin: plugin, startDelay: Double(index) * 0.9)
                    }
                    .buttonStyle(PromoPressStyle())
                }
            }
            .padding(16)
        }
        .navigationTitle("更多插件")
    }
}

/// 一张插件卡片：背景轮播截图（模糊 + 渐隐切换，慢慢推近），底部是图标、名字、简介和「详情」
struct PromoCard: View {
    let plugin: PromoPlugin
    /// 每张卡错开开始轮播，免得同时切换
    var startDelay: Double = 0

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .aspectRatio(1.45, contentMode: .fit)
            .overlay { background }
            .overlay(alignment: .bottom) { footer }
            .overlay(alignment: .topTrailing) { indicator }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            .task { await autoplay() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(plugin.name)，\(plugin.tagline)")
            .accessibilityHint("查看详情")
    }

    private var background: some View {
        ZStack {
            if plugin.shots.indices.contains(index) {
                PromoSlide(image: plugin.shots[index], drifts: !reduceMotion)
                    .id(index)
                    .transition(reduceMotion ? .opacity : .promoBlurFade)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            PromoIconView(plugin: plugin, size: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(plugin.tagline)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(spacing: 4) {
                Text("详情")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.24), in: Capsule())
                Text(plugin.status)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.72))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background {
            // 底部一条渐变模糊（像 App Store 的游戏卡片），文字压在上面也看得清
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private var indicator: some View {
        HStack(spacing: 4) {
            ForEach(plugin.shots.indices, id: \.self) { item in
                Capsule()
                    .fill(Color.white.opacity(item == index ? 0.95 : 0.4))
                    .frame(width: item == index ? 14 : 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.18), in: Capsule())
        .padding(12)
        .animation(.easeInOut(duration: 0.3), value: index)
        .accessibilityHidden(true)
    }

    /// 卡片在屏幕上时自动轮播；划出屏幕时任务取消，不白耗电
    private func autoplay() async {
        guard plugin.shots.count > 1 else { return }
        var delay = 3.0 + startDelay
        while true {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.4 : 1.1)) {
                index = (index + 1) % plugin.shots.count
            }
            delay = 3.8
        }
    }
}

/// 轮播里的一张：出现后慢慢推近一点（Ken Burns），切换时更有层次
private struct PromoSlide: View {
    let image: PromoImage
    let drifts: Bool
    @State private var zoomed = false

    var body: some View {
        PromoImageView(image: image)
            .scaleEffect(zoomed ? 1.08 : 1)
            .onAppear {
                guard drifts else { return }
                withAnimation(.linear(duration: 6)) { zoomed = true }
            }
    }
}

private struct PromoBlurFade: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 22 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 1.06 : 1)
    }
}

extension AnyTransition {
    /// 模糊 + 渐隐 + 轻微缩放的切换
    static var promoBlurFade: AnyTransition {
        .modifier(active: PromoBlurFade(active: true), identity: PromoBlurFade(active: false))
    }
}

/// 按下时轻微缩小的卡片按钮
struct PromoPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - 详情页

struct PromoDetailView: View {
    let plugin: PromoPlugin

    @State private var viewer: ViewerTarget?

    struct ViewerTarget: Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                infoStrip
                screenshots
                about
                if !plugin.features.isEmpty { features }
                if !plugin.tags.isEmpty { tags }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle(plugin.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewer) { target in
            PromoGalleryViewer(images: plugin.shots, start: target.index)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PromoIconView(plugin: plugin, size: 108)
            VStack(alignment: .leading, spacing: 6) {
                Text(plugin.name)
                    .font(.title2.weight(.bold))
                Text(plugin.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer(minLength: 4)
                if let link = plugin.link {
                    Link(destination: link) {
                        Text("获取")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 6)
                            .background(Color.accentColor, in: Capsule())
                    }
                } else {
                    Text(plugin.status)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .frame(minHeight: 108, alignment: .topLeading)
        }
        .padding(.horizontal)
    }

    private var infoStrip: some View {
        HStack(spacing: 0) {
            infoItem("类别", plugin.category)
            Divider().frame(height: 32)
            infoItem("状态", plugin.status)
            Divider().frame(height: 32)
            infoItem("预览", "\(plugin.shots.count) 张")
        }
        .padding(.horizontal)
    }

    private func infoItem(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    /// 截图横着划，点一张全屏看（可以双指放大）
    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("预览")
                .font(.title3.weight(.bold))
                .padding(.horizontal)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(plugin.shots.enumerated()), id: \.offset) { index, image in
                        Button {
                            viewer = ViewerTarget(index: index)
                        } label: {
                            PromoImageView(image: image, showsCaption: true)
                                .frame(width: 210, height: 420)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(PromoPressStyle())
                        .accessibilityLabel("第 \(index + 1) 张预览图")
                    }
                }
                .promoSnapLayout()
            }
            .promoSnapBehavior()
            .hideScrollIndicators()
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("介绍")
                .font(.title3.weight(.bold))
            Text(plugin.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("功能")
                .font(.title3.weight(.bold))
            ForEach(plugin.features, id: \.self) { feature in
                Label {
                    Text(feature)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(PromoCatalog.color(plugin.palette.first ?? "#888888"))
                }
                .font(.callout)
            }
        }
        .padding(.horizontal)
    }

    private var tags: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(plugin.tags, id: \.self) { tag in
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
}

private extension View {
    /// iOS 17 起截图按张对齐停住；旧系统普通滚动
    @ViewBuilder
    func promoSnapLayout() -> some View {
        if #available(iOS 17, *) {
            scrollTargetLayout()
        } else {
            padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    func promoSnapBehavior() -> some View {
        if #available(iOS 17, *) {
            scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, 16, for: .scrollContent)
        } else {
            self
        }
    }
}

// MARK: - 全屏看图

/// 全屏看截图：左右划切换，双指 / 双击放大，放大后可以拖动；往下划或点 × 关闭
struct PromoGalleryViewer: View {
    let images: [PromoImage]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(images: [PromoImage], start: Int) {
        self.images = images
        _index = State(initialValue: start)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.offset) { item, image in
                    PromoZoomableImage(image: image) { dismiss() }
                        .tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            HStack {
                Text("\(index + 1) / \(images.count)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.15), in: Capsule())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.15), in: Circle())
                }
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .statusBar(hidden: true)
    }
}

private struct PromoZoomableImage: View {
    let image: PromoImage
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private var zoomed: Bool { scale > 1.01 }

    var body: some View {
        GeometryReader { geometry in
            let fit = fitSize(in: geometry.size)
            PromoImageView(image: image, showsCaption: true)
                .frame(width: fit.width, height: fit.height)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if zoomed {
                            reset()
                        } else {
                            scale = 2.5
                            baseScale = 2.5
                        }
                    }
                }
                .simultaneousGesture(magnify)
                // 放大后拖动看细节（这时不翻页）；没放大时往下划关闭
                .gesture(pan, including: zoomed ? GestureMask.all : GestureMask.none)
                .simultaneousGesture(dismissDrag, including: zoomed ? GestureMask.none : GestureMask.all)
        }
    }

    /// 截图按 1:2 的比例放进屏幕，上下留出按钮的位置
    private func fitSize(in size: CGSize) -> CGSize {
        let aspect: CGFloat = 0.5
        var width = max(size.width - 32, 1)
        var height = width / aspect
        let maxHeight = max(size.height - 120, 1)
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(baseScale * value, 1), 4)
            }
            .onEnded { _ in
                if scale <= 1.01 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { reset() }
                } else {
                    baseScale = scale
                }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                if value.translation.height > 120, abs(value.translation.width) < value.translation.height {
                    onDismiss()
                }
            }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

// MARK: - 图片和图标

struct PromoImageView: View {
    let image: PromoImage
    var showsCaption = false

    var body: some View {
        switch image {
        case .art(let art):
            PromoArtView(art: art, showsCaption: showsCaption)
        case .remote(let url):
            PosterImage(url: url)
        }
    }
}

/// 插件图标：插件配色的光斑底 + SF 符号
struct PromoIconView: View {
    let plugin: PromoPlugin
    let size: CGFloat

    var body: some View {
        ZStack {
            PromoArtView(art: PromoArt(palette: plugin.palette, style: .aurora, seed: Self.seed(plugin.id)))
            Image(systemName: plugin.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.02)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    /// 由 id 算出固定的随机种子（每次启动图标都一样）
    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

/// 固定种子的随机数（同一张图每次画出来都一样）
struct PromoRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// 把 PromoArt 画出来。所有尺寸都按画布大小算，横着的卡片背景和竖着的截图都能用
struct PromoArtView: View {
    let art: PromoArt
    var showsCaption = false

    var body: some View {
        Canvas { context, size in
            Self.draw(art, showsCaption: showsCaption, context: &context, size: size)
        }
    }

    private static func draw(_ art: PromoArt, showsCaption: Bool, context: inout GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let colors = art.palette.map(PromoCatalog.color)
        guard w > 1, h > 1, let last = colors.last else { return }
        var rng = PromoRandom(seed: art.seed)
        func random(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &rng) }
        let side = max(w, h)
        let short = min(w, h)

        // 渐变底
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: w, y: h))
        )

        // 模糊光斑
        var glow = context
        glow.addFilter(.blur(radius: side * 0.08))
        for index in 0..<5 {
            let radius = side * random(0.18...0.4)
            let center = CGPoint(x: w * random(-0.1...1.1), y: h * random(-0.1...1.1))
            glow.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(colors[index % colors.count].opacity(0.85))
            )
        }

        switch art.style {
        case .aurora:
            var soft = context
            soft.addFilter(.blur(radius: short * 0.05))
            for band in 0..<3 {
                let y = h * (0.22 + 0.2 * CGFloat(band))
                var path = Path()
                path.move(to: CGPoint(x: -w * 0.1, y: y))
                path.addCurve(
                    to: CGPoint(x: w * 1.1, y: y + h * random(-0.12...0.12)),
                    control1: CGPoint(x: w * 0.3, y: y - h * random(0.05...0.2)),
                    control2: CGPoint(x: w * 0.7, y: y + h * random(0.05...0.2))
                )
                soft.stroke(path, with: .color(.white.opacity(0.32)), lineWidth: short * 0.08)
            }

        case .waves:
            for band in 0..<5 {
                let baseY = h * (0.42 + CGFloat(band) * 0.11)
                let amplitude = h * random(0.02...0.06)
                let frequency = random(1.2...2.6)
                let phase = random(0...(CGFloat.pi * 2))
                var path = Path()
                path.move(to: CGPoint(x: 0, y: baseY))
                for step in 0...48 {
                    let x = w * CGFloat(step) / 48
                    path.addLine(to: CGPoint(x: x, y: baseY + sin(x / w * CGFloat.pi * 2 * frequency + phase) * amplitude))
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.closeSubpath()
                context.fill(path, with: .color(.white.opacity(0.07 + 0.04 * Double(band))))
            }

        case .stars:
            for _ in 0..<90 {
                let x = w * random(0...1)
                let y = h * random(0...1)
                let radius = random(0.6...2.2)
                context.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(.white.opacity(Double(random(0.3...0.95))))
                )
            }
            // 星座连线
            var points: [CGPoint] = []
            for _ in 0..<6 {
                points.append(CGPoint(x: w * random(0.12...0.88), y: h * random(0.3...0.8)))
            }
            points.sort { $0.x < $1.x }
            var line = Path()
            line.addLines(points)
            context.stroke(line, with: .color(.white.opacity(0.45)), lineWidth: 1)
            for point in points {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.white))
            }
            // 月牙：在圆里挖掉一个错开的圆
            let moonRadius = short * 0.14
            let moonCenter = CGPoint(x: w * 0.76, y: h * 0.2)
            let moonRect = CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius, width: moonRadius * 2, height: moonRadius * 2)
            var moon = context
            moon.clip(to: Path(ellipseIn: moonRect))
            var crescent = Path(ellipseIn: moonRect)
            crescent.addEllipse(in: moonRect.offsetBy(dx: moonRadius * 0.55, dy: -moonRadius * 0.25))
            moon.fill(crescent, with: .color(.white.opacity(0.92)), style: FillStyle(eoFill: true))

        case .grid:
            let horizon = h * 0.58
            let sunRadius = short * 0.22
            let sunRect = CGRect(x: w / 2 - sunRadius, y: horizon - sunRadius * 1.5, width: sunRadius * 2, height: sunRadius * 2)
            context.fill(
                Path(ellipseIn: sunRect),
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.95), last.opacity(0.5)]),
                    startPoint: CGPoint(x: sunRect.midX, y: sunRect.minY), endPoint: CGPoint(x: sunRect.midX, y: sunRect.maxY)
                )
            )
            context.fill(Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)), with: .color(.black.opacity(0.28)))
            var grid = Path()
            for column in -8...8 {
                grid.move(to: CGPoint(x: w / 2 + CGFloat(column) * w * 0.04, y: horizon))
                grid.addLine(to: CGPoint(x: w / 2 + CGFloat(column) * w * 0.36, y: h))
            }
            var y = horizon
            var step = h * 0.012
            while y < h {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: w, y: y))
                y += step
                step *= 1.35
            }
            context.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 1)

        case .lyrics:
            let count = 7
            let lineHeight = max(h * 0.032, 6)
            let gap = h * 0.045
            let top = h * 0.52 - CGFloat(count) * (lineHeight + gap) / 2
            let current = Int.random(in: 2...4, using: &rng)
            for line in 0..<count {
                let rect = CGRect(x: w * 0.1, y: top + CGFloat(line) * (lineHeight + gap), width: w * random(0.35...0.8), height: lineHeight)
                let path = Path(roundedRect: rect, cornerRadius: lineHeight / 2)
                if line == current {
                    context.fill(path, with: .color(.white.opacity(0.3)))
                    let done = CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.6, height: rect.height)
                    context.fill(Path(roundedRect: done, cornerRadius: lineHeight / 2), with: .color(.white.opacity(0.95)))
                } else {
                    context.fill(path, with: .color(.white.opacity(line < current ? 0.16 : 0.3)))
                }
            }

        case .cards:
            let cardWidth = w * 0.64
            let cardHeight = min(h * 0.24, cardWidth * 0.7)
            for layer in 0..<3 {
                let rect = CGRect(
                    x: (w - cardWidth) / 2 + CGFloat(2 - layer) * w * 0.035,
                    y: h * 0.4 + CGFloat(layer) * cardHeight * 0.32,
                    width: cardWidth, height: cardHeight
                )
                let corner = short * 0.04
                let opacity = [0.16, 0.26, 0.88][layer]
                context.fill(Path(roundedRect: rect, cornerRadius: corner), with: .color(.white.opacity(opacity)))
                if layer == 2 {
                    // 最前面那张画几条内容
                    let inset = cardWidth * 0.08
                    let barHeight = max(cardHeight * 0.1, 3)
                    for bar in 0..<3 {
                        let width = (cardWidth - inset * 2) * [0.7, 0.9, 0.5][bar]
                        let barRect = CGRect(x: rect.minX + inset, y: rect.minY + inset + CGFloat(bar) * barHeight * 2, width: width, height: barHeight)
                        context.fill(Path(roundedRect: barRect, cornerRadius: barHeight / 2), with: .color(colors[bar % colors.count].opacity(0.75)))
                    }
                }
            }

        case .rings:
            let center = CGPoint(x: w * random(0.35...0.65), y: h * random(0.45...0.62))
            for ring in 1...7 {
                let radius = short * 0.075 * CGFloat(ring)
                context.stroke(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(.white.opacity(0.5 - Double(ring) * 0.055)),
                    lineWidth: 1.5
                )
            }
            let dot = short * 0.03
            context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)), with: .color(.white))
        }

        // 截图上的标题
        if showsCaption, !art.caption.isEmpty {
            let text = Text(art.caption)
                .font(.system(size: max(14, w * 0.08), weight: .heavy))
                .foregroundColor(.white)
            context.draw(text, at: CGPoint(x: w / 2, y: h * 0.1), anchor: .center)
        }
    }
}
