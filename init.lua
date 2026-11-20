--[[==========================================================================
  FILE        : defiantlooter/init.lua
  PACKAGE     : Defiant Looter Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.1
  CHANGES     : 1.0.0  First release.
                1.0.1  No change in this file.

  WHAT  : Entry point. Loads settings, takes the Loot.ini snapshot,
          registers the window and the /dloot command, and runs the main
          loop.

  WHY   : MacroQuest runs /lua run defiantlooter by loading this file.
          Keeping it to start up, commands and the loop means every real
          behaviour lives in a module with one job.

  WHERE : <MacroQuest>/lua/defiantlooter/init.lua

  HOW   : The main loop calls config.sync (follow other boxes' checkbox
          changes), engine.tick (button jobs and the scan), ui.flushSave,
          then mq.delay to yield. Jobs run on this coroutine, so waiting
          inside them is safe while the ImGui callback stays non blocking.

  WHEN  : From /lua run defiantlooter until /dloot quit, /lua stop
          defiantlooter, or leaving the game world.

  READING GUIDE (for future you)
    - MacroQuest looks for init.lua when you run a folder by name, so this
      file name must not change.
    - The script ALWAYS starts Paused with Preview on. Nothing is written to
      Loot.ini until you untick Preview, and nothing is scanned automatically
      until you press Start.
==========================================================================]]--

local mq     = require('mq')                    -- MacroQuest API
local config = require('defiantlooter.config')  -- settings
local core   = require('defiantlooter.core')    -- chat helpers, plugin checks
local engine = require('defiantlooter.engine')  -- decisions and jobs
local ui     = require('defiantlooter.ui')      -- the window

--- Run flag ------------------------------------------------------------------------
-- WHAT : The main loop runs while this is true.
-- WHY  : /dloot quit needs a clean way out that saves settings.
-- WHERE: main loop and onCommand.
-- HOW  : Plain boolean.
-- WHEN : Set false only on quit.
local running = true

--[[--------------------------------------------------------------------------
  printHelp()

  WHAT  : Lists the slash commands in chat.
  WHY   : Discoverability without opening the README.
  WHERE : /dloot help and any unknown argument.
  HOW   : core.echo lines.
  WHEN  : On request.
----------------------------------------------------------------------------]]
local function printHelp()
    core.echo('/dloot              toggle the window')
    core.echo('/dloot start        start scanning the Advanced Loot window')  -- Start button
    core.echo('/dloot pause        pause scanning')                           -- Pause button
    core.echo('/dloot preview on|off   on = never write Loot.ini')            -- Preview checkbox
    core.echo('/dloot scan         decide what is listed right now, once')    -- Scan now button
    core.echo('/dloot learn        learn and write rules from gear you own')  -- Learn button
    core.echo('/dloot tier <Name> on|off   e.g. /dloot tier Elegant on')       -- tier checkbox
    core.echo('/dloot status       print the current state')                  -- one line summary
    core.echo('/dloot quit         save and end the script')                  -- clean exit
end

