import XCTest
@testable import YTLoaderCore

final class ModelTests: XCTestCase {
    func testErrorClassification() {
        func kind(_ s: String) -> ErrorKind { ErrorClassifier.kind(of: s) }
        XCTAssertEqual(kind("ERROR: [youtube] abc: Sign in to confirm you’re not a bot"), .bot)
        XCTAssertEqual(kind("ERROR: [youtube] abc: Sign in to confirm your age"), .age)
        XCTAssertEqual(kind("ERROR: [youtube] abc: Private video. Sign in if you've been granted access"), .privateVideo)
        XCTAssertEqual(kind("ERROR: ffmpeg is not installed"), .ffmpeg)
        XCTAssertEqual(kind("ERROR: unable to download video data: HTTP Error 403: Forbidden"), .forbidden)
        XCTAssertEqual(kind("ERROR: [generic] Unsupported URL: https://example.org"), .unsupported)
        XCTAssertEqual(kind("ERROR: [vk] Video unavailable"), .unavailable)
        XCTAssertEqual(kind("ERROR: Requested format is not available"), .format)
        XCTAssertEqual(kind("ERROR: <urlopen error [Errno 8] nodename nor servname provided>"), .network)
        XCTAssertEqual(kind("ERROR: could not find chrome cookies database in /Users/x"), .cookies)
        XCTAssertEqual(kind("something odd"), .generic)
    }

    func testClassifyUsesLanguage() {
        let c = ErrorClassifier.classify(lines: ["[x] y", "ERROR: Video unavailable"], lang: "en")
        XCTAssertEqual(c.kind, .unavailable)
        XCTAssertEqual(c.message, "Video is unavailable or was removed.")
        let ru = ErrorClassifier.classify(lines: ["ERROR: Video unavailable"], lang: "ru")
        XCTAssertEqual(ru.message, "Видео недоступно или удалено.")
    }

    func testEveryErrorKindHasText() {
        for k in [ErrorKind.ffmpeg, .jsRuntime, .bot, .age, .privateVideo, .geo, .live, .unavailable,
                  .cookies, .forbidden, .unsupported, .format, .network, .disk, .generic] {
            for lang in Loc.supported {
                let text = Loc.t(lang, "err." + k.rawValue)
                XCTAssertNotEqual(text, "err." + k.rawValue, "no \(lang) text for \(k)")
            }
        }
    }

    func testSettingsPatch() {
        var s = Settings()
        let changed = s.apply(patch: ["theme": "light", "maxParallel": 4, "wifiOnly": true,
                                      "speedLimit": "5M", "unknown": 1])
        XCTAssertEqual(Set(changed), ["theme", "maxParallel", "wifiOnly", "speedLimit"])
        XCTAssertEqual(s.theme, "light")
        XCTAssertEqual(s.maxParallel, 4)
        s.apply(patch: ["maxParallel": 5, "theme": "purple"])
        XCTAssertEqual(s.maxParallel, 2, "недопустимое значение возвращается к умолчанию")
        XCTAssertEqual(s.theme, "dark")
    }

    func testSettingsDecodeIsTolerant() throws {
        let json = #"{"theme":"light","maxParallel":"oops","extra":1,"notify":false}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.theme, "light")
        XCTAssertEqual(s.maxParallel, 2)
        XCTAssertFalse(s.notify)
        XCTAssertTrue(s.autoResume)
    }

    func testSettingsUIKeys() {
        let keys = Set(Settings().uiJSON.keys)
        for k in ["folder", "defaultQuality", "maxParallel", "speedLimit", "organize", "codec", "cookieBrowser",
                  "filenameTemplate", "subtitles", "subsEmbed", "chapters", "sponsorblock", "wifiOnly",
                  "autoResume", "clipboardWatch", "autoUpdate", "notify", "dockBadge", "menuBar", "theme",
                  "density", "accent", "language", "onboarded"] {
            XCTAssertTrue(keys.contains(k), "settings.\(k) missing")
        }
    }

    func testItemUIJSONShapeAndRoundTrip() throws {
        let it = Item(url: "https://rutube.ru/video/abc/", title: "Тест")
        it.status = .downloading
        it.streams = [StreamInfo(kind: "video", total: 10, done: 5, active: true, estimated: false)]
        it.speed = .nan
        it.groupId = "g1"; it.groupTitle = "Плейлист"; it.groupTotal = 3
        let ui = it.uiJSON()
        for k in ["id", "url", "title", "channel", "thumb", "duration", "status", "stage", "pct", "total",
                  "downloaded", "speed", "eta", "quality", "format", "streams", "error", "rawError",
                  "noCookies", "deferMode", "deferTime", "filepath", "added", "groupId", "groupTitle", "groupTotal"] {
            XCTAssertNotNil(ui[k], "item.\(k) missing")
        }
        XCTAssertEqual(ui["speed"] as? Double, 0, "NaN не должен попасть в JSON")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(ui))

        let data = try JSONEncoder().encode([it])
        let back = Store.loadArray(Item.self, from: {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytl-\(UUID().uuidString).json")
            try? data.write(to: url)
            return url
        }())
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].title, "Тест")
        XCTAssertEqual(back[0].groupId, "g1")
    }

    func testStoreSkipsBrokenItems() throws {
        let json = #"[{"id":"a","url":"https://x.y/1","title":"ok"},{"bad":true},{"id":"b","url":"https://x.y/2"}]"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytl-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        let items = Store.loadArray(Item.self, from: url)
        XCTAssertEqual(items.map { $0.id }, ["a", "b"])
    }

    func testLocResolve() {
        XCTAssertEqual(Loc.resolve("de"), "de")
        XCTAssertEqual(Loc.resolve("auto", system: ["fr-FR"]), "fr")
        XCTAssertEqual(Loc.resolve("auto", system: ["ja-JP"]), "en")
        XCTAssertEqual(Loc.t("ru", "Added: {n}", ["n": "3"]), "Добавлено: 3")
    }

    func testVersionCompare() {
        XCTAssertGreaterThan(Components.compareVersions("2026.10.01", "2026.09.30"), 0)
        XCTAssertLessThan(Components.compareVersions("2026.01.01", "2026.01.01.123"), 0)
        XCTAssertEqual(Components.compareVersions("2026.10.01", "2026.10.01"), 0)
    }

    func testNextOccurrence() {
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let later = String(format: "%02d:%02d", ((comps.hour ?? 0) + 1) % 24, comps.minute ?? 0)
        let d = Engine.nextOccurrence(of: later, now: now)
        XCTAssertNotNil(d)
        XCTAssertGreaterThan(d!, now)
        XCTAssertLessThanOrEqual(d!.timeIntervalSince(now), 24 * 3600 + 1)
        XCTAssertNil(Engine.nextOccurrence(of: "25:99"))
    }

    func testDefaultCodecIsH264ForQuickTime() throws {
        XCTAssertEqual(Settings().codec, "h264")
        // старый файл настроек без поля schema: «any» был значением по умолчанию — меняем на H.264 один раз
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"codec":"any","theme":"light"}"#.utf8))
        XCTAssertEqual(old.codec, "h264")
        XCTAssertEqual(old.theme, "light")
        XCTAssertEqual(old.schema, 2)
        // после миграции выбор пользователя уважается
        let saved = try JSONDecoder().decode(Settings.self, from: Data(#"{"codec":"any","schema":2}"#.utf8))
        XCTAssertEqual(saved.codec, "any")
        let av1 = try JSONDecoder().decode(Settings.self, from: Data(#"{"codec":"av1"}"#.utf8))
        XCTAssertEqual(av1.codec, "av1")
    }
}
