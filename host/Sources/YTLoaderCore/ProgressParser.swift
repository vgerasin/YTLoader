import Foundation

/// Строка прогресса по шаблону из ArgsBuilder.progressTemplate.
public struct ProgressLine: Equatable {
    public var status: String          // downloading | finished | error
    public var downloaded: Int64
    public var total: Int64?           // точный размер
    public var estimate: Int64?        // оценка yt-dlp (HLS/DASH)
    public var speed: Double?
    public var eta: Double?
    public var vcodec: String
    public var acodec: String
    public var fragIndex: Int?
    public var fragCount: Int?

    /// Тип текущей дорожки по кодекам.
    public var kind: String {
        let v = vcodec.lowercased()
        let a = acodec.lowercased()
        let noVideo = v == "none"
        let hasAudio = !(a == "none" || a == "na" || a.isEmpty)
        if noVideo && hasAudio { return "audio" }
        return "video"
    }

    public var knownTotal: Int64? {
        if let t = total, t > 0 { return t }
        if let e = estimate, e > 0 { return e }
        return nil
    }
}

/// Что означает одна строка вывода yt-dlp.
public enum LineEvent: Equatable {
    case progress(ProgressLine)
    case destination(String)
    case merging(String)
    case postprocess(String)
    case alreadyDownloaded(String)
    case error(String)
    case other
}

public enum ProgressParser {
    private static func num(_ s: Substring) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "NA" || t == "None" { return nil }
        return Double(t)
    }

    private static func int(_ s: Substring) -> Int64? {
        guard let d = num(s), d.isFinite, d >= 0, d < 9e18 else { return nil }
        return Int64(d)
    }

    public static func parse(_ line: String) -> LineEvent {
        if line.hasPrefix("YTL|") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count >= 9 else { return .other }
            let p = ProgressLine(
                status: String(f[1]),
                downloaded: int(f[2]) ?? 0,
                total: int(f[3]),
                estimate: int(f[4]),
                speed: num(f[5]),
                eta: num(f[6]),
                vcodec: String(f[7]),
                acodec: String(f[8]),
                fragIndex: f.count > 9 ? int(f[9]).map { Int($0) } : nil,
                fragCount: f.count > 10 ? int(f[10]).map { Int($0) } : nil)
            return .progress(p)
        }

        if line.hasPrefix("[download] Destination: ") {
            return .destination(String(line.dropFirst("[download] Destination: ".count)))
        }
        if line.hasPrefix("[download] "), line.hasSuffix(" has already been downloaded") {
            let mid = line.dropFirst("[download] ".count).dropLast(" has already been downloaded".count)
            return .alreadyDownloaded(String(mid))
        }
        if line.hasPrefix("[Merger] Merging formats into ") {
            return .merging(unquote(String(line.dropFirst("[Merger] Merging formats into ".count))))
        }
        if line.hasPrefix("[ExtractAudio] Destination: ") {
            return .postprocess(String(line.dropFirst("[ExtractAudio] Destination: ".count)))
        }
        for tag in ["[VideoConvertor]", "[VideoRemuxer]", "[EmbedSubtitle]", "[Metadata]", "[ThumbnailsConvertor]",
                    "[EmbedThumbnail]", "[SponsorBlock]", "[ModifyChapters]", "[FixupM3u8]", "[FixupM4a]",
                    "[FixupStretched]", "[FixupTimestamp]", "[FFmpegExtractAudio]", "[MoveFiles]", "[SubtitlesConvertor]"]
        where line.hasPrefix(tag) {
            return .postprocess("")
        }
        if line.hasPrefix("ERROR:") {
            return .error(String(line.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces))
        }
        return .other
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
        return t
    }
}

/// Складывает построчный прогресс в общую картину: сколько всего, сколько
/// скачано, какая дорожка идёт сейчас.
public struct ProgressTracker {
    public var streams: [StreamInfo]
    var idx = 0
    var lastDownloaded: Int64 = 0
    var predicted: Bool

    public init(streams: [StreamInfo] = []) {
        self.streams = streams
        self.predicted = !streams.isEmpty
    }

    public struct Snapshot: Equatable {
        public var downloaded: Int64
        public var total: Int64
        public var pct: Int
        public var speed: Double
        public var eta: Double
        public var stage: String
    }

    public mutating func update(_ p: ProgressLine) -> Snapshot {
        let kind = p.kind
        if streams.isEmpty { streams.append(StreamInfo(kind: kind)) }

        // Если дорожка сменилась или счётчик байт пошёл заново — это уже следующий файл.
        if p.status == "downloading" {
            let kindChanged = streams[idx].kind != kind
            let restarted = lastDownloaded > 0 && p.downloaded + 1_000_000 < lastDownloaded
            if kindChanged || restarted {
                if let next = streams.indices.first(where: { $0 > idx && streams[$0].kind == kind }) {
                    finishCurrent()
                    idx = next
                } else if !predicted || restarted || kindChanged {
                    finishCurrent()
                    streams.append(StreamInfo(kind: kind))
                    idx = streams.count - 1
                }
            }
        }

        var cur = streams[idx]
        cur.active = p.status == "downloading"
        if let t = p.knownTotal {
            cur.total = max(t, p.downloaded)
            cur.estimated = p.total == nil || (p.total ?? 0) <= 0
        } else if cur.total < p.downloaded {
            cur.total = p.downloaded
        }
        if cur.total == 0, let fc = p.fragCount, fc > 0, let fi = p.fragIndex, fi > 0 {
            // размер неизвестен, но фрагменты считаются — оценим по ним позже
            cur.estimated = true
        }
        cur.done = p.downloaded
        streams[idx] = cur
        lastDownloaded = p.downloaded

        if p.status == "finished" {
            finishCurrent()
            if idx + 1 < streams.count { idx += 1; lastDownloaded = 0 }
        }
        return snapshot(p)
    }

    private mutating func finishCurrent() {
        var s = streams[idx]
        s.active = false
        if s.total < s.done { s.total = s.done }
        s.done = s.total
        s.estimated = false
        streams[idx] = s
    }

    /// Все дорожки скачаны — полоса заполняется целиком.
    public mutating func complete() {
        for i in streams.indices {
            streams[i].active = false
            streams[i].done = max(streams[i].total, streams[i].done)
            streams[i].total = streams[i].done
            streams[i].estimated = false
        }
    }

    private func snapshot(_ p: ProgressLine) -> Snapshot {
        let done = streams.reduce(Int64(0)) { $0 + $1.done }
        var total = streams.reduce(Int64(0)) { $0 + max($1.total, $1.done) }

        // Для HLS/DASH общий размер неизвестен: оцениваем по номеру фрагмента.
        var pct: Int
        if total > 0 && done > 0 && (p.knownTotal != nil || streams.count > 1) {
            pct = Int(min(100, done * 100 / max(total, 1)))
        } else if let fi = p.fragIndex, let fc = p.fragCount, fc > 0 {
            pct = min(100, fi * 100 / fc)
            if total == 0 { total = done }
        } else {
            pct = 0
        }
        if p.status == "downloading" && pct >= 100 { pct = 99 }

        let speed = p.speed ?? 0
        var eta = p.eta ?? 0
        if speed > 1, total > done { eta = Double(total - done) / speed }
        return Snapshot(downloaded: done, total: total, pct: pct, speed: speed, eta: eta,
                        stage: streams[idx].kind)
    }
}
