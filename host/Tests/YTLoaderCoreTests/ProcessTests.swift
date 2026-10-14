import XCTest
@testable import YTLoaderCore

final class ProcessTests: XCTestCase {
    /// Строки вывода должны доходить сразу, а не пачкой в конце: от этого зависит полоса прогресса.
    /// (До 5.1.1 читалка ждала 64 КБ или конец потока, и загрузка стояла на 0 %, а потом сразу «готово».)
    func testRunningProcessDeliversLinesAsTheyArrive() throws {
        let start = Date()
        let lock = NSLock()
        var firstAt: TimeInterval = -1
        var exitAt: TimeInterval = -1
        var lines: [String] = []
        let done = expectation(description: "process exited")

        _ = try RunningProcess.start(
            exe: "/bin/sh", args: ["-c", "echo first; sleep 2; echo second"],
            env: ProcessInfo.processInfo.environment,
            onStdout: { line in
                lock.lock(); defer { lock.unlock() }
                lines.append(line)
                if line == "first" { firstAt = Date().timeIntervalSince(start) }
            },
            onStderr: { _ in },
            onExit: { _ in
                lock.lock(); exitAt = Date().timeIntervalSince(start); lock.unlock()
                done.fulfill()
            })
        wait(for: [done], timeout: 15)

        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(lines, ["first", "second"])
        XCTAssertGreaterThan(firstAt, 0)
        XCTAssertGreaterThan(exitAt, 1.9)
        XCTAssertLessThan(firstAt, exitAt - 1.0, "первая строка пришла только в конце: \(firstAt) с из \(exitAt) с")
    }

    func testCarriageReturnsAndSplitLines() {
        let r = LineReader()
        var out: [String] = []
        r.feed(Data("abc\rde".utf8)) { out.append($0) }
        r.feed(Data("f\nlast".utf8)) { out.append($0) }
        r.flush { out.append($0) }
        XCTAssertEqual(out, ["abc", "def", "last"])
    }
}
