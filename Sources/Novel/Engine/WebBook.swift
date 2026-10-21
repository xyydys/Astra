import Foundation

/// 书源的完整流程：搜索 / 发现 → 详情 → 目录 → 正文（BookList、BookInfo、BookChapterList、BookContent 的移植）。
/// 全部是同步函数，必须在 BookEngine 的后台队列里调用
enum WebBook {
    struct InfoResult {
        var book: NovelBook
        /// 目录就在详情页上时，直接用这一页解析目录
        var tocHTML: String?
    }

    // MARK: 搜索、发现

    static func search(_ source: BookSource, key: String, page: Int = 1, env: EngineEnv) throws -> [NovelBook] {
        let searchUrl = source.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchUrl.isEmpty else { throw BookEngineError.message("书源没有搜索地址") }
        let ruleData = RuleBook(NovelBook(origin: source.bookSourceUrl, originName: source.bookSourceName))
        let analyzeUrl = try AnalyzeUrl(
            searchUrl, key: key, page: page, baseUrl: source.bookSourceUrl,
            source: source, book: ruleData, env: env
        )
        let response = try analyzeUrl.strResponse()
        let books = try analyzeBookList(source, ruleData: ruleData, analyzeUrl: analyzeUrl, body: response.body,
                                        baseUrl: response.url, isSearch: true, env: env)
        if books.isEmpty, response.code >= 400 {
            throw BookEngineError.status(response.code, response.url)
        }
        return books
    }

    static func explore(_ source: BookSource, url: String, page: Int = 1, env: EngineEnv) throws -> [NovelBook] {
        let ruleData = RuleBook(NovelBook(origin: source.bookSourceUrl, originName: source.bookSourceName))
        let analyzeUrl = try AnalyzeUrl(url, page: page, baseUrl: source.bookSourceUrl, source: source, book: ruleData, env: env)
        let response = try analyzeUrl.strResponse()
        return try analyzeBookList(source, ruleData: ruleData, analyzeUrl: analyzeUrl, body: response.body,
                                   baseUrl: response.url, isSearch: false, env: env)
    }

    /// 发现页分类：`名称::地址` 按行或 && 分隔，或者 JSON 数组，也可以是返回这些内容的 JS
    static func exploreKinds(_ source: BookSource, env: EngineEnv) -> [ExploreKind] {
        var text = source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let lower = text.lowercased()
        if lower.hasPrefix("<js>") || lower.hasPrefix("@js:") {
            var code: String
            if lower.hasPrefix("@js:") {
                code = String(text.dropFirst(4))
            } else {
                code = String(text.dropFirst(4))
                if let end = code.range(of: "</js>", options: [.backwards, .caseInsensitive]) {
                    code = String(code[..<end.lowerBound])
                }
            }
            let rule = AnalyzeRule(source: source, env: env)
            rule.setBaseUrl(source.bookSourceUrl)
            let value = (try? rule.evalJS(code, result: nil)) ?? nil
            text = RuleValue.string(value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("["), let data = text.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [[String: Any]] {
            return array.compactMap { item in
                let title = RuleValue.string(item["title"])
                guard !title.isEmpty else { return nil }
                let url = RuleValue.string(item["url"])
                return ExploreKind(title: title, url: url.isEmpty ? nil : url)
            }
        }
        let separator = try! NSRegularExpression(pattern: "(&&|\\n)+")
        let ns = text as NSString
        var parts: [String] = []
        var last = 0
        for match in separator.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            last = match.range.location + match.range.length
        }
        parts.append(ns.substring(from: last))
        return parts.compactMap { part in
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return nil }
            let pieces = item.components(separatedBy: "::")
            let title = pieces[0].trimmingCharacters(in: .whitespaces)
            let url = pieces.count > 1 ? pieces[1...].joined(separator: "::").trimmingCharacters(in: .whitespaces) : nil
            return ExploreKind(title: title, url: url?.isEmpty == true ? nil : url)
        }
    }

