--[[==========================================================================
  FILE        : defiantlooter/ui.lua
  PACKAGE     : Defiant Looter Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.0
  CHANGES     : 1.0.0  First release.

  WHAT  : The ImGui window: status and plugin checks, Start / Pause,
          Preview, the nine tier checkboxes, the three family checkboxes,
          item type checkboxes, options, rule maintenance buttons with
          confirmation popups, and the decision log.

  WHY   : You asked for checkboxes to choose the gear categories, a Pause
          button, a preview before anything is written, and a log that shows
          why each item was taken or skipped.

  WHERE : Registered by init.lua with mq.imgui.init('defiantlooter', ui.render).

  HOW   : The ImGui callback must never wait. Every button only sets a flag
          in engine.requests or config.runtime; the main loop does the work.
          Checkbox changes mark the settings dirty and are saved (debounced)
          by ui.flushSave from the main loop, then shared with the other
          boxes through the settings file.

  WHEN  : Every frame while the window is open.

  READING GUIDE (for future you)
    - Every ImGui Begin has its End, every BeginTable its EndTable, every
      Push its Pop, and every BeginDisabled its EndDisabled, on every path.
    - Text is always drawn with a '%s' format so a percent sign in an item
      name or reason can never be read as a format code.
==========================================================================]]--

local mq     = require('mq')                    -- MacroQuest API (TLO for the status line)
local ImGui  = require('ImGui')                 -- MacroQuest ImGui binding
local config = require('defiantlooter.config')  -- settings and runtime switches
local core   = require('defiantlooter.core')    -- plugin checks, labels
local engine = require('defiantlooter.engine')  -- log, conflicts, requests

local ui = { open = true }                      -- window shown at start

--- Save debounce and status cache -------------------------------------------------
-- WHAT : When settings last changed, and the slow status values.
-- WHY  : Saving on every click would rewrite the shared file many times a
--        second while dragging a number; reading Loot.ini every frame for
--        NewItemDelay is wasteful.
-- WHERE: ui.markDirty, ui.flushSave, refreshStatus.
-- HOW  : Timestamps from mq.gettime().
-- WHEN : Updated as the window is used.
local dirtyAt  = nil      -- ms of the first unsaved change, nil when clean
local SAVE_MS  = 750      -- save this long after the last change
local status   = { at = -100000 }  -- cached plugin and Loot.ini status
local STATUS_MS = 2000    -- refresh status every 2 seconds

--[[--------------------------------------------------------------------------
  ui.markDirty(why)

  WHAT  : Records that settings changed.
  WHY   : The change must be saved, shared, and applied to what is on screen.
  WHERE : Every checkbox and input in this file.
  HOW   : Starts the save timer and asks the engine to re-decide.
  WHEN  : On any settings change.
----------------------------------------------------------------------------]]
function ui.markDirty(why)
    dirtyAt = mq.gettime()          -- (re)start the debounce
    engine.reset(why)               -- apply the new choices to listed items
end

--[[--------------------------------------------------------------------------
  ui.flushSave(force)

  WHAT  : Saves the settings if a change is waiting and the debounce passed.
  WHY   : Saving belongs on the main loop, not in the frame callback.
  WHERE : init.lua main loop, and with force at shutdown.
  HOW   : config.save when due.
  WHEN  : Every main loop pass.
----------------------------------------------------------------------------]]
function ui.flushSave(force)
    if not dirtyAt then return end                                   -- nothing waiting
    if force or mq.gettime() - dirtyAt >= SAVE_MS then
        config.save()                                                -- write and share
        dirtyAt = nil                                                -- clean again
    end
end

