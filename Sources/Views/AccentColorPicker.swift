import SwiftUI
import UIKit

/// App 强调色（按钮、选中状态、进度条等），存成十六进制字符串，空字符串是默认的粉色
enum AppAccent {
    static let key = "appAccentColor"

    struct Preset: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let presets: [Preset] = [
        Preset(name: "樱粉", hex: "#FF2D55"),
        Preset(name: "朱红", hex: "#FF3B30"),
        Preset(name: "橙", hex: "#FF9500"),
        Preset(name: "琥珀", hex: "#E0A800"),
        Preset(name: "竹绿", hex: "#34C759"),
        Preset(name: "薄荷", hex: "#00C7BE"),
        Preset(name: "湖蓝", hex: "#30B0C7"),
        Preset(name: "天蓝", hex: "#007AFF"),
        Preset(name: "靛青", hex: "#5856D6"),
        Preset(name: "紫藤", hex: "#AF52DE"),
        Preset(name: "可可", hex: "#A2845E"),
        Preset(name: "石墨", hex: "#8E8E93"),
    ]

    static let defaultHex = presets[0].hex

    static func uiColor(_ hex: String) -> UIColor {
        UIColor(hex: hex.isEmpty ? defaultHex : hex) ?? UIColor(hex: defaultHex)!
    }

    static func color(_ hex: String) -> Color { Color(uiColor: uiColor(hex)) }

    /// UIKit 部分（提示框、系统菜单、分享面板）也跟着换色
    static func applyToWindows(_ hex: String) {
        let color = uiColor(hex)
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] { window.tintColor = color }
        }
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct AccentColorPicker: View {
    @AppStorage(AppAccent.key) private var hex = ""

    private let grid = [GridItem(.adaptive(minimum: 64), spacing: 14)]

    private var current: String { hex.isEmpty ? AppAccent.defaultHex : hex.uppercased() }

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: grid, spacing: 16) {
                    ForEach(AppAccent.presets) { preset in
                        Button {
                            withAnimation(.snappyCompat) { hex = preset.hex == AppAccent.defaultHex ? "" : preset.hex }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(AppAccent.color(preset.hex))
                                    .frame(width: 40, height: 40)
                                    .overlay {
                                        if current == preset.hex {
                                            Image(systemName: "checkmark")
                                                .font(.headline.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                Text(preset.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
                .selectionFeedback(trigger: hex)
            } header: {
                Text("预设")
            }

            Section {
                ColorPicker("自定义颜色", selection: Binding(
                    get: { AppAccent.color(hex) },
                    set: { hex = UIColor($0).hexString.uppercased() }
                ), supportsOpacity: false)
                if !hex.isEmpty {
                    Button("恢复默认") { hex = "" }
                }
            } footer: {
                Text("按钮、开关、选中状态和进度条都会用这个颜色。收藏的心形和各页面的海报取色不受影响。")
            }

            Section {
                HStack(spacing: 12) {
                    Button("按钮") {}
                        .glassProminentButtonStyle()
                    Toggle("开关", isOn: .constant(true))
                        .labelsHidden()
                    ProgressView(value: 0.6)
                }
            } header: {
                Text("预览")
            }
        }
        .navigationTitle("强调色")
        .navigationBarTitleDisplayMode(.inline)
    }
}