    private static func analyzeBookList(
        _ source: BookSource, ruleData: RuleBook, analyzeUrl: AnalyzeUrl, body: String,
        baseUrl: String, isSearch: Bool, env: EngineEnv
    ) throws -> [NovelBook] {
        let rule = AnalyzeRule(source: source, book: ruleData, env: env)
        rule.setContent(body, baseUrl: baseUrl)
        rule.setRedirectUrl(baseUrl)

        let pattern = source.bookUrlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSearch, !pattern.isEmpty, fullMatch(baseUrl, pattern) {
            if let book = infoItem(source, ruleData: ruleData, rule: rule, body: body, baseUrl: baseUrl, env: env) {
                return [book]
            }
            return []
        }

        let listRule = isSearch ? source.ruleSearch : source.exploreListRule
        var listStr = listRule.bookList
        var reverse = false
        if listStr.hasPrefix("-") {
            reverse = true
            listStr.removeFirst()
        }
        if listStr.hasPrefix("+") { listStr.removeFirst() }
        let items = rule.getElements(listStr)
        if items.isEmpty, pattern.isEmpty {
            // 没有列表：可能搜索结果只有一本，直接跳到了详情页
            if let book = infoItem(source, ruleData: ruleData, rule: rule, body: body, baseUrl: baseUrl, env: env) {
                return [book]
            }
            return []
        }

        let nameRule = rule.splitSourceRule(listRule.name)
        let authorRule = rule.splitSourceRule(listRule.author)
        let kindRule = rule.splitSourceRule(listRule.kind)
        let wordCountRule = rule.splitSourceRule(listRule.wordCount)
        let lastChapterRule = rule.splitSourceRule(listRule.lastChapter)
        let introRule = rule.splitSourceRule(listRule.intro)
        let coverRule = rule.splitSourceRule(listRule.coverUrl)
        let bookUrlRule = rule.splitSourceRule(listRule.bookUrl)

        var books: [NovelBook] = []
        var seen = Set<String>()
        for item in items {
            try env.token.check()
            let data = RuleBook(NovelBook(
                origin: source.bookSourceUrl, originName: source.bookSourceName,
                originOrder: source.customOrder, variables: ruleData.book.variables
            ))
            rule.book = data
            rule.setContent(item)
            let name = formatName(rule.getString(nameRule))
            guard !name.isEmpty else { continue }
            data.book.name = name
            data.book.author = formatAuthor(rule.getString(authorRule))
            data.book.kind = (rule.getStringList(kindRule) ?? []).filter { !$0.isEmpty }.joined(separator: ",")
            data.book.wordCount = wordCountFormat(rule.getString(wordCountRule))
            data.book.latestChapterTitle = rule.getString(lastChapterRule)
            data.book.intro = HTMLFormatter.format(rule.getString(introRule))
            let cover = rule.getString(coverRule)
            if !cover.isEmpty { data.book.coverUrl = EngineURL.absolute(baseUrl, cover) }
            var bookUrl = rule.getString(bookUrlRule, isUrl: true)
            if bookUrl.isEmpty { bookUrl = baseUrl }
            data.book.bookUrl = bookUrl
            guard !seen.contains(bookUrl) else { continue }
            seen.insert(bookUrl)
            books.append(data.book)
        }
        rule.book = ruleData
        if reverse { books.reverse() }
        return books
    }

    private static func infoItem(
        _ source: BookSource, ruleData: RuleBook, rule: AnalyzeRule, body: String, baseUrl: String, env: EngineEnv
    ) -> NovelBook? {
        let data = RuleBook(NovelBook(
            bookUrl: baseUrl, origin: source.bookSourceUrl, originName: source.bookSourceName,
            originOrder: source.customOrder, variables: ruleData.book.variables
        ))
        rule.book = data
        analyzeBookInfo(source, book: data, rule: rule, body: body, baseUrl: baseUrl, redirectUrl: baseUrl, canRename: false)
        rule.book = ruleData
        return data.book.name.isEmpty ? nil : data.book
    }

    // MARK: 详情

    static func bookInfo(_ source: BookSource, book: NovelBook, env: EngineEnv, ruleBook: RuleBook? = nil) throws -> InfoResult {
        let data = ruleBook ?? RuleBook(book)
        let analyzeUrl = try AnalyzeUrl(book.bookUrl, baseUrl: source.bookSourceUrl, source: source, book: data, env: env)
        let response = try analyzeUrl.strResponse()
        let rule = AnalyzeRule(source: source, book: data, env: env)
        analyzeBookInfo(source, book: data, rule: rule, body: response.body, baseUrl: book.bookUrl,
                        redirectUrl: response.url, canRename: true)
        let tocHTML = data.book.tocUrl == book.bookUrl ? response.body : nil
        return InfoResult(book: data.book, tocHTML: tocHTML)
    }

