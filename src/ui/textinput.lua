-- Text input / multiline editor with selection, clipboard, word navigation,
-- mouse selection (click, drag, double/triple click), soft wrapping and undo.

local ui = require("src.ui.core")
local theme = require("src.ui.theme")
local util = require("src.util")

local TextInput = {}
TextInput.__index = TextInput

local primaryDown, shiftDown, altDown = ui.primary, ui.shift, ui.alt

--- opts: font, multiline, placeholder, onSubmit(text, input), onCommit(text, input),
---       onChange(text), onCancel(), submitOnEnter (multiline: Enter submits, Shift+Enter newline),
---       escapeCancels, padX, padY, noNewlines (multiline wrapping but no line breaks)
function TextInput.new(opts)
  opts = opts or {}
  local self = setmetatable({}, TextInput)
  self.text = opts.text or ""
  self.font = opts.font or theme.fonts.body
  self.multiline = opts.multiline or false
  self.noNewlines = opts.noNewlines or false
  self.placeholder = opts.placeholder or ""
  self.onSubmit = opts.onSubmit
  self.onCommit = opts.onCommit
  self.onChange = opts.onChange
  self.onCancel = opts.onCancel
  self.submitOnEnter = opts.submitOnEnter
  self.escapeCancels = opts.escapeCancels
  self.padX = opts.padX or 8
  self.padY = opts.padY or 6
  self.lineSpacing = opts.lineSpacing or 1.35
  self.cursor = #self.text + 1
  self.anchor = nil
  self.scrollX = 0
  self.lines = nil
  self.history = {}
  self.future = {}
  self.lastEdit = nil
  self.blinkStart = 0
  self.original = self.text
  self.id = opts.id or tostring(self)
  return self
end

-- Text / selection model -------------------------------------------------------

