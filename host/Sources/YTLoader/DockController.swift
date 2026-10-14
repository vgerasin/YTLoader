import AppKit
import CoreImage
import YTLoaderCore

/// Значок в Dock: красится в акцентный цвет, во время загрузки показывает полосу прогресса и счётчик.
final class DockController {
    private var original: NSImage?
    private var tintedFor = ""
    private var tinted: NSImage?
    private var view: DockProgressView?
    private var shownProgress = false

    /// Базовый оттенок значка (синий #007AFF), от него считается поворот к акценту.
    private let baseHue: CGFloat = 0.586

    func captureOriginalIcon() {
        original = NSApp.applicationIconImage
    }

    func update(_ s: EngineSummary) {
        applyTint(accent: s.accent)

        let busy = s.active + s.queued
        let tile = NSApp.dockTile
        if s.dockBadge && s.active > 0 {
            if view == nil || !shownProgress {
                let v = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
                view = v
                tile.contentView = v
                shownProgress = true
            }
            view?.icon = tinted ?? original
            view?.progress = Double(s.overallPct) / 100
            view?.accent = Self.color(hex: s.accent)
            tile.badgeLabel = busy > 1 ? String(busy) : nil
            tile.display()
        } else if shownProgress {
            tile.contentView = nil
            tile.badgeLabel = nil
            shownProgress = false
            view = nil
            tile.display()
        } else if s.dockBadge, s.failed > 0 {
            tile.badgeLabel = "!"
        } else {
            tile.badgeLabel = nil
        }
    }

    private func applyTint(accent: String) {
        guard accent != tintedFor, let base = original else { return }
        tintedFor = accent
        let color = Self.color(hex: accent)
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        let angle = (hue - baseHue) * 2 * .pi

        if abs(angle) < 0.03 {
            tinted = nil
            NSApp.applicationIconImage = base
            return
        }
        guard let tiff = base.tiffRepresentation, let ci = CIImage(data: tiff),
              let filter = CIFilter(name: "CIHueAdjust") else { return }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(angle, forKey: kCIInputAngleKey)
        guard let out = filter.outputImage else { return }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: base.size)
        image.addRepresentation(rep)
        tinted = image
        NSApp.applicationIconImage = image
    }

    static func color(hex: String) -> NSColor {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else {
            return NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Содержимое плитки Dock: иконка и полоса прогресса снизу.
final class DockProgressView: NSView {
    var icon: NSImage?
    var progress: Double = 0
    var accent: NSColor = .systemBlue

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: bounds)

        let w = bounds.width * 0.78
        let h = bounds.height * 0.085
        let track = NSRect(x: (bounds.width - w) / 2, y: bounds.height * 0.07, width: w, height: h)
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()

        let filled = NSRect(x: track.minX, y: track.minY, width: max(h, w * CGFloat(min(1, max(0, progress)))), height: h)
        accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: h / 2, yRadius: h / 2).fill()
    }
}
