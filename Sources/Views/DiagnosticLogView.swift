import SwiftUI

/// 运行日志：查看、复制、分享、清空
struct DiagnosticLogView: View {
    @AppStorage(DiagnosticLog.enabledKey) private var enabled = false
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? (enabled ? "还没有记录。去操作一下有问题的地方再回来看。" : "日志没有打开。") : text)
                .font(.caption2.monospaced())
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = DiagnosticLog.shared.text
                    copied = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel("复制")
                if let url = DiagnosticLog.shared.exportFile() {
                    ShareLinkCompat(url: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    DiagnosticLog.shared.clear()
                    reload()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("清空")
            }
        }
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() {
        text = DiagnosticLog.shared.text
        copied = false
    }
}

/// 设置页里的「运行日志」分区
struct DiagnosticSettingsSection: View {
    @AppStorage(DiagnosticLog.enabledKey) private var enabled = false

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("记录运行日志", systemImage: "waveform.path.ecg")
            }
            .selectionFeedback(trigger: enabled)
            .onChangeCompat(of: enabled) { _, on in
                if on {
                    Diag.log("日志", "开始记录")
                    DiagnosticLog.shared.startWatchdog()
                }
            }
            if enabled {
                NavigationLink {
                    DiagnosticLogView()
                } label: {
                    Label("查看运行日志", systemImage: "doc.text.magnifyingglass")
                }
            }
        } header: {
            Text("反馈")
        } footer: {
            Text("打开后记录页面切换、底栏颜色、音乐页加载用时和主线程卡顿。复现一次问题，再在这里复制或分享日志发给开发者。日志只在内存里，退出 App 就清空。")
        }
    }
}
