import Foundation
import JavaScriptCore

/// uz 影视扩展（https://github.com/YYDS678/uzVideo-extensions）的运行环境。
/// 所有扩展共用一个 JSContext：先载入 uz 的基础库（cheerio、CryptoJS、JSEncrypt、JSONbig、Buffer、uzUtils、uzVideo），
/// 每个扩展脚本包在各自的函数作用域里执行（同名的 getVideoDetail 等函数互不冲突）。
/// 扩展通过 sendMessage 调用宿主（网络请求、存储、环境变量、toast），这里用 Swift 实现。
/// 所有 JS 调用都在同一个串行队列上执行。
final class UZRuntime: @unchecked Sendable {
    /// 宿主能力：存储、环境变量、提示等由 UZStore 提供
    struct Host: Sendable {
        var getEnv: @Sendable (String) -> String
        var setEnv: @Sendable (String, String) -> Void
        var getStorage: @Sendable (String) -> String
        var setStorage: @Sendable (String, String) -> Void
        var cookie: @Sendable (String) -> String?
        var toast: @Sendable (String) -> Void
        var verify: @Sendable (String, String) -> Void
    }

    private let core: String
    private let host: Host
    private let queue = DispatchQueue(label: "astra.uz", qos: .userInitiated)
    private var context: JSContext?
    private var installed = Set<String>()
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var nextID = 0
    private var logs: [String] = []
    private let logLock = NSLock()

    init(core: String, host: Host) {
        self.core = core
        self.host = host
    }

    var recentLogs: [String] {
        logLock.lock()
        defer { logLock.unlock() }
        return logs
    }

    /// 记一条日志（复制日志时一起带上，方便排查）
    func note(_ text: String) {
        log(text)
    }

    private func log(_ text: String) {
        logLock.lock()
        logs.append(text)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        logLock.unlock()
        Diag.log("网盘扩展", String(text.prefix(300)))
    }

    // MARK: 载入与调用

