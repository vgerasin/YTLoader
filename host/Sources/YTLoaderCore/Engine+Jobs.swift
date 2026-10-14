import Foundation

extension Engine {
    // MARK: - разбор ссылки

    func startResolve(_ it: Item) {
        let args = ArgsBuilder.resolveArgs(url: it.url, settings: settings, tools: tools,
                                           audioOnly: it.audioOnly, quality: it.quality,
                                           noCookies: it.noCookies, fallback: it.fallback)
        let job = Job(kind: .resolve)
        jobs[it.id] = job
        let id = it.id
        let cookies = it.noCookies ? "off" : settings.cookieBrowser
        let js = tools.jsKind.isEmpty ? "none" : tools.jsKind
        Log.shared.write("resolve \(it.url) cookies=\(cookies) js=\(js) fallback=\(it.fallback)")
        do {
            job.process = try RunningProcess.start(
                exe: tools.ytdlp, args: args, env: ArgsBuilder.environment(tools: tools),
                onStdout: { [weak self] line in
                    self?.q.async { job.out.append(line) }
                },
                onStderr: { [weak self] line in
                    self?.q.async { job.addTail(line) }
                },
                onExit: { [weak self] code in
                    self?.q.async { self?.finishResolve(id: id, job: job, code: code) }
                })
        } catch {
            jobs[id] = nil
            fail(it, message: Loc.t(settings.lang, "err.generic"), kind: .generic, raw: "\(error)")
        }
    }

