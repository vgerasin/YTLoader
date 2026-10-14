import Foundation

/// Сайт, который мы узнаём по адресу. Скачивает всё равно yt-dlp —
/// список нужен, чтобы предлагать ссылки из буфера обмена, подписывать
/// карточки и находить дубли.
public struct Site {
    public let name: String
    public let hosts: [String]      // совпадение по окончанию домена
}

public enum Sites {
    public static let known: [Site] = [
        Site(name: "YouTube", hosts: ["youtube.com", "youtu.be", "youtube-nocookie.com"]),
        Site(name: "Vimeo", hosts: ["vimeo.com"]),
        Site(name: "VK", hosts: ["vk.com", "vk.ru", "vkvideo.ru", "vk.cc"]),
        Site(name: "Rutube", hosts: ["rutube.ru"]),
        Site(name: "Dzen", hosts: ["dzen.ru", "zen.yandex.ru"]),
        Site(name: "OK", hosts: ["ok.ru"]),
        Site(name: "Dailymotion", hosts: ["dailymotion.com", "dai.ly"]),
        Site(name: "Twitch", hosts: ["twitch.tv"]),
        Site(name: "TikTok", hosts: ["tiktok.com"]),
        Site(name: "Instagram", hosts: ["instagram.com"]),
        Site(name: "Facebook", hosts: ["facebook.com", "fb.watch"]),
        Site(name: "X", hosts: ["x.com", "twitter.com"]),
        Site(name: "Bilibili", hosts: ["bilibili.com", "b23.tv"]),
        Site(name: "SoundCloud", hosts: ["soundcloud.com"]),
        Site(name: "Bandcamp", hosts: ["bandcamp.com"]),
        Site(name: "Reddit", hosts: ["reddit.com", "redd.it"]),
        Site(name: "Rumble", hosts: ["rumble.com"]),
        Site(name: "Kick", hosts: ["kick.com"]),
        Site(name: "Streamable", hosts: ["streamable.com"]),
        Site(name: "Coub", hosts: ["coub.com"]),
        Site(name: "Odysee", hosts: ["odysee.com"]),
        Site(name: "Niconico", hosts: ["nicovideo.jp"]),
        Site(name: "Pinterest", hosts: ["pinterest.com", "pin.it"]),
        Site(name: "Telegram", hosts: ["t.me"]),
    ]

    /// Все http(s)-ссылки из текста: по одной в строке, через пробел, внутри абзаца.
    public static func extractURLs(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "https?://[^\\s<>\"'`]+", options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            // хвостовая пунктуация чаще относится к предложению, а не к ссылке
            while let last = s.last, ".,;:!?)]}»”’".contains(last) { s.removeLast() }
            if s.hasSuffix("(") { s.removeLast() }
            guard URL(string: s)?.host != nil else { continue }
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    public static func host(of url: String) -> String {
        guard let h = URL(string: url)?.host?.lowercased() else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public static func site(for url: String) -> Site? {
        let h = host(of: url)
        guard !h.isEmpty else { return nil }
        for s in known {
            for d in s.hosts where h == d || h.hasSuffix("." + d) { return s }
        }
        return nil
    }

    public static func isYouTube(_ url: String) -> Bool { site(for: url)?.name == "YouTube" }

    /// Подпись для карточки: имя известного сайта или домен.
    public static func label(for url: String) -> String {
        site(for: url)?.name ?? host(of: url)
    }

    /// Ссылка выглядит как страница видео на известном сайте (для подсказки из буфера).
    public static func isLikelyMedia(_ url: String) -> Bool {
        guard let site = site(for: url), let u = URL(string: url) else { return false }
        let path = u.path
        if path.isEmpty || path == "/" { return false }
        if site.name == "YouTube" {
            let c = URLComponents(url: u, resolvingAgainstBaseURL: false)
            let hasV = c?.queryItems?.contains { $0.name == "v" } ?? false
            let hasList = c?.queryItems?.contains { $0.name == "list" } ?? false
            let h = host(of: url)
            if h == "youtu.be" { return true }
            return hasV || hasList || path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
                || path.hasPrefix("/embed/") || path.hasPrefix("/@") || path.hasPrefix("/channel/")
                || path.hasPrefix("/playlist")
        }
        return true
    }

    /// Ключ для поиска повторов: один и тот же ролик по разным ссылкам.
    public static func videoKey(_ url: String) -> String {
        guard let u = URL(string: url), let rawHost = u.host?.lowercased() else { return "url:" + url }
        let h = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let path = u.path
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        func q(_ name: String) -> String? { comps?.queryItems?.first { $0.name == name }?.value }
        let parts = path.split(separator: "/").map(String.init)

        switch site(for: url)?.name {
        case "YouTube":
            if h == "youtu.be", let id = parts.first { return "yt:" + id }
            if let v = q("v"), !v.isEmpty { return "yt:" + v }
            if let i = parts.firstIndex(where: { ["shorts", "live", "embed", "v"].contains($0) }), i + 1 < parts.count {
                return "yt:" + parts[i + 1]
            }
            if let list = q("list") { return "ytlist:" + list }
            return "url:" + h + path
        case "Vimeo":
            if let id = parts.last(where: { Int($0) != nil }) { return "vimeo:" + id }
        case "VK":
            let pattern = "video(-?\\d+_\\d+)"
            let hay = path + "?" + (u.query ?? "")
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: hay, range: NSRange(location: 0, length: (hay as NSString).length)),
               m.numberOfRanges > 1 {
                return "vk:" + (hay as NSString).substring(with: m.range(at: 1))
            }
        case "Rutube":
            if let i = parts.firstIndex(of: "video"), i + 1 < parts.count { return "rutube:" + parts[i + 1] }
        default:
            break
        }
        return "url:" + h + path + (u.query.map { "?" + $0 } ?? "")
    }

    /// Адрес — страница плейлиста/канала целиком, а не одного ролика?
    public static func looksLikeCollection(_ url: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        let path = u.path
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        let hasV = comps?.queryItems?.contains { $0.name == "v" } ?? false
        if isYouTube(url) {
            if path.hasPrefix("/playlist") { return true }
            if hasV { return false }
            return path.hasPrefix("/@") || path.hasPrefix("/channel/") || path.hasPrefix("/c/") || path.hasPrefix("/user/")
        }
        return false
    }
}
