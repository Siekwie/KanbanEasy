-- Sidebar (projects, API status, settings) and top bar (title, search, new issue).

local ui = require("src.ui.core")
local theme = require("src.ui.theme")

local chrome = {}

chrome.SIDEBAR_W = 232
chrome.TOPBAR_H = 54

local function logo(x, y)
  local c = theme.c
  local hs = { 14, 10, 6 }
  for i = 1, 3 do
    ui.color(c.accent, 1 - (i - 1) * 0.25)
    ui.rect("fill", x + (i - 1) * 6, y, 4, hs[i], 1.5)
  end
end

local function openCount(p)
  local n = 0
  for _, issue in ipairs(p.issues) do
    if issue.status ~= "done" then
      n = n + 1
    end
  end
  return n
end

function chrome.drawSidebar(app, x, y, w, h)
  local c = theme.c
  local f = theme.fonts
  ui.color(c.sidebar)
  love.graphics.rectangle("fill", x, y, w, h)
  ui.color(c.border)
  love.graphics.rectangle("fill", x + w - 1, y, 1, h)
  ui.region("sidebar", x, y, w, h, {})

  logo(x + 20, y + 20)
  ui.text("KanbanEasy", f.heading, x + 44, y + (chrome.TOPBAR_H - f.heading:getHeight()) / 2, c.text)
  ui.button("sidebar-hide", "", x + w - 38, y + 13, 28, 28, {
    style = "ghost",
    icon = "sidebar",
    onClick = function()
      app:toggleSidebar()
    end,
  })

  local cy = y + chrome.TOPBAR_H + 10
  ui.text("PROJECTS", f.small, x + 20, cy + 5, c.textFaint)
  ui.button("project-new", "", x + w - 36, cy, 24, 24, {
    style = "ghost",
    icon = "plus",
    onClick = function()
      app:newProjectDialog()
    end,
  })
  cy = cy + 32

  for _, p in ipairs(app.store:projects()) do
    local active = app.project == p
    local id = "proj-" .. p.key
    local hot = ui.region(id, x + 10, cy, w - 20, 34, {
      cursor = "hand",
      onClick = function()
        app:switchProject(p.key)
      end,
      onDouble = function()
        app:renameProjectDialog(p)
      end,
      onRightClick = function(mx, my)
        app:projectMenu(p, mx, my)
      end,
    })
    if active then
      ui.color(c.accentSoft)
      ui.rect("fill", x + 10, cy, w - 20, 34, 7)
    elseif hot then
      ui.color(c.text, 0.05)
      ui.rect("fill", x + 10, cy, w - 20, 34, 7)
    end
    -- key badge
    local kw = math.max(26, f.mono:getWidth(p.key) + 10)
    local col = theme.labelColor(p.key)
    love.graphics.setColor(col[1], col[2], col[3], 0.2)
    ui.rect("fill", x + 18, cy + 8, kw, 18, 4)
    ui.text(p.key, f.mono, x + 18 + (kw - f.mono:getWidth(p.key)) / 2, cy + 9, col)
    local count = tostring(openCount(p))
    local cw = f.small:getWidth(count)
    ui.textFit(
      p.name,
      active and f.bodyMedium or f.body,
      x + 26 + kw,
      cy + (34 - f.body:getHeight()) / 2,
      w - 70 - kw - cw,
      active and c.text or c.textDim
    )
    ui.text(count, f.small, x + w - 22 - cw, cy + (34 - f.small:getHeight()) / 2, c.textFaint)
    cy = cy + 36
  end

  -- footer ----------------------------------------------------------------------
  local fy = y + h - 166
  ui.color(c.border)
  love.graphics.rectangle("fill", x + 16, fy, w - 32, 1)
  fy = fy + 12

  local people = app.project.people
  local peopleHot = ui.region("people", x + 10, fy, w - 20, 30, {
    cursor = "hand",
    onClick = function()
      app:peopleDialog()
    end,
  })
  if peopleHot then
    ui.color(c.text, 0.05)
    ui.rect("fill", x + 10, fy, w - 20, 30, 7)
  end
  ui.avatar(people.me, x + 16, fy + 6, 9)
  ui.avatar(people.agent, x + 28, fy + 6, 9)
  ui.textFit(
    people.me .. "  ·  " .. people.agent,
    f.body,
    x + 54,
    fy + (30 - f.body:getHeight()) / 2,
    w - 74,
    c.textDim
  )
  fy = fy + 34

  local server = app.server
  local running = server and server:running()
  local apiLabel = running and ("API  127.0.0.1:" .. server.port)
    or ("API off: " .. tostring(server and server.error or "disabled"))
  local hot = ui.region("api-status", x + 10, fy, w - 20, 30, {
    cursor = "hand",
    onClick = function()
      if running then
        app:copy("http://127.0.0.1:" .. server.port, "Copied API URL")
      end
    end,
    onRightClick = function(mx, my)
      app:apiMenu(mx, my)
    end,
  })
  if hot then
    ui.color(c.text, 0.05)
    ui.rect("fill", x + 10, fy, w - 20, 30, 7)
  end
  ui.color(running and c.success or c.danger)
  love.graphics.circle("fill", x + 24, fy + 15, 3.5, 12)
  ui.textFit(apiLabel, f.body, x + 36, fy + (30 - f.body:getHeight()) / 2, w - 56, c.textDim)
  fy = fy + 34

  local dark = theme.name == "dark"
  local themeHot = ui.region("theme-toggle", x + 10, fy, w - 20, 30, {
    cursor = "hand",
    onClick = function()
      app:toggleTheme()
    end,
  })
  if themeHot then
    ui.color(c.text, 0.05)
    ui.rect("fill", x + 10, fy, w - 20, 30, 7)
  end
  ui.icon(dark and "sun" or "moon", x + 17, fy + 8, 14, c.textDim)
  ui.text(dark and "Light mode" or "Dark mode", f.body, x + 36, fy + (30 - f.body:getHeight()) / 2, c.textDim)
  fy = fy + 34

  local fileHot = ui.region("data-file", x + 10, fy, w - 20, 30, {
    cursor = "hand",
    onClick = function()
      app.persist:openFolder()
    end,
    onRightClick = function(mx, my)
      app:dataMenu(mx, my)
    end,
  })
  if fileHot then
    ui.color(c.text, 0.05)
    ui.rect("fill", x + 10, fy, w - 20, 30, 7)
  end
  ui.icon("folder", x + 17, fy + 8, 14, c.textDim)
  local saveErr = app.persist.lastError
  ui.textFit(
    saveErr and ("Save failed: " .. saveErr) or app.persist.displayPath(app.persist.path),
    f.body,
    x + 36,
    fy + (30 - f.body:getHeight()) / 2,
    w - 56,
    saveErr and c.danger or c.textDim
  )
