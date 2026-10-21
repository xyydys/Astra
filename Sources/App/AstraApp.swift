import SwiftUI
import UIKit
import SwiftData
import AVFoundation

@main
struct AstraApp: App {
    @State private var ruleStore = RuleStore()

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
                    UITestHarness(scenario: scenario)
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            .environment(ruleStore)
            .tint(.pink)
        }
        .modelContainer(for: [FavoriteItem.self, WatchRecord.self])
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
        TabView(selection: $tab) {
            Tab("首页", systemImage: "house", value: AppTab.home) {
                NavigationStack {
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
                    .appDestinations()
                }
            }
            Tab("收藏", systemImage: "heart", value: AppTab.favorites) {
                NavigationStack {
                    Group {
                        if mode == .music { MusicTrackListView(kind: .favorites) } else { FavoritesView() }
                    }
                    .appDestinations()
                }
            }
            Tab("历史", systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                NavigationStack {
                    Group {
                        if mode == .music { MusicTrackListView(kind: .history) } else { HistoryView() }
                    }
                    .appDestinations()
                }
            }
            Tab("我的", systemImage: "person.crop.circle", value: AppTab.settings) {
                NavigationStack {
                    SettingsView().appDestinations()
                }
            }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack {
                    SearchView().appDestinations()
                }
                .environment(\.exitSearchTab) {
                    if tab == .search { tab = tabBeforeSearch }
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: tab) { old, new in
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
                        withAnimation(.smooth) { mode = newMode }
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
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("切换内容：当前\(mode.title)")
        .alert("成人内容提示", isPresented: $askAge) {
            Button("取消", role: .cancel) {}
            Button("我已满 18 岁") {
                ageConfirmed = true
                withAnimation(.smooth) { mode = .comic }
            }
        } message: {
            Text("漫画模式的资源来自禁漫天堂，含有成人内容，仅限已满 18 岁的用户使用。请先了解当地法律。")
        }
    }
}