--[[--------------------------------------------------------------------------
  printStatus()

  WHAT  : One chat summary of the current state.
  WHY   : Check a box without opening its window (or through /dex).
  WHERE : /dloot status.
  HOW   : Ticked tiers and families, run state, preview, plugins.
  WHEN  : On request.
----------------------------------------------------------------------------]]
local function printStatus()
    local s, rt = config.settings, config.runtime                               -- shorthand
    local tiers, fams = {}, {}                                                  -- ticked names
    for _, t in ipairs(config.TIERS) do if s.tiers[t] then tiers[#tiers + 1] = t end end  -- ticked tiers
    for _, f in ipairs(config.FAMILIES) do if s.families[f.key] then fams[#fams + 1] = f.label end end  -- ticked families
    core.echo('%s, Preview %s. Tiers: %s. Families: %s.', rt.running and 'Running' or 'Paused', rt.preview and 'ON' or 'OFF',
        #tiers > 0 and table.concat(tiers, ', ') or 'none', #fams > 0 and table.concat(fams, ', ') or 'none')
    core.echo('MQ2AutoLoot %s, MQ2LinkDB %s. Loot.ini: %s', core.pluginLoaded('mq2autoloot') and 'loaded' or 'NOT loaded',
        core.pluginLoaded('mq2linkdb') and 'loaded' or 'not loaded', core.lootIniPath())  -- plugins and file
end

--[[--------------------------------------------------------------------------
  onCommand(...)

  WHAT  : Handler for /dloot.
  WHY   : Lets you, a hotkey, or another box (/dex, /bcaa) drive the script.
  WHERE : Bound with mq.bind in startup.
  HOW   : First argument picks the action. Never waits; jobs are requests.
  WHEN  : Whenever /dloot is typed or broadcast.
----------------------------------------------------------------------------]]
local function onCommand(...)
    local args = { ... }                                -- words after /dloot
    local sub = (args[1] or ''):lower()                 -- first word, any case
    local rt = config.runtime                           -- runtime switches
    if sub == '' then
        ui.open = not ui.open                           -- bare /dloot toggles the window
    elseif sub == 'start' then
        rt.running = true engine.reset('start') core.echo('Started.')        -- same as Start
    elseif sub == 'pause' then
        rt.running = false core.echo('Paused.')                              -- same as Pause
    elseif sub == 'preview' then
        rt.preview = (args[2] or 'on'):lower() ~= 'off'                      -- anything but off is on
        engine.reset('preview') core.echo('Preview %s.', rt.preview and 'ON' or 'OFF')
    elseif sub == 'scan' then
        engine.requests.scan = true                                          -- same as Scan now
    elseif sub == 'learn' then
        engine.requests.learn = true                                         -- same as Learn
    elseif sub == 'tier' then
        local want = (args[2] or ''):lower()                                 -- tier name, any case
        for _, t in ipairs(config.TIERS) do
            if t:lower() == want then
                config.settings.tiers[t] = (args[3] or 'on'):lower() ~= 'off'  -- set the checkbox
                config.save() engine.reset('tier ' .. t)                     -- share and apply
                core.echo('Tier %s %s.', t, config.settings.tiers[t] and 'ticked' or 'unticked')
                return
            end
        end
        core.warn('Unknown tier "%s".', args[2] or '')                       -- no match
    elseif sub == 'status' then
        printStatus()                                                        -- chat summary
    elseif sub == 'quit' then
        running = false                                                      -- loop ends next pass
    else
        printHelp()                                                          -- help or unknown
    end
end

--[[--------------------------------------------------------------------------
  startup()

  WHAT  : One time initialisation.
  WHY   : Settings and the snapshot must exist before the first scan.
  WHERE : Called once below.
  HOW   : config.load, engine.start, plugin warnings, bind, register window.
  WHEN  : Script start.
----------------------------------------------------------------------------]]
local function startup()
    config.load()                                                            -- must be first
    engine.start()                                                           -- Loot.ini snapshot
    if not core.pluginLoaded('mq2autoloot') then
        core.warn('MQ2AutoLoot is not loaded. Rules will be written but nothing will loot them. /plugin mq2autoloot')
    end
    if not core.pluginLoaded('mq2linkdb') then                               -- optional plugin missing
        core.warn('MQ2LinkDB is not loaded. Items nobody owns cannot be looked up. /plugin mq2linkdb, then /linkdb /import')
    end
    mq.bind('/dloot', onCommand)                                             -- slash command
    mq.imgui.init('defiantlooter', ui.render)                                -- window callback
    core.good('Defiant Looter %s loaded: PAUSED, Preview ON. Type /dloot help.', config.VERSION)
end

startup()  -- one time setup before the loop

--[[==========================================================================
  MAIN LOOP

  WHAT  : Follows shared settings, runs jobs and the scan, saves, yields.
  WHY   : Jobs and item lookups must run here, not in the ImGui callback.
  WHERE : Here only.
  HOW   : config.sync, engine.tick, ui.flushSave, mq.delay(100). Ends if the
          character leaves the game world.
  WHEN  : Continuously until quit.
==========================================================================]]--
while running do
    if config.sync() then engine.reset('settings changed on another box') end  -- shared checkboxes
    engine.tick()                                                            -- jobs and scan
    ui.flushSave(false)                                                      -- debounced save
    if mq.TLO.MacroQuest.GameState() ~= 'INGAME' then
        core.warn('Left the game world, ending.')                            -- camp or char select
        break
    end
    mq.delay(100)                                                            -- yield 100 ms
end

-- Shutdown: save pending changes and release the command.
ui.flushSave(true)                 -- write anything still waiting
mq.unbind('/dloot')                -- free the command name
core.echo('Ended.')                -- last line

--[[==========================================================================
  END OF FILE : defiantlooter/init.lua

  STARTUP
    /lua run defiantlooter

  COMMANDS
    /dloot, start, pause, preview on|off, scan, learn, tier <Name> on|off,
    status, quit, help

  DEPENDENCIES : mq, every defiantlooter module. Plugins: MQ2AutoLoot,
                 MQ2LinkDB (optional).

  HOW TO EDIT SAFELY
    - A new command belongs in onCommand and printHelp together, and in the
      Commands table in README.md.
    - Keep the 100 ms delay short so button jobs start promptly.
    - /lua stop defiantlooter ends at once without the shutdown lines;
      /dloot quit is the clean way out.
==========================================================================]]--
