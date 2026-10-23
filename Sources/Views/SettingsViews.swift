import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @AppStorage(AppSettings.hlsAdFilterKey) private var hlsAdFilter = true
    @AppStorage(AppSettings.filterAdultKey) private var filterAdult = true
    @State private var appIcon = AppIconOption.current

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
            } header: {
                Text("外观")
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
    @State private var username = JMClient.username
    @State private var inputName = ""
    @State private var inputPassword = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("API 线路", selection: Binding(get: { domainIndex }, set: { index in
                    domainIndex = index
                    JMClient.domainIndex = index
                })) {
                    ForEach(domains.indices, id: \.self) { index in
                        Text("线路 \(index + 1) · \(domains[index])").tag(index)
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
                        Text("分流 \(stream)").tag(stream)
                    }
                }
                LabeledRow("图片服务器", value: URL(string: imageHost)?.host ?? imageHost)
            } header: {
                Text("网络")
            } footer: {
                Text("连不上或加载慢时换条线路 / 分流。线路列表来自禁漫官方分发地址，每半天自动刷新。")
            }

            Section {
                if let username {
                    LabeledRow("已登录", value: username)
                    Button("退出登录", role: .destructive) {
                        JMClient.logout()
                        self.username = nil
                    }
                } else {
                    TextField("用户名", text: $inputName)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $inputPassword)
                        .textContentType(.password)
                    Button("登录") {
                        let name = inputName, password = inputPassword
                        run {
                            try await JMClient.login(username: name, password: password)
                            username = JMClient.username
                            inputPassword = ""
                            return "登录成功"
                        }
                    }
                    .disabled(inputName.isEmpty || inputPassword.isEmpty)
                }
            } header: {
                Text("账号")
            } footer: {
                Text("密码保存在系统钥匙串里，登录过期时会自动重新登录。")
            }

            if working || message != nil {
                Section {
                    if working {
                        ProgressView()
                    } else if let message {
                        Text(message).font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("禁漫天堂")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run(_ action: @escaping () async throws -> String) {
        working = true
        message = nil
        Task {
            do {
                message = try await action()
            } catch {
                message = error.localizedDescription
            }
            working = false
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
            if !ruleStore.entries.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
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
