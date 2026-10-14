import Foundation

extension Engine {
    // MARK: - добавление

    /// Ближайший момент, когда на часах будет HH:mm.
    static func nextOccurrence(of hhmm: String, now: Date = Date()) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = parts[0]
        comps.minute = parts[1]
        comps.second = 0
        guard var date = Calendar.current.date(from: comps) else { return nil }
        if date <= now { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    func add(_ body: [String: Any]) {
        let lang = settings.lang
        let text = body["text"] as? String ?? ""
        let urls = Sites.extractURLs(text)
        if urls.isEmpty {
            emitToast(Loc.t(lang, "No links found"))
            return
        }
        let force = body["force"] as? Bool ?? false
        let audioOnly = body["audioOnly"] as? Bool ?? false
        let quality = (body["quality"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? settings.defaultQuality
        var deferMode = body["deferMode"] as? String ?? ""
        let deferTime = body["deferTime"] as? String ?? ""
        var deferAt: Double = 0
        if deferMode == "time" {
            if let d = Engine.nextOccurrence(of: deferTime) { deferAt = d.timeIntervalSince1970 }
            else { deferMode = "manual" }
        }
        if !["", "wifi", "time", "manual"].contains(deferMode) { deferMode = "" }

        var duplicates: [[String: Any]] = []
        var duplicateURLs: [String] = []
        var inQueue = 0
        let base = Date().timeIntervalSince1970

        for (n, url) in urls.enumerated() {
            let key = Sites.videoKey(url)
            if items.contains(where: { $0.key == key }) { inQueue += 1; continue }
            if !force, let h = history.first(where: { $0.key == key }) {
                duplicateURLs.append(url)
                duplicates.append([
                    "url": url, "title": h.title, "path": h.filepath,
                    "date": Loc.dateLabel(Date(timeIntervalSince1970: h.finished), lang: lang),
                ])
                continue
            }
            let it = Item(url: url, title: Sites.host(of: url))
            it.added = base + Double(n) * 0.001
            it.audioOnly = audioOnly
            it.quality = audioOnly ? "audio" : quality
            it.format = audioOnly ? "mp3" : "mp4"
            it.deferMode = deferMode
            it.deferTime = deferMode == "time" ? deferTime : ""
            it.deferAt = deferAt
            it.sectionFrom = (body["sectionFrom"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            it.sectionTo = (body["sectionTo"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            it.site = Sites.label(for: url)
            it.key = key
            it.status = .resolving
            if !toolsReady || tools.hasYtdlp {
                items.append(it)
            } else {
                fail(it, message: Loc.t(lang, "err.noYtdlp"), kind: .generic)
                items.append(it)
            }
        }

        if inQueue > 0 && inQueue == urls.count {
            emitToast(Loc.t(lang, "Already in the queue"))
        }
        if !duplicates.isEmpty {
            var payload = body
            payload["text"] = duplicateURLs.joined(separator: "\n")
            payload["duplicates"] = duplicates
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.engine(askDuplicate: payload)
            }
        }
        dirty = true
        scheduleSave()
    }

    // MARK: - управление одной загрузкой

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    func pause(_ id: String) {
        guard let it = item(id) else { return }
        switch it.status {
        case .downloading:
            if let job = jobs[id] {
                job.intent = .pause
                job.process?.interrupt()
                armKill(job)
            }
            it.status = .paused
        case .queued:
            it.status = .paused
        case .resolving:
            // разбор ссылки короткий — останавливаем и начнём заново при продолжении
            if let job = jobs[id] {
                job.intent = .pause
                job.process?.kill()
            }
            it.status = .paused
        default:
            return
        }
        it.speed = 0
        it.eta = 0
        dirty = true
        scheduleSave()
    }

    func resume(_ id: String) {
        guard let it = item(id) else { return }
        switch it.status {
        case .paused, .error, .deferred:
            if it.status == .error {
                it.error = ""
                it.rawError = ""
                it.errorKind = ""
                it.attempts = 0
                it.updateRetried = false
            }
            it.deferMode = ""
            it.deferTime = ""
            it.deferAt = 0
            it.autoDeferred = false
            it.notBefore = 0
            it.status = it.resolved ? .queued : .resolving
            dirty = true
            scheduleSave()
        default:
            return
        }
    }

    func cancel(_ id: String) {
        guard let it = item(id) else { return }
        let temp = it.tempFiles
        if let job = jobs[id] {
            job.intent = .cancel
            job.process?.interrupt()
            armKill(job)
        }
        items.removeAll { $0.id == id }
        removeTempFiles(temp)
        dirty = true
        scheduleSave()
    }

    func deferItem(_ id: String, mode: String) {
        guard let it = item(id), it.status == .downloading || it.status == .queued else { return }
        if let job = jobs[id] {
            job.intent = .defer_
            job.process?.interrupt()
            armKill(job)
        }
        it.status = .deferred
        it.deferMode = mode == "wifi" ? "wifi" : "manual"
        it.autoDeferred = false
        it.speed = 0
        it.eta = 0
        dirty = true
        scheduleSave()
    }

    func bulk(group: String?, statuses: Set<ItemStatus>, _ action: (String) -> Void) {
        let ids = items
            .filter { statuses.contains($0.status) }
            .filter { group == nil || group!.isEmpty || $0.groupId == group! }
            .map { $0.id }
        for id in ids { action(id) }
    }

    func removeTempFiles(_ paths: [String]) {
        let fm = FileManager.default
        for p in paths {
            for suffix in ["", ".part", ".ytdl"] { try? fm.removeItem(atPath: p + suffix) }
        }
    }

    // MARK: - компоненты

    func install(_ name: String) {
        let lang = settings.lang
        guard Components.installable.contains(name), installing.isEmpty else { return }
        installing = name
        dirty = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var ok = true
            do { try Components.install(name) } catch {
                ok = false
                Log.shared.write("install \(name) failed: \(error)")
            }
            let found = Components.detect()
            self?.q.async {
                guard let self = self else { return }
                self.installing = ""
                self.tools = found
                self.toolsReady = true
                self.emitToast(ok ? Loc.t(lang, "{name} installed", ["name": name])
                                  : Loc.t(lang, "Couldn’t install {name}", ["name": name]))
                self.dirty = true
            }
        }
    }

    func runUpdate(manual: Bool) {
        guard !updating, !shuttingDown else { return }
        let lang = settings.lang
        updating = true
        installing = "yt-dlp"
        dirty = true
        let current = tools
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = Components.updateYtdlp(current: current, force: false)
            let found = Components.detect()
            self?.q.async {
                guard let self = self else { return }
                self.updating = false
                self.installing = ""
                self.tools = found
                self.settings.lastUpdateCheck = Date().timeIntervalSince1970
                self.sessionUpdateDone = true
                switch outcome {
                case .updated(let v):
                    if manual { self.emitToast(Loc.t(lang, "yt-dlp updated to {v}", ["v": v])) }
                case .upToDate(let v):
                    if manual { self.emitToast(Loc.t(lang, "yt-dlp is up to date ({v})", ["v": v])) }
                case .failed:
                    if manual { self.emitToast(Loc.t(lang, "Couldn’t update yt-dlp")) }
                }
                self.dirty = true
                self.scheduleSave()
            }
        }
    }
}
