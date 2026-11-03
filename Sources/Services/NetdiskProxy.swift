import Foundation
import Network

/// 网盘原文件的本地多线程代理。播放器请求 http://127.0.0.1:端口/v/<id>.<扩展名>，
/// 这里把请求的区间拆成小块，用多个连接并行从网盘下载，再按顺序交给播放器：
/// 网盘对普通账号按连接限速，并行下载能跑满带宽（猫影视源包用的也是这个办法）。
final class NetdiskProxy: @unchecked Sendable {
    static let shared = NetdiskProxy()

    private struct Source {
        let url: URL
        let headers: [String: String]
        let length: Int64
        let contentType: String
    }

    enum ProxyError: LocalizedError {
        case noRange
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .noRange: return "网盘地址不支持分段下载"
            case .unavailable(let text): return text
            }
        }
    }

    /// 每块 512KB，同时 6 个连接
    static let chunkSize: Int64 = 512 * 1024
    static let parallel = 6

    private let queue = DispatchQueue(label: "astra.netdisk-proxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private var sources: [String: Source] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: config)
    }()

    // MARK: 注册

    /// 登记一个网盘地址，返回给播放器用的本地地址。先试一下网盘支不支持分段下载，不支持就抛错（调用方直接播原地址）
    func register(url: String, headers: [String: String], fileName: String) async throws -> URL {
        guard let target = URL.lenient(url) else { throw ProxyError.unavailable("地址无效") }
        var probe = URLRequest(url: target, timeoutInterval: 15)
        for (key, value) in headers { probe.setValue(value, forHTTPHeaderField: key) }
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: probe)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 else {
            throw ProxyError.noRange
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "", "mp4": contentType = "video/mp4"
        case "mov": contentType = "video/quicktime"
        case "m4v": contentType = "video/x-m4v"
        case "mkv": contentType = "video/x-matroska"
        case "ts", "m2ts", "mts": contentType = "video/mp2t"
        case "webm": contentType = "video/webm"
        case "avi": contentType = "video/x-msvideo"
        case "flv": contentType = "video/x-flv"
        default: contentType = "application/octet-stream"
        }
        let id = UUID().uuidString
        lock.lock()
        sources[id] = Source(url: target, headers: headers, length: total, contentType: contentType)
        lock.unlock()
        let port = try await ensureStarted()
        Diag.log("网盘代理", "登记 \(target.host ?? "") \(total / 1_048_576)MB")
        return URL(string: "http://127.0.0.1:\(port)/v/\(id).\(ext.isEmpty ? "mp4" : ext)")!
    }

    // MARK: 监听

    private func ensureStarted() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                if port != 0, listener != nil {
                    continuation.resume(returning: port)
                    return
                }
                waiters.append(continuation)
                if listener == nil { startListener() }
            }
        }
    }

    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            failWaiters(error)
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? 0
                let waiting = self.waiters
                self.waiters = []
                for waiter in waiting { waiter.resume(returning: self.port) }
            case .failed(let error):
                // 退到后台后监听可能失效：丢掉，下次用到时重新开
                self.listener = nil
                self.port = 0
                self.failWaiters(error)
            case .cancelled:
                self.listener = nil
                self.port = 0
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func failWaiters(_ error: Error) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(throwing: error) }
    }

    // MARK: 请求

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                Task { await self.serve(connection, header: header) }
            } else if complete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receiveHeader(connection, buffer: buffer)
            }
        }
    }

    private func serve(_ connection: NWConnection, header: String) async {
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ")
        let method = requestLine.first.map(String.init) ?? "GET"
        let path = requestLine.count > 1 ? String(requestLine[1]) : ""
        let id = path.components(separatedBy: "/v/").last?.components(separatedBy: ".").first ?? ""
        lock.lock()
        let source = sources[id]
        lock.unlock()
        guard let source else {
            await reply(connection, status: "404 Not Found")
            return
        }
        let rangeValue = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }

        var start: Int64 = 0
        var end = source.length - 1
        var partial = false
        if let rangeValue, rangeValue.hasPrefix("bytes=") {
            let spec = rangeValue.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0) }
            if bounds.count == 2 {
                if bounds[0].isEmpty, let suffix = Int64(bounds[1]) {
                    start = max(0, source.length - suffix)
                } else {
                    start = Int64(bounds[0]) ?? 0
                    if let last = Int64(bounds[1]) { end = min(last, source.length - 1) }
                }
                partial = true
            }
        }
        guard start <= end, start < source.length else {
            await reply(connection, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(source.length)\r\n")
            return
        }

        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(source.contentType)\r\n"
        head += "Content-Length: \(end - start + 1)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Connection: close\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(source.length)\r\n" }
        head += "\r\n"
        do {
            try await send(connection, Data(head.utf8))
        } catch {
            connection.cancel()
            return
        }
        if method.uppercased() == "HEAD" {
            connection.cancel()
            return
        }

        // 并行下载：前面的块到了就按顺序发出去，同时补上后面的块
        let chunk = Self.chunkSize
        let count = Int((end - start) / chunk) + 1
        var tasks: [Task<Data, Error>] = []
        func launch(_ index: Int) -> Task<Data, Error> {
            let from = start + Int64(index) * chunk
            let to = min(from + chunk - 1, end)
            return Task { try await self.fetch(source, from, to) }
        }
        for index in 0..<min(Self.parallel, count) { tasks.append(launch(index)) }
        do {
            for index in 0..<count {
                let data = try await tasks[index].value
                if index + Self.parallel < count { tasks.append(launch(index + Self.parallel)) }
                try await send(connection, data)
            }
        } catch {
            // 播放器拖动进度或者退出时会断开连接，这里停下就行
        }
        for task in tasks { task.cancel() }
        connection.cancel()
    }

    private func fetch(_ source: Source, _ start: Int64, _ end: Int64) async throws -> Data {
        var lastError: Error = ProxyError.unavailable("下载失败")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var request = URLRequest(url: source.url, timeoutInterval: 20)
            for (key, value) in source.headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 206, Int64(data.count) == end - start + 1 { return data }
                lastError = ProxyError.unavailable("网盘返回 \(status)")
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
            try await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
        }
        Diag.log("网盘代理", "分块下载失败 \(start)-\(end)：\(lastError.localizedDescription)")
        throw lastError
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func reply(_ connection: NWConnection, status: String, extra: String = "") async {
        let text = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\n\(extra)Connection: close\r\n\r\n"
        try? await send(connection, Data(text.utf8))
        connection.cancel()
    }
}
