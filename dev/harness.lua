--[[==========================================================================
  FILE        : defiantlooter/dev/harness.lua
  PACKAGE     : Defiant Looter Lua  (MacroQuest / EverQuest)
  VERSION     : 1.1.0
  CHANGES     : 1.0.0  First version.
                1.0.1  No change in this file.
                1.1.0  AugType on fake items; pickle keeps number keys.

  WHAT  : A fake MacroQuest for offline tests: the TLOs the package reads,
          the mq functions it calls, a working /ini that edits a real INI
          file on disk the way WritePrivateProfileString does, a fake
          /executelink that opens a fake item window, and an ImGui stub that
          checks every Begin has its End.

  WHY   : The decision logic can be exercised on a PC with no game running.
          This proves program logic only; it does NOT prove client
          behaviour. Live checks are in TESTING.md.

  WHERE : Loaded by dev/run_tests.py before init.lua. Never shipped to or
          loaded by MacroQuest.

  HOW   : Sets package.loaded['mq'] and package.preload['ImGui'] so the real
          files load these fakes through their normal require calls. H.world
          is the fake game; scenarios change it, queue presses with H.press,
          and schedule steps with H.at(ms, fn).

  WHEN  : Once per test scenario.
==========================================================================]]--

local H = { cmds = {}, prints = {}, presses = {}, toggles = {}, steps = {}, now = 0, frames = 0, stack = 0, stackErrors = 0 }  -- test state
_G.HARNESS = H                                                                   -- reachable from Python

-- The fake game. Scenarios fill these in.
H.world = {
    name = 'Testcleric', class = 'CLR', className = 'Cleric', server = 'test server',
    plugins = { mq2autoloot = true, mq2linkdb = true },   -- loaded plugins
    plist = {}, slist = {},       -- advanced loot rows: { name=, nodrop=, an=, ag=, nv=, ar= }
    bags = {},                    -- name -> item spec (FindItem and Me.Inventory)
    bank = {},                    -- name -> item spec (FindItemBank)
    linkdb = {},                  -- name -> item spec (MQ2LinkDB knows it)
    display = nil,                -- item spec in the open item window
    displayOpens = true,          -- /executelink opens the window
    closed = 0,                   -- item windows closed by the script
}

--[[------------------------------------------------------------------------
  val(v)

  WHAT  : Returns a callable that returns v, like a MacroQuest TLO member.
  WHY   : Package code calls members as x.Name().
  WHERE : Every fake object below.
  HOW   : Table with __call.
  WHEN  : While building fakes.
--------------------------------------------------------------------------]]
local function val(v) return setmetatable({}, { __call = function() return v end }) end
H.val = val

