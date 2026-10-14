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
}
