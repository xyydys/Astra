import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// 我的 → 音乐 → 网易云账号
struct NeteaseAccountView: View {
    @ObservedObject private var account = NeteaseAccount.shared
    @AppStorage(NeteaseAccount.syncLikesKey) private var syncLikes = true
    @AppStorage(NeteaseAccount.accountPlaybackKey) private var accountPlayback = true
    @AppStorage(NeteaseAccount.qualityKey) private var quality = "lossless"
    @State private var working = false
    @State private var message: String?
    @State private var confirmLogout = false

    var body: some View {
        Form {
            if let profile = account.profile {
                Section {
                    NeteaseUserCard(profile: profile)
                    NavigationLink {
                        NeteaseTrackListView(source: .liked)
                    } label: {
                        LabeledRow {
                            Text(account.likedIDs.isEmpty ? "" : "\(account.likedIDs.count) 首")
                        } label: {
                            Label("我喜欢的音乐", systemImage: "heart")
                        }
                    }
                    NavigationLink {
                        NeteasePlaylistsView()
                    } label: {
                        Label("我的歌单", systemImage: "music.note.list")
                    }
                    NavigationLink {
                        NeteaseTrackListView(source: .daily)
                    } label: {
                        Label("每日推荐", systemImage: "calendar")
                    }
                    Button("刷新账号信息", icon: "arrow.clockwise") {
                        run {
                            try await account.refresh()
                            return "已刷新"
                        }
                    }
                    Button("退出登录", role: .destructive) {
                        Haptics.tap()
                        confirmLogout = true
                    }
                    .confirmationDialog("退出网易云账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("退出登录", role: .destructive) {
                            account.logout()
                            message = "已退出登录"
                        }
                    } message: {
                        Text("本地的音乐收藏不受影响。")
                    }
                } header: {
                    Text("账号")
                }

                Section {
                    Button("云端红心 → 本地收藏", icon: "icloud.and.arrow.down") {
                        run {
                            let result = try await account.pullLikes()
                            return "云端共 \(result.total) 首，新加到本地收藏 \(result.added) 首"
                        }
                    }
                    Button("本地收藏 → 云端红心", icon: "icloud.and.arrow.up") {
                        run {
                            let count = try await account.pushLikes()
                            return count == 0 ? "本地收藏里网易云的歌云端都红心了" : "已红心 \(count) 首"
                        }
                    }
                    Toggle(isOn: $syncLikes) {
                        Label("收藏时同步红心", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .selectionFeedback(trigger: syncLikes)
                } header: {
                    Text("收藏同步")
                } footer: {
                    Text("同步只补对方没有的歌，不会删除。只有网易云的歌能同步；打开「收藏时同步红心」后，在音乐页收藏或取消收藏网易云的歌，账号里的红心也跟着变。")
                }

                Section {
                    Toggle(isOn: $accountPlayback) {
                        Label("用账号播放网易云的歌", systemImage: "play.circle")
                    }
                    .selectionFeedback(trigger: accountPlayback)
                    if accountPlayback {
                        Picker(selection: $quality) {
                            ForEach(NeteaseAccount.qualities, id: \.level) { item in
                                Text(item.name).tag(item.level)
                            }
                        } label: {
                            Label("音质", systemImage: "waveform")
                        }
                    }
                } header: {
                    Text("播放")
                } footer: {
                    Text("打开后，网易云的歌先用账号取播放地址（会员歌曲需要账号有会员，音质不够时自动降一档），取不到或只给试听片段时再交给导入的音源。")
                }
            } else {
                NeteaseLoginSections(working: $working, message: $message)
            }
        }
        .toast($message, working: working || account.syncing)
        .navigationTitle("网易云音乐")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run(_ action: @escaping () async throws -> String) {
        Haptics.tap()
        working = true
        message = nil
        Task {
            do {
                message = try await action()
                Haptics.success()
            } catch {
                message = error.localizedDescription
                Haptics.failure()
            }
            working = false
        }
    }
}

// MARK: - 登录

private struct NeteaseLoginSections: View {
    enum Method: String, CaseIterable, Identifiable {
        case sms, qr, cookie
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sms: return "验证码"
            case .qr: return "扫码"
            case .cookie: return "Cookie"
            }
        }
    }

    @Binding var working: Bool
    @Binding var message: String?
    @ObservedObject private var account = NeteaseAccount.shared
    @AppStorage("neteaseLoginMethod") private var method = Method.sms.rawValue
    @AppStorage("neteasePhone") private var phone = ""
    @AppStorage("neteaseCountry") private var country = "86"
    @State private var code = ""
    @State private var countdown = 0
    @State private var cookie = ""
    @State private var qrKey: String?
    @State private var qrImage: UIImage?
    @State private var qrStatus = ""
    @State private var qrExpired = false

    private var current: Method { Method(rawValue: method) ?? .sms }

