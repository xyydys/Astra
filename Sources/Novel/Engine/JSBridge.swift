import Foundation
import JavaScriptCore
import SwiftSoup

/// JS 里 java.getString 等需要回调到规则解析器
protocol JSHost: AnyObject {
    var hostBaseUrl: String? { get }
    var hostBook: RuleBook? { get }
    var hostChapter: RuleChapter? { get }
    func hostGetString(_ rule: String, content: Any?, isUrl: Bool) -> String
    func hostGetStringList(_ rule: String, content: Any?, isUrl: Bool) -> [String]
    func hostGetElements(_ rule: String) -> [Any]
    func hostGetElement(_ rule: String) -> Any?
    func hostSetContent(_ content: Any?, baseUrl: String?)
    func hostPut(_ key: String, _ value: String) -> String
    func hostGet(_ key: String) -> String
}

/// 书源 JS 的运行环境（JavaScriptCore）。阅读用的是 Rhino，这里补上常用的 java.* 扩展函数
final class JSEngine {
    struct BookRef { let book: RuleBook }
    struct ChapterRef { let chapter: RuleChapter }

    let context: JSContext
    private let env: EngineEnv
    private let source: BookSource?
    private weak var host: JSHost?
    private var lastException: String?
    private var runner: JSValue?

    static let userAgent = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"

