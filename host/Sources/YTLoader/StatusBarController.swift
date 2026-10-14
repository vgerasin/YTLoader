import AppKit
import YTLoaderCore

/// Значок в строке меню: скорость и список активных загрузок.
final class StatusBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var summary = EngineSummary()
    private let openAction: () -> Void
    private let pauseAction: () -> Void
    private let resumeAction: () -> Void

    init(open: @escaping () -> Void, pauseAll: @escaping () -> Void, resumeAll: @escaping () -> Void) {
        openAction = open
        pauseAction = pauseAll
        resumeAction = resumeAll
        super.init()
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = it.button {
            let image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "YTLoader")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
        let menu = NSMenu()
        menu.delegate = self
        it.menu = menu
        item = it
    }

    func update(_ s: EngineSummary) {
        summary = s
        guard let button = item?.button else { return }
        if s.active > 0 {
            button.title = " \(s.overallPct)%"
        } else if s.queued > 0 {
            button.title = " \(s.queued)"
        } else {
            button.title = ""
        }
    }

    func remove() {
        if let it = item { NSStatusBar.system.removeStatusItem(it) }
        item = nil
    }

    // MARK: - меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let l = summary.lang

        if summary.running.isEmpty {
            let none = NSMenuItem(title: Loc.t(l, "Nothing is downloading"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for r in summary.running {
                let title = r.title.count > 46 ? String(r.title.prefix(45)) + "…" : r.title
                let row = NSMenuItem(title: "\(title) — \(r.pct)%", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())

        let open = NSMenuItem(title: Loc.t(l, "Open YTLoader"), action: #selector(doOpen), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        if summary.active + summary.queued > 0 {
            let pause = NSMenuItem(title: Loc.t(l, "Pause All"), action: #selector(doPause), keyEquivalent: "")
            pause.target = self
            menu.addItem(pause)
        }
        if summary.paused > 0 {
            let resume = NSMenuItem(title: Loc.t(l, "Resume All"), action: #selector(doResume), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: Loc.t(l, "Quit YTLoader"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func doOpen() { openAction() }
    @objc private func doPause() { pauseAction() }
    @objc private func doResume() { resumeAction() }
}
