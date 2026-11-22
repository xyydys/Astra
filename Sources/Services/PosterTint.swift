import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// 海报底部的主色，用来把海报“延伸”成整页背景
struct PosterTint: Equatable, Codable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// 两张海报之间按滑动进度混色，背景跟手变化
    func mixed(with other: PosterTint, _ t: Double) -> PosterTint {
        let t = min(max(t, 0), 1)
        return PosterTint(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 背景偏亮时用浅色模式（深色文字），否则用深色模式（白色文字）
    var colorScheme: ColorScheme {
        0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.6 ? .light : .dark
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])

    /// 取海报最下面 10% 的平均色，再把亮度限制在适中范围，避免纯黑 / 纯白背景
    init?(bottomOf image: UIImage) {
        guard let input = image.cgImage.map({ CIImage(cgImage: $0) }) ?? CIImage(image: image) else { return nil }
        let extent = input.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }

        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = CGRect(
            x: extent.minX, y: extent.minY,
            width: extent.width, height: max(1, extent.height * 0.1)
        )
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        Self.context.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: output.extent.minX, y: output.extent.minY, width: 1, height: 1),
            format: .RGBA8, colorSpace: Self.sRGB
        )

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1
        ).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let adjusted = UIColor(
            hue: hue,
            saturation: min(saturation, 0.7),
            brightness: min(max(brightness, 0.16), 0.86),
            alpha: 1
        )
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        adjusted.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        red = Double(r)
        green = Double(g)
        blue = Double(b)
    }
}

/// 海报底部渐隐成透明，露出后面的整页背景色。
/// 背景只有一层，海报只是“溶”进去，所以任何时候都不会出现两种颜色的分界线
struct PosterFadeMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.42),
                .init(color: .black.opacity(0.55), location: 0.66),
                .init(color: .black.opacity(0.14), location: 0.86),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// 番剧 id → 海报主色。持久化到磁盘，冷启动第一帧就有颜色；视图可以同步读取
@MainActor
final class PosterTints: ObservableObject {
    static let shared = PosterTints()

    @Published private var values: [Int: PosterTint] = [:]
    private var tasks: [Int: Task<PosterTint?, Never>] = [:]
    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("poster-tints.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([Int: PosterTint].self, from: data) {
            values = saved
        }
    }

    func tint(for id: Int) -> PosterTint? {
        values[id]
    }

    /// 取色（用缩略图就够了，和大图底部颜色一致，加载更快）
    @discardableResult
    func ensure(_ subject: BangumiSubject) async -> PosterTint? {
        if let tint = values[subject.id] { return tint }
        if let task = tasks[subject.id] { return await task.value }
        let url = subject.thumb.isEmpty ? subject.image : subject.thumb
        guard !url.isEmpty else { return nil }
        let task = Task { await ImageCache.shared.tint(url) }
        tasks[subject.id] = task
        let tint = await task.value
        tasks[subject.id] = nil
        if let tint {
            withAnimation(.easeInOut(duration: 0.35)) { values[subject.id] = tint }
            scheduleSave()
        }
        return tint
    }

    /// 列表里的海报提前取色，点进详情页时背景直接就是对的
    func prefetch(_ subjects: [BangumiSubject]) {
        for subject in subjects where values[subject.id] == nil && tasks[subject.id] == nil {
            Task { await ensure(subject) }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            if values.count > 800 {
                values = Dictionary(uniqueKeysWithValues: values.shuffled().prefix(600).map { ($0.key, $0.value) })
            }
            guard let data = try? JSONEncoder().encode(values) else { return }
            let url = Self.fileURL
            Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
        }
    }
}
