import Foundation

/// Настройки приложения. Хранятся в settings.json; незнакомые и
/// отсутствующие поля не ломают чтение — берётся значение по умолчанию.
public struct Settings: Codable, Equatable {
    public var folder: String = AppPaths.defaultDownloadFolder
    public var defaultQuality: String = "1080p"      // best | 1440p | 1080p | 720p | 480p
    public var maxParallel: Int = 2                  // 1, 2, 3, 4, 6
    public var speedLimit: String = ""               // "" | 1M | 3M | 5M | 10M
    public var organize: String = "none"             // none | channel | playlist
    public var codec: String = "h264"                // h264 | any | av1; h264 открывается в QuickTime
    public var cookieBrowser: String = "none"        // chrome | firefox | safari | edge | brave | none
    public var filenameTemplate: String = Settings.defaultTemplate
    public var subtitles: String = "none"            // none | ru,en | all
    public var subsEmbed: Bool = true
    public var chapters: Bool = true
    public var sponsorblock: Bool = false
    public var wifiOnly: Bool = false
    public var autoResume: Bool = true
    public var clipboardWatch: Bool = true
    public var autoUpdate: Bool = true
    public var notify: Bool = true
    public var dockBadge: Bool = true
    public var menuBar: Bool = true
    public var theme: String = "dark"                // dark | light
    public var density: String = "normal"            // normal | compact | list
    public var accent: String = "#007AFF"
    public var language: String = "auto"             // auto | ru | en | de | fr | es
    public var keepHistory: Int = 300
    public var lastUpdateCheck: Double = 0
    public var onboarded: Bool = false
    /// Версия схемы настроек: 2 — кодек по умолчанию H.264 (раньше «любой» отдавал VP9/AV1, которые QuickTime не открывает).
    public var schema: Int = 2

