std = "luajit+love"
max_line_length = 140
exclude_files = { ".luarocks", "lua_modules", ".build-cache", "dist", ".install" }
files["spec/"] = { std = "+busted" }
self = false
