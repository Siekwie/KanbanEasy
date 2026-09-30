-- Small helpers shared across modules. No LÖVE dependencies.

local util = {}

function util.deepcopy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = util.deepcopy(x)
  end
  return setmetatable(out, getmetatable(v))
end

function util.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function util.clamp(x, lo, hi)
  if x < lo then
    return lo
  elseif x > hi then
    return hi
  end
  return x
end

function util.lerp(a, b, t)
  return a + (b - a) * t
end

--- Exponential smoothing that is framerate independent.
function util.damp(a, b, speed, dt)
  return util.lerp(a, b, 1 - math.exp(-speed * dt))
end

function util.slug(s)
  s = s:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return s
end

function util.split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
    out[#out + 1] = part
  end
  return out
end

--- Parse a comma/space separated list of labels into a clean, deduped array.
function util.parseList(s)
  local out, seen = {}, {}
  for item in tostring(s):gmatch("[^,]+") do
    item = util.trim(item):gsub("^#", "")
    if item ~= "" and not seen[item:lower()] then
      seen[item:lower()] = true
      out[#out + 1] = item
    end
  end
  return out
end

function util.contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

function util.indexOf(list, value)
  for i, v in ipairs(list) do
    if v == value then
      return i
    end
  end
  return nil
end

--- Human friendly relative time, e.g. "just now", "5m", "3h", "2d".
function util.ago(t, now)
  now = now or os.time()
  local d = now - (t or now)
  if d < 45 then
    return "just now"
  elseif d < 3600 then
    return math.max(1, math.floor(d / 60 + 0.5)) .. "m ago"
  elseif d < 86400 then
    return math.floor(d / 3600 + 0.5) .. "h ago"
  elseif d < 86400 * 30 then
    return math.floor(d / 86400 + 0.5) .. "d ago"
  end
  return os.date("%b %d, %Y", t)
end

function util.isoTime(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

-- UTF-8 ----------------------------------------------------------------------

--- Byte index of the start of the character after byte position i.
function util.nextChar(s, i)
  if i > #s then
    return #s + 1
  end
  i = i + 1
  while i <= #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    i = i + 1
  end
  return i
end

--- Byte index of the start of the character before byte position i.
function util.prevChar(s, i)
  if i <= 1 then
    return 1
  end
  i = i - 1
  while i > 1 do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    i = i - 1
  end
  return i
end

--- Remove bytes that would make a string invalid UTF-8 (keeps it printable in LÖVE).
function util.sanitizeUtf8(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = b < 0x80 and 1
      or (b >= 0xF0 and b < 0xF8) and 4
      or (b >= 0xE0 and b < 0xF0) and 3
      or (b >= 0xC2 and b < 0xE0) and 2
      or 0
    local ok = len > 0 and i + len - 1 <= n
    if ok then
      for j = i + 1, i + len - 1 do
        local c = s:byte(j)
        if c < 0x80 or c >= 0xC0 then
          ok = false
          break
        end
      end
    end
    if ok then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      i = i + 1
    end
  end
  return table.concat(out)
end

return util
