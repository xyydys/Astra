import Foundation
import SwiftData

@Model
final class FavoriteItem {
    @Attribute(.unique) var subjectID: Int
    var name: String = ""
    var nameCN: String = ""
    var image: String = ""
    var score: Double = 0
    var addedAt: Date = Date()

    init(subject: BangumiSubject) {
        subjectID = subject.id
        name = subject.name
        nameCN = subject.nameCN
        image = subject.image
        score = subject.score
        addedAt = Date()
    }

    var title: String { nameCN.isEmpty ? name : nameCN }

    var subject: BangumiSubject {
        BangumiSubject(
            id: subjectID, name: name, nameCN: nameCN, image: image, thumb: image,
            score: score, rank: 0, airDate: "", summary: "", tags: [], episodes: 0
        )
    }
}

/// 每部番只保留最后一次观看位置
@Model
final class WatchRecord {
    @Attribute(.unique) var subjectID: Int
    var title: String = ""
    var name: String = ""
    var image: String = ""
    var ruleName: String = ""
    var sourceURL: String = ""
    var sourceTitle: String = ""
    var roadIndex: Int = 0
    var episodeIndex: Int = 0
    var episodeName: String = ""
    var position: Double = 0
    var duration: Double = 0
    var updatedAt: Date = Date()
    /// 采集站片源：接口地址和影片 id（Kazumi 规则片源时为空）
    var cmsAPI: String = ""
    var vodID: String = ""
    /// "comic" 表示漫画阅读记录：episodeIndex 是第几话，position / duration 是第几页 / 总页数
    var kind: String = ""

    var isComic: Bool { kind == "comic" }
    /// "novel"：小说阅读记录，episodeIndex 是第几章，position / duration 是章内字符位置 / 章节长度
    var isNovel: Bool { kind == "novel" }

    init(subjectID: Int) {
        self.subjectID = subjectID
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var playRequest: PlayRequest {
        PlayRequest(
            subjectID: subjectID, title: title, name: name, image: image,
            ruleName: ruleName, sourceURL: sourceURL, sourceTitle: sourceTitle,
            roadIndex: roadIndex, episodeIndex: episodeIndex, position: position,
            cmsAPI: cmsAPI, vodID: vodID
        )
    }

    var subject: BangumiSubject {
        BangumiSubject(
            id: subjectID, name: name, nameCN: title, image: image, thumb: image,
            score: 0, rank: 0, airDate: "", summary: "", tags: [], episodes: 0
        )
    }
}

/// 打开播放页需要的全部信息
struct PlayRequest: Hashable {
    var subjectID: Int
    var title: String
    var name: String
    var image: String
    var ruleName: String
    var sourceURL: String
    var sourceTitle: String
    var roadIndex: Int = 0
    var episodeIndex: Int = 0
    var position: Double = 0
    /// 采集站片源：接口地址和影片 id；为空时是 Kazumi 规则片源（ruleName + sourceURL）
    var cmsAPI: String = ""
    var vodID: String = ""

    var isCMS: Bool { !cmsAPI.isEmpty }
}

extension TimeInterval {
    var clockText: String {
        guard isFinite, self > 0 else { return "00:00" }
        let total = Int(self)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
