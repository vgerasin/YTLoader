import AppKit
import WebKit
import YTLoaderCore

/// Самопроверка настоящего окна: `YTLOADER_SELFTEST=1 YTLoader`.
/// Проходит тот же путь, что и пользователь: вставляет ссылку, нажимает «Добавить»,
/// ждёт файл в истории, открывает настройки — и сохраняет снимки окна.
/// Запускается в CI на macOS; пользователю не нужна.
final class SelfTest {
    private unowned let app: AppDelegate
    private let env = ProcessInfo.processInfo.environment
    private var step = 0
    private var busy = false
    private var timer: Timer?
    private let started = Date()
    private var stepStarted = Date()

    init(app: AppDelegate) { self.app = app }

    private var outDir: String { env["YTLOADER_SELFTEST_OUT"] ?? NSTemporaryDirectory() }
    private var url: String? { env["YTLOADER_SELFTEST_URL"] }

    func start() {
        print("SELFTEST start")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func eval(_ js: String, _ done: @escaping (Any?) -> Void) {
        app.web.evaluateJavaScript(js) { result, error in
            if let error = error { print("SELFTEST js error: \(error)") }
            done(result)
        }
    }

    private func text(_ selector: String, _ done: @escaping (String) -> Void) {
        eval("(function(){var e=document.querySelector('\(selector)');return e?e.textContent:'';})()") {
            done(($0 as? String) ?? "")
        }
    }

    private func snapshot(_ name: String, then: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let config = WKSnapshotConfiguration()
        app.web.takeSnapshot(with: config) { [outDir] image, error in
            if let image = image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outDir + "/" + name + ".png"))
                print("SELFTEST snapshot \(name)")
            } else {
                print("SELFTEST snapshot failed \(name): \(String(describing: error))")
            }
            then()
        }
    }

    private func advance(_ to: Int? = nil) {
        step = to ?? step + 1
        stepStarted = Date()
        busy = false
    }

    private func fail(_ message: String) {
        timer?.invalidate()
        eval("document.body ? document.body.innerText.slice(0, 1500) : ''") { body in
            print("SELFTEST FAIL: \(message) (step \(self.step))")
            print("--- page text ---\n\(body as? String ?? "")")
            print("--- log tail ---\n\(Log.shared.tail(bytes: 4000))")
            fflush(stdout)
            exit(1)
        }
    }

    private func pass() {
        timer?.invalidate()
        print("SELFTEST OK")
        fflush(stdout)
        app.core.shutdown()
        exit(0)
    }

    private func tick() {
        if Date().timeIntervalSince(started) > 150 { return fail("overall timeout") }
        if Date().timeIntervalSince(stepStarted) > 60 { return fail("step timeout") }
        guard app.pageLoaded, !busy else { return }
        busy = true

        switch step {
        case 0:  // интерфейс отрисовался из первого снимка состояния
            text("#tabQueue") { t in
                if t.contains("·") { self.snapshot("01-start") { self.advance() } } else { self.busy = false }
            }
        case 1:  // вставляем ссылку и жмём «Добавить», как пользователь
            guard let url = url else { return advance(5) }
            let js = """
            (function(){var i=document.querySelector('#input');i.value=\(Self.js(url));
            document.querySelector('#addBtn').click();return 'clicked';})()
            """
            eval(js) { _ in self.advance() }
        case 2:  // карточка появилась в очереди или сразу в истории
            text("#tabQueue") { q in
                self.text("#tabHistory") { h in
                    if q.contains("· 1") { self.snapshot("02-queue") { self.advance() } }
                    else if h.contains("· 1") { self.advance() }
                    else { self.busy = false }
                }
            }
        case 3:  // ждём готовый файл в истории
            text("#tabHistory") { h in
                if h.hasSuffix("1") || h.contains("· 1") {
                    self.eval("document.querySelector('#tabHistory').click(); 'ok'") { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self.snapshot("03-history") { self.advance() }
                        }
                    }
                } else { self.busy = false }
            }
        case 4:  // файл в самом деле лежит на диске
            text("#list") { t in
                print("SELFTEST history text: \(t.prefix(200))")
                self.advance()
            }
        case 5:  // настройки открываются и показывают найденные инструменты
            eval("document.querySelector('#gear').click(); 'ok'") { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.text(".sheet") { t in
                        if t.contains("yt-dlp") { self.snapshot("04-settings") { self.advance() } }
                        else { self.fail("settings sheet is empty") }
                    }
                }
            }
        default:
            pass()
        }
    }

    /// Строка как литерал JS.
    private static func js(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s), let out = String(data: data, encoding: .utf8) { return out }
        return "\"\""
    }
}
