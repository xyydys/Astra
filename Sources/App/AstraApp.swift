import SwiftUI
import UIKit
import AVFoundation

@main
struct AstraApp: App {
    @StateObject private var ruleStore = RuleStore()

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
            .tint(.pink)
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
        }
        .background {
            HiddenWebViewHost(webView: XPathEngine.shared.webView)
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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

    var body: some View {
        Menu {
            Picker("内容", selection: Binding(
                get: { mode },
                set: { newMode in
                    if newMode == .comic, !ageConfirmed {
                        askAge = true
                    } else {
                        withAnimation(.smoothCompat) { mode = newMode }
                    }
                }
            )) {
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
}
