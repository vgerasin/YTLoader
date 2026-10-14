import Foundation

/// Где приложение хранит свои файлы.
public enum AppPaths {
    private static let fm = FileManager.default

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// ~/Library/Application Support/YTLoader
    public static var appSupport: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("YTLoader", isDirectory: true))
    }

    /// Сюда ставятся ffmpeg, ffprobe, deno и обновлённый yt-dlp.
    public static var binDir: URL {
        ensure(appSupport.appendingPathComponent("bin", isDirectory: true))
    }

    public static var cacheDir: URL {
        ensure(appSupport.appendingPathComponent("cache", isDirectory: true))
    }

    public static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    public static var queueFile: URL { appSupport.appendingPathComponent("queue.json") }
    public static var historyFile: URL { appSupport.appendingPathComponent("history.json") }

    /// ~/Library/Logs/YTLoader/ytloader.log
    public static var logFile: URL {
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = ensure(lib.appendingPathComponent("Logs/YTLoader", isDirectory: true))
        return dir.appendingPathComponent("ytloader.log")
    }

    public static var defaultDownloadFolder: String {
        NSHomeDirectory() + "/Movies/YTLoader"
    }

    /// Каталог bin внутри самого приложения (там лежит yt-dlp из сборки).
    public static var bundledBin: String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let p = res.appendingPathComponent("bin").path
        return fm.fileExists(atPath: p) ? p : nil
    }
}

/// Журнал в файле. Его же показывает раздел «Диагностика» в настройках.
public final class Log {
    public static let shared = Log()
    private let queue = DispatchQueue(label: "ytloader.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public func write(_ text: String) {
        queue.async {
            let line = self.formatter.string(from: Date()) + "  " + text + "\n"
            let url = AppPaths.logFile
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber, size.intValue > 1_500_000 {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Последние килобайты журнала.
    public func tail(bytes: Int = 40_000) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: AppPaths.logFile) else { return "" }
            let slice = data.count > bytes ? data.suffix(bytes) : data
            return String(decoding: slice, as: UTF8.self)
        }
    }
}
