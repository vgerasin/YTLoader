#!/usr/bin/env bash
# Собирает YTLoader.app из исходников репозитория и упаковывает в DMG.
# Запускать на macOS (нужны hdiutil и codesign). Использование:
#   ./scripts/build-dmg.sh [--app-only] [--host путь/к/YTLoader] [--ytdlp путь/к/yt-dlp]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/YTLoader.app"
CACHE="$BUILD/cache"
HOST="$ROOT/host/prebuilt/YTLoader-arm64"   # скомпилированная Swift-оболочка
YTDLP=""
APP_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-only) APP_ONLY=1 ;;
    --host)     HOST="$2"; shift ;;
    --ytdlp)    YTDLP="$2"; shift ;;
    *) echo "неизвестный параметр: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname)" == "Darwin" ]] || { echo "Сборка DMG возможна только на macOS" >&2; exit 1; }
[[ -f "$HOST" ]] || { echo "Нет оболочки: $HOST (см. host/README.md)" >&2; exit 1; }

echo "▸ YTLoader $VERSION"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$CACHE"

# 1. Info.plist с подставленной версией
sed "s/__VERSION__/$VERSION/g" "$ROOT/app/Info.plist.in" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 2. Оболочка и ресурсы (интерфейс, иконка)
cp "$HOST" "$APP/Contents/MacOS/YTLoader"
chmod +x "$APP/Contents/MacOS/YTLoader"
cp -R "$ROOT/app/Resources/." "$APP/Contents/Resources/"

# 3. yt-dlp: свой файл или свежий универсальный релиз (arm64 + x86_64)
if [[ -z "$YTDLP" ]]; then
  YTDLP="$CACHE/yt-dlp_macos"
  if [[ ! -f "$YTDLP" || -n "$(find "$YTDLP" -mtime +7 2>/dev/null)" ]]; then
    echo "▸ Скачиваю yt-dlp"
    curl -fL -o "$YTDLP" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
  fi
fi
cp "$YTDLP" "$APP/Contents/Resources/bin/yt-dlp"
chmod +x "$APP/Contents/Resources/bin/yt-dlp"

# 4. Подпись (ad-hoc — без платного аккаунта разработчика)
codesign --force --deep --sign - "$APP"
echo "▸ Готово: $APP"

[[ $APP_ONLY -eq 1 ]] && exit 0

# 5. DMG с ярлыком на «Программы»
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT="$DIST/YTLoader-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "YTLoader" -srcfolder "$STAGE" -ov -format ULFO "$OUT"
echo "▸ DMG: $OUT"
