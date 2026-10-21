import Foundation

/// 阅读（Legado 3.x）格式的书源。解码很宽松：字段类型不对、规则写成字符串都能读进来
struct BookSource: Codable, Hashable, Identifiable, @unchecked Sendable {
    var bookSourceUrl = ""
    var bookSourceName = ""
    var bookSourceGroup = ""
    var bookSourceType = 0
    var bookSourceComment = ""
    var bookUrlPattern = ""
    var header = ""
    var loginUrl = ""
    var loginUi = ""
    var loginCheckJs = ""
    var jsLib = ""
    var enabled = true
    var enabledExplore = true
    var enabledCookieJar = true
    var customOrder = 0
    var weight = 0
    var lastUpdateTime: Int64 = 0
    var respondTime: Int64 = 180_000
    var searchUrl = ""
    var exploreUrl = ""
    var concurrentRate = ""
    var variableComment = ""
    var coverDecodeJs = ""
    var ruleSearch = BookListRule()
    var ruleExplore = BookListRule()
    var ruleBookInfo = BookInfoRule()
    var ruleToc = TocRule()
    var ruleContent = ContentRule()

    var id: String { bookSourceUrl }
    var key: String { bookSourceUrl }

    init() {}

    struct BookListRule: Codable, Hashable {
        var bookList = ""
        var name = ""
        var author = ""
        var intro = ""
        var kind = ""
        var lastChapter = ""
        var updateTime = ""
        var bookUrl = ""
        var coverUrl = ""
        var wordCount = ""
        var checkKeyWord = ""

        init() {}

        init(from decoder: Decoder) throws {
            let c = try LenientContainer(decoder)
            bookList = c.string("bookList")
            name = c.string("name")
            author = c.string("author")
            intro = c.string("intro")
            kind = c.string("kind")
            lastChapter = c.string("lastChapter")
            updateTime = c.string("updateTime")
            bookUrl = c.string("bookUrl")
            coverUrl = c.string("coverUrl")
            wordCount = c.string("wordCount")
            checkKeyWord = c.string("checkKeyWord")
        }

        var isEmpty: Bool { bookList.isEmpty && name.isEmpty }
    }

    struct BookInfoRule: Codable, Hashable {
        var initRule = ""
        var name = ""
        var author = ""
        var intro = ""
        var kind = ""
        var lastChapter = ""
        var updateTime = ""
        var coverUrl = ""
        var tocUrl = ""
        var wordCount = ""
        var canReName = ""
        var downloadUrls = ""

        enum CodingKeys: String, CodingKey {
            case initRule = "init"
            case name, author, intro, kind, lastChapter, updateTime, coverUrl, tocUrl, wordCount, canReName, downloadUrls
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try LenientContainer(decoder)
            initRule = c.string("init")
            name = c.string("name")
            author = c.string("author")
            intro = c.string("intro")
            kind = c.string("kind")
            lastChapter = c.string("lastChapter")
            updateTime = c.string("updateTime")
            coverUrl = c.string("coverUrl")
            tocUrl = c.string("tocUrl")
            wordCount = c.string("wordCount")
            canReName = c.string("canReName")
            downloadUrls = c.string("downloadUrls")
        }
    }

    struct TocRule: Codable, Hashable {
        var preUpdateJs = ""
        var chapterList = ""
        var chapterName = ""
        var chapterUrl = ""
        var formatJs = ""
        var isVolume = ""
        var isVip = ""
        var isPay = ""
        var updateTime = ""
        var nextTocUrl = ""

        init() {}

        init(from decoder: Decoder) throws {
            let c = try LenientContainer(decoder)
            preUpdateJs = c.string("preUpdateJs")
            chapterList = c.string("chapterList")
            chapterName = c.string("chapterName")
            chapterUrl = c.string("chapterUrl")
            formatJs = c.string("formatJs")
            isVolume = c.string("isVolume")
            isVip = c.string("isVip")
            isPay = c.string("isPay")
            updateTime = c.string("updateTime")
            nextTocUrl = c.string("nextTocUrl")
        }
    }

    struct ContentRule: Codable, Hashable {
        var content = ""
        var title = ""
        var nextContentUrl = ""
        var webJs = ""
        var sourceRegex = ""
        var replaceRegex = ""
        var imageStyle = ""
        var imageDecode = ""
        var payAction = ""

        init() {}

        init(from decoder: Decoder) throws {
            let c = try LenientContainer(decoder)
            content = c.string("content")
            title = c.string("title")
            nextContentUrl = c.string("nextContentUrl")
            webJs = c.string("webJs")
            sourceRegex = c.string("sourceRegex")
            replaceRegex = c.string("replaceRegex")
            imageStyle = c.string("imageStyle")
            imageDecode = c.string("imageDecode")
            payAction = c.string("payAction")
        }
    }

