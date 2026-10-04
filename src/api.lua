-- HTTP API router. Pure Lua: takes a parsed request table, returns a response table.
-- The socket layer lives in server.lua so this can be tested without LÖVE.

local json = require("src.json")
local util = require("src.util")
local Store = require("src.store")

local api = {}

api.HELP = [[
KanbanEasy local API  (JSON in, JSON out; add ?format=md for markdown)

Bodies may be JSON or form-encoded (curl -d title=...). Set an X-Actor header
(or "actor" field) so activity shows who did what; defaults to "agent".
"project" may be omitted when the board only has one project; the project
currently open in the app is used otherwise.

  GET    /                         this help
  GET    /projects                 list projects (+ column counts)
  POST   /projects                 {name, key?}
  GET    /projects/KEY             project with columns and issues   (?format=md)
  PATCH  /projects/KEY             {name?, me?, agent?, default_assignee?}
  POST   /projects/KEY/columns     {name}
  PATCH  /projects/KEY/columns/ID  {name?, auto_assign?, instructions?}
                                   auto_assign: who gets cards that land in the column
                                   ("@agent", "@me", a name, "-" to unassign, "" for no rule)
  GET    /issues                   ?project=&status=&assignee=&label=&q=&limit=   (?format=md)
  POST   /issues                   {project?, title, description?, status?, priority?, labels?, assignee?, top?}
  GET    /issues/ID                one issue with activity           (?format=md)
  PATCH  /issues/ID                any of {title, description, status, priority, labels, assignee}
                                   every issue has a `rev` that grows with each change; send it back as
                                   `If-Match: <rev>` (or a `rev` field) on PATCH, move, comments and DELETE
                                   to get 409 instead of overwriting a card that changed since you read it
  POST   /issues/ID/move           {status, index?}  (index is 1-based within the column)
  POST   /issues/ID/comments       {body, author?}
  DELETE /issues/ID
  POST   /claim                    {project?, from?="todo", to?="in_progress", assignee}
                                   takes the top unassigned (or already-yours) issue in `from`,
                                   assigns it and moves it to `to`. 404 when nothing to claim.

Status accepts column ids or names ("in_progress", "In Progress", "doing").
Assignee accepts a name or the roles "me" / "agent" (set per project; see GET /projects/KEY).
An issue's "instructions" are its column's: what to do with cards in that status.
Priority: none | low | medium | high | urgent (or 0-4). Labels: array or "a, b".
Search (q): words, @assignee, #label, p:high, is:todo.
]]

-- Helpers --------------------------------------------------------------------

local function urldecode(s)
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end
api.urldecode = urldecode

local function parseForm(s)
  local out = {}
  for pair in s:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    if k and k ~= "" then
      out[urldecode(k)] = urldecode(v)
    end
  end
  return out
end
api.parseForm = parseForm

