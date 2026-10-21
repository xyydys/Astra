import Foundation
import JavaScriptCore
import Security

/// 洛雪音乐（LX Music）自定义音源脚本的运行环境。
/// 按 lx-music-desktop 的 userApi/renderer/preload.js 实现 globalThis.lx：
/// EVENT_NAMES、request、send、on、utils（crypto / buffer / zlib）、currentScriptInfo。
/// 脚本跑在 JavaScriptCore 里，所有 JS 调用都在同一个串行队列上执行。
final class LXSourceRuntime: @unchecked Sendable {
    struct ScriptInfo: Codable, Hashable {
        var name = "未命名音源"
        var description = ""
        var version = ""
        var author = ""
        var homepage = ""
    }

    struct SourceSupport: Codable, Hashable {
        var platform: String
        var name: String
        var actions: [String]
        var qualitys: [String]
    }

    let info: ScriptInfo
    private let script: String
    private let queue = DispatchQueue(label: "kazumi.lx-source", qos: .userInitiated)
    private var context: JSContext?
    private(set) var sources: [String: SourceSupport] = [:]
    private var initWaiter: CheckedContinuation<[String: SourceSupport], Error>?
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var requests: [Int: URLSessionDataTask] = [:]
    private var nextID = 0
    /// 最近的脚本日志（显示在音源管理里，方便排查）
    private(set) var logs: [String] = []
    private let logLock = NSLock()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    init(script: String) {
        self.script = script
        info = Self.parseInfo(script)
    }

    deinit {
        for task in requests.values { task.cancel() }
    }

