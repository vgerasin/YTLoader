import AppKit
import WebKit
import Network
import UserNotifications
import YTLoaderCore

/// Не даёт WKUserContentController удерживать делегата (иначе окно никогда не освободится).
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate,
                         WKScriptMessageHandler, EngineDelegate, UNUserNotificationCenterDelegate {
    var core: Engine!
    var window: NSWindow!
    var web: WKWebView!
    var pageLoaded = false
    var pendingState: String?
    var summary = EngineSummary()
    var lang = Loc.systemLanguage()
    var appliedTheme = ""
    var appliedLang = ""
    var lastPasteboardCount = NSPasteboard.general.changeCount
    var queuedURLs: [URL] = []
    var monitor: NWPathMonitor?
    var statusBar: StatusBarController?
    var dock = DockController()
    var notificationsAsked = false

    // MARK: - запуск

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.write("YTLoader \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "dev") launching")
        core = Engine(delegate: self)
        dock.captureOriginalIcon()
        buildWindow()
        buildMenu()
        startNetworkMonitor()
        if canUseNotifications { UNUserNotificationCenter.current().delegate = self }
        core.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateWindowInfo()

        let urls = queuedURLs
        queuedURLs = []
        for u in urls { handle(url: u) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkClipboard()
        flushPending()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard core != nil else { queuedURLs += urls; return }
        for u in urls { handle(url: u) }
    }

    /// ytloader://add?url=https://…&quality=720p&audio=1
    func handle(url: URL) {
        guard url.scheme == "ytloader" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let target = q("url") ?? q("text"), !target.isEmpty else { return }
        var body: [String: Any] = ["text": target]
        if let quality = q("quality") { body["quality"] = quality }
        if let a = q("audio") { body["audioOnly"] = (a == "1" || a == "true") }
        core.handle(path: "/api/add", body: body)
        showWindow()
    }

    func showWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        flushPending()
    }

    // MARK: - окно

    func locateUI() -> URL? {
        if let u = Bundle.main.url(forResource: "ui", withExtension: "html") { return u }
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["YTLOADER_UI"] { candidates.append(env) }
        candidates.append(fm.currentDirectoryPath + "/app/Resources/ui.html")
        candidates.append(fm.currentDirectoryPath + "/../app/Resources/ui.html")
        return candidates.first { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func buildWindow() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakScriptHandler(self), name: "ytl")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "YTLoader"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = web
        applyAppearance(theme: "dark")
        if !window.setFrameUsingName("YTLoaderMain") { window.center() }
        window.setFrameAutosaveName("YTLoaderMain")

        if let ui = locateUI() {
            web.loadFileURL(ui, allowingReadAccessTo: ui.deletingLastPathComponent())
        } else {
            let alert = NSAlert()
            alert.messageText = "ui.html not found"
            alert.informativeText = "Resources/ui.html is missing from the application bundle."
            alert.runModal()
        }
    }

    func applyAppearance(theme: String) {
        guard theme != appliedTheme else { return }
        appliedTheme = theme
        if theme == "light" {
            window.backgroundColor = NSColor(srgbRed: 0xE8 / 255, green: 0xE8 / 255, blue: 0xEE / 255, alpha: 1)
            window.appearance = NSAppearance(named: .aqua)
        } else {
            window.backgroundColor = NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x1B / 255, alpha: 1)
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func updateWindowInfo() {
        let s = window.contentView?.bounds.size ?? window.frame.size
        core.setWindowInfo("\(Int(s.width))×\(Int(s.height))")
    }

    func windowDidResize(_ notification: Notification) { updateWindowInfo() }
    func windowDidChangeOcclusionState(_ notification: Notification) { flushPending() }
    func windowDidDeminiaturize(_ notification: Notification) { flushPending() }

    // MARK: - страница

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        core.requestPush()
        flushPending()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.checkClipboard() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.shared.write("web content process terminated; reloading")
        pageLoaded = false
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    var windowShowsContent: Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    func flushPending() {
        guard pageLoaded, windowShowsContent, let json = pendingState else { return }
        pendingState = nil
        web.evaluateJavaScript("window.applyState && window.applyState(\(json))", completionHandler: nil)
    }

    /// Вызов функции страницы с одним JSON-аргументом.
    func call(_ fn: String, _ arg: Any) {
        guard pageLoaded else { return }
        let data: Data?
        if let s = arg as? String {
            data = try? JSONEncoder().encode(s)
        } else if JSONSerialization.isValidJSONObject(arg) {
            data = try? JSONSerialization.data(withJSONObject: arg)
        } else {
            data = nil
        }
        guard let d = data, let js = String(data: d, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.\(fn) && window.\(fn)(\(js))", completionHandler: nil)
    }

    // MARK: - мост: интерфейс → оболочка

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let path = dict["path"] as? String else { return }
        let body = dict["body"] as? [String: Any] ?? [:]
        switch path {
        case "/api/chooseFolder": chooseFolder()
        case "/api/reveal": reveal(body["path"] as? String ?? "")
        case "/api/openLog": NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logFile])
        case "/api/readLog":
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let text = Log.shared.tail()
                DispatchQueue.main.async { self?.call("showLog", text) }
            }
        case "/api/add":
            core.handle(path: path, body: body)
            requestNotificationsIfNeeded()
        default:
            core.handle(path: path, body: body)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = Loc.t(lang, "Choose")
        panel.message = Loc.t(lang, "Download folder")
        if !summary.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: summary.folder) }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.core.setFolder(url.path) }
        }
    }

    func reveal(_ path: String) {
        let fm = FileManager.default
        if !path.isEmpty, fm.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        let dir = (path as NSString).deletingLastPathComponent
        if !path.isEmpty, fm.fileExists(atPath: dir) {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
            core.toast(Loc.t(lang, "File not found"))
            return
        }
        core.toast(Loc.t(lang, "File not found"))
    }

    // MARK: - EngineDelegate: оболочка → интерфейс

    func engine(push json: String, summary: EngineSummary) {
        self.summary = summary
        if summary.lang != lang {
            lang = summary.lang
        }
        applyAppearance(theme: summary.theme)
        if appliedLang != lang {
            appliedLang = lang
            buildMenu()
        }
        dock.update(summary)
        updateStatusBar()

        pendingState = json
        flushPending()
    }

    func engine(notifyTitle: String, body: String, path: String) {
        guard canUseNotifications else { return }
        // не шумим, пока пользователь смотрит в окно
        if NSApp.isActive && windowShowsContent { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notifyTitle
        content.body = body
        content.sound = .default
        content.userInfo = ["path": path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error { Log.shared.write("notification failed: \(error)") }
        }
    }

    func engine(askDuplicate payload: [String: Any]) {
        showWindow()
        call("askDuplicate", payload)
    }

    // MARK: - уведомления

    var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func requestNotificationsIfNeeded() {
        guard canUseNotifications, !notificationsAsked, summary.notify else { return }
        notificationsAsked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["path"] as? String ?? ""
        DispatchQueue.main.async { [weak self] in
            if path.isEmpty { self?.showWindow() } else { self?.reveal(path) }
        }
        completionHandler()
    }

    // MARK: - сеть и буфер обмена

    func startNetworkMonitor() {
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let l = self.lang
            var kind = "ethernet"
            var label = Loc.t(l, "Network")
            if path.status != .satisfied {
                kind = "none"
                label = ""
            } else if path.usesInterfaceType(.wifi) {
                if path.isExpensive { kind = "cellular"; label = Loc.t(l, "Hotspot") }
                else { kind = "wifi"; label = "Wi-Fi" }
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = "ethernet"
                label = "Ethernet"
            } else if path.usesInterfaceType(.cellular) {
                kind = "cellular"
                label = Loc.t(l, "Cellular")
            }
            self.core.setNetwork(kind: kind, label: label)
        }
        mon.start(queue: DispatchQueue(label: "ytloader.network"))
        monitor = mon
    }

    func checkClipboard() {
        guard pageLoaded else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        guard let text = pb.string(forType: .string), !text.isEmpty, text.count < 4000 else { return }
        core.clipboardCandidate(text) { [weak self] url in
            if let url = url { self?.call("suggestLink", url) }
        }
    }

    // MARK: - меню

    func buildMenu() {
        let l = lang
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        appItem.submenu = app
        app.addItem(withTitle: Loc.t(l, "About YTLoader"),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let prefs = NSMenuItem(title: Loc.t(l, "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        app.addItem(prefs)
        app.addItem(.separator())
        app.addItem(withTitle: Loc.t(l, "Hide YTLoader"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = NSMenuItem(title: Loc.t(l, "Hide Others"),
                                action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(others)
        app.addItem(withTitle: Loc.t(l, "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: Loc.t(l, "Quit YTLoader"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: Loc.t(l, "Edit"))
        editItem.submenu = edit
        edit.addItem(withTitle: Loc.t(l, "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: Loc.t(l, "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: Loc.t(l, "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: Loc.t(l, "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: Loc.t(l, "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: Loc.t(l, "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: Loc.t(l, "Window"))
        winItem.submenu = win
        win.addItem(withTitle: Loc.t(l, "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: Loc.t(l, "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(withTitle: Loc.t(l, "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    @objc func openSettings() {
        showWindow()
        web.evaluateJavaScript("(function(){var g=document.querySelector('#gear');if(g)g.click();})()",
                               completionHandler: nil)
    }

    // MARK: - строка меню

    func updateStatusBar() {
        if summary.menuBar {
            if statusBar == nil {
                statusBar = StatusBarController(
                    open: { [weak self] in self?.showWindow() },
                    pauseAll: { [weak self] in self?.core.handle(path: "/api/pauseAll", body: [:]) },
                    resumeAll: { [weak self] in self?.core.handle(path: "/api/resumeAll", body: [:]) })
            }
            statusBar?.update(summary)
        } else if statusBar != nil {
            statusBar?.remove()
            statusBar = nil
        }
    }
}