--- Split "/issues/KE-1?format=md" into path segments and a query table.
function api.parseTarget(target)
  local path, qs = target:match("^([^?]*)%??(.*)$")
  local segs = {}
  for seg in path:gmatch("[^/]+") do
    segs[#segs + 1] = urldecode(seg)
  end
  return segs, parseForm(qs or "")
end

local function response(status, body, contentType)
  if type(body) == "table" then
    return { status = status, body = json.encode(body, true) .. "\n", contentType = "application/json" }
  end
  return { status = status, body = body, contentType = contentType or "text/plain; charset=utf-8" }
end

local function err(status, msg)
  return response(status, { error = msg })
end

local function issueJSON(store, issue, project, withActivity)
  local col = store:column(project, issue.status)
  local out = {
    instructions = col and col.instructions,
    id = issue.id,
    project = project.key,
    title = issue.title,
    description = issue.description,
    status = issue.status,
    status_name = col and col.name or issue.status,
    priority = Store.PRIORITIES[issue.priority + 1]:lower(),
    labels = issue.labels,
    assignee = issue.assignee,
    created = util.isoTime(issue.created),
    updated = util.isoTime(issue.updated),
    rev = issue.rev,
  }
  local list = store:issuesIn(project, issue.status)
  out.position = util.indexOf(list, issue)
  if withActivity then
    local act = {}
    for i, a in ipairs(issue.activity) do
      act[i] = { kind = a.kind, author = a.author, body = a.body, time = util.isoTime(a.time) }
    end
    out.activity = act
  end
  return out
end

--- Optional optimistic-concurrency check. A caller that sends `If-Match` (or a `rev` field) is
--- rejected with 409 when the issue changed since it read it. Returns nil when the write may go on.
local function staleRev(store, req, id)
  local sent = req.headers["if-match"] or req.body.rev
  if sent == nil or sent == "" then
    return nil
  end
  local issue, p = store:issue(id)
  if not issue then
    return nil -- the handler reports the 404
  end
  if tonumber(tostring(sent):match("%d+")) == issue.rev then
    return nil
  end
  local cur = issueJSON(store, issue, p, false)
  return response(409, {
    error = ("issue %s changed since you read it (your rev %s, current %d)"):format(issue.id, tostring(sent), issue.rev),
    current = cur,
  })
end

local function columnJSON(store, p, c)
  return {
    id = c.id,
    name = c.name,
    count = #store:issuesIn(p, c.id),
    auto_assign = store:ruleAssignee(p, c),
    instructions = c.instructions,
  }
end

local function projectSummary(store, p)
  local cols = {}
  for i, c in ipairs(p.columns) do
    cols[i] = columnJSON(store, p, c)
  end
  return {
    key = p.key,
    name = p.name,
    columns = cols,
    issue_count = #p.issues,
    people = { me = p.people.me, agent = p.people.agent },
    default_assignee = store:resolveAssignee(p, p.defaultAssignee),
  }
end

--- Pick the project for a request: explicit, the only one, or the active one in the UI.
local function resolveProject(store, key)
  if key and key ~= "" then
    local p = store:project(key)
    if not p then
      return nil, "no project '" .. tostring(key) .. "'"
    end
    return p
  end
  local projects = store:projects()
  if #projects == 1 then
    return projects[1]
  end
  local active = store:project(store:setting("activeProject"))
  if active then
    return active
  end
  if #projects == 0 then
    return nil, "no projects yet; POST /projects first"
  end
  return nil, 'several projects exist; pass "project"'
end

local function wantsMarkdown(req)
  local f = req.query.format
  return f == "md" or f == "markdown"
end

local function markdown(body)
  return response(200, body .. "\n", "text/markdown; charset=utf-8")
end

-- Routes ---------------------------------------------------------------------

local routes = {}

local function route(method, pattern, fn)
  routes[#routes + 1] = { method = method, pattern = pattern, fn = fn }
end

route("GET", {}, function()
  return response(200, api.HELP)
end)

route("GET", { "help" }, function()
  return response(200, api.HELP)
end)

route("GET", { "projects" }, function(store)
  local out = {}
  for i, p in ipairs(store:projects()) do
    out[i] = projectSummary(store, p)
  end
  return response(200, out)
end)

route("POST", { "projects" }, function(store, req)
  local p, e = store:createProject({ name = req.body.name, key = req.body.key })
  if not p then
    return err(400, e)
  end
  return response(201, projectSummary(store, p))
end)

route("GET", { "projects", ":key" }, function(store, req, key)
  local p = store:project(key)
  if not p then
    return err(404, "no project '" .. key .. "'")
  end
  if wantsMarkdown(req) then
    return markdown(store:projectMarkdown(p))
  end
  local out = projectSummary(store, p)
  out.issues = {}
  for _, c in ipairs(p.columns) do
    for _, issue in ipairs(store:issuesIn(p, c.id)) do
      out.issues[#out.issues + 1] = issueJSON(store, issue, p, false)
    end
  end
  return response(200, out)
end)

route("PATCH", { "projects", ":key" }, function(store, req, key)
  local b = req.body
  local p, e = store:updateProject(key, {
    name = b.name,
    me = b.me,
    agent = b.agent,
    defaultAssignee = b.default_assignee or b.defaultAssignee,
  })
  if not p then
    return err(p == nil and e:find("^no project") and 404 or 400, e)
  end
  return response(200, projectSummary(store, p))
end)

route("POST", { "projects", ":key", "columns" }, function(store, req, key)
  if not store:project(key) then
    return err(404, "no project '" .. key .. "'")
  end
  local c, e = store:addColumn(key, req.body.name)
  if not c then
    return err(400, e)
  end
  return response(201, c)
end)

route("PATCH", { "projects", ":key", "columns", ":id" }, function(store, req, key, id)
  local p = store:project(key)
  if not p then
    return err(404, "no project '" .. key .. "'")
  end
  local colId = store:resolveStatus(p, id)
  if not colId then
    return err(404, "no column '" .. id .. "'")
  end
  local b = req.body
  local result
  local ok, e = pcall(function()
    store:batch(function()
      if b.name ~= nil then
        local c, e1 = store:renameColumn(key, colId, b.name)
        if not c then
          error(e1, 0)
        end
      end
      local c, n = store:setColumnRules(key, colId, {
        assign = b.auto_assign or b.assign,
        instructions = b.instructions,
      })
      result = columnJSON(store, p, c)
      result.reassigned = n
    end)
  end)
  if not ok then
    return err(400, e)
  end
  return response(200, result)
end)

route("POST", { "projects", ":key", "columns", ":id" }, function(store, req, key, id)
  return routes.patchColumn(store, req, key, id)
end)

route("GET", { "issues" }, function(store, req)
  local q = req.query
  local projects
  if q.project and q.project ~= "" then
    local p = store:project(q.project)
    if not p then
      return err(404, "no project '" .. q.project .. "'")
    end
    projects = { p }
  else
    projects = store:projects()
  end
  local search = {}
  if q.q then
    search[#search + 1] = q.q
  end
  if q.assignee then
    search[#search + 1] = "@" .. q.assignee:gsub("^@", "")
  end
  if q.label then
    search[#search + 1] = "#" .. q.label
  end
  local limit = tonumber(q.limit) or math.huge
  local out, lines = {}, {}
  for _, p in ipairs(projects) do
    local match = Store.matcher(table.concat(search, " "), p.people)
    local status = q.status and store:resolveStatus(p, q.status)
    if not q.status or status then
      for _, c in ipairs(p.columns) do
        if not status or c.id == status then
          for _, issue in ipairs(store:issuesIn(p, c.id, match)) do
            if #out < limit then
              out[#out + 1] = issueJSON(store, issue, p, false)
              lines[#lines + 1] = "- "
                .. issue.id
                .. " ["
                .. c.name
                .. "] "
                .. issue.title
                .. (issue.assignee ~= "" and (" @" .. issue.assignee) or "")
            end
          end
        end
      end
    end
  end
  if wantsMarkdown(req) then
    return markdown(#lines > 0 and table.concat(lines, "\n") or "_no issues_")
  end
  return response(200, out)
end)

route("POST", { "issues" }, function(store, req)
  local b = req.body
  local p, e = resolveProject(store, b.project)
  if not p then
    return err(400, e)
  end
  local top = b.top == true or b.top == "true" or b.top == "1"
  local issue, e2 = store:createIssue(p.key, {
    title = b.title,
    description = b.description,
    status = b.status,
    priority = b.priority,
    labels = b.labels,
    assignee = b.assignee,
    top = top,
  })
  if not issue then
    return err(400, e2)
  end
  return response(201, issueJSON(store, issue, p, false))
end)

route("GET", { "issues", ":id" }, function(store, req, id)
  local issue, p = store:issue(id)
  if not issue then
    return err(404, "no issue '" .. id .. "'")
  end
  if wantsMarkdown(req) then
    return markdown(store:issueMarkdown(issue, true, true))
  end
  return response(200, issueJSON(store, issue, p, true))
end)

route("PATCH", { "issues", ":id" }, function(store, req, id)
  local b = req.body
  local stale = staleRev(store, req, id)
  if stale then
    return stale
  end
  local issue, e = store:updateIssue(id, {
    title = b.title,
    description = b.description,
    status = b.status,
    priority = b.priority,
    labels = b.labels,
    assignee = b.assignee,
  })
  if not issue then
    return err(e:find("^no issue") and 404 or 400, e)
  end
  local _, p = store:issue(id)
  return response(200, issueJSON(store, issue, p, false))
end)

-- Some clients can't send PATCH; accept POST too.
route("POST", { "issues", ":id" }, function(store, req, id)
  return routes.patchIssue(store, req, id)
end)

route("POST", { "issues", ":id", "move" }, function(store, req, id)
  local stale = staleRev(store, req, id)
  if stale then
    return stale
  end
  local issue, e = store:moveIssue(id, req.body.status, tonumber(req.body.index))
  if not issue then
    return err(e:find("^no issue") and 404 or 400, e)
  end
  local _, p = store:issue(id)
  return response(200, issueJSON(store, issue, p, false))
end)

route("POST", { "issues", ":id", "comments" }, function(store, req, id)
  local stale = staleRev(store, req, id)
  if stale then
    return stale
  end
  local entry, e =
    store:addComment(id, req.body.body or req.body.text or req.body.comment, req.body.author or req.actor)
  if not entry then
    return err(e:find("^no issue") and 404 or 400, e)
  end
  return response(201, { author = entry.author, body = entry.body, time = util.isoTime(entry.time) })
end)

route("DELETE", { "issues", ":id" }, function(store, req, id)
  local stale = staleRev(store, req, id)
  if stale then
    return stale
  end
  local ok, e = store:deleteIssue(id)
  if not ok then
    return err(404, e)
  end
  return response(200, { deleted = id:upper() })
end)

route("POST", { "claim" }, function(store, req)
  local b = req.body
  local p, e = resolveProject(store, b.project)
  if not p then
    return err(400, e)
  end
  local assignee = store:resolveAssignee(p, b.assignee or req.actor or "")
  if assignee == "" then
    return err(400, "assignee is required")
  end
  local from = store:resolveStatus(p, b.from or "todo")
  local to = store:resolveStatus(p, b.to or "in_progress")
  if not from or not to then
    return err(400, "unknown from/to status")
  end
  local actor = req.headers["x-actor"] and req.actor or assignee
  for _, issue in ipairs(store:issuesIn(p, from)) do
    if issue.assignee == "" or issue.assignee:lower() == assignee:lower() then
      store:as(actor, function()
        -- one update so the claimer wins over any auto-assign rule on `to`
        store:updateIssue(issue.id, { assignee = assignee, status = to })
      end)
      return response(200, issueJSON(store, issue, p, true))
    end
  end
  return err(404, "nothing to claim in " .. from)
end)

-- Find the PATCH handlers for the POST aliases above.
for _, r in ipairs(routes) do
  if r.method == "PATCH" and r.pattern[1] == "issues" then
    routes.patchIssue = r.fn
  elseif r.method == "PATCH" and r.pattern[3] == "columns" then
    routes.patchColumn = r.fn
  end
end

local function matchRoute(segs, pattern)
  if #segs ~= #pattern then
    return nil
  end
  local params = {}
  for i, p in ipairs(pattern) do
    if p:sub(1, 1) == ":" then
      params[#params + 1] = segs[i]
    elseif p ~= segs[i] then
      return nil
    end
  end
  return params
end

--- Parse the request body into a table (JSON or form-encoded).
local function parseBody(req)
  local raw = req.rawBody or ""
  if util.trim(raw) == "" then
    return {}
  end
  local ctype = (req.headers["content-type"] or ""):lower()
  if ctype:find("x-www-form-urlencoded", 1, true) and not raw:match("^%s*[{%[]") then
    return parseForm(raw)
  end
  local ok, body = pcall(json.decode, raw)
  if not ok then
    return nil, "invalid JSON body: " .. tostring(body)
  end
  if type(body) ~= "table" then
    return nil, "body must be a JSON object"
  end
  return body
end

--- Browsers send Origin / Sec-Fetch-Site; local agents and curl don't.
--- Refusing those blocks random websites from poking the board.
local function isBrowser(req)
  return req.headers["origin"] ~= nil or req.headers["sec-fetch-site"] ~= nil
end

local function badHost(req)
  local host = (req.headers["host"] or ""):lower():gsub(":%d+$", "")
  return host ~= "" and host ~= "localhost" and host ~= "127.0.0.1" and host ~= "[::1]"
end

--- Handle a request table {method, target, headers, rawBody}. Returns {status, body, contentType}.
function api.handle(store, req)
  req.headers = req.headers or {}
  if isBrowser(req) or badHost(req) then
    return err(403, "browser/remote requests are not allowed")
  end
  local segs, query = api.parseTarget(req.target or "/")
  req.query = query
  local body, e = parseBody(req)
  if not body then
    return err(400, e)
  end
  req.body = body
  req.actor = util.trim(tostring(req.headers["x-actor"] or body.actor or "agent"))
  if req.actor == "" then
    req.actor = "agent"
  end
  local method = (req.method or "GET"):upper()
  if method == "HEAD" then
    method = "GET"
  end
  local pathMatched = false
  for _, r in ipairs(routes) do
    local params = matchRoute(segs, r.pattern)
    if params then
      pathMatched = true
      if r.method == method then
        local ok, res = pcall(function()
          return store:as(req.actor, function()
            return r.fn(store, req, unpack(params))
          end)
        end)
        if not ok then
          return err(500, tostring(res))
        end
        return res
      end
    end
  end
  if pathMatched then
    return err(405, "method not allowed")
  end
  return err(404, "not found; GET / for help")
end

return api
