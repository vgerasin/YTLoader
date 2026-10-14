import XCTest
@testable import YTLoaderCore

final class PreviewTests: XCTestCase {
    func testOembedForSingleVideos() {
        let yt = Preview.oembedURL(for: "https://www.youtube.com/watch?v=UC_TsFsiWdI")
        XCTAssertEqual(yt?.host, "www.youtube.com")
        XCTAssertEqual(yt?.path, "/oembed")
        let query = URLComponents(url: yt!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "url" }?.value, "https://www.youtube.com/watch?v=UC_TsFsiWdI")
        XCTAssertNotNil(Preview.oembedURL(for: "https://youtu.be/UC_TsFsiWdI"))
        XCTAssertNotNil(Preview.oembedURL(for: "https://vimeo.com/76979871"))
        // ролик внутри плейлиста — всё равно один ролик
        XCTAssertNotNil(Preview.oembedURL(for: "https://www.youtube.com/watch?v=abc&list=PL123"))
    }

    func testNoOembedForCollectionsAndOtherSites() {
        XCTAssertNil(Preview.oembedURL(for: "https://www.youtube.com/playlist?list=PL123"))
        XCTAssertNil(Preview.oembedURL(for: "https://www.youtube.com/@somechannel"))
        XCTAssertNil(Preview.oembedURL(for: "https://vk.com/video-22822305_456239018"))
        XCTAssertNil(Preview.oembedURL(for: "https://rutube.ru/video/0123456789abcdef0123456789abcdef/"))
    }

    func testParseYouTubeAnswer() {
        let json = """
        {"title":"Тестовый ролик","author_name":"Канал","type":"video",
         "thumbnail_url":"https://i.ytimg.com/vi/UC_TsFsiWdI/hqdefault.jpg"}
        """
        let info = Preview.parse(Data(json.utf8))
        XCTAssertEqual(info?.title, "Тестовый ролик")
        XCTAssertEqual(info?.author, "Канал")
        XCTAssertEqual(info?.thumb, "https://i.ytimg.com/vi/UC_TsFsiWdI/mqdefault.jpg")
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(Preview.parse(Data("<html>".utf8)))
        XCTAssertNil(Preview.parse(Data("{\"title\":\"\"}".utf8)))
        XCTAssertNil(Preview.parse(Data("{\"error\":\"not found\"}".utf8)))
    }

    func testParseKeepsVimeoThumbnail() {
        let json = "{\"title\":\"V\",\"author_name\":\"A\",\"thumbnail_url\":\"https://i.vimeocdn.com/video/1_640.jpg\"}"
        XCTAssertEqual(Preview.parse(Data(json.utf8))?.thumb, "https://i.vimeocdn.com/video/1_640.jpg")
    }
}
