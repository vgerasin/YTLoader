import XCTest
@testable import YTLoaderCore

final class SitesTests: XCTestCase {
    func testExtractURLsFromMessyText() {
        let text = """
        Смотри: https://www.youtube.com/watch?v=dQw4w9WgXcQ, а ещё (https://vimeo.com/76979871).
        https://vk.com/video-22822305_456239018
        https://rutube.ru/video/0123456789abcdef0123456789abcdef/ повтор
        https://vimeo.com/76979871
        """
        let urls = Sites.extractURLs(text)
        XCTAssertEqual(urls.count, 4)
        XCTAssertEqual(urls[0], "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(urls[1], "https://vimeo.com/76979871")
        XCTAssertTrue(urls[3].hasPrefix("https://rutube.ru/video/"))
    }

    func testNoLinks() {
        XCTAssertTrue(Sites.extractURLs("просто текст без ссылок").isEmpty)
    }

    func testKnownSites() {
        XCTAssertEqual(Sites.site(for: "https://m.vk.com/video1_2")?.name, "VK")
        XCTAssertEqual(Sites.site(for: "https://vkvideo.ru/video-1_2")?.name, "VK")
        XCTAssertEqual(Sites.site(for: "https://rutube.ru/video/abc/")?.name, "Rutube")
        XCTAssertEqual(Sites.site(for: "https://player.vimeo.com/video/76979871")?.name, "Vimeo")
        XCTAssertEqual(Sites.site(for: "https://youtu.be/dQw4w9WgXcQ")?.name, "YouTube")
        XCTAssertNil(Sites.site(for: "https://example.org/video"))
        XCTAssertEqual(Sites.label(for: "https://example.org/video"), "example.org")
    }

    func testVideoKeyUnifiesLinks() {
        XCTAssertEqual(Sites.videoKey("https://youtu.be/dQw4w9WgXcQ"),
                       Sites.videoKey("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10s"))
        XCTAssertEqual(Sites.videoKey("https://www.youtube.com/shorts/abc123"), "yt:abc123")
        XCTAssertEqual(Sites.videoKey("https://vimeo.com/76979871"),
                       Sites.videoKey("https://player.vimeo.com/video/76979871"))
        XCTAssertEqual(Sites.videoKey("https://vk.com/video-22822305_456239018"), "vk:-22822305_456239018")
        XCTAssertEqual(Sites.videoKey("https://vk.com/some?z=video-22822305_456239018%2Fabc"), "vk:-22822305_456239018")
        XCTAssertEqual(Sites.videoKey("https://rutube.ru/video/0123abcd/"), "rutube:0123abcd")
        XCTAssertEqual(Sites.videoKey("https://www.youtube.com/playlist?list=PL123"), "ytlist:PL123")
    }

    func testLikelyMedia() {
        XCTAssertTrue(Sites.isLikelyMedia("https://www.youtube.com/watch?v=abc"))
        XCTAssertFalse(Sites.isLikelyMedia("https://www.youtube.com/"))
        XCTAssertFalse(Sites.isLikelyMedia("https://example.org/watch"))
        XCTAssertTrue(Sites.isLikelyMedia("https://rutube.ru/video/abc/"))
    }

    func testCollections() {
        XCTAssertTrue(Sites.looksLikeCollection("https://www.youtube.com/playlist?list=PL1"))
        XCTAssertTrue(Sites.looksLikeCollection("https://www.youtube.com/@channel"))
        XCTAssertFalse(Sites.looksLikeCollection("https://www.youtube.com/watch?v=abc&list=PL1"))
    }
}