    static func analyzeBookInfo(
        _ source: BookSource, book: RuleBook, rule: AnalyzeRule, body: String,
        baseUrl: String, redirectUrl: String, canRename: Bool
    ) {
        let info = source.ruleBookInfo
        rule.setContent(body, baseUrl: baseUrl)
        rule.setRedirectUrl(redirectUrl)
        if !info.initRule.isEmpty, let element = rule.getElement(info.initRule) {
            rule.setContent(element)
        }
        let rename = canRename && !info.canReName.isEmpty
        let name = formatName(rule.getString(info.name))
        if !name.isEmpty, rename || book.book.name.isEmpty { book.book.name = name }
        let author = formatAuthor(rule.getString(info.author))
        if !author.isEmpty, rename || book.book.author.isEmpty { book.book.author = author }
        let kind = (rule.getStringList(info.kind) ?? []).filter { !$0.isEmpty }.joined(separator: ",")
        if !kind.isEmpty { book.book.kind = kind }
        let wordCount = wordCountFormat(rule.getString(info.wordCount))
        if !wordCount.isEmpty { book.book.wordCount = wordCount }
        let last = rule.getString(info.lastChapter)
        if !last.isEmpty { book.book.latestChapterTitle = last }
        let intro = HTMLFormatter.format(rule.getString(info.intro))
        if !intro.isEmpty { book.book.intro = intro }
        let cover = rule.getString(info.coverUrl)
        if !cover.isEmpty { book.book.coverUrl = EngineURL.absolute(redirectUrl, cover) }
        var tocUrl = rule.getString(info.tocUrl, isUrl: true)
        if tocUrl.isEmpty { tocUrl = baseUrl }
        book.book.tocUrl = tocUrl
    }

    // MARK: 目录

    static func chapters(_ source: BookSource, book: NovelBook, tocHTML: String?, env: EngineEnv, ruleBook: RuleBook? = nil) throws -> [NovelChapter] {
        let data = ruleBook ?? RuleBook(book)
        let tocUrl = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl
        let body: String
        let redirect: String
        if let tocHTML, tocUrl == book.bookUrl {
            body = tocHTML
            redirect = tocUrl
        } else {
            let analyzeUrl = try AnalyzeUrl(tocUrl, baseUrl: book.bookUrl, source: source, book: data, env: env)
            let response = try analyzeUrl.strResponse()
            body = response.body
            redirect = response.url
        }

        let toc = source.ruleToc
        var listRule = toc.chapterList
        var reverse = false
        if listRule.hasPrefix("-") {
            reverse = true
            listRule.removeFirst()
        }
        if listRule.hasPrefix("+") { listRule.removeFirst() }

        var visited: [String] = [redirect]
        var (list, nextUrls) = analyzeChapterList(source, book: data, baseUrl: tocUrl, redirectUrl: redirect,
                                                  body: body, listRule: listRule, env: env)
        if nextUrls.count == 1 {
            // 只有一个「下一页」：一页页往后翻
            var next = nextUrls[0]
            while !next.isEmpty, !visited.contains(next), visited.count < 500 {
                try env.token.check()
                visited.append(next)
                let analyzeUrl = try AnalyzeUrl(next, baseUrl: book.bookUrl, source: source, book: data, env: env)
                guard let response = try? analyzeUrl.strResponse() else { break }
                let parsed = analyzeChapterList(source, book: data, baseUrl: next, redirectUrl: response.url,
                                                body: response.body, listRule: listRule, env: env)
                list += parsed.0
                next = parsed.1.first ?? ""
            }
        } else if nextUrls.count > 1 {
            // 第一页就列出了所有分页
            for next in nextUrls where !visited.contains(next) {
                try env.token.check()
                visited.append(next)
                let analyzeUrl = try AnalyzeUrl(next, baseUrl: book.bookUrl, source: source, book: data, env: env)
                guard let response = try? analyzeUrl.strResponse() else { continue }
                list += analyzeChapterList(source, book: data, baseUrl: next, redirectUrl: response.url,
                                           body: response.body, listRule: listRule, env: env).0
            }
        }
        nextUrls = []
        guard !list.isEmpty else { throw BookEngineError.message("目录为空") }

        // 去重：同一章（地址 + 标题）只保留最后一次出现的位置
        if !reverse { list.reverse() }
        var seen = Set<String>()
        var unique: [NovelChapter] = []
        for chapter in list {
            let key = chapter.url + "\n" + chapter.title
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(chapter)
        }
        unique.reverse()
        if reverse { unique.reverse() }

        for i in unique.indices { unique[i].index = i }
        if !toc.formatJs.isEmpty {
            let rule = AnalyzeRule(source: source, book: data, env: env)
            for i in unique.indices {
                rule.chapter = RuleChapter(unique[i])
                let code = "var index = \(i + 1); var gInt = 0; " + toc.formatJs
                if let value = try? rule.evalJS(code, result: nil), let title = value as? String, !title.isEmpty {
                    unique[i].title = title
                }
            }
        }
        return unique
    }

