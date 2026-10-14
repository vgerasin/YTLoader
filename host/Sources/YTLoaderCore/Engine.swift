import Foundation

/// Краткая сводка для Dock, строки меню и уведомлений.
public struct EngineSummary {
    public var active = 0
    public var queued = 0
    public var failed = 0
    public var paused = 0
    public var deferred = 0
    public var speed: Double = 0
    public var overallPct = 0
    public var running: [(title: String, pct: Int)] = []
    public var theme = "dark"
    public var accent = "#007AFF"
    public var dockBadge = true
    public var menuBar = true
    public var notify = true
    public var lang = "en"
    public var folder = ""
    public init() {}
}

/// Всё, что движок сообщает окну. Вызывается в главном потоке.
public protocol EngineDelegate: AnyObject {
    func engine(push json: String, summary: EngineSummary)
    func engine(notifyTitle: String, body: String, path: String)
    func engine(askDuplicate payload: [String: Any])
}

/// Запущенный процесс yt-dlp для одной загрузки или одного разбора ссылки.
final class Job {
    enum Kind { case resolve, download }
    enum Intent { case none, pause, cancel, defer_, shutdown }

    let kind: Kind
    var process: RunningProcess?
    var intent: Intent = .none
    var tracker: ProgressTracker
    var tail: [String] = []
    var out: [String] = []
    var printFile = ""
    var finalPath = ""
    var destinations: [String] = []
    var tempDir = ""
    var finishing = false
    // для журнала: сколько времени занял каждый этап
    let started = Date()
    var firstProgressAt: Date?
    var finishingAt: Date?
    var elapsed: String { Job.seconds(Date().timeIntervalSince(started)) }
    static func seconds(_ t: TimeInterval) -> String { String(format: "%.1fs", t) }

    init(kind: Kind, tracker: ProgressTracker = ProgressTracker()) {
        self.kind = kind
        self.tracker = tracker
    }

    func addTail(_ line: String) {
        tail.append(line)
        if tail.count > 60 { tail.removeFirst(tail.count - 60) }
    }
}

/// Очередь загрузок. Всё состояние живёт в одной последовательной очереди `q`;
/// снаружи вызывать методы можно из любого потока.
public final class Engine {
    let q = DispatchQueue(label: "ytloader.engine")
    weak var delegate: EngineDelegate?

    var settings = Settings()
    var items: [Item] = []
    var history: [HistoryEntry] = []
    var tools = ToolPaths()
    var toolsReady = false
    var installing = ""
    var netKind: NetKind = .wifi
    var netLabel = "Wi-Fi"
    var windowInfo = ""
    var jobs: [String: Job] = [:]
    var dirty = true
    var timer: DispatchSourceTimer?
    var saveScheduled = false
    var dismissedClips = Set<String>()
    var notice = ""
    var updating = false
    var sessionUpdateDone = false
    var started = false
    var shuttingDown = false

    public init(delegate: EngineDelegate) {
        self.delegate = delegate
    }

    // MARK: - запуск