--[[------------------------------------------------------------------------
  item(spec)

  WHAT  : Builds a fake MacroQuest item object from a spec table, or an
          empty (NULL) item when spec is nil.
  WHY   : FindItem, FindItemBank, DisplayItem and Me.Inventory return items.
  WHERE : TLO fakes below.
  HOW   : spec = { name, classes = {'CLR',...}, nodrop, req, type, aug, slots = {primary=true}, bag = {spec,...} }
  WHEN  : On every fake item read.
--------------------------------------------------------------------------]]
local function item(spec)
    if not spec then
        return setmetatable({}, { __index = function() return function() return nil end end })  -- NULL item: every member nil
    end
    local o = {}                                                         -- the item
    o.Name = val(spec.name)
    o.ID = val(spec.id or 1000)
    o.Classes = val(#(spec.classes or {}))
    o.Class = function(i) return { ShortName = val(spec.classes[i]) } end  -- class datatype
    o.NoDrop = val(spec.nodrop == true)
    o.RequiredLevel = val(spec.req or 0)
    o.Type = val(spec.type or 'Armor')
    o.AugType = val(spec.aug or 0)                                      -- augment type, 0 = not an augment
    o.WornSlot = function(s) return val((spec.slots or {})[s] == true) end
    o.Container = val(spec.bag and #spec.bag or 0)
    o.Item = function(j) return item(spec.bag and spec.bag[j]) end
    o.Window = { DoClose = function() H.world.display = nil H.world.closed = H.world.closed + 1 return true end }
    return o
end
H.item = item

--[[------------------------------------------------------------------------
  advRow(row, i)

  WHAT  : Fake advlootitem.
  WHY   : AdvLoot.PList(i) / SList(i).
  WHERE : AdvLoot fake.
  HOW   : Maps row fields to the members the engine reads.
  WHEN  : Each scan.
--------------------------------------------------------------------------]]
local function advRow(row)
    if not row then return item(nil) end                                   -- past the end
    return { Name = val(row.name), NoDrop = val(row.nodrop == true), AlwaysNeed = val(row.an == true),
             AlwaysGreed = val(row.ag == true), Never = val(row.nv == true), AutoRoll = val(row.ar == true) }
end

-- ---------------- INI file handling (WritePrivateProfileString model) ----------------
--[[------------------------------------------------------------------------
  H.iniWrite(path, section, key, value)

  WHAT  : Edits one key of a real INI file on disk; value nil deletes it.
  WHY   : The package reads Loot.ini from disk, so /ini must really change it.
  WHERE : The fake /ini command.
  HOW   : Line based edit: find [section] (case insensitive), replace or
          append the key, or add the section at the end.
  WHEN  : On every /ini.
--------------------------------------------------------------------------]]
function H.iniWrite(path, section, key, value)
    local lines, fh = {}, io.open(path, 'r')                               -- current file
    if fh then for l in fh:lines() do lines[#lines + 1] = l end fh:close() end
    local sStart, sEnd = nil, nil                                          -- section range
    for i, l in ipairs(lines) do
        local s = l:match('^%[(.-)%]$')
        if s and sStart and not sEnd then sEnd = i - 1 end                 -- next section ends ours
        if s and s:lower() == section:lower() then sStart = i end          -- found ours
    end
    if sStart and not sEnd then sEnd = #lines end
    if not sStart then
        if value == nil then return end                                    -- delete in missing section
        lines[#lines + 1] = '[' .. section .. ']'
        lines[#lines + 1] = key .. '=' .. value
    else
        local done = false
        for i = sStart + 1, sEnd do
            local k = lines[i]:match('^([^=]+)=')
            if k and k:lower() == key:lower() then
                if value == nil then table.remove(lines, i) else lines[i] = key .. '=' .. value end  -- replace or delete
                done = true break
            end
        end
        if not done and value ~= nil then table.insert(lines, sEnd + 1, key .. '=' .. value) end  -- append
    end
    fh = io.open(path, 'w') fh:write(table.concat(lines, '\n') .. '\n') fh:close()  -- save
end

--[[------------------------------------------------------------------------
  quoted(line)

  WHAT  : Splits a command line into words, honouring double quotes, and
          remembers which words were quoted.
  WHY   : MacroQuest /ini deletes only for a bare NULL. A quoted "NULL" is
          written as the text NULL (MQCommands.cpp IniOutput comment), so the
          fake must tell the two apart to catch that mistake.
  WHERE : H.exec.
  HOW   : Walks the line: a "..." run is one quoted word, any other run of
          non spaces is one bare word. Returns words and a quoted flag list.
  WHEN  : On every command.
--------------------------------------------------------------------------]]
local function quoted(line)
    local out, isq, i = {}, {}, 1                                  -- words, quoted flags, cursor
    while i <= #line do                                            -- scan the whole line
        local c = line:sub(i, i)                                   -- current character
        if c == '"' then                                           -- quoted word
            local j = line:find('"', i + 1, true) or (#line + 1)   -- closing quote
            out[#out + 1], isq[#out + 1] = line:sub(i + 1, j - 1), true  -- text inside
            i = j + 1                                              -- past the quote
        elseif c:match('%s') then                                  -- spacing
            i = i + 1                                              -- skip it
        else                                                       -- bare word
            local j = line:find('%s', i) or (#line + 1)            -- end of word
            out[#out + 1], isq[#out + 1] = line:sub(i, j - 1), false  -- the word
            i = j                                                  -- continue there
        end
    end
    return out, isq
end

--[[------------------------------------------------------------------------
  H.exec(cmd)

  WHAT  : Runs one command the package sent.
  WHY   : /ini, /executelink, /autoloot are the only commands it sends.
  WHERE : mq.cmdf fake.
  HOW   : Records it, then acts like MacroQuest for the ones that matter.
  WHEN  : Every command.
--------------------------------------------------------------------------]]
function H.exec(cmd)
    H.cmds[#H.cmds + 1] = cmd                                               -- record everything
    if cmd:match('^/ini ') then
        local a, q = quoted(cmd)                                             -- /ini, file, section, key, value
        local del = (a[5] or ''):upper() == 'NULL' and not q[5]               -- only a bare NULL deletes
        H.iniWrite(a[2], a[3], a[4], (not del) and a[5] or nil)              -- quoted "NULL" is literal text
    elseif cmd:match('^/executelink ') then
        local link = cmd:sub(14)                                             -- link text
        local spec = H.world.linkdb[link:match('^LINK:(.*)$') or '']         -- fake link format
        if spec and H.world.displayOpens then H.world.display = spec end     -- window opens
    elseif cmd:match('^/autoloot newitemdelay ') then
        H.iniWrite(H.lootIni, 'Settings', 'NewItemDelay', cmd:match('(%d+)$'))  -- as the plugin does
    end
end

-- ---------------- TLO ----------------
local TLO = {}
TLO.EverQuest = { Server = val(H.world.server), GameState = val('INGAME') }
TLO.MacroQuest = { GameState = function() return H.world.gameState or 'INGAME' end }
TLO.Me = {
    CleanName = function() return H.world.name end,
    Class = { ShortName = function() return H.world.class end, Name = function() return H.world.className end },
    Inventory = function(slot)                                               -- worn 0..22, packs 23..34
        local list = {} for _, spec in pairs(H.world.bags) do list[#list + 1] = spec end
        table.sort(list, function(a, b) return a.name < b.name end)
        return item(list[slot + 1])                                          -- deterministic slot fill
    end,
    Bank = function(slot) return item(nil) end,
}
TLO.Plugin = function(name) return { IsLoaded = val(H.world.plugins[name:lower()] == true) } end
TLO.AutoLoot = { Active = val(true) }
TLO.AdvLoot = {
    PCount = function() return #H.world.plist end, SCount = function() return #H.world.slist end,
    PList = function(i) return advRow(H.world.plist[i]) end, SList = function(i) return advRow(H.world.slist[i]) end,
}
TLO.FindItem = function(q) return item(H.world.bags[q:sub(2)]) end           -- '=name'
TLO.FindItemBank = function(q) return item(H.world.bank[q:sub(2)]) end
TLO.DisplayItem = function(name)
    local d = H.world.display
    if d and d.name == name then return item(d) end
    return item(nil)
end
TLO.LinkDB = function(q)
    local name = q:sub(2)
    return val(H.world.linkdb[name] and ('LINK:' .. name) or '')
end

-- ---------------- mq ----------------
local mq = { TLO = TLO, configDir = nil }
--[[------------------------------------------------------------------------
  mq.delay(ms, cond)

  WHAT  : Advances fake time, draws frames and runs scheduled steps.
  WHY   : The package yields with mq.delay; tests drive time from there.
  WHERE : Package main loop and core.fromLinkDB.
  HOW   : 100 ms steps until ms passed or cond() is true.
  WHEN  : Every package delay.
--------------------------------------------------------------------------]]
function mq.delay(ms, cond)
    local target = H.now + (tonumber(ms) or 0)
    repeat
        H.now = H.now + 100
        for i = #H.steps, 1, -1 do                                           -- due steps
            local s = H.steps[i]
            if s.at <= H.now then table.remove(H.steps, i) s.fn() end
        end
        if H.render and not H.inRender then
            H.inRender = true H.frames = H.frames + 1 H.render() H.inRender = false  -- one frame
            if H.stack ~= 0 then H.stackErrors = H.stackErrors + 1 H.stack = 0 end
        end
        if cond and cond() then return end
    until H.now >= target
end
function mq.gettime() return H.now end
function mq.cmdf(fmt, ...) H.exec(string.format(fmt, ...)) end
function mq.cmd(c) H.exec(c) end
function mq.bind(name, fn) H.binds = H.binds or {} H.binds[name] = fn end
function mq.unbind(name) end
mq.imgui = { init = function(name, fn) H.render = fn end }
--[[------------------------------------------------------------------------
  mq.pickle(path, t)

  WHAT  : Writes a table as a Lua file that returns it.
  WHY   : Same contract as MacroQuest's mq.pickle.
  WHERE : config.lua.
  HOW   : Recursive serializer with sorted keys.
  WHEN  : Every save.
--------------------------------------------------------------------------]]
function mq.pickle(path, t)
    local function ser(v, ind)
        if type(v) == 'table' then
            local keys = {} for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local parts = {}
            for _, k in ipairs(keys) do                                          -- numbers stay numbers, as in MacroQuest's pickle
                local ks = type(k) == 'number' and tostring(k) or string.format('%q', k)  -- [1] not ["1"]
                parts[#parts + 1] = ind .. '  [' .. ks .. '] = ' .. ser(v[k], ind .. '  ')
            end
            return '{\n' .. table.concat(parts, ',\n') .. '\n' .. ind .. '}'
        elseif type(v) == 'string' then return string.format('%q', v) end
        return tostring(v)
    end
    local fh = io.open(path, 'w') fh:write('return ' .. ser(t, '') .. '\n') fh:close()
end
package.loaded['mq'] = mq
H.mq = mq

-- print capture
local realPrint = print
_G.print = function(s) H.prints[#H.prints + 1] = tostring(s) end

-- ---------------- ImGui stub ----------------
local ImGui = {}
local function pressed(label) if H.presses[label] then H.presses[label] = nil return true end return false end
function ImGui.Begin(name, open) H.stack = H.stack + 1 return true, true end
function ImGui.End() H.stack = H.stack - 1 end
function ImGui.BeginChild() H.stack = H.stack + 1 return true end
function ImGui.EndChild() H.stack = H.stack - 1 end
function ImGui.BeginTable() H.stack = H.stack + 1 return true end
function ImGui.EndTable() H.stack = H.stack - 1 end
function ImGui.BeginDisabled(d) H.stack = H.stack + 1 H.disabled = (H.disabled or 0) + (d and 1 or 0) H.dstack = H.dstack or {} table.insert(H.dstack, d and 1 or 0) end
function ImGui.EndDisabled() H.stack = H.stack - 1 H.disabled = H.disabled - table.remove(H.dstack) end
function ImGui.PushStyleColor() H.stack = H.stack + 1 end
function ImGui.PopStyleColor(n) H.stack = H.stack - (n or 1) end
function ImGui.Button(label) if (H.disabled or 0) > 0 then return false end return pressed(label) end
function ImGui.Checkbox(label, v)
    if H.toggles[label] then H.toggles[label] = nil return not v, true end
    return v, false
end
function ImGui.InputInt(label, v)
    if H.inputs and H.inputs[label] then local n = H.inputs[label] H.inputs[label] = nil return n, true end
    return v, false
end
H.popups = {}
function ImGui.OpenPopup(id) H.popups[id] = true end
function ImGui.BeginPopupModal(id) if H.popups[id] then H.stack = H.stack + 1 return true end return false end
function ImGui.EndPopup() H.stack = H.stack - 1 end
function ImGui.CloseCurrentPopup() for k in pairs(H.popups) do H.popups[k] = nil end end
local noop = function() end
for _, n in ipairs({ 'Text', 'TextColored', 'TextWrapped', 'SameLine', 'SeparatorText', 'Separator', 'TableNextColumn', 'TableNextRow',
    'TableSetColumnIndex', 'TableSetupColumn', 'TableHeadersRow', 'SetNextWindowSize', 'SetNextItemWidth', 'SetTooltip' }) do ImGui[n] = noop end
function ImGui.IsItemHovered() return false end
package.preload['ImGui'] = function() return ImGui end
_G.ImGuiCol = { Button = 21 }
_G.ImGuiCond = { FirstUseEver = 4 }
_G.ImGuiWindowFlags = { AlwaysAutoResize = 64 }
_G.ImGuiChildFlags = { Borders = 1 }
_G.ImGuiTableFlags = { RowBg = 64, Borders = 1920, ScrollY = 33554432 }
_G.ImGuiTableColumnFlags = { WidthFixed = 16, WidthStretch = 8 }

-- ---------------- scenario helpers ----------------
function H.at(ms, fn) H.steps[#H.steps + 1] = { at = ms, fn = fn } end
function H.press(label) H.presses[label] = true end
function H.toggle(label) H.toggles[label] = true end
function H.slash(line) local a = {} for w in line:gmatch('%S+') do a[#a + 1] = w end local up = table.unpack or unpack H.binds['/dloot'](up(a)) end  -- all words, not just the first
function H.realPrint(...) realPrint(...) end
return H

--[[==========================================================================
  END OF FILE : defiantlooter/dev/harness.lua

  HOW TO EDIT SAFELY
    - When the package reads a new TLO member, add it here or the scenario
      will see nil (which the package treats as unknown, by design).
    - H.iniWrite models WritePrivateProfileString closely enough for these
      tests; it is not a full INI implementation.
==========================================================================]]--
