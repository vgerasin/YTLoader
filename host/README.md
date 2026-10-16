# Оболочка (host)

Нативная часть приложения на Swift: окно с `app/Resources/ui.html`, очередь загрузок, запуск `yt-dlp`/`ffmpeg`,
сеть, буфер обмена, Dock, строка меню, уведомления. Устройство моста между оболочкой и интерфейсом —
в [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) (версия 5.6).

```
Package.swift
Sources/
  YTLoaderCore/        вся логика, без AppKit — собирается и тестируется отдельно
    Settings.swift       настройки (settings.json), патч от интерфейса, снимок для UI
    Models.swift         Item (загрузка), HistoryEntry, StreamInfo
    Sites.swift          сайты (YouTube, VK, Rutube, Vimeo, …), поиск ссылок в тексте, ключ ролика для дублей
    ArgsBuilder.swift    строка запуска yt-dlp: формат, папки, cookies, SponsorBlock, субтитры, фрагмент
    ProgressParser.swift разбор вывода yt-dlp и общий прогресс по дорожкам
    ErrorClassifier.swift ошибка yt-dlp → понятное сообщение на языке интерфейса
    Components.swift     поиск, установка и обновление yt-dlp / ffmpeg / ffprobe / deno (arm64 и Intel)
    Engine*.swift        очередь: добавление, разбор ссылок и плейлистов, планировщик, пауза, отложенный старт
    Loc.swift            тексты оболочки: ru, en, de, fr, es
    Store.swift, Paths.swift, Util.swift
  YTLoader/            оболочка AppKit
    AppDelegate.swift    окно, WKWebView и мост, меню, сеть, буфер обмена, уведомления, ytloader://
    StatusBarController.swift  значок в строке меню
    DockController.swift       цвет значка и полоса прогресса в Dock
Tests/YTLoaderCoreTests/  модульные и сквозные тесты (настоящий yt-dlp + локальный сервер)
```

## Сборка и тесты (на Mac)

```bash
cd host
swift build -c release --arch arm64 --arch x86_64    # универсальный бинарник
swift test                                           # модульные тесты
YTL_E2E=1 swift test                                 # + сквозные (нужны yt-dlp и по желанию ffmpeg)
```

Из корня репозитория: `make test`, `make run` (запуск из исходников), `make dmg` (универсальный образ),
`make dmg-intel` (только Intel).

Сквозным тестам нужен `yt-dlp` в PATH-каталоге из переменной `YTL_EXTRA_BIN` (или в `~/Library/Application Support/YTLoader/bin`),
для проверок склейки, MP3 и фрагмента — ещё `ffmpeg`. Без ffmpeg эти тесты пропускаются.

## Самопроверка настоящего окна

`YTLOADER_SELFTEST=1 YTLoader` открывает окно, вставляет ссылку в поле, нажимает «Добавить», ждёт файл в истории,
открывает настройки и сохраняет снимки окна (`YTLOADER_SELFTEST_OUT`). Ссылку задаёт `YTLOADER_SELFTEST_URL`,
каталог данных — `YTLOADER_HOME`, интерфейс при запуске не из .app — `YTLOADER_UI`. В CI так проверяются и сама оболочка,
и собранный `.app` перед публикацией релиза.

## CI

`.github/workflows/ci.yml` на каждый push собирает оболочку под обе архитектуры и гоняет все тесты на macOS.
Журналы и снимки окна кладутся в ветку `ci-logs` (папка `latest/`).
