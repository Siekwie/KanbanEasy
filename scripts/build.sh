#!/usr/bin/env bash
# Build KanbanEasy packages into dist/.
#
#   scripts/build.sh love     dist/KanbanEasy.love          (run with: love KanbanEasy.love)
#   scripts/build.sh windows  dist/KanbanEasy-windows.zip   (KanbanEasy.exe + LÖVE runtime)
#   scripts/build.sh macos    dist/KanbanEasy-macos.zip     (KanbanEasy.app, unsigned)
#   scripts/build.sh linux    dist/KanbanEasy-x86_64.AppImage
#   scripts/build.sh all
#
# Needs: zip, unzip, curl (and python3 for the macOS plist).
set -euo pipefail

LOVE_VERSION=11.5
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
CACHE="$ROOT/.build-cache"
APP=KanbanEasy
mkdir -p "$DIST" "$CACHE"

fetch() {
  local file="$1"
  if [[ ! -f "$CACHE/$file" ]]; then
    echo "downloading $file"
    curl -fsSL -o "$CACHE/$file.part" "https://github.com/love2d/love/releases/download/$LOVE_VERSION/$file"
    mv "$CACHE/$file.part" "$CACHE/$file"
  fi
}

build_love() {
  rm -f "$DIST/$APP.love"
  (cd "$ROOT" && zip -9 -qr "$DIST/$APP.love" main.lua conf.lua src assets -x '*.DS_Store')
  echo "built dist/$APP.love"
}

build_windows() {
  build_love
  fetch "love-$LOVE_VERSION-win64.zip"
  local work="$CACHE/win"
  rm -rf "$work" && mkdir -p "$work"
  unzip -q "$CACHE/love-$LOVE_VERSION-win64.zip" -d "$work"
  local src="$work/love-$LOVE_VERSION-win64"
  local out="$work/$APP"
  mkdir -p "$out"
  cat "$src/love.exe" "$DIST/$APP.love" >"$out/$APP.exe"
  cp "$src"/*.dll "$src/license.txt" "$out/"
  cp "$ROOT/README.md" "$out/README.md"
  rm -f "$DIST/$APP-windows.zip"
  (cd "$work" && zip -9 -qr "$DIST/$APP-windows.zip" "$APP")
  echo "built dist/$APP-windows.zip"
}

build_macos() {
  build_love
  fetch "love-$LOVE_VERSION-macos.zip"
  local work="$CACHE/mac"
  rm -rf "$work" && mkdir -p "$work"
  unzip -q "$CACHE/love-$LOVE_VERSION-macos.zip" -d "$work"
  mv "$work/love.app" "$work/$APP.app"
  cp "$DIST/$APP.love" "$work/$APP.app/Contents/Resources/$APP.love"
  python3 - "$work/$APP.app/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    p = plistlib.load(f)
p["CFBundleName"] = "KanbanEasy"
p["CFBundleDisplayName"] = "KanbanEasy"
p["CFBundleIdentifier"] = "dev.kanbaneasy.app"
p.pop("UTExportedTypeDeclarations", None)
p.pop("CFBundleDocumentTypes", None)
with open(path, "wb") as f:
    plistlib.dump(p, f)
PY
  rm -f "$DIST/$APP-macos.zip"
  (cd "$work" && zip -9 -qry "$DIST/$APP-macos.zip" "$APP.app")
  echo "built dist/$APP-macos.zip"
}

build_linux() {
  build_love
  fetch "love-$LOVE_VERSION-x86_64.AppImage"
  local work="$CACHE/linux"
  rm -rf "$work" && mkdir -p "$work"
  cp "$CACHE/love-$LOVE_VERSION-x86_64.AppImage" "$work/love.AppImage"
  chmod +x "$work/love.AppImage"
  (cd "$work" && ./love.AppImage --appimage-extract >/dev/null)
  local root="$work/squashfs-root"
  cat "$root/bin/love" "$DIST/$APP.love" >"$root/bin/$APP"
  chmod +x "$root/bin/$APP"
  sed -i "s|/bin/love|/bin/$APP|" "$root/AppRun" 2>/dev/null || true
  if [[ -f "$root/love.desktop" ]]; then
    sed -i -e "s/^Name=.*/Name=$APP/" -e "s/^Exec=.*/Exec=$APP %f/" "$root/love.desktop"
  fi
  local tool="$CACHE/appimagetool"
  if [[ ! -x "$tool" ]]; then
    curl -fsSL -o "$tool" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x "$tool"
  fi
  ARCH=x86_64 "$tool" --appimage-extract-and-run "$root" "$DIST/$APP-x86_64.AppImage" >/dev/null
  echo "built dist/$APP-x86_64.AppImage"
}

case "${1:-love}" in
  love) build_love ;;
  windows | win) build_windows ;;
  macos | mac) build_macos ;;
  linux | appimage) build_linux ;;
  all)
    build_windows
    build_macos
    build_linux
    ;;
  *)
    echo "usage: $0 love|windows|macos|linux|all" >&2
    exit 1
    ;;
esac
