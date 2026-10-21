import AVFoundation
import Foundation

/// m3u8 广告段过滤。采集站常把广告作为单独的 DISCONTINUITY 段插进正片，这里按段整体剔除
/// （不能只删 DISCONTINUITY 标记：广告段和正片的时间戳基准不同，删标记会音画错位）。
/// 判定都比较保守，宁可漏删也不误删正片：
/// 1. 段内所有分片地址都带明显的广告路径（adjump / advert / ad/）；
/// 2. 两段很长的正片之间夹着的超短段（≤30s，前后都 ≥120s）；
/// 3. 片头插入段：第一个分片前就有 DISCONTINUITY，第一段短小（≤90s、≤20 片）且后面还有正片。
///    如果整条流本来就是按固定小段切分的（各段大小相近），无法区分，跳过。
enum M3U8AdFilter {
    struct Outcome {
        let text: String
        let removedSegments: Int
    }

    private struct Group {
        /// 段前的 DISCONTINUITY 行（第一段没有）
        var disc: Int?
        var start: Int
        var end: Int
        var seconds: Double = 0
        var count = 0
        var allAd = true
    }

    private static let adURL = try? NSRegularExpression(pattern: "adjump|advert|/ads?/", options: [.caseInsensitive])

    static func filter(_ text: String) -> Outcome {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let groups = scan(lines)
        guard groups.count > 1 else { return Outcome(text: text, removedSegments: 0) }

        var dropGroup = Array(repeating: false, count: groups.count)

        // 1. 地址特征
        for (k, g) in groups.enumerated() where g.disc != nil && g.count > 0 && g.allAd {
            dropGroup[k] = true
        }

        // 2. 长正片之间的超短插入段
        for k in 1..<groups.count {
            let g = groups[k]
            guard g.disc != nil, g.count > 0, g.seconds > 0, g.seconds <= 30, k + 1 < groups.count else { continue }
            if groups[k - 1].seconds >= 120, groups[k + 1].seconds >= 120 { dropGroup[k] = true }
        }

        // 3. 片头插入段
        if groups[0].count == 0, groups.count > 2 {
            let lead = groups[1]
            let rest = groups[2...].map(\.count).filter { $0 > 0 }
            var looksInserted = lead.count > 0 && lead.count <= 20 && lead.seconds > 0 && lead.seconds <= 90 && !rest.isEmpty
            if looksInserted, groups.count - 1 >= 4 {
                let sorted = rest.sorted()
                let median = sorted[sorted.count / 2]
                let threshold = max(3, Double(median) * 0.5)
                if abs(Double(lead.count - median)) <= threshold { looksInserted = false }
            }
            if looksInserted { dropGroup[1] = true }
        }

        let removed = zip(groups, dropGroup).filter { $0.1 }.map { $0.0.count }.reduce(0, +)
        let total = groups.map(\.count).reduce(0, +)
        guard removed > 0, removed < total else { return Outcome(text: text, removedSegments: 0) }

        var drop = Array(repeating: false, count: lines.count)
        for (k, g) in groups.enumerated() where dropGroup[k] {
            if let disc = g.disc { drop[disc] = true }
            for i in g.start..<g.end {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                // 加密 / 初始化信息可能被后面的正片沿用，保留
                if t.hasPrefix("#EXT-X-KEY") || t.hasPrefix("#EXT-X-MAP") { continue }
                drop[i] = true
            }
        }

        // 第一个分片之前的 DISCONTINUITY 没有意义，一并去掉
        var output: [String] = []
        var seenSegment = false
        for (i, line) in lines.enumerated() where !drop[i] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !seenSegment, t == "#EXT-X-DISCONTINUITY" { continue }
            if isSegment(t) { seenSegment = true }
            output.append(line)
        }
        return Outcome(text: output.joined(separator: "\n"), removedSegments: removed)
    }

    private static func isSegment(_ trimmed: String) -> Bool {
        !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    private static func scan(_ lines: [String]) -> [Group] {
        var groups = [Group(disc: nil, start: 0, end: lines.count)]
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "#EXT-X-DISCONTINUITY" {
                groups[groups.count - 1].end = i
                groups.append(Group(disc: i, start: i + 1, end: lines.count))
            } else if t.hasPrefix("#EXTINF:") {
                let value = t.dropFirst("#EXTINF:".count).prefix { $0.isNumber || $0 == "." }
                groups[groups.count - 1].seconds += Double(value) ?? 0
            } else if isSegment(t) {
                groups[groups.count - 1].count += 1
                let range = NSRange(t.startIndex..., in: t)
                if adURL?.firstMatch(in: t, range: range) == nil { groups[groups.count - 1].allAd = false }
            }
        }
        return groups
    }
}

