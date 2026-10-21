import SwiftUI
import UIKit

// MARK: - 搜索标签页：点搜索框旁的关闭回到之前的标签

extension EnvironmentValues {
    /// 退出搜索标签页，回到进入搜索前所在的标签
    @Entry var exitSearchTab: @MainActor () -> Void = {}
}

extension View {
    /// 搜索标签页里用的 searchable：关闭搜索（搜索框为空时）就回到之前的标签
    func searchTab(text: Binding<String>, prompt: String) -> some View {
        modifier(SearchTabModifier(text: text, prompt: prompt))
    }
}

private struct SearchTabModifier: ViewModifier {
    @Binding var text: String
    let prompt: String
    @State private var presented = false
    @Environment(\.exitSearchTab) private var exitSearchTab

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, isPresented: $presented, prompt: prompt)
            .onChange(of: presented) { _, isPresented in
                guard !isPresented else { return }
                // 关闭按钮会同时清空文字，等这一轮更新完再判断
                Task { @MainActor in
                    if text.isEmpty { exitSearchTab() }
                }
            }
    }
}
