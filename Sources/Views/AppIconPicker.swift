import SwiftUI
import UIKit

/// 可切换的应用图标：Resources/Assets.xcassets 里的 AppIcon（默认）和 AppIcon-*，
/// 设置页的预览图是 IconPreview-*（图标本身不能当普通图片读）
enum AppIconOption: String, CaseIterable, Identifiable {
    case astra, buddy, night, tray, mochi, sky, tv

    var id: String { rawValue }

    /// 传给 setAlternateIconName 的名字，默认图标是 nil
    var iconName: String? { self == .astra ? nil : "AppIcon-" + rawValue }

    var previewName: String { "IconPreview-" + rawValue }

    var title: String {
        switch self {
        case .astra: return "星芒"
        case .buddy: return "星仔"
        case .night: return "夜空"
        case .tray: return "百宝箱"
        case .mochi: return "团子"
        case .sky: return "晴空"
        case .tv: return "电视怪"
        }
    }

    @MainActor
    static var current: AppIconOption {
        guard let name = UIApplication.shared.alternateIconName else { return .astra }
        return allCases.first { $0.iconName == name } ?? .astra
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
        .sensoryFeedback(.selection, trigger: selected)
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
                withAnimation(.snappy) { selected = option }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