    /// 读取脚本开头注释里的 @name、@description、@version、@author、@homepage
    static func parseInfo(_ script: String) -> ScriptInfo {
        var info = ScriptInfo()
        guard let start = script.range(of: "/*"), let end = script.range(of: "*/", range: start.upperBound..<script.endIndex) else {
            return info
        }
        let header = script[start.upperBound..<end.lowerBound]
        for raw in header.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *\t!"))
            guard line.hasPrefix("@") else { continue }
            let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "name": info.name = String(value.prefix(40))
            case "description": info.description = String(value.prefix(200))
            case "version": info.version = String(value.prefix(20))
            case "author": info.author = String(value.prefix(40))
            case "homepage": info.homepage = String(value.prefix(200))
            default: break
            }
        }
        return info
    }

    func recentLogs() -> [String] {
        logLock.withLock { logs }
    }

    private func log(_ text: String) {
        logLock.withLock {
            logs.append(text)
            if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        }
        #if DEBUG
        print("[LX] " + text)
        #endif
    }

    // MARK: 启动

    /// 执行脚本并等待它 send(inited)
    func start(timeout: TimeInterval = 15) async throws -> [String: SourceSupport] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: SourceSupport], Error>) in
            queue.async { [self] in
                initWaiter = continuation
                setupContext()
                context?.evaluateScript(script)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finishInit(.failure(MusicError.message("音源初始化超时（脚本没有调用 send(inited)）")))
                }
            }
        }
    }

    private func finishInit(_ result: Result<[String: SourceSupport], Error>) {
        guard let waiter = initWaiter else { return }
        initWaiter = nil
        waiter.resume(with: result)
    }

    /// 取播放地址
    func musicUrl(platform: String, quality: String, musicInfo: [String: Any], timeout: TimeInterval = 25) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                guard let context else {
                    continuation.resume(throwing: MusicError.message("音源还没有加载"))
                    return
                }
                nextID += 1
                let id = nextID
                pending[id] = continuation
                let payload: [String: Any] = [
                    "source": platform,
                    "action": "musicUrl",
                    "info": ["type": quality, "musicInfo": musicInfo],
                ]
                context.objectForKeyedSubscript("__lxDispatch").call(withArguments: [id, payload])
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.complete(id, .failure(MusicError.message("音源响应超时")))
                }
            }
        }
    }

    private func complete(_ id: Int, _ result: Result<String, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    func stop() {
        queue.async { [self] in
            for task in requests.values { task.cancel() }
            requests.removeAll()
            for (_, continuation) in pending { continuation.resume(throwing: MusicError.message("音源已停止")) }
            pending.removeAll()
            finishInit(.failure(MusicError.message("音源已停止")))
            context = nil
        }
    }

    // MARK: 环境

    private func setupContext() {
        guard let context = JSContext() else { return }
        self.context = context
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "未知错误"
            self?.log("错误：" + message)
            // 初始化阶段抛出的异常直接算初始化失败
            self?.finishInit(.failure(MusicError.message("音源脚本出错：\(message)")))
        }

        func define<Block>(_ name: String, _ block: Block) {
            context.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: name as NSString)
        }

        let log: @convention(block) (String, String) -> Void = { [weak self] level, text in
            self?.log("[\(level)] \(text)")
        }
        define("__nativeLog", log)

        let schedule: @convention(block) (Int, Double) -> Void = { [weak self] id, ms in
            self?.queue.asyncAfter(deadline: .now() + max(ms, 0) / 1000) { [weak self] in
                self?.context?.objectForKeyedSubscript("__fireTimer").call(withArguments: [id])
            }
        }
        define("__nativeSchedule", schedule)

        let request: @convention(block) (Int, String, JSValue) -> Void = { [weak self] id, url, options in
            self?.performRequest(id: id, url: url, options: options)
        }
        define("__nativeRequest", request)

        let cancel: @convention(block) (Int) -> Void = { [weak self] id in
            self?.requests.removeValue(forKey: id)?.cancel()
        }
        define("__nativeCancel", cancel)

        let send: @convention(block) (String, JSValue) -> String = { [weak self] event, data in
            self?.handleSend(event, data) ?? ""
        }
        define("__nativeSend", send)

        let finish: @convention(block) (Int, JSValue, JSValue) -> Void = { [weak self] id, error, result in
            guard let self else { return }
            if !error.isUndefined, !error.isNull {
                self.complete(id, .failure(MusicError.message(error.toString())))
                return
            }
            let url = result.isString ? result.toString() ?? "" : ""
            if url.hasPrefix("http") {
                self.complete(id, .success(url))
            } else {
                self.complete(id, .failure(MusicError.message("音源没有返回有效的播放地址")))
            }
        }
        define("__nativeFinish", finish)

        let aes: @convention(block) (String, String, String, String) -> String = { data, mode, key, iv in
            LXCrypto.aes(dataB64: data, mode: mode, keyB64: key, ivB64: iv)
        }
        define("__nativeAES", aes)

        let rsa: @convention(block) (String, String) -> String = { data, pem in
            LXCrypto.rsaNoPadding(dataB64: data, pem: pem)
        }
        define("__nativeRSA", rsa)

        let md5: @convention(block) (String) -> String = { b64 in
            EngineCrypto.hex(EngineCrypto.digest(Data(base64Encoded: b64) ?? Data(), algorithm: "md5") ?? Data())
        }
        define("__nativeMD5", md5)

        let random: @convention(block) (Int) -> String = { size in
            var bytes = [UInt8](repeating: 0, count: max(0, min(size, 4096)))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return Data(bytes).base64EncodedString()
        }
        define("__nativeRandom", random)

        let inflate: @convention(block) (String) -> String = { b64 in
            Zlib.inflate(Data(base64Encoded: b64) ?? Data())?.base64EncodedString() ?? ""
        }
        define("__nativeInflate", inflate)

        let deflate: @convention(block) (String) -> String = { b64 in
            Zlib.deflate(Data(base64Encoded: b64) ?? Data())?.base64EncodedString() ?? ""
        }
        define("__nativeDeflate", deflate)

        context.evaluateScript(LXPrelude.buffer)
        context.evaluateScript(LXPrelude.runtime)
        let scriptInfo: [String: Any] = [
            "name": info.name, "description": info.description, "version": info.version,
            "author": info.author, "homepage": info.homepage, "rawScript": script,
        ]
        context.objectForKeyedSubscript("__lxSetup").call(withArguments: [scriptInfo])
    }

    /// lx.send：只认 inited 和 updateAlert
    private func handleSend(_ event: String, _ data: JSValue) -> String {
        switch event {
        case "inited":
            guard initWaiter != nil else { return "Script is inited" }
            var result: [String: SourceSupport] = [:]
            let raw = data.forProperty("sources")
            if let raw, raw.isObject, let dict = raw.toDictionary() as? [String: Any] {
                for (platform, value) in dict {
                    guard let item = value as? [String: Any] else { continue }
                    let type = RuleValue.string(item["type"])
                    guard type.isEmpty || type == "music" else { continue }
                    let actions = (item["actions"] as? [Any])?.map { RuleValue.string($0) } ?? ["musicUrl"]
                    let qualitys = (item["qualitys"] as? [Any])?.map { RuleValue.string($0) } ?? []
                    let name = RuleValue.string(item["name"])
                    result[platform] = SourceSupport(platform: platform, name: name, actions: actions, qualitys: qualitys)
                }
            }
            sources = result
            log("初始化完成：" + result.keys.sorted().joined(separator: ", "))
            finishInit(result.isEmpty ? .failure(MusicError.message("音源没有声明任何平台")) : .success(result))
            return ""
        case "updateAlert":
            let text = data.forProperty("log")?.toString() ?? ""
            log("更新提示：" + text)
            return ""
        default:
            return "The event is not supported: \(event)"
        }
    }

    // MARK: 网络

    private func performRequest(id: Int, url: String, options: JSValue) {
        func option(_ name: String) -> JSValue? {
            guard let value = options.forProperty(name), !value.isUndefined, !value.isNull else { return nil }
            return value
        }
        guard let target = URL.lenient(url) else {
            finishRequest(id: id, error: "Invalid URL: \(url)", response: nil)
            return
        }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = (option("method")?.toString() ?? "GET").uppercased()
        if let timeout = option("timeout")?.toDouble(), timeout > 0 {
            request.timeoutInterval = min(timeout, 60_000) / 1000
        } else {
            request.timeoutInterval = 60
        }
        var headers: [String: String] = [:]
        if let raw = option("headers"), let dict = raw.toDictionary() {
            for (k, v) in dict { headers["\(k)"] = RuleValue.string(v) }
        }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(MusicPlatformAPI.pcUA, forHTTPHeaderField: "User-Agent")
        }
        let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if let body = option("body") {
            if body.isString {
                request.httpBody = Data((body.toString() ?? "").utf8)
            } else if let object = body.toObject(), JSONSerialization.isValidJSONObject(object) {
                if contentType.contains("x-www-form-urlencoded"), let dict = object as? [String: Any] {
                    request.httpBody = Self.formEncode(dict)
                } else {
                    request.httpBody = try? JSONSerialization.data(withJSONObject: object)
                    if contentType.isEmpty { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
                }
            }
        } else if let form = option("form") ?? option("formData") {
            if form.isString {
                request.httpBody = Data((form.toString() ?? "").utf8)
            } else if let dict = form.toDictionary() as? [String: Any] {
                request.httpBody = Self.formEncode(dict)
            }
            if contentType.isEmpty {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        let task = Self.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.requests[id] = nil
                if let error {
                    self.finishRequest(id: id, error: error.localizedDescription, response: nil)
                    return
                }
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)".lowercased()] = "\(v)" }
                let body = data ?? Data()
                let text = String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
                self.finishRequest(id: id, error: nil, response: [
                    "statusCode": http?.statusCode ?? 0,
                    "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0),
                    "headers": headers,
                    "bytes": body.count,
                    "body": text,
                    "rawBase64": body.base64EncodedString(),
                ])
            }
        }
        requests[id] = task
        task.resume()
    }

    private func finishRequest(id: Int, error: String?, response: [String: Any]?) {
        guard let context else { return }
        context.objectForKeyedSubscript("__finishRequest").call(withArguments: [id, error ?? NSNull(), response ?? NSNull()])
    }

    static func formEncode(_ dict: [String: Any]) -> Data {
        Data(dict.map { "\($0.key.queryComponentEncoded)=\(RuleValue.string($0.value).queryComponentEncoded)" }
            .joined(separator: "&").utf8)
    }
}

