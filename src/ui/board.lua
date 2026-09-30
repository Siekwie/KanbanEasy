-- The kanban board: columns of cards with drag & drop, smooth scrolling and
-- a stacked "list" layout used when the window is narrow (docked to a screen edge).

local ui = require("src.ui.core")
local theme = require("src.ui.theme")
local util = require("src.util")

local board = {}

local PAD = 14
local GAP = 12
local HEADER_H = 40
local CARD_GAP = 8
local CARD_PAD = 11
local MIN_COL_W, MAX_COL_W = 190, 340
local LIST_MODE_W = 540

-- Measuring ------------------------------------------------------------------------

local function titleLineH()
  return math.floor(theme.fonts.body:getHeight() * 1.32 + 0.5)
end

local function cardHeight(issue, w)
  local _, lines = theme.fonts.body:getWrap(issue.title, w - CARD_PAD * 2)
  local h = CARD_PAD + 16 + 6 + math.max(1, #lines) * titleLineH() + CARD_PAD - 2
  if #issue.labels > 0 then
    h = h + 26
  end
  return h
end

local function commentCount(issue)
  local n = 0
  for _, a in ipairs(issue.activity) do
    if a.kind == "comment" then
      n = n + 1
    end
  end
  return n
end

-- Layout -----------------------------------------------------------------------------

--- Compute the board geometry. Card y values are in column-content space (before scroll).
function board.layout(app, x, y, w, h)
  local store, p = app.store, app.project
  local L = { x = x, y = y, w = w, h = h, cols = {} }
  L.list = w < LIST_MODE_W
  local n = #p.columns
  local drag = app.drag
  if L.list then
    L.colW = w - PAD * 2
  else
    L.colW = util.clamp(math.floor((w - PAD * 2 - GAP * (n - 1)) / n), MIN_COL_W, MAX_COL_W)
  end
  local listY = 0
  for i, col in ipairs(p.columns) do
    local issues = store:issuesIn(p, col.id, app.filter)
    local C = { col = col, issues = issues, cards = {} }
    if L.list then
      C.x = PAD
      C.headerY = listY
    else
      C.x = PAD + (i - 1) * (L.colW + GAP)
      C.headerY = 0
    end
    local cy = L.list and (listY + HEADER_H) or 0
    if app.quickAdd and app.quickAdd.col == col.id then
      C.quickY = cy
      cy = cy + app.quickAdd.input:contentHeight(L.colW - 12) + 8 + CARD_GAP
    end
    local index = 0
    for _, issue in ipairs(issues) do
      if not (drag and drag.id == issue.id) then
        index = index + 1
        if drag and drag.target and drag.target.col == col.id and drag.target.index == index then
          C.placeholderY = cy
          cy = cy + drag.h + CARD_GAP
        end
        local ch = cardHeight(issue, L.colW - 12)
        C.cards[#C.cards + 1] = { issue = issue, y = cy, h = ch }
        cy = cy + ch + CARD_GAP
      end
    end
    if drag and drag.target and drag.target.col == col.id and drag.target.index > index then
      C.placeholderY = cy
      cy = cy + drag.h + CARD_GAP
    end
    C.addY = cy
    -- in the stacked list the "Add issue" row only takes space when the section is empty
    cy = cy + ((L.list and #C.cards > 0) and 0 or 32)
    C.contentH = cy - (L.list and listY + HEADER_H or 0)
    if L.list then
      C.collapsed = app.collapsed[col.id]
      if C.collapsed then
        cy = listY + HEADER_H
      end
      listY = cy + 6
    end
    L.cols[i] = C
  end
  L.contentW = PAD * 2 + n * L.colW + (n - 1) * GAP
  L.listContentH = listY + PAD
  app.layout = L
  return L
end

-- Scrolling -----------------------------------------------------------------------------

local function scrollState(app, key)
  local s = app.scroll[key]
  if not s then
    s = { pos = 0, target = 0 }
    app.scroll[key] = s
  end
  return s
end
board.scrollState = scrollState

local function clampScroll(s, maxv)
  maxv = math.max(0, maxv)
  s.target = util.clamp(s.target, 0, maxv)
  s.pos = util.clamp(s.pos, 0, maxv)
  s.max = maxv
end

--- Ensure a card is visible (used by keyboard navigation).
function board.reveal(app, id)
  local L = app.layout
  if not L then
    return
  end
  for _, C in ipairs(L.cols) do
    for _, card in ipairs(C.cards) do
      if card.issue.id == id then
        local s = L.list and scrollState(app, "list") or scrollState(app, "col:" .. C.col.id)
        local viewH = L.list and (L.h - PAD) or (L.h - HEADER_H - PAD)
        local top = card.y - 8
        local bottom = card.y + card.h + 8
        if top < s.target then
          s.target = top
        elseif bottom > s.target + viewH then
          s.target = bottom - viewH
        end
        if not L.list then
          local hs = scrollState(app, "board-x")
          local cx = C.x
          if cx - PAD < hs.target then
            hs.target = cx - PAD
          elseif cx + L.colW + PAD > hs.target + L.w then
            hs.target = cx + L.colW + PAD - L.w
          end
        end
        return
      end
    end
  end
end

-- Drag and drop -------------------------------------------------------------------------

--- Work out which column/index the dragged card would land at.
local function dropTarget(app, mx, my)
  local L = app.layout
  if not L then
    return nil
  end
  local best, bestD
  for _, C in ipairs(L.cols) do
    local d
    if L.list then
      local top = C.screenTop
      local bottom = C.screenBottom
      d = my < top and top - my or (my > bottom and my - bottom or 0)
    else
      local cx = C.screenX
      d = mx < cx and cx - mx or (mx > cx + L.colW and mx - cx - L.colW or 0)
    end
    if not bestD or d < bestD then
      best, bestD = C, d
    end
  end
  if not best then
    return nil
  end
  local index = #best.cards + 1
  for i, card in ipairs(best.cards) do
    if card.screenY and my < card.screenY + card.h / 2 then
      index = i
      break
    end
  end
  if best.collapsed then
    index = #best.issues + 1
  end
  return { col = best.col.id, index = index }
end

function board.startDrag(app, issue, card, grabX, grabY, mx, my)
  app.drag = {
    id = issue.id,
    issue = issue,
    w = app.layout.colW - 12,
    h = card.h,
    offX = grabX - card.screenX,
    offY = grabY - card.screenY,
    x = mx,
    y = my,
  }
  app.selected = issue.id
  app.drag.target = dropTarget(app, mx, my)
  ui.startCapture({
    cursor = "sizeall",
    onMove = function(x, y)
      app.drag.x, app.drag.y = x, y
      app.drag.target = dropTarget(app, x, y) or app.drag.target
    end,
    onRelease = function()
      local d = app.drag
      app.drag = nil
      if d and d.target then
        -- place the animated card where it was dropped so it settles smoothly
        local a = app.anim[d.id]
        if a and app.layout then
          local L = app.layout
          for _, C in ipairs(L.cols) do
            if C.col.id == d.target.col then
              a.x = d.x - d.offX - (C.screenX - C.x)
              a.y = d.y - d.offY - (C.screenOffsetY or 0)
            end
          end
        end
        app.store:moveIssue(d.id, d.target.col, d.target.index)
      end
    end,
  })
end

function board.update(app, dt)
  local busy = false
  for _, s in pairs(app.scroll) do
    if math.abs(s.pos - s.target) > 0.3 then
      s.pos = util.damp(s.pos, s.target, 18, dt)
      busy = true
    else
      s.pos = s.target
    end
  end
  for _, a in pairs(app.anim) do
    if a.tx then
      local dx, dy = a.tx - a.x, a.ty - a.y
      if math.abs(dx) > 0.3 or math.abs(dy) > 0.3 then
        a.x = util.damp(a.x, a.tx, 16, dt)
        a.y = util.damp(a.y, a.ty, 16, dt)
        busy = true
      else
        a.x, a.y = a.tx, a.ty
      end
    end
  end
  -- auto-scroll while dragging near edges
  local d, L = app.drag, app.layout
  if d and L then
    busy = true
    local edge, speed = 48, 700 * dt
    if L.list then
      local s = scrollState(app, "list")
      if d.y < L.y + edge then
        s.target = s.target - speed
      elseif d.y > L.y + L.h - edge then
        s.target = s.target + speed
      end
    else
      local hs = scrollState(app, "board-x")
      if d.x < L.x + edge then
        hs.target = hs.target - speed
      elseif d.x > L.x + L.w - edge then
        hs.target = hs.target + speed
      end
      if d.target then
        local s = scrollState(app, "col:" .. d.target.col)
        if d.y < L.y + HEADER_H + edge * 0.6 then
          s.target = s.target - speed
        elseif d.y > L.y + L.h - edge then
          s.target = s.target + speed
        end
      end
    end
    d.target = dropTarget(app, d.x, d.y) or d.target
  end
  for id, t in pairs(app.flash) do
    if ui.time - t > 1.6 then
      app.flash[id] = nil
    else
      busy = true
    end
  end
  return busy
end

-- Drawing ----------------------------------------------------------------------------------

local function drawCard(app, issue, x, y, w, h, opts)
  local c = theme.c
  local f = theme.fonts
  local selected = app.selected == issue.id or app.openIssue == issue.id
  local hot = opts.hot
  if opts.lifted then
    ui.shadow(x, y, w, h, 8, 2.2)
  elseif hot or selected then
    ui.shadow(x, y, w, h, 8, 0.6)
  end
  ui.color((hot or opts.lifted) and c.cardHover or c.card)
  ui.rect("fill", x, y, w, h, 8)
  local flash = app.flash[issue.id]
  if flash then
    local a = 1 - (ui.time - flash) / 1.6
    ui.color(c.accent, 0.35 * a)
    ui.rect("fill", x, y, w, h, 8)
  end
  love.graphics.setLineWidth(selected and 1.5 or 1)
  if selected then
    ui.color(c.accent, 0.9)
  else
    ui.color(hot and c.borderStrong or c.border)
  end
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 8)
  love.graphics.setLineWidth(1)

  -- top row: priority, id, comments, avatar
  local rowY = y + CARD_PAD
  local tx = x + CARD_PAD
  if issue.priority > 0 then
    ui.priorityIcon(issue.priority, tx, rowY + 2, 12)
    tx = tx + 18
  end
  ui.text(issue.id, f.mono, tx, rowY, c.textFaint)
  local rx = x + w - CARD_PAD
  if issue.assignee ~= "" then
    rx = rx - 18
    ui.avatar(issue.assignee, rx, rowY - 1, 9)
    rx = rx - 6
  end
  local comments = commentCount(issue)
  if comments > 0 then
    local label = tostring(comments)
    local lw = f.small:getWidth(label)
    ui.text(label, f.small, rx - lw, rowY + 1, c.textFaint)
    ui.icon("comment", rx - lw - 16, rowY + 1, 13, c.textFaint)
  end

  -- title
  local done = issue.status == "done"
  love.graphics.setFont(f.body)
  ui.color(done and c.textDim or c.text)
  local _, lines = f.body:getWrap(issue.title, w - CARD_PAD * 2)
  local ty = rowY + 16 + 6
  for i, line in ipairs(lines) do
    love.graphics.print(line, math.floor(x + CARD_PAD), math.floor(ty + (i - 1) * titleLineH()))
  end

  -- labels
  if #issue.labels > 0 then
    local lx = x + CARD_PAD
    local ly = y + h - CARD_PAD - 18
    local maxX = x + w - CARD_PAD
    for i, label in ipairs(issue.labels) do
      local cw = ui.chipWidth(label)
      local remaining = #issue.labels - i
      if lx + cw > maxX - (remaining > 0 and 30 or 0) and i > 1 then
        ui.text("+" .. (remaining + 1), f.small, lx + 2, ly + 3, c.textFaint)
        break
      end
      lx = lx + ui.chip(label, lx, ly, theme.labelColor(label))
    end
  end
end

local function drawColumnHeader(app, C, x, y, w)
  local c = theme.c
  local f = theme.fonts
  local col = C.col
  local hot = ui.region("colhead-" .. col.id, x, y, w, HEADER_H, {
    onRightClick = function(mx, my)
      app:columnMenu(col, mx, my)
    end,
    onDouble = function()
      app:renameColumn(col)
    end,
    onClick = function()
      if app.layout and app.layout.list then
        app.collapsed[col.id] = not app.collapsed[col.id] or nil
      end
    end,
  })
  local cx = x + 6
  if app.layout.list then
    ui.icon(C.collapsed and "chevronRight" or "chevronDown", cx - 2, y + 13, 14, c.textFaint)
    cx = cx + 16
  end
  ui.color(theme.statusColor(col.id))
  love.graphics.setLineWidth(2)
  if col.id == "done" then
    love.graphics.circle("fill", cx + 5, y + HEADER_H / 2, 5.5, 20)
  else
    love.graphics.circle("line", cx + 5, y + HEADER_H / 2, 5, 20)
    if col.id == "in_progress" then
      love.graphics.arc("fill", cx + 5, y + HEADER_H / 2, 3.2, -math.pi / 2, math.pi / 2, 12)
    elseif col.id == "review" then
      love.graphics.arc("fill", cx + 5, y + HEADER_H / 2, 3.2, -math.pi / 2, math.pi, 12)
    end
  end
  love.graphics.setLineWidth(1)
  local name = col.name
  local nameX = cx + 18
  local maxNameW = w - (nameX - x) - 80
  local nw = ui.textFit(name, f.heading, nameX, y + (HEADER_H - f.heading:getHeight()) / 2, maxNameW, c.text)
  ui.text(tostring(#C.issues), f.body, nameX + nw + 8, y + (HEADER_H - f.body:getHeight()) / 2, c.textFaint)

  local showButtons = hot or ui.isHot("coladd-" .. col.id) or ui.isHot("colmenu-" .. col.id)
  if showButtons or app.layout.list then
    local bx = x + w - 26
    ui.button("coladd-" .. col.id, "", bx, y + 8, 24, 24, {
      style = "ghost",
      icon = "plus",
      onClick = function()
        app:startQuickAdd(col.id)
      end,
    })
    ui.button("colmenu-" .. col.id, "", bx - 26, y + 8, 24, 24, {
      style = "ghost",
      icon = "dots",
      onClick = function()
        app:columnMenu(col, ui.mx, ui.my + 8)
      end,
    })
  end
end

local function drawAddRow(app, C, x, y, w)
  local c = theme.c
  local id = "addrow-" .. C.col.id
  local hot = ui.region(id, x, y, w, 30, {
    cursor = "hand",
    onClick = function()
      app:startQuickAdd(C.col.id)
    end,
  })
  if hot or #C.issues == 0 then
    local col = hot and c.textDim or c.textFaint
    if hot then
      ui.color(c.text, 0.04)
      ui.rect("fill", x, y, w, 30, 6)
    end
    ui.icon("plus", x + 8, y + 8, 14, col)
    ui.text("Add issue", theme.fonts.body, x + 28, y + (30 - theme.fonts.body:getHeight()) / 2, col)
  end
end

--- Draw one card (registering its interaction region) at content position.
local function placeCard(app, C, card, x, sy, w, offsetX)
  local issue = card.issue
  local a = app.anim[issue.id]
  local tx, ty = C.x, card.y
  if not a or a.project ~= app.project.key then
    a = { x = tx, y = ty, project = app.project.key }
    app.anim[issue.id] = a
  end
  a.tx, a.ty = tx, ty
  a.seen = app.frame
  local dx = x + (a.x - C.x) + 6 + (offsetX or 0)
  local dy = sy + a.y
  card.screenX, card.screenY = love.graphics.transformPoint(x + 6, sy + card.y)
  local hot = ui.region("card-" .. issue.id, dx, dy, w - 12, card.h, {
    cursor = "hand",
    onPress = function()
      app.selected = issue.id
      ui.blur()
    end,
    onClick = function()
      app:openIssueDetail(issue.id)
    end,
    onRightClick = function(mx, my)
      app.selected = issue.id
      app:cardMenu(issue, mx, my)
    end,
    onDragStart = function(px, py, mx, my)
      board.startDrag(app, issue, card, px, py, mx, my)
    end,
  })
  drawCard(app, issue, dx, dy, w - 12, card.h, { hot = hot })
end

local function drawQuickAdd(app, x, y, w)
  local c = theme.c
  local input = app.quickAdd.input
  local h = input:contentHeight(w - 12) + 8
  ui.shadow(x + 6, y, w - 12, h, 8, 0.6)
  ui.color(c.card)
  ui.rect("fill", x + 6, y, w - 12, h, 8)
  ui.color(c.accent, 0.8)
  ui.rect("line", x + 6.5, y + 0.5, w - 13, h - 1, 8)
  input:draw(x + 6, y + 4, w - 12, h - 8, { bg = false, border = false, focusRing = false, hoverBg = false })
end

local function drawPlaceholder(x, y, w, h)
  local c = theme.c
  ui.color(c.accent, 0.08)
  ui.rect("fill", x + 6, y, w - 12, h, 8)
  ui.color(c.accent, 0.5)
  love.graphics.setLineWidth(1.2)
  ui.rect("line", x + 6.5, y + 0.5, w - 13, h - 1, 8)
  love.graphics.setLineWidth(1)
end

local function drawColumns(app, L)
  local c = theme.c
  local hs = scrollState(app, "board-x")
  clampScroll(hs, L.contentW - L.w)
  local ox = L.x - math.floor(hs.pos + 0.5)
  ui.pushClip(L.x, L.y, L.w, L.h)
  -- background region: horizontal scrolling with shift+wheel or on empty space
  ui.region("board-bg", L.x, L.y, L.w, L.h, {
    onWheel = function(dx, dy)
      hs.target = hs.target - (dx ~= 0 and dx or dy) * 60
      return true
    end,
    onPress = function()
      app.selected = nil
      ui.blur()
    end,
  })
  for _, C in ipairs(L.cols) do
    local x = ox + C.x
    C.screenX = x
    if x + L.colW >= L.x - 20 and x <= L.x + L.w + 20 then
      local y = L.y
      local colH = L.h - PAD
      ui.color(c.column)
      ui.rect("fill", x, y, L.colW, colH, 10)
      drawColumnHeader(app, C, x, y, L.colW)
      local s = scrollState(app, "col:" .. C.col.id)
      local viewH = colH - HEADER_H
      clampScroll(s, C.contentH - viewH + 4)
      local sy = y + HEADER_H - math.floor(s.pos + 0.5)
      C.screenOffsetY = y + HEADER_H - s.pos
      ui.region("col-" .. C.col.id, x, y + HEADER_H, L.colW, viewH, {
        onWheel = function(dx, dy)
          if love.keyboard.isDown("lshift", "rshift") or (dx ~= 0 and math.abs(dx) > math.abs(dy)) then
            hs.target = hs.target - (dx ~= 0 and dx or dy) * 60
          else
            s.target = s.target - dy * 60
          end
          return true
        end,
        onPress = function()
          app.selected = nil
          ui.blur()
        end,
        onDouble = function()
          app:startQuickAdd(C.col.id)
        end,
        onRightClick = function(mx, my)
          app:columnMenu(C.col, mx, my)
        end,
      })
      ui.pushClip(x, y + HEADER_H - 2, L.colW, viewH + 2)
      if C.quickY then
        drawQuickAdd(app, x, sy + C.quickY, L.colW)
      end
      for _, card in ipairs(C.cards) do
        local top = sy + card.y
        if top + card.h > y and top < y + colH + 200 then
          placeCard(app, C, card, x, sy, L.colW, 0)
        else
          card.screenX, card.screenY = x + 6, top
          local a = app.anim[card.issue.id]
          if a then
            a.x, a.y, a.tx, a.ty = C.x, card.y, C.x, card.y
          end
        end
      end
      if C.placeholderY then
        drawPlaceholder(x, sy + C.placeholderY, L.colW, app.drag.h)
      end
      if not app.drag then
        drawAddRow(app, C, x + 6, sy + C.addY, L.colW - 12)
      end
      ui.popClip()
      -- scrollbar hint
      if s.max and s.max > 0 then
        local barH = math.max(24, viewH * viewH / (viewH + s.max))
        local barY = y + HEADER_H + (viewH - barH) * (s.pos / s.max)
        ui.color(c.text, 0.12)
        ui.rect("fill", x + L.colW - 5, barY, 3, barH, 1.5)
      end
    end
  end
  ui.popClip()
  if hs.max and hs.max > 0 then
    local barW = math.max(40, L.w * L.w / (L.w + hs.max))
    local barX = L.x + (L.w - barW) * (hs.pos / hs.max)
    ui.color(c.text, 0.1)
    ui.rect("fill", barX, L.y + L.h - 6, barW, 3, 1.5)
  end
end

local function drawList(app, L)
  local c = theme.c
  local s = scrollState(app, "list")
  clampScroll(s, L.listContentH - L.h)
  local sy = L.y - math.floor(s.pos + 0.5)
  ui.pushClip(L.x, L.y, L.w, L.h)
  ui.region("list-bg", L.x, L.y, L.w, L.h, {
    onWheel = function(_, dy)
      s.target = s.target - dy * 60
      return true
    end,
    onPress = function()
      app.selected = nil
      ui.blur()
    end,
  })
  for _, C in ipairs(L.cols) do
    local x = L.x + C.x
    C.screenX = x
    C.screenOffsetY = sy
    C.screenTop = sy + C.headerY
    C.screenBottom = sy + C.headerY + HEADER_H + (C.collapsed and 0 or C.contentH)
    drawColumnHeader(app, C, x, sy + C.headerY, L.colW)
    if not C.collapsed then
      if C.quickY then
        drawQuickAdd(app, x, sy + C.quickY, L.colW)
      end
      for _, card in ipairs(C.cards) do
        local top = sy + card.y
        if top + card.h > L.y - 200 and top < L.y + L.h + 200 then
          placeCard(app, C, card, x, sy, L.colW, 0)
        else
          card.screenX, card.screenY = x + 6, top
        end
      end
      if C.placeholderY then
        drawPlaceholder(x, sy + C.placeholderY, L.colW, app.drag.h)
      end
      if not app.drag and #C.cards == 0 then
        drawAddRow(app, C, x + 6, sy + C.addY, L.colW - 12)
      end
    end
    ui.color(c.border)
    love.graphics.rectangle("fill", x, sy + C.headerY + HEADER_H - 1, L.colW, 1)
  end
  ui.popClip()
end

function board.draw(app, x, y, w, h)
  local L = board.layout(app, x, y, w, h)
  if L.list then
    drawList(app, L)
  else
    drawColumns(app, L)
  end
  -- forget animation state for cards no longer on screen
  for id, a in pairs(app.anim) do
    if a.seen ~= app.frame and not (app.drag and app.drag.id == id) then
      app.anim[id] = nil
    end
  end
end

--- The dragged card floats above everything else.
function board.drawDragged(app)
  local d = app.drag
  if not d then
    return
  end
  local x, y = d.x - d.offX, d.y - d.offY
  love.graphics.push()
  love.graphics.translate(x + d.w / 2, y + d.h / 2)
  love.graphics.rotate(0.025)
  drawCard(app, d.issue, -d.w / 2, -d.h / 2, d.w, d.h, { lifted = true })
  love.graphics.pop()
end

return board
