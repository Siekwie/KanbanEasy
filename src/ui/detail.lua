-- Issue detail panel: everything editable in place, plus activity and comments.

local ui = require("src.ui.core")
local theme = require("src.ui.theme")
local TextInput = require("src.ui.textinput")
local Store = require("src.store")
local util = require("src.util")
local overlay = require("src.ui.overlay")

local detail = {}

local PAD = 24
local LABEL_W = 92

--- Build the editors for an issue.
function detail.open(app, id)
  local issue = app.store:issue(id)
  if not issue then
    return
  end
  local store = app.store
  local d = { id = id, scroll = { pos = 0, target = 0 }, contentH = 0 }

  local function commit(fields)
    local ok, err = store:updateIssue(d.id, fields)
    if not ok then
      overlay.toast(err, "error")
    end
  end

  d.title = TextInput.new({
    text = issue.title,
    font = theme.fonts.title,
    multiline = true,
    noNewlines = true,
    padX = 8,
    padY = 4,
    lineSpacing = 1.25,
    placeholder = "Issue title",
    id = "detail-title",
    onCommit = function(text, input)
      if util.trim(text) == "" then
        input:setText(store:issue(d.id).title)
        return
      end
      commit({ title = text })
    end,
    onSubmit = function()
      ui.blur()
    end,
  })
  d.desc = TextInput.new({
    text = issue.description,
    font = theme.fonts.body,
    multiline = true,
    padX = 8,
    padY = 8,
    lineSpacing = 1.5,
    placeholder = "Add a description…  (Ctrl+Enter to finish)",
    id = "detail-desc",
    onCommit = function(text)
      commit({ description = text })
    end,
  })
  d.assignee = TextInput.new({
    text = issue.assignee,
    placeholder = "Unassigned",
    id = "detail-assignee",
    padX = 8,
    onCommit = function(text)
      commit({ assignee = text })
    end,
    onSubmit = function()
      ui.blur()
    end,
  })
  d.labels = TextInput.new({
    text = table.concat(issue.labels, ", "),
    placeholder = "Add labels, comma separated",
    id = "detail-labels",
    padX = 8,
    onCommit = function(text, input)
      commit({ labels = text })
      local cur = store:issue(d.id)
      if cur then
        input:setText(table.concat(cur.labels, ", "))
      end
    end,
    onSubmit = function()
      ui.blur()
    end,
  })
  d.comment = TextInput.new({
    multiline = true,
    submitOnEnter = true,
    padX = 10,
    padY = 9,
    lineSpacing = 1.45,
    placeholder = "Leave a comment…",
    id = "detail-comment",
    onSubmit = function(text, input)
      if util.trim(text) == "" then
        return
      end
      local entry, err = store:addComment(d.id, text)
      if entry then
        input:setText("")
        input.history, input.future = {}, {}
        d.scroll.target = math.huge
      else
        overlay.toast(err, "error")
      end
    end,
  })
  app.detail = d
  app.openIssue = id
  app.selected = id
end

function detail.close(app)
  if app.detail then
    ui.blur()
  end
  app.detail = nil
  app.openIssue = nil
end

function detail.inputs(d)
  return { d.title, d.assignee, d.labels, d.desc, d.comment }
end

-- Drawing helpers ------------------------------------------------------------------------

local function propLabel(text, x, y, h)
  local f = theme.fonts.body
  ui.text(text, f, x, y + (h - f:getHeight()) / 2, theme.c.textFaint)
end

--- A dropdown-looking button showing the current value.
local function pill(id, x, y, h, drawContent, width, onClick)
  local c = theme.c
  local hot = ui.region(id, x, y, width, h, { cursor = "hand", onClick = onClick })
  if hot then
    ui.color(c.text, 0.05)
    ui.rect("fill", x, y, width, h, 6)
  end
  drawContent(x + 8, y, h)
  return hot
end

local function statusDot(colId, x, y)
  ui.color(theme.statusColor(colId))
  love.graphics.setLineWidth(2)
  if colId == "done" then
    love.graphics.circle("fill", x, y, 5.5, 20)
  else
    love.graphics.circle("line", x, y, 5, 20)
  end
  love.graphics.setLineWidth(1)
end

local function sectionHeader(text, x, y)
  ui.text(text, theme.fonts.small, x, y, theme.c.textFaint)
