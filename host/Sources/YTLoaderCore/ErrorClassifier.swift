import Foundation

public enum ErrorKind: String {
    case ffmpeg, jsRuntime, bot, age, geo, live, unavailable
    case privateVideo = "private"
    case cookies, forbidden, unsupported, format, network, disk, generic
}

public struct ClassifiedError {
    public var kind: ErrorKind
    /// Понятное сообщение на языке интерфейса.
    public var message: String
    /// Последние строки ошибки yt-dlp как есть.
    public var raw: String
}

public enum ErrorClassifier {
    /// Правила проверяются по порядку: первое совпадение побеждает.
    /// Порядок важен: «подтвердите возраст» содержит «Sign in», но это не «приватное видео».
    private static let rules: [(ErrorKind, [String])] = [
        (.ffmpeg, ["ffmpeg is not installed", "ffmpeg not found", "ffprobe and ffmpeg not found",
                   "ffprobe not found", "unable to find ffmpeg", "ffmpeg or avconv"]),
        (.cookies, ["cookies database", "failed to decrypt", "could not copy chrome cookie",
                    "could not copy edge cookie", "could not copy brave cookie", "cookies from browser",
                    "unable to read cookie", "binarycookies", "cookiesfrombrowser", "could not find firefox cookies",
                    "could not find chrome cookies", "could not find safari cookies"]),
        (.bot, ["not a bot", "confirm you’re not a bot", "confirm you're not a bot", "captcha"]),
        (.age, ["confirm your age", "age-restricted", "age restricted", "inappropriate for some users",
                "this video may be inappropriate"]),
        (.jsRuntime, ["no supported javascript runtime", "challenge solving failed",
                      "signature solving failed", "only images are available", "js challenge",
                      "javascript runtime"]),
        (.privateVideo, ["private video", "this video is private", "sign in to", "login required",
                    "log in to", "members-only", "members only", "join this channel",
                    "requires authentication", "need to log in", "авториз"]),
        (.geo, ["not available in your country", "geo restricted", "geo-restricted", "geo restriction",
                "blocked it in your country", "not made this video available in your country",
                "available in your region"]),
        (.live, ["live event will begin", "premieres in", "this live event", "is live", "will begin in"]),
        (.unsupported, ["unsupported url"]),
        (.format, ["requested format is not available", "no video formats found", "no formats found"]),
        (.unavailable, ["video unavailable", "has been removed", "this video is not available",
                        "account associated with this video has been terminated", "does not exist",
                        "http error 404", "video is no longer available", "deleted"]),
        (.forbidden, ["http error 403", "403: forbidden", "403 forbidden"]),
        (.disk, ["no space left", "permission denied", "read-only file system", "disk quota",
                 "unable to open for writing", "unable to create directory"]),
        (.network, ["timed out", "connection reset", "connection refused", "connection aborted",
                    "nodename nor servname", "name or service not known", "network is unreachable",
                    "temporary failure in name resolution", "sslerror", "ssl:", "urlerror", "getaddrinfo",
                    "unable to download", "remote end closed", "http error 5", "incompleteread",
                    "no route to host", "the internet connection appears to be offline"]),
    ]

    public static func kind(of text: String) -> ErrorKind {
        let low = text.lowercased()
        for (kind, needles) in rules where needles.contains(where: { low.contains($0) }) {
            return kind
        }
        return .generic
    }

    /// stderr процесса → сообщение. `lines` — строки вывода, ошибки — в конце.
    public static func classify(lines: [String], lang: String) -> ClassifiedError {
        let errorLines = lines.filter { $0.hasPrefix("ERROR") }
        let source = errorLines.isEmpty ? Array(lines.suffix(6)) : Array(errorLines.suffix(3))
        let text = source.joined(separator: "\n")
        let k = kind(of: text)
        var raw = text
        if raw.count > 500 { raw = String(raw.prefix(500)) + "…" }
        return ClassifiedError(kind: k, message: Loc.t(lang, "err." + k.rawValue), raw: raw)
    }
}
