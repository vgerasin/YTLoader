import XCTest
@testable import YTLoaderCore

final class ArgsTests: XCTestCase {
    private func tools(ffmpeg: Bool = true) -> ToolPaths {
        var t = ToolPaths()
        t.ytdlp = "/x/yt-dlp"
        t.ytdlpVersion = "2026.01.01"
        if ffmpeg { t.ffmpeg = "/x/ffmpeg"; t.ffprobe = "/x/ffprobe" }
        t.jsPath = "/x/deno"
        t.jsKind = "deno"
        return t
    }

    func testFormatSelector() {
        XCTAssertEqual(ArgsBuilder.formatSelector(quality: "1080p", codec: "any", audioOnly: false, canMerge: true),
                       "bv*[height<=?1080]+ba/b[height<=?1080]/b")
        XCTAssertEqual(ArgsBuilder.formatSelector(quality: "best", codec: "any", audioOnly: false, canMerge: true),
                       "bv*+ba/b/b")
        XCTAssertEqual(ArgsBuilder.formatSelector(quality: "720p", codec: "any", audioOnly: true, canMerge: true),
                       "bestaudio/best")
        XCTAssertEqual(ArgsBuilder.formatSelector(quality: "720p", codec: "any", audioOnly: false, canMerge: false),
                       "b[height<=?720]/b")
        XCTAssertTrue(ArgsBuilder.formatSelector(quality: "1080p", codec: "h264", audioOnly: false, canMerge: true)
            .contains("vcodec^=avc1"))
        XCTAssertTrue(ArgsBuilder.formatSelector(quality: "1080p", codec: "av1", audioOnly: false, canMerge: true)
            .contains("vcodec^=av01"))
    }

    func testSectionArg() {
        XCTAssertNil(ArgsBuilder.sectionArg(from: "", to: ""))
        XCTAssertEqual(ArgsBuilder.sectionArg(from: "00:05:00", to: "00:12:00"), "*00:05:00-00:12:00")
        XCTAssertEqual(ArgsBuilder.sectionArg(from: "", to: "1:00"), "*0-1:00")
        XCTAssertEqual(ArgsBuilder.sectionArg(from: "1:00", to: ""), "*1:00-inf")
    }

    func testDownloadArgsVideo() {
        var s = Settings()
        s.folder = "/tmp/dl"
        s.speedLimit = "5M"
        s.sponsorblock = true
        s.subtitles = "ru,en"
        let spec = DownloadSpec(url: "https://www.youtube.com/watch?v=abc", audioOnly: false,
                                quality: "720p", sectionFrom: "0:10", sectionTo: "0:20",
                                printFile: "/tmp/out.txt")
        let a = ArgsBuilder.downloadArgs(spec, settings: s, tools: tools())
        XCTAssertEqual(a.last, "https://www.youtube.com/watch?v=abc")
        XCTAssertTrue(a.contains("--merge-output-format"))
        XCTAssertTrue(a.contains("--limit-rate"))
        XCTAssertTrue(a.contains("--sponsorblock-remove"))
        XCTAssertTrue(a.contains("--embed-subs"))
        XCTAssertTrue(a.contains("*0:10-0:20"))
        XCTAssertTrue(a.contains("--ffmpeg-location"))
        XCTAssertFalse(a.contains("--cookies-from-browser"))
    }

    func testSponsorBlockOnlyForYouTube() {
        var s = Settings()
        s.sponsorblock = true
        let spec = DownloadSpec(url: "https://vimeo.com/76979871", audioOnly: false, quality: "1080p")
        let a = ArgsBuilder.downloadArgs(spec, settings: s, tools: tools())
        XCTAssertFalse(a.contains("--sponsorblock-remove"))
        XCTAssertFalse(a.contains("--extractor-args"))
    }

    func testAudioAndNoFFmpeg() {
        let s = Settings()
        let audio = DownloadSpec(url: "https://rutube.ru/video/abc/", audioOnly: true, quality: "audio")
        let a = ArgsBuilder.downloadArgs(audio, settings: s, tools: tools())
        XCTAssertTrue(a.contains("-x"))
        XCTAssertTrue(a.contains("mp3"))

        let video = DownloadSpec(url: "https://rutube.ru/video/abc/", audioOnly: false, quality: "1080p")
        let b = ArgsBuilder.downloadArgs(video, settings: s, tools: tools(ffmpeg: false))
        XCTAssertFalse(b.contains("--merge-output-format"))
        XCTAssertFalse(b.contains("--embed-thumbnail"))
    }

    func testCookiesAndOrganize() {
        var s = Settings()
        s.cookieBrowser = "chrome"
        s.organize = "playlist"
        let spec = DownloadSpec(url: "https://vk.com/video-1_2", audioOnly: false, quality: "1080p",
                                groupTitle: "Мой 100% плейлист/тест")
        let a = ArgsBuilder.downloadArgs(spec, settings: s, tools: tools())
        XCTAssertTrue(a.contains("--cookies-from-browser"))
        let oIndex = a.firstIndex(of: "-o")!
        XCTAssertEqual(a[oIndex + 1], "Мой 100%% плейлист-тест/" + Settings.defaultTemplate)

        let no = DownloadSpec(url: "https://vk.com/video-1_2", audioOnly: false, quality: "1080p", noCookies: true)
        XCTAssertFalse(ArgsBuilder.downloadArgs(no, settings: s, tools: tools()).contains("--cookies-from-browser"))
    }