--[[--------------------------------------------------------------------------
  refreshStatus()

  WHAT  : Updates the cached plugin and Loot.ini status values.
  WHY   : Shown in the status area so setup problems are obvious.
  WHERE : ui.render.
  HOW   : At most every STATUS_MS: plugin checks, AutoLoot.Active, the
          NewItemDelay value, the Loot.ini path, character and class.
  WHEN  : While the window is drawn.
----------------------------------------------------------------------------]]
local function refreshStatus()
    local now = mq.gettime()                                          -- milliseconds
    if now - status.at < STATUS_MS then return end                    -- still fresh
    status.at = now                                                   -- next refresh later
    status.autoloot = core.pluginLoaded('mq2autoloot')                -- required plugin
    status.linkdb   = core.pluginLoaded('mq2linkdb')                  -- optional plugin
    status.active   = status.autoloot and core.safe(function() return mq.TLO.AutoLoot.Active() end) == true  -- plugin handling loot
    status.delay    = core.newItemDelay()                             -- seconds, or nil
    status.iniPath  = core.lootIniPath()                              -- file we write
    status.name     = core.safe(function() return mq.TLO.Me.CleanName() end) or '?'       -- character
    status.class    = core.safe(function() return mq.TLO.Me.Class.Name() end) or '?'      -- long class name
end

--[[--------------------------------------------------------------------------
  colored(c, text) / line(ok, okText, badText)

  WHAT  : Small text helpers.
  WHY   : Keep the drawing code short and every text call '%s' safe.
  WHERE : ui.render sections.
  HOW   : ImGui.TextColored with a colour table {r, g, b, a}.
  WHEN  : While drawing.
----------------------------------------------------------------------------]]
local function colored(c, text) ImGui.TextColored(c[1], c[2], c[3], c[4], '%s', text) end  -- coloured text
-- green when ok, red otherwise
local function line(ok, okText, badText)
    colored(ok and engine.COLORS.write or engine.COLORS.problem, ok and okText or badText)  -- pick colour and text
end

