#!/usr/bin/env bash
# Собирает YTLoader.app из исходников репозитория и упаковывает в DMG.
# Запускать на macOS (нужны Xcode Command Line Tools: swift, hdiutil, codesign).
#
#   ./scripts/build-dmg.sh                    универсальный DMG (Apple Silicon + Intel)
#   ./scripts/build-dmg.sh --arch x86_64      только Intel      → YTLoader-<версия>-intel.dmg
#   ./scripts/build-dmg.sh --arch arm64       только Apple Silicon → YTLoader-<версия>-arm64.dmg
#   ./scripts/build-dmg.sh --app-only         только .app, без образа
#   ./scripts/build-dmg.sh --host путь        взять готовую оболочку вместо сборки
#   ./scripts/build-dmg.sh --ytdlp путь       свой yt-dlp вместо свежего релиза
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
CACHE="$BUILD/cache"
HOST=""
YTDLP=""
ARCH="universal"
APP_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-only) APP_ONLY=1 ;;
    --arch)     ARCH="$2"; shift ;;
    --host)     HOST="$2"; shift ;;
    --ytdlp)    YTDLP="$2"; shift ;;
    *) echo "неизвестный параметр: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$ARCH" in
  universal) ARCH_FLAGS=(--arch arm64 --arch x86_64); SUFFIX="" ;;
  arm64)     ARCH_FLAGS=(--arch arm64);               SUFFIX="-arm64" ;;
  x86_64|intel) ARCH="x86_64"; ARCH_FLAGS=(--arch x86_64); SUFFIX="-intel" ;;
  *) echo "--arch: universal, arm64 или x86_64" >&2; exit 2 ;;
esac

[[ "$(uname)" == "Darwin" ]] || { echo "Сборка возможна только на macOS" >&2; exit 1; }

APP="$BUILD/$ARCH/YTLoader.app"
echo "▸ YTLoader $VERSION ($ARCH)"

# 1. Оболочка на Swift
if [[ -z "$HOST" ]]; then
  echo "▸ Собираю оболочку (swift build, $ARCH)"
  swift build -c release --package-path "$ROOT/host" "${ARCH_FLAGS[@]}"
  BIN="$(swift build -c release --package-path "$ROOT/host" "${ARCH_FLAGS[@]}" --show-bin-path)"
  HOST="$BIN/YTLoader"
fi
[[ -f "$HOST" ]] || { echo "Нет оболочки: $HOST" >&2; exit 1; }
echo "  архитектуры: $(lipo -archs "$HOST")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$CACHE"

# 2. Info.plist с подставленной версией
sed "s/__VERSION__/$VERSION/g" "$ROOT/app/Info.plist.in" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 3. Оболочка и ресурсы (интерфейс, иконка)
cp "$HOST" "$APP/Contents/MacOS/YTLoader"
chmod +x "$APP/Contents/MacOS/YTLoader"
cp -R "$ROOT/app/Resources/." "$APP/Contents/Resources/"

# 4. yt-dlp: свой файл или свежий универсальный релиз (arm64 + x86_64)
if [[ -z "$YTDLP" ]]; then
  YTDLP="$CACHE/yt-dlp_macos"
  if [[ ! -f "$YTDLP" || -n "$(find "$YTDLP" -mtime +7 2>/dev/null)" ]]; then
    echo "▸ Скачиваю yt-dlp"
    curl -fL -o "$YTDLP" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
  fi
fi
cp "$YTDLP" "$APP/Contents/Resources/bin/yt-dlp"
chmod +x "$APP/Contents/Resources/bin/yt-dlp"

# 5. Подпись (ad-hoc — без платного аккаунта разработчика)
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "▸ Готово: $APP"

[[ $APP_ONLY -eq 1 ]] && exit 0

# 6. DMG с ярлыком на «Программы»
STAGE="$BUILD/$ARCH/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT="$DIST/YTLoader-$VERSION$SUFFIX.dmg"
rm -f "$OUT"
hdiutil create -volname "YTLoader" -srcfolder "$STAGE" -ov -format ULFO "$OUT"
hdiutil verify "$OUT" >/dev/null
echo "▸ DMG: $OUT"
