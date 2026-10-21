import UIKit

/// 已解码海报的内存缓存。NSCache 本身线程安全，可以在视图初始化时同步读取，
/// 已经加载过的海报第一帧就能显示，不会先闪一下占位图
final class ImageMemory: @unchecked Sendable {
    static let shared = ImageMemory()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 200 * 1024 * 1024
        return cache
    }()

    func image(_ urlString: String) -> UIImage? {
        urlString.isEmpty ? nil : cache.object(forKey: urlString as NSString)
    }

    func store(_ image: UIImage, for urlString: String) {
        let pixels = (image.cgImage?.width ?? 0) * (image.cgImage?.height ?? 0)
        cache.setObject(image, forKey: urlString as NSString, cost: max(pixels * 4, 1))
    }
}

/// 海报加载：内存缓存 + URLCache 磁盘缓存，同一地址并发请求只下载一次
actor ImageCache {
    static let shared = ImageCache()

    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var tints: [String: PosterTint] = [:]

    /// 海报底部主色（取色结果缓存，同一张海报只算一次）
    func tint(_ urlString: String) async -> PosterTint? {
        if let tint = tints[urlString] { return tint }
        guard let image = await load(urlString), let tint = PosterTint(bottomOf: image) else { return nil }
        tints[urlString] = tint
        return tint
    }

    func load(_ urlString: String) async -> UIImage? {
        guard !urlString.isEmpty else { return nil }
        if let image = ImageMemory.shared.image(urlString) { return image }
        if let task = inflight[urlString] { return await task.value }

        let task = Task<UIImage?, Never> {
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
            if JMClient.isJMImage(url) {
                for (key, value) in JMClient.imageHeaders { request.setValue(value, forHTTPHeaderField: key) }
            } else if url.host?.contains("doubanio.com") == true {
                // 豆瓣图片有防盗链，需要带上来源
                request.setValue(DoubanAPI.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
            } else {
                request.setValue(BangumiAPI.userAgent, forHTTPHeaderField: "User-Agent")
            }
            guard let result = try? await URLSession.shared.data(for: request),
                  let image = UIImage(data: result.0) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        inflight[urlString] = task
        let image = await task.value
        inflight[urlString] = nil
        if let image { ImageMemory.shared.store(image, for: urlString) }
        return image
    }
}
