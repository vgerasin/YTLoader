import Foundation

public enum ItemStatus: String, Codable {
    case downloading, resolving, queued, paused, error, deferred
}

public enum NetKind: String {
    case wifi, ethernet, cellular, none
}

/// Один участок полосы прогресса — по дорожке (видео, звук).
public struct StreamInfo: Codable, Equatable {
    public var kind: String          // "video" | "audio"
    public var total: Int64
    public var done: Int64
    public var active: Bool
    public var estimated: Bool

    public init(kind: String, total: Int64 = 0, done: Int64 = 0, active: Bool = false, estimated: Bool = true) {
        self.kind = kind
        self.total = total
        self.done = done
        self.active = active
        self.estimated = estimated
    }

    var json: [String: Any] {
        ["kind": kind, "total": total, "done": done, "active": active, "estimated": estimated]
    }
}

/// Загрузка в очереди. Класс, потому что движок меняет её по месту.
public final class Item: Codable {
    public var id: String
    public var url: String
    public var title: String
    public var channel: String = ""
    public var thumb: String = ""
    public var duration: Double = 0
    public var status: ItemStatus = .resolving
    public var stage: String = "video"           // video | audio | merge | convert
    public var pct: Int = 0
    public var total: Int64 = 0
    public var downloaded: Int64 = 0
    public var speed: Double = 0
    public var eta: Double = 0
    public var quality: String = "1080p"
    public var format: String = "mp4"            // mp4 | mp3
    public var streams: [StreamInfo] = []
    public var error: String = ""
    public var rawError: String = ""
    public var errorKind: String = ""
    public var noCookies: Bool = false
    public var groupId: String = ""
    public var groupTitle: String = ""
    public var groupTotal: Int = 0
    public var deferMode: String = ""            // "" | wifi | time | manual
    public var deferTime: String = ""            // HH:mm для режима time
    public var deferAt: Double = 0               // момент запуска для режима time
    public var autoDeferred: Bool = false        // отложено самим приложением (мобильная сеть)
    public var filepath: String = ""
    public var added: Double = Date().timeIntervalSince1970
    public var audioOnly: Bool = false
    public var sectionFrom: String = ""
    public var sectionTo: String = ""
    public var site: String = ""
    public var key: String = ""                  // ключ для поиска дублей
    public var isEntry: Bool = false             // элемент плейлиста: метаданные уже есть
    public var attempts: Int = 0
    public var updateRetried: Bool = false
    public var tempFiles: [String] = []
    public var resolved: Bool = false            // метаданные уже получены
    var notBefore: Double = 0                    // не запускать раньше этого момента (повтор после сбоя сети)
    var fallback: Int = 0                        // 0 — обычные настройки, 1 — запасные клиенты YouTube
    var infoFile: String = ""                    // сохранённый результат разбора для этой загрузки (не пишется на диск)
    var forbiddenRetries: Int = 0                // сколько раз уже повторяли после отказа 403

    public init(id: String = shortID(), url: String, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, channel, thumb, duration, status, stage, pct, total, downloaded
        case quality, format, streams, error, rawError, errorKind, noCookies
        case groupId, groupTitle, groupTotal, deferMode, deferTime, deferAt, autoDeferred
        case filepath, added, audioOnly, sectionFrom, sectionTo, site, key, isEntry, attempts
        case updateRetried, tempFiles, resolved
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? url
        func get<T: Decodable>(_ key: CodingKeys, _ def: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? def
        }
        channel = get(.channel, "")
        thumb = get(.thumb, "")
        duration = get(.duration, 0)
        status = get(.status, ItemStatus.queued)
        stage = get(.stage, "video")
        pct = get(.pct, 0)
        total = get(.total, 0)
        downloaded = get(.downloaded, 0)
        speed = 0
        eta = 0
        quality = get(.quality, "1080p")
        format = get(.format, "mp4")
        streams = get(.streams, [])
        error = get(.error, "")
        rawError = get(.rawError, "")
        errorKind = get(.errorKind, "")
        noCookies = get(.noCookies, false)
        groupId = get(.groupId, "")
        groupTitle = get(.groupTitle, "")
        groupTotal = get(.groupTotal, 0)
        deferMode = get(.deferMode, "")
        deferTime = get(.deferTime, "")
        deferAt = get(.deferAt, 0)
        autoDeferred = get(.autoDeferred, false)
        filepath = get(.filepath, "")
        added = get(.added, Date().timeIntervalSince1970)
        audioOnly = get(.audioOnly, false)
        sectionFrom = get(.sectionFrom, "")
        sectionTo = get(.sectionTo, "")
        site = get(.site, "")
        key = get(.key, "")
        isEntry = get(.isEntry, false)
        attempts = get(.attempts, 0)
        updateRetried = get(.updateRetried, false)
        tempFiles = get(.tempFiles, [])
        resolved = get(.resolved, false)
    }