    public static let defaultTemplate = "%(title)s [%(id)s].%(ext)s"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case folder, defaultQuality, maxParallel, speedLimit, organize, codec, cookieBrowser
        case filenameTemplate, subtitles, subsEmbed, chapters, sponsorblock, wifiOnly, autoResume
        case clipboardWatch, autoUpdate, notify, dockBadge, menuBar, theme, density, accent
        case language, keepHistory, lastUpdateCheck, onboarded, schema
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? current
        }
        folder = get(.folder, folder)
        defaultQuality = get(.defaultQuality, defaultQuality)
        maxParallel = get(.maxParallel, maxParallel)
        speedLimit = get(.speedLimit, speedLimit)
        organize = get(.organize, organize)
        codec = get(.codec, codec)
        cookieBrowser = get(.cookieBrowser, cookieBrowser)
        filenameTemplate = get(.filenameTemplate, filenameTemplate)
        subtitles = get(.subtitles, subtitles)
        subsEmbed = get(.subsEmbed, subsEmbed)
        chapters = get(.chapters, chapters)
        sponsorblock = get(.sponsorblock, sponsorblock)
        wifiOnly = get(.wifiOnly, wifiOnly)
        autoResume = get(.autoResume, autoResume)
        clipboardWatch = get(.clipboardWatch, clipboardWatch)
        autoUpdate = get(.autoUpdate, autoUpdate)
        notify = get(.notify, notify)
        dockBadge = get(.dockBadge, dockBadge)
        menuBar = get(.menuBar, menuBar)
        theme = get(.theme, theme)
        density = get(.density, density)
        accent = get(.accent, accent)
        language = get(.language, language)
        keepHistory = get(.keepHistory, keepHistory)
        lastUpdateCheck = get(.lastUpdateCheck, lastUpdateCheck)
        onboarded = get(.onboarded, onboarded)
        schema = get(.schema, 1)
        if schema < 2 {
            // «любой кодек» из прежних версий — это был выбор по умолчанию, а не осознанный: возвращаем совместимый H.264
            if codec == "any" { codec = "h264" }
            schema = 2
        }
        sanitize()
    }

    /// Приводит значения к допустимым.
    mutating func sanitize() {
        if ![1, 2, 3, 4, 6].contains(maxParallel) { maxParallel = 2 }
        if !["none", "channel", "playlist"].contains(organize) { organize = "none" }
        if !["any", "h264", "av1"].contains(codec) { codec = "any" }
        if !["dark", "light"].contains(theme) { theme = "dark" }
        if !["normal", "compact", "list"].contains(density) { density = "normal" }
        if !["none", "ru,en", "all"].contains(subtitles) { subtitles = "none" }
        if folder.isEmpty { folder = AppPaths.defaultDownloadFolder }
        if filenameTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
            filenameTemplate = Settings.defaultTemplate
        }
        if keepHistory < 20 { keepHistory = 20 }
        if keepHistory > 5000 { keepHistory = 5000 }
        folder = expandTilde(folder)
    }

    /// Применяет патч от интерфейса. Возвращает названия изменённых полей.
    @discardableResult
    public mutating func apply(patch: [String: Any]) -> [String] {
        var changed: [String] = []
        func str(_ k: String) -> String? { patch[k] as? String }
        func bool(_ k: String) -> Bool? {
            if let b = patch[k] as? Bool { return b }
            if let n = patch[k] as? NSNumber { return n.boolValue }
            return nil
        }
        func int(_ k: String) -> Int? {
            if let n = patch[k] as? NSNumber { return n.intValue }
            if let s = patch[k] as? String { return Int(s) }
            return nil
        }
        func set<T: Equatable>(_ key: String, _ target: inout T, _ value: T?) {
            if let v = value, v != target { target = v; changed.append(key) }
        }
        set("folder", &folder, str("folder"))
        set("defaultQuality", &defaultQuality, str("defaultQuality"))
        set("maxParallel", &maxParallel, int("maxParallel"))
        set("speedLimit", &speedLimit, str("speedLimit"))
        set("organize", &organize, str("organize"))
        set("codec", &codec, str("codec"))
        set("cookieBrowser", &cookieBrowser, str("cookieBrowser"))
        set("filenameTemplate", &filenameTemplate, str("filenameTemplate"))
        set("subtitles", &subtitles, str("subtitles"))
        set("subsEmbed", &subsEmbed, bool("subsEmbed"))
        set("chapters", &chapters, bool("chapters"))
        set("sponsorblock", &sponsorblock, bool("sponsorblock"))
        set("wifiOnly", &wifiOnly, bool("wifiOnly"))
        set("autoResume", &autoResume, bool("autoResume"))
        set("clipboardWatch", &clipboardWatch, bool("clipboardWatch"))
        set("autoUpdate", &autoUpdate, bool("autoUpdate"))
        set("notify", &notify, bool("notify"))
        set("dockBadge", &dockBadge, bool("dockBadge"))
        set("menuBar", &menuBar, bool("menuBar"))
        set("theme", &theme, str("theme"))
        set("density", &density, str("density"))
        set("accent", &accent, str("accent"))
        set("language", &language, str("language"))
        set("keepHistory", &keepHistory, int("keepHistory"))
        set("onboarded", &onboarded, bool("onboarded"))
        sanitize()
        return changed
    }

    /// То, что получает интерфейс.
    public var uiJSON: [String: Any] {
        [
            "folder": folder,
            "defaultQuality": defaultQuality,
            "maxParallel": maxParallel,
            "speedLimit": speedLimit,
            "organize": organize,
            "codec": codec,
            "cookieBrowser": cookieBrowser,
            "filenameTemplate": filenameTemplate,
            "subtitles": subtitles,
            "subsEmbed": subsEmbed,
            "chapters": chapters,
            "sponsorblock": sponsorblock,
            "wifiOnly": wifiOnly,
            "autoResume": autoResume,
            "clipboardWatch": clipboardWatch,
            "autoUpdate": autoUpdate,
            "notify": notify,
            "dockBadge": dockBadge,
            "menuBar": menuBar,
            "theme": theme,
            "density": density,
            "accent": accent,
            "language": language,
            "onboarded": onboarded,
        ]
    }

    /// Язык оболочки: настройка или язык системы.
    public var lang: String { Loc.resolve(language) }
}
