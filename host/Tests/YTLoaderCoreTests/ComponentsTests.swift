import XCTest
@testable import YTLoaderCore

/// Распакованная сборка yt-dlp: поиск, выбор самой новой версии, уборка старых копий, условия перехода.
final class ComponentsTests: XCTestCase {
    var bin: URL { AppPaths.binDir }

    override func setUp() {
        AppPaths.overrideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytl-comp-" + UUID().uuidString)
    }

    @discardableResult
    private func fakeYtdlp(at dir: URL, name: String, version: String) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho \(version)\n".write(to: p, atomically: true, encoding: .utf8)
        chmod(p.path, 0o755)
        return p.path
    }

    func testDetectPrefersNewestUnpackedBuild() throws {
        let old = try fakeYtdlp(at: bin.appendingPathComponent("yt-dlp-dist-2099.01.01"), name: "yt-dlp_macos", version: "2099.01.01")
        let new = try fakeYtdlp(at: bin.appendingPathComponent("yt-dlp-dist-2099.01.02"), name: "yt-dlp_macos", version: "2099.01.02")
        XCTAssertEqual(Components.distExecutables(), [new, old])
        let t = Components.detect()
        XCTAssertEqual(t.ytdlp, new)
        XCTAssertEqual(t.ytdlpVersion, "2099.01.02")
        XCTAssertTrue(Components.isUnpacked(t.ytdlp))
    }

    func testEqualVersionPrefersUnpackedOverSingleFile() throws {
        let single = try fakeYtdlp(at: bin, name: "yt-dlp", version: "2099.02.01")
        let dist = try fakeYtdlp(at: bin.appendingPathComponent("yt-dlp-dist-2099.02.01"), name: "yt-dlp_macos", version: "2099.02.01")
        XCTAssertNotEqual(single, dist)
        XCTAssertEqual(Components.detect().ytdlp, dist, "при одинаковой версии берём ту, что стартует быстрее")
    }

    func testPruneKeepsOnlyCurrentAndRemovesSingleFile() throws {
        try fakeYtdlp(at: bin, name: "yt-dlp", version: "2099.03.01")
        let old = bin.appendingPathComponent("yt-dlp-dist-2099.03.01")
        try fakeYtdlp(at: old, name: "yt-dlp_macos", version: "2099.03.01")
        let current = try fakeYtdlp(at: bin.appendingPathComponent("yt-dlp-dist-2099.03.02"), name: "yt-dlp_macos", version: "2099.03.02")
        Components.pruneOldYtdlp(keeping: current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("yt-dlp").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: current))
    }

    func testPruneDoesNothingWhenWorkingWithSingleFile() throws {
        let single = try fakeYtdlp(at: bin, name: "yt-dlp", version: "2099.04.01")
        Components.pruneOldYtdlp(keeping: single)
        XCTAssertTrue(FileManager.default.fileExists(atPath: single))
    }

    func testMigrationConditions() throws {
        var t = ToolPaths()
        XCTAssertFalse(Components.shouldMigrateToUnpacked(t), "yt-dlp нет вообще")

        t.ytdlp = try fakeYtdlp(at: bin, name: "yt-dlp", version: "2099.05.01")
        XCTAssertTrue(Components.shouldMigrateToUnpacked(t), "одиночный файл из нашей папки — переходим")

        t.ytdlp = "/opt/homebrew/bin/yt-dlp"
        XCTAssertFalse(Components.shouldMigrateToUnpacked(t), "чужую установку не трогаем")

        t.ytdlp = try fakeYtdlp(at: bin.appendingPathComponent("yt-dlp-dist-2099.05.01"), name: "yt-dlp_macos", version: "2099.05.01")
        XCTAssertFalse(Components.shouldMigrateToUnpacked(t), "уже распакованная")

        t.ytdlp = bin.appendingPathComponent("yt-dlp").path
        Components.markMigrationFailed()
        XCTAssertFalse(Components.shouldMigrateToUnpacked(t), "после неудачи несколько дней не пробуем снова")
        let old = Date().addingTimeInterval(-4 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: Components.migrationMarker.path)
        XCTAssertTrue(Components.shouldMigrateToUnpacked(t), "через несколько дней пробуем снова")
    }

    func testVersionIsCachedOnDisk() throws {
        let p = try fakeYtdlp(at: bin.appendingPathComponent("yt-dlp-dist-2099.06.01"), name: "yt-dlp_macos", version: "2099.06.01")
        XCTAssertEqual(Components.detect().ytdlpVersion, "2099.06.01")
        // подменяем содержимое на другую «версию», но с тем же размером и временем — кэш должен сработать без запуска файла
        let attrs = try FileManager.default.attributesOfItem(atPath: p)
        let mtime = attrs[.modificationDate] as! Date
        try "#!/bin/sh\necho 2088.06.01\n".write(toFile: p, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: p)
        XCTAssertEqual(Components.detect().ytdlpVersion, "2099.06.01")
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.cacheDir.appendingPathComponent("ytdlp-versions.json").path))
    }
}
