import Foundation

/// Тексты, которые показывает сама оболочка (ошибки, уведомления, меню).
/// Ключ — английская строка; для английского возвращается она же.
public enum Loc {
    public static let supported = ["ru", "en", "de", "fr", "es"]

    /// "auto" → язык системы, если он поддерживается, иначе английский.
    public static func resolve(_ setting: String, system: [String]? = nil) -> String {
        if supported.contains(setting) { return setting }
        let prefs = system ?? Locale.preferredLanguages
        for p in prefs {
            let code = String(p.prefix(2)).lowercased()
            if supported.contains(code) { return code }
        }
        return "en"
    }

    public static func systemLanguage() -> String { resolve("auto") }

    public static func t(_ lang: String, _ key: String, _ vars: [String: String] = [:]) -> String {
        var out = key
        if let row = table[key], let tr = row[lang] { out = tr }
        for (k, v) in vars { out = out.replacingOccurrences(of: "{" + k + "}", with: v) }
        return out
    }

    /// «Сегодня 14:05», «Вчера 09:12», «12 окт».
    public static func dateLabel(_ date: Date, lang: String, now: Date = Date()) -> String {
        let cal = Calendar.current
        let tf = DateFormatter()
        tf.locale = Locale(identifier: lang)
        tf.dateFormat = "HH:mm"
        if cal.isDate(date, inSameDayAs: now) {
            return t(lang, "Today") + " " + tf.string(from: date)
        }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) {
            return t(lang, "Yesterday") + " " + tf.string(from: date)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: lang)
        df.setLocalizedDateFormatFromTemplate(cal.isDate(date, equalTo: now, toGranularity: .year) ? "d MMM" : "d MMM yyyy")
        return df.string(from: date)
    }

    static let table: [String: [String: String]] = [
        // --- даты
        "Today": ["ru": "Сегодня", "de": "Heute", "fr": "Aujourd’hui", "es": "Hoy"],
        "Yesterday": ["ru": "Вчера", "de": "Gestern", "fr": "Hier", "es": "Ayer"],

        // --- ошибки загрузки
        "err.ffmpeg": [
            "en": "ffmpeg is required. Install it in the setup wizard (Settings → Diagnostics).",
            "ru": "Нужен ffmpeg. Установите его в мастере первого запуска (Настройки → Диагностика).",
            "de": "ffmpeg wird benötigt. Installiere es im Einrichtungsassistenten (Einstellungen → Diagnose).",
            "fr": "ffmpeg est requis. Installez-le dans l’assistant (Réglages → Diagnostic).",
            "es": "Hace falta ffmpeg. Instálalo en el asistente (Ajustes → Diagnóstico).",
        ],
        "err.jsRuntime": [
            "en": "No JavaScript engine (deno). Without it YouTube returns links that fail with 403. Install it in the setup wizard.",
            "ru": "Нет JavaScript-движка (deno). Без него YouTube отдаёт ссылки с ошибкой 403. Установите его в мастере.",
            "de": "Keine JavaScript-Engine (deno). Ohne sie liefert YouTube Links mit Fehler 403. Im Assistenten installieren.",
            "fr": "Pas de moteur JavaScript (deno). Sans lui, YouTube renvoie des liens en erreur 403. Installez-le dans l’assistant.",
            "es": "Falta un motor de JavaScript (deno). Sin él YouTube devuelve enlaces con error 403. Instálalo en el asistente.",
        ],
        "err.bot": [
            "en": "The site asks you to confirm you are not a bot. Turn on browser cookies in Settings or update yt-dlp.",
            "ru": "Сайт просит подтвердить, что вы не робот. Включите cookies браузера в настройках или обновите yt-dlp.",
            "de": "Die Seite verlangt den Nachweis, dass du kein Bot bist. Aktiviere Browser-Cookies in den Einstellungen oder aktualisiere yt-dlp.",
            "fr": "Le site demande de prouver que vous n’êtes pas un robot. Activez les cookies du navigateur dans les réglages ou mettez à jour yt-dlp.",
            "es": "El sitio pide confirmar que no eres un robot. Activa las cookies del navegador en Ajustes o actualiza yt-dlp.",
        ],
        "err.age": [
            "en": "Age-restricted video. Pick a browser for cookies in Settings.",
            "ru": "Видео с возрастным ограничением. Выберите браузер для cookies в настройках.",
            "de": "Altersbeschränktes Video. Wähle in den Einstellungen einen Browser für Cookies.",
            "fr": "Vidéo soumise à une limite d’âge. Choisissez un navigateur pour les cookies dans les réglages.",
            "es": "Vídeo con restricción de edad. Elige un navegador para las cookies en Ajustes.",
        ],
        "err.private": [
            "en": "The video is private or requires signing in. Pick a browser for cookies in Settings.",
            "ru": "Видео приватное или требует входа в аккаунт. Выберите браузер для cookies в настройках.",
            "de": "Das Video ist privat oder erfordert eine Anmeldung. Wähle in den Einstellungen einen Browser für Cookies.",
            "fr": "La vidéo est privée ou demande une connexion. Choisissez un navigateur pour les cookies dans les réglages.",
            "es": "El vídeo es privado o requiere iniciar sesión. Elige un navegador para las cookies en Ajustes.",
        ],
        "err.geo": [
            "en": "The video is not available in your country.",
            "ru": "Видео недоступно в вашей стране.",
            "de": "Das Video ist in deinem Land nicht verfügbar.",
            "fr": "Cette vidéo n’est pas disponible dans votre pays.",
            "es": "El vídeo no está disponible en tu país.",
        ],
        "err.live": [
            "en": "This is a live stream that has not ended yet. Try again later.",
            "ru": "Это прямой эфир, который ещё не закончился. Попробуйте позже.",
            "de": "Dies ist ein Livestream, der noch nicht beendet ist. Versuche es später.",
            "fr": "C’est un direct qui n’est pas terminé. Réessayez plus tard.",
            "es": "Es una emisión en directo que aún no ha terminado. Inténtalo más tarde.",
        ],
        "err.unavailable": [
            "en": "Video is unavailable or was removed.",
            "ru": "Видео недоступно или удалено.",
            "de": "Das Video ist nicht verfügbar oder wurde entfernt.",
            "fr": "La vidéo est indisponible ou a été supprimée.",
            "es": "El vídeo no está disponible o fue eliminado.",
        ],
        "err.cookies": [
            "en": "Couldn’t read the browser’s cookies. Give the app Full Disk Access or pick another browser.",
            "ru": "Не удалось прочитать cookies браузера. Дайте приложению «Полный доступ к диску» или выберите другой браузер.",
            "de": "Browser-Cookies konnten nicht gelesen werden. Gib der App „Voller Festplattenzugriff“ oder wähle einen anderen Browser.",
            "fr": "Impossible de lire les cookies du navigateur. Accordez l’« Accès complet au disque » ou choisissez un autre navigateur.",
            "es": "No se pudieron leer las cookies del navegador. Da «Acceso total al disco» a la app o elige otro navegador.",
        ],
        "err.forbidden": [
            "en": "The server refused the download (403). Update yt-dlp.",
            "ru": "Сервер отказал в загрузке (403). Обновите yt-dlp.",
            "de": "Der Server hat den Download abgelehnt (403). Aktualisiere yt-dlp.",
            "fr": "Le serveur a refusé le téléchargement (403). Mettez à jour yt-dlp.",
            "es": "El servidor rechazó la descarga (403). Actualiza yt-dlp.",
        ],
        "err.unsupported": [
            "en": "This link isn’t supported.",
            "ru": "Эта ссылка не поддерживается.",
            "de": "Dieser Link wird nicht unterstützt.",
            "fr": "Ce lien n’est pas pris en charge.",
            "es": "Este enlace no es compatible.",
        ],
        "err.format": [
            "en": "The requested quality isn’t available for this video. Pick another one.",
            "ru": "Нужное качество недоступно для этого видео. Выберите другое.",
            "de": "Die gewünschte Qualität ist für dieses Video nicht verfügbar. Wähle eine andere.",
            "fr": "La qualité demandée n’est pas disponible pour cette vidéo. Choisissez-en une autre.",
            "es": "La calidad pedida no está disponible para este vídeo. Elige otra.",
        ],
        "err.network": [
            "en": "Network error. Check the connection and retry.",
            "ru": "Ошибка сети. Проверьте подключение и повторите.",
            "de": "Netzwerkfehler. Prüfe die Verbindung und versuche es erneut.",
            "fr": "Erreur réseau. Vérifiez la connexion et réessayez.",
            "es": "Error de red. Comprueba la conexión e inténtalo de nuevo.",
        ],
        "err.disk": [
            "en": "Couldn’t write the file: no space or no access to the folder.",
            "ru": "Не удалось записать файл: нет места или нет доступа к папке.",
            "de": "Datei konnte nicht geschrieben werden: kein Speicherplatz oder kein Zugriff auf den Ordner.",
            "fr": "Impossible d’écrire le fichier : disque plein ou dossier inaccessible.",
            "es": "No se pudo escribir el archivo: sin espacio o sin acceso a la carpeta.",
        ],
        "err.generic": [
            "en": "Download failed.",
            "ru": "Не удалось скачать.",
            "de": "Download fehlgeschlagen.",
            "fr": "Échec du téléchargement.",
            "es": "No se pudo descargar.",
        ],
        "err.noYtdlp": [
            "en": "yt-dlp not found. Install it in the setup wizard.",
            "ru": "yt-dlp не найден. Установите его в мастере первого запуска.",
            "de": "yt-dlp nicht gefunden. Installiere es im Einrichtungsassistenten.",
            "fr": "yt-dlp introuvable. Installez-le dans l’assistant.",
            "es": "No se encontró yt-dlp. Instálalo en el asistente.",
        ],

        // --- всплывающие подсказки
        "No links found": [
            "ru": "Не нашёл ссылок", "de": "Keine Links gefunden",
            "fr": "Aucun lien trouvé", "es": "No se encontraron enlaces",
        ],
        "Already in the queue": [
            "ru": "Уже в очереди", "de": "Bereits in der Warteschlange",
            "fr": "Déjà dans la file", "es": "Ya está en la cola",
        ],
        "Added: {n}": [
            "ru": "Добавлено: {n}", "de": "Hinzugefügt: {n}",
            "fr": "Ajouté : {n}", "es": "Añadido: {n}",
        ],
        "Playlist “{title}”: {n} videos": [
            "ru": "Плейлист «{title}»: {n} видео", "de": "Playlist „{title}“: {n} Videos",
            "fr": "Playlist « {title} » : {n} vidéos", "es": "Lista «{title}»: {n} vídeos",
        ],
        "Only the first {n} were added": [
            "ru": "Добавлены только первые {n}", "de": "Nur die ersten {n} wurden hinzugefügt",
            "fr": "Seules les {n} premières ont été ajoutées", "es": "Solo se añadieron los primeros {n}",
        ],
        "Moved to Deferred: waiting for Wi-Fi": [
            "ru": "Перенёс в «Отложено»: жду Wi-Fi", "de": "Zu „Aufgeschoben“ verschoben: warte auf WLAN",
            "fr": "Déplacé vers « Différés » : en attente du Wi-Fi", "es": "Movido a «Aplazadas»: esperando Wi-Fi",
        ],
        "yt-dlp updated to {v}": [
            "ru": "yt-dlp обновлён до {v}", "de": "yt-dlp auf {v} aktualisiert",
            "fr": "yt-dlp mis à jour vers {v}", "es": "yt-dlp actualizado a {v}",
        ],
        "yt-dlp is up to date ({v})": [
            "ru": "yt-dlp актуален ({v})", "de": "yt-dlp ist aktuell ({v})",
            "fr": "yt-dlp est à jour ({v})", "es": "yt-dlp está al día ({v})",
        ],
        "Couldn’t update yt-dlp": [
            "ru": "Не удалось обновить yt-dlp", "de": "yt-dlp konnte nicht aktualisiert werden",
            "fr": "Impossible de mettre à jour yt-dlp", "es": "No se pudo actualizar yt-dlp",
        ],
        "{name} installed": [
            "ru": "{name} установлен", "de": "{name} installiert",
            "fr": "{name} installé", "es": "{name} instalado",
        ],
        "Couldn’t install {name}": [
            "ru": "Не удалось установить {name}", "de": "{name} konnte nicht installiert werden",
            "fr": "Impossible d’installer {name}", "es": "No se pudo instalar {name}",
        ],
        "File not found": [
            "ru": "Файл не найден", "de": "Datei nicht gefunden",
            "fr": "Fichier introuvable", "es": "Archivo no encontrado",
        ],
        "Folder: {path}": [
            "ru": "Папка: {path}", "de": "Ordner: {path}",
            "fr": "Dossier : {path}", "es": "Carpeta: {path}",
        ],

        // --- уведомления
        "Download complete": [
            "ru": "Загрузка завершена", "de": "Download abgeschlossen",
            "fr": "Téléchargement terminé", "es": "Descarga completada",
        ],
        "Playlist complete": [
            "ru": "Плейлист скачан", "de": "Playlist heruntergeladen",
            "fr": "Playlist téléchargée", "es": "Lista descargada",
        ],
        "{n} videos": [
            "ru": "{n} видео", "de": "{n} Videos", "fr": "{n} vidéos", "es": "{n} vídeos",
        ],
        "Download failed": [
            "ru": "Не удалось скачать", "de": "Download fehlgeschlagen",
            "fr": "Échec du téléchargement", "es": "Descarga fallida",
        ],

        // --- меню
        "About YTLoader": ["ru": "О программе YTLoader", "de": "Über YTLoader", "fr": "À propos de YTLoader", "es": "Acerca de YTLoader"],
        "Settings…": ["ru": "Настройки…", "de": "Einstellungen…", "fr": "Réglages…", "es": "Ajustes…"],
        "Hide YTLoader": ["ru": "Скрыть YTLoader", "de": "YTLoader ausblenden", "fr": "Masquer YTLoader", "es": "Ocultar YTLoader"],
        "Hide Others": ["ru": "Скрыть остальные", "de": "Andere ausblenden", "fr": "Masquer les autres", "es": "Ocultar otros"],
        "Show All": ["ru": "Показать все", "de": "Alle einblenden", "fr": "Tout afficher", "es": "Mostrar todo"],
        "Quit YTLoader": ["ru": "Завершить YTLoader", "de": "YTLoader beenden", "fr": "Quitter YTLoader", "es": "Salir de YTLoader"],
        "Edit": ["ru": "Правка", "de": "Bearbeiten", "fr": "Édition", "es": "Edición"],
        "Undo": ["ru": "Отменить", "de": "Widerrufen", "fr": "Annuler", "es": "Deshacer"],
        "Redo": ["ru": "Повторить", "de": "Wiederholen", "fr": "Rétablir", "es": "Rehacer"],
        "Cut": ["ru": "Вырезать", "de": "Ausschneiden", "fr": "Couper", "es": "Cortar"],
        "Copy": ["ru": "Копировать", "de": "Kopieren", "fr": "Copier", "es": "Copiar"],
        "Paste": ["ru": "Вставить", "de": "Einsetzen", "fr": "Coller", "es": "Pegar"],
        "Select All": ["ru": "Выбрать всё", "de": "Alles auswählen", "fr": "Tout sélectionner", "es": "Seleccionar todo"],
        "Window": ["ru": "Окно", "de": "Fenster", "fr": "Fenêtre", "es": "Ventana"],
        "Minimize": ["ru": "Свернуть", "de": "Im Dock ablegen", "fr": "Placer dans le Dock", "es": "Minimizar"],
        "Zoom": ["ru": "Масштаб", "de": "Zoomen", "fr": "Agrandir", "es": "Ampliar"],
        "Close": ["ru": "Закрыть", "de": "Schließen", "fr": "Fermer", "es": "Cerrar"],
        "Open YTLoader": ["ru": "Открыть YTLoader", "de": "YTLoader öffnen", "fr": "Ouvrir YTLoader", "es": "Abrir YTLoader"],
        "Pause All": ["ru": "Пауза для всех", "de": "Alle pausieren", "fr": "Tout mettre en pause", "es": "Pausar todo"],
        "Resume All": ["ru": "Продолжить все", "de": "Alle fortsetzen", "fr": "Tout reprendre", "es": "Reanudar todo"],
        "Nothing is downloading": [
            "ru": "Ничего не качается", "de": "Nichts wird heruntergeladen",
            "fr": "Aucun téléchargement en cours", "es": "No hay descargas en curso",
        ],
        "Choose": ["ru": "Выбрать", "de": "Wählen", "fr": "Choisir", "es": "Elegir"],
        "Download folder": [
            "ru": "Папка для загрузок", "de": "Ordner für Downloads",
            "fr": "Dossier de téléchargement", "es": "Carpeta de descargas",
        ],
    ]
}
