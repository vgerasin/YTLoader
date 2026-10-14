import XCTest
@testable import YTLoaderCore

/// Сквозные проверки с настоящим yt-dlp и локальным HTTP-сервером.
/// Запускаются только при YTL_E2E=1 (в CI после установки yt-dlp и ffmpeg).
final class Collector: EngineDelegate {
    private let lock = NSLock()
    private var _states: [[String: Any]] = []
    private var _notes: [(String, String)] = []
    private var _dups: [[String: Any]] = []

    func engine(push json: String, summary: EngineSummary) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.lock(); _states.append(obj); lock.unlock()
    }
    func engine(notifyTitle: String, body: String, path: String) {
        lock.lock(); _notes.append((notifyTitle, body)); lock.unlock()
    }
    func engine(askDuplicate payload: [String: Any]) {
        lock.lock(); _dups.append(payload); lock.unlock()
    }

    var states: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _states }
    var notes: [(String, String)] { lock.lock(); defer { lock.unlock() }; return _notes }
    var dups: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _dups }
    var last: [String: Any] { states.last ?? [:] }
    var items: [[String: Any]] { last["items"] as? [[String: Any]] ?? [] }
    var history: [[String: Any]] { last["history"] as? [[String: Any]] ?? [] }
}

final class E2ETests: XCTestCase {
    static var server: Process?
    static let port = 8765

    override class func setUp() {
        guard ProcessInfo.processInfo.environment["YTL_E2E"] == "1" else { return }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"]
        p.currentDirectoryURL = fixtures
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        server = p
        Thread.sleep(forTimeInterval: 1.5)
    }

    override class func tearDown() {
        server?.terminate()
    }

    override func setUp() {
        // тесты не должны трогать настоящие настройки и очередь пользователя
        AppPaths.overrideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytl-root-" + UUID().uuidString)
    }

