-- Application state and actions that tie the store, the API server and the views together.

local ui = require("src.ui.core")
local theme = require("src.ui.theme")
local TextInput = require("src.ui.textinput")
local overlay = require("src.ui.overlay")
local board = require("src.ui.board")
local detail = require("src.ui.detail")
local chrome = require("src.ui.chrome")
local Store = require("src.store")
local util = require("src.util")

local App = {}
App.__index = App

function App.new(persist, server)
  local self = setmetatable({}, App)
  self.persist = persist
  self.store = persist.store
  self.server = server
  self.scroll = {}
  self.anim = {}
  self.flash = {}
  self.collapsed = {}
  self.frame = 0
  self.selected = nil
  self.openIssue = nil
  self.sidebarOpen = self.store:setting("sidebar", true)
  theme.use(self.store:setting("theme", "dark"))

  self.search = TextInput.new({
    placeholder = "Search",
    padX = 32,
    id = "search",
    onChange = function()
      self:applySearch()
    end,
    onSubmit = function()
      ui.blur()
    end,
  })

  self.store:on(function(kind, info)
    ui.dirty = true
    if kind == "undo" or kind == "redo" or kind == "project" then
      self:ensureProject()
    end
    if kind == "issue" and info.id and info.actor ~= "you" and not info.deleted then
      self.flash[info.id] = ui.time
    end
    if info.deleted and info.id == self.openIssue then
      detail.close(self)
    end
    if (kind == "undo" or kind == "redo") and self.openIssue and not self.store:issue(self.openIssue) then
      detail.close(self)
    end
  end)
  self:ensureProject()
  return self
end

-- Project & view state ----------------------------------------------------------------

function App:ensureProject()
  local store = self.store
  local p = store:project(store:setting("activeProject"))
  if not p then
    p = store:projects()[1]
    if not p then
      p = store:createProject({ name = "My Project", key = "KE" })
      store.undoStack = {}
    end
    store:setSetting("activeProject", p.key)
  end
  self.project = p
  return p
end

function App:switchProject(key)
  if self.project and self.project.key == key then
    return
  end
  detail.close(self)
  self.store:setSetting("activeProject", key)
  self.selected = nil
  self.quickAdd = nil
  self.scroll = {}
  self.anim = {}
  self.collapsed = {}
  self:ensureProject()
  self.drawerOpen = false
end

function App.narrow()
  return love.graphics.getWidth() < 760
end

--- Wide windows toggle the docked sidebar (remembered); narrow ones use a drawer.
function App:toggleSidebar()
  if App.narrow() then
    self.drawerOpen = not self.drawerOpen
  else
    self.sidebarOpen = not self.sidebarOpen
    self.store:setSetting("sidebar", self.sidebarOpen)
  end
end

function App:toggleTheme()
  theme.use(theme.name == "dark" and "light" or "dark")
  self.store:setSetting("theme", theme.name)
end

function App:applySearch()
  self.filter = Store.matcher(self.search.text)
  ui.dirty = true
end

function App:copy(text, message)
  love.system.setClipboardText(text)
  overlay.toast(message or "Copied")
end

function App:apiBase()
  local port = self.server and self.server.port or 7420
  return "http://127.0.0.1:" .. port
end

--- A ready-to-paste prompt that hands an issue to a coding agent.
function App:agentPrompt(issue)
  local base = self:apiBase()
  local md = self.store:issueMarkdown(issue, true)
  return table.concat({
    "Please work on this task from my kanban board.",
    "",
    md,
    "",
    "Keep the board updated through its local API while you work:",
    "- Mark it in progress: curl -s -X PATCH -d status=in_progress -d assignee=agent "
      .. base
      .. "/issues/"
      .. issue.id,
    "- Post progress notes: curl -s -H 'X-Actor: agent' --data-urlencode body='<what you did>' "
      .. base
      .. "/issues/"
      .. issue.id
      .. "/comments",
    "- When done, move it to review: curl -s -X PATCH -d status=review " .. base .. "/issues/" .. issue.id,
    "- File follow-ups you discover: curl -s -d title='<title>' -d status=backlog -d project=" .. (select(
      2,
      self.store:issue(issue.id)
    ) or self.project).key .. " " .. base .. "/issues",
  }, "\n")
