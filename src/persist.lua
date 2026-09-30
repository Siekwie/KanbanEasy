-- Loading and saving the board file.
-- Default location: a KanbanEasy folder in your user directory
--   Windows C:\Users\<you>\KanbanEasy\board.json, macOS /Users/<you>/KanbanEasy, Linux ~/KanbanEasy
-- Set KANBANEASY_DATA=/path/to/board.json to keep it somewhere else (a git repo, Dropbox...).

local Store = require("src.store")

local persist = {}

local SAVE_DELAY = 0.4

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeAtomic(path, contents)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, err
  end
  f:write(contents)
  f:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    -- Windows refuses to rename over an existing file.
    os.remove(path)
    ok, rerr = os.rename(tmp, path)
  end
  return ok, rerr
end

local function isWindows()
  return love.system.getOS() == "Windows"
end

--- Make sure a directory exists and is writable.
local function ensureDir(dir)
  local probe = dir .. "/.kanbaneasy-write-test"
  local f = io.open(probe, "w")
  if not f then
    if isWindows() then
      os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" >NUL 2>NUL')
    else
      os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
    end
    f = io.open(probe, "w")
  end
  if f then
    f:close()
    os.remove(probe)
    return true
  end
  return false
end

local function slashes(p)
  return (p:gsub("\\", "/"):gsub("/+$", ""))
end

function persist.homeDir()
  return slashes(love.filesystem.getUserDirectory())
end

--- Older versions kept the board in the OS app-data folder; copy it over once.
local function migrateLegacy(dir)
  local target = dir .. "/board.json"
  if readFile(target) then
    return nil
  end
  local candidates = {
    slashes(love.filesystem.getAppdataDirectory()) .. "/KanbanEasy/board.json",
    slashes(love.filesystem.getSaveDirectory()) .. "/board.json",
  }
  for _, legacy in ipairs(candidates) do
    local contents = readFile(legacy)
    if contents and contents:match("%S") and writeAtomic(target, contents) then
      return legacy
    end
  end
  return nil
end

--- Where the board lives. The same folder is used whether you run `love .` or a
--- packaged build (LÖVE would otherwise pick different save folders for each).
function persist.path()
  local env = os.getenv("KANBANEASY_DATA")
  if env and env ~= "" then
    env = slashes(env)
    local dir = env:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
      ensureDir(dir)
    end
    return env, nil
  end
  local dir = persist.homeDir() .. "/KanbanEasy"
  local migrated
  if ensureDir(dir) then
    migrated = migrateLegacy(dir)
  else
    -- user folder not writable: fall back to LÖVE's own save folder
    love.filesystem.write(".keep", "")
    dir = slashes(love.filesystem.getSaveDirectory())
  end
  ensureDir(dir .. "/backups")
  return dir .. "/board.json", dir .. "/backups", migrated
end

