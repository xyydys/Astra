import SwiftUI
import UIKit
import AVFoundation

@main
struct AstraApp: App {
    @StateObject private var ruleStore = RuleStore()
    @AppStorage(AppAccent.key) private var accentHex = ""

    init() {
        #if DEBUG
        UITestScenario.redirectOutput()
        #endif
        NovelEngineSetup.install()
        AppBackup.prepareFolder()
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #if DEBUG
        UITestScenario.prepare()
        UITestScenario.startBarDump()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // UI 测试用的场景（只在 Debug 编译、带启动参数时出现）
                if let scenario = UITestScenario.current {
                    if #available(iOS 26, *) {
                        UITestHarness(scenario: scenario)
                    } else {
                        RootView()
                    }
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            .environmentObject(ruleStore)
            .tint(AppAccent.color(accentHex))
            .accentColor(AppAccent.color(accentHex))
            .onAppear { AppAccent.applyToWindows(accentHex) }
            .onChangeCompat(of: accentHex) { AppAccent.applyToWindows(accentHex) }
        }
    }
}

enum AppTab: Hashable {
    case home, favorites, history, settings, search
}

struct RootView: View {
    @State private var tab: AppTab = .home
    /// 进入搜索标签前所在的标签，关闭搜索时回到这里
    @State private var tabBeforeSearch: AppTab = .home
    @AppStorage(AppSettings.contentModeKey) private var mode: ContentMode = .anime
    @EnvironmentObject private var ruleStore: RuleStore
    /// 从其他 App 打开的文件的导入结果
    @State private var incomingMessage: String?
    @State private var incomingBackup: IncomingBackup?

    struct IncomingBackup: Identifiable {
        let id = UUID()
        let name: String
        let archive: AppBackup.Archive
        let summary: AppBackup.Summary
    }

    var body: some View {
        Group {
            if #available(iOS 18, *) {
                modernTabs
            } else {
                legacyTabs
            }
        }
        .onChangeCompat(of: tab) { old, new in
            if new == .search, old != .search { tabBeforeSearch = old }
            updateTabBarStyle()
        }
        .onChangeCompat(of: mode) { updateTabBarStyle() }
        .onAppear {
            updateTabBarStyle()
            // 冷启动时 TabView 底下的 UITabBarController 可能还没建好，稍后再设一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { updateTabBarStyle() }
        }
        .onOpenURL { url in
            Task {
                switch await IncomingFile.handle(url, rules: ruleStore) {
                case .message(let text): incomingMessage = text
                case .backup(let name, let archive, let summary):
                    incomingBackup = IncomingBackup(name: name, archive: archive, summary: summary)
                case nil: break
                }
            }
        }
        .alert("导入", isPresented: Binding(get: { incomingMessage != nil }, set: { if !$0 { incomingMessage = nil } })) {
            Button("好") { incomingMessage = nil }
        } message: {
            Text(incomingMessage ?? "")
        }
        .alert("恢复备份", isPresented: Binding(get: { incomingBackup != nil }, set: { if !$0 { incomingBackup = nil } }), presenting: incomingBackup) { item in
            Button("取消", role: .cancel) {}
            Button("恢复") { restore(item) }
        } message: { item in
            Text("\(item.name)\n\n\(item.summary.text.isEmpty ? "备份是空的" : item.summary.text)\n\n片源、书源、音源、书架和设置会换成备份里的内容，收藏和历史会合并。恢复前会自动把当前数据另存一份备份。")
        }
        .background {
            HiddenWebViewHost(webView: XPathEngine.shared.webView)
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 音乐首页是深色的，底栏也要深色；其他页面跟随系统。
    /// 直接改 UIKit 底栏的深浅：用 SwiftUI 的 toolbarColorScheme 切换标签时生效很慢，
    /// 经常停在别的页面了底栏还是上一页的颜色
    private func updateTabBarStyle() {
        let style: UIUserInterfaceStyle = tab == .home && mode == .music ? .dark : .unspecified
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                guard let controller = Self.tabBarController(in: window.rootViewController) else { continue }
                if controller.tabBar.overrideUserInterfaceStyle != style {
                    controller.tabBar.overrideUserInterfaceStyle = style
                }
            }
        }
    }

    private static func tabBarController(in root: UIViewController?) -> UITabBarController? {
        guard let root else { return nil }
        if let controller = root as? UITabBarController { return controller }
        for child in root.children {
            if let found = tabBarController(in: child) { return found }
        }
        return nil
    }

    private func restore(_ item: IncomingBackup) {
        Task {
            do {
                _ = try? await AppBackup.export(prefix: "恢复前自动备份")
                try await AppBackup.restore(item.archive, rules: ruleStore)
                incomingMessage = "已恢复：\(item.summary.text)"
            } catch {
                incomingMessage = "恢复失败：\(error.localizedDescription)"
            }
        }
    }

    /// iOS 18 起的 Tab 写法：iOS 26 上搜索是底栏右侧单独的圆形按钮
    @available(iOS 18, *)
    private var modernTabs: some View {
        TabView(selection: $tab) {
            Tab("首页", systemImage: "house", value: AppTab.home) { homeTab }
            Tab("收藏", systemImage: "heart", value: AppTab.favorites) { favoritesTab }
            Tab("历史", systemImage: "clock.arrow.circlepath", value: AppTab.history) { historyTab }
            Tab("我的", systemImage: "person.crop.circle", value: AppTab.settings) { settingsTab }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { searchTab }
        }
        .tabBarMinimizeOnScroll()
    }

    /// iOS 15 – 17：普通的五个标签
    private var legacyTabs: some View {
        TabView(selection: $tab) {
            homeTab
                .tabItem { Label("首页", systemImage: "house") }
                .tag(AppTab.home)
            favoritesTab
                .tabItem { Label("收藏", systemImage: "heart") }
                .tag(AppTab.favorites)
            historyTab
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)
            settingsTab
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(AppTab.settings)
            searchTab
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
        }
    }

    private var homeTab: some View {
        NavigationStackCompat {
            Group {
                switch mode {
                case .anime: HomeView()
                case .video: VideoHomeView()
                case .comic: ComicHomeView()
                case .novel: NovelHomeView()
                case .music: MusicHomeView()
                }
            }
            .overlay(alignment: .topLeading) {
                ContentModeMenu()
                    .padding(.leading, 16)
                    .padding(.top, 4)
            }
        }
    }

    private var favoritesTab: some View {
        NavigationStackCompat {
            if mode == .music { MusicTrackListView(kind: .favorites) } else { FavoritesView() }
        }
    }

    private var historyTab: some View {
        NavigationStackCompat {
            if mode == .music { MusicTrackListView(kind: .history) } else { HistoryView() }
        }
    }

    private var settingsTab: some View {
        NavigationStackCompat {
            SettingsView()
        }
    }

    private var searchTab: some View {
        NavigationStackCompat {
            SearchView()
        }
        .environment(\.exitSearchTab) {
            if tab == .search { tab = tabBeforeSearch }
        }
    }
}