    /// 建立运行环境、载入基础库
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let context = makeContext() else {
                    continuation.resume(throwing: UZError.message("无法创建脚本环境"))
                    return
                }
                var failure: String?
                context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "未知错误" }
                context.evaluateScript(core, withSourceURL: URL(string: "uz://core.js"))
                context.exceptionHandler = { [weak self] _, exception in
                    self?.log("错误：" + (exception?.toString() ?? "未知错误"))
                }
                if let failure {
                    continuation.resume(throwing: UZError.message("基础库载入失败：\(failure)"))
                    return
                }
                self.context = context
                continuation.resume()
            }
        }
    }

    /// 载入一个扩展（已经载入过的跳过）。脚本出错时抛出
    func install(tag: String, name: String, script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let context else {
                    continuation.resume(throwing: UZError.message("脚本环境还没有建立"))
                    return
                }
                if installed.contains(tag) {
                    continuation.resume()
                    return
                }
                var failure: String?
                let handler = context.exceptionHandler
                context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "未知错误" }
                let wrapped = "__uzRegister(" + UZPrelude.jsString(tag) + ", function () {\n" + script + "\n;return __uzExports(" +
                    "typeof appConfig !== 'undefined' ? appConfig : null, " +
                    "typeof uzPanToolsInstance !== 'undefined' ? uzPanToolsInstance : null, " +
                    "{getClassList: typeof getClassList === 'function' ? getClassList : null, " +
                    "getSubclassList: typeof getSubclassList === 'function' ? getSubclassList : null, " +
                    "getVideoList: typeof getVideoList === 'function' ? getVideoList : null, " +
                    "getSubclassVideoList: typeof getSubclassVideoList === 'function' ? getSubclassVideoList : null, " +
                    "getVideoDetail: typeof getVideoDetail === 'function' ? getVideoDetail : null, " +
                    "getVideoPlayUrl: typeof getVideoPlayUrl === 'function' ? getVideoPlayUrl : null, " +
                    "searchVideo: typeof searchVideo === 'function' ? searchVideo : null});\n});"
                context.evaluateScript(wrapped, withSourceURL: URL(string: "uz://ext/\(tag).js"))
                context.exceptionHandler = handler
                if let failure {
                    log("\(name) 载入失败：\(failure)")
                    continuation.resume(throwing: UZError.message("「\(name)」脚本出错：\(failure)"))
                    return
                }
                installed.insert(tag)
                continuation.resume()
            }
        }
    }

    /// 调用视频源扩展的函数（getVideoDetail 等），返回扩展给的 JSON 字符串
    func call(tag: String, function: String, args: [String: Any], webSite: String = "", timeout: TimeInterval = 30) async throws -> String {
        try await invoke(tag: tag, target: "vod", function: function, args: args, webSite: webSite, timeout: timeout)
    }

    /// 调用网盘工具（uzPanToolsInstance）的方法
    func callPan(tag: String, method: String, args: Any, timeout: TimeInterval = 60) async throws -> String {
        try await invoke(tag: tag, target: "pan", function: method, args: args, webSite: "", timeout: timeout)
    }

    /// 夸克 / UC：转存到自己网盘后取转码清晰度（系统播放器放不了 mkv 原文件时用）
    func transcode(tag: String, item: Any, timeout: TimeInterval = 60) async throws -> String {
        try await invoke(tag: tag, target: "transcode", function: "transcode", args: item, webSite: "", timeout: timeout)
    }

    private func invoke(tag: String, target: String, function: String, args: Any, webSite: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                guard let context else {
                    continuation.resume(throwing: UZError.message("脚本环境还没有建立"))
                    return
                }
                nextID += 1
                let id = nextID
                pending[id] = continuation
                context.objectForKeyedSubscript("__uzCall").call(withArguments: [id, tag, target, function, args, webSite])
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.complete(id, .failure(UZError.message("扩展响应超时")))
                }
            }
        }
    }

    private func complete(_ id: Int, _ result: Result<String, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    // MARK: 环境

    private func makeContext() -> JSContext? {
        guard let context = JSContext() else { return nil }
        context.name = "uz 扩展"

        func define<Block>(_ name: String, _ block: Block) {
            context.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: name as NSString)
        }

        let log: @convention(block) (String) -> Void = { [weak self] text in
            self?.log(text)
        }
        define("__nativeLog", log)

        let schedule: @convention(block) (Int, Double) -> Void = { [weak self] id, ms in
            self?.queue.asyncAfter(deadline: .now() + max(ms, 0) / 1000) { [weak self] in
                self?.context?.objectForKeyedSubscript("__fireTimer").call(withArguments: [id])
            }
        }
        define("__nativeSchedule", schedule)

        let message: @convention(block) (Int, String, String) -> Void = { [weak self] id, name, payload in
            self?.handleMessage(id: id, name: name, payload: payload)
        }
        define("__nativeMessage", message)

        let finish: @convention(block) (Int, JSValue, JSValue) -> Void = { [weak self] id, error, result in
            guard let self else { return }
            if !error.isUndefined, !error.isNull {
                self.complete(id, .failure(UZError.message(error.toString())))
            } else {
                self.complete(id, .success(result.isString ? (result.toString() ?? "") : ""))
            }
        }
        define("__nativeFinish", finish)

        context.evaluateScript(UZPrelude.script)
        return context
    }

    private func resolve(_ id: Int, _ value: Any) {
        context?.objectForKeyedSubscript("__uzResolve").call(withArguments: [id, value])
    }

    /// sendMessage(name, payload)：uz 扩展访问宿主的唯一入口
    private func handleMessage(id: Int, name: String, payload: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
        func key() -> String {
            let raw = RuleValue.string(object["key"])
            let tag = RuleValue.string(object["uzTag"])
            return tag.isEmpty ? raw : tag + "|" + raw
        }
        switch name {
        case "req":
            performRequest(id: id, object: object)
        case "getEnv":
            resolve(id, host.getEnv(RuleValue.string(object["key"])))
        case "setEnv":
            host.setEnv(RuleValue.string(object["key"]), RuleValue.string(object["value"]))
            resolve(id, "")
        case "getStorage":
            resolve(id, host.getStorage(key()))
        case "setStorage":
            host.setStorage(key(), RuleValue.string(object["value"]))
            resolve(id, "")
        case "toast":
            host.toast(RuleValue.string(object["msg"]))
            resolve(id, "")
        case "goToVerify", "openWebToBindEnv":
            host.verify(RuleValue.string(object["url"]), RuleValue.string(object["ua"]))
            resolve(id, "")
        case "debugLog":
            log(payload)
            resolve(id, "")
        default:
            log("不支持的调用：\(name)")
            resolve(id, "")
        }
    }

    // MARK: 网络

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // 和 uz 影视（dio）一样不自动管理 Cookie：扩展自己在请求头里带
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: UZRedirectDelegate.shared, delegateQueue: nil)
    }()

    static let defaultUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0.1 Safari/605.1.15"

    private func performRequest(id: Int, object: [String: Any]) {
        var urlString = RuleValue.string(object["url"])
        let options = object["options"] as? [String: Any] ?? [:]
        let responseType = RuleValue.string(options["responseType"]).lowercased()

        if let query = options["queryParameters"] as? [String: Any], !query.isEmpty {
            let pairs = query.keys.sorted().map { key in
                key.queryComponentEncoded + "=" + RuleValue.string(query[key]).queryComponentEncoded
            }
            urlString += (urlString.contains("?") ? "&" : "?") + pairs.joined(separator: "&")
        }
        guard let url = URL.lenient(urlString) else {
            resolveResponse(id, code: 500, error: "地址无效：\(urlString)", responseType: responseType)
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = (RuleValue.string(options["method"]).isEmpty ? "GET" : RuleValue.string(options["method"])).uppercased()
        let send = (options["sendTimeout"] as? NSNumber)?.doubleValue ?? 0
        let receive = (options["receiveTimeout"] as? NSNumber)?.doubleValue ?? 0
        let timeout = max(send, receive)
        request.timeoutInterval = timeout > 0 ? min(max(timeout / 1000, 3), 120) : 30

        var headers: [String: String] = [:]
        for (key, value) in options["headers"] as? [String: Any] ?? [:] {
            guard !(value is NSNull) else { continue }
            headers[key] = RuleValue.string(value)
        }
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name }?.value
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if header("user-agent") == nil { request.setValue(Self.defaultUA, forHTTPHeaderField: "User-Agent") }
        // 过了人机验证的站点：自动带上验证时拿到的 Cookie
        if header("cookie") == nil, let host = url.host, let cookie = self.host.cookie(host) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        if let data = options["data"], !(data is NSNull), request.httpMethod != "GET" {
            let contentType = header("content-type")?.lowercased() ?? ""
            if (options["isBinary"] as? Bool) == true, let bytes = data as? [Any] {
                request.httpBody = Data(bytes.map { UInt8(truncatingIfNeeded: (($0 as? NSNumber)?.intValue ?? 0)) })
            } else if let text = data as? String {
                request.httpBody = Data(text.utf8)
                if contentType.isEmpty {
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    let json = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
                    request.setValue(json ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                }
            } else if contentType.contains("x-www-form-urlencoded"), let dict = data as? [String: Any] {
                request.httpBody = LXSourceRuntime.formEncode(dict)
            } else if JSONSerialization.isValidJSONObject(data) {
                request.httpBody = try? JSONSerialization.data(withJSONObject: data)
                if contentType.isEmpty { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            } else {
                request.httpBody = Data(RuleValue.string(data).utf8)
            }
        }

        let maxRedirects = (options["maxRedirects"] as? NSNumber)?.intValue
        // 日志只记域名和路径（不记查询参数和 Cookie）
        let brief = (url.host ?? "") + url.path
        log("→ \(request.httpMethod ?? "GET") \(brief)")
        var taskID = 0
        let task = Self.session.dataTask(with: request) { [weak self] data, response, error in
            let redirects = UZRedirectDelegate.shared.take(taskID)
            guard let self else { return }
            self.queue.async {
                if let error {
                    let code = (error as? URLError)?.code == .timedOut ? 408 : 500
                    self.log("← \(code) \(brief) \(error.localizedDescription)")
                    self.resolveResponse(id, code: code, error: error.localizedDescription, responseType: responseType)
                    return
                }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                var headerMap: [String: Any] = [:]
                for (key, value) in http?.allHeaderFields ?? [:] {
                    headerMap["\(key)".lowercased()] = "\(value)"
                }
                if let http, let responseURL = http.url ?? response?.url,
                   let fields = http.allHeaderFields as? [String: String] {
                    let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: responseURL)
                    if !cookies.isEmpty {
                        headerMap["set-cookie"] = cookies.map { cookie in
                            var text = "\(cookie.name)=\(cookie.value); Path=\(cookie.path)"
                            if !cookie.domain.isEmpty { text += "; Domain=\(cookie.domain)" }
                            return text
                        }
                    }
                }
                let body = data ?? Data()
                let text = String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
                let failed = status >= 400 || status == 0
                // 接口返回（JSON 的开头一段）一起记下，看得到网盘给的错误码
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = trimmed.hasPrefix("{") || failed ? " " + String(trimmed.prefix(180)) : ""
                self.log("← \(status) \(brief)\(snippet)")
                self.resolveResponse(
                    id, code: status, error: failed ? "HTTP \(status)" : "",
                    headers: headerMap, redirects: redirects.map { ["url": $0] },
                    contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "",
                    text: text, base64: ["arraybuffer", "bytes", "stream"].contains(responseType) ? body.base64EncodedString() : "",
                    responseType: responseType
                )
            }
        }
        taskID = task.taskIdentifier
        UZRedirectDelegate.shared.register(taskID, maxRedirects: maxRedirects)
        task.resume()
    }

    private func resolveResponse(
        _ id: Int, code: Int, error: String, headers: [String: Any] = [:], redirects: [[String: String]] = [],
        contentType: String = "", text: String = "", base64: String = "", responseType: String
    ) {
        context?.objectForKeyedSubscript("__uzResolveReq").call(withArguments: [id, [
            "code": code, "error": error, "headers": headers, "redirects": redirects,
            "contentType": contentType, "text": text, "b64": base64, "responseType": responseType,
        ]])
    }
}

