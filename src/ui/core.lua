-- Immediate-mode plumbing: every frame widgets register hit regions while drawing;
-- input events are routed to the regions registered during the previous frame.

local theme = require("src.ui.theme")

local ui = {}

ui.regions = {}
ui.prev = {}
ui.hot = nil -- id of the region under the mouse (from last frame)
ui.focus = nil -- focused text input
ui.capture = nil -- active drag/capture handlers
ui.pressed = nil -- region pressed but not yet released/dragged
ui.mx, ui.my = 0, 0
ui.time = 0
ui.dirty = true

local DRAG_THRESHOLD = 4
local cursors = {}

local function getCursor(name)
  if not cursors[name] and love.mouse.isCursorSupported() then
    cursors[name] = love.mouse.getSystemCursor(name)
  end
  return cursors[name]
end

function ui.beginFrame()
  ui.prev = ui.regions
  ui.regions = {}
end

function ui.endFrame()
  local hot = ui.hitTest(ui.mx, ui.my)
  local newHot = hot and hot.id or nil
  if newHot ~= ui.hot then
    ui.hot = newHot
    ui.dirty = true
  end
  local cursor = "arrow"
  if ui.capture and ui.capture.cursor then
    cursor = ui.capture.cursor
  elseif hot and hot.cursor then
    cursor = hot.cursor
  end
  if cursor ~= ui.cursorName then
    ui.cursorName = cursor
    local c = getCursor(cursor)
    if c then
      love.mouse.setCursor(c)
    end
  end
end

--- Register an interactive rectangle in local (transformed) coordinates.
function ui.region(id, x, y, w, h, opts)
  local x1, y1 = love.graphics.transformPoint(x, y)
  local x2, y2 = love.graphics.transformPoint(x + w, y + h)
  local r = opts or {}
  r.id = id
  r.x, r.y, r.w, r.h = x1, y1, x2 - x1, y2 - y1
  local sx, sy, sw, sh = love.graphics.getScissor()
  if sx then
    r.clip = { sx, sy, sw, sh }
  end
  ui.regions[#ui.regions + 1] = r
  return ui.hot == id, r
end

--- Is (x, y) inside region r (respecting its clip)?
local function inside(r, x, y)
  if x < r.x or y < r.y or x >= r.x + r.w or y >= r.y + r.h then
    return false
  end
  if r.clip then
    local c = r.clip
    if x < c[1] or y < c[2] or x >= c[1] + c[3] or y >= c[2] + c[4] then
      return false
    end
  end
  return true
end

function ui.hitTest(x, y, field)
  local list = ui.regions
  if #list == 0 then
    list = ui.prev
  end
  for i = #list, 1, -1 do
    local r = list[i]
    if inside(r, x, y) and (not field or r[field]) then
      return r
    end
    if r.modal then
      return nil
    end
  end
  return nil
end

function ui.isHot(id)
  return ui.hot == id
end

-- Scissor helpers (nesting intersects) ---------------------------------------

local clipStack = {}

function ui.pushClip(x, y, w, h)
  clipStack[#clipStack + 1] = { love.graphics.getScissor() }
  local x1, y1 = love.graphics.transformPoint(x, y)
  local x2, y2 = love.graphics.transformPoint(x + w, y + h)
  love.graphics.intersectScissor(x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1))
end

function ui.popClip()
  local s = table.remove(clipStack)
  if s and s[1] then
    love.graphics.setScissor(s[1], s[2], s[3], s[4])
  else
    love.graphics.setScissor()
  end
end

-- Input routing ----------------------------------------------------------------

function ui.mousemoved(x, y)
  ui.mx, ui.my = x, y
  ui.dirty = true
  if ui.capture then
    if ui.capture.onMove then
      ui.capture.onMove(x, y)
    end
    return true
  end
  local p = ui.pressed
  if p and (math.abs(x - p.x) > DRAG_THRESHOLD or math.abs(y - p.y) > DRAG_THRESHOLD) then
    ui.pressed = nil
    if p.region.onDragStart then
      p.region.onDragStart(p.x, p.y, x, y)
    end
  end
  return false
end

function ui.mousepressed(x, y, button, presses)
  ui.mx, ui.my = x, y
  ui.dirty = true
  local r = ui.hitTest(x, y)
  if not r then
    return false
  end
  if button == 1 then
    if r.onPress then
      r.onPress(x, y, presses)
    end
    if not ui.capture then
      ui.pressed = { region = r, x = x, y = y, presses = presses }
    end
  elseif button == 2 and r.onRightClick then
    r.onRightClick(x, y)
  elseif button == 2 then
    -- let right clicks fall through to an enclosing region that handles them
    local rr = ui.hitTest(x, y, "onRightClick")
    if rr then
      rr.onRightClick(x, y)
    end
  end
  return true
end

function ui.mousereleased(x, y, button)
  ui.mx, ui.my = x, y
  ui.dirty = true
  if ui.capture then
    local c = ui.capture
    ui.capture = nil
    if c.onRelease then
      c.onRelease(x, y, button)
    end
    ui.pressed = nil
    return true
  end
  local p = ui.pressed
  ui.pressed = nil
  if p and button == 1 then
    local r = ui.hitTest(x, y)
    if r and r.id == p.region.id then
      if p.presses >= 2 and r.onDouble then
        r.onDouble(x, y)
      elseif r.onClick then
        r.onClick(x, y)
      end
    end
    return true
  end
  return false
end

function ui.wheelmoved(dx, dy)
  ui.dirty = true
  local list = ui.regions
  for i = #list, 1, -1 do
    local r = list[i]
    if inside(r, ui.mx, ui.my) then
      if r.onWheel and r.onWheel(dx, dy) ~= false then
        return true
      end
      if r.modal then
        return true
      end
    end
  end
  return false
end

--- Capture the mouse until release (used for dragging).
function ui.startCapture(handlers)
  ui.capture = handlers
  ui.pressed = nil
end

-- Focus --------------------------------------------------------------------------

function ui.setFocus(input)
  if ui.focus == input then
    return
  end
  local old = ui.focus
  ui.focus = input
  if old and old.onBlur then
    old:onBlur()
  end
  if input and input.onFocus then
    input:onFocus()
  end
  ui.dirty = true
end

function ui.blur()
  ui.setFocus(nil)
end

-- Drawing helpers ------------------------------------------------------------------

function ui.color(c, alpha)
  if alpha then
    love.graphics.setColor(c[1], c[2], c[3], (c[4] or 1) * alpha)
  else
    love.graphics.setColor(c)
  end
end

function ui.rect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x, y, w, h, r or 0, r or 0, 8)
end