end

--- Generic instructions for an agent's system prompt / AGENTS.md.
function App:agentInstructions()
  local base = self:apiBase()
  local key = self.project.key
  return table.concat({
    "## Task board",
    "",
    "Work is tracked on a local kanban board (KanbanEasy) with an HTTP API at " .. base .. ".",
    "Project key: " .. key .. ". Statuses: backlog, todo, in_progress, review, done.",
    "",
    "- See the board:        curl -s '" .. base .. "/projects/" .. key .. "?format=md'",
    "- Take the next task:   curl -s -d assignee=<your-name> -d project=" .. key .. " " .. base .. "/claim",
    "- Read a task:          curl -s '" .. base .. "/issues/" .. key .. "-1?format=md'",
    "- Log progress:         curl -s -H 'X-Actor: <your-name>' --data-urlencode body='...' "
      .. base
      .. "/issues/"
      .. key
      .. "-1/comments",
    "- Change status:        curl -s -X PATCH -d status=review " .. base .. "/issues/" .. key .. "-1",
    "- Create a task:        curl -s -d project=" .. key .. " -d title='...' -d status=todo " .. base .. "/issues",
    "- Full API reference:   curl -s " .. base,
    "",
    "Move a task to review (not done) when you finish; a human will close it.",
  }, "\n")
end

-- Issue actions -------------------------------------------------------------------------

function App:openIssueDetail(id)
  detail.open(self, id)
end