// MARK: - 加解密

enum LXCrypto {
    /// node 的 createCipheriv(mode, key, iv)：aes-128-cbc / aes-128-ecb / aes-256-cbc ...，默认 PKCS7 填充
    static func aes(dataB64: String, mode: String, keyB64: String, ivB64: String) -> String {
        let data = Data(base64Encoded: dataB64) ?? Data()
        let key = Data(base64Encoded: keyB64) ?? Data()
        let iv = Data(base64Encoded: ivB64) ?? Data()
        let parts = mode.lowercased().split(separator: "-")
        let blockMode = parts.count > 2 ? parts[2].uppercased() : "CBC"
        let output = EngineCrypto.symmetric(
            data, transformation: "AES/\(blockMode)/PKCS5Padding", key: key,
            iv: blockMode == "ECB" ? nil : iv, encrypt: true
        )
        return output?.base64EncodedString() ?? ""
    }

    /// RSA 无填充加密（网易云 weapi 用）
    static func rsaNoPadding(dataB64: String, pem: String) -> String {
        guard let data = Data(base64Encoded: dataB64) else { return "" }
        let body = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        guard var der = Data(base64Encoded: body) else { return "" }
        der = stripSPKI(der)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return "" }
        let blockSize = SecKeyGetBlockSize(key)
        var padded = data
        if padded.count < blockSize { padded = Data(count: blockSize - padded.count) + padded }
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, padded as CFData, nil) else { return "" }
        return (encrypted as Data).base64EncodedString()
    }

    /// X.509 SubjectPublicKeyInfo → PKCS#1（Security 框架只认后者）
    private static func stripSPKI(_ der: Data) -> Data {
        let bytes = [UInt8](der)
        var index = 0
        func readLength() -> Int? {
            guard index < bytes.count else { return nil }
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                length = 0
                for _ in 0..<count {
                    guard index < bytes.count else { return nil }
                    length = length << 8 | Int(bytes[index])
                    index += 1
                }
            }
            return length
        }
        guard bytes.first == 0x30 else { return der }
        index = 1
        guard readLength() != nil, index < bytes.count, bytes[index] == 0x30 else { return der }
        index += 1
        guard let algorithmLength = readLength() else { return der }
        index += algorithmLength
        guard index < bytes.count, bytes[index] == 0x03 else { return der }
        index += 1
        guard readLength() != nil, index < bytes.count else { return der }
        index += 1 // 未使用位数
        return Data(bytes[index...])
    }
}

