import Foundation

public enum UpdateOutcome {
    case updated(String)
    case upToDate(String)
    case failed(String)
}

struct ComponentError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Поиск, установка и обновление внешних программ: yt-dlp, ffmpeg, ffprobe, deno.
public enum Components {
    public static let installable = ["yt-dlp", "ffmpeg", "ffprobe", "deno"]

    private static var versionCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    #if arch(arm64)
    static let ffArch = "arm64"
    static let denoTriple = "aarch64-apple-darwin"
    #else
    static let ffArch = "amd64"
    static let denoTriple = "x86_64-apple-darwin"
    #endif

    static func downloadURL(for name: String) -> URL? {
        switch name {
        case "yt-dlp":
            return URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")
        case "ffmpeg", "ffprobe":
            return URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(ffArch)/release/\(name).zip")
        case "deno":
            return URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-\(denoTriple).zip")
        default:
            return nil
        }
    }

    // MARK: - поиск

    private static func searchDirs() -> [String] {
        var dirs = [AppPaths.binDir.path]
        if let b = AppPaths.bundledBin { dirs.append(b) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.deno/bin",
                 NSHomeDirectory() + "/.bun/bin", NSHomeDirectory() + "/.local/bin"]
        return dirs
    }

    private static func executable(_ name: String, in dirs: [String]) -> [String] {
        dirs.map { $0 + "/" + name }.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func version(ofYtdlp path: String) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = "\(path)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((attrs?[.size] as? NSNumber) ?? 0)"
        cacheLock.lock()
        if let v = versionCache[stamp] { cacheLock.unlock(); return v }
        cacheLock.unlock()
        guard let out = runCapture(path, ["--version"], timeout: 25),
              let first = out.split(separator: "\n").first else { return nil }
        let v = String(first).trimmingCharacters(in: .whitespaces)
        cacheLock.lock(); versionCache[stamp] = v; cacheLock.unlock()
        return v
    }

    /// Сравнение версий вида 2026.10.01[.123]: положительное — a новее b.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }

    /// Находит всё, что нужно. Для yt-dlp берётся самая свежая версия из найденных.
    public static func detect() -> ToolPaths {
        var t = ToolPaths()
        let dirs = searchDirs()

        var best: (path: String, version: String)?
        for p in executable("yt-dlp", in: dirs) {
            guard let v = version(ofYtdlp: p) else { continue }
            if best == nil || compareVersions(v, best!.version) > 0 { best = (p, v) }
        }
        if let b = best { t.ytdlp = b.path; t.ytdlpVersion = b.version }

        t.ffmpeg = executable("ffmpeg", in: dirs).first ?? ""
        t.ffprobe = executable("ffprobe", in: dirs).first ?? ""

        for kind in ["deno", "node", "bun"] {
            if let p = executable(kind, in: dirs).first { t.jsPath = p; t.jsKind = kind; break }
        }
        return t
    }

    // MARK: - загрузка

    private static func download(_ url: URL) throws -> URL {
        let tmp = AppPaths.cacheDir.appendingPathComponent("dl-" + shortID())
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 900
        let session = URLSession(configuration: cfg)
        let task = session.downloadTask(with: url) { loc, resp, err in
            defer { sem.signal() }
            if let err = err { failure = err; return }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = ComponentError("HTTP \(http.statusCode)")
                return
            }
            guard let loc = loc else { failure = ComponentError("empty response"); return }
            do { try FileManager.default.moveItem(at: loc, to: tmp) } catch { failure = error }
        }
        task.resume()
        sem.wait()
        session.finishTasksAndInvalidate()
        if let f = failure { throw f }
        return tmp
    }

    private static func makeExecutable(_ path: String) {
        chmod(path, 0o755)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-d", "com.apple.quarantine", path]
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    private static func findFile(named name: String, under dir: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in en where u.lastPathComponent == name { return u }
        return nil
    }

    /// Ставит один компонент в ~/Library/Application Support/YTLoader/bin.
    @discardableResult
    public static func install(_ name: String) throws -> String {
        guard let url = downloadURL(for: name) else { throw ComponentError("unknown component \(name)") }
        let fm = FileManager.default
        let target = AppPaths.binDir.appendingPathComponent(name)
        let downloaded = try download(url)
        defer { try? fm.removeItem(at: downloaded) }

        var staged = downloaded
        if name != "yt-dlp" {
            let dir = AppPaths.cacheDir.appendingPathComponent("unzip-" + shortID(), isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-o", "-q", downloaded.path, "-d", dir.path]
            p.standardError = Pipe()
            p.standardOutput = Pipe()
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let found = findFile(named: name, under: dir) else {
                throw ComponentError("unzip failed")
            }
            staged = AppPaths.cacheDir.appendingPathComponent("bin-" + shortID())
            try fm.moveItem(at: found, to: staged)
        }
        makeExecutable(staged.path)

        let check: [String] = name == "ffmpeg" || name == "ffprobe" ? ["-version"] : ["--version"]
        guard runCapture(staged.path, check, timeout: 40) != nil else {
            try? fm.removeItem(at: staged)
            throw ComponentError("\(name) does not start on this Mac")
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staged, to: target)
        Log.shared.write("installed \(name) → \(target.path)")
        return target.path
    }

    // MARK: - обновление yt-dlp

    private static func latestYtdlpTag() -> String? {
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("YTLoader", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        var tag: String?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            if let d = data,
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let t = obj["tag_name"] as? String { tag = t }
        }.resume()
        sem.wait()
        return tag
    }

    /// Скачивает свежий yt-dlp в папку bin. Внутри .app файл не трогаем — это сломало бы подпись.
    public static func updateYtdlp(current: ToolPaths, force: Bool) -> UpdateOutcome {
        let currentVersion = current.ytdlpVersion
        if !force, !currentVersion.isEmpty, let tag = latestYtdlpTag(), compareVersions(currentVersion, tag) >= 0 {
            return .upToDate(currentVersion)
        }
        do {
            try install("yt-dlp")
            let fresh = detect()
            if !force, !currentVersion.isEmpty, compareVersions(fresh.ytdlpVersion, currentVersion) <= 0 {
                return .upToDate(fresh.ytdlpVersion)
            }
            return .updated(fresh.ytdlpVersion)
        } catch {
            Log.shared.write("yt-dlp update failed: \(error)")
            return .failed("\(error)")
        }
    }

    // MARK: - для интерфейса

    public static func envJSON(tools t: ToolPaths, installing: String, window: String, systemLang: String) -> [String: Any] {
        [
            "ytdlp": t.hasYtdlp, "ytdlpVersion": t.ytdlpVersion, "ytdlpPath": t.ytdlp,
            "ffmpeg": t.hasFFmpeg, "ffmpegPath": t.ffmpeg,
            "ffprobe": t.hasFFprobe, "ffprobePath": t.ffprobe,
            "js": t.hasJS, "jsKind": t.jsKind, "jsPath": t.jsPath,
            "installing": installing, "window": window, "systemLang": systemLang,
        ]
    }
}
