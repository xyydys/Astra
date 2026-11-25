import SwiftUI
import WebKit

struct DeviceComparison: View {
    @AppStorage("lab-web-lyrics") private var webLyrics = true
    @State private var query = ""

    var body: some View {
        TabView {
            Tab("首页", systemImage: "house") {
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 20) {
                            ZStack {
                                if webLyrics {
                                    LyricsWebSurface()
                                        .accessibilityHidden(true)
                                } else {
                                    Color.clear.accessibilityHidden(true)
                                }
                                Text("音乐首页")
                                    .font(.largeTitle.bold())
                                    .foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            VStack(spacing: 12) {
                                Picker("歌词渲染", selection: $webLyrics) {
                                    Text("A · 网页容器").tag(true)
                                    Text("B · 无网页容器").tag(false)
                                }
                                .pickerStyle(.segmented)
                                Text("先看首页底栏。点「我的」，再直接回首页，别滑动。也可退到桌面，再回这个首页看一次。")
                                    .font(.footnote)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white.opacity(0.85))
                                HStack(spacing: 28) {
                                    Image(systemName: "backward.fill")
                                    Image(systemName: "play.fill")
                                    Image(systemName: "forward.fill")
                                }
                                .foregroundStyle(.white)
                                .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 18)
                            .environment(\.colorScheme, .dark)
                        }
                    }
                    .toolbarVisibility(.hidden, for: .navigationBar)
                }
            }
            Tab("收藏", systemImage: "heart") { Text("对照收藏") }
            Tab("历史", systemImage: "clock.arrow.circlepath") { Text("对照历史") }
            Tab("我的", systemImage: "person.crop.circle") {
                NavigationStack {
                    List(1...60, id: \.self) { index in
                        Text("浅色对照列表 \(index)")
                    }
                    .navigationTitle("我的")
                }
            }
            Tab("搜索", systemImage: "magnifyingglass", role: .search) {
                NavigationStack {
                    Text("对照搜索")
                        .navigationTitle("搜索")
                        .searchable(text: $query)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

private struct LyricsWebSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.isUserInteractionEnabled = false
        web.loadHTMLString("<meta name='viewport' content='width=device-width'><style>body {background:transparent; margin:0}</style>", baseURL: nil)
        return web
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
