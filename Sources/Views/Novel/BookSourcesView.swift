import SwiftUI

/// 书源管理：导入、启用、排序、检测
struct BookSourcesView: View {
    @State private var store = BookSourceStore.shared
    @State private var query = ""
    @State private var group = ""
    @State private var showImport = false
    @State private var message: String?
    @State private var health: [String: SourceHealth] = [:]
    @State private var checking = false
    @Environment(\.editMode) private var editMode

    enum SourceHealth {
        case checking
        case ok(Int)
        case failed(String)
    }

    private var filtered: [BookSource] {
        store.sources.filter { source in
            (group.isEmpty || source.groups.contains(group))
                && (query.isEmpty || source.bookSourceName.localizedCaseInsensitiveContains(query)
                    || source.bookSourceUrl.localizedCaseInsensitiveContains(query))
        }
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard query.isEmpty, group.isEmpty else { return nil }
        let store = store
        return { store.move(fromOffsets: $0, toOffset: $1) }
    }

    var body: some View {
        List {
            if store.sources.isEmpty, store.isLoaded {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("还没有书源", systemImage: "text.book.closed")
                            .font(.headline)
                        Text("小说内容全部来自你导入的书源。支持「阅读」（Legado 3.x）格式：书源 JSON、JSON 地址，或者 legado:// 一键导入链接。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("导入书源", systemImage: "square.and.arrow.down") { showImport = true }
                            .buttonStyle(.glassProminent)
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Section {
                    ForEach(filtered) { source in
                        row(source)
                    }
                    .onMove(perform: moveAction)
                    .onDelete { offsets in
                        store.delete(Set(offsets.map { filtered[$0].id }))
                    }
                } header: {
                    Text("共 \(store.sources.count) 个，已启用 \(store.searchable.count) 个")
                } footer: {
                    Text("排在前面的书源优先：搜索结果里同一本书默认用排序最靠前的书源。点编辑可以拖动排序。")
                }
            }
        }
        .overlay {
            if !store.isLoaded { ProgressView() }
        }
        .searchable(text: $query, prompt: "书源名称或地址")
        .navigationTitle("书源")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("导入书源", systemImage: "square.and.arrow.down") { showImport = true }
                    Button("从剪贴板导入", systemImage: "doc.on.clipboard") { importClipboard() }
                    Divider()
                    if !store.groups.isEmpty {
                        Picker("分组", selection: $group) {
                            Text("全部分组").tag("")
                            ForEach(store.groups, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button("检测当前列表", systemImage: "checkmark.seal") { Task { await checkAll() } }
                        .disabled(checking || filtered.isEmpty)
                    Button("全部启用", systemImage: "checkmark.circle") { store.setEnabled(Set(filtered.map(\.id)), true) }
                    Button("全部停用", systemImage: "circle") { store.setEnabled(Set(filtered.map(\.id)), false) }
                    Button("删除失效书源", systemImage: "trash", role: .destructive) { deleteFailed() }
                        .disabled(!health.values.contains { if case .failed = $0 { return true } else { return false } })
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $showImport) {
            BookSourceImportView { text in
                showImport = false
                Task { await runImport(text) }
            }
        }
        .alert("书源", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task { await store.load() }
    }

    private func row(_ source: BookSource) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.bookSourceName)
                        .font(.body)
                        .lineLimit(1)
                    if source.hasExplore {
                        Image(systemName: "safari")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(source.groups.isEmpty ? source.bookSourceUrl : source.groups.joined(separator: " · ") + " · " + source.bookSourceUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let state = health[source.id] {
                    switch state {
                    case .checking:
                        Text("检测中…").font(.caption2).foregroundStyle(.secondary)
                    case .ok(let count):
                        Text("可用 · 搜到 \(count) 本").font(.caption2).foregroundStyle(.green)
                    case .failed(let reason):
                        Text("失效 · \(reason)").font(.caption2).foregroundStyle(.red).lineLimit(1)
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { source.enabled }, set: { _ in store.toggle(source.id) }))
                .labelsHidden()
        }
        .contextMenu {
            Button("置顶", systemImage: "arrow.up.to.line") { store.moveToTop(source.id) }
            Button("检测", systemImage: "checkmark.seal") { Task { await check([source]) } }
            Button("删除", systemImage: "trash", role: .destructive) { store.delete([source.id]) }
        }
    }

    private func runImport(_ text: String) async {
        do {
            message = try await store.importText(text)
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    private func importClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            message = "剪贴板是空的"
            return
        }
        Task { await runImport(text) }
    }

    private func checkAll() async {
        await check(filtered.filter { !$0.searchUrl.isEmpty })
    }

    /// 用书源自带的校验关键词（没有就用「我的」）搜一次
    private func check(_ sources: [BookSource]) async {
        checking = true
        for source in sources { health[source.id] = .checking }
        await withTaskGroup(of: (String, SourceHealth).self) { group in
            var index = 0
            while index < min(10, sources.count) {
                let source = sources[index]
                group.addTask { await Self.checkOne(source) }
                index += 1
            }
            while let (id, state) = await group.next() {
                health[id] = state
                if index < sources.count {
                    let source = sources[index]
                    group.addTask { await Self.checkOne(source) }
                    index += 1
                }
            }
        }
        checking = false
    }

    nonisolated private static func checkOne(_ source: BookSource) async -> (String, SourceHealth) {
        let key = source.ruleSearch.checkKeyWord.isEmpty ? "我的" : source.ruleSearch.checkKeyWord
        let env = EngineEnv()
        let timer = Task {
            try? await Task.sleep(for: .seconds(20))
            env.token.cancel()
        }
        defer { timer.cancel() }
        do {
            let books = try await BookEngine.run(env) { env in try WebBook.search(source, key: key, env: env) }
            return (source.id, books.isEmpty ? .failed("没有搜到结果") : .ok(books.count))
        } catch {
            return (source.id, .failed(error.localizedDescription))
        }
    }

    private func deleteFailed() {
        let ids = health.compactMap { id, state -> String? in
            if case .failed = state { return id }
            return nil
        }
        store.delete(Set(ids))
        for id in ids { health[id] = nil }
    }
}

struct BookSourceImportView: View {
    let onImport: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.callout.monospaced())
                        .frame(minHeight: 180)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("粘贴书源地址或 JSON\n一行一个地址，也支持 legado:// 一键导入链接")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button("粘贴剪贴板", systemImage: "doc.on.clipboard") {
                        text = UIPasteboard.general.string ?? text
                    }
                } footer: {
                    Text("书源需要自己找。只支持文字类书源，音频、漫画类书源会被跳过；需要登录的书源暂时用不了。")
                }
            }
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入") { onImport(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// 设置页里的「小说」分组
struct NovelSettingsSection: View {
    @State private var store = BookSourceStore.shared
    @State private var settings = ReaderSettingsStore.shared
    @State private var cacheSize: Int64 = 0
    @State private var showReaderSettings = false

    var body: some View {
        Section {
            NavigationLink {
                BookSourcesView()
            } label: {
                LabeledContent {
                    Text(store.isLoaded ? "\(store.searchable.count) / \(store.sources.count)" : "")
                } label: {
                    Label("书源管理", systemImage: "text.book.closed")
                }
            }
            Button {
                showReaderSettings = true
            } label: {
                Label("阅读排版", systemImage: "textformat.size")
            }
            .foregroundStyle(.primary)
            Button(role: .destructive) {
                NovelLibrary.clearCache()
                cacheSize = 0
            } label: {
                LabeledContent {
                    Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                } label: {
                    Label("清除已缓存的章节", systemImage: "trash")
                }
            }
        } header: {
            Text("小说")
        } footer: {
            Text("兼容「阅读」（Legado）的书源格式，书源需要自己导入。读过的章节会缓存在本机，方便离线看。")
        }
        .task {
            await store.load()
            cacheSize = await Task.detached { NovelLibrary.cacheSize() }.value
        }
        .sheet(isPresented: $showReaderSettings) {
            ReaderSettingsSheet(store: settings)
                .presentationDetents([.medium, .large])
        }
    }
}