// MARK: - JS 预置代码

enum LXPrelude {
    /// 精简版 Buffer（Uint8Array 子类），外加 TextEncoder / TextDecoder / atob / btoa
    static let buffer = #"""
    (function () {
      var g = globalThis;
      g.window = g; g.self = g; g.global = g;
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
        var out = [], buffer = 0, bits = 0;
        for (var i = 0; i < str.length; i++) {
          buffer = (buffer << 6) | B64.indexOf(str[i]); bits += 6;
          if (bits >= 8) { bits -= 8; out.push((buffer >> bits) & 255); }
        }
        return out;
      }
      function hexDecode(str) {
        var out = [];
        for (var i = 0; i + 1 < str.length; i += 2) out.push(parseInt(str.substr(i, 2), 16));
        return out;
      }
      class Buffer extends Uint8Array {
        static from(value, encoding) {
          if (typeof value === 'string') {
            var enc = String(encoding || 'utf8').toLowerCase();
            var bytes;
            if (enc === 'base64' || enc === 'base64url') bytes = b64Decode(value);
            else if (enc === 'hex') bytes = hexDecode(value);
            else if (enc === 'binary' || enc === 'latin1' || enc === 'ascii') { bytes = []; for (var i = 0; i < value.length; i++) bytes.push(value.charCodeAt(i) & 255); }
            else bytes = utf8Encode(value);
            var b = new Buffer(bytes.length); b.set(bytes); return b;
          }
          if (value instanceof ArrayBuffer) return new Buffer(value.slice(0));
          if (value && value.type === 'Buffer' && Array.isArray(value.data)) return Buffer.from(value.data);
          if (value && typeof value.length === 'number') { var r = new Buffer(value.length); for (var j = 0; j < value.length; j++) r[j] = value[j] & 255; return r; }
          throw new TypeError('Unsupported Buffer.from argument');
        }
        static alloc(size, fill) { var b = new Buffer(size); if (fill !== undefined) b.fill(typeof fill === 'number' ? fill : 0); return b; }
        static allocUnsafe(size) { return new Buffer(size); }
        static isBuffer(b) { return b instanceof Buffer; }
        static byteLength(str, enc) { return Buffer.from(str, enc).length; }
        static concat(list, total) {
          if (total === undefined) { total = 0; for (var i = 0; i < list.length; i++) total += list[i].length; }
          var out = new Buffer(total), offset = 0;
          for (var k = 0; k < list.length && offset < total; k++) { var item = list[k]; out.set(item.subarray(0, Math.min(item.length, total - offset)), offset); offset += item.length; }
          return out;
        }
        toString(encoding, start, end) {
          var bytes = this.subarray(start || 0, end === undefined ? this.length : end);
          var enc = String(encoding || 'utf8').toLowerCase();
          if (enc === 'hex') { var h = ''; for (var i = 0; i < bytes.length; i++) h += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16); return h; }
          if (enc === 'base64') return b64Encode(bytes);
          if (enc === 'binary' || enc === 'latin1' || enc === 'ascii') { var s = ''; for (var j = 0; j < bytes.length; j++) s += String.fromCharCode(bytes[j]); return s; }
          return utf8Decode(bytes);
        }
        toJSON() { return { type: 'Buffer', data: Array.prototype.slice.call(this) }; }
        equals(other) { if (!other || other.length !== this.length) return false; for (var i = 0; i < this.length; i++) if (this[i] !== other[i]) return false; return true; }
        write(str, offset) { var bytes = utf8Encode(str); this.set(bytes.slice(0, this.length - (offset || 0)), offset || 0); return bytes.length; }
        readUInt8(o) { return this[o]; }
        readUInt16BE(o) { return (this[o] << 8) | this[o + 1]; }
        readUInt32BE(o) { return ((this[o] << 24) >>> 0) + ((this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3]); }
        readUInt32LE(o) { return ((this[o + 3] << 24) >>> 0) + ((this[o + 2] << 16) | (this[o + 1] << 8) | this[o]); }
      }
      g.Buffer = Buffer;
      g.TextEncoder = function () {};
      g.TextEncoder.prototype.encode = function (s) { return new Uint8Array(utf8Encode(String(s === undefined ? '' : s))); };
      g.TextDecoder = function () {};
      g.TextDecoder.prototype.decode = function (b) { return b ? utf8Decode(new Uint8Array(b.buffer || b)) : ''; };
      g.btoa = function (s) { var bytes = []; for (var i = 0; i < s.length; i++) bytes.push(s.charCodeAt(i) & 255); return b64Encode(bytes); };
      g.atob = function (s) { var bytes = b64Decode(s), out = ''; for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]); return out; };
      g.__b64Encode = b64Encode;
    })();
    """#

    /// globalThis.lx、定时器、console
    static let runtime = #"""
    (function () {
      var g = globalThis;
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
      function stringify(args) {
        return Array.prototype.map.call(args, function (a) {
          if (typeof a === 'string') return a;
          if (a instanceof Error) return a.message;
          try { return JSON.stringify(a); } catch (e) { return String(a); }
        }).join(' ');
      }
      g.console = {
        log: function () { __nativeLog('log', stringify(arguments)); },
        info: function () { __nativeLog('info', stringify(arguments)); },
        warn: function () { __nativeLog('warn', stringify(arguments)); },
        error: function () { __nativeLog('error', stringify(arguments)); },
        debug: function () {},
        trace: function () {},
        group: function () {}, groupEnd: function () {}, groupCollapsed: function () {}
      };

      var handlers = {}, reqCallbacks = {}, reqId = 0;
      var EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' };
      function toB64(value) {
        if (value === undefined || value === null) return '';
        if (typeof value === 'string') return g.__b64Encode(Buffer.from(value, 'utf8'));
        return g.__b64Encode(Buffer.from(value));
      }
      g.__lxSetup = function (scriptInfo) {
        var lx = {
          EVENT_NAMES: EVENT_NAMES,
          version: '2.0.0',
          env: 'mobile',
          currentScriptInfo: scriptInfo,
          request: function (url, options, callback) {
            if (typeof options === 'function') { callback = options; options = {}; }
            var id = ++reqId;
            reqCallbacks[id] = callback;
            __nativeRequest(id, String(url), options || {});
            return function () { delete reqCallbacks[id]; __nativeCancel(id); };
          },
          send: function (eventName, data) {
            var error = __nativeSend(String(eventName), data === undefined ? null : data);
            if (error) __nativeLog('warn', error);
            return Promise.resolve();
          },
          on: function (eventName, handler) {
            // 洛雪音乐会 reject；有些音源会注册桌面版没有的事件（比如配置界面），这里安静忽略
            if (eventName !== EVENT_NAMES.request) { __nativeLog('warn', '忽略不支持的事件：' + eventName); return Promise.resolve(); }
            handlers.request = handler;
            return Promise.resolve();
          },
          utils: {
            crypto: {
              aesEncrypt: function (buffer, mode, key, iv) {
                return Buffer.from(__nativeAES(toB64(buffer), String(mode), toB64(key), toB64(iv)), 'base64');
              },
              rsaEncrypt: function (buffer, key) {
                return Buffer.from(__nativeRSA(toB64(buffer), String(key)), 'base64');
              },
              randomBytes: function (size) { return Buffer.from(__nativeRandom(size), 'base64'); },
              md5: function (str) { return __nativeMD5(toB64(str)); }
            },
            buffer: {
              from: function () { return Buffer.from.apply(Buffer, arguments); },
              bufToString: function (buf, format) { return Buffer.from(buf, 'binary').toString(format); }
            },
            zlib: {
              inflate: function (buf) {
                var out = __nativeInflate(toB64(buf));
                return out ? Promise.resolve(Buffer.from(out, 'base64')) : Promise.reject(new Error('inflate failed'));
              },
              deflate: function (buf) {
                var out = __nativeDeflate(toB64(buf));
                return out ? Promise.resolve(Buffer.from(out, 'base64')) : Promise.reject(new Error('deflate failed'));
              }
            }
          }
        };
        g.lx = lx;
      };
      g.__finishRequest = function (id, error, resp) {
        var cb = reqCallbacks[id];
        delete reqCallbacks[id];
        if (typeof cb !== 'function') return;
        if (error) { cb.call(g.lx, new Error(error), null, null); return; }
        var raw = Buffer.from(resp.rawBase64 || '', 'base64');
        delete resp.rawBase64;
        var body = resp.body;
        try { body = JSON.parse(resp.body); } catch (e) {}
        resp.body = body;
        resp.raw = raw;
        cb.call(g.lx, null, resp, body);
      };
      g.__lxDispatch = function (id, payload) {
        try {
          var handler = handlers.request;
          if (!handler) { __nativeFinish(id, 'Request event is not defined', null); return; }
          Promise.resolve(handler.call(g.lx, payload)).then(function (result) {
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
}
