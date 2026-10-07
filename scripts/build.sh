#!/usr/bin/env bash
# Build KanbanEasy packages into dist/. (On Windows, use scripts/build.ps1.)
#
#   scripts/build.sh love     dist/KanbanEasy.love          (run with: love KanbanEasy.love)
#   scripts/build.sh windows  dist/KanbanEasy.exe           (one self-contained file, no DLLs)
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
RUNTIME_VERSION="$(head -n 1 "$ROOT/scripts/runtime/version.txt" | tr -d '[:space:]')"
RUNTIME_URL="https://github.com/Siekwie/KanbanEasy/releases/download/runtime-$RUNTIME_VERSION"
mkdir -p "$DIST" "$CACHE"

fetch() {
  local file="$1"
  if [[ ! -f "$CACHE/$file" ]]; then
    echo "downloading $file"
    curl -fsSL -o "$CACHE/$file.part" "https://github.com/love2d/love/releases/download/$LOVE_VERSION/$file"
    mv "$CACHE/$file.part" "$CACHE/$file"
  fi
}

# The Windows runtime is LÖVE built as one statically linked exe with our icon
# (see scripts/runtime). CI publishes it as a release.
fetch_runtime() {
  local file="$1" dir="$CACHE/runtime-$RUNTIME_VERSION"
  if [[ ! -f "$dir/$file" ]]; then
    echo "downloading $file (runtime $RUNTIME_VERSION)"
    mkdir -p "$dir"
    curl -fsSL -o "$dir/$file.part" "$RUNTIME_URL/$file"
    mv "$dir/$file.part" "$dir/$file"
  fi
}

build_love() {
  rm -f "$DIST/$APP.love"
  (cd "$ROOT" && zip -9 -qr "$DIST/$APP.love" main.lua conf.lua src assets -x '*.DS_Store')
  echo "built dist/$APP.love"
}

build_windows() {
  build_love
  fetch_runtime "$APP-runtime-win64.exe"
  fetch_runtime LOVE-license.txt
  local runtime="$CACHE/runtime-$RUNTIME_VERSION"
  # A fused game is just the runtime with the .love archive appended.
  cat "$runtime/$APP-runtime-win64.exe" "$DIST/$APP.love" >"$DIST/$APP.exe"
  cp "$runtime/LOVE-license.txt" "$DIST/"
  echo "built dist/$APP.exe"
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
