import Foundation

// 书源引擎的命令行测试：novel-engine <书源.json> <关键词> [最多测试几个书源]
// 对每个书源跑一遍 搜索 → 详情 → 目录 → 第一章正文，输出每一步的结果

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("用法：novel-engine <书源.json> <关键词> [最多书源数]")
    exit(1)
}

let sourceFile = URL(fileURLWithPath: arguments[1])
let keyword = arguments[2]
let limit = arguments.count > 3 ? Int(arguments[3]) ?? 30 : 30
/// 第 4 个参数：只测书源名包含这些词的书源（逗号分隔），同时打印请求和 JS 日志
let filters = arguments.count > 4 ? arguments[4].split(separator: ",").map(String.init).filter { !$0.isEmpty } : []
let verbose = ProcessInfo.processInfo.environment["VERBOSE"] == "1" || !filters.isEmpty

guard let data = try? Data(contentsOf: sourceFile) else {
    print("读取书源失败")
    exit(1)
}
let all = BookSource.decodeList(data)
let sources = Array(all.filter { source in
    source.isText && !source.searchUrl.isEmpty
        && (filters.isEmpty ? source.enabled : filters.contains { source.bookSourceName.contains($0) })
}.prefix(limit))
print("书源 \(all.count) 个，测试 \(sources.count) 个，关键词「\(keyword)」\n")

let logLock = NSLock()
EngineHooks.log = { text in
    guard verbose else { return }
    logLock.withLock { print("    · " + text.prefix(300)) }
}

struct Report {
    var name: String
    var lines: [String] = []
    var search = false
    var info = false
    var toc = false
    var content = false
}

func runSource(_ source: BookSource) -> Report {
    var report = Report(name: source.bookSourceName)
    let env = EngineEnv()
    let started = Date()
    func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(started)) }
    do {
        let books = try WebBook.search(source, key: keyword, env: env)
        report.search = !books.isEmpty
        report.lines.append("搜索 \(books.count) 本 \(elapsed())")
        for book in books.prefix(3) {
            report.lines.append("  《\(book.name)》\(book.author) | \(book.kind.prefix(30)) | \(book.latestChapterTitle.prefix(30))")
            report.lines.append("    \(book.bookUrl.prefix(120))")
            if !book.coverUrl.isEmpty { report.lines.append("    封面 \(book.coverUrl.prefix(120))") }
        }
        guard var book = books.first(where: { $0.name.contains(keyword) }) ?? books.first else { return report }
        let ruleBook = RuleBook(book)
        let info = try WebBook.bookInfo(source, book: book, env: env, ruleBook: ruleBook)
        book = info.book
        report.info = true
        report.lines.append("详情 《\(book.name)》\(book.author) 目录 \(book.tocUrl.prefix(100)) \(elapsed())")
        if !book.intro.isEmpty { report.lines.append("  简介 \(book.intro.replacingOccurrences(of: "\n", with: " ").prefix(80))") }
        let chapters = try WebBook.chapters(source, book: book, tocHTML: info.tocHTML, env: env, ruleBook: ruleBook)
        report.toc = !chapters.isEmpty
        report.lines.append("目录 \(chapters.count) 章 \(elapsed())")
        if let first = chapters.first { report.lines.append("  第一章 \(first.title) \(first.absoluteURL.prefix(100))") }
        if let last = chapters.last { report.lines.append("  最后 \(last.title)") }
        guard let first = chapters.first(where: { !$0.isVolume }) else { return report }
        let next = chapters.first(where: { $0.index > first.index && !$0.isVolume })
        let text = try WebBook.content(source, book: book, chapter: first, nextChapterUrl: next?.absoluteURL, env: env, ruleBook: ruleBook)
        report.content = text.count > 50
        let preview = text.replacingOccurrences(of: "\n", with: "⏎").prefix(120)
        report.lines.append("正文 \(text.count) 字 \(elapsed())：\(preview)")
    } catch {
        report.lines.append("出错 \(elapsed())：\(error.localizedDescription)")
    }
    return report
}

var reports = [Report?](repeating: nil, count: sources.count)
let reportLock = NSLock()
let group = DispatchGroup()
let gate = DispatchSemaphore(value: 6)

for (index, source) in sources.enumerated() {
    gate.wait()
    group.enter()
    Thread.detachNewThread {
        let done = DispatchSemaphore(value: 0)
        let box = EngineBox<Report?>(nil)
        Thread.detachNewThread {
            box.value = runSource(source)
            done.signal()
        }
        let report: Report
        if done.wait(timeout: .now() + 60) == .timedOut {
            var timeout = box.value ?? Report(name: source.bookSourceName)
            timeout.lines.append("超时（60 秒）")
            report = timeout
        } else {
            report = box.value ?? Report(name: source.bookSourceName)
        }
        reportLock.withLock { reports[index] = report }
        gate.signal()
        group.leave()
    }
}
group.wait()

var counts = (search: 0, info: 0, toc: 0, content: 0)
for report in reports.compactMap({ $0 }) {
    let flags = [report.search ? "搜" : "✗", report.info ? "详" : "✗", report.toc ? "目" : "✗", report.content ? "文" : "✗"].joined()
    print("【\(flags)】\(report.name)")
    for line in report.lines { print("   " + line) }
    print("")
    if report.search { counts.search += 1 }
    if report.info { counts.info += 1 }
    if report.toc { counts.toc += 1 }
    if report.content { counts.content += 1 }
}
print("汇总：\(sources.count) 个书源，搜索成功 \(counts.search)，详情 \(counts.info)，目录 \(counts.toc)，正文 \(counts.content)")