    public func start() {
        q.async { [self] in
            guard !started else { return }
            started = true
            if let s = Store.load(Settings.self, from: AppPaths.settingsFile) { settings = s }
            settings.sanitize()
            history = Store.loadArray(HistoryEntry.self, from: AppPaths.historyFile)
            items = Store.loadArray(Item.self, from: AppPaths.queueFile)
            restoreQueue()
            try? FileManager.default.createDirectory(atPath: settings.folder, withIntermediateDirectories: true)
            Log.shared.write("start; items=\(items.count) history=\(history.count)")

            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 0.2, repeating: 0.4)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t

            redetectTools(thenAutoUpdate: true)
        }
    }

    /// После перезапуска незавершённое либо продолжается само, либо ждёт нажатия.
    private func restoreQueue() {
        for it in items {
            it.speed = 0
            it.eta = 0
            switch it.status {
            case .downloading, .queued:
                it.status = settings.autoResume ? .queued : .paused
            case .resolving:
                it.status = settings.autoResume ? .resolving : .paused
            default:
                break
            }
        }
    }

    func redetectTools(thenAutoUpdate: Bool = false) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Components.detect()
            self?.q.async {
                guard let self = self else { return }
                self.tools = found
                self.toolsReady = true
                self.dirty = true
                Log.shared.write("tools: yt-dlp=\(found.ytdlpVersion) ffmpeg=\(found.hasFFmpeg) ffprobe=\(found.hasFFprobe) js=\(found.jsKind)")
                if thenAutoUpdate, self.settings.autoUpdate, found.hasYtdlp {
                    let week: Double = 7 * 24 * 3600
                    if Date().timeIntervalSince1970 - self.settings.lastUpdateCheck > week {
                        self.runUpdate(manual: false)
                    }
                }
            }
        }
    }

    // MARK: - то, что приходит от окна

    public func setNetwork(kind: String, label: String) {
        q.async { [self] in
            let k = NetKind(rawValue: kind) ?? .none
            if k != netKind || label != netLabel {
                netKind = k
                netLabel = label
                dirty = true
            }
        }
    }

    public func setWindowInfo(_ text: String) {
        q.async { [self] in
            if text != windowInfo { windowInfo = text; dirty = true }
        }
    }

    public func requestPush() {
        q.async { [self] in dirty = true; pushIfNeeded(force: true) }
    }

    /// Ссылка из буфера, которую стоит предложить добавить (нет в очереди и истории).
    public func clipboardCandidate(_ text: String, completion: @escaping (String?) -> Void) {
        q.async { [self] in
            var found: String?
            if settings.clipboardWatch {
                for url in Sites.extractURLs(text) where Sites.isLikelyMedia(url) {
                    let key = Sites.videoKey(url)
                    if dismissedClips.contains(url) { continue }
                    if items.contains(where: { $0.key == key }) { continue }
                    if history.contains(where: { $0.key == key }) { continue }
                    found = url
                    break
                }
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    public func currentFolder(_ completion: @escaping (String) -> Void) {
        q.async { [self] in
            let f = settings.folder
            DispatchQueue.main.async { completion(f) }
        }
    }

    /// Команда из интерфейса (`/api/...`), которую обрабатывает сам движок.
    public func handle(path: String, body: [String: Any]) {
        q.async { [self] in
            switch path {
            case "/api/add": add(body)
            case "/api/pause": if let id = body["id"] as? String { pause(id) }
            case "/api/resume": if let id = body["id"] as? String { resume(id) }
            case "/api/cancel": if let id = body["id"] as? String { cancel(id) }
            case "/api/defer": if let id = body["id"] as? String { deferItem(id, mode: body["mode"] as? String ?? "manual") }
            case "/api/pauseAll": bulk(group: body["group"] as? String, statuses: [.downloading, .queued, .resolving]) { self.pause($0) }
            case "/api/resumeAll": bulk(group: body["group"] as? String, statuses: [.paused]) { self.resume($0) }
            case "/api/retryFailed": bulk(group: body["group"] as? String, statuses: [.error]) { self.resume($0) }
            case "/api/cancelAll":
                bulk(group: body["group"] as? String, statuses: [.downloading, .queued, .resolving, .paused, .error]) { self.cancel($0) }
            case "/api/clearHistory":
                history.removeAll()
                dirty = true
                scheduleSave()
            case "/api/dismissClip":
                if let u = body["url"] as? String { dismissedClips.insert(u) }
            case "/api/settings":
                applySettings(body)
            case "/api/updateYtdlp":
                runUpdate(manual: true)
            case "/api/recheckComponents":
                redetectTools()
            case "/api/installComponent":
                if let name = body["name"] as? String { install(name) }
            default:
                Log.shared.write("unknown command \(path)")
            }
        }
    }

    func applySettings(_ patch: [String: Any]) {
        let changed = settings.apply(patch: patch)
        guard !changed.isEmpty else { return }
        if changed.contains("folder") {
            try? FileManager.default.createDirectory(atPath: settings.folder, withIntermediateDirectories: true)
        }
        dirty = true
        scheduleSave()
        // Новые значения подхватятся при следующем запуске; идущие загрузки не трогаем.
    }

    /// Вызывается после выбора папки в системном диалоге.
    public func setFolder(_ path: String) {
        q.async { [self] in applySettings(["folder": path]) }
    }

    public func toast(_ text: String) {
        q.async { [self] in notice = text; dirty = true }
    }

    // MARK: - завершение

    /// Останавливает процессы мягко и сохраняет очередь. Блокирует поток до 3 секунд.
    public func shutdown() {
        q.sync {
            shuttingDown = true
            timer?.cancel()
            for (_, job) in jobs {
                job.intent = .shutdown
                job.process?.interrupt()
            }
            for it in items {
                if it.status == .downloading { it.status = settings.autoResume ? .queued : .paused }
                it.speed = 0
                it.eta = 0
            }
            saveNow()
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let alive = q.sync { jobs.values.contains { $0.process?.isRunning == true } }
            if !alive { break }
            usleep(100_000)
        }
        q.sync { for (_, job) in jobs { job.process?.kill() } }
    }

    // MARK: - планировщик

    func tick() {
        guard !shuttingDown else { return }
        let now = Date().timeIntervalSince1970
        let unmetered = netKind == .wifi || netKind == .ethernet

        for it in items where it.status == .deferred {
            if it.autoDeferred, unmetered { wake(it); continue }
            switch it.deferMode {
            case "time": if it.deferAt > 0 && now >= it.deferAt { wake(it) }
            case "wifi": if unmetered { wake(it) }
            default: break
            }
        }

        if settings.wifiOnly && netKind == .cellular {
            for it in items where it.status == .downloading || it.status == .queued {
                deferBecauseMetered(it)
            }
        }

        if toolsReady && !updating {
            // разбор ссылок — не больше трёх одновременно
            var resolving = jobs.values.filter { $0.kind == .resolve }.count
            for it in items where it.status == .resolving && jobs[it.id] == nil && resolving < 3 {
                startResolve(it)
                resolving += 1
            }

            if netKind != .none {
                let active = items.filter { $0.status == .downloading }.count
                let slots = settings.maxParallel - active
                if slots > 0 {
                    let ready = items
                        .filter { $0.status == .queued && jobs[$0.id] == nil && $0.notBefore <= now }
                        .sorted { $0.added < $1.added }
                    for it in ready.prefix(slots) { startDownload(it) }
                }
            }
        }
        pushIfNeeded(force: false)
    }

    func wake(_ it: Item) {
        it.status = it.resolved ? .queued : .resolving
        it.autoDeferred = false
        it.deferMode = ""
        it.deferTime = ""
        it.deferAt = 0
        dirty = true
        scheduleSave()
    }

    func deferBecauseMetered(_ it: Item) {
        if let job = jobs[it.id], job.kind == .download {
            job.intent = .defer_
            job.process?.interrupt()
            armKill(job)
        }
        it.status = .deferred
        it.deferMode = "wifi"
        it.autoDeferred = true
        it.speed = 0
        it.eta = 0
        dirty = true
        scheduleSave()
        notice = Loc.t(settings.lang, "Moved to Deferred: waiting for Wi-Fi")
    }

    /// Если процесс не откликнулся на мягкую остановку — убиваем.
    func armKill(_ job: Job) {
        q.asyncAfter(deadline: .now() + 4) {
            if let p = job.process, p.isRunning { p.kill() }
        }
    }

    // MARK: - снимок состояния

    func pushIfNeeded(force: Bool) {
        guard dirty || force else { return }
        dirty = false
        let lang = settings.lang

        var state: [String: Any] = [:]
        state["items"] = items.map { $0.uiJSON() }
        state["history"] = history.prefix(settings.keepHistory).map { $0.uiJSON(lang: lang) }
        state["settings"] = settings.uiJSON
        state["env"] = Components.envJSON(tools: tools, installing: installing, window: windowInfo,
                                          systemLang: Loc.systemLanguage())
        state["net"] = ["kind": netKind.rawValue, "label": netLabel]
        let running = items.filter { $0.status == .downloading }
        let totals: [String: Any] = ["active": running.count, "speed": jsonNum(running.reduce(0) { $0 + $1.speed })]
        state["totals"] = totals
        state["notice"] = notice
        notice = ""

        guard JSONSerialization.isValidJSONObject(state),
              let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else {
            Log.shared.write("state is not serialisable")
            return
        }
        let summary = makeSummary(running: running)
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.engine(push: json, summary: summary)
        }
    }

    func makeSummary(running: [Item]) -> EngineSummary {
        var s = EngineSummary()
        s.active = running.count
        s.queued = items.filter { $0.status == .queued || $0.status == .resolving }.count
        s.failed = items.filter { $0.status == .error }.count
        s.paused = items.filter { $0.status == .paused }.count
        s.deferred = items.filter { $0.status == .deferred }.count
        s.speed = running.reduce(0) { $0 + $1.speed }
        let live = items.filter { $0.status == .downloading || $0.status == .queued || $0.status == .paused }
        let total = live.reduce(Int64(0)) { $0 + $1.total }
        let done = live.reduce(Int64(0)) { $0 + $1.downloaded }
        s.overallPct = total > 0 ? Int(min(100, done * 100 / total)) : (running.first?.pct ?? 0)
        s.running = running.prefix(5).map { (title: $0.title, pct: $0.pct) }
        s.theme = settings.theme
        s.accent = settings.accent
        s.dockBadge = settings.dockBadge
        s.menuBar = settings.menuBar
        s.notify = settings.notify
        s.lang = settings.lang
        s.folder = settings.folder
        return s
    }

    // MARK: - сохранение

    func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        q.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    func saveNow() {
        Store.save(settings, to: AppPaths.settingsFile)
        Store.save(items, to: AppPaths.queueFile)
        Store.save(Array(history.prefix(settings.keepHistory)), to: AppPaths.historyFile)
    }

    // MARK: - уведомления окну

    func emitToast(_ text: String) {
        notice = text
        dirty = true
    }

    func emitNotification(title: String, body: String, path: String) {
        guard settings.notify else { return }
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.engine(notifyTitle: title, body: body, path: path)
        }
    }
}