    private func requireE2E() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YTL_E2E"] == "1", "set YTL_E2E=1")
    }

    struct Timeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timeout waiting for: \(what)" }
    }

    /// Ждёт условие, обрабатывая главную очередь (делегат движка получает снимки именно там).
    private func wait(_ what: String, timeout: TimeInterval = 90, _ cond: () -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw Timeout(what: what)
    }

    private func makeEngine(folder: String) throws -> (Engine, Collector) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ytl-root-" + UUID().uuidString)
        AppPaths.overrideRoot = root
        let c = Collector()
        let e = Engine(delegate: c)
        e.start()
        e.handle(path: "/api/settings", body: ["folder": folder, "autoUpdate": false, "onboarded": true,
                                               "language": "en", "notify": true, "cookieBrowser": "none"])
        let tools = Components.detect()
        XCTAssertTrue(tools.hasYtdlp, "yt-dlp must be installed for E2E tests")
        try wait("tools detected") { (c.last["env"] as? [String: Any])?["ytdlp"] as? Bool == true }
        return (e, c)
    }

    private func tempFolder() -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ytl-e2e-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    /// В папке загрузок после завершения — только готовые файлы: ни .part, ни .ytdl, ни обложки, ни скрытой временной папки.
    private func assertOnlyFinished(_ folder: String, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        XCTAssertEqual(names.count, count, "в папке загрузок лишнее: \(names)", file: file, line: line)
        XCTAssertFalse(names.contains { $0.hasPrefix(".") || $0.hasSuffix(".part") || $0.hasSuffix(".ytdl") || $0.hasSuffix(".jpg") },
                       "служебные файлы в папке загрузок: \(names)", file: file, line: line)
    }

    /// Процент каждой загрузки за всё время — не убывает и не прыгает на 100, пока файл качается.
    private func assertProgressSane(_ c: Collector, file: StaticString = #filePath, line: UInt = #line) {
        var lastPct: [String: Int] = [:]
        for st in c.states {
            for it in st["items"] as? [[String: Any]] ?? [] where (it["status"] as? String) == "downloading" {
                let id = it["id"] as? String ?? ""
                let pct = (it["pct"] as? NSNumber)?.intValue ?? 0
                XCTAssertGreaterThanOrEqual(pct, lastPct[id] ?? 0, "процент уменьшился", file: file, line: line)
                lastPct[id] = pct
            }
        }
    }

    func testPlainFileDownloadWithProgressAndDuplicates() throws {
        try requireE2E()
        let folder = tempFolder()
        let (e, c) = try makeEngine(folder: folder)
        e.handle(path: "/api/settings", body: ["speedLimit": "1M"])
        let url = "http://127.0.0.1:\(E2ETests.port)/sample.mp4"
        e.handle(path: "/api/add", body: ["text": url, "quality": "720p", "audioOnly": false])

        try wait("item shows up") { !c.items.isEmpty }
        try wait("download finished") { c.history.count == 1 && c.items.isEmpty }

        let h = c.history[0]
        let path = h["filepath"] as? String ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "file missing: \(path)")
        XCTAssertTrue(path.hasPrefix(folder))
        XCTAssertGreaterThan((h["total"] as? NSNumber)?.int64Value ?? 0, 10_000)
        XCTAssertFalse((h["dateLabel"] as? String ?? "").isEmpty)

        // по пути прогресс должен был двигаться
        let sawProgress = c.states.contains { st in
            (st["items"] as? [[String: Any]] ?? []).contains { ($0["status"] as? String) == "downloading" }
        }
        XCTAssertTrue(sawProgress, "never saw a downloading state")
        XCTAssertFalse(c.notes.isEmpty, "completion notification expected")
        assertOnlyFinished(folder, count: 1)
        assertProgressSane(c)

        // повторная ссылка: приложение спрашивает про дубль
        e.handle(path: "/api/add", body: ["text": url])
        try wait("duplicate question") { !c.dups.isEmpty }
        let dup = (c.dups[0]["duplicates"] as? [[String: Any]])?.first
        XCTAssertEqual(dup?["path"] as? String, path)

        // а с force — качает снова
        var forced = c.dups[0]
        forced["force"] = true
        e.handle(path: "/api/add", body: forced)
        try wait("second download") { c.history.count == 2 }
        e.shutdown()
    }

    func testMissingFileBecomesFriendlyError() throws {
        try requireE2E()
        let (e, c) = try makeEngine(folder: tempFolder())
        e.handle(path: "/api/add", body: ["text": "http://127.0.0.1:\(E2ETests.port)/nope.mp4"])
        try wait("error state") { c.items.first?["status"] as? String == "error" }
        let item = c.items[0]
        XCTAssertFalse((item["error"] as? String ?? "").isEmpty)
        XCTAssertFalse((item["rawError"] as? String ?? "").isEmpty)

        // «Убрать» удаляет карточку
        e.handle(path: "/api/cancel", body: ["id": item["id"] as Any])
        try wait("removed") { c.items.isEmpty }
        e.shutdown()
    }

    func testPauseResumeAndCancel() throws {
        try requireE2E()
        let (e, c) = try makeEngine(folder: tempFolder())
        e.handle(path: "/api/settings", body: ["speedLimit": "1M"])
        let url = "http://127.0.0.1:\(E2ETests.port)/sample.mp4"
        e.handle(path: "/api/add", body: ["text": url, "deferMode": "manual"])
        try wait("deferred") { c.items.first?["status"] as? String == "deferred" }
        let id = c.items[0]["id"] as? String ?? ""
        XCTAssertEqual(c.items[0]["deferMode"] as? String, "manual")

        e.handle(path: "/api/resume", body: ["id": id])
        try wait("downloading or done") { c.items.first?["status"] as? String == "downloading" || !c.history.isEmpty }
        e.handle(path: "/api/pause", body: ["id": id])
        try wait("paused or done") { c.items.first?["status"] as? String == "paused" || !c.history.isEmpty }
        if c.items.first?["status"] as? String == "paused" {
            e.handle(path: "/api/resume", body: ["id": id])
            try wait("finished after resume") { !c.history.isEmpty && c.items.isEmpty }
        }
        e.shutdown()
    }

    func testHLSTwoStreamsMergeNeedsFFmpeg() throws {
        try requireE2E()
        let tools = Components.detect()
        try XCTSkipUnless(tools.hasFFmpeg, "ffmpeg is not installed")
        let folder = tempFolder()
        let (e, c) = try makeEngine(folder: folder)
        e.handle(path: "/api/settings", body: ["speedLimit": "", "maxParallel": 1])
        e.handle(path: "/api/add", body: ["text": "http://127.0.0.1:\(E2ETests.port)/hls/master.m3u8", "quality": "1080p"])
        try wait("resolved with streams") {
            (c.items.first?["streams"] as? [[String: Any]])?.count == 2 || !c.history.isEmpty
        }
        try wait("done") { c.history.count == 1 && c.items.isEmpty }
        let path = c.history[0]["filepath"] as? String ?? ""
        XCTAssertTrue(path.hasSuffix(".mp4"), path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        assertOnlyFinished(folder, count: 1)
        assertProgressSane(c)
        e.shutdown()
    }

    /// Сохранённый разбор берётся только свежим и только при обычных настройках (не после отказа 403).
    func testSavedInfoIsUsedOnlyWhenFresh() throws {
        let e = Engine(delegate: Collector())
        let it = Item(url: "https://example.com/v", title: "v")
        e.saveInfo(it, line: "{\"id\":\"x\"}")
        XCTAssertEqual(e.usableInfo(it), e.infoPath(for: it.id))

        it.forbiddenRetries = 1
        XCTAssertEqual(e.usableInfo(it), "", "после отказа 403 ссылки в разборе могли протухнуть")
        it.forbiddenRetries = 0
        it.fallback = 1
        XCTAssertEqual(e.usableInfo(it), "", "запасные клиенты YouTube требуют нового разбора")
        it.fallback = 0

        let old = Date().addingTimeInterval(-Engine.infoMaxAge - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: e.infoPath(for: it.id))
        XCTAssertEqual(e.usableInfo(it), "", "устаревший разбор не используется")

        e.removeInfo(it)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.infoPath(for: it.id)))
        XCTAssertEqual(it.infoFile, "")
    }

    /// Страница ролика разбирается один раз: загрузка берёт сохранённый результат разбора, а не разбирает всё заново
    /// (на YouTube второй разбор — это ещё десятки секунд). После завершения служебный файл убирается.
    func testDownloadReusesResolvedInfo() throws {
        try requireE2E()
        let tools = Components.detect()
        try XCTSkipUnless(tools.hasFFmpeg, "ffmpeg is not installed")
        let folder = tempFolder()
        let (e, c) = try makeEngine(folder: folder)
        e.handle(path: "/api/settings", body: ["speedLimit": "", "maxParallel": 1])
        e.handle(path: "/api/add", body: ["text": "http://127.0.0.1:\(E2ETests.port)/hls/master.m3u8", "quality": "1080p"])
        try wait("done") { c.history.count == 1 && c.items.isEmpty }
        let path = c.history[0]["filepath"] as? String ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        assertOnlyFinished(folder, count: 1)
        let log = Log.shared.tail()
        XCTAssertTrue(log.contains("reuse-info=true"), "загрузка не использовала сохранённый разбор:\n\(log)")
        let cache = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.cacheDir.path)) ?? []
        XCTAssertFalse(cache.contains { $0.hasPrefix("info-") }, "остался служебный файл разбора: \(cache)")
        e.shutdown()
    }

    /// Полоса действительно живёт во время загрузки: проценты и скачанные байты растут между 0 и 100,
    /// карточка не уходит раньше времени в «склеиваю». (В 5.0 и 5.1 весь прогресс терялся в первую секунду.)
    func testProgressIsLiveWhileDownloading() throws {
        try requireE2E()
        let folder = tempFolder()
        let (e, c) = try makeEngine(folder: folder)
        e.handle(path: "/api/settings", body: ["speedLimit": "100K"])
        e.handle(path: "/api/add", body: ["text": "http://127.0.0.1:\(E2ETests.port)/sample.mp4", "quality": "720p"])
        try wait("finished") { c.history.count == 1 && c.items.isEmpty }

        var mid: [(pct: Int, bytes: Int64)] = []
        var earlyMerge = false
        for st in c.states {
            for it in st["items"] as? [[String: Any]] ?? [] where (it["status"] as? String) == "downloading" {
                let pct = (it["pct"] as? NSNumber)?.intValue ?? 0
                let bytes = (it["downloaded"] as? NSNumber)?.int64Value ?? 0
                if (it["stage"] as? String) == "merge", pct < 100 { earlyMerge = true }
                if pct > 0 && pct < 100 && bytes > 0 { mid.append((pct, bytes)) }
            }
        }
        XCTAssertGreaterThanOrEqual(mid.count, 3, "прогресс по ходу загрузки не виден: \(mid)")
        XCTAssertEqual(mid.map { $0.bytes }, mid.map { $0.bytes }.sorted(), "скачанные байты должны расти")
        XCTAssertFalse(earlyMerge, "карточка ушла в «склеиваю» до конца загрузки")
        e.shutdown()
    }

    /// Отмена: недокачанное и обложка удаляются, в папке загрузок ничего не остаётся.
    func testCancelLeavesNoTraceInDownloads() throws {
        try requireE2E()
        let folder = tempFolder()
        let (e, c) = try makeEngine(folder: folder)
        e.handle(path: "/api/settings", body: ["speedLimit": "100K"])
        e.handle(path: "/api/add", body: ["text": "http://127.0.0.1:\(E2ETests.port)/sample.mp4"])
        try wait("downloading") { c.items.first?["status"] as? String == "downloading" }
        let id = c.items[0]["id"] as? String ?? ""
        // недокачанные части лежат в скрытой папке, а не рядом с будущим файлом
        let temp = (folder as NSString).appendingPathComponent(".ytloader-tmp/" + id)
        try wait("temp dir with partial data") { FileManager.default.fileExists(atPath: temp) }
        let visible = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { !$0.hasPrefix(".") } ?? []
        XCTAssertTrue(visible.isEmpty, "посреди загрузки в видимой папке: \(visible)")

        e.handle(path: "/api/cancel", body: ["id": id])
        try wait("removed") { c.items.isEmpty }
        try wait("temp dir removed") { (try? FileManager.default.contentsOfDirectory(atPath: folder))?.isEmpty ?? false }
        e.shutdown()
    }

    func testAudioOnlyProducesMP3() throws {
        try requireE2E()
        try XCTSkipUnless(Components.detect().hasFFmpeg, "ffmpeg is not installed")
        let (e, c) = try makeEngine(folder: tempFolder())
        e.handle(path: "/api/add", body: ["text": "http://127.0.0.1:\(E2ETests.port)/sample.mp4", "audioOnly": true])
        try wait("done") { c.history.count == 1 && c.items.isEmpty }
        let path = c.history[0]["filepath"] as? String ?? ""
        XCTAssertTrue(path.hasSuffix(".mp3"), path)
        XCTAssertEqual(c.history[0]["format"] as? String, "mp3")
        e.shutdown()
    }

    func testSectionCut() throws {
        try requireE2E()
        let tools = Components.detect()
        try XCTSkipUnless(tools.hasFFmpeg, "ffmpeg is not installed")
        let (e, c) = try makeEngine(folder: tempFolder())
        // HLS: ffmpeg читает его потоково; простой http.server не умеет Range, а mp4 без него не вырезать
        e.handle(path: "/api/add", body: ["text": "http://127.0.0.1:\(E2ETests.port)/hls/master.m3u8",
                                          "sectionFrom": "00:00:01", "sectionTo": "00:00:03"])
        try wait("done or error") { c.history.count == 1 || c.items.first?["status"] as? String == "error" }
        XCTAssertEqual(c.history.count, 1, "section download failed: \(c.items)")
        let path = c.history.first?["filepath"] as? String ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        if tools.hasFFprobe,
           let out = runCapture(tools.ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]),
           let d = Double(out) {
            XCTAssertLessThan(d, 4.5, "фрагмент должен быть короче исходных 8 секунд")
        }
        e.shutdown()
    }

    // MARK: - разбор плейлистов без сети

    func testPlaylistExpansion() throws {
        let c = Collector()
        let e = Engine(delegate: c)
        let json: [String: Any] = [
            "_type": "playlist", "title": "Мой плейлист", "uploader": "Автор",
            "entries": [
                ["id": "aaa", "title": "Первый", "url": "https://www.youtube.com/watch?v=aaa", "duration": 61.0, "ie_key": "Youtube"],
                ["id": "bbb", "title": "[Private video]", "url": "https://www.youtube.com/watch?v=bbb"],
                ["id": "ccc", "title": "Третий", "ie_key": "Youtube", "thumbnails": [["url": "https://i.ytimg.com/vi/ccc/hqdefault.jpg"]]],
                ["_type": "playlist", "title": "Вкладка", "entries": [
                    ["id": "ddd", "title": "Вложенный", "url": "https://www.youtube.com/watch?v=ddd"],
                ]],
            ],
        ]
        e.q.sync {
            let placeholder = Item(url: "https://www.youtube.com/playlist?list=PL1", title: "x")
            placeholder.quality = "720p"
            e.items = [placeholder]
            e.applyResolved(placeholder, json)
            XCTAssertEqual(e.items.count, 3)
            XCTAssertEqual(e.items.map { $0.title }, ["Первый", "Третий", "Вложенный"])
            XCTAssertTrue(e.items.allSatisfy { $0.status == .queued && $0.resolved && $0.quality == "720p" })
            XCTAssertEqual(Set(e.items.map { $0.groupId }).count, 1)
            XCTAssertEqual(e.items[0].groupTotal, 3)
            XCTAssertEqual(e.items[0].groupTitle, "Мой плейлист")
            XCTAssertEqual(e.items[1].url, "https://www.youtube.com/watch?v=ccc")
            XCTAssertTrue(e.items[1].thumb.contains("hqdefault"))
        }
    }

    func testSingleResolvedVideoFillsStreams() throws {
        let e = Engine(delegate: Collector())
        let json: [String: Any] = [
            "_type": "video", "id": "x1", "title": "Видео с VK", "uploader": "Канал", "duration": 100.0,
            "thumbnail": "https://example.org/t.jpg",
            "requested_formats": [
                ["vcodec": "avc1", "acodec": "none", "height": 1080, "filesize": 8_000_000],
                ["vcodec": "none", "acodec": "mp4a", "tbr": 128.0],
            ],
        ]
        e.q.sync {
            let it = Item(url: "https://vk.com/video-1_2", title: "x")
            e.items = [it]
            e.applyResolved(it, json)
            XCTAssertEqual(it.status, .queued)
            XCTAssertEqual(it.title, "Видео с VK")
            XCTAssertEqual(it.channel, "Канал")
            XCTAssertEqual(it.quality, "1080p")
            XCTAssertEqual(it.streams.map { $0.kind }, ["video", "audio"])
            XCTAssertEqual(it.streams[0].total, 8_000_000)
            XCTAssertEqual(it.streams[1].total, 1_600_000)
            XCTAssertEqual(it.total, 9_600_000)
        }
    }

    func testDeferredAfterResolve() throws {
        let e = Engine(delegate: Collector())
        e.q.sync {
            e.netKind = .cellular
            let it = Item(url: "https://rutube.ru/video/abc/", title: "x")
            it.deferMode = "wifi"
            e.items = [it]
            e.applyResolved(it, ["_type": "video", "title": "Rutube"])
            XCTAssertEqual(it.status, .deferred)
            XCTAssertEqual(it.deferMode, "wifi")
            e.netKind = .wifi
            e.tick()
            XCTAssertNotEqual(it.status, .deferred, "Wi-Fi должен будить отложенное")
        }
    }
}