    func testResolveArgsSingleVideoInPlaylistLink() {
        let a = ArgsBuilder.resolveArgs(url: "https://www.youtube.com/watch?v=abc&list=PL1", settings: Settings(),
                                        tools: tools(), audioOnly: false, quality: "1080p", noCookies: false)
        XCTAssertTrue(a.contains("--no-playlist"))
        XCTAssertTrue(a.contains("-J"))
        let b = ArgsBuilder.resolveArgs(url: "https://www.youtube.com/playlist?list=PL1", settings: Settings(),
                                        tools: tools(), audioOnly: false, quality: "1080p", noCookies: false)
        XCTAssertFalse(b.contains("--no-playlist"))
    }

    func testYouTubeSelectorPrefersPlainHTTPSOverHLS() {
        let yt = ArgsBuilder.formatSelector(quality: "1080p", codec: "h264", audioOnly: false, canMerge: true, avoidHLS: true)
        XCTAssertTrue(yt.hasPrefix("bv*[vcodec^=avc1][height<=?1080][protocol!*=m3u8]+ba[ext=m4a][protocol!*=m3u8]/"), yt)
        // запасные варианты без ограничения протокола остаются — иначе ролик без https-форматов не скачать
        XCTAssertTrue(yt.hasSuffix("/b[height<=?1080]/b"), yt)
        XCTAssertEqual(ArgsBuilder.formatSelector(quality: "720p", codec: "any", audioOnly: true, canMerge: true, avoidHLS: true),
                       "ba[protocol!*=m3u8]/bestaudio/best")
        // на других сайтах селектор прежний
        XCTAssertFalse(ArgsBuilder.formatSelector(quality: "1080p", codec: "h264", audioOnly: false, canMerge: true)
            .contains("m3u8"))
    }

    func testYouTubeArgsAvoidHLSButOtherSitesDoNot() {
        let yt = DownloadSpec(url: "https://www.youtube.com/watch?v=abc", audioOnly: false, quality: "1080p")
        let a = ArgsBuilder.downloadArgs(yt, settings: Settings(), tools: tools())
        XCTAssertTrue(a[a.firstIndex(of: "-f")! + 1].contains("protocol!*=m3u8"))
        let vk = DownloadSpec(url: "https://vk.com/video-1_2", audioOnly: false, quality: "1080p")
        let b = ArgsBuilder.downloadArgs(vk, settings: Settings(), tools: tools())
        XCTAssertFalse(b[b.firstIndex(of: "-f")! + 1].contains("m3u8"))
    }

    func testSavedInfoReplacesURL() {
        var spec = DownloadSpec(url: "https://www.youtube.com/watch?v=abc", audioOnly: false, quality: "1080p")
        let plain = ArgsBuilder.downloadArgs(spec, settings: Settings(), tools: tools())
        XCTAssertEqual(plain.last, "https://www.youtube.com/watch?v=abc")
        XCTAssertFalse(plain.contains("--load-info-json"))

        spec.infoFile = "/tmp/info-1.json"
        let a = ArgsBuilder.downloadArgs(spec, settings: Settings(), tools: tools())
        let i = a.firstIndex(of: "--load-info-json")
        XCTAssertNotNil(i)
        XCTAssertEqual(a[i! + 1], "/tmp/info-1.json")
        XCTAssertFalse(a.contains("https://www.youtube.com/watch?v=abc"), "ссылка не нужна: страница уже разобрана")
    }

    func testTempDirKeepsPartsAndThumbnailOutOfDownloads() {
        var spec = DownloadSpec(url: "https://vimeo.com/76979871", audioOnly: false, quality: "1080p")
        spec.tempDir = "/Users/me/Downloads/.ytloader-tmp/abc"
        let a = ArgsBuilder.downloadArgs(spec, settings: Settings(), tools: tools())
        let i = a.firstIndex(of: "temp:/Users/me/Downloads/.ytloader-tmp/abc")
        XCTAssertNotNil(i)
        XCTAssertEqual(a[i! - 1], "-P")
        // без временной папки параметра нет
        let plain = ArgsBuilder.downloadArgs(DownloadSpec(url: "https://vimeo.com/1", audioOnly: false, quality: "1080p"),
                                             settings: Settings(), tools: tools())
        XCTAssertFalse(plain.contains { $0.hasPrefix("temp:") })
    }

    func testFallbackClientsAfterForbidden() {
        func clients(_ fallback: Int) -> String {
            var spec = DownloadSpec(url: "https://www.youtube.com/watch?v=abc", audioOnly: false, quality: "1080p")
            spec.fallback = fallback
            let a = ArgsBuilder.downloadArgs(spec, settings: Settings(), tools: tools())
            return a[a.firstIndex(of: "--extractor-args")! + 1]
        }
        XCTAssertEqual(clients(0), "youtube:player_client=default,web_embedded")
        XCTAssertEqual(clients(1), "youtube:player_client=tv,android_vr,web_safari")
        // на других сайтах запасных клиентов YouTube нет
        var vk = DownloadSpec(url: "https://vk.com/video-1_2", audioOnly: false, quality: "1080p")
        vk.fallback = 1
        XCTAssertFalse(ArgsBuilder.downloadArgs(vk, settings: Settings(), tools: tools()).contains("--extractor-args"))
    }
}
