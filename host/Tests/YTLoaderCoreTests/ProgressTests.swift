import XCTest
@testable import YTLoaderCore

final class ProgressTests: XCTestCase {
    func testParseProgressLine() {
        let line = "YTL|downloading|1048576|10485760|NA|2097152.5|4|avc1.640028|none|NA|NA"
        guard case .progress(let p) = ProgressParser.parse(line) else { return XCTFail("not progress") }
        XCTAssertEqual(p.status, "downloading")
        XCTAssertEqual(p.downloaded, 1_048_576)
        XCTAssertEqual(p.total, 10_485_760)
        XCTAssertNil(p.estimate)
        XCTAssertEqual(p.speed ?? 0, 2_097_152.5, accuracy: 0.01)
        XCTAssertEqual(p.kind, "video")
    }

    func testAudioKindAndFragments() {
        let line = "YTL|downloading|500|NA|9000|100.0|NA|none|mp4a.40.2|3|10"
        guard case .progress(let p) = ProgressParser.parse(line) else { return XCTFail("not progress") }
        XCTAssertEqual(p.kind, "audio")
        XCTAssertEqual(p.knownTotal, 9000)
        XCTAssertEqual(p.fragIndex, 3)
        XCTAssertEqual(p.fragCount, 10)
        XCTAssertNil(p.eta)
    }

    func testOtherLines() {
        XCTAssertEqual(ProgressParser.parse("[download] Destination: /tmp/a.f137.mp4"), .destination("/tmp/a.f137.mp4"))
        XCTAssertEqual(ProgressParser.parse("[Merger] Merging formats into \"/tmp/a.mp4\""), .merging("/tmp/a.mp4"))
        XCTAssertEqual(ProgressParser.parse("[ExtractAudio] Destination: /tmp/a.mp3"), .postprocess("/tmp/a.mp3"))
        XCTAssertEqual(ProgressParser.parse("[download] /tmp/a.mp4 has already been downloaded"), .alreadyDownloaded("/tmp/a.mp4"))
        XCTAssertEqual(ProgressParser.parse("ERROR: Video unavailable"), .error("Video unavailable"))
        XCTAssertEqual(ProgressParser.parse("[youtube] abc: Downloading webpage"), .other)
        XCTAssertEqual(ProgressParser.parse("YTL|broken"), .other)
    }

    func testTrackerTwoStreams() {
        var tr = ProgressTracker(streams: [
            StreamInfo(kind: "video", total: 800), StreamInfo(kind: "audio", total: 200),
        ])
        func line(_ s: String, _ d: Int64, _ t: Int64, v: String, a: String) -> ProgressLine {
            ProgressLine(status: s, downloaded: d, total: t, estimate: nil, speed: 100, eta: nil,
                         vcodec: v, acodec: a, fragIndex: nil, fragCount: nil)
        }
        var snap = tr.update(line("downloading", 400, 800, v: "avc1", a: "none"))
        XCTAssertEqual(snap.downloaded, 400)
        XCTAssertEqual(snap.total, 1000)
        XCTAssertEqual(snap.pct, 40)
        XCTAssertEqual(snap.stage, "video")

        _ = tr.update(line("finished", 800, 800, v: "avc1", a: "none"))
        snap = tr.update(line("downloading", 100, 200, v: "none", a: "mp4a"))
        XCTAssertEqual(snap.stage, "audio")
        XCTAssertEqual(snap.downloaded, 900)
        XCTAssertEqual(snap.pct, 90)

        tr.complete()
        XCTAssertTrue(tr.streams.allSatisfy { !$0.active && !$0.estimated })
    }

    func testTrackerUnknownStreamsGrowDynamically() {
        var tr = ProgressTracker()
        func line(_ s: String, _ d: Int64, v: String, a: String) -> ProgressLine {
            ProgressLine(status: s, downloaded: d, total: 1000, estimate: nil, speed: 10, eta: nil,
                         vcodec: v, acodec: a, fragIndex: nil, fragCount: nil)
        }
        _ = tr.update(line("downloading", 500, v: "vp9", a: "none"))
        _ = tr.update(line("finished", 1000, v: "vp9", a: "none"))
        _ = tr.update(line("downloading", 10, v: "none", a: "opus"))
        XCTAssertEqual(tr.streams.count, 2)
        XCTAssertEqual(tr.streams[1].kind, "audio")
    }

    func testFragmentProgressWithoutTotal() {
        var tr = ProgressTracker()
        let p = ProgressLine(status: "downloading", downloaded: 3000, total: nil, estimate: nil, speed: 10,
                             eta: nil, vcodec: "NA", acodec: "NA", fragIndex: 5, fragCount: 20)
        let snap = tr.update(p)
        XCTAssertEqual(snap.pct, 25)
    }
}