--- Soft drop shadow made of stacked translucent rounded rects.
function ui.shadow(x, y, w, h, r, strength)
  local c = theme.c.shadow
  strength = strength or 1
  for i = 1, 6 do
    local s = i * 1.6
    love.graphics.setColor(c[1], c[2], c[3], c[4] * 0.09 * strength)
    love.graphics.rectangle("fill", x - s * 0.6, y - s * 0.3 + s * 0.5, w + s * 1.2, h + s * 1.2, r + s, r + s, 8)
  end
end

function ui.text(s, font, x, y, color)
  love.graphics.setFont(font)
  ui.color(color or theme.c.text)
  love.graphics.print(s, math.floor(x + 0.5), math.floor(y + 0.5))
end

--- Print text truncated with an ellipsis to fit maxW. Returns drawn width.
function ui.textFit(s, font, x, y, maxW, color)
  local fitted = ui.ellipsize(s, font, maxW)
  ui.text(fitted, font, x, y, color)
  return font:getWidth(fitted)
end

function ui.ellipsize(s, font, maxW)
  if font:getWidth(s) <= maxW then
    return s
  end
  local util = require("src.util")
  local ell = "…"
  local i = #s + 1
  while i > 1 do
    i = util.prevChar(s, i)
    local candidate = s:sub(1, i - 1) .. ell
    if font:getWidth(candidate) <= maxW then
      return candidate
    end
  end
  return ell
end

-- Icons (drawn with primitives so they scale crisply) ----------------------------

local icons = {}

function icons.plus(x, y, s)
  local h = s / 2
  love.graphics.line(x + h, y + 2, x + h, y + s - 2)
  love.graphics.line(x + 2, y + h, x + s - 2, y + h)
end

function icons.close(x, y, s)
  love.graphics.line(x + 3, y + 3, x + s - 3, y + s - 3)
  love.graphics.line(x + s - 3, y + 3, x + 3, y + s - 3)
