import SwiftUI
import UniformTypeIdentifiers

/// 音乐搜索：默认「全部」把各平台的结果交错合并，后面是单个平台的标签。
/// 和洛雪音乐一样，搜索用平台接口，播放地址交给音源。搜索框为空时显示搜索历史。
struct MusicSearchView: View {
    /// "all" 或平台的 rawValue
    @AppStorage("musicSearchScope") private var scope = "all"
    /// 搜索历史，换行分隔，最近的在前
    @AppStorage("musicSearchHistory") private var historyRaw = ""
    @State private var query = ""
    @State private var searched = ""
    @State private var results: [MusicTrack] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var exhausted = false
    @State private var error: String?
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var sources = LXSourceStore.shared

    private static let historyLimit = 20

    private var platform: MusicPlatform? { MusicPlatform(rawValue: scope) }

    private var history: [String] {
        historyRaw.split(separator: "\n").map(String.init)
    }

    private var showsHistory: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !history.isEmpty
    }

    /// 「全部」搜的平台：有音源时只搜音源支持的（搜出来能放），否则全搜
    private var aggregatePlatforms: [MusicPlatform] {
        let supported = MusicPlatform.searchable.filter { sources.supports($0) }
        return sources.active == nil || supported.isEmpty ? MusicPlatform.searchable : supported
    }

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $scope) {
                    Text("全部").tag("all")
                    ForEach(MusicPlatform.searchable) { item in
                        Text(item.short).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                if let platform, sources.active != nil, !sources.supports(platform) {
                    Label("当前音源不支持\(platform.name)，搜到的歌可能放不了", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if showsHistory {
                historySection
            } else {
                resultSection
            }
        }
        .listStyle(.plain)
        .dismissKeyboardOnScroll()
        .overlay {
            if !showsHistory, results.isEmpty, !isLoading {
                if searched.isEmpty {
                    EmptyStateView("搜索音乐", systemImage: "music.magnifyingglass",
                                           description: Text(sources.entries.isEmpty
                                                             ? "还没有导入洛雪音源：到「我的 → 音乐 → 音源管理」导入后才能播放"
                                                             : "当前音源：\(sources.active?.info.name ?? "")"))
                } else if error == nil {
                    EmptyStateView.search(text: searched)
                }
            }
        }
        .navigationTitle("搜索")
        .searchTab(text: $query, prompt: "歌名、歌手")
        .onSubmit(of: .search) { Task { await search() } }
        .onChangeCompat(of: scope) {
            if !searched.isEmpty { Task { await search(keyword: searched) } }
        }
    }

    private var historySection: some View {
        Section {
            ForEach(history, id: \.self) { word in
                Button {
                    query = word
                    Task { await search(keyword: word) }
                } label: {
                    Label(word, systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.primary)
                }
                .swipeActions {
                    Button("删除", icon: "trash", role: .destructive) { removeHistory(word) }
                }
            }
        } header: {
            HStack(alignment: .center) {
                Text("搜索历史")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("清空", icon: "trash") { historyRaw = "" }
                    .font(.footnote.weight(.medium))
                    .glassButtonStyle()
                    .controlSize(.small)
                    .textCase(nil)
            }
            .textCase(nil)
        }
    }

    private var resultSection: some View {
        Section {
            ForEach(results) { track in
                Button {
                    player.play(track, in: results)
                } label: {
                    MusicTrackRow(track: track, isCurrent: player.current?.id == track.id)
                }
                .buttonStyle(.plain)
                .contextMenu { MusicTrackMenu(track: track) }
                .onAppear {
                    if track.id == results.last?.id { Task { await loadMore() } }
                }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error {
                Button("加载失败，点击重试：\(error)") { Task { await loadMore() } }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func search(keyword: String? = nil) async {
        let key = (keyword ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        remember(key)
        searched = key
        results = []
        page = 1
        exhausted = false
        error = nil
        isLoading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading, !exhausted, !searched.isEmpty else { return }
        isLoading = true
        error = nil
        let key = searched, target = scope, current = page
        do {
            let list: [MusicTrack]
            if let platform = MusicPlatform(rawValue: target) {
                list = try await MusicPlatformAPI.search(platform, keyword: key, page: current)
            } else {
                list = try await MusicPlatformAPI.searchAll(aggregatePlatforms, keyword: key, page: current)
            }
            guard key == searched, target == scope else { return }
            let ids = Set(results.map(\.id))
            let keys = Set(results.map(\.dedupeKey))
            let fresh = list.filter { !ids.contains($0.id) && (platform != nil || !keys.contains($0.dedupeKey)) }
            results += fresh
            page += 1
            if list.isEmpty { exhausted = true }
        } catch {
            if key == searched, target == scope { self.error = error.localizedDescription }
        }
        if key == searched, target == scope { isLoading = false }
    }

    private func remember(_ word: String) {
        var list = history.filter { $0 != word }
        list.insert(word, at: 0)
        historyRaw = list.prefix(Self.historyLimit).joined(separator: "\n")
    }

    private func removeHistory(_ word: String) {
        historyRaw = history.filter { $0 != word }.joined(separator: "\n")
    }
}

// MARK: - 音源管理

struct MusicSourcesView: View {
    @ObservedObject private var store = LXSourceStore.shared
    @AppStorage(LXSourceStore.qualityKey) private var quality = "320k"
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var showFileImporter = false
    @State private var importing = false
    @State private var message: String?
    @State private var logs: [String] = []

    var body: some View {
        List {
            Section {
                ForEach(store.entries) { entry in
                    Button {
                        store.activate(entry.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.id == store.active?.id ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(entry.id == store.active?.id ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.info.name + (entry.info.version.isEmpty ? "" : "  v" + entry.info.version))
                                    .font(.body)
                                if !entry.info.description.isEmpty {
                                    Text(entry.info.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text(entry.platformNames + (entry.info.author.isEmpty ? "" : " · 作者 \(entry.info.author)"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        if entry.isRemote {
                            Button("更新", icon: "arrow.clockwise") { update([entry]) }
                                .tint(.blue)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { store.delete(store.entries[index].id) }
                }
                if store.entries.isEmpty {
                    Text("还没有音源")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("洛雪音源")
            } footer: {
                Text("兼容洛雪音乐（LX Music）的自定义音源脚本，音源需要自己找。搜索、歌词和封面由 App 直接请求各平台，只有播放地址交给音源获取。点一下切换正在使用的音源。")
            }

            Section {
                Picker("首选音质", selection: $quality) {
                    Text("标准 128k").tag("128k")
                    Text("高品 320k").tag("320k")
                    Text("无损 FLAC").tag("flac")
                    Text("Hi-Res").tag("flac24bit")
                }
            } footer: {
                Text("音源或歌曲不支持时自动降一档，取不到再用 128k 重试。")
            }

            if !logs.isEmpty {
                Section("音源日志") {
                    ForEach(Array(logs.suffix(30).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("音源管理")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("从网址导入", icon: "link") { showURLPrompt = true }
                    Button("从文件导入", icon: "doc") { showFileImporter = true }
                    Button("从剪贴板导入", icon: "doc.on.clipboard") { importClipboard() }
                    Divider()
                    Button("更新全部网址音源", icon: "arrow.clockwise") { update(store.entries.filter(\.isRemote)) }
                        .disabled(!store.entries.contains(where: \.isRemote))
                } label: {
                    if importing { ProgressView() } else { Image(systemName: "plus") }
                }
                .disabled(importing)
            }
        }
        .textFieldAlert(
            "从网址导入", isPresented: $showURLPrompt, text: $urlText,
            placeholder: "https://…/source.js", confirm: "导入", isURL: true
        ) {
            run { try await store.importURL(urlText) }
        }
        .alert("音源", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .filePicker(isPresented: $showFileImporter) { data, name in
            let script = TextDecoding.string(from: data)
            run { try await store.importScript(script, origin: name) }
        }
        .refreshable {
            let remote = store.entries.filter(\.isRemote)
            guard !remote.isEmpty else { return }
            update(remote)
        }
        .task {
            logs = store.logs()
        }
    }

    /// 从导入时的网址重新下载音源脚本
    private func update(_ entries: [LXSourceEntry]) {
        guard !entries.isEmpty else { return }
        Haptics.tap()
        importing = true
        Task {
            var done: [String] = [], failed: [String] = []
            for entry in entries {
                do {
                    _ = try await store.importURL(entry.origin)
                    done.append(entry.info.name)
                } catch {
                    failed.append(entry.info.name)
                }
            }
            importing = false
            message = (done.isEmpty ? "" : "已更新：\(done.joined(separator: "、"))") + (failed.isEmpty ? "" : "\n更新失败：\(failed.joined(separator: "、"))")
            failed.isEmpty ? Haptics.success() : Haptics.failure()
            logs = store.logs()
        }
    }

    private func importClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            message = "剪贴板是空的"
            return
        }
        if EngineURL.isAbsolute(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            run { try await store.importURL(text) }
        } else {
            run { try await store.importScript(text) }
        }
    }

    private func run(_ work: @escaping () async throws -> LXSourceEntry) {
        importing = true
        Task {
            do {
                let entry = try await work()
                message = "已导入「\(entry.info.name)」：支持 \(entry.platformNames)"
            } catch {
                message = "导入失败：\(error.localizedDescription)"
            }
            importing = false
            logs = store.logs()
        }
    }
}

/// 设置页里的「音乐」分组
struct MusicSettingsSection: View {
    @ObservedObject private var store = LXSourceStore.shared

    var body: some View {
        Section {
            NavigationLink {
                MusicSourcesView()
            } label: {
                LabeledRow {
                    Text(store.active?.info.name ?? "未导入")
                } label: {
                    Label("音源管理", systemImage: "music.note.list")
                }
            }
        } header: {
            Text("音乐")
        } footer: {
            Text("播放地址来自洛雪音乐的自定义音源；歌词动画移植自开源播放器 Folia。")
        }
    }
}
