import SwiftUI
import UIKit

/// 猫影视插件：添加 index.js.md5 订阅、看运行状态、打开插件自带的配置中心（网盘登录等）、站点开关
struct CatSettingsView: View {
    @ObservedObject private var store = CatStore.shared
    @State private var input = ""
    @State private var showWebsite = false
    @State private var confirmRemove = false

    private var statusText: String {
        switch store.status {
        case .idle: return store.hasPackage ? "未启动（用到时自动启动）" : "未添加"
        case .starting: return "启动中…"
        case .running: return "运行中 · \(store.vodSources.count) 个站点参与搜索"
        case .failed(let message): return message
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("http://… /index.js.md5", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button(store.working ? "下载中…" : (store.saved.url.isEmpty ? "添加" : "更换订阅"), icon: "arrow.down.circle") {
                    let text = input
                    Task {
                        await store.subscribe(text)
                        if store.hasPackage { input = "" }
                    }
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || store.working)
            } header: {
                Text("订阅")
            } footer: {
                Text("填猫影视插件包的地址（Miraplay、猫爪等用的 index.js.md5），地址里带账号密码的（http://用户:密码@域名/…）原样填。插件包在内置的 Node.js 里运行，里面的影视站点会出现在片源列表里。")
            }

            if store.hasPackage {
                Section {
                    LabeledRow("状态", value: statusText)
                    if !store.saved.url.isEmpty {
                        LabeledRow("地址", value: store.saved.url)
                    }
                    if let date = store.saved.updatedAt {
                        LabeledRow("更新时间", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("配置中心（网盘登录、站点设置）", icon: "gearshape.2") {
                        Task {
                            try? await store.ensureRunning()
                            if store.status == .running { showWebsite = true }
                        }
                    }
                    Button(store.working ? "检查中…" : "检查更新", icon: "arrow.triangle.2.circlepath") {
                        Task { await store.update() }
                    }
                    .disabled(store.working)
                    Button("重新载入", icon: "arrow.clockwise") {
                        Task {
                            do {
                                try await store.reload()
                                store.notice = "已重新载入"
                            } catch {
                                store.notice = error.localizedDescription
                            }
                        }
                    }
                    NavigationLink {
                        CatLogView()
                    } label: {
                        Label("运行日志", systemImage: "doc.text.magnifyingglass")
                    }
                    Button("删除插件包", role: .destructive) { confirmRemove = true }
                } header: {
                    Text("插件包")
                } footer: {
                    Text("网盘账号在配置中心里登录（插件包自己保存，和「网盘资源」里的账号分开）。配置中心是插件包自带的网页。")
                }

                if !store.videoSites.isEmpty {
                    Section {
                        ForEach(store.videoSites) { site in
                            Toggle(site.name, isOn: Binding(
                                get: { store.isEnabled(site) },
                                set: { store.setEnabled(site.key, $0) }
                            ))
                        }
                    } header: {
                        Text("影视站点")
                    } footer: {
                        Text("关掉的站点不参与详情页的自动找片源和搜索。音乐、课堂、直播、电台、听书这类站点搜不到影视，默认关着，需要的话可以打开。")
                    }
                }
            }
        }
        .navigationTitle("猫影视插件")
        .navigationBarTitleDisplayMode(.inline)
        .toast($store.notice, working: store.working)
        .sheet(isPresented: $showWebsite) {
            NavigationStackCompat {
                UZWebView(url: store.websiteURL, userAgent: UZWebView.mobileUA)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("配置中心")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showWebsite = false }
                        }
                    }
            }
        }
        .alert("删除猫影视插件包？", isPresented: $confirmRemove) {
            Button("删除", role: .destructive) { Task { await store.remove() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("片源列表里的插件站点会一起去掉。插件包里保存的网盘账号不会删除。")
        }
        .task {
            if input.isEmpty, !store.hasPackage, let moved = UZStore.shared.movedCatSubscription { input = moved }
            if store.hasPackage, store.status == .idle { try? await store.ensureRunning() }
        }
    }
}

/// 插件包的运行日志（Node 里的 console 输出）
struct CatLogView: View {
    @State private var lines: [String] = []
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "还没有日志" : lines.joined(separator: "\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    copied = true
                }
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        let store = CatStore.shared
        lines = store.diagnostics + ["—— 插件输出 ——"] + (await store.nodeLogs())
    }
}
