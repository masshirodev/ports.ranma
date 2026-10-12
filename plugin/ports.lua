-- ports: which panes are serving something on a local port.
--
-- Every pane's screen is watched for the address a dev server prints as it
-- starts: `http://localhost:5173/` (Vite), `127.0.0.1:3000` (cargo, axum),
-- `0.0.0.0:8000` and `[::]:8000` (python -m http.server, docker), and
-- `listening on port 3000` (express). A pane serving one gets a badge on its
-- border, `▸ :5173`, taken off when its command finishes or the pane closes.
-- With ports.verify on, `ss -ltn` says whether each port is listening on this
-- machine (not which process holds it): one that is not (a server
-- recompiling, or one that died where no shell said so) drops its badge until
-- it listens again, and is forgotten once a shell is back in the foreground.
--
-- leader O (shift+o), `ports` in the palette, or a click on the bar module
-- opens a screen of every serving pane. On it:
--   enter  focus the pane      b  open the URL in the browser (ports.opener;
--   y      copy the URL           over ssh it is copied instead)
--   d      forget it           r  look again: every screen, and ss
--   o      options
-- Another key: ranma.bind("x", function() ranma.emit("ports_open") end).
-- The bar module `ports` says how many are serving, nothing when none:
-- `ranma.bar { right = { "ports", "clock" } }`.
--
-- Where the shell marks its commands (OSC 133, ranma's CONFIG.md, "Hooks"), a
-- command finishing clears its pane, and a server restarted while its old
-- address is still on screen is seen again. Without the marks, press r for
-- that. A shell, editor or pager in the foreground (ports.ignore) is never
-- taken for a server, so an address `cat` or `grep` printed is not one, and
-- neither is one inside a connection string (`postgres://u@localhost:5432`).
-- Options (settings panel, "ports" group): ports.verify, ports.recheck,
-- ports.opener, ports.badges, ports.ignore.
--
-- ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md ("Pane
-- handles": watch and badge, "Timers and processes", "The bar").

ranma.option("ports.verify", {
  type = "bool", default = true,
  name = "Check it listens",
  desc = "Ask ss whether each port is listening; one that is not loses its badge until it does.",
})
ranma.option("ports.recheck", {
  type = "int", min = 0, max = 120, default = 10, slider = false,
  name = "Look again every",
  desc = "Seconds between two looks with ss while a pane serves something; 0 looks only when a server is found.",
})
ranma.option("ports.opener", {
  type = "string", default = "xdg-open",
  name = "Opener", desc = "The command a URL is opened with (b on the screen); the URL is its last word.",
})
ranma.option("ports.badges", {
  type = "bool", default = true,
  name = "Badges", desc = "Mark a serving pane's border with its ports: ▸ :5173.",
})
ranma.option("ports.ignore", {
  type = "string",
  default = "zsh bash fish sh dash ksh tcsh nu elvish xonsh vim nvim vi nano hx emacs less more most man bat",
  name = "Not servers",
  desc = "Programs whose screen is never taken for a server: an address they show was printed by something else.",
})

local OWNER = "ports"

-- What servers print as they start. Rust regex, as pane:watch takes it.
local PATTERN = [=[(?:https?://)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):\d{2,5}(?:/[^\s"'<>)\]]*)?|(?i:listening on port) \d{2,5}]=]

-- A port not listening yet this soon after it was printed is a server still
-- starting, not one that is gone.
local GRACE = 5

local store = ranma.store("ports")

-- pane id -> { [port] = { port, url, row, since, listening = nil|true|false } }
local served = {}
-- pane id -> true while a marked command runs, false once one finished; nil
-- for a shell that marks nothing (or not since the last reload).
local running = {}
local watching = {}
local screen = nil
local timer = nil
local job = nil
-- Why ss could not answer, once it could not: verification is off from then.
local broken = nil

-- A process's start time (field 22 of /proc/PID/stat), or nil when it is gone.
local function started(pid)
  local f = io.open("/proc/" .. pid .. "/stat")
  if not f then return nil end
  local stat = f:read("l")
  f:close()
  -- The fields after the command (field 2, which may hold spaces).
  local rest = stat and stat:match("%)%s(.*)$")
  if not rest then return nil end
  local fields = {}
  for w in rest:gmatch("%S+") do fields[#fields + 1] = w end
  return fields[20]
end

-- This server, by pid and start time: pane ids are per server, so what one
-- server saved is never read by another (two at once, or one after a reboot).
local function server_key()
  local f = io.open("/proc/self/stat")
  local pid = f and f:read("n")
  if f then f:close() end
  local t = pid and started(pid)
  return t and ("served:" .. pid .. ":" .. t) or nil
end
local SERVER = server_key()

-- The port and the URL to open, from what the watch matched; nil if it is no
-- port.
local function parse(text)
  local scheme = text:match("^(https?)://")
  local rest = scheme and text:sub(#scheme + 4) or text
  local host, port, path = rest:match("^(%[[^%]]*%]):(%d+)(.*)$")
  if not host then host, port, path = rest:match("^([%w%.]+):(%d+)(.*)$") end
  if not host then host, port, path = "localhost", text:match("(%d+)%s*$"), "" end
  port = tonumber(port)
  if not port or port < 1 or port > 65535 then return nil end
  -- Every address is reached from here as localhost.
  if host == "0.0.0.0" or host == "[::]" then host = "localhost" end
  path = (path or ""):gsub("[.,;:]+$", "")
  if path == "" then path = "/" end
  return port, (scheme or "http") .. "://" .. host .. ":" .. port .. path
end

local function save()
  local out = {}
  for id, ports in pairs(served) do
    local list = {}
    for _, e in pairs(ports) do list[#list + 1] = { port = e.port, url = e.url, row = e.row, since = e.since } end
    if #list > 0 then out[tostring(id)] = list end
  end
  if SERVER then store:set(SERVER, next(out) and out or nil) end
end

-- A pane's ports, in order.
local function ports_of(id)
  local list = {}
  for _, e in pairs(served[id] or {}) do list[#list + 1] = e end
  table.sort(list, function(a, b) return a.port < b.port end)
  return list
end

-- Serving: listening, or not asked (no ss, or not yet).
local function live(e)
  return e.listening ~= false
end

local function count()
  local n = 0
  for id in pairs(served) do
    for _, e in ipairs(ports_of(id)) do
      if live(e) then n = n + 1 end
    end
  end
  return n
end

local function badge(id)
  local p = ranma.pane(id)
  if not p then return end
  local shown, checked = {}, true
  for _, e in ipairs(ports_of(id)) do
    if live(e) then
      shown[#shown + 1] = ":" .. e.port
      if e.listening == nil then checked = false end
    end
  end
  if #shown == 0 or not ranma.get("ports.badges") then return p:badge(OWNER) end
  local word = #shown <= 2 and table.concat(shown, " ") or (shown[1] .. " +" .. (#shown - 1))
  p:badge(OWNER, "▸", word:sub(1, 12), checked and "accent" or "normal")
end

local HOME = os.getenv("HOME")

local function home(path)
  if HOME and path:sub(1, #HOME) == HOME then return "~" .. path:sub(#HOME + 1) end
  return path
end

local function where(p)
  if not p then return "" end
  return (p.workspace == 0 and "S" or tostring(p.workspace)) .. "  " .. p.title
end

local function close_screen()
  if screen then screen:close() end
  screen = nil
end

local function find(row_id)
  local id, port = (row_id or ""):match("^(%d+):(%d+)$")
  id, port = tonumber(id), tonumber(port)
  return id and served[id] and served[id][port], id
end

local function open_url(url)
  if ranma.client().remote then
    ranma.copy(url)
    return ranma.notify("over ssh: copied " .. url .. " instead of opening it here")
  end
  local cmd = {}
  for w in ranma.get("ports.opener"):gmatch("%S+") do cmd[#cmd + 1] = w end
  if #cmd == 0 then return ranma.notify("ports.opener is empty") end
  cmd[#cmd + 1] = url
  ranma.spawn(cmd, { timeout = 10, on_exit = function(r)
    if r.error or r.code ~= 0 then
      ranma.toast("ports: " .. cmd[1] .. ": " .. (r.error or r.stderr or "failed"), { urgent = true })
    end
  end })
  ranma.notify("opening " .. url)
end

local refresh_screen, keep_timer

local function forget(id, port)
  if not served[id] then return end
  if port then served[id][port] = nil else served[id] = nil end
  if served[id] and next(served[id]) == nil then served[id] = nil end
  badge(id)
  save()
  refresh_screen()
  keep_timer()
end

local function row(id, e)
  local p = ranma.pane(id)
  local value
  if e.listening == true then value = { "listening", "accent" }
  elseif e.listening == false then value = { "not listening", "dim" }
  else value = { broken and "unchecked" or (ranma.get("ports.verify") and "checking" or "unchecked"), "dim" } end
  return {
    "row", id = id .. ":" .. e.port, name = e.url, note = where(p), value = value,
    keys = {
      { "enter", "focus", function()
        local q = ranma.pane(id)
        if q then q:focus(); close_screen() end
      end },
      { "b", "browser", function() open_url(e.url) end },
      { "y", "copy", function() ranma.copy(e.url); ranma.notify("copied " .. e.url) end },
      { "d", "forget", function() forget(id, e.port) end },
    },
    detail = {
      { "log", lines = { e.row or "" }, at = 1 },
      { "facts", { "pane", tostring(id) }, { "", p and (p:program() or "") or "gone" },
        { "", p and home(p:cwd() or "") or "" } },
    },
  }
end

local function body()
  local up, down = {}, {}
  local ids = {}
  for id in pairs(served) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    for _, e in ipairs(ports_of(id)) do
      local list = live(e) and up or down
      list[#list + 1] = row(id, e)
    end
  end
  local out = {}
  if #up > 0 then
    out[#out + 1] = { "heading", "Serving", count = #up }
    table.move(up, 1, #up, #out + 1, out)
  end
  if #down > 0 then
    out[#out + 1] = { "heading", "Not listening", tag = "ss", count = #down }
    table.move(down, 1, #down, #out + 1, out)
  end
  return out
end

local function status()
  if broken then return { "not checked: " .. broken, "urgent" } end
  if not ranma.get("ports.verify") then return { "not checked", "dim" } end
  return { "checked with ss", "dim" }
end

local function counted()
  local n = count()
  return n == 1 and "1 serving" or (n .. " serving")
end

refresh_screen = function()
  if not screen then return end
  screen:set { body = body(), count = counted(), status = status() }
end

local function any()
  return next(served) ~= nil
end

-- A shell in the foreground is serving nothing: the address was printed by
-- something that has ended (`cat`, `grep`), or is an old one coming back into
-- view after a reload. An editor or a pager is showing a file.
local function ignored(prog)
  local name = prog:match("[^/]*$"):gsub("^%-", "")
  for w in ranma.get("ports.ignore"):gmatch("%S+") do
    if w == name then return true end
  end
  return false
end

local verify

-- The recheck timer runs only while something is served: none, no wakeups.
keep_timer = function()
  local every = ranma.get("ports.recheck")
  if any() and every > 0 and ranma.get("ports.verify") and not broken then
    if not timer then timer = ranma.every(every * 1000, function() verify() end) end
  elseif timer then
    ranma.cancel(timer)
    timer = nil
  end
end

verify = function()
  keep_timer()
  if job or broken or not ranma.get("ports.verify") or not any() then return end
  job = ranma.spawn({ "ss", "-Hltn" }, { timeout = 5, on_exit = function(r)
    job = nil
    if r.error or r.code ~= 0 then
      broken = r.error or (r.stderr ~= "" and r.stderr:match("[^\n]*")) or ("ss exited " .. tostring(r.code))
      for id, ports in pairs(served) do
        for _, e in pairs(ports) do e.listening = nil end
        badge(id)
      end
      keep_timer()
      return refresh_screen()
    end
    local open = {}
    for line in (r.stdout or ""):gmatch("[^\n]+") do
      -- State, Recv-Q, Send-Q, then the local address: 127.0.0.1:5173, [::]:8000, *:22.
      local fields = {}
      for w in line:gmatch("%S+") do fields[#fields + 1] = w end
      local port = fields[4] and tonumber(fields[4]:match(":(%d+)$"))
      if port then open[port] = true end
    end
    local now = os.time()
    local dropped = false
    for id, ports in pairs(served) do
      local changed = false
      -- Back at a shell and not listening: the server ended where the shell
      -- marks no commands. Gone, so the timer can stop.
      local p = ranma.pane(id)
      local prog = p and p:program()
      local ended = prog ~= nil and ignored(prog)
      for port, e in pairs(ports) do
        local was = e.listening
        if open[e.port] then
          e.listening = true
        elseif now - e.since >= GRACE then
          e.listening = false
        end
        if e.listening == false and ended then
          ports[port] = nil
          changed, dropped = true, true
        elseif e.listening ~= was then
          changed = true
        end
      end
      if next(ports) == nil then served[id] = nil end
      if changed then badge(id) end
    end
    if dropped then save(); keep_timer() end
    refresh_screen()
  end })
end

-- Whether the match is a part of something else: a word (`mylocalhost:80`),
-- a login (`u@localhost:5432`), or a URL of another scheme (`redis://`); an
-- http(s) scheme is inside the match itself.
local function embedded(row, text)
  local at = row and row:find(text, 1, true)
  if not at or at == 1 then return false end
  local before = row:sub(1, at - 1)
  return before:match("[%w@_%-]$") ~= nil or before:match("://$") ~= nil
end

local function found(e)
  local id = e.pane
  local p = ranma.pane(id)
  local prog = p and p:program()
  -- The foreground program says best whether a command runs; the shell's
  -- marks only where it is not known (a shell may send the end mark alone).
  if prog then
    if ignored(prog) then return end
  elseif running[id] == false then
    return
  end
  if embedded(e.row, e.text) then return end
  local port, url = parse(e.text)
  if not port then return end
  served[id] = served[id] or {}
  local old = served[id][port]
  served[id][port] = { port = port, url = url, row = e.row, since = os.time(),
    listening = old and old.listening or nil }
  badge(id)
  save()
  refresh_screen()
  -- A moment for the server to bind, if it printed first.
  ranma.defer(300, verify)
end

local function watch(p)
  if watching[p.id] then return end
  local ok, w = pcall(p.watch, p, PATTERN, found)
  if ok then watching[p.id] = w else ranma.notify("ports: " .. tostring(w)) end
end

-- A watch fires for a row it has not seen at its last look, so a server
-- restarted while its old address is still on screen prints a row it has
-- seen, and is missed. A new watch has seen nothing and looks at once.
local function rearm(id)
  if watching[id] then ranma.unwatch(watching[id]) end
  watching[id] = nil
  local p = ranma.pane(id)
  if p then watch(p) end
end

ranma.on("pane_open", function(e)
  local p = ranma.pane(e.pane)
  if p then watch(p) end
end)

ranma.on("pane_close", function(e)
  watching[e.pane], running[e.pane] = nil, nil
  if served[e.pane] then
    served[e.pane] = nil
    save()
    refresh_screen()
    keep_timer()
  end
end)

-- A moment in, the command is the foreground program, and a look at the
-- screen takes what it printed for its own.
local REARM = 500

ranma.on("command_started", function(e)
  local id = e.pane
  running[id] = true
  if served[id] then return end
  ranma.defer(REARM, function()
    if running[id] and not served[id] then rearm(id) end
  end)
end)

-- The server was the command: it ended, and its address with it.
ranma.on("command_finished", function(e)
  running[e.pane] = false
  if served[e.pane] then
    served[e.pane] = nil
    badge(e.pane)
    save()
    refresh_screen()
    keep_timer()
  end
end)

-- Lua starts over on a reload (badges and watches with it), and the settings
-- panel saving is one: what was served comes back from the store, for the
-- panes that are still here.
ranma.defer(0, function()
  -- What servers that are gone saved is forgotten.
  for _, key in ipairs(store:keys()) do
    local pid, t = key:match("^served:(%d+):(%d+)$")
    if key ~= SERVER and (not pid or started(pid) ~= t) then store:set(key, nil) end
  end
  local saved = SERVER and store:get(SERVER)
  if saved then
    for k, list in pairs(saved) do
      local id = tonumber(k)
      if id and ranma.pane(id) then
        served[id] = {}
        for _, e in ipairs(list) do
          served[id][e.port] = { port = e.port, url = e.url, row = e.row, since = e.since }
        end
        badge(id)
      end
    end
  end
  for _, p in ipairs(ranma.panes()) do watch(p) end
  save()
  verify()
end)

local function open()
  screen = ranma.screen {
    title = "ports", filter = "names", detail = 3, options = true,
    status = status(),
    count = counted(),
    empty = "no pane is serving anything",
    body = body(),
    keys = {
      { "r", "look again", function()
        for _, p in ipairs(ranma.panes()) do
          if not served[p.id] then rearm(p.id) end
        end
        verify()
      end },
    },
    card = {
      { "enter", "focus its pane" },
      { "b", "open the URL (ports.opener)" },
      { "y", "copy the URL" },
      { "d", "forget it" },
      { "r", "look at every screen again, and ask ss" },
      { "o", "the ports plugin's options" },
    },
    on_close = function() screen = nil end,
  }
  verify()
end

-- `ports` in ranma.bar: how many are serving, nothing when none.
ranma.module("ports", {
  interval = 1,
  render = function()
    local n = count()
    if n == 0 then return nil end
    return { text = "▸ " .. n .. ((ranma.client().cols or 80) < 80 and "" or (n == 1 and " port" or " ports")),
             style = "accent" }
  end,
  on_click = open,
})

-- An edit in the settings panel takes effect as it is made; saving reloads.
ranma.on("option_change", function(e)
  if not tostring(e.key):match("^ports%.") then return end
  if e.key == "ports.verify" then broken = nil end
  -- A new interval needs a new timer; verify starts one if it is wanted.
  if timer then ranma.cancel(timer); timer = nil end
  for id in pairs(served) do badge(id) end
  verify()
  refresh_screen()
end)

ranma.command("ports", open, { desc = "the panes serving something on a port" })
-- For a bind of the user's own: ranma.bind("x", function() ranma.emit("ports_open") end).
ranma.on("user:ports_open", function() open() end)
-- WM mode ends as the screen opens: it has the keyboard from there.
ranma.bind("shift+o", open, { desc = "ports", group = "plugins", exit = true })
