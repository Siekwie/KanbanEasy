-- Colors and fonts. Two palettes (dark default, light); fonts are loaded once.

local theme = {}

local function hex(s, a)
  s = s:gsub("#", "")
  return {
    tonumber(s:sub(1, 2), 16) / 255,
    tonumber(s:sub(3, 4), 16) / 255,
    tonumber(s:sub(5, 6), 16) / 255,
    a or 1,
  }
end
theme.hex = hex

local palettes = {
  dark = {
    bg = hex("#0d0e12"),
    sidebar = hex("#111217"),
    topbar = hex("#0d0e12"),
    column = hex("#14151b"),
    card = hex("#1b1d24"),
    cardHover = hex("#21242c"),
    raised = hex("#1f2129"),
    input = hex("#16171d"),
    border = hex("#262932"),
    borderStrong = hex("#343846"),
    text = hex("#e7e9ef"),
    textDim = hex("#a0a6b3"),
    textFaint = hex("#6b7180"),
    accent = hex("#7b83ff"),
    accentText = hex("#ffffff"),
    accentSoft = hex("#7b83ff", 0.16),
    selection = hex("#7b83ff", 0.35),
    danger = hex("#f47272"),
    success = hex("#4ade80"),
    shadow = { 0, 0, 0, 0.45 },
    overlay = { 0, 0, 0, 0.5 },
    labelAlpha = 0.18,
  },
  light = {
    bg = hex("#f6f7f9"),
    sidebar = hex("#eef0f3"),
    topbar = hex("#f6f7f9"),
    column = hex("#eceef2"),
    card = hex("#ffffff"),
    cardHover = hex("#fafbfc"),
    raised = hex("#ffffff"),
    input = hex("#ffffff"),
    border = hex("#dfe2e8"),
    borderStrong = hex("#c9cdd6"),
    text = hex("#1b1d24"),
    textDim = hex("#5b6170"),
    textFaint = hex("#9095a1"),
    accent = hex("#5b63f0"),
    accentText = hex("#ffffff"),
    accentSoft = hex("#5b63f0", 0.12),
    selection = hex("#5b63f0", 0.25),
    danger = hex("#e04848"),
    success = hex("#1f9d55"),
    shadow = { 0.1, 0.12, 0.2, 0.14 },
    overlay = { 0.05, 0.06, 0.1, 0.28 },
    labelAlpha = 0.14,
  },
}

theme.statusColors = {
  backlog = hex("#6b7180"),
  todo = hex("#a0a6b3"),
  in_progress = hex("#f5b73b"),
  review = hex("#a78bfa"),
  done = hex("#4ade80"),
}

theme.priorityColors = {
  [0] = hex("#6b7180"),
  [1] = hex("#60a5fa"),
  [2] = hex("#f5b73b"),
  [3] = hex("#fb923c"),
  [4] = hex("#f47272"),
}

local labelHues = {
  hex("#60a5fa"),
  hex("#f472b6"),
  hex("#34d399"),
  hex("#fbbf24"),
  hex("#a78bfa"),
  hex("#fb923c"),
  hex("#22d3ee"),
  hex("#f87171"),
  hex("#a3e635"),
}

function theme.labelColor(name)
  local h = 0
  for i = 1, #name do
    h = (h * 31 + name:lower():byte(i)) % 2147483647
  end
  return labelHues[h % #labelHues + 1]
end

function theme.statusColor(id)
  return theme.statusColors[id] or theme.c.accent
end

function theme.use(name)
  theme.name = palettes[name] and name or "dark"
  theme.c = palettes[theme.name]
end

function theme.loadFonts()
  local dir = "assets/fonts/"
  local function f(file, size)
    local font = love.graphics.newFont(dir .. file, size)
    font:setFilter("linear", "linear")
    return font
  end
  theme.fonts = {
    body = f("Inter-Regular.ttf", 13),
    bodyMedium = f("Inter-Medium.ttf", 13),
    small = f("Inter-Medium.ttf", 11),
    smallRegular = f("Inter-Regular.ttf", 11.5),
    heading = f("Inter-SemiBold.ttf", 14),
    title = f("Inter-SemiBold.ttf", 19),
    mono = f("JetBrainsMono-Regular.ttf", 11.5),
    monoBody = f("JetBrainsMono-Regular.ttf", 12.5),
  }
  -- Emoji / symbols not in Inter fall back to LÖVE's default font.
  local fallback = love.graphics.newFont(13)
  for _, font in pairs(theme.fonts) do
    font:setFallbacks(fallback)
  end
end

theme.use("dark")

return theme