end

function icons.search(x, y, s)
  local r = s * 0.3
  love.graphics.circle("line", x + r + 2, y + r + 2, r, 24)
  love.graphics.line(x + r * 1.7 + 2, y + r * 1.7 + 2, x + s - 2, y + s - 2)
end

function icons.copy(x, y, s)
  ui.rect("line", x + 5, y + 2, s - 7, s - 7, 2)
  love.graphics.line(x + 2, y + 5, x + 2, y + s - 2, x + s - 5, y + s - 2)
end

function icons.trash(x, y, s)
  love.graphics.line(x + 2, y + 4, x + s - 2, y + 4)
  love.graphics.line(x + s * 0.38, y + 4, x + s * 0.38, y + 2, x + s * 0.62, y + 2, x + s * 0.62, y + 4)
  love.graphics.line(x + 3.5, y + 4, x + 4.5, y + s - 1.5, x + s - 4.5, y + s - 1.5, x + s - 3.5, y + 4)
end

function icons.sidebar(x, y, s)
  ui.rect("line", x + 1.5, y + 2.5, s - 3, s - 5, 2)
  love.graphics.line(x + s * 0.4, y + 2.5, x + s * 0.4, y + s - 2.5)
end

function icons.chevronDown(x, y, s)
  love.graphics.line(x + s * 0.25, y + s * 0.4, x + s * 0.5, y + s * 0.65, x + s * 0.75, y + s * 0.4)
end

function icons.chevronRight(x, y, s)
  love.graphics.line(x + s * 0.4, y + s * 0.25, x + s * 0.65, y + s * 0.5, x + s * 0.4, y + s * 0.75)
end

function icons.dots(x, y, s)
  for i = -1, 1 do
    love.graphics.circle("fill", x + s / 2 + i * s * 0.28, y + s / 2, 1.3, 8)
  end
end

function icons.comment(x, y, s)
  ui.rect("line", x + 1.5, y + 2, s - 3, s - 5.5, 2.5)
  love.graphics.line(x + s * 0.3, y + s - 3.5, x + s * 0.3, y + s - 1, x + s * 0.55, y + s - 3.5)
end

function icons.sun(x, y, s)
  local cx, cy = x + s / 2, y + s / 2
  love.graphics.circle("line", cx, cy, s * 0.2, 16)
  for i = 0, 7 do
    local a = i * math.pi / 4
    love.graphics.line(
      cx + math.cos(a) * s * 0.32,
      cy + math.sin(a) * s * 0.32,
      cx + math.cos(a) * s * 0.45,
      cy + math.sin(a) * s * 0.45
    )
  end
end

function icons.moon(x, y, s)
  local cx, cy = x + s / 2, y + s / 2
  love.graphics.arc("line", "open", cx, cy, s * 0.36, math.pi * 0.35, math.pi * 1.85, 20)
  love.graphics.arc("line", "open", cx + s * 0.16, cy - s * 0.1, s * 0.26, math.pi * 0.5, math.pi * 1.55, 16)
end

function icons.folder(x, y, s)
  love.graphics.line(
    x + 1.5,
    y + s - 3,
    x + 1.5,
    y + 3,
    x + s * 0.4,
    y + 3,
    x + s * 0.5,
    y + 5,
    x + s - 1.5,
    y + 5,
    x + s - 1.5,
    y + s - 3,
    x + 1.5,
    y + s - 3
  )
end

function icons.link(x, y, s)
  love.graphics.circle("line", x + s * 0.5, y + s * 0.5, s * 0.36, 20)
  love.graphics.circle("fill", x + s * 0.5, y + s * 0.5, s * 0.14, 12)
end

function icons.agent(x, y, s)
  ui.rect("line", x + 2, y + 4, s - 4, s - 6, 3)
  love.graphics.line(x + s / 2, y + 4, x + s / 2, y + 1.5)
  love.graphics.circle("fill", x + s * 0.37, y + s * 0.6, 1.3, 8)
  love.graphics.circle("fill", x + s * 0.63, y + s * 0.6, 1.3, 8)
end

--- Draw a named icon of size s at x,y in the given color.
function ui.icon(name, x, y, s, color)
  ui.color(color or theme.c.textDim)
  love.graphics.setLineWidth(1.4)
  love.graphics.setLineJoin("miter")
  icons[name](x, y, s)
  love.graphics.setLineWidth(1)
