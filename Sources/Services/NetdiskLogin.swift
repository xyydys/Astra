import CoreImage
import CryptoKit
import Foundation
import UIKit

/// 网盘扫码登录：夸克 / UC 的官方扫码接口换 Cookie，UC 电视版接口换不限速 Token。
/// 流程参考猫影视 Node.js 源包和 AList 的 quark_uc_tv 驱动，都是网盘自己的接口，登录的是你自己的账号。
enum NetdiskQRLogin {
    enum Kind: String, Identifiable {
        case quark, uc, ucTV
        var id: String { rawValue }

        var title: String {
            switch self {
            case .quark: return "夸克扫码登录"
            case .uc: return "UC 扫码登录"
            case .ucTV: return "UC 不限速（电视版扫码）"
            }
        }

        var appName: String {
            switch self {
            case .quark: return "夸克"
            case .uc, .ucTV: return "UC 浏览器"
            }
        }
    }

    struct Session {
        let kind: Kind
        var requestID = ""
        var token = ""
        /// 二维码内容（链接）：同一台手机上直接打开就能跳到 App 里确认
        var qrContent = ""
        /// 接口直接给的二维码图片（UC 电视版）
        var qrImage: UIImage?
        var deviceID = ""
    }

    enum PollResult {
        case waiting(String)
        case done(String)
    }

    enum LoginError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    // MARK: 常量

    private static let quarkUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    private static let ucUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    private static let ucUT = "Nk15t19U8LJVOz9oEFf1mPhjjQVjufhd5ItiyeRv0%2FSchg%3D%3D"

    /// UC 电视版接口（网盘工具 v40 用同一个 device_id 调 Open API，所以登录也用它）
    private enum TV {
        static let api = "https://open-api-drive.uc.cn"
        static let tokenURL = "http://api.extscreen.com/ucdrive/token"
        static let clientID = "5acf882d27b74502b7040b0c65519aa7"
        static let signKey = "l3srvtd7p42l0d0x1u8d7yc8ye9kki4d"
        static let appVer = "1.6.8"
        static let channel = "UCTVOFFICIALWEB"
        static let deviceID = "07b48aaba8a739356ab8107b5e230ad4"
        static let userAgent = "Mozilla/5.0 (Linux; U; Android 12; zh-cn; V2238A Build/V417IR) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1"
        static var deviceParams: [(String, String)] {
            [
                ("app_ver", appVer), ("device_id", deviceID), ("device_brand", "Xiaomi"), ("platform", "tv"),
                ("device_name", "22081212C"), ("device_model", "22081212C"), ("build_device", "star2qltechn"),
                ("build_product", "22081212C"), ("device_gpu", "Adreno (TM) 640"), ("activity_rect", "{}"), ("channel", channel),
            ]
        }
    }

    static let ucRefreshTokenKey = "UC_RefreshToken"
    static let ucTokenExpiryKey = "UC_TokenExpiry"

    // MARK: 开始

    static func start(_ kind: Kind) async throws -> Session {
        switch kind {
        case .quark:
            let requestID = UUID().uuidString.lowercased()
            let url = "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?pr=ucpro&fr=pc&sys=win32&client_id=386&v=1.2&request_id=\(requestID)"
            let json = try await getJSON(url, headers: ["User-Agent": quarkUA])
            let token = RuleValue.string(((json["data"] as? [String: Any])?["members"] as? [String: Any])?["token"])
            guard !token.isEmpty else { throw LoginError.message("夸克二维码获取失败") }
            let content = "https://su.quark.cn/4_eMHBJ?token=\(token.queryComponentEncoded)&client_id=386&sch=pckk@other_ch&sve=3.1.8&ssb=weblogin&uc_param_str=&uc_biz_str=S:custom%7COPT:SAREA@0%7COPT:IMMERSIVE@1%7COPT:BACK_BTN_STYLE@0"
            return Session(kind: kind, requestID: requestID, token: token, qrContent: content)
        case .uc:
            let requestID = UUID().uuidString.lowercased()
            let url = "https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin?pr=UCBrowser&fr=pc&sys=win32&client_id=529&v=1.2&request_id=\(requestID)"
            let json = try await getJSON(url, headers: ["User-Agent": ucUA])
            let token = RuleValue.string(((json["data"] as? [String: Any])?["members"] as? [String: Any])?["token"])
            guard !token.isEmpty else { throw LoginError.message("UC 二维码获取失败") }
            let content = "https://su.uc.cn/4_fzMj2?token=\(token.queryComponentEncoded)&client_id=529&uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix"
            return Session(kind: kind, requestID: requestID, token: token, qrContent: content)
        case .ucTV:
            let json = try await tvGet("/oauth/authorize", query: [
                ("auth_type", "code"), ("client_id", TV.clientID), ("scope", "netdisk"),
                ("qrcode", "1"), ("qr_width", "460"), ("qr_height", "460"),
            ])
            let queryToken = RuleValue.string(json["query_token"])
            let base64 = RuleValue.string(json["qr_data"]).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            guard !queryToken.isEmpty, let data = Data(base64Encoded: base64), let image = UIImage(data: data) else {
                throw LoginError.message("UC 电视版二维码获取失败：\(RuleValue.string(json["error_info"]))")
            }
            return Session(kind: kind, token: queryToken, qrContent: decodeQR(image) ?? "", qrImage: image, deviceID: TV.deviceID)
        }
    }