    init(env: EngineEnv, source: BookSource?, host: JSHost?) {
        self.env = env
        self.source = source
        self.host = host
        let vm = env.sharedVM { JSVirtualMachine() }
        context = JSContext(virtualMachine: vm)
        context.exceptionHandler = { [weak self] _, exception in
            guard let self else { return }
            var message = exception?.toString() ?? "未知错误"
            if let line = exception?.objectForKeyedSubscript("line"), !line.isUndefined {
                message += "（第 \(line.toInt32()) 行）"
            }
            self.lastException = message
        }
        context.evaluateScript(Self.prelude)
        runner = context.objectForKeyedSubscript("__kgRun")
        installJava()
        installCookie()
        installCache()
        installSource()
        if let lib = source?.jsLib, !lib.isEmpty, !lib.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            context.evaluateScript(lib)
            lastException = nil
        }
    }

    /// 每段 JS 在函数作用域里 eval：顶层的 let / const 不会和上一段冲突，返回值是最后一个表达式
    private static let prelude = """
    var __kgRun = function(__kgCode) { return eval(String(__kgCode)); };
    var __kgList = function(arr) {
      Object.defineProperty(arr, 'size', { value: function() { return this.length; }, enumerable: false });
      Object.defineProperty(arr, 'get', { value: function(i) { return this[i]; }, enumerable: false });
      Object.defineProperty(arr, 'isEmpty', { value: function() { return this.length == 0; }, enumerable: false });
      Object.defineProperty(arr, 'first', { value: function() { return this[0]; }, enumerable: false });
      Object.defineProperty(arr, 'last', { value: function() { return this[this.length - 1]; }, enumerable: false });
      Object.defineProperty(arr, 'toArray', { value: function() { return this; }, enumerable: false });
      Object.defineProperty(arr, 'text', { value: function() { return this.map(function(e) { return e.text(); }).join(' '); }, enumerable: false });
      Object.defineProperty(arr, 'html', { value: function() { return this.map(function(e) { return e.html(); }).join('\\n'); }, enumerable: false });
      Object.defineProperty(arr, 'outerHtml', { value: function() { return this.map(function(e) { return e.outerHtml(); }).join('\\n'); }, enumerable: false });
      Object.defineProperty(arr, 'attr', { value: function(k) { for (var i = 0; i < this.length; i++) { if (this[i].hasAttr(k)) return this[i].attr(k); } return ''; }, enumerable: false });
      Object.defineProperty(arr, 'eachAttr', { value: function(k) { var out = []; for (var i = 0; i < this.length; i++) { if (this[i].hasAttr(k)) out.push(this[i].attr(k)); } return out; }, enumerable: false });
      Object.defineProperty(arr, 'eachText', { value: function() { return this.map(function(e) { return e.text(); }); }, enumerable: false });
      Object.defineProperty(arr, 'select', { value: function(css) { var out = []; for (var i = 0; i < this.length; i++) { out = out.concat(Array.prototype.slice.call(this[i].select(css))); } return __kgList(out); }, enumerable: false });
      Object.defineProperty(arr, 'eq', { value: function(i) { return __kgList(this[i] ? [this[i]] : []); }, enumerable: false });
      Object.defineProperty(arr, 'remove', { value: function() { for (var i = 0; i < this.length; i++) { this[i].remove(); } return this; }, enumerable: false });
      Object.defineProperty(arr, 'toString', { value: function() { return this.outerHtml(); }, enumerable: false, writable: true });
      return arr;
    };
    if (!String.prototype.equals) { String.prototype.equals = function(o) { return String(this) == String(o); }; }
    if (!String.prototype.equalsIgnoreCase) { String.prototype.equalsIgnoreCase = function(o) { return String(this).toLowerCase() == String(o).toLowerCase(); }; }
    if (!String.prototype.contains) { String.prototype.contains = function(o) { return String(this).indexOf(String(o)) >= 0; }; }
    if (!String.prototype.isEmpty) { String.prototype.isEmpty = function() { return this.length == 0; }; }
    if (!String.prototype.matches) { String.prototype.matches = function(re) { return new RegExp('^(?:' + re + ')$').test(String(this)); }; }
    if (!String.prototype.replaceFirst) { String.prototype.replaceFirst = function(re, s) { return String(this).replace(new RegExp(re), s); }; }
    """

    // MARK: 执行

    func eval(_ code: String, bindings: [String: Any?]) throws -> Any? {
        let names = Array(bindings.keys)
        let saved = names.map { context.objectForKeyedSubscript($0) }
        for name in names {
            context.setObject(toJS(bindings[name] ?? nil), forKeyedSubscript: name as NSString)
        }
        let previousException = lastException
        lastException = nil
        let value = runner?.call(withArguments: [code])
        let exception = lastException
        lastException = previousException
        for (name, value) in zip(names, saved) {
            context.setObject(value, forKeyedSubscript: name as NSString)
        }
        if let exception { throw BookEngineError.js(exception) }
        return fromJS(value)
    }

    // MARK: 类型转换

    func toJS(_ value: Any?) -> JSValue {
        toJS(value, in: context)
    }

    func toJS(_ value: Any?, in ctx: JSContext) -> JSValue {
        guard let value else { return JSValue(nullIn: ctx) }
        switch value {
        case let v as JSValue:
            return v
        case let s as String:
            return JSValue(object: s, in: ctx)
        case let e as Element:
            return JSValue(object: ElementBox(e), in: ctx)
        case let ref as BookRef:
            return bookObject(ref.book, in: ctx)
        case let ref as ChapterRef:
            return chapterObject(ref.chapter, in: ctx)
        case let response as StrResponse:
            return JSValue(object: ResponseBox(response), in: ctx)
        case let data as Data:
            return bytesValue(data, in: ctx)
        case is NSNull:
            return JSValue(nullIn: ctx)
        case let list as [Any]:
            let array = JSValue(newArrayIn: ctx)!
            for (i, item) in list.enumerated() {
                array.setObject(toJS(item, in: ctx), atIndexedSubscript: i)
            }
            if list.contains(where: { $0 is Element }) {
                return ctx.objectForKeyedSubscript("__kgList").call(withArguments: [array]) ?? array
            }
            return array
        case let dict as [String: Any]:
            return JSValue(object: dict, in: ctx)
        default:
            return JSValue(object: value, in: ctx)
        }
    }

    func fromJS(_ value: JSValue?) -> Any? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString { return value.toString() }
        if value.isBoolean { return value.toBool() }
        if value.isNumber { return value.toNumber() }
        if value.isArray {
            let length = Int(value.forProperty("length")?.toInt32() ?? 0)
            var out: [Any] = []
            out.reserveCapacity(length)
            for i in 0..<length {
                out.append(fromJS(value.atIndex(i)) ?? NSNull())
            }
            return out
        }
        if let box = value.toObjectOf(ElementBox.self) as? ElementBox { return box.element }
        if let box = value.toObjectOf(ResponseBox.self) as? ResponseBox { return box.response.body }
        if value.isObject, let dict = value.toDictionary() {
            var out: [String: Any] = [:]
            for (k, v) in dict { out["\(k)"] = v }
            return out
        }
        return value.toString()
    }

    private func bytesValue(_ data: Data, in ctx: JSContext) -> JSValue {
        let array = JSValue(newArrayIn: ctx)!
        for (i, byte) in data.enumerated() {
            array.setObject(Int(Int8(bitPattern: byte)), atIndexedSubscript: i)
        }
        return array
    }

    /// JS 传来的字节数组或字符串
    static func bytes(_ value: JSValue?, encoding: String.Encoding = .utf8) -> Data {
        guard let value, !value.isUndefined, !value.isNull else { return Data() }
        if value.isString { return value.toString().data(using: encoding) ?? Data() }
        if value.isArray || value.isObject, let lengthValue = value.forProperty("length"), lengthValue.isNumber {
            let length = Int(lengthValue.toInt32())
            var out = Data(capacity: length)
            for i in 0..<length {
                out.append(UInt8(truncatingIfNeeded: value.atIndex(i).toInt32()))
            }
            return out
        }
        return Data(value.toString().utf8)
    }

    // MARK: 定义函数

    private func define(_ object: JSValue, _ name: String, _ body: @escaping ([JSValue]) -> Any?) {
        let block: @convention(block) () -> JSValue? = { [weak self] in
            guard let self, let ctx = JSContext.current() else { return nil }
            let args = (JSContext.currentArguments() as? [JSValue]) ?? []
            return self.toJS(body(args), in: ctx)
        }
        object.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: name as NSString)
    }

    private func arg(_ args: [JSValue], _ i: Int) -> String? {
        guard i < args.count, !args[i].isUndefined, !args[i].isNull else { return nil }
        return args[i].toString()
    }

    private func headerMap(_ value: JSValue?) -> [String: String] {
        guard let value, value.isObject, let dict = value.toDictionary() else {
            if let value, value.isString, let data = value.toString().data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] {
                return json.mapValues { RuleValue.string($0) }
            }
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in dict { out["\(k)"] = RuleValue.string(v) }
        return out
    }

    // MARK: java

    private func installJava() {
        let java = JSValue(newObjectIn: context)!

        // 网络
        define(java, "ajax") { [unowned self] args in
            guard let first = args.first else { return nil }
            let url = first.isArray ? first.atIndex(0).toString() ?? "" : first.toString() ?? ""
            return self.request(url).body
        }
        define(java, "ajaxAll") { [unowned self] args in
            guard let first = args.first, first.isArray else { return [] }
            let length = Int(first.forProperty("length")?.toInt32() ?? 0)
            return (0..<length).map { self.request(first.atIndex($0).toString() ?? "") as Any }
        }
        define(java, "connect") { [unowned self] args in
            var url = self.arg(args, 0) ?? ""
            if let header = self.arg(args, 1), !header.isEmpty {
                url += ",{\"headers\":" + header + "}"
            }
            return self.request(url)
        }
        define(java, "get") { [unowned self] args in
            if args.count >= 2, let url = self.arg(args, 0), EngineURL.isAbsolute(url) || url.hasPrefix("/") {
                return self.rawRequest(url, method: "GET", body: nil, headers: self.headerMap(args[1]))
            }
            return self.host?.hostGet(self.arg(args, 0) ?? "") ?? ""
        }
        define(java, "post") { [unowned self] args in
            self.rawRequest(self.arg(args, 0) ?? "", method: "POST", body: self.arg(args, 1), headers: self.headerMap(args.count > 2 ? args[2] : nil))
        }
        define(java, "head") { [unowned self] args in
            self.rawRequest(self.arg(args, 0) ?? "", method: "HEAD", body: nil, headers: self.headerMap(args.count > 1 ? args[1] : nil))
        }
        define(java, "put") { [unowned self] args in
            let key = self.arg(args, 0) ?? ""
            let value = args.count > 1 ? RuleValue.string(self.fromJS(args[1])) : ""
            return self.host?.hostPut(key, value) ?? value
        }
        define(java, "webView") { [unowned self] args in
            let html = self.arg(args, 0)
            let url = self.arg(args, 1) ?? self.host?.hostBaseUrl ?? ""
            let js = self.arg(args, 2)
            guard let loader = EngineHooks.webLoader else { return html ?? "" }
            return (try? loader.load(url: url, html: html, headers: [:], js: js, delay: 0)) ?? ""
        }
        define(java, "startBrowser") { args in
            EngineHooks.debug("书源请求打开浏览器：\(args.first?.toString() ?? "")")
            return nil
        }
        define(java, "startBrowserAwait") { [unowned self] args in
            // 没有交互式浏览器：直接请求一次页面
            let url = self.arg(args, 0) ?? ""
            if let loader = EngineHooks.webLoader, let html = try? loader.load(url: url, html: nil, headers: [:], js: nil, delay: 0) {
                return StrResponse(url: url, body: html, code: 200, headers: [:])
            }
            return self.request(url)
        }
        define(java, "getVerificationCode") { _ in "" }

        // 规则
        define(java, "getString") { [unowned self] args in
            let rule = self.arg(args, 0) ?? ""
            var content: Any?
            var isUrl = false
            if args.count > 1 {
                if args[1].isBoolean { isUrl = args[1].toBool() } else { content = self.fromJS(args[1]) }
            }
            if args.count > 2, args[2].isBoolean { isUrl = args[2].toBool() }
            return self.host?.hostGetString(rule, content: content, isUrl: isUrl) ?? ""
        }
        define(java, "getStringList") { [unowned self] args in
            let rule = self.arg(args, 0) ?? ""
            var content: Any?
            var isUrl = false
            if args.count > 1 {
                if args[1].isBoolean { isUrl = args[1].toBool() } else { content = self.fromJS(args[1]) }
            }
            if args.count > 2, args[2].isBoolean { isUrl = args[2].toBool() }
            return self.host?.hostGetStringList(rule, content: content, isUrl: isUrl) ?? []
        }
        define(java, "getElements") { [unowned self] args in
            self.host?.hostGetElements(self.arg(args, 0) ?? "") ?? []
        }
        define(java, "getElement") { [unowned self] args in
            self.host?.hostGetElement(self.arg(args, 0) ?? "")
        }
        define(java, "setContent") { [unowned self] args in
            self.host?.hostSetContent(args.isEmpty ? nil : self.fromJS(args[0]), baseUrl: self.arg(args, 1))
            return nil
        }

        // 日志
        define(java, "log") { args in
            let text = args.first.map { $0.toString() ?? "" } ?? ""
            EngineHooks.debug(text)
            return args.first
        }
        define(java, "logType") { args in
            EngineHooks.debug("type: \(args.first.map { $0.isString ? "String" : $0.isArray ? "Array" : $0.isObject ? "Object" : "other" } ?? "null")")
            return nil
        }
        define(java, "toast") { args in
            EngineHooks.toast?(args.first?.toString() ?? "")
            return nil
        }
        define(java, "longToast") { args in
            EngineHooks.toast?(args.first?.toString() ?? "")
            return nil
        }

        // 编码
        define(java, "md5Encode") { [unowned self] args in EngineCrypto.md5Hex(self.arg(args, 0) ?? "") }
        define(java, "md5Encode16") { [unowned self] args in
            let full = EngineCrypto.md5Hex(self.arg(args, 0) ?? "")
            return String(full.dropFirst(8).prefix(16))
        }
        define(java, "base64Decode") { [unowned self] args in
            guard let data = EngineCrypto.base64Decode(self.arg(args, 0) ?? "") else { return "" }
            var encoding = String.Encoding.utf8
            if args.count > 1, args[1].isString, let named = EngineText.encoding(named: args[1].toString()) { encoding = named }
            return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        }
        define(java, "base64DecodeToByteArray") { [unowned self] args in
            EngineCrypto.base64Decode(self.arg(args, 0) ?? "") ?? Data()
        }
        define(java, "base64Encode") { [unowned self] args in
            Data((self.arg(args, 0) ?? "").utf8).base64EncodedString()
        }
        define(java, "hexDecodeToString") { [unowned self] args in
            guard let data = EngineCrypto.hexDecode(self.arg(args, 0) ?? "") else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        define(java, "hexDecodeToByteArray") { [unowned self] args in
            EngineCrypto.hexDecode(self.arg(args, 0) ?? "") ?? Data()
        }
        define(java, "hexEncodeToString") { [unowned self] args in
            EngineCrypto.hex(Data((self.arg(args, 0) ?? "").utf8))
        }
        define(java, "strToBytes") { [unowned self] args in
            let encoding = EngineText.encoding(named: self.arg(args, 1)) ?? .utf8
            return (self.arg(args, 0) ?? "").data(using: encoding, allowLossyConversion: true) ?? Data()
        }
        define(java, "bytesToStr") { [unowned self] args in
            let encoding = EngineText.encoding(named: self.arg(args, 1)) ?? .utf8
            let bytes = Self.bytes(args.first)
            return String(data: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
        }
        define(java, "encodeURI") { [unowned self] args in
            let encoding = EngineText.encoding(named: self.arg(args, 1)) ?? .utf8
            return EngineText.urlEncode(self.arg(args, 0) ?? "", encoding: encoding)
        }
        define(java, "utf8ToGbk") { [unowned self] args in self.arg(args, 0) ?? "" }
        define(java, "htmlFormat") { [unowned self] args in
            HTMLFormatter.formatKeepImage(self.arg(args, 0), baseURL: self.host?.hostBaseUrl)
        }
        define(java, "timeFormat") { args in
            let ms = args.first?.toDouble() ?? 0
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        define(java, "timeFormatUTC") { [unowned self] args in
            let ms = args.first?.toDouble() ?? 0
            let formatter = DateFormatter()
            formatter.dateFormat = self.arg(args, 1) ?? "yyyy-MM-dd HH:mm:ss"
            let hours = args.count > 2 ? Int(args[2].toInt32()) : 0
            formatter.timeZone = TimeZone(secondsFromGMT: hours * 3600)
            return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        define(java, "toNumChapter") { [unowned self] args in ChineseNumber.toNumChapter(self.arg(args, 0)) }
        define(java, "t2s") { [unowned self] args in
            (self.arg(args, 0) ?? "").applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? ""
        }
        define(java, "s2t") { [unowned self] args in
            (self.arg(args, 0) ?? "").applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? ""
        }
        define(java, "randomUUID") { _ in UUID().uuidString.lowercased() }
        define(java, "androidId") { _ in Self.deviceID }
        define(java, "deviceID") { _ in Self.deviceID }
        define(java, "getWebViewUA") { _ in Self.userAgent }
        define(java, "getUserAgent") { _ in Self.userAgent }

        // 加解密
        for (name, transformation) in [("aes", "AES"), ("des", "DES")] {
            define(java, name + "DecodeToString") { [unowned self] args in
                self.crypto(args, defaultAlgorithm: transformation, encrypt: false, output: "string")
            }
            define(java, name + "Base64DecodeToString") { [unowned self] args in
                self.crypto(args, defaultAlgorithm: transformation, encrypt: false, output: "string")
            }
            define(java, name + "DecodeToByteArray") { [unowned self] args in
                self.crypto(args, defaultAlgorithm: transformation, encrypt: false, output: "bytes")
            }
            define(java, name + "Base64DecodeToByteArray") { [unowned self] args in
                self.crypto(args, defaultAlgorithm: transformation, encrypt: false, output: "bytes")
            }
            define(java, name + "EncodeToString") { [unowned self] args in
                self.crypto(args, defaultAlgorithm: transformation, encrypt: true, output: "hex")
            }
            define(java, name + "EncodeToBase64String") { [unowned self] args in
                self.crypto(args, defaultAlgorithm: transformation, encrypt: true, output: "base64")
            }
        }
        define(java, "createSymmetricCrypto") { [unowned self] args in
            self.symmetricObject(
                transformation: self.arg(args, 0) ?? "AES/ECB/PKCS5Padding",
                key: Self.bytes(args.count > 1 ? args[1] : nil),
                iv: args.count > 2 ? Self.bytes(args[2]) : nil
            )
        }
        define(java, "digestHex") { [unowned self] args in
            EngineCrypto.digest(Self.bytes(args.first), algorithm: self.arg(args, 1) ?? "MD5").map(EngineCrypto.hex) ?? ""
        }
        define(java, "digestBase64Str") { [unowned self] args in
            EngineCrypto.digest(Self.bytes(args.first), algorithm: self.arg(args, 1) ?? "MD5")?.base64EncodedString() ?? ""
        }
        define(java, "HMacHex") { [unowned self] args in
            EngineCrypto.hmac(Self.bytes(args.first), algorithm: self.arg(args, 1) ?? "HmacSHA256", key: Self.bytes(args.count > 2 ? args[2] : nil))
                .map(EngineCrypto.hex) ?? ""
        }
        define(java, "HMacBase64") { [unowned self] args in
            EngineCrypto.hmac(Self.bytes(args.first), algorithm: self.arg(args, 1) ?? "HmacSHA256", key: Self.bytes(args.count > 2 ? args[2] : nil))?
                .base64EncodedString() ?? ""
        }

        // 其它
        define(java, "getCookie") { [unowned self] args in
            let tag = self.arg(args, 0) ?? ""
            if let key = self.arg(args, 1) { return CookieJar.getKey(tag, key) }
            return CookieJar.getCookie(tag)
        }
        define(java, "cacheFile") { [unowned self] args in
            let url = self.arg(args, 0) ?? ""
            let key = "cacheFile_" + EngineCrypto.md5Hex(url)
            if let cached = EngineStorage.shared.get(key) { return cached }
            let body = self.request(url).body
            let seconds = args.count > 1 ? args[1].toDouble() : 0
            if !body.isEmpty { EngineStorage.shared.put(key, body, seconds: seconds) }
            return body
        }
        define(java, "importScript") { [unowned self] args in
            let path = self.arg(args, 0) ?? ""
            guard EngineURL.isAbsolute(path) else { return "" }
            let key = "importScript_" + EngineCrypto.md5Hex(path)
            if let cached = EngineStorage.shared.get(key) { return cached }
            let body = self.request(path).body
            if !body.isEmpty { EngineStorage.shared.put(key, body) }
            return body
        }
        define(java, "replaceFont") { [unowned self] args in self.arg(args, 0) ?? "" }
        define(java, "queryTTF") { _ in nil }
        define(java, "queryBase64TTF") { _ in nil }
        for name in ["refreshTocUrl", "refreshBookUrl", "refreshContent", "refreshExplore", "openUrl", "openVideoPlayer",
                     "downloadFile", "readFile", "readTxtFile", "unzipFile", "getZipStringContent", "getTxtInFolder"] {
            define(java, name) { _ in "" }
        }

        context.setObject(java, forKeyedSubscript: "java" as NSString)
    }

    private static let deviceID: String = {
        let key = "deviceID"
        if let id = EngineStorage.shared.get(key) { return id }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        EngineStorage.shared.put(key, id)
        return id
    }()

    private func crypto(_ args: [JSValue], defaultAlgorithm: String, encrypt: Bool, output: String) -> Any? {
        let text = arg(args, 0) ?? ""
        let key = Self.bytes(args.count > 1 ? args[1] : nil)
        var transformation = arg(args, 2) ?? defaultAlgorithm + "/ECB/PKCS5Padding"
        if !transformation.contains("/") { transformation = defaultAlgorithm + "/ECB/PKCS5Padding" }
        let iv = args.count > 3 ? Self.bytes(args[3]) : nil
        let input = encrypt ? Data(text.utf8) : EngineCrypto.decodeInput(text)
        guard let result = EngineCrypto.symmetric(input, transformation: transformation, key: key, iv: iv, encrypt: encrypt) else {
            return nil
        }
        switch output {
        case "bytes": return result
        case "hex": return EngineCrypto.hex(result)
        case "base64": return result.base64EncodedString()
        default: return String(data: result, encoding: .utf8) ?? String(decoding: result, as: UTF8.self)
        }
    }

    private func symmetricObject(transformation: String, key: Data, iv: Data?) -> JSValue {
        let object = JSValue(newObjectIn: context)!
        func input(_ value: JSValue?, encrypt: Bool) -> Data {
            guard let value else { return Data() }
            if value.isString {
                let text = value.toString() ?? ""
                return encrypt ? Data(text.utf8) : EngineCrypto.decodeInput(text)
            }
            return JSEngine.bytes(value)
        }
        define(object, "decrypt") { args in
            EngineCrypto.symmetric(input(args.first, encrypt: false), transformation: transformation, key: key, iv: iv, encrypt: false) ?? Data()
        }
        define(object, "decryptStr") { args in
            let out = EngineCrypto.symmetric(input(args.first, encrypt: false), transformation: transformation, key: key, iv: iv, encrypt: false) ?? Data()
            return String(data: out, encoding: .utf8) ?? String(decoding: out, as: UTF8.self)
        }
        define(object, "encrypt") { args in
            EngineCrypto.symmetric(input(args.first, encrypt: true), transformation: transformation, key: key, iv: iv, encrypt: true) ?? Data()
        }
        define(object, "encryptBase64") { args in
            (EngineCrypto.symmetric(input(args.first, encrypt: true), transformation: transformation, key: key, iv: iv, encrypt: true) ?? Data())
                .base64EncodedString()
        }
        define(object, "encryptHex") { args in
            EngineCrypto.hex(EngineCrypto.symmetric(input(args.first, encrypt: true), transformation: transformation, key: key, iv: iv, encrypt: true) ?? Data())
        }
        return object
    }

    // MARK: 网络

    func request(_ url: String) -> StrResponse {
        do {
            let analyze = try AnalyzeUrl(
                url, baseUrl: host?.hostBaseUrl ?? source?.bookSourceUrl ?? "", source: source,
                book: host?.hostBook, chapter: host?.hostChapter, env: env
            )
            return try analyze.strResponse()
        } catch {
            EngineHooks.debug("ajax(\(url)) 出错：\(error.localizedDescription)")
            return StrResponse(url: url, body: error.localizedDescription, code: 500, headers: [:])
        }
    }

    private func rawRequest(_ url: String, method: String, body: String?, headers: [String: String]) -> StrResponse {
        let absolute = EngineURL.absolute(host?.hostBaseUrl ?? source?.bookSourceUrl, url)
        guard let target = URL.lenient(absolute) else {
            return StrResponse(url: url, body: "", code: 0, headers: [:])
        }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        if headers.keys.contains(where: { $0.lowercased() == "user-agent" }) == false {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(body.looksLikeJSON ? "application/json; charset=UTF-8" : "application/x-www-form-urlencoded",
                                 forHTTPHeaderField: "Content-Type")
            }
        }
        do {
            let (data, response) = try EngineHTTP.perform(request, token: env.token, followRedirects: false)
            return StrResponse(
                url: response.url?.absoluteString ?? absolute,
                body: EngineText.decode(data, charset: nil, response: response),
                code: response.statusCode,
                headers: EngineHTTP.headers(response)
            )
        } catch {
            return StrResponse(url: absolute, body: error.localizedDescription, code: 500, headers: [:])
        }
    }

    // MARK: cookie / cache / source

    private func installCookie() {
        let cookie = JSValue(newObjectIn: context)!
        define(cookie, "getCookie") { [unowned self] args in CookieJar.getCookie(self.arg(args, 0) ?? "") }
        define(cookie, "getKey") { [unowned self] args in CookieJar.getKey(self.arg(args, 0) ?? "", self.arg(args, 1) ?? "") }
        define(cookie, "setCookie") { [unowned self] args in
            CookieJar.setCookie(self.arg(args, 0) ?? "", self.arg(args, 1))
            return nil
        }
        define(cookie, "replaceCookie") { [unowned self] args in
            CookieJar.replaceCookie(self.arg(args, 0) ?? "", self.arg(args, 1))
            return nil
        }
        define(cookie, "removeCookie") { [unowned self] args in
            CookieJar.removeCookie(self.arg(args, 0) ?? "")
            return nil
        }
        context.setObject(cookie, forKeyedSubscript: "cookie" as NSString)
    }

    private func installCache() {
        let cache = JSValue(newObjectIn: context)!
        let storage = EngineStorage.shared
        define(cache, "get") { [unowned self] args in storage.get(self.arg(args, 0) ?? "") }
        define(cache, "getFile") { [unowned self] args in storage.get(self.arg(args, 0) ?? "") }
        define(cache, "put") { [unowned self] args in
            let seconds = args.count > 2 ? args[2].toDouble() : 0
            storage.put(self.arg(args, 0) ?? "", args.count > 1 ? RuleValue.string(self.fromJS(args[1])) : "", seconds: seconds)
            return nil
        }
        define(cache, "putFile") { [unowned self] args in
            let seconds = args.count > 2 ? args[2].toDouble() : 0
            storage.put(self.arg(args, 0) ?? "", args.count > 1 ? RuleValue.string(self.fromJS(args[1])) : "", seconds: seconds)
            return nil
        }
        define(cache, "delete") { [unowned self] args in
            storage.delete(self.arg(args, 0) ?? "")
            return nil
        }
        define(cache, "getFromMemory") { [unowned self] args in storage.getMemory(self.arg(args, 0) ?? "") }
        define(cache, "putMemory") { [unowned self] args in
            storage.putMemory(self.arg(args, 0) ?? "", args.count > 1 ? RuleValue.string(self.fromJS(args[1])) : "")
            return nil
        }
        define(cache, "deleteMemory") { [unowned self] args in
            storage.deleteMemory(self.arg(args, 0) ?? "")
            return nil
        }
        context.setObject(cache, forKeyedSubscript: "cache" as NSString)
    }

    private func installSource() {
        guard let source else {
            context.setObject(JSValue(nullIn: context), forKeyedSubscript: "source" as NSString)
            return
        }
        let object = JSValue(newObjectIn: context)!
        let fields: [String: Any] = [
            "bookSourceUrl": source.bookSourceUrl, "bookSourceName": source.bookSourceName,
            "bookSourceGroup": source.bookSourceGroup, "bookSourceComment": source.bookSourceComment,
            "bookSourceType": source.bookSourceType, "loginUrl": source.loginUrl, "header": source.header,
            "variableComment": source.variableComment, "key": source.key, "searchUrl": source.searchUrl,
            "exploreUrl": source.exploreUrl, "jsLib": source.jsLib,
        ]
        for (k, v) in fields { object.setObject(v, forKeyedSubscript: k as NSString) }
        let key = source.key
        let storage = EngineStorage.shared
        define(object, "getKey") { _ in key }
        define(object, "getTag") { _ in source.bookSourceName }
        define(object, "getVariable") { _ in storage.sourceVariable(key) }
        define(object, "setVariable") { [unowned self] args in
            storage.setSourceVariable(key, self.arg(args, 0))
            return nil
        }
        define(object, "put") { [unowned self] args in
            let value = self.arg(args, 1) ?? ""
            storage.put("v_" + key + "_" + (self.arg(args, 0) ?? ""), value)
            return value
        }
        define(object, "get") { [unowned self] args in storage.get("v_" + key + "_" + (self.arg(args, 0) ?? "")) ?? "" }
        define(object, "getLoginInfo") { _ in storage.loginInfo(key) }
        define(object, "getLoginInfoMap") { _ in
            guard let info = storage.loginInfo(key), let data = info.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        define(object, "putLoginInfo") { [unowned self] args in
            storage.setLoginInfo(key, self.arg(args, 0))
            return true
        }
        define(object, "removeLoginInfo") { _ in
            storage.setLoginInfo(key, nil)
            return nil
        }
        define(object, "getLoginHeader") { _ in storage.loginHeader(key) }
        define(object, "getLoginHeaderMap") { _ in
            guard let header = storage.loginHeader(key), let data = header.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        define(object, "putLoginHeader") { [unowned self] args in
            storage.setLoginHeader(key, self.arg(args, 0))
            return nil
        }
        define(object, "removeLoginHeader") { _ in
            storage.setLoginHeader(key, nil)
            return nil
        }
        define(object, "getHeaderMap") { [unowned self] _ in
            AnalyzeUrl.headerMap(for: source, env: self.env)
        }
        context.setObject(object, forKeyedSubscript: "source" as NSString)
    }

    private func bookObject(_ ruleBook: RuleBook, in ctx: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: ctx)!
        let book = ruleBook.book
        let fields: [String: Any] = [
            "name": book.name, "author": book.author, "bookUrl": book.bookUrl, "tocUrl": book.tocUrl,
            "origin": book.origin, "originName": book.originName, "coverUrl": book.coverUrl, "intro": book.intro,
            "kind": book.kind, "latestChapterTitle": book.latestChapterTitle, "wordCount": book.wordCount,
            "durChapterTitle": ruleBook.durChapterTitle, "durChapterIndex": ruleBook.durChapterIndex,
            "type": 0, "variable": RuleValue.string(book.variables),
        ]
        for (k, v) in fields { object.setObject(v, forKeyedSubscript: k as NSString) }
        define(object, "getVariable") { [unowned self] args in
            if let key = self.arg(args, 0) { return ruleBook.getVariable(key) }
            return RuleValue.string(ruleBook.book.variables)
        }
        define(object, "putVariable") { [unowned self] args in
            ruleBook.putVariable(self.arg(args, 0) ?? "", self.arg(args, 1))
            return nil
        }
        return object
    }

    private func chapterObject(_ ruleChapter: RuleChapter, in ctx: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: ctx)!
        let chapter = ruleChapter.chapter
        let fields: [String: Any] = [
            "title": chapter.title, "url": chapter.url, "index": chapter.index, "baseUrl": chapter.baseUrl,
            "isVolume": chapter.isVolume, "isVip": chapter.isVip, "isPay": chapter.isPay, "tag": chapter.tag,
        ]
        for (k, v) in fields { object.setObject(v, forKeyedSubscript: k as NSString) }
        define(object, "getVariable") { [unowned self] args in
            if let key = self.arg(args, 0) { return ruleChapter.chapter.variables[key] ?? "" }
            return RuleValue.string(ruleChapter.chapter.variables)
        }
        define(object, "putVariable") { [unowned self] args in
            ruleChapter.chapter.variables[self.arg(args, 0) ?? ""] = self.arg(args, 1)
            return nil
        }
        return object
    }
}

// MARK: - 给 JS 用的元素和响应对象

@objc protocol ElementBoxExports: JSExport {
    func text() -> String
    func ownText() -> String
    func html() -> String
    func outerHtml() -> String
    func attr(_ key: String) -> String
    func hasAttr(_ key: String) -> Bool
    func select(_ css: String) -> JSValue?
    func selectFirst(_ css: String) -> JSValue?
    func children() -> JSValue?
    func child(_ index: Int) -> JSValue?
    func parent() -> JSValue?
    func tagName() -> String
    func hasClass(_ name: String) -> Bool
    func data() -> String
    func remove()
    func getElementsByTag(_ tag: String) -> JSValue?
    func getElementsByClass(_ name: String) -> JSValue?
    func nextElementSibling() -> JSValue?
    func previousElementSibling() -> JSValue?
    func toString() -> String
}

final class ElementBox: NSObject, ElementBoxExports {
    let element: Element

    init(_ element: Element) {
        self.element = element
    }

    func text() -> String { (try? element.text()) ?? "" }
    func ownText() -> String { element.ownText() }
    func html() -> String { (try? element.html()) ?? "" }
    func outerHtml() -> String { (try? element.outerHtml()) ?? "" }
    func attr(_ key: String) -> String { (try? element.attr(key)) ?? "" }
    func hasAttr(_ key: String) -> Bool { element.hasAttr(key) }
    func tagName() -> String { element.tagName() }
    func hasClass(_ name: String) -> Bool { element.hasClass(name) }
    func data() -> String { element.data() }
    func remove() { try? element.remove() }
    func toString() -> String { outerHtml() }

    private func list(_ elements: [Element]) -> JSValue? {
        guard let ctx = JSContext.current() else { return nil }
        let array = JSValue(newArrayIn: ctx)!
        for (i, e) in elements.enumerated() {
            array.setObject(ElementBox(e), atIndexedSubscript: i)
        }
        return ctx.objectForKeyedSubscript("__kgList").call(withArguments: [array])
    }

    private func single(_ element: Element?) -> JSValue? {
        guard let ctx = JSContext.current() else { return nil }
        guard let element else { return JSValue(nullIn: ctx) }
        return JSValue(object: ElementBox(element), in: ctx)
    }

    func select(_ css: String) -> JSValue? { list((try? element.select(css).array()) ?? []) }
    func selectFirst(_ css: String) -> JSValue? { single((try? element.select(css).array())?.first) }
    func children() -> JSValue? { list(element.children().array()) }
    func child(_ index: Int) -> JSValue? {
        let all = element.children().array()
        return single(index >= 0 && index < all.count ? all[index] : nil)
    }
    func parent() -> JSValue? { single(element.parent()) }
    func getElementsByTag(_ tag: String) -> JSValue? { list((try? element.getElementsByTag(tag).array()) ?? []) }
    func getElementsByClass(_ name: String) -> JSValue? { list((try? element.getElementsByClass(name).array()) ?? []) }
    func nextElementSibling() -> JSValue? { single((try? element.nextElementSibling()) ?? nil) }
    func previousElementSibling() -> JSValue? { single((try? element.previousElementSibling()) ?? nil) }
}

/// 网络响应（阅读的 StrResponse）
struct StrResponse {
    var url: String
    var body: String
    var code: Int
    var headers: [String: String]
}

@objc protocol ResponseBoxExports: JSExport {
    func body() -> String
    func url() -> String
    func code() -> Int
    func statusCode() -> Int
    func message() -> String
    func headers() -> [String: String]
    func header(_ name: String) -> String
    func cookies() -> [String: String]
    func toString() -> String
}

final class ResponseBox: NSObject, ResponseBoxExports {
    let response: StrResponse

    init(_ response: StrResponse) {
        self.response = response
    }

    func body() -> String { response.body }
    func url() -> String { response.url }
    func code() -> Int { response.code }
    func statusCode() -> Int { response.code }
    func message() -> String { HTTPURLResponse.localizedString(forStatusCode: response.code) }
    func headers() -> [String: String] { response.headers }
    func header(_ name: String) -> String {
        response.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }
    func cookies() -> [String: String] {
        let raw = header("Set-Cookie")
        var out: [String: String] = [:]
        for part in raw.components(separatedBy: ",") {
            let pair = part.components(separatedBy: ";")[0]
            if let eq = pair.firstIndex(of: "=") {
                out[pair[..<eq].trimmingCharacters(in: .whitespaces)] = String(pair[pair.index(after: eq)...])
            }
        }
        return out
    }
    func toString() -> String { response.body }
}
