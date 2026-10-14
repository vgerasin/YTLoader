# Как устроен YTLoader

```
YTLoader.app
├── Contents/MacOS/YTLoader          Swift-оболочка (host/): окно, очередь, процессы, система (arm64 + x86_64)
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
(`none | channel | playlist`), `codec` (`h264 | any | av1`, по умолчанию `h264` — открывается в QuickTime; поле `schema` нужно для одноразовой миграции старого «any»), `cookieBrowser`, `filenameTemplate`,
`subtitles` (`none | ru,en | all`), `subsEmbed`, `chapters`, `sponsorblock`, `wifiOnly`, `autoResume`,
`clipboardWatch`, `autoUpdate`, `notify`, `dockBadge`, `menuBar`, `theme`, `density`, `accent`, `language`, `onboarded`.

## Как добавить функцию

**Только интерфейс** (новая вкладка, фильтр, оформление, перевод) — правьте `app/Resources/ui.html`,
запустите `make screenshots`, чтобы посмотреть результат без Mac, и `make dmg` на Mac для сборки.
Тексты интерфейса — русские строки, переводы лежат в объекте `I18N` в начале скрипта
(ключ — русская строка; нет перевода — показывается сама строка).

**Нужна поддержка оболочки** (новая команда `/api/…`, новое поле снимка, новый флаг yt-dlp):

1. Команда: добавьте ветку в `Engine.handle(path:body:)` (`host/Sources/YTLoaderCore/Engine.swift`),
   если она про очередь, или в `userContentController(_:didReceive:)` (`host/Sources/YTLoader/AppDelegate.swift`),
   если ей нужны окно или система (диалоги, Finder).
2. Новое поле загрузки: `Item` (`Models.swift`) — свойство, ключ в `CodingKeys`, строка в `uiJSON()`.
3. Новая настройка: `Settings.swift` — свойство, ключ в `CodingKeys`/`init(from:)`, ветка в `apply(patch:)`, строка в `uiJSON`.
4. Флаг yt-dlp: `ArgsBuilder.downloadArgs` — и тест в `Tests/YTLoaderCoreTests/ArgsTests.swift`.
5. Проверка: `make test` на Mac или push в ветку — CI соберёт и прогонит тесты (журналы в ветке `ci-logs`).

## Другие сайты

Приложение принимает любую http(s)-ссылку: разбор и загрузку делает yt-dlp, а он умеет больше тысячи сайтов.
Список в `Sites.swift` нужен только для удобства: подсказка из буфера обмена, подпись «откуда» на карточке,
ключ ролика для поиска дублей (`youtu.be/ID` = `watch?v=ID`, `vk.com/video-1_2`, `rutube.ru/video/<hash>/`, …).
Чтобы добавить сайт, допишите его в `Sites.known` (имя и домены) — и, если у него особый адрес видео, правило в `Sites.videoKey`.
Приёмы, специфичные для YouTube (`player_client`, SponsorBlock, JS-проверка), включаются только для его адресов.

## Как работает очередь

- Состояние живёт в `Engine` и меняется только в его последовательной очереди; окно получает снимок
  (`window.applyState`) не чаще ~2,5 раза в секунду и только если что-то изменилось.
- Добавленная ссылка сначала получает статус `resolving`: `yt-dlp -J --flat-playlist -f <формат>` возвращает название, превью,
  длительность и список дорожек с размерами. Плейлист или канал заменяется группой карточек (до 500 роликов).
- Затем планировщик (тик 0,4 с) запускает загрузки, пока их меньше «Одновременно». Процесс `yt-dlp` печатает прогресс по шаблону
  (`ArgsBuilder.progressTemplate`), `ProgressTracker` складывает его в общую полосу из участков по дорожкам.
- Пауза — `SIGINT`: yt-dlp оставляет `.part`, продолжение докачивает. Отмена удаляет недокачанное.
- Сбой разбирает `ErrorClassifier`; часть случаев чинится сама: cookies не читаются → повтор без них,
  403 → повтор со свежими ссылками, затем (YouTube) запасные клиенты `tv,android_vr,web_safari`, затем обновление yt-dlp и повтор;
  «unable to extract» → обновление yt-dlp и повтор; сетевая ошибка → до трёх повторов с паузой.
- Недокачанные части и обложка пишутся в `-P temp:<папка>/.ytloader-tmp/<id>`; готовый файл yt-dlp переносит оттуда сам
  (`after_move`), папка удаляется после завершения и отмены, при паузе и ошибке остаётся для докачки.
- Прогресс: доля дорожки — по номеру фрагмента (HLS/DASH) или по байтам, вес дорожки — размер из разбора ссылки; процент не убывает.
  На YouTube селектор формата сначала берёт форматы без `m3u8` (`[protocol!*=m3u8]`), потом любые.
- Очередь, история и настройки сохраняются в `~/Library/Application Support/YTLoader/*.json`, журнал — в `~/Library/Logs/YTLoader/`.

## Сборка новой версии

1. Поднять номер в файле `VERSION`, записать изменения в `CHANGELOG.md`.
2. На Mac: `make dmg` → `dist/YTLoader-<версия>.dmg` (универсальный), `make dmg-intel` → `…-intel.dmg`.
   Либо на GitHub: **Actions → Release DMG → Run workflow** — обе сборки, релиз и обновление `downloads/` делаются сами.