    init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder)
        bookSourceUrl = c.string("bookSourceUrl").trimmingCharacters(in: .whitespacesAndNewlines)
        bookSourceName = c.string("bookSourceName")
        bookSourceGroup = c.string("bookSourceGroup")
        bookSourceType = c.int("bookSourceType") ?? 0
        bookSourceComment = c.string("bookSourceComment")
        bookUrlPattern = c.string("bookUrlPattern")
        header = c.string("header")
        loginUrl = c.string("loginUrl")
        loginUi = c.string("loginUi")
        loginCheckJs = c.string("loginCheckJs")
        jsLib = c.string("jsLib")
        enabled = c.bool("enabled") ?? true
        enabledExplore = c.bool("enabledExplore") ?? true
        enabledCookieJar = c.bool("enabledCookieJar") ?? true
        customOrder = c.int("customOrder") ?? 0
        weight = c.int("weight") ?? 0
        lastUpdateTime = Int64(c.int("lastUpdateTime") ?? 0)
        respondTime = Int64(c.int("respondTime") ?? 180_000)
        searchUrl = c.string("searchUrl")
        exploreUrl = c.string("exploreUrl")
        concurrentRate = c.string("concurrentRate")
        variableComment = c.string("variableComment")
        coverDecodeJs = c.string("coverDecodeJs")
        ruleSearch = c.rule("ruleSearch") ?? BookListRule()
        ruleExplore = c.rule("ruleExplore") ?? BookListRule()
        ruleBookInfo = c.rule("ruleBookInfo") ?? BookInfoRule()
        ruleToc = c.rule("ruleToc") ?? TocRule()
        ruleContent = c.rule("ruleContent") ?? ContentRule()
        if bookSourceName.isEmpty { bookSourceName = bookSourceUrl }
    }

    /// 只支持文字书源
    var isText: Bool { bookSourceType == 0 }
    var hasExplore: Bool { !exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var groups: [String] {
        bookSourceGroup.split(whereSeparator: { ",;，；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 发现页：没有单独的发现规则时用搜索规则
    var exploreListRule: BookListRule {
        ruleExplore.bookList.isEmpty ? ruleSearch : ruleExplore
    }

    /// 从 JSON 文本解析书源：数组、单个对象都可以
    static func decodeList(_ data: Data, allowJSON5: Bool = true) -> [BookSource] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([LenientItem<BookSource>].self, from: data) {
            return list.compactMap(\.value).filter { !$0.bookSourceUrl.isEmpty }
        }
        if let single = try? decoder.decode(BookSource.self, from: data), !single.bookSourceUrl.isEmpty {
            return [single]
        }
        // 有些书源文件是 JSON5（单引号、注释）
        if allowJSON5,
           let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed, .fragmentsAllowed]),
           let normalized = try? JSONSerialization.data(withJSONObject: json) {
            return decodeList(normalized, allowJSON5: false)
        }
        return []
    }
}

/// 数组里某一项解析失败时跳过，不影响其它项
struct LenientItem<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// 宽松的 JSON 字段读取
struct LenientContainer {
    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    let container: KeyedDecodingContainer<Key>

    init(_ decoder: Decoder) throws {
        container = try decoder.container(keyedBy: Key.self)
    }

    func string(_ name: String) -> String {
        let key = Key(stringValue: name)
        if let s = try? container.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? container.decodeIfPresent(Int64.self, forKey: key) { return String(i) }
        if let d = try? container.decodeIfPresent(Double.self, forKey: key) { return String(d) }
        if let b = try? container.decodeIfPresent(Bool.self, forKey: key) { return b ? "true" : "false" }
        return ""
    }

    func int(_ name: String) -> Int? {
        let key = Key(stringValue: name)
        if let i = try? container.decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? container.decodeIfPresent(String.self, forKey: key) { return Int(s.trimmingCharacters(in: .whitespaces)) }
        if let b = try? container.decodeIfPresent(Bool.self, forKey: key) { return b ? 1 : 0 }
        return nil
    }

    func bool(_ name: String) -> Bool? {
        let key = Key(stringValue: name)
        if let b = try? container.decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? container.decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? container.decodeIfPresent(String.self, forKey: key) {
            return ["true", "1", "yes"].contains(s.lowercased().trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// 规则既可能是对象，也可能是 JSON 字符串
    func rule<T: Decodable>(_ name: String) -> T? {
        let key = Key(stringValue: name)
        if let value = try? container.decodeIfPresent(T.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key), let data = text.data(using: .utf8) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return nil
    }
}

// MARK: - 书、章节

/// 书（搜索结果和书架共用）
struct NovelBook: Codable, Hashable, Identifiable, @unchecked Sendable {
    var name = ""
    var author = ""
    var kind = ""
    var wordCount = ""
    var latestChapterTitle = ""
    var intro = ""
    var coverUrl = ""
    var bookUrl = ""
    var tocUrl = ""
    /// 书源地址
    var origin = ""
    var originName = ""
    var originOrder = 0
    /// java.put 存的变量
    var variables: [String: String] = [:]

    var id: String { origin + "\n" + bookUrl }

    /// 同一本书（换源时按书名 + 作者匹配）
    var identity: String { NovelBook.identity(name: name, author: author) }

    static func identity(name: String, author: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var kinds: [String] {
        kind.split(whereSeparator: { ",，\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct NovelChapter: Codable, Hashable, Identifiable, @unchecked Sendable {
    var title = ""
    var url = ""
    /// 目录页地址，用来把相对地址补全
    var baseUrl = ""
    var isVolume = false
    var isVip = false
    var isPay = false
    /// 更新时间等附加信息
    var tag = ""
    var index = 0
    var variables: [String: String] = [:]

    var id: Int { index }

    /// 带选项的绝对地址（BookChapter.getAbsoluteURL）
    var absoluteURL: String {
        if isVolume, url.hasPrefix(title) { return baseUrl }
        return EngineURL.absolute(baseUrl, url)
    }
}

struct ExploreKind: Hashable, Identifiable {
    var title: String
    var url: String?

    var id: String { title + "|" + (url ?? "") }
}
