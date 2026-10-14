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

    /// Тип текущей дорожки: у аудиоформата видеокодека нет («none»),
    /// а звуковой кодек у HLS часто не указан вовсе («NA»).
    public var kind: String {
        vcodec.lowercased() == "none" ? "audio" : "video"
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
///
/// Главное правило: полоса идёт только вперёд. Оценка размера у HLS/DASH скачет
/// (yt-dlp прикидывает её по первым фрагментам), счётчик байт при повторе фрагмента
/// может уменьшиться — на проценты это влиять не должно. Доля дорожки берётся
/// из номера фрагмента, когда он известен, иначе из байтов; вес дорожки в общей
/// полосе — её размер из разбора ссылки, он не меняется по ходу загрузки.
public struct ProgressTracker {
    public var streams: [StreamInfo]
    var fractions: [Double]
    var weights: [Double]
    var finished: [Bool]
    var idx = 0
    var lastPct = 0
    /// В режиме «только звук» любая дорожка считается звуковой.
    public var forcedKind: String?

    public init(streams: [StreamInfo] = []) {
        self.streams = streams
        fractions = Array(repeating: 0, count: streams.count)
        weights = streams.map { Double(max($0.total, 0)) }
        finished = Array(repeating: false, count: streams.count)
    }

    public struct Snapshot: Equatable {
        public var downloaded: Int64
        public var total: Int64
        public var pct: Int
        public var speed: Double
        public var eta: Double
        public var stage: String
    }

    private mutating func addStream(_ kind: String) {
        streams.append(StreamInfo(kind: kind))
        fractions.append(0)
        weights.append(0)
        finished.append(false)
    }

    public mutating func update(_ p: ProgressLine) -> Snapshot {
        let kind = forcedKind ?? p.kind
        if streams.isEmpty { addStream(kind) }

        // Дорожку определяет только её тип: следующая ещё не законченная того же типа.
        // Просадка счётчика байт — не повод считать дорожку новой.
        if p.status == "downloading", streams[idx].kind != kind || finished[idx] {
            if let next = streams.indices.first(where: { !finished[$0] && streams[$0].kind == kind }) {
                idx = next
            } else {
                addStream(kind)
                idx = streams.count - 1
            }
        }

        var cur = streams[idx]
        cur.active = p.status == "downloading"
        var fraction = fractions[idx]

        if let t = p.total, t > 0 {
            // точный размер
            cur.total = max(t, p.downloaded)
            cur.done = max(cur.done, p.downloaded)
            cur.estimated = false
            fraction = max(fraction, Double(cur.done) / Double(max(cur.total, 1)))
        } else if let fc = p.fragCount, fc > 0, let fi = p.fragIndex, fi > 0 {
            // HLS/DASH: доля — по номеру фрагмента; размер показываем по оценке yt-dlp,
            // но только когда она устоялась, до этого — по разбору ссылки.
            let f = min(1, Double(fi) / Double(fc))
            let stable = fi >= max(5, fc / 20)
            if stable, let e = p.estimate, e > 0 {
                cur.total = max(e, p.downloaded)
            } else if cur.total == 0 {
                cur.total = max(p.estimate ?? 0, p.downloaded)
            }
            cur.estimated = true
            fraction = max(fraction, f)
            cur.done = max(cur.done, Int64(fraction * Double(cur.total)))
        } else if let k = p.knownTotal {
            cur.total = max(k, p.downloaded)
            cur.done = max(cur.done, p.downloaded)
            cur.estimated = true
            fraction = max(fraction, Double(cur.done) / Double(max(cur.total, 1)))
        } else {
            cur.done = max(cur.done, p.downloaded)
            if cur.total < cur.done { cur.total = cur.done }
            if cur.total > 0 { fraction = max(fraction, Double(cur.done) / Double(cur.total)) }
        }
        if cur.total < cur.done { cur.total = cur.done }
        streams[idx] = cur
        fractions[idx] = min(1, fraction)

        if p.status == "finished" { finishCurrent() }
        return snapshot(p)
    }

    private mutating func finishCurrent() {
        var s = streams[idx]
        s.active = false
        if s.total < s.done { s.total = s.done }
        s.done = s.total
        s.estimated = false
        streams[idx] = s
        fractions[idx] = 1
        finished[idx] = true
        if let next = streams.indices.first(where: { !finished[$0] }) { idx = next }
    }

    /// Все дорожки скачаны — полоса заполняется целиком.
    public mutating func complete() {
        for i in streams.indices {
            streams[i].active = false
            streams[i].done = max(streams[i].total, streams[i].done)
            streams[i].total = streams[i].done
            streams[i].estimated = false
            fractions[i] = 1
            finished[i] = true
        }
        lastPct = 100
    }

    private mutating func snapshot(_ p: ProgressLine) -> Snapshot {
        let done = streams.reduce(Int64(0)) { $0 + $1.done }
        let total = streams.reduce(Int64(0)) { $0 + max($1.total, $1.done) }

        var weighted = 0.0, sum = 0.0
        for i in streams.indices {
            let w = weights[i] > 0 ? weights[i] : Double(max(streams[i].total, 1))
            weighted += w * fractions[i]
            sum += w
        }
        var pct = sum > 0 ? Int((weighted / sum * 100).rounded()) : 0
        if p.status == "downloading" && pct >= 100 { pct = 99 }
        pct = max(pct, min(lastPct, 99))
        lastPct = pct

        let speed = p.speed ?? 0
        var eta = p.eta ?? 0
        if speed > 1, total > done { eta = Double(total - done) / speed }
        return Snapshot(downloaded: done, total: total, pct: pct, speed: speed, eta: eta,
                        stage: streams[idx].kind)
    }
}
