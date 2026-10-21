import Foundation

/// 各平台的搜索、歌词和封面接口（参考洛雪音乐 musicSdk 的公开实现，用 Swift 重写）
enum MusicPlatformAPI {
    static let pcUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private static func request(_ url: String, method: String = "GET", headers: [String: String] = [:],
                                body: Data? = nil) async throws -> Data {
        guard let target = URL.lenient(url) else { throw MusicError.message("地址无效") }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue(pcUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw MusicError.message("服务器返回 \(http.statusCode)")
        }
        return data
    }

    private static func json(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .json5Allowed])
    }

    private static func form(_ fields: [String: String]) -> Data {
        Data(fields.map { "\($0.key)=\($0.value.queryComponentEncoded)" }.joined(separator: "&").utf8)
    }

    // MARK: 搜索

    static func search(_ platform: MusicPlatform, keyword: String, page: Int = 1, limit: Int = 30) async throws -> [MusicTrack] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        switch platform {
        case .wy: return try await searchWY(key, page: page, limit: limit)
        case .tx: return try await searchTX(key, page: page, limit: limit)
        case .kw: return try await searchKW(key, page: page, limit: limit)
        case .kg: return try await searchKG(key, page: page, limit: limit)
        case .mg: throw MusicError.message("暂不支持咪咕搜索")
        }
    }

    /// 聚合搜索：几个平台同时搜，按各自的名次交错排列，同名同歌手的只留先出现的一条（平台顺序即优先级）。
    /// 只要有一个平台成功就返回；全部失败时抛出第一个错误。
    static func searchAll(_ platforms: [MusicPlatform], keyword: String, page: Int = 1, limit: Int = 20) async throws -> [MusicTrack] {
        let results = await withTaskGroup(of: (Int, Result<[MusicTrack], Error>).self) { group in
            for (index, platform) in platforms.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await search(platform, keyword: keyword, page: page, limit: limit)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<[MusicTrack], Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let lists = results.compactMap { try? $0.get() }
        if lists.isEmpty {
            for case .failure(let error) in results { throw error }
            return []
        }
        var merged: [MusicTrack] = []
        var seen = Set<String>()
        for rank in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where rank < list.count {
                if seen.insert(list[rank].dedupeKey).inserted { merged.append(list[rank]) }
            }
        }
        return merged
    }

    // MARK: 网易云

    private static let eapiKey = Data("e82ckenh8dichen8".utf8)

    /// 网易云 eapi 参数加密
    static func eapi(_ path: String, _ object: [String: Any]) -> [String: String] {
        let text = (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let digest = EngineCrypto.md5Hex("nobody\(path)use\(text)md5forencrypt")
        let data = "\(path)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        let encrypted = EngineCrypto.symmetric(Data(data.utf8), transformation: "AES/ECB/PKCS5Padding", key: eapiKey, iv: nil, encrypt: true) ?? Data()
        return ["params": EngineCrypto.hex(encrypted).uppercased()]
    }

    private static func eapiRequest(_ endpoint: String, path: String, _ object: [String: Any]) async throws -> [String: Any] {
        let data = try await request(endpoint, method: "POST", headers: [
            "origin": "https://music.163.com",
            "Content-Type": "application/x-www-form-urlencoded",
        ], body: form(eapi(path, object)))
        guard let result = json(data) as? [String: Any] else { throw MusicError.message("网易云返回的数据无法解析") }
        return result
    }

    private static func searchWY(_ key: String, page: Int, limit: Int) async throws -> [MusicTrack] {
        do {
            let body = try await eapiRequest("http://interface.music.163.com/eapi/batch", path: "/api/search/song/list/page", [
                "keyword": key, "needCorrect": "1", "channel": "typing", "offset": limit * (page - 1),
                "scene": "normal", "total": page == 1, "limit": limit,
            ])
            let data = body["data"] as? [String: Any]
            let resources = data?["resources"] as? [[String: Any]] ?? []
            let tracks = resources.compactMap { item -> MusicTrack? in
                let base = item["baseInfo"] as? [String: Any]
                guard let song = base?["simpleSongData"] as? [String: Any] else { return nil }
                return wyTrack(song)
            }
            if !tracks.isEmpty { return tracks }
        } catch {
            // 换个接口再试
        }
        let url = "https://music.163.com/api/cloudsearch/pc?s=\(key.queryComponentEncoded)&type=1&limit=\(limit)&offset=\(limit * (page - 1))"
        let data = try await request(url, headers: ["Referer": "https://music.163.com/"])
        let result = (json(data) as? [String: Any])?["result"] as? [String: Any]
        let songs = result?["songs"] as? [[String: Any]] ?? []
        return songs.compactMap(wyTrack)
    }

    private static func wyTrack(_ song: [String: Any]) -> MusicTrack? {
        let id = RuleValue.string(song["id"])
        guard !id.isEmpty else { return nil }
        let artists = (song["ar"] as? [[String: Any]] ?? song["artists"] as? [[String: Any]] ?? [])
            .map { RuleValue.string($0["name"]) }
        let album = song["al"] as? [String: Any] ?? song["album"] as? [String: Any] ?? [:]
        var qualities: [String] = ["128k"]
        let privilege = song["privilege"] as? [String: Any]
        let maxbr = RuleValue.double(privilege?["maxbr"]) ?? 320000
        if maxbr >= 320000 { qualities.append("320k") }
        if maxbr >= 999000 { qualities.append("flac") }
        if RuleValue.string(privilege?["maxBrLevel"]) == "hires" { qualities.append("flac24bit") }
        var cover = RuleValue.string(album["picUrl"])
        if !cover.isEmpty, !cover.contains("?") { cover += "?param=500y500" }
        return MusicTrack(
            source: .wy, songmid: id, name: RuleValue.string(song["name"]),
            singer: artists.joined(separator: "、"), album: RuleValue.string(album["name"]),
            albumId: RuleValue.string(album["id"]),
            duration: (RuleValue.double(song["dt"]) ?? RuleValue.double(song["duration"]) ?? 0) / 1000,
            cover: cover.replacingOccurrences(of: "http://", with: "https://"), qualities: qualities
        )
    }

    // MARK: QQ 音乐

    /// QQ 音乐 musics.fcg 的 zzc 签名
    static func zzcSign(_ text: String) -> String {
        let hash = EngineCrypto.hex(EngineCrypto.digest(Data(text.utf8), algorithm: "sha1") ?? Data())
        let chars = Array(hash)
        // 和 JS 版一致：下标 40 超出 40 位哈希时取不到字符，直接跳过
        let pick: ([Int]) -> String = { indexes in String(indexes.filter { $0 < chars.count }.map { chars[$0] }) }
        let part1 = pick([23, 14, 6, 36, 16, 40, 7, 19])
        let part2 = pick([16, 1, 32, 12, 19, 27, 8, 5])
        let scramble: [UInt8] = [89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179]
        var bytes: [UInt8] = []
        for (i, value) in scramble.enumerated() {
            let start = hash.index(hash.startIndex, offsetBy: i * 2)
            let pair = String(hash[start..<hash.index(start, offsetBy: 2)])
            bytes.append(value ^ (UInt8(pair, radix: 16) ?? 0))
        }
        let b64 = Data(bytes).base64EncodedString().filter { !"\\/+=".contains($0) }
        return "zzc\(part1)\(b64)\(part2)".lowercased()
    }

    private static func searchTX(_ key: String, page: Int, limit: Int) async throws -> [MusicTrack] {
        var guid = ""
        for _ in 0..<32 { guid += String(Int.random(in: 0..<16), radix: 16) }
        let searchId = guid.uppercased() + String(format: "%05d", Int.random(in: 0..<100000))
        let payload: [String: Any] = [
            "comm": [
                "_channelid": "0", "_os_version": "6.2.9200-2", "ct": "19", "cv": "2151",
                "guid": "1F70E520B2EAA7D25E11760783C53CA9", "patch": "118", "psrf_access_token_expiresAt": 0,
                "psrf_qqaccess_token": "", "psrf_qqopenid": "", "psrf_qqunionid": "", "tmeAppID": "qqmusic",
                "tmeLoginType": 0, "uin": "0", "wid": "7223299733393904640",
            ],
            "music.search.SearchCgiService": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "grp": 1, "num_per_page": limit, "page_num": page, "query": key,
                    "remoteplace": "txt.newclient.top", "search_type": 0, "searchid": searchId,
                ],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: body, as: UTF8.self)
        let data = try await request("https://u.y.qq.com/cgi-bin/musics.fcg?sign=\(zzcSign(text))", method: "POST",
                                     headers: ["User-Agent": "QQMusic 14090508(android 12)", "Content-Type": "application/json"],
                                     body: body)
        guard let root = json(data) as? [String: Any],
              let req = root["music.search.SearchCgiService"] as? [String: Any] ?? root["req"] as? [String: Any],
              let reqData = req["data"] as? [String: Any] else {
            throw MusicError.message("QQ 音乐搜索失败")
        }
        let list = ((reqData["body"] as? [String: Any])?["song"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        return list.compactMap { item -> MusicTrack? in
            guard let file = item["file"] as? [String: Any], !RuleValue.string(file["media_mid"]).isEmpty else { return nil }
            var qualities: [String] = []
            if (RuleValue.double(file["size_128mp3"]) ?? 0) > 0 { qualities.append("128k") }
            if (RuleValue.double(file["size_320mp3"]) ?? 0) > 0 { qualities.append("320k") }
            if (RuleValue.double(file["size_flac"]) ?? 0) > 0 { qualities.append("flac") }
            if (RuleValue.double(file["size_hires"]) ?? 0) > 0 { qualities.append("flac24bit") }
            let singers = item["singer"] as? [[String: Any]] ?? []
            let album = item["album"] as? [String: Any] ?? [:]
            let albumMid = RuleValue.string(album["mid"])
            var cover = ""
            if !albumMid.isEmpty, albumMid != "空" {
                cover = "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMid).jpg"
            } else if let first = singers.first {
                cover = "https://y.gtimg.cn/music/photo_new/T001R500x500M000\(RuleValue.string(first["mid"])).jpg"
            }
            return MusicTrack(
                source: .tx, songmid: RuleValue.string(item["mid"]), name: RuleValue.string(item["title"]),
                singer: singers.map { RuleValue.string($0["name"]) }.joined(separator: "、"),
                album: RuleValue.string(album["name"]), albumId: albumMid,
                duration: RuleValue.double(item["interval"]) ?? 0, cover: cover,
                songId: RuleValue.string(item["id"]), strMediaMid: RuleValue.string(file["media_mid"]),
                albumMid: albumMid, qualities: qualities
            )
        }
    }

    // MARK: 酷我

    private static func searchKW(_ key: String, page: Int, limit: Int) async throws -> [MusicTrack] {
        let url = "http://search.kuwo.cn/r.s?client=kt&all=\(key.queryComponentEncoded)&pn=\(page - 1)&rn=\(limit)&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1"
        let data = try await request(url)
        guard let root = json(data) as? [String: Any] else { throw MusicError.message("酷我搜索失败") }
        let list = root["abslist"] as? [[String: Any]] ?? []
        let infoRegex = try! NSRegularExpression(pattern: "level:(\\w+),bitrate:(\\d+),format:(\\w+),size:([\\w.]+)")
        return list.compactMap { item -> MusicTrack? in
            let rid = RuleValue.string(item["MUSICRID"]).replacingOccurrences(of: "MUSIC_", with: "")
            guard !rid.isEmpty else { return nil }
            var qualities: [String] = []
            let minfo = RuleValue.string(item["N_MINFO"])
            for match in minfo.regexMatches(infoRegex) {
                let bitrate = (minfo as NSString).substring(with: match.range(at: 2))
                switch bitrate {
                case "128": qualities.append("128k")
                case "320": qualities.append("320k")
                case "2000": qualities.append("flac")
                case "4000": qualities.append("flac24bit")
                default: break
                }
            }
            var cover = RuleValue.string(item["web_albumpic_short"])
            if !cover.isEmpty {
                if cover.hasPrefix("120/") { cover = "500/" + cover.dropFirst(4) }
                cover = "https://img4.kuwo.cn/star/albumcover/" + cover
            }
            return MusicTrack(
                source: .kw, songmid: rid, name: decodeName(RuleValue.string(item["SONGNAME"])),
                singer: decodeName(RuleValue.string(item["ARTIST"])).replacingOccurrences(of: "&", with: "、"),
                album: decodeName(RuleValue.string(item["ALBUM"])), albumId: RuleValue.string(item["ALBUMID"]),
                duration: RuleValue.double(item["DURATION"]) ?? 0, cover: cover,
                qualities: qualities.isEmpty ? ["128k"] : Array(Set(qualities)).sorted(by: qualityOrder)
            )
        }
    }

    // MARK: 酷狗

    private static func searchKG(_ key: String, page: Int, limit: Int) async throws -> [MusicTrack] {
        let url = "http://songsearch.kugou.com/song_search_v2?platform=AndroidFilter&iscorrection=1&keyword=\(key.queryComponentEncoded)&hifiquality=0&pagesize=\(limit)&PrivilegeFilter=0&page=\(page)"
        let data = try await request(url)
        guard let root = json(data) as? [String: Any],
              let lists = (root["data"] as? [String: Any])?["lists"] as? [[String: Any]] else {
            throw MusicError.message("酷狗搜索失败")
        }
        var seen = Set<String>()
        var tracks: [MusicTrack] = []
        func add(_ item: [String: Any]) {
            let key = RuleValue.string(item["Audioid"]) + RuleValue.string(item["FileHash"])
            guard !seen.contains(key) else { return }
            seen.insert(key)
            var qualities: [String] = []
            var hashes: [String: String] = [:]
            for (quality, sizeKey, hashKey) in [("128k", "FileSize", "FileHash"), ("320k", "HQFileSize", "HQFileHash"),
                                                ("flac", "SQFileSize", "SQFileHash"), ("flac24bit", "ResFileSize", "ResFileHash")] {
                if (RuleValue.double(item[sizeKey]) ?? 0) > 0 {
                    qualities.append(quality)
                    hashes[quality] = RuleValue.string(item[hashKey])
                }
            }
            let singers = (item["Singers"] as? [[String: Any]])?.map { RuleValue.string($0["name"]) }.joined(separator: "、")
            let suffix = RuleValue.string(item["Suffix"])
            tracks.append(MusicTrack(
                source: .kg, songmid: RuleValue.string(item["Audioid"]),
                name: decodeName(RuleValue.string(item["OriSongName"]) + (suffix.isEmpty ? "" : " " + suffix)),
                singer: decodeName(singers ?? RuleValue.string(item["SingerName"])),
                album: decodeName(RuleValue.string(item["AlbumName"])), albumId: RuleValue.string(item["AlbumID"]),
                duration: RuleValue.double(item["Duration"]) ?? 0,
                cover: RuleValue.string(item["Image"]).replacingOccurrences(of: "{size}", with: "400"),
                hash: RuleValue.string(item["FileHash"]), qualities: qualities, qualityHashes: hashes
            ))
        }
        for item in lists {
            add(item)
            for child in item["Grp"] as? [[String: Any]] ?? [] { add(child) }
        }
        return tracks
    }

    static func qualityOrder(_ a: String, _ b: String) -> Bool {
        let order = ["128k": 0, "320k": 1, "flac": 2, "flac24bit": 3]
        return (order[a] ?? 9) < (order[b] ?? 9)
    }

    static func decodeName(_ text: String) -> String {
        EngineText.unescapeHTML(text)
    }

    // MARK: 歌词

    static func lyric(_ track: MusicTrack) async throws -> LyricPayload {
        switch track.source {
        case .wy: return try await lyricWY(track)
        case .tx: return try await lyricTX(track)
        case .kw: return try await lyricKW(track)
        case .kg: return try await lyricKG(track)
        case .mg: throw MusicError.message("暂不支持咪咕歌词")
        }
    }

    private static func lyricWY(_ track: MusicTrack) async throws -> LyricPayload {
        let body = try await eapiRequest("https://interface3.music.163.com/eapi/song/lyric/v1", path: "/api/song/lyric/v1", [
            "id": track.songmid, "cp": false, "tv": 0, "lv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0,
        ])
        let lrc = RuleValue.string((body["lrc"] as? [String: Any])?["lyric"])
        let tlrc = RuleValue.string((body["tlyric"] as? [String: Any])?["lyric"])
        let yrc = RuleValue.string((body["yrc"] as? [String: Any])?["lyric"])
        let ytlrc = RuleValue.string((body["ytlrc"] as? [String: Any])?["lyric"])
        if !yrc.isEmpty {
            return LyricPayload(format: "yrc", content: yrc, translation: ytlrc.isEmpty ? tlrc : ytlrc)
        }
        guard !lrc.isEmpty else { throw MusicError.message("没有歌词") }
        return LyricPayload(format: "lrc", content: lrc, translation: tlrc)
    }

    private static func lyricTX(_ track: MusicTrack) async throws -> LyricPayload {
        let url = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(track.songmid)&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq"
        let data = try await request(url, headers: ["Referer": "https://y.qq.com/portal/player.html"])
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // 有时返回 JSONP
        if let open = text.firstIndex(of: "("), text.hasSuffix(")"), !text.hasPrefix("{") {
            text = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        }
        guard let root = json(Data(text.utf8)) as? [String: Any] else { throw MusicError.message("QQ 音乐歌词获取失败") }
        func decode(_ value: Any?) -> String {
            let raw = RuleValue.string(value)
            if raw.isEmpty { return "" }
            if raw.contains("["), raw.contains("]") { return EngineText.unescapeHTML(raw) }
            guard let data = EngineCrypto.base64Decode(raw) else { return "" }
            return EngineText.unescapeHTML(String(decoding: data, as: UTF8.self))
        }
        let lyric = decode(root["lyric"])
        guard !lyric.isEmpty else { throw MusicError.message("没有歌词") }
        return LyricPayload(format: "lrc", content: lyric, translation: decode(root["trans"]))
    }

    private static func lyricKW(_ track: MusicTrack) async throws -> LyricPayload {
        let data = try await request("http://mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=0&rid=\(track.songmid)&encode=utf8")
        let marker = Data("\r\n\r\n".utf8)
        guard String(decoding: data.prefix(10), as: UTF8.self).lowercased() == "tp=content",
              let range = data.range(of: marker),
              let inflated = Zlib.inflate(data[range.upperBound...]) else {
            throw MusicError.message("酷我歌词获取失败")
        }
        let text = String(data: inflated, encoding: .utf8) ?? String(data: inflated, encoding: Net.gb18030) ?? ""
        return splitDuplicateTranslation(EngineText.unescapeHTML(text))
    }

    /// 酷我把翻译放在同一时间戳的下一行
    static func splitDuplicateTranslation(_ lrc: String) -> LyricPayload {
        let timeRegex = try! NSRegularExpression(pattern: "^\\[(\\d{1,2}:\\d{1,2}(?:[.:]\\d{1,3})?)\\]")
        var lines: [String] = []
        var translations: [String] = []
        var lastTime: String?
        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = timeRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
                if line.hasPrefix("[") { lines.append(line) }
                continue
            }
            let time = (line as NSString).substring(with: match.range(at: 1))
            if time == lastTime, !lines.isEmpty {
                translations.append(line)
            } else {
                lines.append(line)
                lastTime = time
            }
        }
        // 翻译太少就当成是正常的重复时间戳
        if translations.count < max(3, lines.count / 4) {
            return LyricPayload(format: "lrc", content: lrc)
        }
        return LyricPayload(format: "lrc", content: lines.joined(separator: "\n"), translation: translations.joined(separator: "\n"))
    }

    private static let kgHeaders = [
        "KG-RC": "1",
        "KG-THash": "expand_search_manager.cpp:852736169:451",
        "User-Agent": "KuGou2012-9020-ExpandSearchManager",
    ]
    private static let krcKey: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69]

    private static func lyricKG(_ track: MusicTrack) async throws -> LyricPayload {
        let searchURL = "http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=\(track.name.queryComponentEncoded)&hash=\(track.hash)&timelength=\(Int(track.duration))&lrctxt=1"
        let searchData = try await request(searchURL, headers: kgHeaders)
        guard let candidates = (json(searchData) as? [String: Any])?["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            throw MusicError.message("没有歌词")
        }
        let isKRC = RuleValue.string(first["krctype"]) == "1" && RuleValue.string(first["contenttype"]) != "1"
        let fmt = isKRC ? "krc" : "lrc"
        let downloadURL = "http://lyrics.kugou.com/download?ver=1&client=pc&id=\(RuleValue.string(first["id"]))&accesskey=\(RuleValue.string(first["accesskey"]))&fmt=\(fmt)&charset=utf8"
        let data = try await request(downloadURL, headers: kgHeaders)
        guard let root = json(data) as? [String: Any], let content = EngineCrypto.base64Decode(RuleValue.string(root["content"])) else {
            throw MusicError.message("酷狗歌词获取失败")
        }
        if RuleValue.string(root["fmt"]) == "krc" {
            var bytes = [UInt8](content.dropFirst(4))
            for i in bytes.indices { bytes[i] ^= krcKey[i % 16] }
            guard let inflated = Zlib.inflate(Data(bytes)) else { throw MusicError.message("酷狗歌词解密失败") }
            return LyricPayload(format: "krc", content: String(decoding: inflated, as: UTF8.self))
        }
        return LyricPayload(format: "lrc", content: String(decoding: content, as: UTF8.self))
    }

    // MARK: 封面

    /// 搜索结果里没有封面时再单独查一次
    static func cover(_ track: MusicTrack) async -> String? {
        switch track.source {
        case .kw:
            guard let data = try? await request("http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=\(track.songmid)") else { return nil }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.hasPrefix("http") ? text : nil
        default:
            return nil
        }
    }
}
