-- Floating UI: context/dropdown menus, modal dialogs and toast notifications.

local ui = require("src.ui.core")
local theme = require("src.ui.theme")
local TextInput = require("src.ui.textinput")
local util = require("src.util")

local overlay = {}

-- Menus ----------------------------------------------------------------------------

overlay.menu = nil

--- items: { {label=, onSelect=, dot=color, icon=, hint=, danger=, checked=} | {separator=true} | {header=} }
function overlay.openMenu(x, y, items, opts)
  opts = opts or {}
  local sel
  for i, item in ipairs(items) do
    if item.onSelect and not sel then
      sel = i
    end
  end
  overlay.menu = { x = x, y = y, items = items, hover = opts.keyboard and sel or nil, minW = opts.minW or 0 }
  ui.dirty = true
end

function overlay.closeMenu()
  overlay.menu = nil
  ui.dirty = true
end

local ITEM_H, PAD = 28, 5

local function menuSize(m)
  local f = theme.fonts.body
  local w, h = m.minW, PAD * 2
  for _, item in ipairs(m.items) do
    if item.separator then
      h = h + 9
    elseif item.header then
      h = h + 24
      w = math.max(w, theme.fonts.small:getWidth(item.header:upper()) + 24)
    else
      h = h + ITEM_H
      local iw = f:getWidth(item.label) + 40 + (item.hint and (theme.fonts.small:getWidth(item.hint) + 20) or 0)
      w = math.max(w, iw)
    end
  end
  return math.max(170, w), h
end

local function selectItem(item)
  overlay.closeMenu()
  if item.onSelect then
    item.onSelect()
  end
end

local function drawMenu()
  local m = overlay.menu
  local c = theme.c
  local W, H = love.graphics.getDimensions()
  local w, h = menuSize(m)
  local x = util.clamp(m.x, 6, W - w - 6)
  local y = m.y
  if y + h > H - 6 then
    y = math.max(6, math.min(m.y - h, H - h - 6))
  end
  -- click-away catcher
  ui.region("menu-backdrop", 0, 0, W, H, {
    modal = true,
    onPress = function()
      overlay.closeMenu()
    end,
    onWheel = function()
      return true
    end,
  })
  ui.shadow(x, y, w, h, 8, 1.2)
  ui.color(c.raised)
  ui.rect("fill", x, y, w, h, 8)
  ui.color(c.borderStrong)
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 8)
  ui.region("menu-body", x, y, w, h, {})
  local cy = y + PAD
  for i, item in ipairs(m.items) do
    if item.separator then
      ui.color(c.border)
      love.graphics.rectangle("fill", x + 8, cy + 4, w - 16, 1)
      cy = cy + 9
    elseif item.header then
      ui.text(item.header:upper(), theme.fonts.small, x + 12, cy + 7, c.textFaint)
      cy = cy + 24
    else
      local hot = ui.region("menu-item-" .. i, x + 4, cy, w - 8, ITEM_H, {
        cursor = "hand",
        onClick = function()
          selectItem(item)
        end,
      })
      if hot then
        m.hover = i
      end
      if m.hover == i then
        ui.color(item.danger and c.danger or c.accent, item.danger and 0.16 or 0.18)
        ui.rect("fill", x + 4, cy, w - 8, ITEM_H, 5)
      end
      local tx = x + 12
      if item.dot then
        ui.color(item.dot)
        love.graphics.circle("fill", tx + 5, cy + ITEM_H / 2, 4, 16)
        tx = tx + 18
      elseif item.icon then
        ui.icon(item.icon, tx, cy + (ITEM_H - 14) / 2, 14, item.danger and c.danger or c.textDim)
        tx = tx + 22
      elseif item.priority then
        ui.priorityIcon(item.priority, tx, cy + (ITEM_H - 12) / 2, 12)
        tx = tx + 20
      end
      local col = item.danger and c.danger or c.text
      ui.text(item.label, theme.fonts.body, tx, cy + (ITEM_H - theme.fonts.body:getHeight()) / 2, col)
      if item.checked then
        ui.color(c.accent)
        love.graphics.setLineWidth(1.6)
        love.graphics.line(x + w - 24, cy + 14, x + w - 20, cy + 18, x + w - 13, cy + 10)
        love.graphics.setLineWidth(1)
      elseif item.hint then
        local f = theme.fonts.small
        ui.text(item.hint, f, x + w - 12 - f:getWidth(item.hint), cy + (ITEM_H - f:getHeight()) / 2, c.textFaint)
      end
      cy = cy + ITEM_H
    end
  end
