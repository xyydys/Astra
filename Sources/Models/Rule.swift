import Foundation

/// Kazumi 规则（与原版 JSON 格式兼容，字段名保持一致以便导入/导出）
struct Rule: Codable, Hashable, Identifiable {
    var api: String = "1"
    var type: String = "anime"
    var name: String = ""
    var version: String = ""
    var muliSources: Bool = true
    var useWebview: Bool = true
    var useNativePlayer: Bool = true
    var usePost: Bool = false
    var useLegacyParser: Bool = false
    var adBlocker: Bool = false
    var userAgent: String = ""
    var baseURL: String = ""
    var searchURL: String = ""
    var searchList: String = ""
    var searchName: String = ""
    var searchResult: String = ""
    var chapterRoads: String = ""
    var chapterResult: String = ""
    var referer: String = ""
    var searchMode: String = "xpath"
    var chapterMode: String = "xpath"
    var antiCrawlerConfig: AntiCrawlerConfig = AntiCrawlerConfig()

    var id: String { name.lowercased() }

    /// 目前只实现了 XPath 规则，API 模式规则暂不支持
    var isSupported: Bool {
        searchMode.lowercased() != "api"
            && chapterMode.lowercased() != "api"
            && !searchURL.isEmpty
            && !searchList.isEmpty
            && !chapterRoads.isEmpty
    }

    var unsupportedReason: String? {
        if searchMode.lowercased() == "api" || chapterMode.lowercased() == "api" {
            return "API 模式规则暂不支持"
        }
        if searchURL.isEmpty || searchList.isEmpty || chapterRoads.isEmpty {
            return "规则字段不完整"
        }
        return nil
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        api = c.lenientString("api", "1")
        type = c.lenientString("type", "anime")
        name = c.lenientString("name")
        version = c.lenientString("version")
        muliSources = c.lenientBool("muliSources", true)
        useWebview = c.lenientBool("useWebview", true)
        useNativePlayer = c.lenientBool("useNativePlayer", true)
        usePost = c.lenientBool("usePost", false)
        useLegacyParser = c.lenientBool("useLegacyParser", false)
        adBlocker = c.lenientBool("adBlocker", false)
        userAgent = c.lenientString("userAgent")
        baseURL = c.lenientString("baseURL")
        searchURL = c.lenientString("searchURL")
        searchList = c.lenientString("searchList")
        searchName = c.lenientString("searchName")
        searchResult = c.lenientString("searchResult")
        chapterRoads = c.lenientString("chapterRoads")
        chapterResult = c.lenientString("chapterResult")
        referer = c.lenientString("referer")
        let sm = c.lenientString("searchMode", "xpath")
        searchMode = sm.isEmpty ? "xpath" : sm
        let cm = c.lenientString("chapterMode", "xpath")
        chapterMode = cm.isEmpty ? "xpath" : cm
        antiCrawlerConfig = (try? c.decodeIfPresent(AntiCrawlerConfig.self, forKey: AnyKey("antiCrawlerConfig"))) ?? AntiCrawlerConfig()
    }
}

struct AntiCrawlerConfig: Codable, Hashable {
    var enabled: Bool = false
    /// 1 图片验证码, 2 自动点击按钮, 3 自定义脚本
    var captchaType: Int = 1
    var captchaImage: String = ""
    var captchaInput: String = ""
    var captchaButton: String = ""
    /// 1 xpath, 2 文本包含, 3 正则
    var captchaDetectType: Int = 1
    var captchaDetectValue: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        enabled = c.lenientBool("enabled", false)
        captchaType = c.lenientInt("captchaType", 1)
        captchaImage = c.lenientString("captchaImage")
        captchaInput = c.lenientString("captchaInput")
        captchaButton = c.lenientString("captchaButton")
        captchaDetectType = c.lenientInt("captchaDetectType", 1)
        captchaDetectValue = c.lenientString("captchaDetectValue")
    }
}

// MARK: - 宽松解码（规则仓库里的字段类型并不统一）

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where K == AnyKey {
    func lenientString(_ key: String, _ fallback: String = "") -> String {
        let k = AnyKey(key)
        if let v = try? decodeIfPresent(String.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return String(v) }
        if let v = try? decodeIfPresent(Bool.self, forKey: k) { return v ? "true" : "false" }
        return fallback
    }

    func lenientBool(_ key: String, _ fallback: Bool) -> Bool {
        let k = AnyKey(key)
        if let v = try? decodeIfPresent(Bool.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return v != 0 }
        if let v = try? decodeIfPresent(String.self, forKey: k) {
            switch v.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return fallback
            }
        }
        return fallback
    }

    func lenientInt(_ key: String, _ fallback: Int) -> Int {
        let k = AnyKey(key)
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return Int(v) }
        if let v = try? decodeIfPresent(String.self, forKey: k), let i = Int(v) { return i }
        return fallback
    }
}

// MARK: - 规则解析结果

struct SearchItem: Hashable, Identifiable {
    let name: String
    let url: String
    var id: String { url }
}

struct Episode: Hashable {
    let name: String
    let url: String
}

struct Road: Hashable {
    let name: String
    let episodes: [Episode]
}

/// 规则仓库 index.json 里的一项
struct RepoEntry: Decodable, Hashable, Identifiable {
    var name: String
    var version: String
    var antiCrawlerEnabled: Bool
    var lastUpdate: Double

    var id: String { name.lowercased() }

    var updatedDate: Date? {
        lastUpdate > 0 ? Date(timeIntervalSince1970: lastUpdate / 1000) : nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.lenientString("name")
        version = c.lenientString("version")
        antiCrawlerEnabled = c.lenientBool("antiCrawlerEnabled", false)
        lastUpdate = Double(c.lenientString("lastUpdate", "0")) ?? 0
    }
}