    func finishResolve(id: String, job: Job, code: Int32) {
        jobs[id] = nil
        guard let it = item(id) else { return }
        if job.intent != .none || shuttingDown { return }
        Log.shared.write("resolve finished in \(job.elapsed) exit=\(code)")
        if code != 0 {
            fail(it, lines: job.tail)
            return
        }
        // JSON — последняя строка stdout, которая начинается с «{»
        guard let line = job.out.last(where: { $0.hasPrefix("{") }),
              let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail(it, lines: job.tail + ["ERROR: could not read video information"])
            return
        }
        applyResolved(it, json)
        dirty = true
        scheduleSave()
    }

    /// Раскладывает вложенные списки (вкладки канала) в плоский список роликов.
    static func flatten(_ node: [String: Any], depth: Int = 0) -> [[String: Any]] {
        guard let entries = node["entries"] as? [Any] else { return [] }
        var out: [[String: Any]] = []
        for case let e as [String: Any] in entries {
            if e["entries"] != nil, depth < 3 {
                out += flatten(e, depth: depth + 1)
            } else if (e["ie_key"] as? String) == "YoutubeTab" || (e["_type"] as? String) == "playlist" {
                continue
            } else {
                out.append(e)
            }
        }
        return out
    }

    static func entryURL(_ e: [String: Any]) -> String? {
        for key in ["url", "webpage_url", "original_url"] {
            if let u = e[key] as? String, u.hasPrefix("http") { return u }
        }
        if let id = e["id"] as? String, (e["ie_key"] as? String) == "Youtube" {
            return "https://www.youtube.com/watch?v=" + id
        }
        return nil
    }

    static func thumbnail(of e: [String: Any]) -> String {
        if let t = e["thumbnail"] as? String, t.hasPrefix("http") { return t }
        if let list = e["thumbnails"] as? [[String: Any]] {
            // у YouTube последние в списке — самые крупные, но нам хватит и средних
            let urls = list.compactMap { $0["url"] as? String }.filter { $0.hasPrefix("http") }
            if let u = urls.first(where: { $0.contains("mqdefault") || $0.contains("hqdefault") }) { return u }
            if let u = urls.last { return u }
        }
        if let id = e["id"] as? String, let u = entryURL(e), Sites.isYouTube(u) {
            return "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"
        }
        return ""
    }

    static func number(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }

    func applyResolved(_ it: Item, _ json: [String: Any]) {
        let lang = settings.lang
        let isList = (json["_type"] as? String) == "playlist" || json["entries"] != nil

        if isList {
            let entries = Engine.flatten(json).filter { e in
                let title = (e["title"] as? String) ?? ""
                return title != "[Private video]" && title != "[Deleted video]"
            }
            if entries.isEmpty {
                fail(it, message: Loc.t(lang, "err.unavailable"), kind: .unavailable)
                return
            }
            if entries.count == 1, let url = Engine.entryURL(entries[0]) {
                applySingle(it, entries[0], url: url)
                return
            }
            expandPlaylist(it, json: json, entries: entries)
            return
        }
        applySingle(it, json, url: nil)
    }

    func applySingle(_ it: Item, _ e: [String: Any], url: String?) {
        let lang = settings.lang
        if (e["is_live"] as? Bool) == true || (e["live_status"] as? String) == "is_upcoming" {
            fail(it, message: Loc.t(lang, "err.live"), kind: .live)
            return
        }
        if let t = e["title"] as? String, !t.isEmpty { it.title = t }
        it.channel = (e["channel"] as? String) ?? (e["uploader"] as? String) ?? ""
        it.thumb = Engine.thumbnail(of: e)
        it.duration = jsonNum(Engine.number(e["duration"]))
        if let u = url { it.url = u }

        // Что будем качать: дорожки и их примерный размер — для составной полосы прогресса.
        var formats = (e["requested_formats"] as? [[String: Any]]) ?? []
        if formats.isEmpty { formats = [e] }
        var streams: [StreamInfo] = []
        var height = 0
        for f in formats {
            let v = (f["vcodec"] as? String) ?? "unknown"
            let isVideo = v != "none"
            var size = Engine.number(f["filesize"])
            if size == 0 { size = Engine.number(f["filesize_approx"]) }
            if size == 0, let tbr = f["tbr"] as? NSNumber, it.duration > 0 {
                size = tbr.doubleValue * 1000 / 8 * it.duration
            }
            streams.append(StreamInfo(kind: it.audioOnly ? "audio" : (isVideo ? "video" : "audio"),
                                      total: Int64(jsonNum(size)), done: 0, active: false, estimated: true))
            if isVideo { height = max(height, Int(Engine.number(f["height"]))) }
        }
        if !it.audioOnly, height > 0 { it.quality = "\(height)p" }
        Engine.fillUnknownSizes(&streams, duration: it.duration)
        it.streams = streams
        it.total = streams.reduce(Int64(0)) { $0 + $1.total }
        it.resolved = true
        it.error = ""
        it.status = nextStatusAfterResolve(it)
    }

    /// Размер дорожки не всегда известен заранее. Чтобы участок полосы не схлопнулся
    /// в ноль, подставляем прикидку: звук ≈ 128 кбит/с, видео — раз в девять больше.
    static func fillUnknownSizes(_ streams: inout [StreamInfo], duration: Double) {
        // одна дорожка без размера — полоса без сегментов, прогресс покажет сам yt-dlp
        if streams.count < 2 { 
            if streams.count == 1, streams[0].total == 0 { streams = [] }
            return
        }
        let audioGuess = duration > 0 ? Int64(16_000 * duration) : 1_000_000
        for i in streams.indices where streams[i].total == 0 {
            if streams[i].kind == "audio" {
                streams[i].total = audioGuess
            } else {
                let known = streams.filter { $0.kind == "audio" }.map { $0.total }.max() ?? audioGuess
                streams[i].total = max(known * 9, 1_000_000)
            }
        }
    }

    func nextStatusAfterResolve(_ it: Item) -> ItemStatus {
        let unmetered = netKind == .wifi || netKind == .ethernet
        switch it.deferMode {
        case "":
            return .queued
        case "wifi":
            if unmetered { it.deferMode = ""; return .queued }
            return .deferred
        default:
            return .deferred
        }
    }

    func expandPlaylist(_ it: Item, json: [String: Any], entries: [[String: Any]]) {
        let lang = settings.lang
        let gid = shortID()
        let title = (json["title"] as? String) ?? Sites.label(for: it.url)
        var created: [Item] = []
        for (n, e) in entries.enumerated() {
            guard let url = Engine.entryURL(e) else { continue }
            let child = Item(url: url, title: (e["title"] as? String) ?? Sites.host(of: url))
            child.channel = (e["channel"] as? String) ?? (e["uploader"] as? String) ?? (json["uploader"] as? String) ?? ""
            child.thumb = Engine.thumbnail(of: e)
            child.duration = jsonNum(Engine.number(e["duration"]))
            child.groupId = gid
            child.groupTitle = title
            child.audioOnly = it.audioOnly
            child.quality = it.quality
            child.format = it.format
            child.deferMode = it.deferMode
            child.deferTime = it.deferTime
            child.deferAt = it.deferAt
            child.noCookies = it.noCookies
            child.site = Sites.label(for: url)
            child.key = Sites.videoKey(url)
            child.isEntry = true
            child.resolved = true
            child.added = it.added + Double(n) * 0.0001
            child.status = nextStatusAfterResolve(child)
            // ролики, которые уже в очереди, не дублируем
            if items.contains(where: { $0.key == child.key && $0.id != it.id }) { continue }
            created.append(child)
        }
        for c in created { c.groupTotal = created.count }
        items.removeAll { $0.id == it.id }
        items.append(contentsOf: created)
        emitToast(Loc.t(lang, "Playlist “{title}”: {n} videos", ["title": title, "n": String(created.count)]))
        if json["playlist_count"] as? Int == ArgsBuilder.maxPlaylist || created.count >= ArgsBuilder.maxPlaylist {
            emitToast(Loc.t(lang, "Only the first {n} were added", ["n": String(ArgsBuilder.maxPlaylist)]))
        }
    }

    // MARK: - загрузка

    func startDownload(_ it: Item) {
        guard tools.hasYtdlp else {
            fail(it, message: Loc.t(settings.lang, "err.noYtdlp"), kind: .generic)
            return
        }
        let printFile = AppPaths.cacheDir.appendingPathComponent("out-\(it.id).txt").path
        try? FileManager.default.removeItem(atPath: printFile)

        let spec = DownloadSpec(url: it.url, audioOnly: it.audioOnly, quality: it.quality,
                                sectionFrom: it.isEntry ? "" : it.sectionFrom,
                                sectionTo: it.isEntry ? "" : it.sectionTo,
                                noCookies: it.noCookies, groupTitle: it.groupTitle,
                                printFile: printFile, tempDir: tempDirPath(for: it.id),
                                fallback: it.fallback)
        let args = ArgsBuilder.downloadArgs(spec, settings: settings, tools: tools)

        // Полосу прогресса начинаем заново: yt-dlp сам докачает .part, а счётчик покажет остаток.
        var streams = it.streams
        for i in streams.indices { streams[i].done = 0; streams[i].active = false }
        var tracker = ProgressTracker(streams: streams)
        if it.audioOnly { tracker.forcedKind = "audio" }
        let job = Job(kind: .download, tracker: tracker)
        job.printFile = printFile
        job.tempDir = spec.tempDir
        jobs[it.id] = job

        it.status = .downloading
        it.stage = it.audioOnly ? "audio" : "video"
        it.speed = 0
        it.eta = 0
        it.error = ""
        it.rawError = ""
        dirty = true

        let id = it.id
        Log.shared.write("download \(it.url) quality=\(it.quality) audio=\(it.audioOnly)")
        do {
            job.process = try RunningProcess.start(
                exe: tools.ytdlp, args: args, env: ArgsBuilder.environment(tools: tools),
                onStdout: { [weak self] line in self?.q.async { self?.handleLine(id: id, job: job, line: line) } },
                onStderr: { [weak self] line in self?.q.async { self?.handleLine(id: id, job: job, line: line) } },
                onExit: { [weak self] code in self?.q.async { self?.finishDownload(id: id, job: job, code: code) } })
        } catch {
            jobs[id] = nil
            fail(it, message: Loc.t(settings.lang, "err.generic"), kind: .generic, raw: "\(error)")
        }
    }

    func handleLine(id: String, job: Job, line: String) {
        guard let it = item(id), jobs[id] === job else { return }
        let event = ProgressParser.parse(line)
        switch event {
        case .progress(let p):
            if job.finishing { return }
            if job.firstProgressAt == nil {
                job.firstProgressAt = Date()
                Log.shared.write("download: first progress after \(job.elapsed) (yt-dlp startup + extraction)")
            }
            let snap = job.tracker.update(p)
            it.downloaded = snap.downloaded
            it.total = snap.total
            it.pct = snap.pct
            it.speed = jsonNum(snap.speed)
            it.eta = jsonNum(snap.eta)
            it.stage = it.audioOnly ? "audio" : snap.stage
            it.streams = job.tracker.streams
        case .destination(let path):
            job.destinations.append(path)
            if !it.tempFiles.contains(path) { it.tempFiles.append(path) }
        case .merging(let path):
            job.finalPath = path
            enterFinishing(it, job, stage: "merge")
        case .postprocess(let path):
            if !path.isEmpty { job.finalPath = path }
            enterFinishing(it, job, stage: it.audioOnly ? "convert" : "merge")
        case .alreadyDownloaded(let path):
            job.finalPath = path
            job.addTail(line)
        case .error:
            job.addTail(line)
            Log.shared.write(line)
        case .other:
            job.addTail(line)
            if line.hasPrefix("WARNING") { Log.shared.write(line) }
        }
        dirty = true
    }

    func enterFinishing(_ it: Item, _ job: Job, stage: String) {
        if !job.finishing {
            job.finishing = true
            job.finishingAt = Date()
            job.tracker.complete()
            it.streams = job.tracker.streams
            it.pct = 100
            if it.total > 0 { it.downloaded = it.total }
        }
        it.stage = stage
        it.speed = 0
        it.eta = 0
    }

    func finishDownload(id: String, job: Job, code: Int32) {
        jobs[id] = nil
        defer { try? FileManager.default.removeItem(atPath: job.printFile) }
        guard let it = item(id) else {
            // загрузку отменили: убираем недокачанные файлы
            if job.intent == .cancel {
                removeTempFiles(job.destinations)
                removeTempDir(job.tempDir)
            }
            return
        }
        it.speed = 0
        it.eta = 0
        if job.intent == .none {
            var parts = ["total \(job.elapsed)"]
            if let f = job.firstProgressAt {
                parts.append("preparation \(Job.seconds(f.timeIntervalSince(job.started)))")
                parts.append("transfer \(Job.seconds((job.finishingAt ?? Date()).timeIntervalSince(f)))")
            }
            if let fin = job.finishingAt { parts.append("finishing \(Job.seconds(Date().timeIntervalSince(fin)))") }
            Log.shared.write("download finished exit=\(code): " + parts.joined(separator: ", "))
        }
        switch job.intent {
        case .pause, .defer_, .shutdown:
            dirty = true
            scheduleSave()
            return
        case .cancel:
            removeTempFiles(job.destinations)
            removeTempDir(job.tempDir)
            return
        case .none:
            break
        }
        if code == 0 {
            complete(it, job)
        } else {
            fail(it, lines: job.tail)
        }
    }

    func resultPath(_ job: Job) -> String {
        if let text = try? String(contentsOfFile: job.printFile, encoding: .utf8) {
            let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if let last = lines.last(where: { FileManager.default.fileExists(atPath: $0) }) ?? lines.last { return last }
        }
        if !job.finalPath.isEmpty { return job.finalPath }
        return job.destinations.last ?? ""
    }

    func complete(_ it: Item, _ job: Job) {
        let path = resultPath(job)
        let size = fileSize(atPath: path) ?? it.total
        let ext = (path as NSString).pathExtension.lowercased()
        let entry = HistoryEntry(
            id: it.id, url: it.url, title: it.title, channel: it.channel, thumb: it.thumb,
            duration: it.duration, quality: it.quality,
            format: ext.isEmpty ? it.format : ext, filepath: path, total: size,
            finished: Date().timeIntervalSince1970, key: it.key, site: it.site)
        history.removeAll { $0.id == it.id }
        history.insert(entry, at: 0)
        if history.count > settings.keepHistory { history.removeLast(history.count - settings.keepHistory) }
        items.removeAll { $0.id == it.id }
        removeTempDir(job.tempDir)
        Log.shared.write("done \(path) (\(size) bytes)")

        let lang = settings.lang
        if !it.groupId.isEmpty {
            if !items.contains(where: { $0.groupId == it.groupId }) {
                emitNotification(title: Loc.t(lang, "Playlist complete"),
                                 body: it.groupTitle + " · " + Loc.t(lang, "{n} videos", ["n": String(it.groupTotal)]),
                                 path: path)
            }
        } else {
            emitNotification(title: Loc.t(lang, "Download complete"), body: it.title, path: path)
        }
        dirty = true
        scheduleSave()
    }

    // MARK: - ошибки

    func fail(_ it: Item, message: String, kind: ErrorKind, raw: String = "") {
        it.status = .error
        it.error = message
        it.rawError = raw
        it.errorKind = kind.rawValue
        it.speed = 0
        it.eta = 0
        dirty = true
        scheduleSave()
    }

    func fail(_ it: Item, lines: [String]) {
        let lang = settings.lang
        let c = ErrorClassifier.classify(lines: lines, lang: lang)
        Log.shared.write("fail \(it.url) kind=\(c.kind.rawValue) :: \(c.raw)")
        let text = c.raw.lowercased()

        // Куки не читаются — пробуем без них, один раз.
        if c.kind == .cookies, settings.cookieBrowser != "none", !it.noCookies {
            it.noCookies = true
            requeue(it)
            return
        }
        // Отказ 403 (чаще всего посреди загрузки: ссылка на видео «протухла»). Лесенка, пока не показали ошибку:
        // 1) просто повторить — yt-dlp возьмёт новые ссылки и докачает начатое;
        // 2) на YouTube — запасной набор клиентов (плееров);
        // 3) ниже — обновить yt-dlp.
        if c.kind == .forbidden, tools.hasYtdlp {
            if it.forbiddenRetries < 1 {
                it.forbiddenRetries += 1
                it.notBefore = Date().timeIntervalSince1970 + 3
                requeue(it)
                return
            }
            if Sites.isYouTube(it.url), it.fallback == 0 {
                it.fallback = 1
                it.notBefore = Date().timeIntervalSince1970 + 3
                requeue(it)
                return
            }
        }
        // Старый yt-dlp — самая частая причина 403 и «unable to extract». Обновляем и повторяем один раз.
        let looksOutdated = c.kind == .forbidden || c.kind == .jsRuntime || text.contains("unable to extract")
        if looksOutdated, settings.autoUpdate, !it.updateRetried, !sessionUpdateDone, tools.hasYtdlp {
            it.updateRetried = true
            requeue(it)
            runUpdate(manual: false)
            return
        }
        // Сеть мигнула — пробуем ещё, с паузой.
        if c.kind == .network, it.attempts < 3 {
            it.attempts += 1
            it.notBefore = Date().timeIntervalSince1970 + Double(5 * it.attempts)
            requeue(it)
            return
        }
        fail(it, message: c.message, kind: c.kind, raw: c.raw)
        emitNotification(title: Loc.t(lang, "Download failed"), body: it.title, path: "")
    }

    func requeue(_ it: Item) {
        it.status = it.resolved ? .queued : .resolving
        it.error = ""
        dirty = true
        scheduleSave()
    }
}