end

function chrome.drawTopbar(app, x, y, w)
  local c = theme.c
  local f = theme.fonts
  local h = chrome.TOPBAR_H
  ui.color(c.topbar)
  love.graphics.rectangle("fill", x, y, w, h)
  ui.color(c.border)
  love.graphics.rectangle("fill", x, y + h - 1, w, 1)
  ui.region("topbar", x, y, w, h, {
    onPress = function()
      ui.blur()
    end,
  })

  local lx = x + 14
  if not app.sidebarOpen or app.narrow() then
    ui.button("sidebar-show", "", lx, y + 13, 28, 28, {
      style = "ghost",
      icon = "sidebar",
      onClick = function()
        app:toggleSidebar()
      end,
    })
    lx = lx + 36
  end

  local narrow = w < 620
  -- right side: new issue, search
  local rx = x + w - 14
  local newW = narrow and 32 or (f.bodyMedium:getWidth("New issue") + 42)
  rx = rx - newW
  ui.button("new-issue", narrow and "" or "New issue", rx, y + 11, newW, 32, {
    style = "primary",
    icon = "plus",
    onClick = function()
      app:startQuickAdd()
    end,
  })
  local searchW = math.max(120, math.min(280, w * 0.3))
  rx = rx - 10 - searchW
  local search = app.search
  local sx, sy = rx, y + 11
  search:draw(sx, sy, searchW, 32, { bg = true })
  if search.text == "" and not search:isFocused() then
    local hint = "/"
    ui.color(c.border)
    ui.rect("line", sx + searchW - 24.5, sy + 8.5, 16, 16, 4)
    ui.text(hint, f.small, sx + searchW - 16 - f.small:getWidth(hint) / 2 - 0.5, sy + 9, c.textFaint)
  elseif search.text ~= "" then
    ui.button("search-clear", "", sx + searchW - 28, sy + 4, 24, 24, {
      style = "ghost",
      icon = "close",
      onClick = function()
        search:setText("")
        app:applySearch()
      end,
    })
  end
  ui.icon("search", sx + 10, sy + 9, 14, c.textFaint)

  -- title (project name) - click to switch projects
  local p = app.project
  local maxTitleW = rx - lx - 20
  local titleHot = ui.region("project-title", lx, y + 10, math.min(maxTitleW, f.heading:getWidth(p.name) + 40), 34, {
    cursor = "hand",
    onClick = function()
      app:projectSwitcher(lx, y + h - 6)
    end,
    onDouble = function()
      app:renameProjectDialog(p)
    end,
  })
  if titleHot then
    ui.color(c.text, 0.05)
    ui.rect("fill", lx, y + 10, math.min(maxTitleW, f.heading:getWidth(p.name) + 40), 34, 7)
  end
  local tw = ui.textFit(p.name, f.heading, lx + 8, y + (h - f.heading:getHeight()) / 2, maxTitleW - 32, c.text)
  ui.icon("chevronDown", lx + 12 + tw, y + (h - 14) / 2 + 1, 14, c.textFaint)
end

return chrome
