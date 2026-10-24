import SwiftUI
import UIKit

/// 可切换的应用图标：Resources/Assets.xcassets 里的 AppIcon（默认）和 AppIcon-*，
/// 设置页的预览图是 IconPreview-*（图标本身不能当普通图片读）
enum AppIconOption: String, CaseIterable, Identifiable {
    // 顺序就是设置页里的排列顺序；柔光是默认图标（AppIcon）
    case chroma, glow, sticker, blueprint, white, black, gold, klein, lemon, redyellow

    var id: String { rawValue }

    static let primary: AppIconOption = .glow

    /// 传给 setAlternateIconName 的名字，默认图标是 nil
    var iconName: String? { self == Self.primary ? nil : "AppIcon-" + rawValue }

    var previewName: String { "IconPreview-" + rawValue }

    var title: String {
        switch self {
        case .chroma: return "多彩"
        case .glow: return "柔光"
        case .sticker: return "糖纸"
        case .blueprint: return "蓝图"
        case .white: return "白"
        case .black: return "黑"
        case .gold: return "黑金"
        case .klein: return "克莱因橙"
        case .lemon: return "柠檬紫"
        case .redyellow: return "红黄"
        }
    }

    @MainActor
    static var current: AppIconOption {
        guard let name = UIApplication.shared.alternateIconName else { return primary }
        return allCases.first { $0.iconName == name } ?? primary
    }
}

/// 主屏同款圆角的图标缩略图
struct AppIconImage: View {
    let option: AppIconOption
    var size: CGFloat = 60

    var body: some View {
        Image(option.previewName)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

struct AppIconPicker: View {
    @State private var selected = AppIconOption.current
    @State private var error: String?
    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(AppIconOption.allCases) { option in
                    Button {
                        apply(option)
                    } label: {
                        VStack(spacing: 8) {
                            AppIconImage(option: option, size: 76)
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                                .overlay(alignment: .bottomTrailing) {
                                    if option == selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.accentColor)
                                            .offset(x: 6, y: 6)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                            Text(option.title)
                                .font(.footnote.weight(option == selected ? .semibold : .regular))
                                .foregroundStyle(option == selected ? .primary : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title + (option == selected ? "，当前图标" : ""))
                }
            }
            .padding(20)
        }
        .navigationTitle("应用图标")
        .navigationBarTitleDisplayMode(.inline)
        .selectionFeedback(trigger: selected)
        .alert("换图标失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func apply(_ option: AppIconOption) {
        guard option != selected else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            error = "当前系统不支持更换图标"
            return
        }
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(option.iconName)
                withAnimation(.snappyCompat) { selected = option }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
