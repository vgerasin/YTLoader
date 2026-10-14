import Foundation

/// Где лежат инструменты на этой машине.
public struct ToolPaths: Equatable {
    public var ytdlp: String = ""
    public var ytdlpVersion: String = ""
    public var ffmpeg: String = ""
    public var ffprobe: String = ""
    public var jsPath: String = ""
    public var jsKind: String = ""

    public init() {}

    public var hasYtdlp: Bool { !ytdlp.isEmpty }
    public var hasFFmpeg: Bool { !ffmpeg.isEmpty }
    public var hasFFprobe: Bool { !ffprobe.isEmpty }
    public var hasJS: Bool { !jsPath.isEmpty }

    /// Каталог, в котором лежит ffmpeg (yt-dlp ищет там и ffprobe).
    var ffmpegDir: String {
        ffmpeg.isEmpty ? "" : (ffmpeg as NSString).deletingLastPathComponent
    }
}

/// Что именно качаем: всё, что нужно для строки запуска.
public struct DownloadSpec {
    public var url: String
    public var audioOnly: Bool
    public var quality: String
    public var sectionFrom: String
    public var sectionTo: String
    public var noCookies: Bool
    public var groupTitle: String
    public var printFile: String       // куда yt-dlp запишет итоговый путь
    public var tempDir: String         // где лежат недокачанные части и обложка (скрытая папка)
    public var fallback: Int           // 0 — обычные настройки, 1+ — запасные (после отказа 403)
    /// Результат разбора ссылки (`-J`): если задан, yt-dlp не разбирает страницу заново, а берёт форматы оттуда.
    public var infoFile: String

    public init(url: String, audioOnly: Bool, quality: String, sectionFrom: String = "",
                sectionTo: String = "", noCookies: Bool = false, groupTitle: String = "",
                printFile: String = "", tempDir: String = "", fallback: Int = 0, infoFile: String = "") {
        self.url = url
        self.audioOnly = audioOnly
        self.quality = quality
        self.sectionFrom = sectionFrom
        self.sectionTo = sectionTo
        self.noCookies = noCookies
        self.groupTitle = groupTitle
        self.printFile = printFile
        self.tempDir = tempDir
        self.fallback = fallback
        self.infoFile = infoFile
    }
}

public enum ArgsBuilder {
    /// Шаблон строки прогресса. Поля разделены «|», пустые приходят как NA.
    public static let progressTemplate =
        "download:YTL|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s"
        + "|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"
        + "|%(info.vcodec)s|%(info.acodec)s|%(progress.fragment_index)s|%(progress.fragment_count)s"

    /// Высота для выбранного качества. nil — без ограничения.
    public static func height(for quality: String) -> Int? {
        switch quality {
        case "best", "": return nil
        default:
            let digits = quality.filter { $0.isNumber }
            return Int(digits)
        }
    }

    /// Селектор формата yt-dlp.
    /// `height<=?` пропускает форматы без указанной высоты (так бывает у HLS на VK и Rutube).
    ///
    /// `avoidHLS` (для YouTube): сначала обычные https-форматы, потом всё остальное.
    /// У HLS-форматов («Premium», f616) размер известен только приблизительно, качаются они
    /// сотнями фрагментов и чаще получают отказ 403 посреди загрузки.
    public static func formatSelector(quality: String, codec: String, audioOnly: Bool, canMerge: Bool,
                                      avoidHLS: Bool = false) -> String {
        let plain = avoidHLS ? "[protocol!*=m3u8]" : ""
        if audioOnly {
            return avoidHLS ? "ba\(plain)/bestaudio/best" : "bestaudio/best"
        }
        let cap = height(for: quality).map { "[height<=?\($0)]" } ?? ""
        guard canMerge else {
            // без ffmpeg склеить дорожки нельзя — берём готовый файл
            return avoidHLS ? "b\(cap)\(plain)/b\(cap)/b" : "b\(cap)/b"
        }
        var variants: [String] = []
        switch codec {
        case "h264":
            if avoidHLS { variants.append("bv*[vcodec^=avc1]\(cap)\(plain)+ba[ext=m4a]\(plain)") }
            variants += ["bv*[vcodec^=avc1]\(cap)+ba[ext=m4a]", "bv*[vcodec^=avc1]\(cap)+ba",
                         "bv*\(cap)+ba", "b\(cap)", "b"]
        case "av1":
            if avoidHLS { variants.append("bv*[vcodec^=av01]\(cap)\(plain)+ba\(plain)") }
            variants += ["bv*[vcodec^=av01]\(cap)+ba", "bv*\(cap)+ba", "b\(cap)", "b"]
        default:
            if avoidHLS { variants.append("bv*\(cap)\(plain)+ba\(plain)") }
            variants += ["bv*\(cap)+ba", "b\(cap)", "b"]
        }
        return variants.joined(separator: "/")
    }

    /// Общие для разбора ссылки и для загрузки параметры.
    static func common(_ s: Settings, tools: ToolPaths, noCookies: Bool, url: String, fallback: Int = 0) -> [String] {
        var a = ["--ignore-config", "--no-colors", "--socket-timeout", "30"]
        if Sites.isYouTube(url) {
            // запасной набор клиентов — после того, как обычный получил отказ 403
            let clients = fallback > 0 ? "tv,android_vr,web_safari" : "default,web_embedded"
            a += ["--extractor-args", "youtube:player_client=\(clients)"]
        }
        if s.cookieBrowser != "none", !s.cookieBrowser.isEmpty, !noCookies {
            a += ["--cookies-from-browser", s.cookieBrowser]
        }
        if tools.hasFFmpeg { a += ["--ffmpeg-location", tools.ffmpegDir] }
        if tools.hasJS, !tools.jsKind.isEmpty, tools.jsKind != "deno" {
            a += ["--js-runtimes", "\(tools.jsKind):\(tools.jsPath)"]
        }
        return a
    }

