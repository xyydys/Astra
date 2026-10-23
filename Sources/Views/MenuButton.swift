import SwiftUI
import UIKit

/// 系统原生下拉菜单按钮（UIButton + UIMenu）。
///
/// SwiftUI 的 Menu 展开后，只要同一页面上别的地方在刷新（比如播放时的进度条、歌词动画），
/// 菜单就会被重建，点按和按住滑选都会失灵。UIKit 的菜单不受 SwiftUI 刷新影响：
/// 菜单只在 `menuKey` 变化（选中项变了）时才重新生成。
struct MenuButton: UIViewRepresentable {
    let title: String
    let systemImage: String
    /// 菜单内容的版本（选中项等），变了才重建菜单
    let menuKey: AnyHashable
    let menu: () -> UIMenu

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        apply(to: button)
        button.menu = menu()
        context.coordinator.menuKey = menuKey
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        apply(to: button)
        if context.coordinator.menuKey != menuKey {
            context.coordinator.menuKey = menuKey
            button.menu = menu()
        }
    }

    private func apply(to button: UIButton) {
        let font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
        config.baseForegroundColor = .label
        config.image = UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(font: font))
        config.imagePadding = 6

        let text = NSMutableAttributedString(string: title + " ", attributes: [.font: font])
        let chevronFont = UIFont.systemFont(ofSize: font.pointSize * 0.62, weight: .bold)
        if let chevron = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(font: chevronFont)) {
            let attachment = NSTextAttachment(image: chevron.withRenderingMode(.alwaysTemplate))
            text.append(NSAttributedString(attachment: attachment))
        }
        config.attributedTitle = AttributedString(text)
        button.configuration = config
        button.accessibilityLabel = title
    }

    final class Coordinator {
        var menuKey: AnyHashable?
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// 菜单里的一个选项
struct MenuOption<Value> {
    var value: Value
    var title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
}

extension UIMenu {
    /// 单选列表（相当于 Picker）：当前项打勾，选中时回调
    static func picker<Value: Equatable>(
        title: String = "",
        image: UIImage? = nil,
        inline: Bool = true,
        options: [MenuOption<Value>],
        selected: Value,
        onSelect: @escaping (Value) -> Void
    ) -> UIMenu {
        let actions = options.map { option in
            let action = UIAction(
                title: option.title,
                image: option.systemImage.flatMap { UIImage(systemName: $0) },
                state: option.value == selected ? .on : .off
            ) { _ in onSelect(option.value) }
            if let subtitle = option.subtitle { action.subtitle = subtitle }
            return action
        }
        return UIMenu(title: title, image: image, options: inline ? .displayInline : [], children: actions)
    }
}