extension View {
    /// 往下滚动时底栏缩小（iOS 26）
    @ViewBuilder
    func tabBarMinimizeOnScroll() -> some View {
        if #available(iOS 26, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

/// 首页左上角：番剧（Kazumi）/ 影视（LibreTV）切换，点开是系统原生的下拉菜单
struct ContentModeMenu: View {
    @AppStorage(AppSettings.contentModeKey) private var mode: ContentMode = .anime
    /// 禁漫天堂是成人内容，第一次进入漫画模式时确认年龄
    @AppStorage("comicAgeConfirmed") private var ageConfirmed = false
    @State private var askAge = false

    /// 设置里可以改成 UIKit 菜单（音乐播放时更稳），默认是原来的 SwiftUI 菜单
    @AppStorage(ContentModeMenu.nativeKey) private var native = false

    static let nativeKey = "contentModeMenuNative"

    var body: some View {
        Group {
            if native {
                MenuButton(title: mode.title, systemImage: mode.icon, menuKey: mode) {
                    UIMenu.picker(
                        options: ContentMode.allCases.map { MenuOption(value: $0, title: $0.title, subtitle: $0.subtitle, systemImage: $0.icon) },
                        selected: mode
                    ) { select($0) }
                }
                .fixedSize()
                .glass(in: Capsule())
            } else {
                Menu {
                    Picker("内容", selection: Binding(get: { mode }, set: { select($0) })) {
                        ForEach(ContentMode.allCases) { item in
                            Label {
                                Text(item.title)
                                Text(item.subtitle)
                            } icon: {
                                Image(systemName: item.icon)
                            }
                            .tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                        Text(mode.title)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glass(interactive: true, in: Capsule())
            }
        }
        .accessibilityLabel("切换内容：当前\(mode.title)")
        .alert("成人内容提示", isPresented: $askAge) {
            Button("取消", role: .cancel) {}
            Button("我已满 18 岁") {
                ageConfirmed = true
                withAnimation(.smoothCompat) { mode = .comic }
            }
        } message: {
            Text("漫画模式的资源来自禁漫天堂，含有成人内容，仅限已满 18 岁的用户使用。请先了解当地法律。")
        }
    }

    private func select(_ newMode: ContentMode) {
        if newMode == .comic, !ageConfirmed {
            askAge = true
        } else {
            withAnimation(.smoothCompat) { mode = newMode }
        }
    }
}
