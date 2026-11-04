import Foundation
import NodeMobile

/// 内置的 Node.js（nodejs-mobile）：运行猫影视的插件包（index.js）。
/// 插件包会在本机开一个 HTTP 服务（/config、/spider/<站点>/…），App 通过它搜索、取详情和播放地址。
/// Node 一个进程只能启动一次，插件包更新时用启动脚本的控制接口重新加载
final class CatNode: @unchecked Sendable {
    static let shared = CatNode()

    /// 插件包的服务端口（被占用时插件包会自己往后找）和启动脚本的控制端口
    static let catPort = 50_988
    static let controlPort = 50_987

    private let lock = NSLock()
    private var started = false
    private var exitCode: Int32?

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    /// Node 退出了（插件包出了无法恢复的错）：要重启 App 才能再启动
    var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitCode != nil
    }

    func start(boot: URL, dataDir: URL, packageDir: URL) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        // --security-revert：插件里有的站点要用 RSA PKCS1 v1.5 解密（Node 18.20 起默认禁止）
        let args = [
            "node", "--security-revert=CVE-2023-46809",
            boot.path, dataDir.path, packageDir.path, String(Self.catPort), String(Self.controlPort),
        ]
        let thread = Thread { [weak self] in
            let code = Self.run(args)
            guard let self else { return }
            self.lock.lock()
            self.exitCode = code
            self.lock.unlock()
        }
        thread.name = "astra.node"
        thread.stackSize = 4 << 20
        thread.start()
    }

    /// nodejs-mobile 要求参数放在一块连续内存里（libuv 会就地改写 argv），这块内存一直不释放
    private static func run(_ args: [String]) -> Int32 {
        let total = args.reduce(0) { $0 + $1.utf8.count + 1 }
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: total)
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: args.count + 1)
        var offset = 0
        for (index, arg) in args.enumerated() {
            let bytes = Array(arg.utf8CString)
            for (position, byte) in bytes.enumerated() { buffer[offset + position] = byte }
            argv[index] = buffer + offset
            offset += bytes.count
        }
        argv[args.count] = nil
        return node_start(Int32(args.count), argv)
    }

    // MARK: 启动脚本

    /// 加载插件包、开控制接口（/status、/logs、/reload），把插件包的日志收集起来
    static let bootScript = #"""
    'use strict';
    const path = require('path');
    const fs = require('fs');
    const http = require('http');
    const [, , dataDir, packageDir, catPort, controlPort] = process.argv;
    fs.mkdirSync(dataDir, { recursive: true });
    process.chdir(dataDir);
    process.env.NODE_PATH = dataDir;
    process.env.CATVOD_DISABLE_AUTOSTART = '1';
    process.env.HOST = '127.0.0.1';
    process.env.PORT = catPort;
    process.env.NODE_ENV = 'production';

    const logs = [];
    let port = 0;
    let state = 'idle';
    let lastError = '';
    let cat = null;

    function text(value) {
      if (typeof value === 'string') return value;
      if (value && value.stack) return value.stack;
      try { return JSON.stringify(value); } catch (e) { return String(value); }
    }
    function note(level, args) {
      const line = '[' + level + '] ' + args.map(text).join(' ');
      const match = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(line);
      if (match) port = Number(match[1]);
      logs.push(line.length > 800 ? line.slice(0, 800) + '…' : line);
      if (logs.length > 400) logs.splice(0, logs.length - 400);
    }
    for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
      const original = (console[level] || console.log).bind(console);
      console[level] = (...args) => { note(level, args); original(...args); };
    }
    process.on('uncaughtException', (error) => note('fatal', [error]));
    process.on('unhandledRejection', (error) => note('fatal', [error]));

    async function load() {
      state = 'loading';
      lastError = '';
      try {
        if (cat && typeof cat.stop === 'function') {
          try { await cat.stop(); } catch (error) { note('warn', ['stop', error]); }
        }
        for (const key of Object.keys(require.cache)) {
          if (key.startsWith(packageDir)) delete require.cache[key];
        }
        const entry = path.join(packageDir, 'index.js');
        if (!fs.existsSync(entry)) { state = 'empty'; return; }
        let config;
        const configFile = path.join(packageDir, 'index.config.js');
        if (fs.existsSync(configFile)) {
          try {
            const loaded = require(configFile);
            config = loaded && (loaded.default || loaded);
          } catch (error) { note('warn', ['index.config.js', error]); }
        }
        port = 0;
        cat = require(entry);
        if (config && typeof config === 'object' && Object.keys(config).length > 0) {
          await cat.start(config);
        } else {
          await cat.start();
        }
        if (!port) port = Number(catPort);
        state = 'running';
      } catch (error) {
        state = 'failed';
        lastError = text(error);
        note('error', ['load', error]);
      }
    }

    http.createServer((req, res) => {
      const send = (body) => {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(body));
      };
      const url = req.url || '';
      if (url.startsWith('/status')) return send({ state, port, error: lastError, node: process.version });
      if (url.startsWith('/logs')) return send({ logs });
      if (url.startsWith('/reload')) { load().then(() => send({ state, port, error: lastError })); return; }
      res.writeHead(404);
      res.end();
    }).listen(Number(controlPort), '127.0.0.1');

    load();
    """#
}

// MARK: - 本机请求

enum CatHTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: config)
    }()

    static func get(_ url: String, timeout: TimeInterval = 10) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw UZError.message("地址无效") }
        let (data, _) = try await session.data(for: URLRequest(url: target, timeoutInterval: timeout))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func post(_ url: String, body: [String: Any], timeout: TimeInterval = 40) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw UZError.message("地址无效") }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status >= 400 {
            let message = RuleValue.string(object["message"]).isEmpty ? RuleValue.string(object["error"]) : RuleValue.string(object["message"])
            throw UZError.message(message.isEmpty ? "插件返回 \(status)" : message)
        }
        return object
    }
}