    /// То, что видит интерфейс.
    public func uiJSON() -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "url": url, "title": title, "channel": channel, "thumb": thumb,
            "duration": jsonNum(duration), "status": status.rawValue, "stage": stage,
            "pct": pct, "total": total, "downloaded": downloaded,
            "speed": jsonNum(speed), "eta": jsonNum(eta),
            "quality": quality, "format": format,
            "streams": streams.map { $0.json },
            "error": error, "rawError": rawError, "noCookies": noCookies,
            "deferMode": deferMode, "deferTime": deferTime, "filepath": filepath,
            "added": added, "site": site,
        ]
        if !groupId.isEmpty {
            d["groupId"] = groupId
            d["groupTitle"] = groupTitle
            d["groupTotal"] = groupTotal
        }
        return d
    }
}

/// Запись в истории: то, что уже скачано.
public struct HistoryEntry: Codable {
    public var id: String
    public var url: String
    public var title: String
    public var channel: String
    public var thumb: String
    public var duration: Double
    public var quality: String
    public var format: String
    public var filepath: String
    public var total: Int64
    public var finished: Double
    public var key: String
    public var site: String

    public init(id: String, url: String, title: String, channel: String, thumb: String,
                duration: Double, quality: String, format: String, filepath: String,
                total: Int64, finished: Double, key: String, site: String) {
        self.id = id; self.url = url; self.title = title; self.channel = channel
        self.thumb = thumb; self.duration = duration; self.quality = quality
        self.format = format; self.filepath = filepath; self.total = total
        self.finished = finished; self.key = key; self.site = site
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, channel, thumb, duration, quality, format, filepath, total, finished, key, site
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? shortID()
        url = try c.decode(String.self, forKey: .url)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? url
        channel = (try? c.decodeIfPresent(String.self, forKey: .channel)) ?? ""
        thumb = (try? c.decodeIfPresent(String.self, forKey: .thumb)) ?? ""
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0
        quality = (try? c.decodeIfPresent(String.self, forKey: .quality)) ?? ""
        format = (try? c.decodeIfPresent(String.self, forKey: .format)) ?? "mp4"
        filepath = (try? c.decodeIfPresent(String.self, forKey: .filepath)) ?? ""
        total = (try? c.decodeIfPresent(Int64.self, forKey: .total)) ?? 0
        finished = (try? c.decodeIfPresent(Double.self, forKey: .finished)) ?? 0
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        site = (try? c.decodeIfPresent(String.self, forKey: .site)) ?? ""
    }

    public func uiJSON(lang: String) -> [String: Any] {
        [
            "id": id, "url": url, "title": title, "channel": channel, "thumb": thumb,
            "duration": jsonNum(duration), "status": "done", "quality": quality, "format": format,
            "filepath": filepath, "total": total, "pct": 100,
            "dateLabel": Loc.dateLabel(Date(timeIntervalSince1970: finished), lang: lang),
            "site": site,
        ]
    }
}
