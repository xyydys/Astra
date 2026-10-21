import Compression
import Foundation

/// 洛雪音乐（LX Music）里的五个平台标识
enum MusicPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case wy, tx, kw, kg, mg

    var id: String { rawValue }

    var name: String {
        switch self {
        case .wy: return "网易云音乐"
        case .tx: return "QQ 音乐"
        case .kw: return "酷我音乐"
        case .kg: return "酷狗音乐"
        case .mg: return "咪咕音乐"
        }
    }

    var short: String {
        switch self {
        case .wy: return "网易"
        case .tx: return "QQ"
        case .kw: return "酷我"
        case .kg: return "酷狗"
        case .mg: return "咪咕"
        }
    }

    /// 这几个平台的搜索和歌词接口由 App 自己实现（和洛雪音乐一样，音源脚本只负责取播放地址）
    static let searchable: [MusicPlatform] = [.wy, .tx, .kw, .kg]
}

/// 一首歌（搜索结果、播放队列、收藏和历史共用）
struct MusicTrack: Codable, Hashable, Identifiable, Sendable {
    var source: MusicPlatform
    /// 各平台的歌曲 id：网易 id、QQ mid、酷我 rid、酷狗 audio id
    var songmid: String
    var name: String
    var singer: String
    var album: String = ""
    var albumId: String = ""
    /// 秒
    var duration: Double = 0
    var cover: String = ""
    /// 酷狗：文件 hash
    var hash: String = ""
    /// QQ：数字 id、media mid、专辑 mid
    var songId: String = ""
    var strMediaMid: String = ""
    var albumMid: String = ""
    /// 咪咕
    var copyrightId: String = ""
    /// 平台标注的可用音质：128k / 320k / flac / flac24bit
    var qualities: [String] = []
    /// 酷狗每种音质对应的 hash
    var qualityHashes: [String: String] = [:]

    var id: String { source.rawValue + "_" + songmid }

    /// 聚合搜索去重用：歌名 + 歌手，只保留字母和数字（不同平台歌手分隔符不一样）
    var dedupeKey: String {
        func normalize(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }
        return normalize(name) + "|" + normalize(singer)
    }

    var durationText: String {
        guard duration > 0 else { return "" }
        let total = Int(duration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var subtitle: String {
        album.isEmpty ? singer : singer + " · " + album
    }

    /// 传给音源脚本的 musicInfo：洛雪音乐旧版结构（大部分音源按这个写），再附上新版的 id / meta
    var lxMusicInfo: [String: Any] {
        var types: [[String: Any]] = []
        var typesMap: [String: Any] = [:]
        for quality in qualities {
            var item: [String: Any] = ["type": quality, "size": ""]
            if let hash = qualityHashes[quality] { item["hash"] = hash }
            types.append(item)
            var entry: [String: Any] = ["size": ""]
            if let hash = qualityHashes[quality] { entry["hash"] = hash }
            typesMap[quality] = entry
        }
        var info: [String: Any] = [
            "id": id,
            "name": name,
            "singer": singer,
            "source": source.rawValue,
            "songmid": songmid,
            "albumId": albumId,
            "albumName": album,
            "interval": durationText,
            "_interval": Int(duration),
            "img": cover,
            "types": types,
            "_types": typesMap,
            "typeUrl": [String: Any](),
            "lrc": NSNull(),
            "otherSource": NSNull(),
        ]
        var meta: [String: Any] = [
            "songId": source == .tx ? (songId.isEmpty ? songmid : songId) : songmid,
            "albumName": album,
            "picUrl": cover,
            "albumId": albumId,
            "qualitys": types,
            "_qualitys": typesMap,
        ]
        switch source {
        case .kg:
            info["hash"] = hash
            meta["hash"] = hash
        case .tx:
            info["songId"] = songId
            info["strMediaMid"] = strMediaMid
            info["albumMid"] = albumMid
            meta["strMediaMid"] = strMediaMid
            meta["albumMid"] = albumMid
            meta["mid"] = songmid
            meta["qq"] = ["mid": songmid, "songid": songId]
        case .mg:
            info["copyrightId"] = copyrightId
            meta["copyrightId"] = copyrightId
        default:
            break
        }
        info["meta"] = meta
        return info
    }
}

/// 歌词：格式交给 Folia 解析（yrc / krc 是逐字歌词）
struct LyricPayload: Codable, Hashable, Sendable {
    var format: String
    var content: String
    var translation: String = ""

    var isEmpty: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum MusicError: LocalizedError {
    case message(String)
    case noSource
    case unsupported(MusicPlatform)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .noSource: return "还没有导入音源：到「我的 → 音乐 → 音源管理」导入洛雪音乐的自定义音源"
        case .unsupported(let platform): return "当前音源不支持\(platform.name)"
        }
    }
}

// MARK: - zlib

/// zlib（RFC 1950）格式的压缩 / 解压；Apple 的 COMPRESSION_ZLIB 是不带头尾的 raw deflate
enum Zlib {
    static func inflate(_ data: Data) -> Data? {
        var body = data
        if body.count > 2, (Int(body[body.startIndex]) * 256 + Int(body[body.startIndex + 1])) % 31 == 0,
           body[body.startIndex] & 0x0F == 8 {
            body = body.dropFirst(2)
        }
        if let raw = rawInflate(Data(body)) { return raw }
        return rawInflate(Data(data))
    }

    static func rawInflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var capacity = max(data.count * 6, 64 * 1024)
        while capacity <= 64 * 1024 * 1024 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { out in
                data.withUnsafeBytes { input in
                    compression_decode_buffer(
                        out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written == 0 { return nil }
            if written < capacity {
                output.count = written
                return output
            }
            capacity *= 4
        }
        return nil
    }

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]) }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        var result = Data([0x78, 0x9C])
        result.append(output)
        result.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return result
    }
}