end

local function menuKey(key)
  local m = overlay.menu
  if key == "escape" then
    overlay.closeMenu()
    return true
  end
  local selectable = {}
  for i, item in ipairs(m.items) do
    if item.onSelect then
      selectable[#selectable + 1] = i
    end
  end
  if #selectable == 0 then
    return true
  end
  local pos = util.indexOf(selectable, m.hover) or 0
  if key == "down" or key == "tab" then
    m.hover = selectable[pos % #selectable + 1]
  elseif key == "up" then
    m.hover = selectable[(pos - 2) % #selectable + 1]
  elseif (key == "return" or key == "kpenter" or key == "space") and m.hover then
    selectItem(m.items[m.hover])
  end
  ui.dirty = true
  return true
end

-- Modal dialogs ------------------------------------------------------------------

overlay.modal = nil

--- opts: title, message, fields = { {key, label, value, placeholder} }, confirm = label,
---       danger = bool, onConfirm(values) -> errString|nil
function overlay.openModal(opts)
  local m = { opts = opts, inputs = {}, error = nil }
  for i, f in ipairs(opts.fields or {}) do
    local input = TextInput.new({
      text = f.value or "",
      placeholder = f.placeholder or "",
      font = theme.fonts.body,
      padX = 10,
      onSubmit = function()
        overlay.confirmModal()
      end,
      id = "modal-input-" .. i,
    })
    input.onChange = f.onChange and function(text)
      f.onChange(text, m)
    end
    input:selectAll()
    m.inputs[i] = input
  end
  overlay.modal = m
  if m.inputs[1] then
    ui.setFocus(m.inputs[1])
  else
    ui.blur()
  end
  ui.dirty = true
end

function overlay.closeModal()
  if overlay.modal then
    overlay.modal = nil
    ui.blur()
    ui.dirty = true
  end
end

function overlay.confirmModal()
  local m = overlay.modal
  if not m then
    return
  end
  local values = {}
  for i, f in ipairs(m.opts.fields or {}) do
    values[f.key] = m.inputs[i].text
  end
  local err = m.opts.onConfirm and m.opts.onConfirm(values)
  if err then
    m.error = err
    ui.dirty = true
    return
  end
  overlay.closeModal()
end

local function drawModal()
  local m = overlay.modal
  local c = theme.c
  local W, H = love.graphics.getDimensions()
  ui.color(c.overlay)
  love.graphics.rectangle("fill", 0, 0, W, H)
  ui.region("modal-backdrop", 0, 0, W, H, {
    modal = true,
    onPress = function()
      overlay.closeModal()
    end,
    onWheel = function()
      return true
    end,
  })
  local w = math.min(420, W - 32)
  local f = theme.fonts
  local msgLines = {}
  if m.opts.message then
    local _, lines = f.body:getWrap(m.opts.message, w - 40)
    msgLines = lines
  end
  local fields = m.opts.fields or {}
  local h = 24 + f.heading:getHeight() + 14
  h = h + #msgLines * math.floor(f.body:getHeight() * 1.4) + (#msgLines > 0 and 10 or 0)
  h = h + #fields * 62 + (m.error and 24 or 0) + 56
  local x, y = math.floor((W - w) / 2), math.floor(math.max(20, H * 0.28 - h / 3))
  ui.region("modal-body", x, y, w, h, {
    onWheel = function()
      return true
    end,
  })
  ui.shadow(x, y, w, h, 12, 1.5)
  ui.color(c.raised)
  ui.rect("fill", x, y, w, h, 12)
  ui.color(c.borderStrong)
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 12)
  local cy = y + 22
  ui.text(m.opts.title or "", f.heading, x + 20, cy, c.text)
  cy = cy + f.heading:getHeight() + 14
  for _, line in ipairs(msgLines) do
    ui.text(line, f.body, x + 20, cy, c.textDim)
    cy = cy + math.floor(f.body:getHeight() * 1.4)
  end
  if #msgLines > 0 then
    cy = cy + 10
  end
  for i, field in ipairs(fields) do
    ui.text(field.label or "", f.small, x + 20, cy, c.textDim)
    m.inputs[i]:draw(x + 20, cy + 20, w - 40, 34)
    cy = cy + 62
  end
  if m.error then
    ui.text(m.error, f.smallRegular, x + 20, cy - 4, c.danger)
    -- (error line sits above the buttons)
  end
  local bw = math.max(96, f.bodyMedium:getWidth(m.opts.confirm or "OK") + 32)
  ui.button("modal-ok", m.opts.confirm or "OK", x + w - 20 - bw, y + h - 50, bw, 32, {
    style = m.opts.danger and "danger" or "primary",
    onClick = overlay.confirmModal,
  })
  if not m.opts.noCancel then
    ui.button("modal-cancel", "Cancel", x + w - 20 - bw - 8 - 84, y + h - 50, 84, 32, {
      style = "ghost",
      onClick = overlay.closeModal,
    })
  end
end

local function modalKey(key)
  local m = overlay.modal
  if key == "escape" then
    overlay.closeModal()
    return true
  end
  if key == "tab" and #m.inputs > 1 then
    local idx = util.indexOf(m.inputs, ui.focus) or 0
    local nxt = m.inputs[idx % #m.inputs + 1]
    ui.setFocus(nxt)
    nxt:selectAll()
    return true
  end
  if (key == "return" or key == "kpenter") and not ui.focus then
    overlay.confirmModal()
    return true
  end
  return true
end

-- Toasts -----------------------------------------------------------------------------

overlay.toasts = {}

function overlay.toast(text, kind)
  table.insert(overlay.toasts, { text = text, kind = kind, t = 0 })
  if #overlay.toasts > 3 then
    table.remove(overlay.toasts, 1)
  end
  ui.dirty = true
end

local TOAST_LIFE = 2.2

local function drawToasts()
  local c = theme.c
  local W, H = love.graphics.getDimensions()
  local y = H - 20
  local f = theme.fonts.bodyMedium
  for i = #overlay.toasts, 1, -1 do
    local t = overlay.toasts[i]
    local a = math.min(1, t.t / 0.12, (TOAST_LIFE - t.t) / 0.35)
    local w = f:getWidth(t.text) + 36
    local h = 34
    local slide = (1 - math.min(1, t.t / 0.15)) * 10
    y = y - h - 8
    local x = math.floor((W - w) / 2)
    love.graphics.push()
    love.graphics.translate(0, slide)
    ui.shadow(x, y, w, h, h / 2, a)
    ui.color(c.raised, a)
    ui.rect("fill", x, y, w, h, h / 2)
    ui.color(c.borderStrong, a)
    ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, h / 2)
    ui.color(t.kind == "error" and c.danger or c.success, a)
    love.graphics.circle("fill", x + 16, y + h / 2, 3.5, 12)
    love.graphics.setFont(f)
    ui.color(c.text, a)
    love.graphics.print(t.text, x + 26, math.floor(y + (h - f:getHeight()) / 2))
    love.graphics.pop()
  end
end

-- Shared entry points ---------------------------------------------------------------

function overlay.update(dt)
  local busy = false
  for i = #overlay.toasts, 1, -1 do
    local t = overlay.toasts[i]
    t.t = t.t + dt
    if t.t > TOAST_LIFE then
      table.remove(overlay.toasts, i)
    end
    busy = true
  end
  return busy
end

function overlay.draw()
  if overlay.modal then
    drawModal()
  end
  if overlay.menu then
    drawMenu()
  end
  drawToasts()
end

--- Returns true if an overlay consumed the key.
function overlay.keypressed(key)
  if overlay.menu then
    return menuKey(key)
  end
  if overlay.modal then
    if key ~= "escape" and ui.focus and ui.focus:keypressed(key) then
      return true
    end
    return modalKey(key)
  end
  return false
end

function overlay.isOpen()
  return overlay.menu ~= nil or overlay.modal ~= nil
end

return overlay
