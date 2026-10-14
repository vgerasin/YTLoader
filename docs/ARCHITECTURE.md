# Как устроен YTLoader

```
YTLoader.app
├── Contents/MacOS/YTLoader          Swift-оболочка (host): окно, очередь, процессы, система
├── Contents/Resources/ui.html       весь интерфейс: один файл HTML/CSS/JS
├── Contents/Resources/bin/yt-dlp    универсальный бинарник (arm64 + x86_64)
├── Contents/Resources/AppIcon.icns
└── Contents/Info.plist              id com.vgerasin.ytloader, URL-схема ytloader://
```

Оболочка показывает `ui.html` в веб-окне и держит всё «настоящее» состояние. Интерфейс сам ничего не качает:
он рисует то, что прислала оболочка, и отправляет ей команды.

Дополнительные компоненты (`ffmpeg`, `ffprobe`, `deno`) оболочка ставит по кнопке в мастере первого запуска
в `~/Library/Application Support/YTLoader`. Deno нужен, чтобы yt-dlp решал JS-проверки YouTube
(иначе ссылки отдаются с ошибкой 403), ffmpeg/ffprobe — для склейки дорожек, mp3, глав, фрагментов и SponsorBlock.

## Мост интерфейс ⇄ оболочка

**Интерфейс → оболочка.** Команда уходит так:

```js
window.webkit.messageHandlers.ytl.postMessage({ path: "/api/pause", body: { id: "…" } });
```

**Оболочка → интерфейс.** Примерно 2–3 раза в секунду оболочка вызывает

```js
window.applyState(state);   // state — весь снимок, интерфейс перерисовывает только изменившееся
window.toast("текст");      // короткое уведомление внизу окна
```

### Команды (`path`)

| path | что делает |
|---|---|
| `/api/add` | добавить ссылки (качество, видео/MP3, режим старта, фрагмент) |
| `/api/pause`, `/api/resume`, `/api/cancel` | одна загрузка, `{id}` |
| `/api/pauseAll`, `/api/resumeAll`, `/api/retryFailed`, `/api/cancelAll` | вся очередь или группа плейлиста, `{group}` |
| `/api/defer` | отложить загрузку (`{id, mode}`) |
| `/api/reveal` | показать файл в Finder |
| `/api/clearHistory` | очистить историю |
| `/api/dismissClip` | скрыть подсказку со ссылкой из буфера |
| `/api/settings` | записать настройки |
| `/api/chooseFolder` | выбор папки загрузок |
| `/api/updateYtdlp` | обновить yt-dlp |
| `/api/recheckComponents`, `/api/installComponent` | проверка и установка yt-dlp / ffmpeg / ffprobe / deno |
| `/api/readLog`, `/api/openLog` | журнал в «Диагностике» |
| `/api/state` | запрос текущего снимка (интерфейс отвечает из последнего пуша) |

### Снимок состояния (`state`)

```jsonc
{
  "items":   [ /* активные, ожидающие, отложенные и упавшие загрузки */ ],
  "history": [ /* завершённые */ ],
  "settings": { /* см. ниже */ },
  "env":     { "ytdlp": true, "ytdlpVersion": "…", "ytdlpPath": "…", "ffmpeg": true, "ffprobe": true,
               "js": true, "jsKind": "deno", "jsPath": "…", "installing": "", "window": "…", "systemLang": "ru" },
  "net":     { "kind": "wifi | ethernet | cellular | none", "label": "Wi-Fi" },
  "totals":  { "active": 3, "speed": 17500000 },
  "notice":  ""   // если непусто — показывается как toast
}
```

**Загрузка (`items[]`, `history[]`):** `id`, `url`, `title`, `channel`, `thumb`, `duration`,
`status` (`downloading | resolving | queued | paused | error | deferred`), `stage` (`video | audio | merge | convert`),
`pct`, `total`, `downloaded`, `speed`, `eta`, `quality`, `format` (`mp4 | mp3 …`),
`streams[]` (`{kind, total, done, active, estimated}` — по одному участку полосы на дорожку),
`error`, `rawError`, `noCookies`, `groupId`, `groupTitle`, `groupTotal` (плейлист),
`deferMode` (`wifi | time | manual`), `deferTime`, `filepath`, `dateLabel`.

**Настройки (`settings`):** `folder`, `defaultQuality`, `maxParallel`, `speedLimit`, `organize`
(`none | channel | playlist`), `codec` (`any | h264 | av1`), `cookieBrowser`, `filenameTemplate`,
`subtitles` (`none | ru,en | all`), `subsEmbed`, `chapters`, `sponsorblock`, `wifiOnly`, `autoResume`,
`clipboardWatch`, `autoUpdate`, `notify`, `dockBadge`, `menuBar`, `theme`, `density`, `accent`, `language`, `onboarded`.

## Как добавить функцию

**Только интерфейс** (новая вкладка, фильтр, оформление, перевод) — правьте `app/Resources/ui.html`,
запустите `make screenshots`, чтобы посмотреть результат без Mac, и `make dmg` на Mac для сборки.
Тексты интерфейса — русские строки, переводы лежат в объекте `I18N` в начале скрипта
(ключ — русская строка; нет перевода — показывается сама строка).

**Нужна поддержка оболочки** (новая команда `/api/…`, новое поле снимка, новый флаг yt-dlp) —
нужны исходники Swift-части, см. [host/README.md](../host/README.md).

## Сборка новой версии

1. Поднять номер в файле `VERSION`.
2. На Mac: `make dmg` → `dist/YTLoader-<версия>.dmg`.
3. Записать изменения в `CHANGELOG.md`, выложить DMG в GitHub Releases.
