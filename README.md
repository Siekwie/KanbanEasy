# KanbanEasy

A small, fast, native kanban board for keeping track of agentic AI work. Built with [LÖVE](https://love2d.org) (Lua).
No accounts, no cloud, no config screens. Keep it docked next to your editor, and let your agents update it over a
local HTTP API.

![Board](docs/board.png)

- **Board**: columns you can drag cards between. Reordering animates smoothly, and there's undo/redo for everything.
- **Fast capture**: press `N`, type `Fix flaky test #ci @claude !high`, hit Enter. Labels, assignee and priority are
  parsed out of the title, and the input stays open so you can add the next one straight away.
- **Everything editable in place**: title, description, status, priority, assignee, labels, comments. The text
  fields support selection, word jumps, clipboard, undo and double/triple-click select.
- **Copy anything**: ID, title, Markdown, Markdown with comments, or a ready-to-paste **agent prompt** that includes
  the task plus the curl commands the agent can use to report progress.
- **Status tracking**: each issue keeps an activity log of moves and assignments, and records who made each change
  (you, or the agent's name). When an agent changes a card, the card briefly glows on the board.
- **Local API**: plain JSON over HTTP on `127.0.0.1:7420`. No MCP needed. There's a `kb` CLI wrapper too.
- **Docks nicely**: below ~540px wide the board switches to a stacked list with collapsible sections. The sidebar
  becomes a drawer.
- **Light and dark themes**, plus low idle CPU: the app only redraws when something changes.

| Issue detail | Docked to the side |
| --- | --- |
| ![Detail](docs/detail.png) | ![Narrow](docs/narrow.png) |

## Install / run

**Packaged builds** (from the GitHub Releases page, built by CI when a `v*` tag is pushed):

- **Windows**: unzip `KanbanEasy-windows.zip` and run `KanbanEasy.exe`.
- **macOS**: unzip `KanbanEasy-macos.zip` and move `KanbanEasy.app` to Applications. It isn't signed, so the first
  time, right-click → Open (or run `xattr -dr com.apple.quarantine KanbanEasy.app`).
- **Linux**: `chmod +x KanbanEasy-x86_64.AppImage && ./KanbanEasy-x86_64.AppImage`

**From source**, with [LÖVE 11.5](https://love2d.org) installed:

```sh
love .                      # from the repo root
scripts/build.sh love       # or build dist/KanbanEasy.love and double-click it
scripts/build.sh all        # Windows zip, macOS app and Linux AppImage in dist/
```

## Using it

| Key | Action |
| --- | --- |
| `N` / `Ctrl+N` | New issue in the selected column (or Todo) |
| `Enter` / click | Open issue · `E` edit its title |
| Arrows or `hjkl` | Move the selection · `Shift`+arrows moves the card |
| `0`–`4` | Priority (none, low, medium, high, urgent) |
| `Ctrl+C` / `Ctrl+Shift+C` | Copy the selected issue as Markdown / copy its ID |
| `Ctrl+Shift+P` | Copy an agent prompt for the selected issue |
| `/` or `Ctrl+F` | Search: words, `@assignee`, `#label`, `p:high`, `is:todo` |
| `Del` | Delete (undo with `Ctrl+Z`) · `Ctrl+D` duplicate |
| `Ctrl+Z` / `Ctrl+Shift+Z` | Undo / redo |
| `Ctrl+P`, `Ctrl+1..9` | Switch project |
| `Ctrl+B` | Toggle sidebar · `?` shows all shortcuts |

Right-click a card, column header or project for more actions (rename or add columns, copy the whole board as
Markdown, and so on). Double-click a column header or project to rename it. In the issue panel, `Tab` moves between
fields. The description saves when you click away, or with `Ctrl+Enter`.

## For agents: the local API

The app serves JSON on `http://127.0.0.1:7420` while it's running. `curl localhost:7420` prints the full reference.
Bodies can be JSON or form-encoded (`curl -d key=value`). Add `?format=md` to GET requests to get Markdown back.
Send an `X-Actor: <name>` header so the activity log shows who did what.

| Method | Path | |
| --- | --- | --- |
| GET | `/projects` | projects with per-column counts |
| POST | `/projects` | `{name, key?}` |
| GET | `/projects/KEY` | a project with all its issues (`?format=md` gives a checklist) |
| POST | `/projects/KEY/columns` | `{name}` |
| GET | `/issues` | filters: `project`, `status`, `assignee`, `label`, `q`, `limit` |
| POST | `/issues` | `{project?, title, description?, status?, priority?, labels?, assignee?, top?}` |
| GET | `/issues/KE-12` | one issue with its activity |
| PATCH | `/issues/KE-12` | any of `title, description, status, priority, labels, assignee` |
| POST | `/issues/KE-12/move` | `{status, index?}` |
| POST | `/issues/KE-12/comments` | `{body}` |
| DELETE | `/issues/KE-12` | |
| POST | `/claim` | `{assignee, project?, from?=todo, to?=in_progress}`: takes the next free task |

Statuses are matched loosely: `in_progress`, `In Progress` and `doing` all work. `project` can be left out when you
only have one project; otherwise the project currently open in the app is used.

```sh
curl -s 'localhost:7420/projects/KE?format=md'                       # what's on the board
curl -s -d assignee=claude localhost:7420/claim                       # take the next todo
curl -s -H 'X-Actor: claude' --data-urlencode body='Tests pass' localhost:7420/issues/KE-7/comments
curl -s -X PATCH -d status=review localhost:7420/issues/KE-7          # hand it back for review
curl -s -d title='Follow-up: flaky retry test' -d status=backlog localhost:7420/issues
```

**Wiring it into an agent:** right-click the API line at the bottom of the sidebar and choose **Copy agent
instructions**. That puts a short "here's your task board and how to use it" snippet on your clipboard for
`CLAUDE.md` / `AGENTS.md` or a system prompt. To hand an agent a single task, use **Agent prompt** in the issue panel.

### `kb` CLI

`bin/kb` is a small bash + curl wrapper. Put it on your `PATH` if you like:

```sh
kb                                   # board as markdown
kb ls todo                           # issues in a status
kb add "Fix login redirect" status=todo priority=high labels=bug
kb claim claude                      # take the next todo
kb note KE-12 "halfway there"        # comment
kb mv KE-12 review
kb set KE-12 assignee= labels=bug,auth
kb show KE-12
```

Environment: `KB_URL` (default `http://127.0.0.1:7420`), `KB_PROJECT`, `KB_ACTOR` (defaults to `$USER`).

### Security

The server binds to `127.0.0.1` only. It rejects requests that carry browser headers (`Origin`, `Sec-Fetch-Site`)
or a non-local `Host`, so a web page you visit can't reach it and DNS-rebinding tricks don't work. Anything running
locally as you can use it. That's intentional.

## Data

Everything lives in a single, human-readable JSON file in a `KanbanEasy` folder in your user directory:

- Windows: `C:\Users\<you>\KanbanEasy\board.json`
- macOS: `/Users/<you>/KanbanEasy/board.json`
- Linux: `~/KanbanEasy/board.json`

Keys are sorted so the file diffs cleanly in git. The first launch of each day saves a snapshot to `backups/` next
to it, one per weekday, so you always have the last week. Click the path at the bottom of the sidebar to open the
folder; right-click it to copy the path. The file is watched, so if you edit it by hand (or `git pull` it) the app
reloads it, and Ctrl+Z undoes the reload.

Earlier builds kept the board in the OS app-data folder (`%APPDATA%\KanbanEasy` on Windows). If one is found there,
it's copied to the new folder on first launch. The old file is left untouched.

| Env var | |
| --- | --- |
| `KANBANEASY_DATA` | use a different board file, e.g. one inside a project repo |
| `KANBANEASY_PORT` | API port (default `7420`) |
| `KANBANEASY_NO_API=1` | don't start the API |

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
