import Foundation
import UIKit

/// 运行日志：在设置里打开后记录界面切换、底栏样式、主线程卡顿等，方便反馈问题时导出。
/// 只存在内存里（最多 2000 条），导出时写成文本文件。默认关闭，关闭时几乎没有开销。
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()
    static let enabledKey = "diagnosticLogEnabled"

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 2000
    private let start = Date()
    private var watchdog: Thread?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private init() {}

    /// 写一条日志：[相对启动的秒数] [分类] 内容
    func log(_ category: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let time = String(format: "%8.3f", Date().timeIntervalSince(start))
        let thread = Thread.isMainThread ? "main" : "bg"
        let line = "\(time) [\(category)] \(message()) (\(thread))"
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    /// 导出成文件（带设备和系统信息），给分享面板用
    @MainActor
    func exportFile() -> URL? {
        let device = UIDevice.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let header = """
        Astra \(version) · \(device.model) · \(device.systemName) \(device.systemVersion)
        导出时间 \(Date())
        ----
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Astra 运行日志.txt")
        do {
            try (header + "\n" + text).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: 卡顿检测

    /// 后台线程每 50ms 往主线程投一个任务，超过 250ms 没执行就记一次「主线程卡顿」
    func startWatchdog() {
        guard isEnabled, watchdog == nil else { return }
        let thread = Thread { [weak self] in
            while let self, self.isEnabled {
                let semaphore = DispatchSemaphore(value: 0)
                let sent = Date()
                DispatchQueue.main.async { semaphore.signal() }
                if semaphore.wait(timeout: .now() + 0.25) == .timedOut {
                    semaphore.wait()
                    let ms = Int(Date().timeIntervalSince(sent) * 1000)
                    self.log("卡顿", "主线程卡了 \(ms)ms · \(DiagnosticLog.context)")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            self?.watchdog = nil
        }
        thread.name = "Astra.Watchdog"
        thread.qualityOfService = .utility
        watchdog = thread
        thread.start()
    }

    /// 当前所在的页面（卡顿日志里一起记下来）
    nonisolated(unsafe) static var context = ""
}

/// 简写：Diag.log("底栏", "…")
enum Diag {
    static func log(_ category: String, _ message: @autoclosure () -> String) {
        DiagnosticLog.shared.log(category, message())
    }
}
