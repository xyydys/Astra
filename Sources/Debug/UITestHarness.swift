#if DEBUG
import SwiftUI
import UIKit

/// 只给 UI 测试用（Debug 编译才有）：启动参数 `-uiTestScenario <名字>` 时显示对应的场景，
/// 在模拟器里复现问题、截图对比，正式包里没有这些代码。
enum UITestScenario {
    static var current: String? {
        UserDefaults.standard.string(forKey: "uiTestScenario")
    }

    /// 启动时（还没有任何视图）准备测试数据：不能放在视图的 init 里，那里改动可观察的状态会让视图反复重建
    @MainActor
    static func prepare() {
        guard let scenario = current else { return }
        resetReaderSettings()
        switch scenario {
        case "novelDetailDark":
            NovelDetailScenario.seed(tint: PosterTint(red: 0.20, green: 0.17, blue: 0.16))
        case "novelDetailMid":
            NovelDetailScenario.seed(tint: PosterTint(red: 0.37, green: 0.34, blue: 0.33))
        default:
            break
        }
    }

    /// 每个场景开始前把阅读设置恢复默认，避免上一次测试留下的状态影响判断
    @MainActor
    static func resetReaderSettings() {
        var settings = ReaderSettings()
        if let raw = UserDefaults.standard.string(forKey: "uiTestPageMode"), let mode = ReaderPageMode(rawValue: raw) {
            settings.pageMode = mode
        }
        ReaderSettingsStore.shared.settings = settings
    }
}

/// 测试场景里的计数（比如阅读器被外层重新创建了多少次），测试读出来看有没有在不停重建
enum UITestProbe {
    static var counts: [String: Int] = [:]

    @discardableResult
    static func tick(_ key: String) -> Int {
        counts[key, default: 0] += 1
        return counts[key, default: 0]
    }

    static var summary: String {
        counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

extension UITestScenario {
    /// `-uiTestLog 文件名` 时把标准输出（含 SwiftUI 的 _printChanges）写进 Documents 下的文件，CI 从模拟器里取出来
    static func redirectOutput() {
        guard let name = UserDefaults.standard.string(forKey: "uiTestLog") else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        freopen(url.path, "a", stdout)
        setvbuf(stdout, nil, _IOLBF, 0)
        print("===== \(UserDefaults.standard.string(forKey: "uiTestLabel") ?? "-") =====")
    }
}

extension UITestScenario {
    /// `-uiTestDumpBars YES` 时每 0.3 秒检查一次底栏、导航栏的状态，有变化就打印（看 SwiftUI 到底改了栏的哪些属性）
    @MainActor
    static func startBarDump() {
        guard UserDefaults.standard.bool(forKey: "uiTestDumpBars") else { return }
        var last = ""
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                let text = describeBars()
                if text != last {
                    last = text
                    print("BARS \(String(format: "%.1f", Date().timeIntervalSince1970)) \(text)")
                }
            }
        }
    }

    @MainActor
    private static func describeBars() -> String {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var parts: [String] = []
        for window in windows {
            for view in allViews(window) {
                if let bar = view as? UITabBar, !bar.isHidden, bar.window != nil {
                    parts.append("tab[" + describe(bar, appearance: bar.standardAppearance, edge: bar.scrollEdgeAppearance) + " selIcon=\(color(bar.standardAppearance.stackedLayoutAppearance.selected.iconColor)) unselTint=\(color(bar.unselectedItemTintColor))]")
                }
                if let bar = view as? UINavigationBar, !bar.isHidden, bar.window != nil, bar.frame.width > 0 {
                    parts.append("nav[" + describe(bar, appearance: bar.standardAppearance, edge: bar.scrollEdgeAppearance) + "]")
                }
            }
        }
        return parts.joined(separator: " ")
    }

    @MainActor
    private static func describe(_ bar: UIView, appearance: UIBarAppearance, edge: UIBarAppearance?) -> String {
        "trait=\(bar.traitCollection.userInterfaceStyle.rawValue) override=\(bar.overrideUserInterfaceStyle.rawValue) tint=\(color(bar.tintColor))"
            + " bgEffect=\(appearance.backgroundEffect.map { String(describing: $0) } ?? "nil") bgColor=\(color(appearance.backgroundColor))"
            + " edge=\(edge == nil ? "nil" : "set:" + (edge!.backgroundEffect.map { String(describing: $0) } ?? "nil") + "/" + color(edge!.backgroundColor))"
    }

    private static func color(_ color: UIColor?) -> String {
        guard let color else { return "nil" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.2f,%.2f,%.2f,%.2f", r, g, b, a)
    }

    @MainActor
    private static func allViews(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { allViews($0) }
    }
}

/// 所有计数，每 0.25 秒刷新一次（不依赖所在视图重绘）
struct UITestCounters: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Text(UITestProbe.summary).font(.system(size: 3)).opacity(0.05).accessibilityIdentifier("probe-all")
        }
    }
}

/// UI 测试只在 iOS 26 模拟器上跑
@available(iOS 26, *)
struct UITestHarness: View {
    let scenario: String

    var body: some View {
        switch scenario {
        case "reader":
            ReaderScenario()
        case "readerInline":
            ReaderInlineScenario()
        case "settingsSheet":
            SettingsSheetScenario(backgroundInteraction: false)
        case "settingsSheetBG":
            SettingsSheetScenario(backgroundInteraction: true)
        case "novelDetailDark", "novelDetailMid":
            NovelDetailScenario()
        default:
            Text("未知场景 \(scenario)")
        }
    }
}