--[[--------------------------------------------------------------------------
  drawStatus()

  WHAT  : Character, class, Start / Pause, Preview, plugin and setup checks.
  WHY   : What the script is doing, and anything that would stop it working,
          must be visible at a glance.
  WHERE : ui.render.
  HOW   : Start and Pause set config.runtime.running; Preview toggles
          config.runtime.preview; both reset decisions so the change applies
          to what is listed. Set NewItemDelay queues an engine request.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawStatus()
    local rt = config.runtime                                                   -- runtime switches
    ImGui.Text('%s', string.format('Character: %s    Class: %s', status.name, status.class))  -- who is running it
    colored(rt.running and engine.COLORS.write or engine.COLORS.keep, rt.running and 'Status: RUNNING' or 'Status: PAUSED')  -- state
    ImGui.SameLine()
    colored(rt.preview and engine.COLORS.preview or engine.COLORS.write, rt.preview and '  Preview ON: nothing is written' or '  Preview OFF: rules are written')

    ImGui.BeginDisabled(rt.running)                                             -- Start only when paused
    ImGui.PushStyleColor(ImGuiCol.Button, 0.15, 0.50, 0.15, 1.0)                -- green button
    if ImGui.Button('Start##dl_start', 90, 0) then rt.running = true engine.reset('start') end  -- begin scanning
    ImGui.PopStyleColor(1)
    ImGui.EndDisabled()
    ImGui.SameLine()
    ImGui.BeginDisabled(not rt.running)                                         -- Pause only when running
    ImGui.PushStyleColor(ImGuiCol.Button, 0.70, 0.15, 0.15, 1.0)                -- red button
    if ImGui.Button('Pause##dl_pause', 90, 0) then rt.running = false end      -- stop scanning at once
    ImGui.PopStyleColor(1)
    ImGui.EndDisabled()
    ImGui.SameLine()
    local pv, pp = ImGui.Checkbox('Preview only##dl_preview', rt.preview)       -- never write while on
    if pp then rt.preview = pv engine.reset('preview') end                      -- apply at once
    ImGui.SameLine()
    if ImGui.Button('Scan now##dl_scan') then engine.requests.scan = true end   -- one pass, works while paused

    line(status.autoloot, 'MQ2AutoLoot loaded' .. (status.active and ' and handling loot' or ''), 'MQ2AutoLoot is NOT loaded: /plugin mq2autoloot')  -- required plugin
    ImGui.SameLine()
    line(status.linkdb, '   MQ2LinkDB loaded', '   MQ2LinkDB not loaded (unseen items cannot be looked up)')  -- optional plugin
    if status.delay == nil or status.delay < 3 then
        colored(engine.COLORS.problem, string.format('NewItemDelay is %s. The master looter may take a new item before its class rule exists.', tostring(status.delay or 'unknown')))
        ImGui.SameLine()
        if ImGui.Button('Set to 5##dl_delay') then engine.requests.setDelay = 5 status.at = -100000 end  -- /autoloot newitemdelay 5
    else
        line(true, string.format('NewItemDelay is %d seconds', status.delay), '')  -- good setting
    end
    ImGui.TextWrapped('%s', 'Loot.ini: ' .. tostring(status.iniPath))          -- the file rules go into
end

--[[--------------------------------------------------------------------------
  drawChoices()

  WHAT  : Tier, family and item type checkboxes.
  WHY   : The categories you asked for.
  WHERE : ui.render.
  HOW   : Tiers in a 3 column table with Select All and Clear. Every change
          calls ui.markDirty.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawChoices()
    local s = config.settings                                                   -- live settings
    ImGui.SeparatorText('Gear tiers')
    if ImGui.Button('Select All##dl_all') then
        for _, t in ipairs(config.TIERS) do s.tiers[t] = true end               -- tick all nine
        ui.markDirty('select all')
    end
    ImGui.SameLine()
    if ImGui.Button('Clear##dl_clear') then                                     -- untick every tier
        for _, t in ipairs(config.TIERS) do s.tiers[t] = false end              -- untick all nine
        ui.markDirty('clear')
    end
    if ImGui.BeginTable('##dl_tiers', 3) then                                   -- three per row
        for _, t in ipairs(config.TIERS) do
            ImGui.TableNextColumn()                                             -- next cell
            local v, p = ImGui.Checkbox(t .. '##dl_tier_' .. t, s.tiers[t] == true)  -- one tier
            if p then s.tiers[t] = v ui.markDirty('tier ' .. t) end             -- save and apply
        end
        ImGui.EndTable()
    end

    ImGui.SeparatorText('Gear families')                                        -- section title
    for i, fam in ipairs(config.FAMILIES) do                                    -- Defiant, Adept's, Combatant's
        if i > 1 then ImGui.SameLine() end                                      -- one row
        local v, p = ImGui.Checkbox(fam.label .. '##dl_fam_' .. fam.key, s.families[fam.key] == true)  -- one family
        if p then s.families[fam.key] = v ui.markDirty('family ' .. fam.key) end
    end

    ImGui.SeparatorText('Item types')                                           -- section title
    for i, g in ipairs(config.GROUPS) do                                        -- armor, weapons, shields
        if i > 1 then ImGui.SameLine() end                                      -- one row
        local v, p = ImGui.Checkbox(g.label .. '##dl_grp_' .. g.key, s.groups[g.key] == true)  -- one group
        if p then s.groups[g.key] = v ui.markDirty('group ' .. g.key) end
    end
end

--[[--------------------------------------------------------------------------
  checkbox(label, key, tip)

  WHAT  : One option checkbox bound to a settings key, with a tooltip.
  WHY   : The options section has several of these.
  WHERE : drawOptions.
  HOW   : ImGui.Checkbox; tooltip on hover.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function checkbox(label, key, tip)
    local v, p = ImGui.Checkbox(label .. '##dl_opt_' .. key, config.settings[key] == true)  -- the box
    if p then config.settings[key] = v ui.markDirty(key) end                   -- save and apply
    if tip and ImGui.IsItemHovered() then ImGui.SetTooltip('%s', tip) end       -- explanation
end

--[[--------------------------------------------------------------------------
  drawOptions()

  WHAT  : Collection options.
  WHY   : No Trade choice, copies per item, and lookup behaviour.
  WHERE : ui.render.
  HOW   : Checkboxes and one InputInt clamped to 1..999.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawOptions()
    local s = config.settings                                                   -- live settings
    ImGui.SeparatorText('Options')
    checkbox('Include No Trade items', 'includeNoTrade', 'No Trade gear cannot be passed between your characters later. Off = log and skip.')
    ImGui.SetNextItemWidth(110)                                                 -- narrow number box
    local n, changed = ImGui.InputInt('Copies per exact item##dl_copies', s.copiesPerItem, 1, 10)  -- NumberToLoot
    if changed then s.copiesPerItem = math.max(1, math.min(999, math.floor(n))) ui.markDirty('copies') end  -- 1..999
    if ImGui.IsItemHovered() then ImGui.SetTooltip('%s', 'MQ2AutoLoot needs a number. It counts copies of this exact item carried (not banked). It is never a per slot limit. 99 = in practice no limit.') end
    checkbox('Replace MQ2AutoLoot new item defaults', 'replacePluginDefaults', 'Keep or Quest entries MQ2AutoLoot creates for matching gear after this script started are replaced by the class rule.')
    checkbox('Look up unseen items with MQ2LinkDB', 'useLinkDB', 'Opens the item window from the MQ2LinkDB link to read its Class line.')
    ImGui.SameLine()                                                            -- same row as LinkDB
    checkbox('Close it after', 'closeItemWindow', 'Close the item window the script opened.')
    checkbox('Debug trace in chat', 'debug', nil)                               -- trace lines in chat
end

--[[--------------------------------------------------------------------------
  countOf(t)

  WHAT  : Number of keys in a table.
  WHY   : Button labels show how many entries an action affects.
  WHERE : drawMaintenance.
  HOW   : pairs count.
  WHEN  : Every frame (tables are small).
----------------------------------------------------------------------------]]
local function countOf(t)
    local n = 0                                -- running count
    for _ in pairs(t) do n = n + 1 end         -- every key
    return n
end

--[[--------------------------------------------------------------------------
  confirmPopup(id, title, list, describe, onConfirm)

  WHAT  : A modal popup listing what an action will change, with Confirm
          and Cancel.
  WHY   : Convert and Retire change existing Loot.ini entries, so you see the
          exact list first.
  WHERE : drawMaintenance.
  HOW   : BeginPopupModal; EndPopup only when it returned true.
  WHEN  : While the popup is open.
----------------------------------------------------------------------------]]
local function confirmPopup(id, title, list, describe, onConfirm)
    if ImGui.BeginPopupModal(id, nil, ImGuiWindowFlags.AlwaysAutoResize) then  -- only true while open
        ImGui.Text('%s', title)                                                 -- what will happen
        if config.runtime.preview then colored(engine.COLORS.preview, 'Preview is on: the log will show the changes, nothing is written.') end
        if ImGui.BeginChild('##' .. id .. '_list', 560, 200, ImGuiChildFlags.Borders) then  -- scrollable list
            for name, e in pairs(list) do ImGui.Text('%s', name .. ':  ' .. describe(e)) end  -- one line each
        end
        ImGui.EndChild()                                                        -- always paired with BeginChild
        if ImGui.Button('Confirm##' .. id, 110, 0) then onConfirm() ImGui.CloseCurrentPopup() end  -- queue the job
        ImGui.SameLine()
        if ImGui.Button('Cancel##' .. id, 110, 0) then ImGui.CloseCurrentPopup() end  -- do nothing
        ImGui.EndPopup()
    end
end

--[[--------------------------------------------------------------------------
  drawMaintenance()

  WHAT  : Learn, Convert and Retire buttons.
  WHY   : Pre-seed rules from gear you own; change old Keep entries; undo
          rules for tiers you untick.
  WHERE : ui.render.
  HOW   : Learn queues a request at once. Convert and Retire open a
          confirmation popup that queues the request.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawMaintenance()
    ImGui.SeparatorText('Rules')
    if ImGui.Button('Learn from my gear, bags and bank##dl_learn') then engine.requests.learn = true end  -- pre-seed
    if ImGui.IsItemHovered() then ImGui.SetTooltip('%s', 'Reads the Class line of matching gear you own and writes the rules now, so future drops are handled instantly.') end
    local nc = countOf(engine.conflicts)                                        -- existing entries found
    ImGui.SameLine()
    ImGui.BeginDisabled(nc == 0)                                                -- nothing to convert
    if ImGui.Button(string.format('Convert existing entries (%d)##dl_conv', nc)) then ImGui.OpenPopup('Convert entries##dl_conv_pop') end
    ImGui.EndDisabled()
    local retire = engine.retireList()                                          -- rules for unticked tiers
    local nr = countOf(retire)                                                  -- how many
    ImGui.SameLine()
    ImGui.BeginDisabled(nr == 0)                                                -- nothing to retire
    if ImGui.Button(string.format('Retire unticked (%d)##dl_ret', nr)) then ImGui.OpenPopup('Retire rules##dl_ret_pop') end
    ImGui.EndDisabled()
    confirmPopup('Convert entries##dl_conv_pop', 'Replace these Keep or Quest entries with class Gear rules:', engine.conflicts,
        function(c) return c.existing .. '  ->  ' .. c.rule end, function() engine.requests.convert = true end)  -- line text, job
    -- Retire popup: lists rules for unticked tiers and what each will become
    confirmPopup('Retire rules##dl_ret_pop', 'Undo the rules this package wrote for unticked tiers or families:', retire,
        function(e) return e.previous and ('restore "' .. e.previous .. '"') or 'remove the entry' end, function() engine.requests.retire = true end)  -- line text, job
end

--[[--------------------------------------------------------------------------
  drawLog()

  WHAT  : The decision log table and session totals.
  WHY   : Shows why each item was accepted or rejected.
  WHERE : ui.render.
  HOW   : 4 column table, newest first, inside a scrolling table.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawLog()
    local c = engine.counts                                                     -- session totals
    ImGui.SeparatorText(string.format('Decisions   written %d   previewed %d   skipped %d   undecided %d', c.written, c.previewed, c.skipped, c.unresolved))
    if ImGui.Button('Clear log##dl_clearlog') then engine.log = {} end         -- empties the list only
    local flags = ImGuiTableFlags.RowBg + ImGuiTableFlags.Borders + ImGuiTableFlags.ScrollY  -- table style
    if ImGui.BeginTable('##dl_log', 4, flags, 0, 220) then                      -- 220 px high
        ImGui.TableSetupColumn('Time', ImGuiTableColumnFlags.WidthFixed, 60)    -- hh:mm:ss
        ImGui.TableSetupColumn('Item', ImGuiTableColumnFlags.WidthFixed, 230)   -- item name
        ImGui.TableSetupColumn('Result', ImGuiTableColumnFlags.WidthFixed, 110) -- short outcome
        ImGui.TableSetupColumn('Reason', ImGuiTableColumnFlags.WidthStretch)    -- the why
        ImGui.TableHeadersRow()
        for _, e in ipairs(engine.log) do
            ImGui.TableNextRow()                                                -- one decision
            ImGui.TableSetColumnIndex(0) ImGui.Text('%s', e.time)               -- when
            ImGui.TableSetColumnIndex(1) ImGui.Text('%s', e.item)               -- what
            ImGui.TableSetColumnIndex(2) colored(e.color, e.result)             -- outcome, coloured
            ImGui.TableSetColumnIndex(3) ImGui.TextWrapped('%s', e.reason)      -- why
        end
        ImGui.EndTable()
    end
end

--[[--------------------------------------------------------------------------
  ui.render()

  WHAT  : The ImGui callback.
  WHY   : Draws the window each frame.
  WHERE : Registered by init.lua.
  HOW   : Begin, sections, End. End is always called after Begin.
  WHEN  : Every frame while ui.open.
----------------------------------------------------------------------------]]
function ui.render()
    if not ui.open then return end                                              -- hidden
    refreshStatus()                                                             -- cheap unless due
    ImGui.SetNextWindowSize(640, 760, ImGuiCond.FirstUseEver)                   -- first run size
    local open, draw = ImGui.Begin('Defiant Looter ' .. config.VERSION .. '##defiantlooter', ui.open)  -- the window
    ui.open = open                                                              -- X button hides it
    if draw then
        drawStatus()                                                            -- state and setup
        drawChoices()                                                           -- the checkboxes
        drawOptions()                                                           -- collection options
        drawMaintenance()                                                       -- rule buttons
        drawLog()                                                               -- decisions
    end
    ImGui.End()                                                                 -- always paired with Begin
end

return ui

--[[==========================================================================
  END OF FILE : defiantlooter/ui.lua

  DEPENDENCIES : mq, ImGui, defiantlooter.config, .core, .engine.

  HOW TO EDIT SAFELY
    - Never call mq.delay, core.resolveItem or any engine job from here; set
      a request and let the main loop run it.
    - Keep Begin/End, BeginChild/EndChild, BeginTable/EndTable, Push/Pop and
      BeginDisabled/EndDisabled balanced on every path.
    - New settings: add to config.DEFAULTS, draw here, call ui.markDirty.
==========================================================================]]--
