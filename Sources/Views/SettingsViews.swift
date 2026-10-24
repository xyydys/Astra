import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @AppStorage(AppSettings.hlsAdFilterKey) private var hlsAdFilter = true
    @AppStorage(AppSettings.filterAdultKey) private var filterAdult = true
    @State private var appIcon = AppIconOption.current
    @AppStorage(AppAccent.key) private var accentHex = ""
    @AppStorage(ContentModeMenu.nativeKey) private var nativeModeMenu = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    RulesView()
                } label: {
                    LabeledRow {
                        Text("\(ruleStore.entries.filter(\.enabled).count) / \(ruleStore.entries.count)")
                    } label: {
                        Label("规则管理", systemImage: "puzzlepiece.extension")
                    }
                }
                Toggle(isOn: $filterAdult) {
                    Label("过滤成人内容", systemImage: "eye.slash")
                }
                .selectionFeedback(trigger: filterAdult)
            } header: {
                Text("片源")
            } footer: {
                Text("Kazumi 规则和采集站在同一个列表里排优先级。过滤成人内容会按分类名隐藏采集站里的相关结果。")
            }

            Section {
                NavigationLink {
                    JMSettingsView()
                } label: {
                    Label("禁漫天堂", systemImage: "book")
                }
            } header: {
                Text("漫画")
            } footer: {
                Text("线路、图片分流和账号。有些本子需要登录才能看。")
            }

            NovelSettingsSection()

            MusicSettingsSection()

            Section {
                Toggle(isOn: $hlsAdFilter) {
                    Label("跳过视频内广告", systemImage: "forward.frame")
                }
                .selectionFeedback(trigger: hlsAdFilter)
            } header: {
                Text("播放")
            } footer: {
                Text("识别并去掉 m3u8 播放列表里插入的广告片段（片头 / 中插）。万一导致某个视频放不了，会自动改用原始播放列表重试。")
            }

            Section {
                NavigationLink {
                    AppIconPicker()
                } label: {
                    LabeledRow {
                        AppIconImage(option: appIcon, size: 30)
                    } label: {
                        Label("应用图标", systemImage: "app.badge")
                    }
                }
                NavigationLink {
                    AccentColorPicker()
                } label: {
                    LabeledRow {
                        Circle().fill(AppAccent.color(accentHex)).frame(width: 22, height: 22)
                    } label: {
                        Label("强调色", systemImage: "paintpalette")
                    }
                }
                NavigationLink {
                    TabIconSettingsView()
                } label: {
                    Label("底栏图标", systemImage: "rectangle.bottomthird.inset.filled")
                }
                Toggle(isOn: $nativeModeMenu) {
                    Label("首页模式菜单显示详情", systemImage: "filemenu.and.selection")
                }
                .selectionFeedback(trigger: nativeModeMenu)
            } header: {
                Text("外观")
            } footer: {
                Text("首页左上角的模式切换菜单，打开后每一项下面显示说明，播放音乐时点按、滑选也更稳定。")
            }

            Section {
                NavigationLink {
                    BackupView()
                } label: {
                    Label("备份与恢复", systemImage: "externaldrive.badge.timemachine")
                }
            } header: {
                Text("数据")
            } footer: {
                Text("片源、书源、音源、书架、收藏、历史和设置一起导出成一个文件，换包名或换设备时在新 App 里导入即可。")
            }

            DiagnosticSettingsSection()

            Section {
                LabeledRow("版本", value: version)
                Link(destination: URL(string: "https://github.com/Predidit/Kazumi")!) {
                    Label("Kazumi 原项目", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://github.com/LibreSpark/LibreTV")!) {
                    Label("LibreTV（影视模式参考）", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://bgm.tv")!) {
                    Label("Bangumi 番组计划", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("关于")
            } footer: {
                Text("Astra 是 Kazumi 的 SwiftUI 移植版，规则格式与原版兼容，按 GPL-3.0 协议开源。影视模式参考 LibreTV 的思路用 Swift 重新实现。番剧信息来自 Bangumi，影视推荐来自豆瓣。应用本身不提供任何视频内容。")
            }
        }
        .navigationTitle("我的")
        .onAppear { appIcon = .current }
    }
}

// MARK: - 禁漫天堂

struct JMSettingsView: View {
    @State private var domains = JMClient.domains
    @State private var domainIndex = JMClient.domainIndex
    @State private var imageStream = JMClient.imageStream
    @State private var imageHost = JMClient.imageHost
    @ObservedObject private var account = JMAccount.shared
    @AppStorage(JMAccount.syncFavoritesKey) private var syncFavorites = true
    @State private var inputName = JMClient.username ?? ""
    @State private var inputPassword = ""
    @State private var working = false
    @State private var message: String?
    /// 测速结果：线路下标 / 分流号 → 文字（「测速中」「120ms」「超时」）
    @State private var domainLatency: [Int: String] = [:]
    @State private var streamLatency: [Int: String] = [:]
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Picker("API 线路", selection: Binding(get: { domainIndex }, set: { index in
                    domainIndex = index
                    JMClient.domainIndex = index
                })) {
                    ForEach(domains.indices, id: \.self) { index in
                        Text("线路 \(index + 1) · \(domains[index])" + (domainLatency[index].map { " · " + $0 } ?? "")).tag(index)
                    }
                }
                Button("刷新线路列表", icon: "arrow.clockwise") {
                    run {
                        await JMClient.prepare(force: true)
                        domains = JMClient.domains
                        domainIndex = JMClient.domainIndex
                        imageHost = JMClient.imageHost
                        return "已刷新，共 \(domains.count) 条线路"
                    }
                }
                Picker("图片分流", selection: Binding(get: { imageStream }, set: { stream in
                    imageStream = stream
                    JMClient.imageStream = stream
                    run {
                        await JMClient.refreshImageHost()
                        imageHost = JMClient.imageHost
                        return "图片服务器：\(imageHost)"
                    }
                })) {
                    ForEach(1...4, id: \.self) { stream in
                        Text("分流 \(stream)" + (streamLatency[stream].map { " · " + $0 } ?? "")).tag(stream)
                    }
                }
                LabeledRow("图片服务器", value: URL(string: imageHost)?.host ?? imageHost)
                Button {
                    Haptics.tap()
                    Task { await testLatency() }
                } label: {
                    HStack {
                        Label("测速", systemImage: "speedometer")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing)
            } header: {
                Text("网络")
            } footer: {
                Text("连不上或加载慢时换条线路 / 分流。线路列表来自禁漫官方分发地址，每半天自动刷新。")
            }

            if let user = account.user {
                Section {
                    JMUserCard(user: user)
                    NavigationLink {
                        JMFavoritesView()
                    } label: {
                        LabeledRow {
                            Text(user.favoritesMax > 0 ? "\(user.favorites) / \(user.favoritesMax)" : "\(user.favorites)")
                        } label: {
                            Label("云端收藏夹", systemImage: "icloud")
                        }
                    }
                    Button("刷新账号信息", icon: "arrow.clockwise") {
                        run {
                            try await account.refresh()
                            return "已刷新"
                        }
                    }
                    Button("退出登录", role: .destructive) {
                        Haptics.tap()
                        account.logout()
                        message = "已退出登录"
                    }
                } header: {
                    Text("账号")
                }

                Section {
                    Button("云端收藏 → 本地收藏", icon: "icloud.and.arrow.down") {
                        run {
                            let result = try await account.pullFavorites()
                            return "云端共 \(result.total) 本，新加到本地收藏 \(result.added) 本"
                        }
                    }
                    Button("本地漫画收藏 → 云端", icon: "icloud.and.arrow.up") {
                        run {
                            let count = try await account.pushFavorites()
                            return count == 0 ? "本地的漫画收藏云端都有了" : "已上传 \(count) 本到云端收藏"
                        }
                    }
                    Toggle(isOn: $syncFavorites) {
                        Label("收藏时同步到账号", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .selectionFeedback(trigger: syncFavorites)
                } header: {
                    Text("收藏同步")
                } footer: {
                    Text("同步只会补上对方没有的本子，不会删除。打开「收藏时同步到账号」后，在详情页收藏或取消收藏，账号里也会跟着变。")
                }
            } else {
                Section {
                    TextField("用户名", text: $inputName)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $inputPassword)
                        .textContentType(.password)
                    Button("登录") {
                        let name = inputName.trimmingCharacters(in: .whitespaces), password = inputPassword
                        run {
                            try await account.login(username: name, password: password)
                            inputPassword = ""
                            return "登录成功"
                        }
                    }
                    .disabled(inputName.isEmpty || inputPassword.isEmpty || working)
                } header: {
                    Text("账号")
                } footer: {
                    Text("用禁漫天堂的账号登录。云端收藏可以在漫画模式的收藏页直接看，需要时再手动同步到本地。密码保存在系统钥匙串里，登录过期时自动重新登录。")
                }
            }

        }
        .toast($message, working: working)
        .navigationTitle("禁漫天堂")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 所有线路和分流一起测速（点「测速」时），结果显示在选项后面
    private func testLatency() async {
        guard !testing else { return }
        testing = true
        let list = domains
        for index in list.indices { domainLatency[index] = "测速中" }
        for stream in 1...4 { streamLatency[stream] = "测速中" }
        await withTaskGroup(of: (Bool, Int, Int?).self) { group in
            for (index, domain) in list.enumerated() {
                group.addTask { (true, index, await JMClient.latency(domain: domain)) }
            }
            for stream in 1...4 {
                group.addTask {
                    guard let host = await JMClient.imageHost(stream: stream) else { return (false, stream, nil) }
                    return (false, stream, await JMClient.latency(imageHost: host))
                }
            }
            for await (isDomain, key, ms) in group {
                let text = ms.map { "\($0)ms" } ?? "超时"
                if isDomain { domainLatency[key] = text } else { streamLatency[key] = text }
            }
        }
        testing = false
    }

    private func run(_ action: @escaping () async throws -> String) {
        Haptics.tap()
        working = true
        message = nil
        Task {
            do {
                message = try await action()
                Haptics.success()
            } catch {
                message = error.localizedDescription
                Haptics.failure()
            }
            working = false
        }
    }
}

/// 禁漫账号信息卡片：头像、用户名、等级、金币
struct JMUserCard: View {
    let user: JMUser

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let avatar = user.avatarURL {
                    PosterImage(url: avatar)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(user.username)
                    .font(.headline)
                HStack(spacing: 10) {
                    if !user.levelName.isEmpty || user.level > 0 {
                        Label(user.levelName.isEmpty ? "Lv.\(user.level)" : "Lv.\(user.level) \(user.levelName)", systemImage: "star.circle")
                    }
                    if !user.coin.isEmpty {
                        Label(user.coin, systemImage: "bitcoinsign.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 云端收藏夹：按收藏夹分组浏览
struct JMFavoritesView: View {
    @State private var folders: [JMFolder] = []
    @State private var folderID = "0"
    @State private var sort = "mr"
    @StateObject private var model = ComicListModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !folders.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            TagChip(title: "全部", selected: folderID == "0") { folderID = "0" }
                            ForEach(folders) { folder in
                                TagChip(title: folder.name, selected: folderID == folder.id) { folderID = folder.id }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .hideScrollIndicators()
                }
                if model.total > 0 {
                    Text("共 \(model.total) 本")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                ComicGrid(model: model)
            }
            .padding(.vertical)
        }
        .overlay {
            if model.items.isEmpty, !model.isLoading, model.error == nil {
                EmptyStateView("收藏夹是空的", systemImage: "heart")
            }
        }
        .navigationTitle("云端收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 不直接用 Picker：iOS 26 上它当工具栏按钮时会撑成一条长胶囊，文字还左右跳
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("排序", selection: $sort) {
                        Text("按收藏时间").tag("mr")
                        Text("按更新时间").tag("mp")
                    }
                } label: {
                    // 两个选项一样长，宽度不会变；fixedSize 防止被撑成一整条
                    Text(sort == "mr" ? "按收藏时间" : "按更新时间")
                        .fixedSize()
                }
            }
        }
        .task(id: folderID + sort) {
            let folder = folderID, order = sort
            model.loader = { page in
                let result = try await JMClient.favorites(page: page, folderID: folder, sort: order)
                if !result.folders.isEmpty {
                    await MainActor.run { folders = result.folders }
                }
                return JMPage(comics: result.comics, total: result.total, redirectID: nil)
            }
            await model.reload()
        }
    }
}

// MARK: - 规则管理

struct RulesView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @State private var showRepo = false
    @State private var showImport = false
    @State private var showAddCMS = false
    @State private var editMode: EditMode = .inactive

    private var hasCMS: Bool { ruleStore.entries.contains { $0.cms != nil } }

    var body: some View {
        List {
            if ruleStore.entries.isEmpty {
                EmptyStateView(
                    "还没有片源", systemImage: "puzzlepiece.extension",
                    description: Text("片源决定从哪些站点搜索和播放：Kazumi 规则用于番剧；采集站（苹果 CMS 接口）番剧、电影、剧集都能搜，可以单个添加，也可以导入订阅或 TVBox 配置")
                ) {
                    Button("打开规则仓库") { showRepo = true }
                        .glassProminentButtonStyle()
                    Button("添加采集站") { showAddCMS = true }
                        .glassButtonStyle()
                }
            }

            if !ruleStore.entries.isEmpty {
                Section {
                    ForEach(Array(ruleStore.entries.enumerated()), id: \.element.id) { index, entry in
                        RuleRow(entry: entry, rank: index + 1)
                            .swipeActions(edge: .leading) {
                                if index > 0 {
                                    Button("置顶", icon: "arrow.up.to.line") {
                                        withAnimation { ruleStore.moveToTop(entry.id) }
                                    }
                                    .tint(.orange)
                                }
                            }
                            .contextMenu {
                                Button("置顶", icon: "arrow.up.to.line") {
                                    withAnimation { ruleStore.moveToTop(entry.id) }
                                }
                                .disabled(index == 0)
                                Button("移到最后", icon: "arrow.down.to.line") {
                                    withAnimation { ruleStore.moveToBottom(entry.id) }
                                }
                                .disabled(index == ruleStore.entries.count - 1)
                            }
                    }
                    .onDelete { ruleStore.remove(at: $0) }
                    .onMove { ruleStore.move(from: $0, to: $1) }
                } header: {
                    Text("优先级")
                } footer: {
                    Text("排在前面的片源优先，选择片源时按这个顺序排列。点「排序」拖动调整，或右滑 / 长按置顶。影视模式只使用采集站。")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("规则管理")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !ruleStore.entries.isEmpty {
                    Button(editMode.isEditing ? "完成" : "排序") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .fontWeightCompat(editMode.isEditing ? .semibold : .regular)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Kazumi 规则") {
                        Button("从规则仓库添加", icon: "shippingbox") { showRepo = true }
                    }
                    Section("采集站") {
                        Button("添加采集站", icon: "server.rack") { showAddCMS = true }
                        if hasCMS {
                            Button("检测全部采集站", icon: "speedometer") {
                                Task { await ruleStore.testAllCMS() }
                            }
                        }
                    }
                    Button("粘贴 / 订阅导入", icon: "doc.on.clipboard") { showImport = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showRepo) {
            NavigationStackCompat { RuleRepoView() }
        }
        .sheet(isPresented: $showAddCMS) {
            NavigationStackCompat { AddCMSView() }
        }
        .sheet(isPresented: $showImport) {
            NavigationStackCompat { ImportRulesView() }
        }
    }
}

private struct RuleRow: View {
    let entry: RuleStore.Entry
    let rank: Int
    @EnvironmentObject private var ruleStore: RuleStore

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(rank == 1 ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 24, height: 24)
                .background(
                    rank == 1 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.14)),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    SourceKindBadge(isCMS: entry.cms != nil)
                }
                HStack(spacing: 6) {
                    if let rule = entry.rule {
                        Text("v\(rule.version)")
                        if rule.antiCrawlerConfig.enabled { Badge(text: "需验证", color: .orange) }
                        if rule.useLegacyParser { Badge(text: "旧版解析", color: .blue) }
                        if let reason = rule.unsupportedReason { Badge(text: reason, color: .red) }
                    } else if let source = entry.cms {
                        Text(URL(string: source.url)?.host ?? source.url)
                            .lineLimit(1)
                        if source.isAdult { Badge(text: "成人", color: .red) }
                        healthBadge
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("启用", isOn: Binding(
                get: { entry.enabled },
                set: { ruleStore.setEnabled(entry.id, $0) }
            ))
            .labelsHidden()
            .disabled(!entry.isSupported)
        }
    }

    @ViewBuilder
    private var healthBadge: some View {
        switch ruleStore.health[entry.id] {
        case .testing:
            ProgressView().controlSize(.mini)
        case .ok(let seconds):
            Badge(text: "\(Int(seconds * 1000)) ms", color: seconds < 1.5 ? .green : .orange)
        case .failed:
            Badge(text: "不可用", color: .red)
        case nil:
            EmptyView()
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - 规则仓库

struct RuleRepoView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [RepoEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var working: Set<String> = []
    @State private var failures: [String: String] = [:]

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                }
            }
            Section {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name).font(.body.weight(.medium))
                            HStack(spacing: 6) {
                                Text("v\(entry.version)")
                                if let date = entry.updatedDate {
                                    Text(date, format: .dateTime.year().month().day())
                                }
                                if entry.antiCrawlerEnabled { Badge(text: "需验证", color: .orange) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let failure = failures[entry.id] {
                                Text(failure).font(.caption2).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        actionButton(for: entry)
                    }
                }
            } footer: {
                if !entries.isEmpty {
                    Text("规则来自 Kazumi 社区规则仓库（GitHub，失败时自动切换 GitCode 镜像）。规则指向的站点与本应用无关。")
                }
            }
        }
        .overlay {
            if isLoading && entries.isEmpty { ProgressView() }
        }
        .navigationTitle("规则仓库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭", icon: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("全部安装") { Task { await installAll() } }
                    .disabled(entries.isEmpty || !working.isEmpty)
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func actionButton(for entry: RepoEntry) -> some View {
        let installed = ruleStore.installedVersion(of: entry.name)
        if working.contains(entry.id) {
            ProgressView()
        } else if let installed, installed == entry.version {
            Text("已安装")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button(installed == nil ? "安装" : "更新") {
                Task { await install(entry) }
            }
            .glassButtonStyle()
            .controlSize(.small)
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            entries = try await ruleStore.fetchIndex()
        } catch {
            self.error = "规则仓库连接失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func install(_ entry: RepoEntry) async {
        working.insert(entry.id)
        failures[entry.id] = nil
        do {
            let rule = try await ruleStore.fetchRule(named: entry.name)
            ruleStore.install(rule)
            if let reason = rule.unsupportedReason {
                failures[entry.id] = "已安装但暂不可用：\(reason)"
            }
        } catch {
            failures[entry.id] = "安装失败：\(error.localizedDescription)"
        }
        working.remove(entry.id)
    }

    private func installAll() async {
        let targets = entries.filter { ruleStore.installedVersion(of: $0.name) != $0.version }
        await withTaskGroup(of: Void.self) { group in
            for entry in targets {
                group.addTask { @MainActor in
                    await install(entry)
                }
            }
        }
    }
}

// MARK: - 粘贴导入

struct ImportRulesView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message: String?
    @State private var importing = false
    @State private var showFilePicker = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("从剪贴板粘贴", icon: "doc.on.clipboard") {
                    text = UIPasteboard.general.string ?? ""
                }
                Button("从文件读取", icon: "doc") { showFilePicker = true }
            } footer: {
                Text("""
                支持：
                · Kazumi 规则 JSON、kazumi:// 分享链接（可以一次粘贴多条）
                · 采集站订阅：地址或 JSON 内容（LibreTV-SourceList、MoonTV / LunaTV 配置，含 Base58 编码的订阅）
                · TVBox 配置地址（只导入其中的苹果 CMS 接口，爬虫和 XML 接口会跳过）
                · 单个采集站接口地址，如 https://example.com/api.php/provide/vod
                """)
            }
            if importing {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取…").foregroundStyle(.secondary)
                    }
                }
            } else if let message {
                Section { Text(message).font(.footnote) }
            }
        }
        .filePicker(isPresented: $showFilePicker) { data, _ in
            text = TextDecoding.string(from: data)
        }
        .navigationTitle("导入片源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", icon: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("导入") { importSources() }
                    .disabled(importing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func importSources() {
        importing = true
        message = nil
        let input = text
        Task {
            do {
                let result = try await SourceImport.parse(text: input)
                message = "已导入\n" + ruleStore.install(result)
                importing = false
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } catch {
                message = error.localizedDescription
                importing = false
            }
        }
    }
}

// MARK: - 添加采集站

struct AddCMSView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var testState: RuleStore.Health?

    private var isValid: Bool { CMSSource.isValidURL(url) }

    var body: some View {
        Form {
            Section {
                TextField("名称（可选）", text: $name)
                GrowingTextField("接口地址", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("苹果 CMS v10 接口，一般形如 https://example.com/api.php/provide/vod。应用不内置任何采集站，需要自行添加。")
            }

            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Label("检测接口", systemImage: "speedometer")
                        Spacer()
                        switch testState {
                        case .testing:
                            ProgressView()
                        case .ok(let seconds):
                            Text("可用 · \(Int(seconds * 1000)) ms").foregroundStyle(.green)
                        case .failed(let reason):
                            Text(reason).foregroundStyle(.red).lineLimit(1)
                        case nil:
                            EmptyView()
                        }
                    }
                }
                .disabled(!isValid || testState == .testing)
            }
        }
        .navigationTitle("添加采集站")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", icon: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("添加") {
                    ruleStore.install([CMSSource(name: name, url: url)])
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .onChangeCompat(of: url) { testState = nil }
    }

    private func test() {
        let source = CMSSource(name: name, url: url)
        testState = .testing
        Task {
            do {
                testState = .ok(try await CMSClient.probe(source))
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