/// 和正式版一样的五个标签，首页放测试内容
/// UI 测试只在 iOS 26 模拟器上跑
@available(iOS 26, *)
private struct TestTabs<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        TabView {
            Tab("首页", systemImage: "house") { content() }
            Tab("收藏", systemImage: "heart") { Text("收藏") }
            Tab("历史", systemImage: "clock.arrow.circlepath") { Text("历史") }
            Tab("我的", systemImage: "person.crop.circle") { Text("我的") }
            Tab("搜索", systemImage: "magnifyingglass", role: .search) { Text("搜索") }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

// MARK: - 阅读器 + 设置 sheet（和正式代码完全一样的 NovelReaderView）

/// UI 测试只在 iOS 26 模拟器上跑
@available(iOS 26, *)
private struct ReaderScenario: View {
    @State private var request: NovelReadRequest?

    var body: some View {
        let _ = Self._printChanges()
        let _ = UITestProbe.tick("parent")
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
            .onAppear { request = Self.makeRequest() }
            .fullScreenCover(item: $request) { request in
                let _ = UITestProbe.tick("coverContent")
                NovelReaderView(request: request)
                    .overlay(alignment: .bottomLeading) { UITestCounters() }
            }
    }

    @MainActor
    static func makeRequest() -> NovelReadRequest? {
        UITestScenario.resetReaderSettings()
        var book = NovelBook()
        book.name = "测试之书"
        book.author = "测试作者"
        book.origin = "uitest://source"
        book.originName = "测试书源"
        book.bookUrl = "uitest://book"
        let chapters = cacheChapters(id: 999_999, origin: book.origin)
        return NovelReadRequest(subjectID: 999_999, book: book, chapters: chapters, chapterIndex: 0, offset: 0)
    }

    /// 目录和正文写进缓存（没有书源也能从缓存读）
    @MainActor
    static func cacheChapters(id: Int, origin: String) -> [NovelChapter] {
        let chapters = (0..<5).map { index -> NovelChapter in
            var chapter = NovelChapter()
            chapter.title = "第\(index + 1)章 测试章节"
            chapter.url = "uitest://chapter/\(index)"
            chapter.index = index
            return chapter
        }
        let text = (1...80).map { "这是第\($0)段测试正文，用来在模拟器里检查阅读器的排版和设置面板能不能正常切换。" }
            .joined(separator: "\n")
        for chapter in chapters {
            NovelLibrary.saveContent(text, id: id, origin: origin, chapter: chapter)
        }
        NovelLibrary.saveChapters(chapters, id: id, origin: origin)
        return chapters
    }
}

/// 阅读器直接当根视图（不经过 fullScreenCover）
/// UI 测试只在 iOS 26 模拟器上跑
@available(iOS 26, *)
private struct ReaderInlineScenario: View {
    @State private var request: NovelReadRequest?

    var body: some View {
        let _ = Self._printChanges()
        let _ = UITestProbe.tick("parent")
        Group {
            if let request {
                NovelReaderView(request: request)
                    .overlay(alignment: .bottomLeading) { UITestCounters() }
            } else {
                Color.clear
            }
        }
        .onAppear {
            if request == nil { request = ReaderScenario.makeRequest() }
        }
    }
}

/// 设置 sheet 单独从普通页面弹出（不在阅读器里），用来区分问题出在 sheet 本身还是阅读器
/// UI 测试只在 iOS 26 模拟器上跑
@available(iOS 26, *)
private struct SettingsSheetScenario: View {
    let backgroundInteraction: Bool
    @State private var show = false
    @ObservedObject private var store = ReaderSettingsStore.shared

    var body: some View {
        VStack(spacing: 12) {
            Text("pageMode=\(store.settings.pageMode.rawValue) margin=\(Int(store.settings.margin))")
                .accessibilityIdentifier("settingsState")
            Button("打开设置") { show = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { UITestScenario.resetReaderSettings() }
        .sheet(isPresented: $show) {
            if backgroundInteraction {
                ReaderSettingsSheet(store: store)
                    .presentationDetents([.height(430), .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(430)))
            } else {
                ReaderSettingsSheet(store: store)
                    .presentationDetents([.height(430), .large])
            }
        }
    }
}

// MARK: - 小说详情（真实页面，假书 + 指定封面色）

/// UI 测试只在 iOS 26 模拟器上跑
@available(iOS 26, *)
private struct NovelDetailScenario: View {
    @State private var path = [NovelDetailScenario.subject]

    static var book: NovelBook {
        var book = NovelBook()
        book.name = "诡秘测试"
        book.author = "测试作者"
        book.kind = "玄幻,异世大陆,完本"
        book.intro = "这是一段测试简介，用来撑出和真实书籍差不多的页面高度。"
        book.origin = "uitest://source"
        book.originName = "测试书源"
        book.bookUrl = "uitest://book/detail"
        return book
    }

    static var subject: BangumiSubject { .novel(book) }

    /// 启动时准备数据：封面色写进取色缓存（PosterTints 第一次用到时从这里读），书、目录、正文写进缓存
    @MainActor
    static func seed(tint: PosterTint) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("poster-tints.json")
        if let data = try? JSONEncoder().encode([subject.id: tint]) { try? data.write(to: url) }
        NovelLibrary.shared.update(book, for: subject.id)
        _ = ReaderScenario.cacheChapters(id: subject.id, origin: book.origin)
    }

    var body: some View {
        TestTabs {
            NavigationStack(path: $path) {
                VStack(spacing: 20) {
                    Text("根页面")
                    NavigationLink("打开详情", value: Self.subject)
                }
                
            }
        }
    }
}
#endif
