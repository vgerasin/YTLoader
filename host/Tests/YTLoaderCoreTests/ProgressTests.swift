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

    func testHLSAudioHasNoCodecButIsAudio() {
        let line = "YTL|downloading|1024|NA|217140.0|0|NA|none|NA|0|11"
        guard case .progress(let p) = ProgressParser.parse(line) else { return XCTFail("not progress") }
        XCTAssertEqual(p.kind, "audio")
        let direct = "YTL|downloading|1024|2256199|NA|NA|NA|NA|NA|NA|NA"
        guard case .progress(let d) = ProgressParser.parse(direct) else { return XCTFail("not progress") }
        XCTAssertEqual(d.kind, "video")
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

    /// Эти строки yt-dlp печатает ДО загрузки. Если принять их за «постобработку», карточка уходит в режим
    /// «склеиваю» и весь прогресс отбрасывается (так было в 5.0 и 5.1).
    func testPreDownloadStepsAreNotTheEndOfTheDownload() {
        for line in ["[ThumbnailsConvertor] There aren't any thumbnails to convert",
                     "[ThumbnailsConvertor] Converting thumbnail \"/x/a.webp\" to jpg",
                     "[SponsorBlock] Fetching SponsorBlock segments",
                     "[SubtitlesConvertor] Converting subtitles"] {
            XCTAssertEqual(ProgressParser.parse(line), .other, line)
        }
        for line in ["[Metadata] Adding metadata to \"/x/a.mp4\"", "[EmbedThumbnail] ffmpeg: Adding thumbnail to \"/x/a.mp4\"",
                     "[MoveFiles] Moving file \"/x/a.mp4\" to \"/y/a.mp4\"", "[FixupM3u8] Fixing MPEG-TS in MP4 container",
                     "[ModifyChapters] Removing chapters from a.mp4"] {
            XCTAssertEqual(ProgressParser.parse(line), .postprocess(""), line)
        }
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

    private func hls(_ downloaded: Int64, estimate: Int64?, frag: Int, of count: Int, status: String = "downloading",
                     vcodec: String = "avc1.640028") -> ProgressLine {
        ProgressLine(status: status, downloaded: downloaded, total: nil, estimate: estimate, speed: 1_000_000, eta: nil,
                     vcodec: vcodec, acodec: "NA", fragIndex: frag, fragCount: count)
    }

    /// HLS: оценка размера от yt-dlp скачет, а процент должен идти ровно и только вперёд.
    func testHLSEstimateSwingsDoNotMoveProgressBar() {
        var tr = ProgressTracker(streams: [StreamInfo(kind: "video", total: 900_000_000),
                                           StreamInfo(kind: "audio", total: 30_000_000)])
        // оценка в начале сильно занижена и потом растёт — раньше это давало «сразу 100%»
        let seq: [(Int64, Int64, Int)] = [(2_000_000, 2_500_000, 1), (6_000_000, 8_000_000, 2),
                                          (40_000_000, 60_000_000, 10), (300_000_000, 950_000_000, 100),
                                          (640_000_000, 1_150_000_000, 200), (880_000_000, 880_000_000, 300)]
        var last = -1
        for (done, est, frag) in seq {
            let snap = tr.update(hls(done, estimate: est, frag: frag, of: 300))
            XCTAssertGreaterThanOrEqual(snap.pct, last, "процент не должен уменьшаться")
            XCTAssertLessThan(snap.pct, 100)
            last = snap.pct
        }
        // 300 из 300 фрагментов видео — это почти вся полоса, кроме звука
        XCTAssertGreaterThan(last, 90)
        XCTAssertLessThan(last, 100)
        // после первого же фрагмента полоса почти пустая
        var fresh = ProgressTracker(streams: [StreamInfo(kind: "video", total: 900_000_000)])
        XCTAssertLessThan(fresh.update(hls(2_000_000, estimate: 2_500_000, frag: 1, of: 300)).pct, 5)
    }

    /// Повтор фрагмента после ошибки уменьшает счётчик байт — это не новая дорожка.
    func testDownloadedBytesDroppingDoesNotFinishTheStream() {
        var tr = ProgressTracker(streams: [StreamInfo(kind: "video", total: 800_000_000),
                                           StreamInfo(kind: "audio", total: 20_000_000)])
        _ = tr.update(hls(100_000_000, estimate: 800_000_000, frag: 40, of: 300))
        let before = tr.update(hls(120_000_000, estimate: 800_000_000, frag: 50, of: 300))
        let after = tr.update(hls(60_000_000, estimate: 800_000_000, frag: 50, of: 300))
        XCTAssertEqual(tr.streams.count, 2)
        XCTAssertEqual(tr.streams[0].kind, "video")
        XCTAssertEqual(after.stage, "video")
        XCTAssertGreaterThanOrEqual(after.pct, before.pct)
        XCTAssertLessThan(after.pct, 30)
        XCTAssertFalse(tr.streams[0].done == tr.streams[0].total)
    }

    /// Размер по ссылке (1,15 ГБ) не должен оставаться в полосе, когда yt-dlp уже знает точнее.
    func testEstimatedSizeFollowsYtdlpOnceItSettles() {
        var tr = ProgressTracker(streams: [StreamInfo(kind: "video", total: 1_150_000_000)])
        _ = tr.update(hls(1_000_000, estimate: 3_000_000, frag: 1, of: 300))
        XCTAssertEqual(tr.streams[0].total, 1_150_000_000, "ранняя оценка yt-dlp не заменяет размер из разбора")
        let snap = tr.update(hls(300_000_000, estimate: 905_000_000, frag: 100, of: 300))
        XCTAssertEqual(tr.streams[0].total, 905_000_000)
        XCTAssertEqual(snap.total, 905_000_000)
        _ = tr.update(hls(905_000_000, estimate: 905_000_000, frag: 300, of: 300, status: "finished"))
        XCTAssertEqual(tr.streams[0].total, 905_000_000)
        XCTAssertFalse(tr.streams[0].estimated)
    }

    /// Дорожка звука раньше видео (или другой порядок) — полоса всё равно идёт к нужному участку.
    func testStreamOrderDoesNotMatter() {
        var tr = ProgressTracker(streams: [StreamInfo(kind: "video", total: 800), StreamInfo(kind: "audio", total: 200)])
        let audio = ProgressLine(status: "downloading", downloaded: 100, total: 200, estimate: nil, speed: 10, eta: nil,
                                 vcodec: "none", acodec: "mp4a", fragIndex: nil, fragCount: nil)
        let snap = tr.update(audio)
        XCTAssertEqual(snap.stage, "audio")
        XCTAssertEqual(snap.pct, 10)
        XCTAssertFalse(tr.streams[0].active)
        XCTAssertEqual(tr.streams[0].done, 0)
    }
}
