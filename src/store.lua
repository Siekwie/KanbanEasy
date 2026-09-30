-- The data model: projects, columns (statuses) and issues.
-- Pure Lua so it can be tested outside LÖVE and shared by the UI and the API.

local util = require("src.util")
local json = require("src.json")

local Store = {}
Store.__index = Store

Store.PRIORITIES = { "None", "Low", "Medium", "High", "Urgent" } -- index = priority + 1
local PRIORITY_ALIASES = {
  none = 0,
  ["0"] = 0,
  low = 1,
  ["1"] = 1,
  medium = 2,
  med = 2,
  normal = 2,
  ["2"] = 2,
  high = 3,
  ["3"] = 3,
  urgent = 4,
  critical = 4,
  ["4"] = 4,
}

Store.DEFAULT_COLUMNS = {
  { id = "backlog", name = "Backlog" },
  { id = "todo", name = "Todo" },
  { id = "in_progress", name = "In Progress" },
  { id = "review", name = "Review" },
  { id = "done", name = "Done" },
}

local STATUS_ALIASES = {
  doing = "in_progress",
  wip = "in_progress",
  started = "in_progress",
  active = "in_progress",
  progress = "in_progress",
  inprogress = "in_progress",
  complete = "done",
  completed = "done",
  closed = "done",
  finished = "done",
  resolved = "done",
  open = "todo",
  ready = "todo",
  reviewing = "review",
  in_review = "review",
  qa = "review",
  later = "backlog",
  icebox = "backlog",
}

local UNDO_LIMIT = 60
local RANK_STEP = 1024

-- Construction / serialization ---------------------------------------------

local function emptyData()
  return { version = 1, projects = {}, settings = json.object({}) }
end

function Store.new(data, opts)
  opts = opts or {}
  local self = setmetatable({}, Store)
  self.clock = opts.clock or os.time
  self.data = Store.normalize(data or emptyData())
  self.version = 0
  self.listeners = {}
  self.undoStack = {}
  self.redoStack = {}
  self.batchDepth = 0
  self.actor = "you"
  return self
end

--- Fill in missing fields so older or hand-edited files still load.
function Store.normalize(data)
  data.version = data.version or 1
  data.projects = data.projects or {}
  data.settings = data.settings or json.object({})
  for _, p in ipairs(data.projects) do
    p.name = p.name or p.key
    p.columns = p.columns or util.deepcopy(Store.DEFAULT_COLUMNS)
    if #p.columns == 0 then
      p.columns = util.deepcopy(Store.DEFAULT_COLUMNS)
    end
    p.issues = p.issues or {}
    local maxNum = 0
    for i, issue in ipairs(p.issues) do
      issue.num = issue.num or tonumber((issue.id or ""):match("%-(%d+)$")) or i
      issue.id = p.key .. "-" .. issue.num
      issue.title = issue.title or "Untitled"
      issue.description = issue.description or ""
      issue.priority = issue.priority or 0
      issue.labels = issue.labels or {}
      issue.assignee = issue.assignee or ""
      issue.activity = issue.activity or {}
      issue.rank = issue.rank or i * RANK_STEP
      issue.created = issue.created or os.time()
      issue.updated = issue.updated or issue.created
      local valid = false
      for _, c in ipairs(p.columns) do
        if c.id == issue.status then
          valid = true
        end
      end
      if not valid then
        issue.status = p.columns[1].id
      end
      maxNum = math.max(maxNum, issue.num)
    end
    p.nextNum = math.max(p.nextNum or 1, maxNum + 1)
  end
  return data
end

function Store.fromJSON(str, opts)
  local ok, data = pcall(json.decode, str)
  if not ok then
    return nil, data
  end
  if type(data) ~= "table" then
    return nil, "save file is not an object"
  end
  return Store.new(data, opts)
end

function Store:toJSON()
  return json.encode(self.data, true)
end

-- Change tracking & undo -----------------------------------------------------