end

-- Main draw ---------------------------------------------------------------------------------

function detail.draw(app, x, y, w, h)
  local d = app.detail
  local issue, project = app.store:issue(d.id)
  if not issue then
    detail.close(app)
    return
  end
  local store = app.store
  local c = theme.c
  local f = theme.fonts

  -- keep editors in sync with changes from the API / undo
  d.title:sync(issue.title)
  d.desc:sync(issue.description)
  d.assignee:sync(issue.assignee)
  d.labels:sync(table.concat(issue.labels, ", "))

  ui.shadow(x, y, w, h, 0, 1.6)
  ui.color(c.sidebar)
  love.graphics.rectangle("fill", x, y, w, h)
  ui.color(c.border)
  love.graphics.rectangle("fill", x, y, 1, h)
  -- swallow input so the board underneath doesn't react
  ui.region("detail-bg", x, y, w, h, {
    onWheel = function(_, dy)
      d.scroll.target = d.scroll.target - dy * 60
      return true
    end,
    onPress = function()
      ui.blur()
    end,
  })

  -- Header ---------------------------------------------------------------
  local headerH = 52
  local hx = x + PAD
  local col = store:column(project, issue.status)
  ui.text(project.key, f.bodyMedium, hx, y + (headerH - f.bodyMedium:getHeight()) / 2, c.textDim)
  hx = hx + f.bodyMedium:getWidth(project.key) + 6
  ui.icon("chevronRight", hx, y + (headerH - 14) / 2, 14, c.textFaint)
  hx = hx + 18
  local idW = f.mono:getWidth(issue.id)
  local idHot = ui.region("detail-id", hx - 4, y + 14, idW + 8, 24, {
    cursor = "hand",
    onClick = function()
      app:copy(issue.id, "Copied " .. issue.id)
    end,
  })
  if idHot then
    ui.color(c.text, 0.06)
    ui.rect("fill", hx - 4, y + 14, idW + 8, 24, 5)
  end
  ui.text(issue.id, f.mono, hx, y + (headerH - f.mono:getHeight()) / 2, idHot and c.text or c.textDim)

  local bx = x + w - PAD - 28
  ui.button("detail-close", "", bx, y + 12, 28, 28, {
    style = "ghost",
    icon = "close",
    onClick = function()
      detail.close(app)
    end,
  })
  bx = bx - 32
  ui.button("detail-more", "", bx, y + 12, 28, 28, {
    style = "ghost",
    icon = "dots",
    onClick = function()
      app:cardMenu(issue, ui.mx - 150, ui.my + 14)
    end,
  })
  local copyW = f.bodyMedium:getWidth("Copy") + 40
  bx = bx - copyW - 6
  ui.button("detail-copy", "Copy", bx, y + 12, copyW, 28, {
    style = "subtle",
    icon = "copy",
    onClick = function()
      app:copyMenu(issue, ui.mx - 60, y + 44)
    end,
  })
  local agentW = f.bodyMedium:getWidth("Agent prompt") + 40
  if bx - agentW - 8 > hx + idW + 12 then
    bx = bx - agentW - 8
    ui.button("detail-agent", "Agent prompt", bx, y + 12, agentW, 28, {
      style = "subtle",
      icon = "agent",
      onClick = function()
        app:copy(app:agentPrompt(issue), "Copied agent prompt for " .. issue.id)
      end,
    })
  end
  ui.color(c.border)
  love.graphics.rectangle("fill", x, y + headerH, w, 1)

  -- Scrollable body --------------------------------------------------------
  local bodyY = y + headerH + 1
  local bodyH = h - headerH - 1
  local s = d.scroll
  local maxScroll = math.max(0, d.contentH - bodyH)
  s.target = util.clamp(s.target, 0, maxScroll)
  s.pos = util.clamp(s.pos, 0, maxScroll)
  ui.pushClip(x, bodyY, w, bodyH)
  local top = bodyY - math.floor(s.pos + 0.5)
  local cy = top + 18
  local cx = x + PAD - 8
  local cw = w - PAD * 2 + 16

  -- Title
  cy = cy + d.title:draw(cx, cy, cw, nil, { bg = false, border = false }) + 14

  -- Properties
  local rowH = 32
  local vx = x + PAD + LABEL_W
  local vw = w - PAD * 2 - LABEL_W

  propLabel("Status", x + PAD, cy, rowH)
  pill(
    "detail-status",
    vx - 8,
    cy,
    rowH,
    function(px, py, ph)
      statusDot(issue.status, px + 6, py + ph / 2)
      ui.text(col and col.name or issue.status, f.body, px + 20, py + (ph - f.body:getHeight()) / 2, c.text)
    end,
    math.min(vw + 8, 220),
    function()
      app:statusMenu(issue, ui.mx, ui.my + 10)
    end
  )
  cy = cy + rowH + 2

  propLabel("Priority", x + PAD, cy, rowH)
  pill(
    "detail-priority",
    vx - 8,
    cy,
    rowH,
    function(px, py, ph)
      ui.priorityIcon(issue.priority, px, py + (ph - 12) / 2, 12)
      local name = Store.PRIORITIES[issue.priority + 1]
      ui.text(
        issue.priority == 0 and "No priority" or name,
        f.body,
        px + 20,
        py + (ph - f.body:getHeight()) / 2,
        issue.priority == 0 and c.textDim or c.text
      )
    end,
    math.min(vw + 8, 220),
    function()
      app:priorityMenu(issue, ui.mx, ui.my + 10)
    end
  )
  cy = cy + rowH + 2

  propLabel("Assignee", x + PAD, cy, rowH)
  if issue.assignee ~= "" and not d.assignee:isFocused() then
    d.assignee.padX = 30
  else
    d.assignee.padX = 8
  end
  d.assignee:draw(vx - 8, cy, math.min(vw + 8, 300), rowH, { bg = false, border = false })
  if issue.assignee ~= "" and not d.assignee:isFocused() then
    ui.avatar(issue.assignee, vx, cy + rowH / 2 - 9, 9)
  end
  cy = cy + rowH + 2

  propLabel("Labels", x + PAD, cy, rowH)
  if #issue.labels > 0 and not d.labels:isFocused() then
    -- show chips; clicking focuses the text field
    local chipsW = math.min(vw + 8, 420)
    local hot = ui.region("detail-labelchips", vx - 8, cy, chipsW, rowH, {
      cursor = "ibeam",
      onPress = function()
        d.labels:focus()
        d.labels:moveTo(#d.labels.text + 1)
      end,
    })
    if hot then
      ui.color(c.text, 0.04)
      ui.rect("fill", vx - 8, cy, chipsW, rowH, 6)
    end
    local lx = vx
    for _, label in ipairs(issue.labels) do
      if lx + ui.chipWidth(label) > vx + chipsW - 16 then
        ui.text("…", f.body, lx, cy + 8, c.textFaint)
        break
      end
      lx = lx + ui.chip(label, lx, cy + (rowH - 20) / 2, theme.labelColor(label)) + 2
    end
  else
    d.labels:draw(vx - 8, cy, math.min(vw + 8, 420), rowH, { bg = false, border = false })
  end
  cy = cy + rowH + 2

  propLabel("Updated", x + PAD, cy, rowH)
  ui.text(
    util.ago(issue.updated) .. "  ·  created " .. os.date("%b %d, %H:%M", issue.created),
    f.body,
    vx,
    cy + (rowH - f.body:getHeight()) / 2,
    c.textDim
  )
  cy = cy + rowH + 16

  -- Description
  sectionHeader("DESCRIPTION", x + PAD, cy)
  ui.button("detail-copydesc", "", x + w - PAD - 22, cy - 6, 22, 22, {
    style = "ghost",
    icon = "copy",
    onClick = function()
      app:copy(issue.description, "Copied description")
    end,
  })
  cy = cy + 20
  local descH = math.max(110, d.desc:contentHeight(cw))
  d.desc:draw(cx, cy, cw, descH, { bg = false, border = false })
  cy = cy + descH + 22

  -- Activity
  ui.color(c.border)
  love.graphics.rectangle("fill", x + PAD, cy - 8, w - PAD * 2, 1)
  sectionHeader("ACTIVITY", x + PAD, cy + 6)
  cy = cy + 30
  local textW = w - PAD * 2 - 28
  for i, a in ipairs(issue.activity) do
    if a.kind == "comment" then
      local _, lines = f.body:getWrap(a.body, textW - 20)
      local lh = math.floor(f.body:getHeight() * 1.45)
      local boxH = 34 + #lines * lh + 8
      local bxx = x + PAD + 28
      local hot = ui.region("comment-" .. i, bxx, cy, textW, boxH, {
        onRightClick = function(mx, my)
          overlay.openMenu(mx, my, {
            {
              label = "Copy comment",
              icon = "copy",
              onSelect = function()
                app:copy(a.body, "Copied comment")
              end,
            },
          })
        end,
      })
      ui.avatar(a.author, x + PAD, cy + 6, 10)
      ui.color(c.card)
      ui.rect("fill", bxx, cy, textW, boxH, 8)
      ui.color(c.border)
      ui.rect("line", bxx + 0.5, cy + 0.5, textW - 1, boxH - 1, 8)
      ui.text(a.author, f.bodyMedium, bxx + 10, cy + 10, c.text)
      ui.text(util.ago(a.time), f.smallRegular, bxx + 18 + f.bodyMedium:getWidth(a.author), cy + 11, c.textFaint)
      if hot or ui.isHot("comment-copy-" .. i) then
        ui.button("comment-copy-" .. i, "", bxx + textW - 28, cy + 5, 22, 22, {
          style = "ghost",
          icon = "copy",
          onClick = function()
            app:copy(a.body, "Copied comment")
          end,
        })
      end
      love.graphics.setFont(f.body)
      ui.color(c.text)
      for li, line in ipairs(lines) do
        love.graphics.print(line, math.floor(bxx + 10), math.floor(cy + 32 + (li - 1) * lh))
      end
      cy = cy + boxH + 12
    else
      local text = a.author .. " " .. a.body
      local _, lines = f.smallRegular:getWrap(text .. "  ·  " .. util.ago(a.time), textW)
      ui.color(c.textFaint, 0.6)
      love.graphics.circle("fill", x + PAD + 10, cy + 7, 3, 12)
      local lh = math.floor(f.smallRegular:getHeight() * 1.4)
      for li, line in ipairs(lines) do
        ui.text(line, f.smallRegular, x + PAD + 28, cy + (li - 1) * lh, c.textFaint)
      end
      cy = cy + #lines * lh + 10
    end
  end

  -- New comment
  cy = cy + 4
  local commentH = math.max(64, d.comment:contentHeight(w - PAD * 2))
  d.comment:draw(x + PAD, cy, w - PAD * 2, commentH)
  cy = cy + commentH + 6
  ui.text("Enter to post · Shift+Enter for a new line", f.smallRegular, x + PAD + 2, cy, c.textFaint)
  cy = cy + 40
  ui.popClip()

  d.contentH = cy - top
  if s.target == math.huge then
    s.target = math.max(0, d.contentH - bodyH)
  end

  -- keep the caret of the focused editor in view
  for _, input in ipairs(detail.inputs(d)) do
    if input:isFocused() and input.wantScroll and input.drawn then
      input.wantScroll = false
      local off, lh = input:caretOffset()
      local _, iy = love.graphics.inverseTransformPoint(input.drawn.x, input.drawn.y)
      local caretTop = iy + (off or 0)
      local caretBottom = caretTop + (lh or 20)
      if caretTop < bodyY + 10 then
        s.target = s.target - (bodyY + 10 - caretTop)
      elseif caretBottom > bodyY + bodyH - 20 then
        s.target = s.target + (caretBottom - (bodyY + bodyH - 20))
      end
    end
  end

  -- scrollbar
  if maxScroll > 0 then
    local barH = math.max(30, bodyH * bodyH / d.contentH)
    local barY = bodyY + (bodyH - barH) * (s.pos / maxScroll)
    ui.color(c.text, 0.12)
    ui.rect("fill", x + w - 6, barY, 3, barH, 1.5)
  end
end

function detail.update(app, dt)
  local d = app.detail
  if not d then
    return false
  end
  local s = d.scroll
  if s.target ~= math.huge and math.abs(s.pos - s.target) > 0.3 then
    s.pos = util.damp(s.pos, s.target, 18, dt)
    return true
  end
  if s.target ~= math.huge then
    s.pos = s.target
  end
  return false
end

return detail
