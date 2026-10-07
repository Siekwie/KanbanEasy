# Building and developing

Releases are built by CI on every push to `main` (see `.github/workflows/ci.yml`), so most people never need this.

## Build it yourself

**On Windows**: double-click `build.bat` in the repo root. It downloads the runtime, builds `dist\KanbanEasy.exe`
(one self-contained file, no DLLs) and shows it in Explorer. Or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1           # dist\KanbanEasy.exe
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 install   # + %LOCALAPPDATA%\Programs, Start Menu shortcut
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 run       # run from source with an installed LÖVE
```

Other targets: `love` (just the `.love` file), `runtime` (see below) and `clean`. Running `install` again updates
in place. If the app is open, it gets closed first (the board is already saved).

**On macOS / Linux**, with [LÖVE 11.5](https://love2d.org) installed:

```sh
love .                      # from the repo root
scripts/build.sh love       # or build dist/KanbanEasy.love and double-click it
scripts/build.sh all        # Windows exe, macOS app and Linux AppImage in dist/
```

## The Windows runtime

The official LÖVE download for Windows is `love.exe` plus seven DLLs, and `love.exe` shows the LÖVE icon. So that
KanbanEasy can be a single file with its own icon, `scripts/runtime/build-runtime.ps1` builds LÖVE 11.5 from source
([megasource](https://github.com/love2d/megasource)) with every library and the C runtime linked into one executable,
and with the icon and version info from `scripts/runtime/app.rc`. `KanbanEasy.exe` is that runtime with the `.love`
archive appended.

You don't need a compiler for a normal build: CI publishes the runtime as the release `runtime-<version>` and the
build scripts download it from there. To change it (LÖVE version, the two patches, the icon), bump
`scripts/runtime/version.txt` and push: CI builds and publishes the new one before packaging. To build it locally
you need Visual Studio with the C++ workload, CMake and git:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 runtime   # about ten minutes the first time
```

Because everything is linked statically, native Lua modules that ship as DLLs can't be loaded by this runtime.
KanbanEasy doesn't use any.

## Development

```sh
busted            # unit tests (store, API, JSON)
luacheck .        # lint
stylua .          # format
love .            # run
```

Layout: `src/store.lua` is the data model (pure Lua). `src/api.lua` is the HTTP router (pure Lua) and
`src/server.lua` is the non-blocking LuaSocket server. `src/persist.lua` handles saving. `src/app.lua` wires it all
together, and `src/ui/` holds the views (`board`, `detail`, `chrome`, `overlay`) plus a small immediate-mode core
and a text editor widget.

Fonts: [Inter](https://rsms.me/inter/) and [JetBrains Mono](https://www.jetbrains.com/lp/mono/), both under the
SIL Open Font License (see `assets/fonts/`).
