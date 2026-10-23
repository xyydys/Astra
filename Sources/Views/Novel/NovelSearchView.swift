import SwiftUI

/// 小说搜索：并发搜所有启用的书源，同名同作者的结果合并成一本
struct NovelSearchView: View {
    @State private var query = ""
    @StateObject private var model = NovelSearchModel()
    @ObservedObject private var store = BookSourceStore.shared
    @AppStorage("novelSearchGroup") private var group = ""

    private let grid = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 14)]

    private var sources: [BookSource] {
        store.searchable.filter { group.isEmpty || $0.groups.contains(group) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.isSearching || (model.total > 0 && !model.groups.isEmpty) {
                    HStack(spacing: 10) {
                        if model.isSearching {
                            ProgressView(value: Double(model.done), total: Double(max(model.total, 1)))
                                .frame(maxWidth: 120)
                            Text("\(model.done)/\(model.total) 个书源")
                        } else {
                            Text("\(model.groups.count) 本 · 搜了 \(model.total) 个书源" + (model.failed > 0 ? "，\(model.failed) 个没响应" : ""))
                        }
                        Spacer()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                }
                LazyVGrid(columns: grid, spacing: 18) {
                    ForEach(model.groups) { item in
                        let book = item.display
                        let subject = NovelLibrary.shared.prepare(book, candidates: item.books)
                        NavigationLink(destination: AppDestination(subject)) {
                            BookCard(book: book, subtitle: subtitle(item))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .dismissKeyboardOnScroll()
        .overlay {
            if model.groups.isEmpty, !model.isSearching {
                if store.isLoaded, store.searchable.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView("没有可用的书源", systemImage: "text.book.closed",
                                               description: Text("导入「阅读」（Legado）格式的书源后才能搜书"))
                        NavigationLink("管理书源") { BookSourcesView() }
                            .glassProminentButtonStyle()
                    }
                } else if model.keyword.isEmpty {
                    EmptyStateView("搜索小说", systemImage: "text.magnifyingglass",
                                           description: Text("同时在 \(sources.count) 个书源里搜索书名或作者"))
                } else {
                    EmptyStateView.search(text: model.keyword)
                }
            }
        }
        .navigationTitle("搜索")
        .searchTab(text: $query, prompt: "书名或作者")
        .onSubmit(of: .search) {
            model.search(query, sources: sources)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.isSearching {
                    Button("停止", icon: "stop.fill") { model.cancel() }
                } else if store.groups.count > 1 {
                    Menu {
                        Picker("搜索范围", selection: $group) {
                            Text("全部书源").tag("")
                            ForEach(store.groups, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        Image(systemName: group.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
        }
        .task { await store.load() }
    }

    private func subtitle(_ item: NovelSearchModel.Group) -> String {
        let author = item.author.isEmpty ? "佚名" : item.author
        return item.books.count > 1 ? "\(author) · \(item.books.count) 源" : author
    }
}
