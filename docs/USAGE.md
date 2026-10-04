# Using KanbanEasy

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `N` / `Ctrl+N` | New issue in the selected column (or Todo) |
| `Enter` / click | Open issue · `E` edit its title |
| Arrows or `hjkl` | Move the selection · `Shift`+arrows moves the card |
| `0`–`4` | Priority (none, low, medium, high, urgent) |
| `M` / `A` | Assign to me / to the agent (press again to unassign) |
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

## People & rules

Each project knows two people: **me** (you) and **agent** (your coding agent). Click the names at the bottom of
the sidebar (or right-click a project → **People & defaults…**) to set them, and to pick who new issues are assigned
to. After that, `me` and `agent` work anywhere you'd type a name: the assignee field, quick add (`@agent`), search
(`@me`), and the API (`assignee=agent`). Renaming one moves their issues to the new name.

Right-click a column header (or use its `⋯` button) to give the column rules:

- **Cards landing here go to** me, the agent, nobody, or someone else. It applies whenever a card enters the
  column, from the board or the API, and also to the cards already there when you set it. Setting an assignee
  explicitly in the same change wins over the rule.
- **Agent instructions**: what to do with cards in this column. Agents get them with the task (the API's
  `instructions` field, `?format=md`, the copied agent prompt and the agent instructions snippet).

Columns with rules show who cards go to next to the count. For example, a review loop where you make the call and
the agent writes it up:

```sh
kb people me=siekwie agent=claude default=me
kb rule review assign=agent instructions="Read my decision in the comments, write it up in docs/decisions.md, then move the card to done"
kb rule done assign=-          # optional: done cards are nobody's
```

The agent then checks its queue with `kb mine agent` (or `GET /issues?assignee=agent`) and reads each task with
its instructions.

## Your data

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
