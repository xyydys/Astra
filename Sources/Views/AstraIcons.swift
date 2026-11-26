import SwiftUI
import UIKit

/// App-owned icons use bundled IconMCP vectors. Native controls retain their behaviors and
/// tint; a system symbol is a defensive fallback for a new or unavailable icon.
enum AstraGlyph {
    private static let resized = NSCache<NSString, UIImage>()

    static func assetName(_ key: String) -> String { "imcp-" + key.replacingOccurrences(of: ".", with: "-") }

    static func image(_ key: String, pointSize: CGFloat = 17,
                      withConfiguration configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        guard !key.isEmpty else { return nil }
        let asset = assetName(key)
        let side = max(1, pointSize)
        let cacheKey = "\(asset):\(side)" as NSString
        if let hit = resized.object(forKey: cacheKey) { return hit }
        guard let vector = UIImage(named: asset) else {
            if let configuration { return UIImage(systemName: key, withConfiguration: configuration) }
            return UIImage(systemName: key, withConfiguration: .init(pointSize: side))
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        // Use a stable scale for UIKit menu images, e.g. under multiple scene traits.
        format.scale = 3
        let size = CGSize(width: side, height: side)
        let result = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            vector.withRenderingMode(.alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysTemplate)
        resized.countLimit = 240
        resized.setObject(result, forKey: cacheKey)
        return result
    }
}

func AstraIcon(_ key: String, pointSize: CGFloat = 17) -> Image {
    if let image = AstraGlyph.image(key, pointSize: pointSize) {
        return Image(uiImage: image).renderingMode(.template)
    }
    return Image(systemName: key)
}

func AstraLabel(_ title: LocalizedStringKey, systemImage key: String) -> Label<Text, Image> {
    Label { Text(title) } icon: { AstraIcon(key) }
}

@_disfavoredOverload
func AstraLabel<S: StringProtocol>(_ title: S, systemImage key: String) -> Label<Text, Image> {
    Label { Text(title) } icon: { AstraIcon(key) }
}
