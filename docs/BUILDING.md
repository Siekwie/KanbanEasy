# Building and developing

Releases are built by CI on every push to `main` (see `.github/workflows/ci.yml`), so most people never need this.

## Build it yourself

**On Windows**: double-click `build.bat` in the repo root. It downloads LÖVE, builds
`dist\KanbanEasy\KanbanEasy.exe` (keep the DLLs next to it) plus `dist\KanbanEasy-windows.zip`, and opens the folder.
Or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1           # dist\KanbanEasy\KanbanEasy.exe + zip
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 install   # + %LOCALAPPDATA%\Programs, Start Menu shortcut
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 run       # run from source with an installed LÖVE
```

Other targets: `love` (just the `.love` file) and `clean`. Running `install` again updates in place. If the app is
open, it gets closed first (the board is already saved).

**On macOS / Linux**, with [LÖVE 11.5](https://love2d.org) installed:

```sh
love .                      # from the repo root
scripts/build.sh love       # or build dist/KanbanEasy.love and double-click it
scripts/build.sh all        # Windows zip, macOS app and Linux AppImage in dist/
```

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
