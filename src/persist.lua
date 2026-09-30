-- Loading and saving the board file.
-- Default location: <appdata>/KanbanEasy/board.json
--   Linux ~/.local/share/KanbanEasy, macOS ~/Library/Application Support/KanbanEasy, Windows %APPDATA%\KanbanEasy
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

--- Where the board lives. The same folder is used whether you run `love .` or a
--- packaged build (LÖVE would otherwise pick different save folders for each).
function persist.path()
  local env = os.getenv("KANBANEASY_DATA")
  if env and env ~= "" then
    local dir = env:match("^(.*)[/\\][^/\\]+$")
    if dir and dir ~= "" then
      ensureDir(dir)
    end
    return env, nil
  end
  local base = love.filesystem.getAppdataDirectory():gsub("[/\\]+$", "")
  local dir = base .. "/KanbanEasy"
  if not ensureDir(dir) then
    dir = love.filesystem.getSaveDirectory()
    love.filesystem.createDirectory("")
  end
  ensureDir(dir .. "/backups")
  return dir .. "/board.json", dir .. "/backups"
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
  local path, backups = persist.path()
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
  local self = { store = store, path = path, backups = backups, pending = nil, lastError = nil }
  if seeded then
    persist.save(self)
  end
  store:on(function()
    self.pending = self.pending or SAVE_DELAY
  end)
  -- One snapshot per weekday (first launch of the day), so there's always a week of history.
  local today = os.date("%Y-%m-%d")
  if backups and contents and not warning and store:setting("lastBackup") ~= today then
    writeAtomic(backups .. "/board-" .. os.date("%a") .. ".json", contents)
    store:setSetting("lastBackup", today)
  end
  return setmetatable(self, { __index = persist }), warning
end

function persist:update(dt)
  if self.pending then
    self.pending = self.pending - dt
    if self.pending <= 0 then
      self:save()
    end
  end
end

function persist:save()
  self.pending = nil
  local ok, err = writeAtomic(self.path, self.store:toJSON())
  self.lastError = not ok and err or nil
  return ok, err
end

function persist:flush()
  if self.pending then
    self:save()
  end
end

return persist
