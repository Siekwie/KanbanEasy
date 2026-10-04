# Local API and `kb` CLI

The app serves JSON on `http://127.0.0.1:7420` while it's running. `curl localhost:7420` prints the full reference.
Bodies can be JSON or form-encoded (`curl -d key=value`). Add `?format=md` to GET requests to get Markdown back.
Send an `X-Actor: <name>` header so the activity log shows who did what.

| Method | Path | |
| --- | --- | --- |
| GET | `/projects` | projects with per-column counts |
| POST | `/projects` | `{name, key?}` |
| GET | `/projects/KEY` | a project with all its issues (`?format=md` gives a checklist) |
| PATCH | `/projects/KEY` | `{name?, me?, agent?, default_assignee?}` |
| POST | `/projects/KEY/columns` | `{name}` |
| PATCH | `/projects/KEY/columns/ID` | `{name?, auto_assign?, instructions?}`; `auto_assign` takes `me`, `agent`, a name, `-` (unassign) or `""` (no rule) |
| GET | `/issues` | filters: `project`, `status`, `assignee`, `label`, `q`, `limit` |
| POST | `/issues` | `{project?, title, description?, status?, priority?, labels?, assignee?, top?}` |
| GET | `/issues/KE-12` | one issue with its activity |
| PATCH | `/issues/KE-12` | any of `title, description, status, priority, labels, assignee` |
| POST | `/issues/KE-12/move` | `{status, index?}` |
| POST | `/issues/KE-12/comments` | `{body}` |
| DELETE | `/issues/KE-12` | |
| POST | `/claim` | `{assignee, project?, from?=todo, to?=in_progress}`: takes the next free task |

Every issue carries a `rev` that grows with each change. To avoid overwriting a card that changed since you read it,
send the `rev` back as `If-Match: <rev>` (or a `rev` field) on `PATCH`, `move`, `comments` and `DELETE`. A stale rev
gets `409` with the card's current state in `current`. It's optional: without it the write goes through as before.
`/claim` is atomic (the server handles one request at a time), so two simultaneous claims never get the same card.

Statuses are matched loosely: `in_progress`, `In Progress` and `doing` all work. Assignees can be a name or `me` /
`agent`. Issues include their column's `instructions` when it has any. `project` can be left out when you
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

## `kb` CLI

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
kb mine agent                        # open issues assigned to the agent
kb people me=sam agent=claude        # who "me" and "agent" are (no args: show)
kb rule review assign=agent instructions="..."   # column rules (no args: show)
```

Environment: `KB_URL` (default `http://127.0.0.1:7420`), `KB_PROJECT`, `KB_ACTOR` (defaults to `$USER`).

## Security

The server binds to `127.0.0.1` only. It rejects requests that carry browser headers (`Origin`, `Sec-Fetch-Site`)
or a non-local `Host`, so a web page you visit can't reach it and DNS-rebinding tricks don't work. Anything running
locally as you can use it. That's intentional.