--- Short, human-friendly version of a path ("~/KanbanEasy/board.json").
function persist.displayPath(path)
  local home = persist.homeDir()
  if home ~= "" and path:sub(1, #home + 1) == home .. "/" then
    path = "~" .. path:sub(#home + 1)
  end
  if isWindows() then
    path = path:gsub("/", "\\")
  end
  return path
end

--- Open the folder containing the board in Explorer / Finder / the file manager.
function persist:openFolder()
  local dir = self.path:match("^(.*)/[^/]+$") or self.path
  love.system.openURL("file://" .. (dir:sub(1, 1) == "/" and "" or "/") .. dir)
end

local function seed(store)
  local p = store:createProject({ name = "My Project", key = "KE" })
  local welcome = {
    {
      title = "Welcome to KanbanEasy",
      status = "todo",
      description = table.concat({
        "Click a card to open it. Everything is editable in place and saves automatically.",
        "",
        "Keyboard:",
        "• N — new issue (type #label @assignee !high inline)",
        "• / or Ctrl+F — search: words, @assignee, #label, p:high, is:todo",
        "• Arrows — move selection · Shift+Arrows — move the card",
        "• Enter — open · E — edit title · 0-4 — set priority",
        "• Ctrl+C — copy as Markdown · Ctrl+Shift+C — copy ID",
        "• Ctrl+Shift+P — copy a ready-to-paste agent prompt",
        "• Ctrl+Z / Ctrl+Shift+Z — undo / redo · Del — delete",
        "• Ctrl+B — sidebar · Ctrl+P — switch project",
      }, "\n"),
      labels = { "guide" },
    },
    {
      title = "Agents can use the local API",
      status = "todo",
      description = "curl localhost:7420 for the full list of endpoints.\n\n"
        .. "curl -d title='Fix the flaky test' -d status=todo localhost:7420/issues\n"
        .. "curl -d assignee=claude localhost:7420/claim",
      labels = { "guide", "api" },
    },
    { title = "Drag cards between columns", status = "in_progress", labels = { "guide" }, priority = 2 },
    { title = "Right-click a card for more actions", status = "backlog", labels = { "guide" } },
  }
  for _, w in ipairs(welcome) do
    store:createIssue(p.key, w)
  end
  store.undoStack = {}
  store:setSetting("activeProject", p.key)
end

--- Load the store from disk (or seed a fresh one). Returns store, path, warning.
function persist.load()
  local path, backups, migratedFrom = persist.path()
  local warning
  local contents = readFile(path)
  local store
  if contents and contents:match("%S") then
    local err
    store, err = Store.fromJSON(contents)
    if not store then
      -- Keep the broken file around rather than overwriting it.
      local broken = path .. ".broken-" .. os.time()
      writeAtomic(broken, contents)
      warning = "Could not read board file (" .. tostring(err) .. "). A copy was saved to " .. broken
    end
  end
  local seeded = false
  if not store then
    store = Store.new()
    seed(store)
    seeded = true
  end
  local self =
    { store = store, path = path, backups = backups, pending = nil, lastError = nil, lastContents = contents }
  if seeded then
    persist.save(self)
  end
  if migratedFrom then
    self.notice = "Moved your board to " .. persist.displayPath(path)
  end
  store:on(function()
    self.pending = self.pending or SAVE_DELAY
  end)
  -- One snapshot per weekday (first launch of the day), so there's always a week of history.
  local today = os.date("%Y-%m-%d")
  if backups and contents and not warning and (store:setting("lastBackup") ~= today or migratedFrom) then
    writeAtomic(backups .. "/board-" .. os.date("%a") .. ".json", contents)
    store:setSetting("lastBackup", today)
  end
  return setmetatable(self, { __index = persist }), warning
end

local WATCH_INTERVAL = 1.5

function persist:update(dt)
  if self.pending then
    self.pending = self.pending - dt
    if self.pending <= 0 then
      self:save()
    end
    return
  end
  -- Pick up edits made by something else (git pull, a script, another instance).
  self.watchTimer = (self.watchTimer or 0) + dt
  if self.watchTimer >= WATCH_INTERVAL then
    self.watchTimer = 0
    return self:checkExternal()
  end
end

--- Reload if the file on disk no longer matches what we last read or wrote.
function persist:checkExternal()
  local contents = readFile(self.path)
  if not contents or contents == self.lastContents or not contents:match("%S") then
    return false
  end
  local fresh = Store.fromJSON(contents)
  if not fresh then
    return false -- half-written or broken; try again later
  end
  self.lastContents = contents
  self.store:replaceData(fresh.data)
  return true
end

function persist:save()
  self.pending = nil
  local contents = self.store:toJSON()
  local ok, err = writeAtomic(self.path, contents)
  self.lastError = not ok and err or nil
  if ok then
    self.lastContents = contents
  end
  return ok, err
end

function persist:flush()
  if self.pending then
    self:save()
  end
end

return persist