enum UZError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 控制重定向次数（req 的 maxRedirects），并记下跳转过的地址（ProData.redirects）
final class UZRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = UZRedirectDelegate()

    private struct State {
        var limit: Int?
        var count = 0
        var urls: [String] = []
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]

    func register(_ taskID: Int, maxRedirects: Int?) {
        lock.lock()
        states[taskID] = State(limit: maxRedirects)
        lock.unlock()
    }

    /// 任务结束时取走跳转记录
    func take(_ taskID: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return states.removeValue(forKey: taskID)?.urls ?? []
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        var state = states[task.taskIdentifier] ?? State()
        let allowed = state.limit.map { state.count < $0 } ?? (state.count < 10)
        if allowed {
            state.count += 1
            if let url = request.url?.absoluteString { state.urls.append(url) }
        }
        states[task.taskIdentifier] = state
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }

}

// MARK: - 预置代码

enum UZPrelude {
    /// 定时器、console、TextEncoder / atob、sendMessage 桥，以及 uz 运行时注入的常量
    static let script = #"""
    (function () {
      var g = globalThis;
      g.window = g; g.self = g; g.global = g;

      var timers = {}, timerId = 0;
      g.setTimeout = function (fn, ms) {
        var id = ++timerId, args = Array.prototype.slice.call(arguments, 2);
        timers[id] = function () { delete timers[id]; if (typeof fn === 'function') fn.apply(null, args); };
        __nativeSchedule(id, Number(ms) || 0);
        return id;
      };
      g.setInterval = function (fn, ms) {
        var id = ++timerId;
        timers[id] = function () { if (typeof fn === 'function') fn(); if (timers[id]) __nativeSchedule(id, Number(ms) || 0); };
        __nativeSchedule(id, Number(ms) || 0);
        return id;
      };
      g.clearTimeout = g.clearInterval = function (id) { delete timers[id]; };
      g.setImmediate = function (fn) { return g.setTimeout(fn, 0); };
      g.__fireTimer = function (id) { var f = timers[id]; if (f) f(); };

      function text(args) {
        return Array.prototype.map.call(args, function (a) {
          if (typeof a === 'string') return a;
          if (a instanceof Error) return a.message;
          try { return JSON.stringify(a); } catch (e) { return String(a); }
        }).join(' ');
      }
      g.console = {
        log: function () { __nativeLog(text(arguments)); },
        info: function () { __nativeLog(text(arguments)); },
        warn: function () { __nativeLog(text(arguments)); },
        error: function () { __nativeLog('[error] ' + text(arguments)); },
        debug: function () {}, trace: function () {},
        group: function () {}, groupEnd: function () {}, groupCollapsed: function () {}
      };

      function utf8Encode(str) {
        var out = [];
        for (var i = 0; i < str.length; i++) {
          var c = str.charCodeAt(i);
          if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
            var d = str.charCodeAt(i + 1);
            if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
          }
          if (c < 0x80) out.push(c);
          else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
          else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
          else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
        return out;
      }
      function utf8Decode(bytes) {
        var out = '', i = 0;
        while (i < bytes.length) {
          var c = bytes[i++];
          if (c < 0x80) { out += String.fromCharCode(c); continue; }
          var n = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : c >= 0xc0 ? 1 : 0;
          var code = n === 3 ? c & 7 : n === 2 ? c & 15 : n === 1 ? c & 31 : 0xfffd;
          for (var k = 0; k < n && i < bytes.length; k++) code = (code << 6) | (bytes[i++] & 63);
          if (code > 0xffff) { code -= 0x10000; out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 1023)); }
          else out += String.fromCharCode(code);
        }
        return out;
      }
      var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      function b64Encode(bytes) {
        var out = '', i;
        for (i = 0; i + 2 < bytes.length; i += 3) {
          var n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
          out += B64[n >> 18] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
        }
        var rest = bytes.length - i;
        if (rest === 1) { var a = bytes[i] << 16; out += B64[a >> 18] + B64[(a >> 12) & 63] + '=='; }
        else if (rest === 2) { var b = (bytes[i] << 16) | (bytes[i + 1] << 8); out += B64[b >> 18] + B64[(b >> 12) & 63] + B64[(b >> 6) & 63] + '='; }
        return out;
      }
      function b64Decode(str) {
        str = String(str).replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/]/g, '');
        var out = new Uint8Array(Math.floor(str.length * 3 / 4)), len = 0, buffer = 0, bits = 0;
        for (var i = 0; i < str.length; i++) {
          buffer = ((buffer << 6) | B64.indexOf(str[i])) & 0xffffff; bits += 6;
          if (bits >= 8) { bits -= 8; out[len++] = (buffer >> bits) & 255; }
        }
        return out.subarray(0, len);
      }
      if (typeof g.TextEncoder === 'undefined') {
        g.TextEncoder = function () {};
        g.TextEncoder.prototype.encode = function (s) { return new Uint8Array(utf8Encode(String(s === undefined ? '' : s))); };
      }
      if (typeof g.TextDecoder === 'undefined') {
        g.TextDecoder = function () {};
        g.TextDecoder.prototype.decode = function (b) { return b ? utf8Decode(new Uint8Array(b.buffer || b)) : ''; };
      }
      if (typeof g.btoa === 'undefined') {
        g.btoa = function (s) { var bytes = []; for (var i = 0; i < s.length; i++) bytes.push(s.charCodeAt(i) & 255); return b64Encode(bytes); };
        g.atob = function (s) { var bytes = b64Decode(s), out = ''; for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]); return out; };
      }

      // sendMessage(name, json)：uz 扩展访问宿主的入口，返回 Promise
      var callbacks = {}, messageId = 0;
      g.sendMessage = function (name, payload) {
        return new Promise(function (resolve) {
          var id = ++messageId;
          callbacks[id] = resolve;
          __nativeMessage(id, String(name), payload === undefined || payload === null ? '' : String(payload));
        });
      };
      g.__uzResolve = function (id, value) {
        var cb = callbacks[id];
        delete callbacks[id];
        if (cb) cb(value);
      };
      g.__uzResolveReq = function (id, raw) {
        var cb = callbacks[id];
        delete callbacks[id];
        if (!cb) return;
        var pro = typeof ProData === 'function' ? new ProData() : {};
        pro.code = raw.code;
        pro.error = raw.error || '';
        pro.headers = raw.headers || {};
        pro.redirects = raw.redirects || [];
        pro.status = raw.code;
        var type = raw.responseType || '';
        var ct = String(raw.contentType || '').toLowerCase();
        if (!type) type = ct.indexOf('json') >= 0 ? 'json' : 'plain';
        if (type === 'arraybuffer' || type === 'bytes' || type === 'stream') {
          pro.data = b64Decode(raw.b64 || '').slice().buffer;
        } else if (type === 'json') {
          try { pro.data = JSON.parse(raw.text); } catch (e) { pro.data = raw.text; }
        } else {
          pro.data = raw.text;
        }
        cb(pro);
      };

      // uz 运行时注入的常量（uzUtils.js 里这部分是开发时的模拟值，运行时由 App 提供）
      g.kIsDesktop = false; g.kIsAndroid = false; g.kIsIOS = true; g.kIsWindows = false;
      g.kIsMacOS = false; g.kIsTV = false; g.kLocale = 'zh-CN'; g.kAppVersion = 1680; g.kIsDebug = false;

      // 夸克 / UC 转存后取网盘转码的清晰度（用网盘工具里 QuarkUC 的 save / getLiveTranscoding）
      var transcode = async function (item) {
        var pan = this;
        var handlers = (pan && pan.panToolsHandlers) || [];
        var handler = null;
        for (var i = 0; i < handlers.length; i++) {
          try { if (handlers[i].getPanType() === item.panType) { handler = handlers[i]; break; } } catch (e) {}
        }
        if (!handler || typeof handler.save !== 'function' || typeof handler.getLiveTranscoding !== 'function') {
          return { url: '', urls: [], error: '这个网盘不支持转码播放' };
        }
        if (typeof handler.initPan === 'function') await handler.initPan();
        var d = item.data || {};
        var saved = await handler.save({ shareId: d.shareId, stoken: d.shareToken, fileId: d.fileId, fileToken: d.shareFileToken, clean: true });
        if (!saved) return { url: '', urls: [], error: '转存失败，可能空间不足或登录失效' };
        handler.saveFileIdCaches = {};
        handler.saveFileIdCaches[d.fileId] = saved;
        var urls = await handler.getLiveTranscoding({ fileId: d.fileId });
        urls.sort(function (a, b) { return (b.priority || 0) - (a.priority || 0); });
        return { url: urls.length ? urls[0].url : '', urls: urls, playHeaders: handler.playHeaders, error: urls.length ? '' : '没有取到转码地址' };
      };

      // 每个扩展包在自己的函数作用域里执行，导出的东西按 uzTag 存在这里
      var registry = {};
      g.__uzExports = function (appConfig, pan, fns) { return { appConfig: appConfig, pan: pan, fns: fns }; };
      g.__uzRegister = function (tag, factory) {
        var ext = factory();
        registry[tag] = ext;
        if (ext.appConfig) ext.appConfig.uzTag = tag;
        if (ext.pan) ext.pan.uzTag = tag;
      };
      g.__uzCall = function (id, tag, target, name, args, webSite) {
        try {
          var ext = registry[tag];
          if (!ext) { __nativeFinish(id, '扩展没有载入', null); return; }
          var self = null, fn = null;
          if (target === 'transcode') {
            self = ext.pan;
            fn = transcode;
          } else if (target === 'pan') {
            self = ext.pan;
            fn = self ? self[name] : null;
          } else {
            if (webSite && ext.appConfig) ext.appConfig.webSite = webSite;
            fn = ext.fns[name];
          }
          if (typeof fn !== 'function') { __nativeFinish(id, '扩展没有实现 ' + name, null); return; }
          Promise.resolve(fn.call(self, args)).then(function (result) {
            if (typeof result !== 'string') result = JSON.stringify(result === undefined ? null : result);
            __nativeFinish(id, null, result);
          }, function (err) {
            __nativeFinish(id, err && err.message ? err.message : String(err), null);
          });
        } catch (err) {
          __nativeFinish(id, err && err.message ? err.message : String(err), null);
        }
      };
    })();
    """#

    /// Swift 字符串 → JS 字符串字面量
    static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// uz 的扩展和基础库里成对的「// ignore」之间是开发时用的代码（import、模拟数据），运行前去掉；
    /// 顺带去掉 ES module 的 export 语句（JavaScriptCore 按普通脚本执行）
    static func strip(_ source: String) -> String {
        var output: [Substring] = []
        var ignoring = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "// ignore" || trimmed == "//ignore" {
                ignoring.toggle()
                continue
            }
            if !ignoring { output.append(line) }
        }
        var result = output.joined(separator: "\n")
        result = result.replacingOccurrences(
            of: #"(?m)^\s*export\s*\{[^}]*\}\s*;?"#, with: "", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?m)^\s*import\s+[^;\n]*from\s+['"][^'"]+['"]\s*;?"#, with: "", options: .regularExpression
        )
        return result
    }
}