    // MARK: 轮询

    @MainActor
    static func poll(_ session: Session) async throws -> PollResult {
        switch session.kind {
        case .quark:
            let url = "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?pr=ucpro&fr=pc&sys=win32&client_id=386&v=1.2&request_id=\(session.requestID)&token=\(session.token.queryComponentEncoded)"
            guard let ticket = try await serviceTicket(url, ua: quarkUA) else { return .waiting("等待在夸克 App 里确认") }
            let login = try await getJSON("https://pan.quark.cn/desktop/account/login?pr=ucpro&fr=pc&sys=win32&st=\(ticket.queryComponentEncoded)", headers: ["User-Agent": quarkUA])
            var cookie = try cookie(fromLogin: login)
            cookie = await refreshed(cookie, url: "https://drive-pc.quark.cn/1/clouddrive/auth/pc/flush?pr=ucpro&fr=pc&sys=win32&ve=3.1.8", ua: quarkUA, referer: "https://pan.quark.cn/")
            UZStore.shared.setEnv("夸克Cookie", cookie)
            return .done("夸克登录成功")
        case .uc:
            let url = "https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken?pr=UCBrowser&fr=pc&sys=win32&client_id=529&v=1.2&request_id=\(session.requestID)&token=\(session.token.queryComponentEncoded)&ve=1.8.5&ut=\(ucUT)"
            guard let ticket = try await serviceTicket(url, ua: ucUA) else { return .waiting("等待在 UC 浏览器里确认") }
            let login = try await getJSON("https://drive.uc.cn/desktop/account/login?pr=UCBrowser&fr=pc&client=uc_desktop&sys=win32&st=\(ticket.queryComponentEncoded)&ve=1.8.5&ut=\(ucUT)", headers: ["User-Agent": ucUA])
            var cookie = try cookie(fromLogin: login)
            cookie = await refreshed(cookie, url: "https://pc-api.uc.cn/1/clouddrive/auth/pc/flush?pr=UCBrowser&fr=pc&sys=win32&ve=1.8.5&ut=\(ucUT)", ua: ucUA, referer: "https://drive.uc.cn/")
            UZStore.shared.setEnv("UCCookie", cookie)
            return .done("UC 登录成功")
        case .ucTV:
            let json = try await tvGet("/oauth/code", query: [
                ("client_id", TV.clientID), ("scope", "netdisk"), ("query_token", session.token),
            ])
            let code = RuleValue.string(json["code"])
            guard RuleValue.string(json["status"]) == "0", !code.isEmpty else { return .waiting("等待在 UC 浏览器里确认") }
            try await exchangeTVToken(["code": code])
            return .done("UC 不限速已开启")
        }
    }

    // MARK: UC 电视版 Token

