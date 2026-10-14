import Foundation

/// Короткий идентификатор для загрузки.
public func shortID() -> String {
    String(UUID().uuidString.prefix(8)).lowercased()
}

/// JSON не умеет NaN и бесконечность — JSONSerialization на них падает.
func jsonNum(_ d: Double) -> Double {
    d.isFinite ? d : 0
}

func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

func fileSize(atPath path: String) -> Int64? {
    guard !path.isEmpty,
          let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? NSNumber else { return nil }
    return size.int64Value
}

/// Разбирает вывод процесса на строки. И \n, и \r считаются концом строки.
final class LineReader {
    private var buffer = Data()

    func feed(_ data: Data, _ emit: (String) -> Void) {
        buffer.append(data)
        while let idx = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            if !lineData.isEmpty, let s = String(data: lineData, encoding: .utf8) {
                emit(s)
            }
        }
    }

    func flush(_ emit: (String) -> Void) {
        if !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) {
            emit(s)
        }
        buffer.removeAll()
    }
}

/// Запущенный внешний процесс (yt-dlp и т. п.) с построчным чтением вывода.
final class RunningProcess {
    let process = Process()

    /// onStdout/onStderr вызываются из фоновых потоков, onExit — после того,
    /// как оба потока вывода дочитаны до конца.
    static func start(exe: String,
                      args: [String],
                      env: [String: String],
                      onStdout: @escaping (String) -> Void,
                      onStderr: @escaping (String) -> Void,
                      onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
        let rp = RunningProcess()
        let p = rp.process
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()

        let group = DispatchGroup()
        let readers: [(Pipe, (String) -> Void)] = [(outPipe, onStdout), (errPipe, onStderr)]
        for (pipe, callback) in readers {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let reader = LineReader()
                let handle = pipe.fileHandleForReading
                while true {
                    guard let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty else { break }
                    reader.feed(chunk, callback)
                }
                reader.flush(callback)
                group.leave()
            }
        }
        group.notify(queue: DispatchQueue.global(qos: .utility)) {
            p.waitUntilExit()
            onExit(p.terminationStatus)
        }
        return rp
    }

    /// Мягкая остановка (SIGINT): yt-dlp оставляет .part-файлы для докачки.
    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    func kill() {
        if process.isRunning { process.terminate() }
    }

    var isRunning: Bool { process.isRunning }
}

/// Запускает короткую команду и возвращает её вывод (для --version и т. п.).
func runCapture(_ exe: String, _ args: [String], timeout: TimeInterval = 15) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if p.isRunning { p.terminate() }
    }
    let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
    while p.isRunning && Date() < deadline { usleep(20_000) }
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}