function Store:on(fn)
  self.listeners[#self.listeners + 1] = fn
end

function Store:_emit(kind, info)
  self.version = self.version + 1
  for _, fn in ipairs(self.listeners) do
    fn(kind, info or {})
  end
end

--- Snapshot the state before a mutation (grouped when inside a batch).
function Store:_checkpoint()
  if self.batchDepth > 0 and self.batchCheckpointed then
    return
  end
  if self.batchDepth > 0 then
    self.batchCheckpointed = true
  end
  table.insert(self.undoStack, util.deepcopy(self.data.projects))
  if #self.undoStack > UNDO_LIMIT then
    table.remove(self.undoStack, 1)
  end
  self.redoStack = {}
end

--- Run fn with all mutations collapsed into a single undo step.
function Store:batch(fn)
  self.batchDepth = self.batchDepth + 1
  if self.batchDepth == 1 then
    self.batchCheckpointed = false
  end
  local ok, a, b = pcall(fn)
  self.batchDepth = self.batchDepth - 1
  if not ok then
    error(a, 0)
  end
  return a, b
end

--- Run fn with a given actor name recorded on activity entries.
function Store:as(actor, fn)
  local prev = self.actor
  self.actor = actor
  local ok, a, b = pcall(fn)
  self.actor = prev
  if not ok then
    error(a, 0)
  end
  return a, b
end

function Store:canUndo()
  return #self.undoStack > 0
end

function Store:canRedo()
  return #self.redoStack > 0
end

function Store:undo()
  local snap = table.remove(self.undoStack)
  if not snap then
    return false
  end
  table.insert(self.redoStack, self.data.projects)
  self.data.projects = snap
  self:_emit("undo")
  return true
end

function Store:redo()
  local snap = table.remove(self.redoStack)
  if not snap then
    return false
  end
  table.insert(self.undoStack, self.data.projects)
  self.data.projects = snap
  self:_emit("redo")
  return true
end

--- Swap in data loaded from disk (external edit). Undoable, keeps local UI settings.
function Store:replaceData(data)
  self:_checkpoint()
  local settings = self.data.settings
  self.data = Store.normalize(data)
  self.data.settings = settings
  self:_emit("reload")
end

-- Settings -------------------------------------------------------------------

function Store:setting(key, default)
  local v = self.data.settings[key]
  if v == nil then
    return default
  end
  return v
end

function Store:setSetting(key, value)
  if self.data.settings[key] ~= value then
    self.data.settings[key] = value
    self:_emit("settings", { key = key })
  end
end

-- Projects -------------------------------------------------------------------

function Store:projects()
  return self.data.projects
end

function Store:project(key)
  if not key then
    return nil
  end
  key = tostring(key):upper()
  for _, p in ipairs(self.data.projects) do
    if p.key == key then
      return p
    end
  end
  return nil
end

--- Suggest a short project key from a name ("Agent Tasks" -> "AT", "Scraper" -> "SCR").
function Store:suggestKey(name)
  local words = {}
  for w in tostring(name):gmatch("[%a%d]+") do
    words[#words + 1] = w
  end
  local key
  if #words >= 2 then
    key = ""
    for i = 1, math.min(4, #words) do
      key = key .. words[i]:sub(1, 1)
    end
  elseif #words == 1 then
    key = words[1]:sub(1, 3)
  else
    key = "P"
  end
  key = key:upper()
  if not key:match("^%a") then
    key = "P" .. key
  end
  local base, n = key, 2
  while self:project(key) do
    key = base .. n
    n = n + 1
  end
  return key
end

function Store:createProject(fields)
  local name = util.trim(tostring(fields.name or ""))
  if name == "" then
    return nil, "project name is required"
  end
  local key = fields.key and util.trim(tostring(fields.key)):upper() or ""
  if key == "" then
    key = self:suggestKey(name)
  end
  if not key:match("^%u[%u%d]*$") or #key > 8 then
    return nil, "project key must be 1-8 letters/digits starting with a letter"
  end
  if self:project(key) then
    return nil, "project key '" .. key .. "' already exists"
  end
  self:_checkpoint()
  local p = {
    key = key,
    name = name,
    nextNum = 1,
    columns = util.deepcopy(Store.DEFAULT_COLUMNS),
    issues = {},
    created = self.clock(),
  }
  table.insert(self.data.projects, p)
  self:_emit("project", { key = key })
  return p
end

function Store:updateProject(key, fields)
  local p = self:project(key)
  if not p then
    return nil, "no project '" .. tostring(key) .. "'"
  end
  if fields.name ~= nil then
    local name = util.trim(tostring(fields.name))
    if name == "" then
      return nil, "project name cannot be empty"
    end
    if name ~= p.name then
      self:_checkpoint()
      p.name = name
      self:_emit("project", { key = p.key })
    end
  end
  return p
end

function Store:deleteProject(key)
  local p = self:project(key)
  if not p then
    return nil, "no project '" .. tostring(key) .. "'"
  end
  self:_checkpoint()
  for i, q in ipairs(self.data.projects) do
    if q == p then
      table.remove(self.data.projects, i)
      break
    end
  end
  self:_emit("project", { key = p.key, deleted = true })
  return true
end

-- Columns --------------------------------------------------------------------

function Store:column(project, id)
  for i, c in ipairs(project.columns) do
    if c.id == id then
      return c, i
    end
  end
  return nil
end

--- Resolve loose status input ("In progress", "doing", "done") to a column id.
function Store:resolveStatus(project, s)
  if s == nil then
    return nil
  end
  s = tostring(s)
  local slug = util.slug(s)
  for _, c in ipairs(project.columns) do
    if c.id == s or c.id == slug or util.slug(c.name) == slug then
      return c.id
    end
  end
  local alias = STATUS_ALIASES[slug] or STATUS_ALIASES[slug:gsub("_", "")]
  if alias and self:column(project, alias) then
    return alias
  end
  -- Unique prefix match ("prog" -> in_progress)
  local found
  for _, c in ipairs(project.columns) do
    if #slug >= 2 and (c.id:find(slug, 1, true) or util.slug(c.name):find(slug, 1, true)) then
      if found then
        return nil
      end
      found = c.id
    end
  end
  return found
end

function Store:addColumn(key, name)
  local p = self:project(key)
  if not p then
    return nil, "no project '" .. tostring(key) .. "'"
  end
  name = util.trim(tostring(name or ""))
  if name == "" then
    return nil, "column name is required"
  end
  local id = util.slug(name)
  if id == "" then
    id = "col"
  end
  local base, n = id, 2
  while self:column(p, id) do
    id = base .. "_" .. n
    n = n + 1
  end
  self:_checkpoint()
  local col = { id = id, name = name }
  table.insert(p.columns, col)
  self:_emit("columns", { key = p.key })
  return col
end

function Store:renameColumn(key, id, name)
  local p = self:project(key)
  local c = p and self:column(p, id)
  if not c then
    return nil, "no such column"
  end
  name = util.trim(tostring(name or ""))
  if name == "" then
    return nil, "column name is required"
  end
  if name ~= c.name then
    self:_checkpoint()
    c.name = name
    self:_emit("columns", { key = p.key })
  end
  return c
end

--- Move a column left (-1) or right (+1).
function Store:shiftColumn(key, id, dir)
  local p = self:project(key)
  local c, i = nil, nil
  if p then
    c, i = self:column(p, id)
  end
  if not c then
    return nil, "no such column"
  end
  local j = i + dir
  if j < 1 or j > #p.columns then
    return c
  end
  self:_checkpoint()
  p.columns[i], p.columns[j] = p.columns[j], p.columns[i]
  self:_emit("columns", { key = p.key })
  return c
end

--- Delete a column; its issues move to the neighbouring column.
function Store:deleteColumn(key, id)
  local p = self:project(key)
  local c, i = nil, nil
  if p then
    c, i = self:column(p, id)
  end
  if not c then
    return nil, "no such column"
  end
  if #p.columns <= 1 then
    return nil, "a project needs at least one column"
  end
  self:_checkpoint()
  table.remove(p.columns, i)
  local fallback = p.columns[math.max(1, i - 1)].id
  local base = self:_maxRank(p, fallback)
  for _, issue in ipairs(self:issuesIn(p, id)) do
    base = base + RANK_STEP
    issue.status = fallback
    issue.rank = base
  end
  self:_emit("columns", { key = p.key })
  return true
end

-- Issues ---------------------------------------------------------------------

--- Find an issue by id ("KE-12", case-insensitive). Returns issue, project.
function Store:issue(id)
  if type(id) ~= "string" then
    return nil
  end
  local key, num = id:upper():match("^%s*([%u%d]+)%-(%d+)%s*$")
  if not key then
    return nil
  end
  local p = self:project(key)
  if not p then
    return nil
  end
  num = tonumber(num)
  for _, issue in ipairs(p.issues) do
    if issue.num == num then
      return issue, p
    end
  end
  return nil
end

local function byRank(a, b)
  if a.rank == b.rank then
    return a.num < b.num
  end
  return a.rank < b.rank
end

--- Issues in a column, ordered by rank.
function Store:issuesIn(project, status, filter)
  local out = {}
  for _, issue in ipairs(project.issues) do
    if issue.status == status and (not filter or filter(issue)) then
      out[#out + 1] = issue
    end
  end
  table.sort(out, byRank)
  return out
end

function Store:_maxRank(project, status)
  local m = 0
  for _, issue in ipairs(project.issues) do
    if issue.status == status and issue.rank > m then
      m = issue.rank
    end
  end
  return m
end

function Store:_minRank(project, status)
  local m
  for _, issue in ipairs(project.issues) do
    if issue.status == status and (not m or issue.rank < m) then
      m = issue.rank
    end
  end
  return m or RANK_STEP
end

local function parsePriority(v)
  if v == nil then
    return nil
  end
  if type(v) == "number" then
    return util.clamp(math.floor(v), 0, 4)
  end
  return PRIORITY_ALIASES[tostring(v):lower()]
end
Store.parsePriority = parsePriority

local function parseLabels(v)
  if type(v) == "table" then
    local s = {}
    for _, x in ipairs(v) do
      s[#s + 1] = tostring(x)
    end
    return util.parseList(table.concat(s, ","))
  end
  return util.parseList(tostring(v or ""))
end

function Store:_log(issue, kind, body, author)
  table.insert(issue.activity, {
    kind = kind,
    author = author or self.actor,
    body = body,
    time = self.clock(),
  })
end

--- Validate a partial update. Returns a table of normalized fields or nil, err.
function Store:_validate(project, fields, creating)
  local out = {}
  if fields.title ~= nil or creating then
    local title = util.trim(tostring(fields.title or ""):gsub("[\r\n]+", " "))
    if title == "" then
      return nil, "title is required"
    end
    out.title = title
  end
  if fields.description ~= nil then
    out.description = tostring(fields.description)
  end
  if fields.status ~= nil then
    local status = self:resolveStatus(project, fields.status)
    if not status then
      local names = {}
      for _, c in ipairs(project.columns) do
        names[#names + 1] = c.id
      end
      return nil, "unknown status '" .. tostring(fields.status) .. "' (use one of: " .. table.concat(names, ", ") .. ")"
    end
    out.status = status
  end
  if fields.priority ~= nil then
    local pr = parsePriority(fields.priority)
    if not pr then
      return nil, "priority must be none, low, medium, high or urgent"
    end
    out.priority = pr
  end
  if fields.labels ~= nil then
    out.labels = parseLabels(fields.labels)
  end
  if fields.assignee ~= nil then
    out.assignee = util.trim(tostring(fields.assignee))
  end
  return out
end

--- Create an issue. fields: title (required), description, status, priority, labels, assignee, top.
function Store:createIssue(key, fields)
  local p = self:project(key)
  if not p then
    return nil, "no project '" .. tostring(key) .. "'"
  end
  local v, err = self:_validate(p, fields, true)
  if not v then
    return nil, err
  end
  self:_checkpoint()
  local now = self.clock()
  local status = v.status or p.columns[1].id
  local rank
  if fields.top then
    rank = self:_minRank(p, status) - RANK_STEP
  else
    rank = self:_maxRank(p, status) + RANK_STEP
  end
  local issue = {
    num = p.nextNum,
    id = p.key .. "-" .. p.nextNum,
    title = v.title,
    description = v.description or "",
    status = status,
    priority = v.priority or 0,
    labels = v.labels or {},
    assignee = v.assignee or "",
    rank = rank,
    created = now,
    updated = now,
    activity = {},
  }
  p.nextNum = p.nextNum + 1
  table.insert(p.issues, issue)
  self:_log(issue, "event", "created in " .. self:column(p, status).name)
  self:_emit("issue", { id = issue.id, created = true, actor = self.actor })
  return issue
end

--- Update fields on an issue. Changing status appends the issue to the end of the new column.
function Store:updateIssue(id, fields)
  local issue, p = self:issue(id)
  if not issue then
    return nil, "no issue '" .. tostring(id) .. "'"
  end
  local v, err = self:_validate(p, fields, false)
  if not v then
    return nil, err
  end
  local changed = false
  for k, val in pairs(v) do
    local cur = issue[k]
    if type(val) == "table" then
      if table.concat(val, "\0") ~= table.concat(cur, "\0") then
        changed = true
      end
    elseif cur ~= val then
      changed = true
    end
  end
  if not changed then
    return issue
  end
  self:_checkpoint()
  if v.status and v.status ~= issue.status then
    self:_log(issue, "event", "moved " .. self:column(p, issue.status).name .. " → " .. self:column(p, v.status).name)
    issue.rank = self:_maxRank(p, v.status) + RANK_STEP
  end
  if v.assignee and v.assignee ~= issue.assignee then
    self:_log(issue, "event", v.assignee == "" and "unassigned" or ("assigned to " .. v.assignee))
  end
  if v.priority and v.priority ~= issue.priority then
    self:_log(issue, "event", "priority " .. Store.PRIORITIES[v.priority + 1]:lower())
  end
  for k, val in pairs(v) do
    issue[k] = val
  end
  issue.updated = self.clock()
  self:_emit("issue", { id = issue.id, actor = self.actor })
  return issue
end

--- Move an issue to a column at a 1-based position (nil = end).
function Store:moveIssue(id, status, index)
  local issue, p = self:issue(id)
  if not issue then
    return nil, "no issue '" .. tostring(id) .. "'"
  end
  local target = self:resolveStatus(p, status or issue.status)
  if not target then
    return nil, "unknown status '" .. tostring(status) .. "'"
  end
  local list = {}
  for _, other in ipairs(self:issuesIn(p, target)) do
    if other ~= issue then
      list[#list + 1] = other
    end
  end
  index = util.clamp(math.floor(index or (#list + 1)), 1, #list + 1)
  -- No-op if already in place
  if issue.status == target then
    local current = self:issuesIn(p, target)
    if current[index] == issue then
      return issue
    end
  end
  self:_checkpoint()
  local before, after = list[index - 1], list[index]
  local rank
  if before and after then
    rank = (before.rank + after.rank) / 2
    if math.abs(after.rank - before.rank) < 1e-6 then
      -- Ranks collapsed: renumber the column and retry.
      for i, other in ipairs(list) do
        other.rank = i * RANK_STEP
      end
      rank = (index - 0.5) * RANK_STEP
    end
  elseif before then
    rank = before.rank + RANK_STEP
  elseif after then
    rank = after.rank - RANK_STEP
  else
    rank = RANK_STEP
  end
  if issue.status ~= target then
    self:_log(issue, "event", "moved " .. self:column(p, issue.status).name .. " → " .. self:column(p, target).name)
    issue.status = target
  end
  issue.rank = rank
  issue.updated = self.clock()
  self:_emit("issue", { id = issue.id, moved = true, actor = self.actor })
  return issue
end

function Store:deleteIssue(id)
  local issue, p = self:issue(id)
  if not issue then
    return nil, "no issue '" .. tostring(id) .. "'"
  end
  self:_checkpoint()
  for i, other in ipairs(p.issues) do
    if other == issue then
      table.remove(p.issues, i)
      break
    end
  end
  self:_emit("issue", { id = issue.id, deleted = true, actor = self.actor })
  return true
end

function Store:addComment(id, body, author)
  local issue = self:issue(id)
  if not issue then
    return nil, "no issue '" .. tostring(id) .. "'"
  end
  body = util.trim(tostring(body or ""))
  if body == "" then
    return nil, "comment body is required"
  end
  self:_checkpoint()
  self:_log(issue, "comment", body, author)
  issue.updated = self.clock()
  self:_emit("issue", { id = issue.id, comment = true, actor = author or self.actor })
  return issue.activity[#issue.activity]
end

--- Duplicate an issue right below the original.
function Store:duplicateIssue(id)
  local issue, p = self:issue(id)
  if not issue then
    return nil, "no issue '" .. tostring(id) .. "'"
  end
  return self:batch(function()
    local copy = self:createIssue(p.key, {
      title = issue.title .. " (copy)",
      description = issue.description,
      status = issue.status,
      priority = issue.priority,
      labels = issue.labels,
      assignee = issue.assignee,
    })
    local list = self:issuesIn(p, issue.status)
    return self:moveIssue(copy.id, issue.status, util.indexOf(list, issue) + 1)
  end)
end

-- Queries --------------------------------------------------------------------

--- Build a predicate from a search query.
--- Supports plain words, @assignee, #label, is:status and p:priority tokens.
function Store.matcher(query)
  query = util.trim(query or "")
  if query == "" then
    return nil
  end
  local tests = {}
  for token in query:gmatch("%S+") do
    local lower = token:lower()
    if lower:sub(1, 1) == "@" and #lower > 1 then
      local who = lower:sub(2)
      tests[#tests + 1] = function(issue)
        return issue.assignee:lower():find(who, 1, true) ~= nil
      end
    elseif lower:sub(1, 1) == "#" and #lower > 1 then
      local label = lower:sub(2)
      tests[#tests + 1] = function(issue)
        for _, l in ipairs(issue.labels) do
          if l:lower():find(label, 1, true) then
            return true
          end
        end
        return false
      end
    elseif lower:match("^p:") then
      local pr = parsePriority(lower:sub(3))
      tests[#tests + 1] = function(issue)
        return issue.priority == pr
      end
    elseif lower:match("^is:") then
      local st = util.slug(lower:sub(4))
      tests[#tests + 1] = function(issue)
        return issue.status:find(st, 1, true) ~= nil
      end
    else
      tests[#tests + 1] = function(issue)
        return issue.title:lower():find(lower, 1, true) ~= nil
          or issue.id:lower() == lower
          or issue.description:lower():find(lower, 1, true) ~= nil
      end
    end
  end
  return function(issue)
    for _, t in ipairs(tests) do
      if not t(issue) then
        return false
      end
    end
    return true
  end
end

-- Export ---------------------------------------------------------------------

function Store:issueMarkdown(issue, withActivity)
  local _, p = self:issue(issue.id)
  local col = p and self:column(p, issue.status)
  local meta = { "Status: " .. (col and col.name or issue.status) }
  if issue.priority > 0 then
    meta[#meta + 1] = "Priority: " .. Store.PRIORITIES[issue.priority + 1]
  end
  if #issue.labels > 0 then
    meta[#meta + 1] = "Labels: " .. table.concat(issue.labels, ", ")
  end
  if issue.assignee ~= "" then
    meta[#meta + 1] = "Assignee: " .. issue.assignee
  end
  local out = { "## " .. issue.id .. ": " .. issue.title, "", table.concat(meta, " · ") }
  if util.trim(issue.description) ~= "" then
    out[#out + 1] = ""
    out[#out + 1] = issue.description
  end
  if withActivity then
    local comments = {}
    for _, a in ipairs(issue.activity) do
      if a.kind == "comment" then
        comments[#comments + 1] = "- **"
          .. a.author
          .. "** ("
          .. util.isoTime(a.time)
          .. "): "
          .. a.body:gsub("\n", "\n  ")
      end
    end
    if #comments > 0 then
      out[#out + 1] = ""
      out[#out + 1] = "### Comments"
      for _, c in ipairs(comments) do
        out[#out + 1] = c
      end
    end
  end
  return table.concat(out, "\n")
end

function Store:projectMarkdown(project, filter)
  local out = { "# " .. project.name .. " (" .. project.key .. ")" }
  for _, col in ipairs(project.columns) do
    local issues = self:issuesIn(project, col.id, filter)
    out[#out + 1] = ""
    out[#out + 1] = "## " .. col.name .. " (" .. #issues .. ")"
    for _, issue in ipairs(issues) do
      local extra = {}
      if issue.priority > 0 then
        extra[#extra + 1] = Store.PRIORITIES[issue.priority + 1]:lower()
      end
      if issue.assignee ~= "" then
        extra[#extra + 1] = "@" .. issue.assignee
      end
      for _, l in ipairs(issue.labels) do
        extra[#extra + 1] = "#" .. l
      end
      local check = col.id == "done" and "[x]" or "[ ]"
      out[#out + 1] = "- "
        .. check
        .. " "
        .. issue.id
        .. " "
        .. issue.title
        .. (#extra > 0 and (" (" .. table.concat(extra, " ") .. ")") or "")
    end
  end
  return table.concat(out, "\n")
end

return Store
