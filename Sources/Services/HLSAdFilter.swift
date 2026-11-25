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

/// 播放列表改写：相对地址补全；变体和字幕 / 音轨播放列表继续走本机代理，
/// 分片、密钥和初始化段仍由 mpv 直接向来源服务器请求。
enum HLSPlaylistRewriter {
    private static let uriAttribute = try? NSRegularExpression(pattern: #"URI="([^"]*)""#)

    static func rewrite(_ text: String, base: URL, playlistURL: (URL) -> URL) -> M3U8AdFilter.Outcome {
        let isMaster = text.contains("#EXT-X-STREAM-INF:") || text.contains("#EXT-X-I-FRAME-STREAM-INF:")
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                output.append(line)
            } else if t.hasPrefix("#") {
                output.append(rewriteAttributes(t, base: base, playlistURL: playlistURL))
            } else if let absolute = resolve(t, base: base) {
                output.append((isMaster ? playlistURL(absolute) : absolute).absoluteString)
            } else {
                output.append(t)
            }
        }
        let rewritten = output.joined(separator: "\n")
        guard !isMaster else { return M3U8AdFilter.Outcome(text: rewritten, removedSegments: 0) }
        return M3U8AdFilter.filter(rewritten)
    }

    private static func rewriteAttributes(_ tag: String, base: URL, playlistURL: (URL) -> URL) -> String {
        guard let regex = uriAttribute,
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag),
              let absolute = resolve(String(tag[range]), base: base) else { return tag }
        let isPlaylist = tag.hasPrefix("#EXT-X-MEDIA:") || tag.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
            || tag.hasPrefix("#EXT-X-RENDITION-REPORT:")
        let target = isPlaylist ? playlistURL(absolute) : absolute
        return tag.replacingCharacters(in: range, with: target.absoluteString)
    }

    private static func resolve(_ uri: String, base: URL) -> URL? {
        let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(.urlPathAllowed)) ?? uri
        guard let url = (URL(string: uri, relativeTo: base) ?? URL(string: encoded, relativeTo: base))?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// 只在当前播放期间提供 m3u8；地址映射不向客户端暴露可任意请求的上游 URL。
actor HLSAdBlockSession {
    private static let maxPlaylistBytes = 4 * 1024 * 1024
    private static let network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private let id: UUID
    private let port: UInt16
    private let headers: [String: String]
    private let onFiltered: @Sendable (UUID, Int) -> Void
    private var sources: [UUID: URL]
    private var registered: [URL: UUID]
    private var counted: Set<UUID> = []

    init(id: UUID, root: UUID, url: URL, port: UInt16, headers: [String: String],
         onFiltered: @escaping @Sendable (UUID, Int) -> Void) {
        self.id = id
        self.port = port
        self.headers = headers
        self.onFiltered = onFiltered
        sources = [root: url]
        registered = [url: root]
    }

    static func canHandle(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
            url.absoluteString.lowercased().contains(".m3u8")
    }

    static func localURL(port: UInt16, session: UUID, playlist: UUID) -> URL {
        URL(string: "http://127.0.0.1:\(port)/hls/\(session.uuidString)/\(playlist.uuidString).m3u8")!
    }

    func response(for playlist: UUID) async throws -> Data? {
        guard let source = sources[playlist] else { return nil }
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await Self.network.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard response.expectedContentLength <= Int64(Self.maxPlaylistBytes) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var body = Data()
        for try await byte in bytes {
            guard body.count < Self.maxPlaylistBytes else { throw URLError(.dataLengthExceedsMaximum) }
            body.append(byte)
            // 地址带 .m3u8 但返回文件、HTML 等时，及早交回给播放器直连尝试。
            if body.count == 1024, !Self.decode(body).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
                throw URLError(.cannotDecodeContentData)
            }
        }
        let text = Self.decode(body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("#EXTM3U") else { throw URLError(.cannotDecodeContentData) }
        let result = HLSPlaylistRewriter.rewrite(text, base: response.url ?? source) { register($0) }
        if result.removedSegments > 0, counted.insert(playlist).inserted {
            onFiltered(id, result.removedSegments)
        }
        return Data(result.text.utf8)
    }

    private static func decode(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private func register(_ url: URL) -> URL {
        let target = registered[url] ?? UUID()
        // 直播播放列表可能不断变化；只保留有限数量的变体映射。
        guard registered[url] != nil || sources.count < 256 else { return url }
        registered[url] = target
        sources[target] = url
        return Self.localURL(port: port, session: id, playlist: target)
    }
}