    /// Token 快过期时用 refresh_token 换新的（播放 UC 资源前调用）
    @MainActor
    static func refreshUCTokenIfNeeded() async {
        let store = UZStore.shared
        let refresh = store.env[ucRefreshTokenKey] ?? ""
        guard !refresh.isEmpty else { return }
        let expiry = Double(store.env[ucTokenExpiryKey] ?? "") ?? 0
        guard Date().timeIntervalSince1970 > expiry - 600 else { return }
        do {
            try await exchangeTVToken(["refresh_token": refresh])
            Diag.log("网盘", "UC 电视版 Token 已续期")
        } catch {
            Diag.log("网盘", "UC 电视版 Token 续期失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func exchangeTVToken(_ extra: [String: String]) async throws {
        let tm = String(Int(Date().timeIntervalSince1970 * 1000))
        var body: [String: String] = ["req_id": md5(TV.deviceID + tm)]
        for (key, value) in TV.deviceParams { body[key] = value }
        for (key, value) in extra { body[key] = value }
        var request = URLRequest(url: URL(string: TV.tokenURL)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(TV.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let payload = json["data"] as? [String: Any] ?? json
        let access = RuleValue.string(payload["access_token"])
        let refresh = RuleValue.string(payload["refresh_token"])
        guard !access.isEmpty, !refresh.isEmpty else {
            throw LoginError.message("UC 电视版 Token 换取失败：\(RuleValue.string(json["message"]))")
        }
        let expires = Double(RuleValue.string(payload["expires_in"])) ?? 3600 * 24
        let store = UZStore.shared
        store.setEnv("UC_Token", access)
        store.setEnv(ucRefreshTokenKey, refresh)
        store.setEnv(ucTokenExpiryKey, String(Int(Date().timeIntervalSince1970 + expires)))
    }

    private static func tvGet(_ path: String, query: [(String, String)]) async throws -> [String: Any] {
        let tm = String(Int(Date().timeIntervalSince1970 * 1000))
        var items: [(String, String)] = [("req_id", md5(TV.deviceID + tm)), ("access_token", "")]
        items += TV.deviceParams
        items += query
        let queryString = items.map { "\($0.0)=\($0.1.queryComponentEncoded)" }.joined(separator: "&")
        let headers = [
            "User-Agent": TV.userAgent,
            "x-pan-tm": tm,
            "x-pan-token": sha256("GET&\(path)&\(tm)&\(TV.signKey)"),
            "x-pan-client-id": TV.clientID,
            "Content-Type": "text/plain;charset=UTF-8",
        ]
        return try await getJSON(TV.api + path + "?" + queryString, headers: headers)
    }

    // MARK: 工具

    private static func serviceTicket(_ url: String, ua: String) async throws -> String? {
        let json = try await getJSON(url, headers: ["User-Agent": ua])
        guard RuleValue.string(json["message"]).contains("ok") else { return nil }
        let ticket = RuleValue.string(((json["data"] as? [String: Any])?["members"] as? [String: Any])?["service_ticket"])
        return ticket.isEmpty ? nil : ticket
    }

    private static func cookie(fromLogin json: [String: Any]) throws -> String {
        let data = json["data"] as? [String: Any] ?? [:]
        let pus = RuleValue.string(data["pus"])
        let uid = RuleValue.string(data["uid"])
        guard !pus.isEmpty, !uid.isEmpty else {
            throw LoginError.message("登录换 Cookie 失败：\(RuleValue.string(json["message"]))")
        }
        return "__pus=\(pus); __uid=\(uid)"
    }

    /// 刷新一次，把返回的 __puus 等 Cookie 合并进来
    private static func refreshed(_ cookie: String, url: String, ua: String, referer: String) async -> String {
        guard let target = URL(string: url) else { return cookie }
        var request = URLRequest(url: target, timeoutInterval: 15)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        guard let (_, response) = try? await URLSession(configuration: config).data(for: request),
              let http = response as? HTTPURLResponse,
              let fields = http.allHeaderFields as? [String: String] else { return cookie }
        var pairs: [(String, String)] = cookie.split(separator: ";").compactMap { part in
            let item = part.trimmingCharacters(in: .whitespaces)
            guard let eq = item.firstIndex(of: "=") else { return nil }
            return (String(item[..<eq]), String(item[item.index(after: eq)...]))
        }
        for new in HTTPCookie.cookies(withResponseHeaderFields: fields, for: target) where !new.value.isEmpty {
            if let index = pairs.firstIndex(where: { $0.0 == new.name }) {
                pairs[index].1 = new.value
            } else {
                pairs.append((new.name, new.value))
            }
        }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static func getJSON(_ url: String, headers: [String: String]) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw LoginError.message("地址无效") }
        var request = URLRequest(url: target, timeoutInterval: 15)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let (data, _) = try await URLSession(configuration: config).data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 从二维码图片里读出内容（UC 电视版只给图片，读出链接后可以在本机直接打开）
    static func decodeQR(_ image: UIImage) -> String? {
        guard let ciImage = CIImage(image: image),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return (detector.features(in: ciImage).first as? CIQRCodeFeature)?.messageString
    }

    static func qrImage(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