/// 播放列表改写：相对地址补全为绝对地址，子播放列表继续走自定义协议（这样也能被过滤），
/// 分片、密钥保持原始 http(s) 地址由 AVPlayer 直接请求
enum HLSPlaylistRewriter {
    static let schemePrefix = "kgad"

    static func wrap(_ url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = comps.scheme,
              ["http", "https"].contains(scheme.lowercased()) else { return nil }
        comps.scheme = schemePrefix + scheme.lowercased()
        return comps.url
    }

    static func unwrap(_ url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = comps.scheme,
              scheme.lowercased().hasPrefix(schemePrefix) else { return nil }
        comps.scheme = String(scheme.dropFirst(schemePrefix.count))
        return comps.url
    }

    private static let uriAttribute = try? NSRegularExpression(pattern: "URI=\"([^\"]*)\"")

    static func rewrite(_ text: String, base: URL, filterAds: Bool) -> M3U8AdFilter.Outcome {
        let isMaster = text.contains("#EXT-X-STREAM-INF")
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                output.append(line)
            } else if t.hasPrefix("#") {
                output.append(rewriteAttributes(t, base: base))
            } else if let absolute = resolve(t, base: base) {
                output.append((isMaster ? wrap(absolute) ?? absolute : absolute).absoluteString)
            } else {
                output.append(t)
            }
        }
        let rewritten = output.joined(separator: "\n")
        guard !isMaster, filterAds else { return M3U8AdFilter.Outcome(text: rewritten, removedSegments: 0) }
        return M3U8AdFilter.filter(rewritten)
    }

    private static func rewriteAttributes(_ tag: String, base: URL) -> String {
        guard let regex = uriAttribute,
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag),
              let absolute = resolve(String(tag[range]), base: base) else { return tag }
        // 音轨 / 字幕 / I 帧也是播放列表，继续走自定义协议；密钥和初始化分片直接请求
        let isPlaylist = tag.hasPrefix("#EXT-X-MEDIA") || tag.hasPrefix("#EXT-X-I-FRAME-STREAM-INF")
        let target = isPlaylist ? (wrap(absolute) ?? absolute) : absolute
        return tag.replacingCharacters(in: range, with: target.absoluteString)
    }

    private static func resolve(_ uri: String, base: URL) -> URL? {
        if uri.hasPrefix("data:") || uri.hasPrefix("skd:") { return nil }
        if let url = URL(string: uri, relativeTo: base)?.absoluteURL { return url }
        let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(.urlPathAllowed)) ?? uri
        return URL(string: encoded, relativeTo: base)?.absoluteURL
    }
}

/// 播放列表请求经过这里：改写地址、过滤广告段；分片仍由 AVPlayer 直接下载
final class HLSAdBlockLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "Astra.HLSAdBlock")
    /// 每次从播放列表里去掉广告分片时回调（在后台队列）
    var onFiltered: (@Sendable (Int) -> Void)?

    init(headers: [String: String]) {
        self.headers = headers
    }

    /// 只拦截 m3u8，直链视频交给 AVPlayer 自己处理
    static func canHandle(_ url: URL) -> Bool {
        url.absoluteString.lowercased().contains(".m3u8")
    }

    func makeAsset(url: URL) -> AVURLAsset {
        let wrapped = HLSPlaylistRewriter.wrap(url) ?? url
        let asset = AVURLAsset(url: wrapped, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, let real = HLSPlaylistRewriter.unwrap(url) else { return false }
        var request = URLRequest(url: real, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                loadingRequest.finishLoading(with: error ?? URLError(.cancelled))
                return
            }
            self.queue.async {
                self.respond(loadingRequest, real: real, data: data, response: response, error: error)
            }
        }
        task.resume()
        return true
    }

    private func respond(
        _ loadingRequest: AVAssetResourceLoadingRequest, real: URL,
        data: Data?, response: URLResponse?, error: Error?
    ) {
        guard !loadingRequest.isCancelled, !loadingRequest.isFinished else { return }
        if let error {
            loadingRequest.finishLoading(with: error)
            return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            loadingRequest.finishLoading(with: URLError(.badServerResponse))
            return
        }
        guard let data, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            // 不是播放列表（地址里带 m3u8 但其实是视频）：让播放器直接去请求原地址
            loadingRequest.redirect = URLRequest(url: real)
            loadingRequest.response = HTTPURLResponse(url: real, statusCode: 302, httpVersion: nil, headerFields: nil)
            loadingRequest.finishLoading()
            return
        }

        let result = HLSPlaylistRewriter.rewrite(text, base: response?.url ?? real, filterAds: true)
        if result.removedSegments > 0 { onFiltered?(result.removedSegments) }
        let body = Data(result.text.utf8)
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(body.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: body)
        loadingRequest.finishLoading()
    }
}