function TextInput:setText(text, keepCursor)
  text = text or ""
  if text == self.text then
    return
  end
  self.text = text
  if keepCursor then
    self.cursor = math.min(self.cursor, #text + 1)
  else
    self.cursor = #text + 1
  end
  self.anchor = nil
  self.lines = nil
end

--- Refresh from the model unless the user is editing.
function TextInput:sync(text)
  if not self:isFocused() and text ~= self.text then
    self:setText(text, true)
    self.history, self.future = {}, {}
  end
end

function TextInput:isFocused()
  return ui.focus == self
end

function TextInput:focus()
  ui.setFocus(self)
end

function TextInput:onFocus()
  self.original = self.text
  self.blinkStart = ui.time
end

function TextInput:onBlur()
  self.anchor = nil
  if self.onCommit and self.text ~= self.original then
    self.onCommit(self.text, self)
  end
  self.original = self.text
end

function TextInput:selection()
  if not self.anchor or self.anchor == self.cursor then
    return nil
  end
  return math.min(self.anchor, self.cursor), math.max(self.anchor, self.cursor)
end

function TextInput:selectedText()
  local a, b = self:selection()
  if not a then
    return ""
  end
  return self.text:sub(a, b - 1)
end

function TextInput:selectAll()
  self.anchor = 1
  self.cursor = #self.text + 1
  self:touch()
end

function TextInput:touch()
  self.blinkStart = ui.time
  self.wantScroll = true
  ui.dirty = true
end

function TextInput:pushHistory(kind)
  -- Group consecutive typing into a single undo step.
  if kind == "type" and self.lastEdit == "type" then
    return
  end
  table.insert(self.history, { text = self.text, cursor = self.cursor })
  if #self.history > 200 then
    table.remove(self.history, 1)
  end
  self.future = {}
  self.lastEdit = kind
end

function TextInput:changed()
  self.lines = nil
  if self.onChange then
    self.onChange(self.text, self)
  end
  self:touch()
end

function TextInput:insert(s, kind)
  if not self.multiline or self.noNewlines then
    s = s:gsub("\r?\n", " ")
  else
    s = s:gsub("\r\n", "\n")
  end
  s = s:gsub("\t", "  ")
  s = util.sanitizeUtf8(s)
  if s == "" then
    return
  end
  self:pushHistory(kind or "type")
  local a, b = self:selection()
  if not a then
    a, b = self.cursor, self.cursor
  end
  self.text = self.text:sub(1, a - 1) .. s .. self.text:sub(b)
  self.cursor = a + #s
  self.anchor = nil
  self:changed()
end

function TextInput:deleteRange(a, b)
  if a >= b then
    return
  end
  self:pushHistory("delete")
  self.text = self.text:sub(1, a - 1) .. self.text:sub(b)
  self.cursor = a
  self.anchor = nil
  self:changed()
end

function TextInput:undo()
  local h = table.remove(self.history)
  if not h then
    return false
  end
  table.insert(self.future, { text = self.text, cursor = self.cursor })
  self.text, self.cursor, self.anchor = h.text, h.cursor, nil
  self.lastEdit = nil
  self:changed()
  return true
end

function TextInput:redo()
  local h = table.remove(self.future)
  if not h then
    return false
  end
  table.insert(self.history, { text = self.text, cursor = self.cursor })
  self.text, self.cursor, self.anchor = h.text, h.cursor, nil
  self.lastEdit = nil
  self:changed()
  return true
end

-- Word boundaries --------------------------------------------------------------

local function isWordByte(b)
  return b and (b >= 0x80 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

function TextInput:wordLeft(pos)
  local s = self.text
  local i = pos
  while i > 1 and not isWordByte(s:byte(util.prevChar(s, i))) do
    i = util.prevChar(s, i)
  end
  while i > 1 and isWordByte(s:byte(util.prevChar(s, i))) do
    i = util.prevChar(s, i)
  end
  return i
end

function TextInput:wordRight(pos)
  local s = self.text
  local i = pos
  while i <= #s and not isWordByte(s:byte(i)) do
    i = util.nextChar(s, i)
  end
  while i <= #s and isWordByte(s:byte(i)) do
    i = util.nextChar(s, i)
  end
  return i
end

function TextInput:wordAt(pos)
  local s = self.text
  local a, b = pos, pos
  if pos <= #s and isWordByte(s:byte(pos)) or (pos > 1 and isWordByte(s:byte(util.prevChar(s, pos)))) then
    while a > 1 and isWordByte(s:byte(util.prevChar(s, a))) do
      a = util.prevChar(s, a)
    end
    while b <= #s and isWordByte(s:byte(b)) do
      b = util.nextChar(s, b)
    end
  else
    b = util.nextChar(s, pos)
  end
  return a, b
end

-- Layout -------------------------------------------------------------------------

function TextInput:lineHeight()
  return math.floor(self.font:getHeight() * (self.multiline and self.lineSpacing or 1) + 0.5)
end

--- Break text into visual lines for a given width. Each line: {s = first byte, e = byte after last char}.
function TextInput:layout(width)
  if self.lines and self.layoutText == self.text and self.layoutWidth == width then
    return self.lines
  end
  local font, s = self.font, self.text
  local lines = {}
  if not self.multiline then
    lines[1] = { s = 1, e = #s + 1 }
  else
    local pos = 1
    while true do
      local nl = s:find("\n", pos, true)
      local pe = nl or (#s + 1)
      -- wrap the paragraph [pos, pe)
      local ls = pos
      if ls == pe then
        lines[#lines + 1] = { s = ls, e = pe }
      end
      while ls < pe do
        -- find the longest prefix that fits, preferring to break after spaces
        local lastBreak, i, fitEnd, acc = nil, ls, ls, 0
        while i < pe do
          local ni = util.nextChar(s, i)
          acc = acc + font:getWidth(s:sub(i, ni - 1))
          if acc > width and i > ls and s:byte(i) ~= 32 then
            break
          end
          fitEnd = ni
          if s:byte(i) == 32 then
            lastBreak = ni
          end
          i = ni
        end
        local e = fitEnd
        if fitEnd < pe and lastBreak and lastBreak > ls then
          e = lastBreak
        end
        lines[#lines + 1] = { s = ls, e = e }
        ls = e
      end
      if not nl then
        break
      end
      pos = nl + 1
    end
  end
  self.lines = lines
  self.layoutText = self.text
  self.layoutWidth = width
  return lines
end

--- Line index containing byte position pos.
function TextInput:lineOf(pos)
  local lines = self.lines
  for i = #lines, 1, -1 do
    if pos >= lines[i].s then
      return i
    end
  end
  return 1
end

function TextInput:posX(line, pos)
  return self.font:getWidth(self.text:sub(line.s, pos - 1))
end

--- Byte position closest to x on a line.
function TextInput:posAtX(line, x)
  local s = self.text
  local best, bestD = line.s, math.abs(x)
  local i = line.s
  while i < line.e do
    local ni = util.nextChar(s, i)
    local w = self.font:getWidth(s:sub(line.s, ni - 1))
    local d = math.abs(x - w)
    if d < bestD then
      best, bestD = ni, d
    end
    if w > x then
      break
    end
    i = ni
  end
  -- Don't place the cursor after a wrapped line's trailing space (it belongs to the next line).
  local last = self.lines[#self.lines]
  if best == line.e and line ~= last and s:byte(line.e) ~= 10 and best > line.s then
    local prev = util.prevChar(s, best)
    if s:byte(prev) == 32 then
      best = prev
    end
  end
  return best
end

--- Content height for a given width (multiline inputs grow to fit).
function TextInput:contentHeight(width)
  local lines = self:layout(width - self.padX * 2)
  return #lines * self:lineHeight() + self.padY * 2
end

function TextInput:posAtPoint(mx, my)
  if not self.drawn then
    return self.cursor
  end
  local d = self.drawn
  local lx, ly = mx - d.x - self.padX + self.scrollX, my - d.y - self.padY
  local lines = self.lines or self:layout(d.w - self.padX * 2)
  local li = util.clamp(math.floor(ly / self:lineHeight()) + 1, 1, #lines)
  if not self.multiline then
    li = 1
  end
  return self:posAtX(lines[li], lx)
end

--- Caret rectangle relative to the input's top-left (for scrolling containers).
function TextInput:caretOffset()
  if not self.lines then
    return 0
  end
  local li = self:lineOf(self.cursor)
  return self.padY + (li - 1) * self:lineHeight(), self:lineHeight()
end

-- Keyboard ------------------------------------------------------------------------

function TextInput:moveTo(pos, extend)
  if extend then
    self.anchor = self.anchor or self.cursor
  else
    self.anchor = nil
  end
  self.cursor = util.clamp(pos, 1, #self.text + 1)
  self.lastEdit = nil
  self.goalX = nil
  self:touch()
end

function TextInput:verticalMove(dir, extend)
  local lines = self.lines
  if not lines then
    return false
  end
  local li = self:lineOf(self.cursor)
  local target = li + dir
  if target < 1 or target > #lines then
    -- move to start/end like most editors
    self:moveTo(dir < 0 and 1 or #self.text + 1, extend)
    return true
  end
  local gx = self.goalX or self:posX(lines[li], self.cursor)
  local pos = self:posAtX(lines[target], gx)
  self:moveTo(pos, extend)
  self.goalX = gx
  return true
end

function TextInput:keypressed(key)
  local ctrl, shift, alt = primaryDown(), shiftDown(), altDown()
  local wordMod = ctrl or alt
  local s = self.text
  local lines = self.lines or self:layout(1e9)
  local li = self:lineOf(self.cursor)
  if key == "left" then
    local a = self:selection()
    if a and not shift then
      self:moveTo(a)
    else
      self:moveTo(wordMod and self:wordLeft(self.cursor) or util.prevChar(s, self.cursor), shift)
    end
  elseif key == "right" then
    local _, b = self:selection()
    if b and not shift then
      self:moveTo(b)
    else
      self:moveTo(wordMod and self:wordRight(self.cursor) or util.nextChar(s, self.cursor), shift)
    end
  elseif key == "up" and self.multiline then
    self:verticalMove(-1, shift)
  elseif key == "down" and self.multiline then
    self:verticalMove(1, shift)
  elseif key == "home" or (key == "up" and not self.multiline) then
    self:moveTo(ctrl and 1 or lines[li].s, shift)
  elseif key == "end" or (key == "down" and not self.multiline) then
    local e = lines[li].e
    -- end of a wrapped line: stay before the break so we don't jump to the next line
    if li < #lines and s:byte(e - 1) == 32 and lines[li + 1].s == e then
      e = e - 1
    end
    self:moveTo(ctrl and #s + 1 or e, shift)
  elseif key == "backspace" then
    local a, b = self:selection()
    if a then
      self:deleteRange(a, b)
    elseif ctrl or alt then
      self:deleteRange(self:wordLeft(self.cursor), self.cursor)
    elseif self.cursor > 1 then
      self:deleteRange(util.prevChar(s, self.cursor), self.cursor)
    end
  elseif key == "delete" then
    local a, b = self:selection()
    if a then
      self:deleteRange(a, b)
    elseif ctrl or alt then
      self:deleteRange(self.cursor, self:wordRight(self.cursor))
    elseif self.cursor <= #s then
      self:deleteRange(self.cursor, util.nextChar(s, self.cursor))
    end
  elseif ctrl and key == "a" then
    self:selectAll()
  elseif ctrl and (key == "c" or key == "x") then
    local sel = self:selectedText()
    if sel ~= "" then
      love.system.setClipboardText(sel)
      if key == "x" then
        local a, b = self:selection()
        self:deleteRange(a, b)
      end
    elseif key == "c" then
      return false -- let the app handle copy when there's no selection
    end
  elseif ctrl and key == "v" then
    local clip = love.system.getClipboardText() or ""
    self:insert(clip, "paste")
  elseif ctrl and key == "z" then
    if shift then
      self:redo()
    else
      self:undo()
    end
  elseif ctrl and key == "y" then
    self:redo()
  elseif key == "return" or key == "kpenter" then
    local submit
    if not self.multiline or self.noNewlines then
      submit = true
    elseif self.submitOnEnter then
      submit = not shift
    else
      submit = ctrl
    end
    if submit then
      if self.onSubmit then
        self.onSubmit(self.text, self)
      else
        ui.blur()
      end
    else
      self:insert("\n", "newline")
    end
  elseif key == "escape" then
    if self.escapeCancels then
      self.text = self.original
      self.lines = nil
      self.original = self.text
      if self.onCancel then
        self.onCancel(self)
      end
    end
    ui.blur()
  elseif key == "tab" then
    return false
  else
    return false
  end
  return true
end

function TextInput:textinput(t)
  self:insert(t, "type")
  return true
end

-- Mouse ----------------------------------------------------------------------------

function TextInput:press(mx, my, presses)
  local wasFocused = self:isFocused()
  ui.setFocus(self)
  local pos = self:posAtPoint(mx, my)
  if presses == 2 then
    local a, b = self:wordAt(pos)
    self.anchor, self.cursor = a, b
    self:touch()
  elseif presses >= 3 then
    local lines = self.lines or self:layout(1e9)
    -- select the whole paragraph
    local s = self.text
    local a, b = pos, pos
    while a > 1 and s:byte(a - 1) ~= 10 do
      a = a - 1
    end
    while b <= #s and s:byte(b) ~= 10 do
      b = b + 1
    end
    self.anchor, self.cursor = a, b
    self:touch()
    local _ = lines
  else
    self:moveTo(pos, shiftDown() and wasFocused)
    self.anchor = self.anchor or pos
  end
  local selecting = presses
  local wordA, wordB = self.anchor, self.cursor
  ui.startCapture({
    cursor = "ibeam",
    onMove = function(x, y)
      local p = self:posAtPoint(x, y)
      if selecting == 2 then
        local a, b = self:wordAt(p)
        if p < wordA then
          self.anchor, self.cursor = wordB, a
        else
          self.anchor, self.cursor = wordA, b
        end
      else
        self.cursor = p
      end
      self:touch()
    end,
  })
end

-- Drawing --------------------------------------------------------------------------

--- Draw the input. For multiline, h may be nil to auto-size. Returns the drawn height.
--- opts: bg (bool), border (bool), color, placeholderColor
function TextInput:draw(x, y, w, h, opts)
  opts = opts or {}
  local c = theme.c
  local font = self.font
  local lh = self:lineHeight()
  local innerW = w - self.padX * 2
  local lines = self:layout(self.multiline and innerW or 1e9)
  if not h then
    h = #lines * lh + self.padY * 2
  end
  self.drawn = { x = x, y = y, w = w, h = h }
  local focused = self:isFocused()
  local hovered = ui.region(self.id, x, y, w, h, {
    cursor = "ibeam",
    onPress = function(mx, my, presses)
      self:press(mx, my, presses)
    end,
    onWheel = opts.onWheel,
  })
  -- store screen-space rect for mouse mapping
  local sx, sy = love.graphics.transformPoint(x, y)
  self.drawn.x, self.drawn.y = sx, sy

  if opts.bg ~= false then
    ui.color(focused and c.input or (hovered and c.input or opts.bgColor or c.input))
    ui.rect("fill", x, y, w, h, 6)
  end
  if opts.border ~= false then
    if focused then
      ui.color(c.accent, 0.8)
    else
      ui.color(hovered and c.borderStrong or c.border)
    end
    love.graphics.setLineWidth(1)
    ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 6)
  elseif focused and opts.focusRing ~= false then
    ui.color(c.accent, 0.5)
    ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 6)
  elseif hovered and opts.hoverBg ~= false then
    ui.color(c.text, 0.04)
    ui.rect("fill", x, y, w, h, 6)
  end

  ui.pushClip(x + 2, y, w - 4, h)
  local tx = x + self.padX
  local ty = y + self.padY
  if not self.multiline then
    ty = y + math.floor((h - font:getHeight()) / 2)
    -- horizontal scroll to keep the caret visible
    local cx = self:posX(lines[1], self.cursor)
    if cx - self.scrollX > innerW then
      self.scrollX = cx - innerW
    elseif cx - self.scrollX < 0 then
      self.scrollX = cx
    end
    local tw = font:getWidth(self.text)
    if tw - self.scrollX < innerW then
      self.scrollX = math.max(0, tw - innerW)
    end
    tx = tx - self.scrollX
  end
  local lineOffset = self.multiline and math.floor((lh - font:getHeight()) / 2) or 0

  -- selection
  local sa, sb = self:selection()
  if sa and focused then
    ui.color(c.selection)
    for i, line in ipairs(lines) do
      local a, b = math.max(sa, line.s), math.min(sb, line.e)
      local nextLine = lines[i + 1]
      local includesBreak = sb > line.e and nextLine and nextLine.s > line.e
      if a < b or (a == b and includesBreak and sa <= line.e) then
        local x1 = self:posX(line, a)
        local x2 = self:posX(line, b)
        if includesBreak then
          x2 = x2 + 5
        end
        love.graphics.rectangle("fill", tx + x1, ty + (i - 1) * lh, math.max(2, x2 - x1), lh)
      end
    end
  end

  love.graphics.setFont(font)
  if self.text == "" then
    ui.color(opts.placeholderColor or c.textFaint)
    love.graphics.print(self.placeholder, math.floor(tx), math.floor(ty + lineOffset))
  else
    ui.color(opts.color or c.text)
    for i, line in ipairs(lines) do
      local seg = self.text:sub(line.s, line.e - 1):gsub("\n", "")
      if seg ~= "" then
        love.graphics.print(seg, math.floor(tx), math.floor(ty + (i - 1) * lh + lineOffset))
      end
    end
  end

  -- caret
  if focused then
    local phase = (ui.time - self.blinkStart) % 1.06
    if phase < 0.6 then
      local li = self:lineOf(self.cursor)
      local cx = self:posX(lines[li], self.cursor)
      ui.color(c.accent)
      love.graphics.rectangle(
        "fill",
        math.floor(tx + cx),
        ty + (li - 1) * lh + lineOffset - 1,
        1.5,
        font:getHeight() + 2
      )
    end
  end
  ui.popClip()
  return h
end

return TextInput
