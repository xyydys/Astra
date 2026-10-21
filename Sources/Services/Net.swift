import Foundation

enum UserAgents {
    /// 与 Kazumi 一致的桌面 UA 列表，很多站点只给桌面端完整播放器
    static let desktop = [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.1",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36 Edg/136.0.0.0",
    ]

    static let acceptLanguages = [
        "zh-CN,zh;q=0.9",
        "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6",
        "zh-CN,zh-TW;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6",
    ]

    static func random() -> String { desktop.randomElement() ?? desktop[0] }
    static func randomLanguage() -> String { acceptLanguages.randomElement() ?? acceptLanguages[0] }
}

enum NetError: LocalizedError {
    case badURL(String)
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "地址无效：\(s)"
        case .status(let code): return "服务器返回 \(code)"
        }
    }
}

enum Net {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config)
    }()

    struct TextResponse {
        let text: String
        let status: Int
        let headers: [AnyHashable: Any]

        func header(_ name: String) -> String? {
            for (key, value) in headers {
                if let k = key as? String, k.caseInsensitiveCompare(name) == .orderedSame {
                    return value as? String
                }
            }
            return nil
        }
    }

    static func text(_ request: URLRequest) async throws -> TextResponse {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return TextResponse(
            text: decodeText(data, response: response),
            status: http?.statusCode ?? 200,
            headers: http?.allHeaderFields ?? [:]
        )
    }

    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    /// 按 HTTP 头 / meta charset 解码，兜底 UTF-8 → GB18030
    static func decodeText(_ data: Data, response: URLResponse) -> String {
        if let name = response.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != CFStringEncoding(kCFStringEncodingInvalidId) {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: encoding) { return s }
            }
        }
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if head.contains("charset=gb") || head.contains("charset=\"gb") {
            if let s = String(data: data, encoding: gb18030) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: gb18030) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

extension URL {
    /// 宽松解析：补全协议相对地址、对非法字符做百分号编码
    static func lenient(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        if let u = URL(string: s), u.scheme != nil { return u }
        let allowed = CharacterSet.urlQueryAllowed
            .union(.urlPathAllowed)
            .union(CharacterSet(charactersIn: "#%"))
        if let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed),
           let u = URL(string: encoded), u.scheme != nil {
            return u
        }
        return nil
    }
}

extension String {
    /// 与 Dart 的 Uri.encodeQueryComponent 一致：空格编码为 +
    var queryComponentEncoded: String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = addingPercentEncoding(withAllowedCharacters: allowed) ?? self
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}