    var body: some View {
        Section {
            Picker("登录方式", selection: $method) {
                ForEach(Method.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }

        switch current {
        case .sms: smsSection
        case .qr: qrSection
        case .cookie: cookieSection
        }
    }

    // MARK: 验证码

    private var smsSection: some View {
        Section {
            HStack {
                HStack(spacing: 2) {
                    Text("+").foregroundStyle(.secondary)
                    TextField("86", text: $country)
                        .keyboardType(.numberPad)
                        .frame(width: 44)
                }
                Divider()
                TextField("手机号", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
            }
            HStack {
                TextField("验证码", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button { sendCode() } label: {
                    Text(countdown > 0 ? "\(countdown) 秒后重发" : "获取验证码")
                }
                    .disabled(countdown > 0 || phoneDigits.isEmpty || working)
                    .buttonStyle(.borderless)
            }
            Button("登录") {
                let phone = phoneDigits, code = code.trimmingCharacters(in: .whitespaces), country = country
                run {
                    try await NeteaseAPI.login(phone: phone, code: code, country: country)
                    try await account.finishLogin()
                    return "登录成功"
                }
            }
            .disabled(phoneDigits.isEmpty || code.trimmingCharacters(in: .whitespaces).isEmpty || working)
        } header: {
            Text("手机验证码登录")
        } footer: {
            Text("登录信息只保存在这台设备的系统钥匙串里。网易云偶尔会对新设备要求安全验证（提示 8821 之类），遇到时换扫码或 Cookie 登录。")
        }
    }

    private var phoneDigits: String {
        phone.filter(\.isNumber)
    }

    private func sendCode() {
        let phone = phoneDigits, country = country
        run {
            try await NeteaseAPI.sendCode(phone: phone, country: country)
            startCountdown()
            return "验证码已发送"
        }
    }

    private func startCountdown() {
        countdown = 60
        Task {
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdown -= 1
            }
        }
    }

    // MARK: 扫码

    private var qrSection: some View {
        Section {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white)
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                            .opacity(qrExpired ? 0.15 : 1)
                    } else {
                        ProgressView()
                    }
                    if qrExpired {
                        Button("刷新二维码", icon: "arrow.clockwise") { Task { await newQR() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(width: 210, height: 210)
                Text(qrStatus.isEmpty ? "用网易云音乐 App 扫码" : qrStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .task(id: qrKey) { await pollQR() }
            .onAppear {
                if qrKey == nil { Task { await newQR() } }
            }

            Button("保存二维码到相册", icon: "square.and.arrow.down") {
                guard let qrImage else { return }
                UIImageWriteToSavedPhotosAlbum(Self.printable(qrImage), nil, nil, nil)
                Haptics.success()
                message = "已保存到相册"
            }
            .disabled(qrImage == nil || qrExpired)
            Button("打开网易云音乐", icon: "arrow.up.forward.app") {
                Haptics.tap()
                if let url = URL(string: "orpheus://") {
                    UIApplication.shared.open(url) { opened in
                        if !opened { message = "没有安装网易云音乐 App" }
                    }
                }
            }
        } header: {
            Text("扫码登录")
        } footer: {
            Text("用另一台设备上的网易云音乐扫码并确认。只有这一台手机时：先把二维码存到相册，打开网易云音乐 →「扫一扫」→ 右上角相册里选这张图，确认后回到这里。")
        }
    }

    private func newQR() async {
        qrExpired = false
        qrImage = nil
        qrStatus = ""
        do {
            let key = try await NeteaseAPI.qrKey()
            qrImage = Self.qrCode(NeteaseAPI.qrURL(key))
            qrKey = key
        } catch {
            qrStatus = "二维码获取失败：\(error.localizedDescription)"
            qrExpired = true
        }
    }

    /// 每两秒查一次扫码状态（离开这一页时自动停止）
    private func pollQR() async {
        guard let key = qrKey else { return }
        while !Task.isCancelled, qrKey == key, !account.isLoggedIn {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, qrKey == key else { return }
            guard let result = try? await NeteaseAPI.qrCheck(key) else { continue }
            switch result.code {
            case 800:
                qrStatus = "二维码已过期"
                qrExpired = true
                return
            case 801:
                qrStatus = "等待扫码"
            case 802:
                qrStatus = "已扫码，请在网易云音乐里确认登录"
            case 803:
                qrStatus = "登录成功"
                run {
                    try await account.finishLogin()
                    return "登录成功"
                }
                return
            default:
                qrStatus = result.message.isEmpty ? "状态 \(result.code)" : result.message
            }
        }
    }

    static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    /// 存到相册的版本：白底加一圈留白，从相册识别更稳
    static func printable(_ image: UIImage) -> UIImage {
        let margin: CGFloat = image.size.width * 0.12
        let size = CGSize(width: image.size.width + margin * 2, height: image.size.height + margin * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.interpolationQuality = .none
            image.draw(in: CGRect(x: margin, y: margin, width: image.size.width, height: image.size.height))
        }
    }

    // MARK: Cookie

    private var cookieSection: some View {
        Section {
            TextEditor(text: $cookie)
                .font(.footnote.monospaced())
                .frame(minHeight: 90)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("从剪贴板粘贴", icon: "doc.on.clipboard") {
                cookie = UIPasteboard.general.string ?? ""
            }
            Button("登录") {
                let raw = cookie
                run {
                    try await account.login(cookie: raw)
                    cookie = ""
                    return "登录成功"
                }
            }
            .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
        } header: {
            Text("Cookie 登录")
        } footer: {
            Text("在电脑浏览器登录 music.163.com，打开开发者工具 → 应用 / 存储 → Cookie，复制 MUSIC_U 的值（或整段 Cookie）粘贴到这里。")
        }
    }

    private func run(_ action: @escaping () async throws -> String) {
        Haptics.tap()
        working = true
        message = nil
        Task {
            do {
                message = try await action()
                Haptics.success()
            } catch {
                message = error.localizedDescription
                Haptics.failure()
            }
            working = false
        }
    }
}

// MARK: - 账号卡片

struct NeteaseUserCard: View {
    let profile: NeteaseProfile

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if profile.avatarUrl.isEmpty {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                } else {
                    PosterImage(url: profile.avatarUrl + "?param=160y160")
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.nickname)
                        .font(.headline)
                    if profile.vipType > 0 {
                        Text(profile.vipType >= 11 ? "黑胶 VIP" : "VIP")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(Color.red, in: Capsule())
                    }
                }
                Text(profile.signature.isEmpty ? "UID \(profile.userId)" : profile.signature)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 歌单 / 歌曲列表

struct NeteasePlaylistsView: View {
    @ObservedObject private var account = NeteaseAccount.shared
    @State private var playlists: [NeteasePlaylist] = []
    @State private var loading = true
    @State private var error: String?

    private var uid: Int { account.profile?.userId ?? 0 }
    private var created: [NeteasePlaylist] { playlists.filter { $0.creatorId == uid } }
    private var collected: [NeteasePlaylist] { playlists.filter { $0.creatorId != uid } }

    var body: some View {
        List {
            if !created.isEmpty {
                Section("创建的歌单") {
                    ForEach(created) { row($0) }
                }
            }
            if !collected.isEmpty {
                Section("收藏的歌单") {
                    ForEach(collected) { row($0) }
                }
            }
        }
        .overlay {
            if loading, playlists.isEmpty {
                ProgressView()
            } else if let error, playlists.isEmpty {
                EmptyStateView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if playlists.isEmpty {
                EmptyStateView("没有歌单", systemImage: "music.note.list")
            }
        }
        .navigationTitle("我的歌单")
        .navigationBarTitleDisplayMode(.inline)
        .task { if playlists.isEmpty { await load() } }
        .refreshable { await load() }
    }

    private func row(_ playlist: NeteasePlaylist) -> some View {
        NavigationLink {
            NeteaseTrackListView(source: .playlist(playlist))
        } label: {
            HStack(spacing: 12) {
                PosterImage(url: playlist.cover.isEmpty ? "" : playlist.cover + "?param=200y200")
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.specialType == 5 ? "我喜欢的音乐" : playlist.name)
                        .lineLimit(1)
                    Text("\(playlist.trackCount) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        guard uid > 0 else { return }
        loading = true
        do {
            playlists = try await NeteaseAPI.playlists(uid: uid)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct NeteaseTrackListView: View {
    enum Source: Hashable {
        case liked, daily
        case playlist(NeteasePlaylist)

        var title: String {
            switch self {
            case .liked: return "我喜欢的音乐"
            case .daily: return "每日推荐"
            case .playlist(let playlist): return playlist.specialType == 5 ? "我喜欢的音乐" : playlist.name
            }
        }
    }

    let source: Source
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var account = NeteaseAccount.shared
    @State private var tracks: [MusicTrack] = []
    @State private var loading = true
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        List {
            ForEach(tracks) { track in
                Button {
                    player.play(track, in: tracks)
                } label: {
                    MusicTrackRow(track: track, isCurrent: player.current?.id == track.id)
                }
                .buttonStyle(.plain)
                .contextMenu { MusicTrackMenu(track: track) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loading, tracks.isEmpty {
                ProgressView()
            } else if let error, tracks.isEmpty {
                EmptyStateView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if tracks.isEmpty {
                EmptyStateView("没有歌曲", systemImage: "music.note")
            }
        }
        .toast($message)
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !tracks.isEmpty {
                    Menu {
                        Button("全部加到本地收藏", icon: "heart") {
                            let added = MusicLibrary.shared.mergeFavorites(tracks)
                            Haptics.success()
                            message = added == 0 ? "都已经在本地收藏里了" : "新加到本地收藏 \(added) 首"
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    Button("全部播放", icon: "play.fill") {
                        if let first = tracks.first { player.play(first, in: tracks) }
                    }
                }
            }
        }
        .task { if tracks.isEmpty { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        do {
            switch source {
            case .liked:
                guard let uid = account.profile?.userId else { throw NeteaseError.needLogin }
                tracks = try await NeteaseAPI.songs(NeteaseAPI.likedIDs(uid: uid))
            case .daily:
                tracks = try await NeteaseAPI.dailySongs()
            case .playlist(let playlist):
                tracks = try await NeteaseAPI.playlistTracks(playlist.id)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
