import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 备份与恢复：导出全部片源 / 书源 / 音源 / 书架 / 收藏 / 历史 / 设置，或从备份文件导入
struct BackupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RuleStore.self) private var ruleStore
    @State private var backups: [URL] = []
    @State private var working: String?
    @State private var pending: PendingRestore?
    @State private var showImporter = false
    @State private var message: String?

    struct PendingRestore: Identifiable {
        let id = UUID()
        let name: String
        let archive: AppBackup.Archive
        let summary: AppBackup.Summary
    }

    var body: some View {
        List {
            Section {
                Button {
                    export()
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up.on.square")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("从文件导入", systemImage: "square.and.arrow.down.on.square")
                }
            } footer: {
                Text("备份包含片源（Kazumi 规则和采集站）、书源、洛雪音源、书架、收藏、观看 / 阅读历史、音乐收藏与播放历史和各项设置；不含图片缓存、离线章节和禁漫密码。导出的文件在「文件 → 我的 iPhone → \(AppBackup.displayName) → 备份」里，也可以长按分享到别处。")
            }

            Section {
                ForEach(backups, id: \.self) { url in
                    HStack(spacing: 12) {
                        Button {
                            load(url)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.zipper")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .lineLimit(1)
                                    Text(detail(url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                    .contextMenu {
                        ShareLink(item: url)
                        Button("恢复这个备份", systemImage: "arrow.counterclockwise") { load(url) }
                        Button("删除", systemImage: "trash", role: .destructive) { delete(url) }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { delete(backups[index]) }
                }
                if backups.isEmpty {
                    Text("还没有备份")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("本机备份")
            } footer: {
                Text("点一下备份可以恢复。换包名或换设备时：在旧 App 导出，把文件存到「文件」或 iCloud，再在新 App 里「从文件导入」。")
            }
        }
        .navigationTitle("备份与恢复")
        .disabled(working != nil)
        .overlay {
            if let working {
                ProgressView(working)
                    .padding(24)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .data]) { result in
            if case .success(let url) = result { load(url) }
        }
        .alert("恢复备份", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { item in
            Button("取消", role: .cancel) {}
            Button("恢复") { restore(item) }
        } message: { item in
            Text("\(item.name)\n\n\(item.summary.text.isEmpty ? "备份是空的" : item.summary.text)\n\n片源、书源、音源、书架和设置会换成备份里的内容，收藏和历史会合并。恢复前会自动把当前数据另存一份备份。")
        }
        .alert("备份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task { refresh() }
    }

    private func refresh() {
        backups = AppBackup.localBackups()
    }

    private func detail(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? ""
        let date = AppBackup.modified(url).formatted(date: .abbreviated, time: .shortened)
        return [date, size].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func export() {
        working = "正在导出…"
        Task {
            do {
                let url = try await AppBackup.export(context: modelContext)
                refresh()
                let (_, summary) = try await AppBackup.read(url)
                message = "已导出「\(url.deletingPathExtension().lastPathComponent)」\n\n\(summary.text)"
            } catch {
                message = "导出失败：\(error.localizedDescription)"
            }
            working = nil
        }
    }

    private func load(_ url: URL) {
        working = "正在读取备份…"
        Task {
            do {
                let (archive, summary) = try await AppBackup.read(url)
                pending = PendingRestore(name: url.deletingPathExtension().lastPathComponent, archive: archive, summary: summary)
            } catch {
                message = "读取失败：\(error.localizedDescription)"
            }
            working = nil
        }
    }

    private func restore(_ item: PendingRestore) {
        working = "正在恢复…"
        Task {
            do {
                _ = try? await AppBackup.export(context: modelContext, prefix: "恢复前自动备份")
                try await AppBackup.restore(item.archive, context: modelContext, rules: ruleStore)
                refresh()
                message = "已恢复：\(item.summary.text)\n\n之前登录过禁漫的话需要重新登录一次。"
            } catch {
                message = "恢复失败：\(error.localizedDescription)"
            }
            working = nil
        }
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }
}
