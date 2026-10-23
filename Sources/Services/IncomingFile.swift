import Foundation

/// 从其他 App「用 Astra 打开」/ 分享过来的文件：按内容判断是音源、书源、片源还是备份，直接导入
@MainActor
enum IncomingFile {
    enum Outcome {
        case message(String)
        /// 备份文件要用户确认后才恢复
        case backup(name: String, archive: AppBackup.Archive, summary: AppBackup.Summary)
    }

    static func handle(_ url: URL, rules: RuleStore) async -> Outcome? {
        guard url.isFileURL else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return .message("读取文件失败") }
        let name = url.lastPathComponent

        if let (archive, summary) = try? await AppBackup.read(url) {
            return .backup(name: name, archive: archive, summary: summary)
        }

        let text = TextDecoding.string(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .message("文件是空的") }
        do {
            if isBookSource(text) {
                await BookSourceStore.shared.load()
                return .message("书源：" + (try await BookSourceStore.shared.importText(text)))
            }
            if isMusicSource(text) {
                let entry = try await LXSourceStore.shared.importScript(text, origin: name)
                return .message("已导入音源「\(entry.info.name)」")
            }
            let result = try await SourceImport.parse(text: text)
            return .message("片源：\n" + rules.install(result))
        } catch {
            return .message("没能导入「\(name)」：\(error.localizedDescription)")
        }
    }

    private static func isBookSource(_ text: String) -> Bool {
        (text.hasPrefix("[") || text.hasPrefix("{")) && text.contains("bookSourceUrl")
    }

    /// 洛雪自定义音源：脚本开头的注释信息、或用到 lx 的接口
    private static func isMusicSource(_ text: String) -> Bool {
        guard !text.hasPrefix("[") && !text.hasPrefix("{") else { return false }
        return text.contains("@name") || text.contains("globalThis.lx") || text.contains("EVENT_NAMES") || text.contains("lx.on")
    }
}
