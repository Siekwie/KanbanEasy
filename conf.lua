function love.conf(t)
  t.identity = "kanbaneasy"
  t.version = "11.5"
  t.console = false

  t.window.title = "KanbanEasy"
  t.window.icon = "assets/icon.png"
  t.window.width = 1280
  t.window.height = 800
  t.window.minwidth = 360
  t.window.minheight = 420
  t.window.resizable = true
  t.window.highdpi = true
  t.window.usedpiscale = true
  t.window.vsync = 1
  t.window.msaa = 4

  -- Only what we use: keeps startup fast and memory low.
  t.modules.audio = false
  t.modules.sound = false
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
  t.modules.touch = false
end