    /// Разбор ссылки: один JSON с названием, превью и форматами.
    public static func resolveArgs(url: String, settings s: Settings, tools: ToolPaths,
                                   audioOnly: Bool, quality: String, noCookies: Bool, fallback: Int = 0) -> [String] {
        var a = common(s, tools: tools, noCookies: noCookies, url: url, fallback: fallback)
        a += ["-J", "--flat-playlist", "--no-warnings", "--playlist-end", "\(maxPlaylist)"]
        if !Sites.looksLikeCollection(url) {
            // «watch?v=…&list=…» — это один ролик, а не весь список
            if let c = URLComponents(string: url), c.queryItems?.contains(where: { $0.name == "v" }) == true {
                a.append("--no-playlist")
            }
        }
        a += ["-f", formatSelector(quality: quality, codec: s.codec, audioOnly: audioOnly, canMerge: tools.hasFFmpeg,
                                   avoidHLS: Sites.isYouTube(url))]
        a.append(url)
        return a
    }

    public static let maxPlaylist = 500

    /// Префикс подпапки для раскладки.
    static func folderPrefix(_ s: Settings, groupTitle: String) -> String {
        switch s.organize {
        case "channel":
            return "%(uploader,channel,extractor)s/"
        case "playlist":
            let clean = sanitizeForTemplate(groupTitle)
            return clean.isEmpty ? "%(playlist_title,uploader,extractor)s/" : clean + "/"
        default:
            return ""
        }
    }

    /// Название папки идёт в шаблон yt-dlp: «%» надо удваивать, «/» убирать.
    static func sanitizeForTemplate(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "%", with: "%%")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix(".") { t.removeFirst() }
        return String(t.prefix(120))
    }

    /// Фрагмент: «*от-до»; пустая граница — начало или конец ролика.
    public static func sectionArg(from: String, to: String) -> String? {
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        if f.isEmpty && t.isEmpty { return nil }
        return "*\(f.isEmpty ? "0" : f)-\(t.isEmpty ? "inf" : t)"
    }

    public static func downloadArgs(_ spec: DownloadSpec, settings s: Settings, tools: ToolPaths) -> [String] {
        let canMerge = tools.hasFFmpeg
        var a = common(s, tools: tools, noCookies: spec.noCookies, url: spec.url, fallback: spec.fallback)
        a += [
            "--newline", "--progress", "--progress-delta", "0.5",
            "--progress-template", progressTemplate,
            "--no-playlist", "--no-mtime",
            "--fragment-retries", "10", "--retries", "5",
            "--concurrent-fragments", "4",
            "-P", s.folder,
            "-o", folderPrefix(s, groupTitle: spec.groupTitle) + s.filenameTemplate,
        ]
        if !spec.tempDir.isEmpty {
            // части файла, фрагменты и обложка — в скрытую папку; в загрузки попадает только готовый файл
            a += ["-P", "temp:" + spec.tempDir]
        }
        if !spec.printFile.isEmpty {
            a += ["--print-to-file", "after_move:%(filepath)s", spec.printFile]
        }

        a += ["-f", formatSelector(quality: spec.quality, codec: s.codec, audioOnly: spec.audioOnly, canMerge: canMerge,
                                   avoidHLS: Sites.isYouTube(spec.url))]
        if spec.audioOnly {
            a += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
        } else if canMerge {
            a += ["--merge-output-format", "mp4"]
        }

        if !s.speedLimit.isEmpty { a += ["--limit-rate", s.speedLimit] }

        if let section = sectionArg(from: spec.sectionFrom, to: spec.sectionTo), canMerge {
            a += ["--download-sections", section]
        }

        if canMerge {
            a += ["--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg"]
            if s.chapters && !spec.audioOnly { a.append("--embed-chapters") }
            if s.sponsorblock && Sites.isYouTube(spec.url) && tools.hasFFprobe {
                a += ["--sponsorblock-remove", "sponsor,selfpromo,interaction"]
            }
        }

        if s.subtitles != "none" && !spec.audioOnly {
            a += ["--write-subs"]
            if s.subtitles == "all" {
                a += ["--sub-langs", "all,-live_chat"]
            } else {
                a += ["--write-auto-subs", "--sub-langs", s.subtitles]
            }
            if canMerge {
                if s.subsEmbed { a.append("--embed-subs") }
                else { a += ["--convert-subs", "srt"] }
            }
        }

        if spec.infoFile.isEmpty {
            a.append(spec.url)
        } else {
            // разбор страницы уже сделан при добавлении ссылки — второй раз он занимает те же секунды
            a += ["--load-info-json", spec.infoFile]
        }
        return a
    }

    /// Окружение для процессов: наши каталоги впереди, чтобы нашёлся deno/ffmpeg.
    public static func environment(tools: ToolPaths) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var dirs: [String] = []
        for p in [tools.jsPath, tools.ffmpeg, tools.ytdlp] where !p.isEmpty {
            dirs.append((p as NSString).deletingLastPathComponent)
        }
        dirs.append(AppPaths.binDir.path)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let unique = dirs.filter { seen.insert($0).inserted }
        env["PATH"] = unique.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }
}