    private static func analyzeChapterList(
        _ source: BookSource, book: RuleBook, baseUrl: String, redirectUrl: String,
        body: String, listRule: String, env: EngineEnv
    ) -> ([NovelChapter], [String]) {
        let toc = source.ruleToc
        let rule = AnalyzeRule(source: source, book: book, env: env)
        rule.setContent(body, baseUrl: baseUrl)
        rule.setRedirectUrl(redirectUrl)
        let elements = rule.getElements(listRule)
        var nextUrls: [String] = []
        if !toc.nextTocUrl.isEmpty {
            for url in rule.getStringList(toc.nextTocUrl, isUrl: true) ?? [] where url != redirectUrl && !url.isEmpty {
                nextUrls.append(url)
            }
        }
        var chapters: [NovelChapter] = []
        guard !elements.isEmpty else { return (chapters, nextUrls) }
        let nameRule = rule.splitSourceRule(toc.chapterName)
        let urlRule = rule.splitSourceRule(toc.chapterUrl)
        let vipRule = rule.splitSourceRule(toc.isVip)
        let payRule = rule.splitSourceRule(toc.isPay)
        let timeRule = rule.splitSourceRule(toc.updateTime)
        let volumeRule = rule.splitSourceRule(toc.isVolume)
        for (index, item) in elements.enumerated() {
            rule.setContent(item)
            let chapter = RuleChapter(NovelChapter(baseUrl: redirectUrl))
            rule.chapter = chapter
            chapter.chapter.title = rule.getString(nameRule).trimmingCharacters(in: .whitespacesAndNewlines)
            chapter.chapter.url = rule.getString(urlRule)
            chapter.chapter.tag = rule.getString(timeRule)
            chapter.chapter.isVolume = rule.getString(volumeRule).isLegadoTrue
            if chapter.chapter.url.isEmpty {
                chapter.chapter.url = chapter.chapter.isVolume ? chapter.chapter.title + "\(index)" : baseUrl
            }
            guard !chapter.chapter.title.isEmpty else { continue }
            chapter.chapter.isVip = rule.getString(vipRule).isLegadoTrue
            chapter.chapter.isPay = rule.getString(payRule).isLegadoTrue
            chapters.append(chapter.chapter)
        }
        rule.chapter = nil
        return (chapters, nextUrls)
    }

    // MARK: 正文

