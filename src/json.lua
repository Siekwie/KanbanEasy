-- Minimal JSON encode/decode.
-- Encoder sorts object keys so the save file diffs cleanly in git.
-- Empty tables encode as [] unless marked with json.object().

local json = {}

local objectMarker = {}

--- Mark a table so it always encodes as a JSON object, even when empty.
function json.object(t)
  return setmetatable(t or {}, objectMarker)
end

local escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escapeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function isArray(t)
  if getmetatable(t) == objectMarker then
    return false
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return true, n
end

local encodeValue

local function encodeTable(t, indent, depth, seen)
  if seen[t] then
    error("json: circular reference")
  end
  seen[t] = true
  local nl, pad, padIn, sep = "", "", "", ":"
  if indent then
    nl = "\n"
    pad = string.rep(indent, depth)
    padIn = string.rep(indent, depth + 1)
    sep = ": "
  end
  local out
  local arr, n = isArray(t)
  if arr then
    if n == 0 then
      seen[t] = nil
      return "[]"
    end
    local parts = {}
    for i = 1, n do
      parts[i] = padIn .. encodeValue(t[i], indent, depth + 1, seen)
    end
    out = "[" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "]"
  else
    local keys = {}
    for k in pairs(t) do
      if type(k) ~= "string" and type(k) ~= "number" then
        error("json: invalid key type " .. type(k))
      end
      keys[#keys + 1] = k
    end
    if #keys == 0 then
      seen[t] = nil
      return "{}"
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for i, k in ipairs(keys) do
      parts[i] = padIn .. escapeString(tostring(k)) .. sep .. encodeValue(t[k], indent, depth + 1, seen)
    end
    out = "{" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "}"
  end
  seen[t] = nil
  return out
end

encodeValue = function(v, indent, depth, seen)
  local tv = type(v)
  if tv == "nil" then
    return "null"
  elseif tv == "boolean" then
    return tostring(v)
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("json: cannot encode " .. tostring(v))
    end
    if math.floor(v) == v and math.abs(v) < 1e15 then
      return string.format("%d", v)
    end
    return string.format("%.14g", v)
  elseif tv == "string" then
    return escapeString(v)
  elseif tv == "table" then
    return encodeTable(v, indent, depth, seen)
  end
  error("json: cannot encode type " .. tv)
end

--- Encode a value. Pass pretty=true for indented output.
function json.encode(v, pretty)
  return encodeValue(v, pretty and "  " or nil, 0, {})
end

-- Decoder -------------------------------------------------------------------

local function decodeError(str, pos, msg)
  local line = 1
  for _ in str:sub(1, pos):gmatch("\n") do
    line = line + 1
  end
  error(string.format("json: %s at line %d (char %d)", msg, line, pos), 0)
end

local function skipWs(str, pos)
  return str:find("[^ \t\r\n]", pos) or #str + 1
end

local function codepointToUtf8(n)
  if n < 0x80 then
    return string.char(n)
  elseif n < 0x800 then
    return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
  elseif n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
  return string.char(
    0xF0 + math.floor(n / 0x40000),
    0x80 + math.floor(n / 0x1000) % 0x40,
    0x80 + math.floor(n / 0x40) % 0x40,
    0x80 + n % 0x40
  )
end

local decodeValue

local function decodeString(str, pos)
  -- pos points at the opening quote
  local parts = {}
  local i = pos + 1
  while true do
    local s, e = str:find('["\\]', i)
    if not s then
      decodeError(str, pos, "unterminated string")
    end
    parts[#parts + 1] = str:sub(i, s - 1)
    if str:sub(s, s) == '"' then
      return table.concat(parts), e + 1
    end
    local c = str:sub(s + 1, s + 1)
    local simple = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
    if simple[c] then
      parts[#parts + 1] = simple[c]
      i = s + 2
    elseif c == "u" then
      local hex = str:sub(s + 2, s + 5)
      if not hex:match("^%x%x%x%x$") then
        decodeError(str, s, "invalid unicode escape")
      end
      local n = tonumber(hex, 16)
      i = s + 6
      if n >= 0xD800 and n <= 0xDBFF then
        local lo = str:match("^\\u(%x%x%x%x)", i)
        if lo then
          local m = tonumber(lo, 16)
          if m >= 0xDC00 and m <= 0xDFFF then
            n = 0x10000 + (n - 0xD800) * 0x400 + (m - 0xDC00)
            i = i + 6
          end
        end
      end
      parts[#parts + 1] = codepointToUtf8(n)
    else
      decodeError(str, s, "invalid escape")
    end
  end
end

decodeValue = function(str, pos)
  pos = skipWs(str, pos)
  local c = str:sub(pos, pos)
  if c == "{" then
    local obj = {}
    pos = skipWs(str, pos + 1)
    if str:sub(pos, pos) == "}" then
      return json.object(obj), pos + 1
    end
    while true do
      pos = skipWs(str, pos)
      if str:sub(pos, pos) ~= '"' then
        decodeError(str, pos, "expected string key")
      end
      local key
      key, pos = decodeString(str, pos)
      pos = skipWs(str, pos)
      if str:sub(pos, pos) ~= ":" then
        decodeError(str, pos, "expected ':'")
      end
      obj[key], pos = decodeValue(str, pos + 1)
      pos = skipWs(str, pos)
      local d = str:sub(pos, pos)
      if d == "}" then
        return obj, pos + 1
      elseif d ~= "," then
        decodeError(str, pos, "expected ',' or '}'")
      end
      pos = pos + 1
    end
  elseif c == "[" then
    local arr = {}
    pos = skipWs(str, pos + 1)
    if str:sub(pos, pos) == "]" then
      return arr, pos + 1
    end
    while true do
      arr[#arr + 1], pos = decodeValue(str, pos)
      pos = skipWs(str, pos)
      local d = str:sub(pos, pos)
      if d == "]" then
        return arr, pos + 1
      elseif d ~= "," then
        decodeError(str, pos, "expected ',' or ']'")
      end
      pos = pos + 1
    end
  elseif c == '"' then
    return decodeString(str, pos)
  elseif str:find("^true", pos) then
    return true, pos + 4
  elseif str:find("^false", pos) then
    return false, pos + 5
  elseif str:find("^null", pos) then
    return nil, pos + 4
  else
    local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if num and #num > 0 and tonumber(num) then
      return tonumber(num), pos + #num
    end
    decodeError(str, pos, "unexpected character '" .. c .. "'")
  end
end

--- Decode a JSON string. Raises an error string on malformed input.
function json.decode(str)
  if type(str) ~= "string" then
    error("json: expected string, got " .. type(str), 0)
  end
  local value, pos = decodeValue(str, 1)
  pos = skipWs(str, pos)
  if pos <= #str then
    decodeError(str, pos, "trailing garbage")
  end
  return value
end

return json
