import SwiftUI
import WebKit

/// 我的 → 片源 → 网盘资源：uz 扩展订阅、网盘账号、资源站开关
struct UZSettingsView: View {
    @ObservedObject private var store = UZStore.shared
    @EnvironmentObject private var ruleStore: RuleStore
    @AppStorage(AppSettings.filterAdultKey) private var filterAdult = true
    @State private var input = ""
    @State private var message: String?
    @State private var working = false

    private var vods: [UZStore.Extension] {
        store.vodExtensions.filter { !(filterAdult && $0.isAV) }
    }

    var body: some View {
        List {
            Section {
                TextField("订阅地址（zip / json / 扩展脚本）", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { importInput(input) }
                Button("导入", icon: "square.and.arrow.down") { importInput(input) }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || working)
                if store.subscriptions.isEmpty {
                    Button("导入 uz 影视官方扩展仓库", icon: "sparkles") { importInput(UZStore.officialSubscription) }
                        .disabled(working)
                }
                ForEach(store.subscriptions) { subscription in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.url)
                            .font(.footnote.monospaced())
                            .lineLimit(2)
                        Text("更新于 \(subscription.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { store.removeSubscription(subscription.url) }
                    }
                }
                if !store.subscriptions.isEmpty {
                    Button("更新订阅", icon: "arrow.clockwise") {
                        run {
                            let result = try await store.updateSubscriptions()
                            return Self.summary(result)
                        }
                    }
                    .disabled(working)
                }
            } header: {
                Text("订阅")
            } footer: {
                Text("兼容 uz 影视的扩展订阅。资源站搜到的网盘分享会展开成剧集，在影视模式的片源列表里排在采集站后面。uz 影视私有加密的扩展只有它自己能运行，会标出来并跳过。")
            }

            Section {
                ForEach(UZStore.webLogins) { login in
                    NavigationLink {
                        UZCookieLoginView(login: login)
                    } label: {
                        LabeledRow {
                            Text(Self.status(login, store: store))
                        } label: {
                            Label(login.name, systemImage: "externaldrive")
                        }
                    }
                }
                NavigationLink {
                    UZEnvListView()
                } label: {
                    Label("其他网盘与设置", systemImage: "slider.horizontal.3")
                }
            } header: {
                Text("网盘账号")
            } footer: {
                Text("播放网盘资源要用你自己的账号。在网盘官网登录后自动保存 Cookie，只存在这台设备的钥匙串里。夸克直接取分享里的原文件，不用转存；MKV 等系统播放器放不了的格式用 mpv 播放原画。")
            }

            Section {
                if let pan = store.panTools {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pan.name)
                        Text("v\(pan.version)" + (pan.remark.isEmpty ? "" : " · " + pan.remark))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("还没有网盘工具，导入订阅时会自动下载")
                        .foregroundStyle(.secondary)
                }
                Button("更新网盘工具", icon: "arrow.down.circle") {
                    run {
                        try await store.updatePanTools()
                        return "网盘工具已更新"
                    }
                }
                .disabled(working)
                Button("重新下载基础库", icon: "shippingbox") {
                    run {
                        try await store.refreshCore()
                        return "基础库已更新"
                    }
                }
                .disabled(working)
                NavigationLink {
                    UZLogView()
                } label: {
                    Label("运行日志", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("网盘工具")
            } footer: {
                Text("网盘工具负责展开分享链接、取播放地址。订阅里的新版本是加密的，这里用 uz 扩展仓库历史里最后一个公开版本（v40，夸克不转存版）。")
            }

            if !vods.isEmpty {
                Section {
                    ForEach(vods) { ext in
                        UZExtensionRow(ext: ext)
                            .swipeActions {
                                Button("删除", role: .destructive) { store.remove(ext.id) }
                            }
                    }
                } header: {
                    Text("资源站 · \(vods.filter { $0.enabled && $0.usable }.count) 个启用")
                } footer: {
                    Text("名称带「盘」的是网盘资源站，其余是直接播放的视频站。")
                }
            }
        }
        .toast($message, working: working || store.working)
        .navigationTitle("网盘资源")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func importInput(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run {
            let result = try await store.importSubscription(text)
            if !result.cms.isEmpty { ruleStore.install(result.cms) }
            input = ""
            return Self.summary(result)
        }
    }

    private static func summary(_ result: UZStore.ImportResult) -> String {
        var parts = ["新增 \(result.added) 个", "更新 \(result.updated) 个"]
        if result.encrypted > 0 { parts.append("\(result.encrypted) 个加密的已跳过") }
        if !result.cms.isEmpty { parts.append("采集站 \(result.cms.count) 个已加到规则管理") }
        return parts.joined(separator: "，")
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

private struct UZExtensionRow: View {
    let ext: UZStore.Extension
    @ObservedObject private var store = UZStore.shared

    var body: some View {
        Toggle(isOn: Binding(get: { ext.enabled && ext.usable }, set: { store.setEnabled(ext.id, $0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ext.name)
                    .foregroundStyle(ext.usable ? Color.primary : Color.secondary)
                Group {
                    if ext.encrypted {
                        Text("uz 加密扩展，无法使用")
                    } else {
                        Text(["v\(ext.version)", ext.remark].filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .disabled(!ext.usable)
    }
}

// MARK: - 网盘登录

extension UZSettingsView {
    @MainActor
    static func status(_ login: UZStore.WebLogin, store: UZStore) -> String {
        switch store.loginState(login) {
        case .none: return "未登录"
        case .incomplete: return "需要重新登录"
        case .ok: return login.envKey == "UCCookie" && !(store.env["UC_Token"] ?? "").isEmpty ? "已登录 · 不限速" : "已登录"
        }
    }
}

/// 一个网盘的登录页：网页登录自动取 Cookie，或者手动粘贴
struct UZCookieLoginView: View {
    let login: UZStore.WebLogin
    @ObservedObject private var store = UZStore.shared
    @State private var showWeb = false
    @State private var manual = ""
    @State private var message: String?
    @State private var qrKind: NetdiskQRLogin.Kind?

    private var cookie: String? { store.env[login.envKey] }

    /// 夸克 / UC 支持扫码登录
    private var qrLogin: NetdiskQRLogin.Kind? {
        switch login.envKey {
        case "夸克Cookie": return .quark
        case "UCCookie": return .uc
        default: return nil
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledRow("状态", value: UZSettingsView.status(login, store: store))
                if let qrLogin {
                    Button("扫码登录（推荐）", icon: "qrcode.viewfinder") { qrKind = qrLogin }
                }
                Button("网页登录", icon: "globe") { showWeb = true }
            } footer: {
                if store.loginState(login) == .incomplete {
                    Text("保存的 Cookie 里没有登录信息（\(login.loginKeys.joined(separator: " / "))），像是打开登录页后没登录成功。请重新登录。")
                } else if qrLogin != nil {
                    Text("扫码登录：用\(qrLogin?.appName ?? "")扫码确认；只有这一台手机时，点「在本机打开」直接跳到 App 里确认。也可以在\(login.name)官网用手机号登录，看到文件列表后点「完成」。")
                } else {
                    Text("打开 \(login.name)官网，用手机号验证码或账号密码登录，看到自己的文件列表后点右上角「完成」，Cookie 会自动保存。")
                }
            }

            if login.envKey == "UCCookie" {
                Section {
                    LabeledRow("状态", value: (store.env["UC_Token"] ?? "").isEmpty ? "未开启" : "已开启")
                    Button("扫码开启", icon: "bolt.horizontal.circle") { qrKind = .ucTV }
                    if !(store.env["UC_Token"] ?? "").isEmpty {
                        Button("关闭", role: .destructive) {
                            store.setEnv("UC_Token", "")
                            store.setEnv(NetdiskQRLogin.ucRefreshTokenKey, "")
                            store.setEnv(NetdiskQRLogin.ucTokenExpiryKey, "")
                            message = "已关闭"
                        }
                    }
                } header: {
                    Text("不限速（电视版接口）")
                } footer: {
                    Text("用 UC 浏览器扫码授权电视版接口，之后 UC 网盘的原文件不限速。仍然需要上面的 Cookie 登录（转存文件用）。")
                }
            }

            Section {
                TextEditor(text: $manual)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 90)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("保存", icon: "checkmark") {
                    store.setEnv(login.envKey, manual)
                    let valid = login.hasLogin(manual)
                    manual = ""
                    if valid { Haptics.success() } else { Haptics.failure() }
                    message = valid ? "已保存" : "已保存，但里面没有 \(login.loginKeys.joined(separator: " / "))，可能不是登录后的 Cookie"
                }
                .disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("手动填写 Cookie")
            } footer: {
                Text("也可以在电脑浏览器登录后，从开发者工具复制整段 Cookie 粘贴到这里。")
            }

            if cookie != nil {
                Section {
                    Button("退出登录", role: .destructive) {
                        store.setEnv(login.envKey, "")
                        UZWebLoginSheet.clearCookies(domains: login.domains)
                        Haptics.tap()
                        message = "已清除"
                    }
                }
            }
        }
        .toast($message)
        .navigationTitle(login.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWeb) {
            UZWebLoginSheet(
                title: login.name, url: login.url, domains: login.domains,
                isLoggedIn: login.hasLogin, missingHint: "还没有登录成功（没读到 \(login.loginKeys.joined(separator: " / "))），登录后再点完成"
            ) { cookie in
                store.setEnv(login.envKey, cookie)
                message = "登录成功，Cookie 已保存"
            }
        }
        .sheet(item: $qrKind) { kind in
            NetdiskQRLoginSheet(kind: kind) { text in message = text }
        }
    }
}

/// 扫码登录：显示二维码，轮询直到在 App 里确认
struct NetdiskQRLoginSheet: View {
    let kind: NetdiskQRLogin.Kind
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var session: NetdiskQRLogin.Session?
    @State private var status = "正在获取二维码…"
    @State private var failed = false
    @State private var attempt = 0
    @State private var hint: String?

    private var image: UIImage? {
        guard let session else { return nil }
        return session.qrImage ?? NetdiskQRLogin.qrImage(session.qrContent)
    }

    var body: some View {
        NavigationStackCompat {
            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white)
                        if let image {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(14)
                                .opacity(failed ? 0.15 : 1)
                        } else if !failed {
                            ProgressView()
                        }
                    }
                    .frame(width: 240, height: 240)

                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if failed {
                        Button("重新获取二维码", icon: "arrow.clockwise") { attempt += 1 }
                            .buttonStyle(.borderedProminent)
                    } else if let link = session?.qrContent, let url = URL(string: link), !link.isEmpty {
                        Button("在本机打开\(kind.appName)确认", icon: "arrow.up.forward.app") {
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let image, !failed {
                        Button("保存二维码到相册", icon: "square.and.arrow.down") {
                            UIImageWriteToSavedPhotosAlbum(Self.printable(image), nil, nil, nil)
                            Haptics.success()
                            hint = "已保存到相册"
                        }
                    }

                    Text("用\(kind.appName)扫码后在 App 里点确认；确认后这里会自动完成。只有这一台手机时，点上面的按钮在本机打开确认，或者把二维码存到相册，再用\(kind.appName)的扫一扫从相册识别。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .toast($hint)
            .task(id: attempt) { await run() }
        }
    }

    private func run() async {
        failed = false
        session = nil
        status = "正在获取二维码…"
        do {
            let current = try await NetdiskQRLogin.start(kind)
            session = current
            status = "等待扫码确认"
            for _ in 0..<150 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    switch try await NetdiskQRLogin.poll(current) {
                    case .waiting(let text):
                        status = text
                    case .done(let text):
                        Haptics.success()
                        onDone(text)
                        dismiss()
                        return
                    }
                } catch {
                    status = error.localizedDescription
                }
            }
            status = "二维码过期了"
            failed = true
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription
            failed = true
        }
    }

    /// 存到相册的版本：白底加一圈留白，从相册识别更稳
    static func printable(_ image: UIImage) -> UIImage {
        let margin = image.size.width * 0.12
        let size = CGSize(width: image.size.width + margin * 2, height: image.size.height + margin * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.interpolationQuality = .none
            image.draw(in: CGRect(x: margin, y: margin, width: image.size.width, height: image.size.height))
        }
    }
}

/// 网页登录：登录后从 WebView 里读出指定域名的 Cookie
struct UZWebLoginSheet: View {
    let title: String
    let url: String
    let domains: [String]
    var userAgent: String = UZRuntime.defaultUA
    /// 读到的 Cookie 是不是登录后的（没登录时网站也会发 Cookie）
    var isLoggedIn: (String) -> Bool = { !$0.isEmpty }
    var missingHint = "还没有读到登录信息，登录成功后再点完成"
    let onCapture: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hint: String?
    @State private var desktop = true

    var body: some View {
        NavigationStackCompat {
            UZWebView(url: url, userAgent: desktop ? userAgent : UZWebView.mobileUA)
                .id(desktop)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) {
                        Menu {
                            Button("电脑版页面") { desktop = true }
                            Button("手机版页面") { desktop = false }
                        } label: {
                            HStack(spacing: 4) {
                                Text(desktop ? "电脑版页面" : "手机版页面")
                                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { capture() }
                    }
                }
                .toast($hint)
        }
    }

    private func capture() {
        Self.cookies(domains: domains) { cookie in
            if !isLoggedIn(cookie) {
                hint = missingHint
                Haptics.failure()
            } else {
                onCapture(cookie)
                Haptics.success()
                dismiss()
            }
        }
    }

    static func cookies(domains: [String], completion: @escaping (String) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let matched = cookies.filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
            }
            var seen = Set<String>()
            let text = matched
                .filter { seen.insert($0.name).inserted }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            DispatchQueue.main.async { completion(text) }
        }
    }

    static func clearCookies(domains: [String]) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            for cookie in cookies {
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                if domains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
                    store.delete(cookie)
                }
            }
        }
    }
}

struct UZWebView: UIViewRepresentable {
    let url: String
    let userAgent: String

    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = userAgent
        view.allowsBackForwardNavigationGestures = true
        if let target = URL(string: url) { view.load(URLRequest(url: target)) }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

// MARK: - 人机验证

struct UZVerifyRequest: Identifiable {
    let url: String
    var id: String { url }
}

/// 扩展请求验证（goToVerify）：打开网页让用户过验证，关掉时把这个站点的 Cookie 存下来给之后的请求用
struct UZVerifySheet: View {
    let url: String

