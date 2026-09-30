-- KanbanEasy: a small, fast kanban board for keeping track of agentic work.

local ui = require("src.ui.core")
local theme = require("src.ui.theme")
local overlay = require("src.ui.overlay")
local persist = require("src.persist")
local Server = require("src.server")
local App = require("src.app")

local app

function love.load()
  love.keyboard.setKeyRepeat(true)
  love.keyboard.setTextInput(true)
  theme.loadFonts()

  local p, warning = persist.load()
  local port = tonumber(os.getenv("KANBANEASY_PORT") or "") or 7420
  local server = Server.new(p.store, { port = port })
  if os.getenv("KANBANEASY_NO_API") ~= "1" then
    server:start()
  else
    server.error = "disabled"
  end

  app = App.new(p, server)
  if warning then
    overlay.toast(warning, "error")
  end
  if server.error and server.error ~= "disabled" then
    overlay.toast("API not started: " .. server.error, "error")
  end
end

function love.update(dt)
  ui.time = ui.time + dt
  app.swallowText = false
  local busy = false
  if app.server:update() then
    busy = true
  end
  app.persist:update(dt)
  if app:update(dt) then
    busy = true
  end
  return busy
end

function love.draw()
  app:draw()
end

function love.keypressed(key)
  ui.keyEvent(key, true)
  app:keypressed(key)
end

function love.keyreleased(key)
  ui.keyEvent(key, false)
end

function love.textinput(t)
  app:textinput(t)
end

function love.mousepressed(x, y, button, _, presses)
  -- Clicking anything other than the focused input commits and blurs it
  -- (inputs re-focus themselves when clicked).
  if ui.focus and not overlay.modal then
    local r = ui.hitTest(x, y)
    if not (r and r.id == ui.focus.id) then
      ui.blur()
    end
  end
  ui.mousepressed(x, y, button, presses)
end

function love.mousereleased(x, y, button)
  ui.mousereleased(x, y, button)
end

function love.mousemoved(x, y)
  ui.mousemoved(x, y)
end

function love.wheelmoved(dx, dy)
  ui.wheelmoved(dx, dy)
end

function love.resize()
  ui.dirty = true
end

function love.focus()
  -- modifiers released while unfocused never reach us
  ui.clearMods()
  ui.dirty = true
end

function love.quit()
  app:quit()
  return false
end

-- A power-friendly main loop: only redraw when something changed or is animating,
-- and sleep while idle so the app can sit open all day next to your editor.
function love.run()
  love.load(love.arg.parseGameArguments(arg), arg) -- luacheck: ignore
  love.timer.step()
  local lastBlink = -1
  local idle = 0

  return function()
    love.event.pump()
    local hadEvents = false
    for name, a, b, c, d, e, f in love.event.poll() do
      if name == "quit" then
        if not love.quit or not love.quit() then
          return a or 0
        end
      end
      love.handlers[name](a, b, c, d, e, f) -- luacheck: ignore
      hadEvents = true
    end

    local dt = love.timer.step()
    local busy = love.update(dt)

    -- caret blink needs a redraw twice a second while an input is focused
    local blink = ui.focus and math.floor(ui.time / 0.53) or -1
    if blink ~= lastBlink then
      lastBlink = blink
      busy = true
    end

    if hadEvents or busy or ui.dirty then
      ui.dirty = false
      idle = 0
      if love.graphics.isActive() then
        love.graphics.origin()
        love.draw()
        love.graphics.present()
      end
      -- the draw can reveal new hover state; one extra frame settles it
    else
      idle = idle + dt
      love.timer.sleep(idle > 2 and 1 / 30 or 1 / 60)
    end
  end
end