end

--- Linear-style priority glyph: bars for low..high, a filled badge for urgent.
function ui.priorityIcon(p, x, y, s)
  if p == 4 then
    ui.color(theme.priorityColors[4])
    ui.rect("fill", x, y, s, s, 3)
    love.graphics.setColor(1, 1, 1, 0.95)
    love.graphics.rectangle("fill", x + s / 2 - 0.9, y + 2.5, 1.8, s * 0.45)
    love.graphics.rectangle("fill", x + s / 2 - 0.9, y + s - 4.2, 1.8, 1.8)
    return
  end
  local bw = (s - 4) / 3
  for i = 1, 3 do
    local bh = s * (0.3 + 0.23 * (i - 1))
    if i <= p then
      ui.color(theme.c.textDim)
    else
      ui.color(theme.c.textFaint, 0.45)
    end
    ui.rect("fill", x + (i - 1) * (bw + 2), y + s - bh, bw, bh, 1)
  end
end

--- A small round avatar with the first letter of a name.
function ui.avatar(name, x, y, r)
  local col = theme.labelColor(name)
  love.graphics.setColor(col[1], col[2], col[3], 0.9)
  love.graphics.circle("fill", x + r, y + r, r, 24)
  local f = theme.fonts.small
  local letter = name:sub(1, 1):upper()
  love.graphics.setFont(f)
  love.graphics.setColor(0.08, 0.08, 0.1, 1)
  love.graphics.print(
    letter,
    math.floor(x + r - f:getWidth(letter) / 2 + 0.5),
    math.floor(y + r - f:getHeight() / 2 + 0.5)
  )
end

--- Pill-shaped label chip. Returns its width.
function ui.chip(text, x, y, color, font)
  font = font or theme.fonts.small
  local w = font:getWidth(text) + 21
  local h = font:getHeight() + 6
  love.graphics.setColor(color[1], color[2], color[3], theme.c.labelAlpha)
  ui.rect("fill", x, y, w, h, h / 2)
  love.graphics.setColor(color[1], color[2], color[3], 1)
  love.graphics.circle("fill", x + 9, y + h / 2, 2.5, 12)
  ui.text(text, font, x + 15, y + 3, theme.c.textDim)
  return w + 3, h
end

function ui.chipWidth(text, font)
  font = font or theme.fonts.small
  return font:getWidth(text) + 24
end

--- A simple button. style: "primary" | "ghost" | "danger" | "subtle".
function ui.button(id, label, x, y, w, h, opts)
  opts = opts or {}
  local style = opts.style or "subtle"
  local hot = ui.region(id, x, y, w, h, { onClick = opts.onClick, cursor = "hand" })
  local c = theme.c
  local font = opts.font or theme.fonts.bodyMedium
  local fg = c.text
  if style == "primary" then
    ui.color(c.accent, hot and 1 or 0.92)
    ui.rect("fill", x, y, w, h, 6)
    fg = c.accentText
  elseif style == "danger" then
    ui.color(c.danger, hot and 1 or 0.9)
    ui.rect("fill", x, y, w, h, 6)
    fg = { 1, 1, 1, 1 }
  elseif style == "subtle" then
    ui.color(hot and c.cardHover or c.raised)
    ui.rect("fill", x, y, w, h, 6)
    ui.color(c.border)
    ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 6)
  elseif hot then
    ui.color(c.text, 0.07)
    ui.rect("fill", x, y, w, h, 6)
  end
  local tx = x + w / 2
  local iconSize = 14
  local labelW = label ~= "" and font:getWidth(label) or 0
  local total = labelW + (opts.icon and (iconSize + (labelW > 0 and 6 or 0)) or 0)
  local sx = tx - total / 2
  if opts.icon then
    ui.icon(opts.icon, sx, y + (h - iconSize) / 2, iconSize, style == "ghost" and (hot and c.text or c.textDim) or fg)
    sx = sx + iconSize + 6
  end
  if label ~= "" then
    ui.text(label, font, sx, y + (h - font:getHeight()) / 2, style == "ghost" and (hot and c.text or c.textDim) or fg)
  end
  return hot
end

return ui