    private var host: String { URL(string: url)?.host ?? "" }

    private var rootDomain: String {
        let parts = host.split(separator: ".")
        return parts.count > 2 ? parts.suffix(2).joined(separator: ".") : host
    }

    var body: some View {
        UZWebLoginSheet(title: "网页验证", url: url, domains: [rootDomain]) { cookie in
            UZStore.setVerifyCookie(host: host, cookie: cookie)
        }
    }
}

// MARK: - 其他环境变量

/// 天翼 / 123 账号密码、移动云盘 Token、转存文件夹名称等（来自扩展声明的环境变量）
struct UZEnvListView: View {
    @ObservedObject private var store = UZStore.shared

    private var items: [(key: String, desc: String)] {
        let webKeys = Set(UZStore.webLogins.map(\.envKey))
        return store.declaredEnv.filter { !webKeys.contains($0.key) }
    }

    var body: some View {
        List {
            if items.isEmpty {
                Text("导入订阅后，扩展需要的账号和设置会列在这里")
                    .foregroundStyle(.secondary)
            }
            ForEach(items, id: \.key) { item in
                NavigationLink {
                    UZEnvEditor(key: item.key, desc: item.desc)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.key)
                            Spacer()
                            if store.env[item.key] != nil {
                                Text(item.key.contains("密码") ? "已填写" : (store.env[item.key] ?? ""))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if !item.desc.isEmpty {
                            Text(item.desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("其他网盘与设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct UZEnvEditor: View {
    let key: String
    let desc: String
    @ObservedObject private var store = UZStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        Form {
            Section {
                if key.contains("密码") {
                    SecureField(key, text: $value)
                } else {
                    TextEditor(text: $value)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 90)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } footer: {
                Text(desc)
            }
            Section {
                Button("保存", icon: "checkmark") {
                    store.setEnv(key, value)
                    Haptics.success()
                    dismiss()
                }
                if store.env[key] != nil {
                    Button("清除", role: .destructive) {
                        store.setEnv(key, "")
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { value = store.env[key] ?? "" }
    }
}

// MARK: - 日志

struct UZLogView: View {
    @ObservedObject private var store = UZStore.shared
    @State private var logs: [String] = []

    var body: some View {
        List {
            if logs.isEmpty {
                Text("还没有日志。在影视详情页搜一部片子后再来看")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(logs.enumerated().reversed()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { logs = store.runtimeLogs }
        .refreshable { logs = store.runtimeLogs }
    }
}
