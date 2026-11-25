import SwiftUI

/// Uses only system controls: no lyrics, glass overrides, UIKit bridges,
/// global accents, or work on foregrounding. Match Astra's tab structure.
@available(iOS 26, *)
struct TabBarForegroundControl: View {
    var body: some View {
        TabView {
            Tab("首页", systemImage: "house") {
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        Text("原生深色首页").foregroundStyle(.white)
                    }
                    .toolbarVisibility(.hidden, for: .navigationBar)
                }
            }
            Tab("收藏", systemImage: "heart") { Text("原生收藏") }
            Tab("历史", systemImage: "clock.arrow.circlepath") { Text("原生历史") }
            Tab("我的", systemImage: "person.crop.circle") {
                NavigationStack {
                    List(1...60, id: \.self) { index in
                        Text("原生浅色列表 \(index)")
                    }
                    .navigationTitle("我的")
                }
            }
            Tab("搜索", systemImage: "magnifyingglass", role: .search) {
                NavigationStack {
                    Text("原生搜索")
                        .navigationTitle("搜索")
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