--- Parse quick-add text: "Fix login #bug @claude !high" -> fields.
function App.parseQuickAdd(text)
  local labels, assignee, priority = {}, nil, nil
  local words = {}
  for word in text:gmatch("%S+") do
    local lower = word:lower()
    if word:match("^#[^#%s]+$") then
      labels[#labels + 1] = word:sub(2)
    elseif word:match("^@[^@%s]+$") then
      assignee = word:sub(2)
    elseif lower:match("^!+$") then
      priority = math.min(4, #lower + 1)
    elseif lower:match("^!%a+$") and Store.parsePriority(lower:sub(2)) then
      priority = Store.parsePriority(lower:sub(2))
    else
      words[#words + 1] = word
    end
  end
  return {
    title = table.concat(words, " "),
    labels = labels,
    assignee = assignee,
    priority = priority,
  }
end

function App:defaultColumn()
  local p = self.project
  local sel = self.selected and self.store:issue(self.selected)
  if sel then
    return sel.status
  end
  if self.store:column(p, "todo") then
    return "todo"
  end
  return p.columns[1].id
end

function App:startQuickAdd(colId)
  colId = colId or self:defaultColumn()
  detail.close(self)
  if self.quickAdd and self.quickAdd.col == colId then
    self.quickAdd.input:focus()
    return
  end
  local qa = { col = colId }
  qa.input = TextInput.new({
    multiline = true,
    noNewlines = true,
    placeholder = "Issue title  (#label @who !high)",
    id = "quickadd",
    padX = 10,
    padY = 8,
    lineSpacing = 1.3,
    escapeCancels = true,
    onCancel = function()
      self.quickAdd = nil
    end,
    onSubmit = function(text, input)
      local fields = App.parseQuickAdd(text)
      if util.trim(fields.title) == "" then
        return
      end
      fields.status = qa.col
      fields.top = true
      local issue, err = self.store:createIssue(self.project.key, fields)
      if not issue then
        overlay.toast(err, "error")
        return
      end
      input:setText("")
      input.history, input.future = {}, {}
      self.selected = issue.id
      if ui.shift() then
        self.quickAdd = nil
        self:openIssueDetail(issue.id)
      end
    end,
  })
  self.quickAdd = qa
  qa.input:focus()
  board.scrollState(self, "col:" .. colId).target = 0
  if self.layout and not self.layout.list then
    for _, C in ipairs(self.layout.cols) do
      if C.col.id == colId then
        local hs = board.scrollState(self, "board-x")
        if C.x - 14 < hs.target or C.x + self.layout.colW + 14 > hs.target + self.layout.w then
          hs.target = C.x - 14
        end
      end
    end
  end
  self.collapsed[colId] = nil
end

function App:deleteIssue(id)
  local ok = self.store:deleteIssue(id)
  if ok then
    overlay.toast("Deleted " .. id .. "  ·  Ctrl+Z to undo")
    if self.selected == id then
      self.selected = nil
    end
  end
end

function App:moveSelected(dx, dy)
  local issue = self.selected and self.store:issue(self.selected)
  if not issue then
    return
  end
  local p = self.project
  local _, ci = self.store:column(p, issue.status)
  if dx ~= 0 then
    local target = p.columns[ci + dx]
    if target then
      self.store:moveIssue(issue.id, target.id)
    end
  else
    local list = self.store:issuesIn(p, issue.status)
    local idx = util.indexOf(list, issue)
    local newIdx = idx + dy
    if newIdx >= 1 and newIdx <= #list then
      self.store:moveIssue(issue.id, issue.status, newIdx)
    end
  end
  board.reveal(self, issue.id)
end

--- Arrow-key navigation between cards (uses the last drawn layout, so it respects filters).
function App:navigate(dx, dy)
  local L = self.layout
  if not L then
    return
  end
  local ci, idx
  for i, C in ipairs(L.cols) do
    for j, card in ipairs(C.cards) do
      if card.issue.id == self.selected then
        ci, idx = i, j
      end
    end
  end
  if not ci then
    for _, C in ipairs(L.cols) do
      if #C.cards > 0 and not C.collapsed then
        self.selected = C.cards[1].issue.id
        board.reveal(self, self.selected)
        return
      end
    end
    return
  end
  if dy ~= 0 then
    local C = L.cols[ci]
    local j = idx + dy
    if C.cards[j] then
      self.selected = C.cards[j].issue.id
    elseif L.list then
      -- flow into the next/previous section
      local k = ci + dy
      while L.cols[k] do
        local D = L.cols[k]
        if #D.cards > 0 and not D.collapsed then
          self.selected = (dy > 0 and D.cards[1] or D.cards[#D.cards]).issue.id
          break
        end
        k = k + dy
      end
    end
  else
    local k = ci + dx
    while L.cols[k] do
      local D = L.cols[k]
      if #D.cards > 0 and not D.collapsed then
        self.selected = D.cards[math.min(idx, #D.cards)].issue.id
        break
      end
      k = k + dx
    end
  end
  board.reveal(self, self.selected)
  if self.openIssue and self.openIssue ~= self.selected then
    detail.open(self, self.selected)
  end
end

-- Menus ------------------------------------------------------------------------------------

function App:copyItems(issue)
  local md = self.store:issueMarkdown(issue, false)
  return {
    {
      label = "Copy ID",
      icon = "copy",
      hint = "Ctrl+Shift+C",
      onSelect = function()
        self:copy(issue.id, "Copied " .. issue.id)
      end,
    },
    {
      label = "Copy title",
      icon = "copy",
      onSelect = function()
        self:copy(issue.title, "Copied title")
      end,
    },
    {
      label = "Copy ID + title",
      icon = "copy",
      onSelect = function()
        self:copy(issue.id .. " " .. issue.title, "Copied " .. issue.id)
      end,
    },
    {
      label = "Copy as Markdown",
      icon = "copy",
      hint = "Ctrl+C",
      onSelect = function()
        self:copy(md, "Copied " .. issue.id .. " as Markdown")
      end,
    },
    {
      label = "Copy with comments",
      icon = "copy",
      onSelect = function()
        self:copy(self.store:issueMarkdown(issue, true), "Copied " .. issue.id .. " with comments")
      end,
    },
    {
      label = "Copy agent prompt",
      icon = "agent",
      hint = "Ctrl+Shift+P",
      onSelect = function()
        self:copy(self:agentPrompt(issue), "Copied agent prompt for " .. issue.id)
      end,
    },
    {
      label = "Copy API URL",
      icon = "link",
      onSelect = function()
        self:copy(self:apiBase() .. "/issues/" .. issue.id, "Copied API URL")
      end,
    },
  }
end

function App:copyMenu(issue, x, y)
  overlay.openMenu(x, y, self:copyItems(issue), { minW = 230 })
end

function App:cardMenu(issue, x, y)
  local items = {
    {
      label = "Open",
      hint = "Enter",
      onSelect = function()
        self:openIssueDetail(issue.id)
      end,
    },
    { separator = true },
  }
  for _, item in ipairs(self:copyItems(issue)) do
    items[#items + 1] = item
  end
  items[#items + 1] = { header = "Move to" }
  local _, p = self.store:issue(issue.id)
  for _, col in ipairs(p.columns) do
    items[#items + 1] = {
      label = col.name,
      dot = theme.statusColor(col.id),
      checked = col.id == issue.status,
      onSelect = function()
        self.store:updateIssue(issue.id, { status = col.id })
      end,
    }
  end
  items[#items + 1] = { separator = true }
  items[#items + 1] = {
    label = "Duplicate",
    icon = "copy",
    hint = "Ctrl+D",
    onSelect = function()
      local copy = self.store:duplicateIssue(issue.id)
      if copy then
        self.selected = copy.id
      end
    end,
  }
  items[#items + 1] = {
    label = "Delete",
    icon = "trash",
    danger = true,
    hint = "Del",
    onSelect = function()
      self:deleteIssue(issue.id)
    end,
  }
  overlay.openMenu(x, y, items, { minW = 240 })
end

function App:statusMenu(issue, x, y)
  local _, p = self.store:issue(issue.id)
  local items = {}
  for _, col in ipairs(p.columns) do
    items[#items + 1] = {
      label = col.name,
      dot = theme.statusColor(col.id),
      checked = col.id == issue.status,
      onSelect = function()
        self.store:updateIssue(issue.id, { status = col.id })
      end,
    }
  end
  overlay.openMenu(x, y, items)
end

function App:priorityMenu(issue, x, y)
  local items = {}
  for i = 4, 0, -1 do
    items[#items + 1] = {
      label = i == 0 and "No priority" or Store.PRIORITIES[i + 1],
      priority = i,
      checked = issue.priority == i,
      hint = tostring(i),
      onSelect = function()
        self.store:updateIssue(issue.id, { priority = i })
      end,
    }
  end
  overlay.openMenu(x, y, items)
end

function App:columnMenu(col, x, y)
  local key = self.project.key
  overlay.openMenu(x, y, {
    {
      label = "Add issue",
      icon = "plus",
      onSelect = function()
        self:startQuickAdd(col.id)
      end,
    },
    {
      label = "Copy column as Markdown",
      icon = "copy",
      onSelect = function()
        local lines = { "## " .. col.name }
        for _, issue in ipairs(self.store:issuesIn(self.project, col.id, self.filter)) do
          lines[#lines + 1] = "- " .. issue.id .. " " .. issue.title
        end
        self:copy(table.concat(lines, "\n"), "Copied " .. col.name)
      end,
    },
    { separator = true },
    {
      label = "Rename column…",
      onSelect = function()
        self:renameColumn(col)
      end,
    },
    {
      label = "Move left",
      onSelect = function()
        self.store:shiftColumn(key, col.id, -1)
      end,
    },
    {
      label = "Move right",
      onSelect = function()
        self.store:shiftColumn(key, col.id, 1)
      end,
    },
    {
      label = "New column…",
      icon = "plus",
      onSelect = function()
        self:addColumnDialog(col)
      end,
    },
    { separator = true },
    {
      label = "Delete column",
      icon = "trash",
      danger = true,
      onSelect = function()
        local n = #self.store:issuesIn(self.project, col.id)
        overlay.openModal({
          title = "Delete “" .. col.name .. "”?",
          message = n > 0 and (n .. " issue(s) will move to the neighbouring column.") or "The column is empty.",
          confirm = "Delete",
          danger = true,
          onConfirm = function()
            local ok, err = self.store:deleteColumn(key, col.id)
            return not ok and err or nil
          end,
        })
      end,
    },
  }, { minW = 220 })
end

function App:renameColumn(col)
  local key = self.project.key
  overlay.openModal({
    title = "Rename column",
    fields = { { key = "name", label = "Name", value = col.name } },
    confirm = "Rename",
    onConfirm = function(v)
      local ok, err = self.store:renameColumn(key, col.id, v.name)
      return not ok and err or nil
    end,
  })
end

function App:addColumnDialog(after)
  local key = self.project.key
  overlay.openModal({
    title = "New column",
    fields = { { key = "name", label = "Name", placeholder = "e.g. Blocked" } },
    confirm = "Add column",
    onConfirm = function(v)
      local col, err = self.store:addColumn(key, v.name)
      if not col then
        return err
      end
      -- place it after the column the menu was opened on
      local p = self.project
      local _, ai = self.store:column(p, after.id)
      local _, ci = self.store:column(p, col.id)
      while ci and ai and ci > ai + 1 do
        self.store:shiftColumn(key, col.id, -1)
        ci = ci - 1
      end
    end,
  })
end

function App:newProjectDialog()
  overlay.openModal({
    title = "New project",
    message = "Issue IDs are prefixed with the key, like KEY-12.",
    fields = {
      {
        key = "name",
        label = "Name",
        placeholder = "e.g. Agent Tasks",
        onChange = function(text, m)
          local keyInput = m.inputs[2]
          if not keyInput.touchedByUser then
            keyInput:setText(util.trim(text) ~= "" and self.store:suggestKey(text) or "")
          end
        end,
      },
      { key = "key", label = "Key", placeholder = "AT" },
    },
    confirm = "Create project",
    onConfirm = function(v)
      local p, err = self.store:createProject({ name = v.name, key = v.key })
      if not p then
        return err
      end
      self:switchProject(p.key)
    end,
  })
  local m = overlay.modal
  m.inputs[2].onChange = function()
    m.inputs[2].touchedByUser = true
  end
end

function App:renameProjectDialog(p)
  overlay.openModal({
    title = "Rename project",
    fields = { { key = "name", label = "Name", value = p.name } },
    confirm = "Rename",
    onConfirm = function(v)
      local ok, err = self.store:updateProject(p.key, { name = v.name })
      return not ok and err or nil
    end,
  })
end

function App:projectMenu(p, x, y)
  overlay.openMenu(x, y, {
    {
      label = "Rename…",
      onSelect = function()
        self:renameProjectDialog(p)
      end,
    },
    {
      label = "Copy board as Markdown",
      icon = "copy",
      onSelect = function()
        self:copy(self.store:projectMarkdown(p), "Copied " .. p.name .. " as Markdown")
      end,
    },
    { separator = true },
    {
      label = "Delete project…",
      icon = "trash",
      danger = true,
      onSelect = function()
        overlay.openModal({
          title = "Delete “" .. p.name .. "”?",
          message = "This removes the project and its " .. #p.issues .. " issue(s). You can undo with Ctrl+Z.",
          confirm = "Delete project",
          danger = true,
          onConfirm = function()
            self.store:deleteProject(p.key)
            self:ensureProject()
            self.selected = nil
            detail.close(self)
          end,
        })
      end,
    },
  })
end

function App:projectSwitcher(x, y)
  local items = { { header = "Projects" } }
  for i, p in ipairs(self.store:projects()) do
    items[#items + 1] = {
      label = p.name,
      dot = theme.labelColor(p.key),
      checked = p == self.project,
      hint = i <= 9 and ("Ctrl+" .. i) or nil,
      onSelect = function()
        self:switchProject(p.key)
      end,
    }
  end
  items[#items + 1] = { separator = true }
  items[#items + 1] = {
    label = "New project…",
    icon = "plus",
    onSelect = function()
      self:newProjectDialog()
    end,
  }
  items[#items + 1] = {
    label = "Copy board as Markdown",
    icon = "copy",
    onSelect = function()
      self:copy(self.store:projectMarkdown(self.project, self.filter), "Copied board as Markdown")
    end,
  }
  overlay.openMenu(x, y, items, { minW = 240, keyboard = true })
end

function App:apiMenu(x, y)
  overlay.openMenu(x, y, {
    {
      label = "Copy API URL",
      icon = "link",
      onSelect = function()
        self:copy(self:apiBase(), "Copied API URL")
      end,
    },
    {
      label = "Copy agent instructions",
      icon = "agent",
      onSelect = function()
        self:copy(self:agentInstructions(), "Copied agent instructions")
      end,
    },
    {
      label = "Copy API reference",
      icon = "copy",
      onSelect = function()
        self:copy(require("src.api").HELP, "Copied API reference")
      end,
    },
  }, { minW = 240 })
end

function App:showShortcuts()
  overlay.openModal({
    title = "Keyboard shortcuts",
    message = table.concat({
      "N  new issue  ·  E  edit title  ·  Enter  open",
      "↑↓←→ / hjkl  select  ·  Shift+arrows  move card",
      "0–4  priority  ·  Del  delete  ·  Ctrl+D  duplicate",
      "Ctrl+C  copy Markdown  ·  Ctrl+Shift+C  copy ID",
      "Ctrl+Shift+P  copy agent prompt",
      "/  Ctrl+F  search  (@who  #label  p:high  is:todo)",
      "Ctrl+Z  undo  ·  Ctrl+Shift+Z  redo",
      "Ctrl+P  switch project  ·  Ctrl+1–9  jump to project",
      "Ctrl+B  sidebar  ·  Esc  close / clear",
      "",
      "Quick add understands  #label  @assignee  !high  (or !!!)",
    }, "\n"),
    confirm = "Got it",
    noCancel = true,
  })
end

-- Frame -------------------------------------------------------------------------------------

function App:update(dt)
  self.frame = self.frame + 1
  -- Re-resolve every frame: undo/redo swap in restored project tables.
  self:ensureProject()
  if self.quickAdd and not self.quickAdd.input:isFocused() and self.quickAdd.input.text == "" then
    self.quickAdd = nil
    ui.dirty = true
  end
  local busy = board.update(self, dt)
  busy = detail.update(self, dt) or busy
  busy = overlay.update(dt) or busy
  return busy
end

function App:draw()
  local W, H = love.graphics.getDimensions()
  local c = theme.c
  love.graphics.clear(c.bg)
  ui.beginFrame()

  local overlaySidebar = App.narrow()
  local sbW = (self.sidebarOpen and not overlaySidebar) and chrome.SIDEBAR_W or 0
  local bx, bw = sbW, W - sbW
  chrome.drawTopbar(self, bx, 0, bw)
  board.draw(self, bx, chrome.TOPBAR_H + 12, bw, H - chrome.TOPBAR_H - 12)
  if sbW > 0 then
    chrome.drawSidebar(self, 0, 0, sbW, H)
  end
  if self.detail then
    local full = bw < 820
    local pw = full and W or util.clamp(math.floor(W * 0.42), 440, 620)
    local py = full and 0 or chrome.TOPBAR_H
    detail.draw(self, W - pw, py, pw, H - py)
  end
  board.drawDragged(self)
  if self.drawerOpen and overlaySidebar then
    ui.color(c.overlay)
    love.graphics.rectangle("fill", 0, 0, W, H)
    ui.region("sidebar-backdrop", 0, 0, W, H, {
      modal = true,
      onPress = function()
        self.drawerOpen = false
      end,
    })
    chrome.drawSidebar(self, 0, 0, math.min(chrome.SIDEBAR_W + 20, W - 40), H)
  end
  overlay.draw()
  ui.endFrame()

  local title = "KanbanEasy — " .. self.project.name
  if title ~= self.windowTitle then
    self.windowTitle = title
    love.window.setTitle(title)
  end
end

-- Keyboard ------------------------------------------------------------------------------------

local ctrlDown, shiftDown = ui.primary, ui.shift

function App:keypressed(key)
  ui.dirty = true
  if overlay.keypressed(key) then
    return true
  end
  local ctrl, shift = ctrlDown(), shiftDown()

  -- A focused text field gets first go at the key.
  if ui.focus then
    if ui.focus:keypressed(key) then
      return true
    end
    if key == "tab" and self.detail then
      local inputs = detail.inputs(self.detail)
      local idx = util.indexOf(inputs, ui.focus)
      if idx then
        local nxt = inputs[(idx - 1 + (shift and -1 or 1)) % #inputs + 1]
        nxt:focus()
        nxt:selectAll()
        return true
      end
    end
    if not ctrl or key == "c" or key == "x" or key == "d" then
      return true -- these belong to the input
    end
  end

  local sel = self.selected and self.store:issue(self.selected)

  if ctrl then
    if key == "z" and not shift then
      overlay.toast(self.store:undo() and "Undone" or "Nothing to undo")
    elseif key == "y" or key == "z" then
      overlay.toast(self.store:redo() and "Redone" or "Nothing to redo")
    elseif key == "f" or key == "k" then
      self.search:focus()
      self.search:selectAll()
    elseif key == "n" then
      self:startQuickAdd()
    elseif key == "b" then
      self:toggleSidebar()
    elseif key == "p" and shift and sel then
      self:copy(self:agentPrompt(sel), "Copied agent prompt for " .. sel.id)
    elseif key == "p" then
      self:projectSwitcher((self.sidebarOpen and not App.narrow()) and chrome.SIDEBAR_W + 14 or 60, chrome.TOPBAR_H - 6)
    elseif key == "c" and sel then
      if shift then
        self:copy(sel.id, "Copied " .. sel.id)
      else
        self:copy(self.store:issueMarkdown(sel, false), "Copied " .. sel.id .. " as Markdown")
      end
    elseif key == "d" and sel then
      local copy = self.store:duplicateIssue(sel.id)
      if copy then
        self.selected = copy.id
      end
    elseif key == "s" then
      ui.blur()
      self.persist:save()
      overlay.toast("Saved")
    elseif key:match("^%d$") then
      local p = self.store:projects()[tonumber(key)]
      if p then
        self:switchProject(p.key)
      end
    else
      return false
    end
    return true
  end

  if key == "escape" then
    if self.detail then
      detail.close(self)
    elseif self.search.text ~= "" then
      self.search:setText("")
      self:applySearch()
    elseif self.selected then
      self.selected = nil
    elseif self.drawerOpen then
      self.drawerOpen = false
    end
  elseif key == "/" and shift or key == "?" then
    self:showShortcuts()
    self.swallowText = true
  elseif key == "/" then
    self.search:focus()
    self.search:selectAll()
    self.swallowText = true
  elseif key == "n" or key == "c" then
    self:startQuickAdd()
    self.swallowText = true
  elseif
    key == "up"
    or key == "down"
    or key == "left"
    or key == "right"
    or key == "j"
    or key == "k"
    or key == "h"
    or key == "l"
  then
    local map = {
      up = { 0, -1 },
      k = { 0, -1 },
      down = { 0, 1 },
      j = { 0, 1 },
      left = { -1, 0 },
      h = { -1, 0 },
      right = { 1, 0 },
      l = { 1, 0 },
    }
    local dx, dy = map[key][1], map[key][2]
    if (shift or ui.alt()) and sel then
      self:moveSelected(dx, dy)
    else
      self:navigate(dx, dy)
    end
  elseif (key == "return" or key == "kpenter" or key == "space") and sel then
    self:openIssueDetail(sel.id)
  elseif key == "e" and sel then
    self:openIssueDetail(sel.id)
    self.detail.title:focus()
    self.detail.title:selectAll()
    self.swallowText = true
  elseif (key == "delete" or key == "backspace") and sel then
    self:deleteIssue(sel.id)
  elseif key:match("^[0-4]$") and sel then
    self.store:updateIssue(sel.id, { priority = tonumber(key) })
  else
    return false
  end
  return true
end

function App:textinput(t)
  if self.swallowText then
    self.swallowText = false
    return
  end
  if ui.focus then
    ui.focus:textinput(t)
  end
end

function App:quit()
  ui.blur()
  self.persist:flush()
  if self.server then
    self.server:stop()
  end
end

return App