    static func content(
        _ source: BookSource, book: NovelBook, chapter: NovelChapter, nextChapterUrl: String?,
        env: EngineEnv, ruleBook: RuleBook? = nil
    ) throws -> String {
        let contentRule = source.ruleContent
        if contentRule.content.isEmpty { return chapter.url }
        if chapter.isVolume, chapter.url.hasPrefix(chapter.title) { return "" }
        let data = ruleBook ?? RuleBook(book)
        data.durChapterTitle = chapter.title
        data.durChapterIndex = chapter.index
        let ruleChapter = RuleChapter(chapter)

        let chapterURL = chapter.absoluteURL
        let analyzeUrl = try AnalyzeUrl(chapterURL, baseUrl: book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl,
                                        source: source, book: data, chapter: ruleChapter, env: env)
        let response = try analyzeUrl.strResponse(jsStr: contentRule.webJs.isEmpty ? nil : contentRule.webJs)

        var parts: [String] = []
        var visited = [response.url]
        var (text, nextUrls) = analyzeContent(source, book: data, chapter: ruleChapter, baseUrl: chapterURL,
                                              redirectUrl: response.url, body: response.body, nextChapterUrl: nextChapterUrl, env: env)
        parts.append(text)
        let nextChapterAbsolute = nextChapterUrl.map { EngineURL.splitOption(EngineURL.absolute(response.url, $0)).url }
        if nextUrls.count == 1 {
            var next = nextUrls[0]
            while !next.isEmpty, !visited.contains(next), visited.count < 100 {
                try env.token.check()
                if let nextChapterAbsolute, EngineURL.splitOption(EngineURL.absolute(response.url, next)).url == nextChapterAbsolute { break }
                visited.append(next)
                let pageUrl = try AnalyzeUrl(next, baseUrl: chapterURL, source: source, book: data, chapter: ruleChapter, env: env)
                guard let pageResponse = try? pageUrl.strResponse() else { break }
                (text, nextUrls) = analyzeContent(source, book: data, chapter: ruleChapter, baseUrl: next,
                                                  redirectUrl: pageResponse.url, body: pageResponse.body,
                                                  nextChapterUrl: nextChapterUrl, env: env)
                parts.append(text)
                next = nextUrls.first ?? ""
            }
        } else if nextUrls.count > 1 {
            for next in nextUrls where !visited.contains(next) {
                try env.token.check()
                if let nextChapterAbsolute, EngineURL.splitOption(next).url == nextChapterAbsolute { continue }
                visited.append(next)
                let pageUrl = try AnalyzeUrl(next, baseUrl: chapterURL, source: source, book: data, chapter: ruleChapter, env: env)
                guard let pageResponse = try? pageUrl.strResponse() else { continue }
                let parsed = analyzeContent(source, book: data, chapter: ruleChapter, baseUrl: next,
                                            redirectUrl: pageResponse.url, body: pageResponse.body,
                                            nextChapterUrl: nextChapterUrl, env: env, getNext: false)
                parts.append(parsed.0)
            }
        }

        var content = parts.joined(separator: "\n")
        if !contentRule.replaceRegex.isEmpty {
            content = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            let rule = AnalyzeRule(source: source, book: data, env: env)
            rule.chapter = ruleChapter
            rule.setContent(content, baseUrl: chapterURL)
            content = rule.getString(contentRule.replaceRegex, content: content, unescape: false)
        }
        return content
    }

    private static func analyzeContent(
        _ source: BookSource, book: RuleBook, chapter: RuleChapter, baseUrl: String, redirectUrl: String,
        body: String, nextChapterUrl: String?, env: EngineEnv, getNext: Bool = true
    ) -> (String, [String]) {
        let rule = AnalyzeRule(source: source, book: book, env: env)
        rule.setContent(body, baseUrl: baseUrl)
        rule.setRedirectUrl(redirectUrl)
        rule.nextChapterUrl = nextChapterUrl
        rule.chapter = chapter
        var content = rule.getString(source.ruleContent.content, unescape: false)
        content = HTMLFormatter.formatKeepImage(content, baseURL: redirectUrl)
        if content.contains("&") { content = EngineText.unescapeHTML(content) }
        var nextUrls: [String] = []
        if getNext, !source.ruleContent.nextContentUrl.isEmpty {
            nextUrls = rule.getStringList(source.ruleContent.nextContentUrl, isUrl: true) ?? []
        }
        return (content, nextUrls)
    }

    // MARK: 格式化

    private static let nameRegex = try! NSRegularExpression(pattern: "\\s+作\\s*者.*|\\s+\\S+\\s+著")
    private static let authorRegex = try! NSRegularExpression(pattern: "^\\s*作\\s*者[:：\\s]+|\\s+著")

    static func formatName(_ name: String) -> String {
        let ns = name as NSString
        return nameRegex.stringByReplacingMatches(in: name, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .legadoTrimmed
    }

    static func formatAuthor(_ author: String) -> String {
        let ns = author as NSString
        return authorRegex.stringByReplacingMatches(in: author, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .legadoTrimmed
    }

    static func wordCountFormat(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(t) else { return t }
        if n >= 10000 { return String(format: "%.1f万字", Double(n) / 10000) }
        return "\(n)字"
    }

    private static func fullMatch(_ text: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return false }
        return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}

/// 在后台队列里执行同步的书源操作
enum BookEngine {
    static let queue = DispatchQueue(label: "kazumi.book-engine", qos: .userInitiated, attributes: .concurrent)

    static func run<T>(_ env: EngineEnv = EngineEnv(), _ work: @escaping (EngineEnv) throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async {
                    continuation.resume(with: Result { try work(env) })
                }
            }
        } onCancel: {
            env.token.cancel()
        }
    }
}
