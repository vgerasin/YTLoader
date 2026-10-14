import Foundation

/// Быстрый предпросмотр: название, автор и обложка берутся из oEmbed сайта за долю секунды,
/// пока yt-dlp ещё разбирает ссылку (на YouTube это занимает секунды).
public enum Preview {
    public struct Info: Equatable {
        public var title: String
        public var author: String
        public var thumb: String
    }

    /// Адрес oEmbed для одиночного ролика YouTube или Vimeo; для остальных сайтов и списков — nil.
    public static func oembedURL(for url: String) -> URL? {
        guard let site = Sites.site(for: url), !Sites.looksLikeCollection(url),
              Sites.isLikelyMedia(url) else { return nil }
        var base: String
        switch site.name {
        case "YouTube": base = "https://www.youtube.com/oembed"
        case "Vimeo": base = "https://vimeo.com/api/oembed.json"
        default: return nil
        }
        guard var c = URLComponents(string: base) else { return nil }
        c.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "format", value: "json")]
        return c.url
    }

    public static func parse(_ data: Data) -> Info? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let title = obj["title"] as? String, !title.isEmpty else { return nil }
        var thumb = (obj["thumbnail_url"] as? String) ?? ""
        // у YouTube hqdefault — картинка 4:3 с чёрными полосами; mqdefault — чистые 16:9
        if thumb.contains("i.ytimg.com/vi/") { thumb = thumb.replacingOccurrences(of: "/hqdefault.", with: "/mqdefault.") }
        if !thumb.hasPrefix("http") { thumb = "" }
        return Info(title: title, author: (obj["author_name"] as? String) ?? "", thumb: thumb)
    }
}

extension Engine {
    /// Подставляет название и обложку, не дожидаясь yt-dlp. Ошибки молча игнорируются:
    /// полный разбор всё равно заполнит карточку.
    func fetchPreview(_ it: Item) {
        guard let endpoint = Preview.oembedURL(for: it.url) else { return }
        let id = it.id
        let started = Date()
        var req = URLRequest(url: endpoint, timeoutInterval: 8)
        req.setValue("YTLoader", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self, let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let info = Preview.parse(data) else { return }
            self.q.async {
                guard let it = self.item(id), !it.resolved, it.status == .resolving || it.status == .downloading else { return }
                it.title = info.title
                if !info.author.isEmpty { it.channel = info.author }
                if it.thumb.isEmpty { it.thumb = info.thumb }
                Log.shared.write("preview in \(Job.seconds(Date().timeIntervalSince(started))): \(info.title)")
                self.dirty = true
            }
        }.resume()
    }
}
