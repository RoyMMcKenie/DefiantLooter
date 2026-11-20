--[[==========================================================================
  FILE        : defiantlooter/config.lua
  PACKAGE     : Defiant Looter Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.0
  CHANGES     : 1.0.0  First release.

  WHAT  : Default settings, the shared team settings file (load, save and
          cross box sync), and the small persistent stores the engine keeps:
          the item class cache and the rule ledger.

  WHY   : The tier, family and item type checkboxes decide which Loot.ini
          rules get written. MQ2AutoLoot reads one Loot.ini that is normally
          shared by every box, so a rule written by any box applies to all of
          them. If each box kept its own checkbox choices, whichever box
          happened to see an item first would decide for the whole team.
          Keeping ONE settings file per server, and having every running box
          notice when it changes, means the team always follows the same
          choices. Class filtering is still per character: MQ2AutoLoot only
          lets the classes listed in a Gear rule take the item.

  WHERE : Required by core.lua, engine.lua, ui.lua and init.lua. Files live in
          the MacroQuest config folder:
            defiantlooter_<server>.lua          team settings
            defiantlooter_<server>_ledger.lua   rules this package wrote
            defiantlooter_itemcache.lua         item class lists learned

  HOW   : DEFAULTS is the full schema. config.load reads the saved file with
          loadfile and fills in any key it lacks from DEFAULTS, so adding a
          setting later never breaks an old file. config.save writes with
          mq.pickle and remembers the exact text written. config.sync rereads
          the file every few seconds; if the text differs from what this box
          last wrote or read, another box changed it and the settings reload.
          The ledger and item cache use load, merge, save so two boxes writing
          at nearly the same moment do not erase each other's entries.

  WHEN  : config.load once at startup. config.save whenever the window
          changes a value (debounced by ui.lua) and at shutdown. config.sync
          from the main loop. Store functions whenever the engine learns an
          item or writes a rule.

  READING GUIDE (for future you)
    - The settings file is a plain Lua file that returns a table. You can
      edit it while no box is running the script. Delete it to reset.
    - mq.configDir is the "config" folder inside your MacroQuest install.
    - Nothing in this file talks to the game except mq.TLO.EverQuest.Server
      for the file name.
==========================================================================]]--

local mq = require('mq')   -- MacroQuest API: configDir, pickle, TLO

local config = {}          -- module table returned at the bottom

--- Version -----------------------------------------------------------------------
-- WHAT : Package version shown in the window title and chat.
-- WHY  : One place to change it; the doc audit checks every file matches.
-- WHERE: ui.lua title, init.lua startup line.
-- HOW  : Plain string.
-- WHEN : Read at any time.
config.VERSION = '1.0.0'

--[[==========================================================================
  TIERS and FAMILIES

  WHAT  : The nine gear tiers and three name families, in display order.
  WHY   : The window draws one checkbox per entry, and core.matchName uses
          the same lists, so there is exactly one definition of each.
  WHERE : ui.lua (checkboxes), core.lua (name matching).
  HOW   : TIERS is a list of the first word of the item name. FAMILIES maps a
          settings key to its label and the second word forms it may take.
          Adept's and Combatant's are listed with and without the apostrophe,
          and core.normalize turns curly apostrophes into straight ones.
  WHEN  : Read at any time; never changed at run time.
==========================================================================]]--
config.TIERS = {
    'Crude', 'Simple', 'Rough', 'Ornate', 'Flawed',      -- lower Defiant tiers
    'Intricate', 'Elaborate', 'Elegant', 'Transcendent', -- upper tiers
}

-- Family key -> label shown in the window and the lower case second words
-- that identify it in an item name.
config.FAMILIES = {
    { key = 'Defiant',    label = 'Defiant',      words = { 'defiant' } },                     -- e.g. Simple Defiant Leather Bracer
    { key = 'Adepts',     label = "Adept's",      words = { "adept's", 'adepts' } },           -- e.g. Transcendent Adept's Cloak
    { key = 'Combatants', label = "Combatant's",  words = { "combatant's", 'combatants' } },   -- e.g. Transcendent Combatant's Pauldrons
}

-- Item type groups. core.itemGroup puts every resolved item in one of these.
config.GROUPS = {
    { key = 'armor',   label = 'Armor and jewelry' },   -- worn slots that are not weapons or shields
    { key = 'weapons', label = 'Weapons' },             -- primary, secondary or range weapons
    { key = 'shields', label = 'Shields' },             -- item Type is Shield
}

--[[==========================================================================
  DEFAULTS

  WHAT  : Every setting the package understands, with its starting value.
  WHY   : One readable list of everything configurable.
  WHERE : config.load merges these into the saved file.
  HOW   : Plain nested Lua table. Comments explain each key.
  WHEN  : Read once at load time.
==========================================================================]]--
config.DEFAULTS = {
    -- Tier checkboxes. All start unticked so nothing is written until you
    -- choose. Keyed by the tier word exactly as in config.TIERS.
    tiers = {
        Crude = false, Simple = false, Rough = false, Ornate = false, Flawed = false,  -- lower tiers
        Intricate = false, Elaborate = false, Elegant = false, Transcendent = false,   -- upper tiers
    },

    -- Family checkboxes. All three start ticked.
    families = { Defiant = true, Adepts = true, Combatants = true },

    -- Item type checkboxes. All start ticked.
    groups = { armor = true, weapons = true, shields = true },

    -- No Trade (NO DROP) items. Off means they are logged and skipped. Your
    -- characters cannot pass these between each other later, so the choice is
    -- left to you.
    includeNoTrade = false,

    -- NumberToLoot written into every Gear rule. MQ2AutoLoot REQUIRES a number
    -- and stops a character once it carries that many of the exact item (it
    -- uses MacroQuest FindItemCount, which does not include the bank). 99 is
    -- far more than any one character carries, so in practice there is no
    -- limit. This is a per exact item number, never a per slot limit.
    copiesPerItem = 99,

    -- When MQ2AutoLoot sees a brand new item it writes Keep (or Quest|N for
    -- No Trade) into Loot.ini on its own. When this is on, an entry like that
    -- which appeared AFTER this script started, for gear that matches your
    -- checkboxes, is replaced with a class Gear rule. Entries that already
    -- existed when the script started are never touched automatically; they
    -- show as "Existing rule kept" and the Convert button can change them.
    replacePluginDefaults = true,

    -- Ask MQ2LinkDB for the item link and open it to read the Class list when
    -- the item is not in the cache, your bags, your bank, or an open item
    -- window. Needs MQ2LinkDB loaded and its database imported.
    useLinkDB = true,

    -- Close the item window the script opened after reading it.
    closeItemWindow = true,

    -- Milliseconds between Advanced Loot scans while items are listed.
    scanIntervalMs = 500,

    -- Lines kept in the window's decision log.
    logSize = 200,

    -- Show the debug trace in chat.
    debug = false,
}

--- Runtime only state (never saved) ----------------------------------------------
-- WHAT : Start or Pause state and Preview mode.
-- WHY  : The script must always open paused and in preview, so these are not
--        saved: a crash or restart can never leave a box writing rules
--        without you pressing Start.
-- WHERE: engine.lua reads them; ui.lua and /dloot change them.
-- HOW  : Plain booleans in config.runtime.
-- WHEN : Reset every time the script starts.
config.runtime = {
    running = false,   -- false = paused. Start sets true, Pause sets false.
    preview = true,    -- true = log what would happen, never write Loot.ini
}

--- Live settings ---------------------------------------------------------------
-- WHAT : The table every module reads and the window writes.
-- WHY  : One shared table means a change is seen on the next engine pass.
-- WHERE: Everywhere, as config.settings.
-- HOW  : Filled by config.load.
-- WHEN : Valid after config.load returns.
config.settings = nil

--- File bookkeeping ----------------------------------------------------------------
-- WHAT : Paths and the last text seen in the settings file.
-- WHY  : config.sync compares the file to this text to detect another box's
--        change without needing a file time stamp (Lua has no stat call).
-- WHERE: config.load, config.save, config.sync.
-- HOW  : Strings.
-- WHEN : Set by config.load.
config.paths = {}          -- settings, ledger, cache file paths
config.lastText = nil      -- exact text of the settings file last read or written
config.lastSyncMs = 0      -- mq.gettime() of the last sync check
config.SYNC_MS = 3000      -- check the settings file every 3 seconds

--[[--------------------------------------------------------------------------
  serverSafe()

  WHAT  : Returns the server name with spaces and odd characters replaced.
  WHY   : The name goes into a file name.
  WHERE : config.load.
  HOW   : mq.TLO.EverQuest.Server, lower cased, anything not a letter or
          digit becomes an underscore. Falls back to 'unknown'.
  WHEN  : Once at load.
----------------------------------------------------------------------------]]
local function serverSafe()
    local ok, server = pcall(function() return mq.TLO.EverQuest.Server() end)  -- may be nil at char select
    server = (ok and server) or 'unknown'                                     -- never nil
    return (tostring(server):lower():gsub('[^%w]', '_'))                      -- safe for a file name
end

--[[--------------------------------------------------------------------------
  readText(path)

  WHAT  : Returns the whole text of a file, or nil when it does not exist.
  WHY   : Used to detect settings changes and to read Loot.ini read only.
  WHERE : config.sync, config.load, core.lua (Loot.ini snapshot).
  HOW   : io.open in read mode; the file is always closed.
  WHEN  : Whenever a file needs reading.
----------------------------------------------------------------------------]]
function config.readText(path)
    local fh = io.open(path, 'r')   -- nil when missing
    if not fh then return nil end   -- caller treats nil as "no file"
    local text = fh:read('*a')      -- whole file
    fh:close()                      -- always release the handle
    return text
end

--[[--------------------------------------------------------------------------
  loadTable(path)

  WHAT  : Loads a pickled Lua table file, or returns nil.
  WHY   : Settings, ledger and cache are all pickled tables.
  WHERE : config.load, config.sync, store helpers below.
  HOW   : loadfile then pcall the chunk; anything but a table is ignored so
          a damaged file falls back to defaults instead of stopping the script.
  WHEN  : On load, sync and every store merge.
----------------------------------------------------------------------------]]
local function loadTable(path)
    local chunk = loadfile(path)                -- nil when missing or unreadable
    if not chunk then return nil end            -- no file yet
    local ok, data = pcall(chunk)               -- run the file to get its table
    if ok and type(data) == 'table' then return data end  -- good file
    return nil                                  -- damaged file: caller uses defaults
end

--[[--------------------------------------------------------------------------
  fillDefaults(dst, src)

  WHAT  : Copies every key in src that dst lacks, recursing into tables.
  WHY   : A settings file saved by an older version gains new keys silently.
  WHERE : config.load and config.sync.
  HOW   : Deep copy of missing keys only; existing values are kept.
  WHEN  : After every settings read.
----------------------------------------------------------------------------]]
local function fillDefaults(dst, src)
    for k, v in pairs(src) do                       -- every default key
        if type(v) == 'table' then
            if type(dst[k]) ~= 'table' then dst[k] = {} end  -- missing or wrong type
            fillDefaults(dst[k], v)                 -- recurse into nested tables
        elseif dst[k] == nil then
            dst[k] = v                              -- missing scalar gets default
        end
    end
    return dst
end

--[[--------------------------------------------------------------------------
  config.load()

  WHAT  : Builds the file paths and loads the team settings.
  WHY   : Everything else reads config.settings.
  WHERE : init.lua startup.
  HOW   : Paths from mq.configDir and the server; loadTable then fillDefaults.
  WHEN  : Once at startup.
----------------------------------------------------------------------------]]
function config.load()
    local base = mq.configDir .. '/defiantlooter_'                  -- common prefix
    local server = serverSafe()                                     -- per server files
    config.paths.settings = base .. server .. '.lua'                -- team settings
    config.paths.ledger   = base .. server .. '_ledger.lua'         -- rules we wrote
    config.paths.cache    = base .. 'itemcache.lua'                 -- item facts are the same on every server

    config.settings = fillDefaults(loadTable(config.paths.settings) or {}, config.DEFAULTS)  -- saved values plus new defaults
    config.lastText = config.readText(config.paths.settings)        -- remember for sync
end

--[[--------------------------------------------------------------------------
  config.save()

  WHAT  : Writes the team settings file.
  WHY   : Choices must survive restarts and reach the other boxes.
  WHERE : ui.lua (debounced), init.lua shutdown, /dloot commands.
  HOW   : mq.pickle, then rereads the text so this box's own write is not
          mistaken for another box's change by config.sync.
  WHEN  : After any settings change.
----------------------------------------------------------------------------]]
function config.save()
    mq.pickle(config.paths.settings, config.settings)               -- write the table as Lua
    config.lastText = config.readText(config.paths.settings)        -- our own write is not a change
end

--[[--------------------------------------------------------------------------
  config.sync()

  WHAT  : Reloads the settings when another box changed the file.
  WHY   : Keeps every box following the same checkboxes.
  WHERE : init.lua main loop.
  HOW   : At most every SYNC_MS, reads the file text. If it differs from
          lastText, loads it and returns true so the engine can re-evaluate.
  WHEN  : Every main loop pass (cheap when not due).
----------------------------------------------------------------------------]]
function config.sync()
    local now = mq.gettime()                                        -- milliseconds
    if now - config.lastSyncMs < config.SYNC_MS then return false end  -- not due yet
    config.lastSyncMs = now                                         -- next check later
    local text = config.readText(config.paths.settings)             -- current file text
    if not text or text == config.lastText then return false end    -- unchanged
    local data = loadTable(config.paths.settings)                   -- parse the new file
    if not data then return false end                               -- half written: try next time
    config.settings = fillDefaults(data, config.DEFAULTS)           -- adopt the other box's choices
    config.lastText = text                                          -- remember it
    return true                                                     -- tell the caller
end

--[[==========================================================================
  STORES: item cache and rule ledger

  WHAT  : Two small persistent tables shared by all boxes.
            cache  : item name -> { classes = {'WAR', ...}, nodrop, group,
                     reqLevel, source, learned }
            ledger : item name -> { tier, family, value, previous, at, by }
  WHY   : The cache stops the script opening the same item window again and
          lets one box's lookup help every other box. The ledger records every
          Loot.ini entry this package wrote, and what was there before, so the
          Retire button can undo exactly those entries and nothing else.
  WHERE : core.lua (cache), engine.lua (ledger).
  HOW   : storeGet reads the file each time (it is small). storePut loads,
          merges one key, and saves, so concurrent boxes do not erase each
          other's keys.
  WHEN  : Whenever an item is learned or a rule is written or retired.
==========================================================================]]--

--[[--------------------------------------------------------------------------
  config.storeAll(which)

  WHAT  : Returns the whole cache or ledger table (empty when no file).
  WHY   : The window lists ledger entries; the engine looks items up.
  WHERE : core.lua, engine.lua, ui.lua.
  HOW   : loadTable on the right path.
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function config.storeAll(which)
    return loadTable(config.paths[which]) or {}   -- which is 'cache' or 'ledger'
end

--[[--------------------------------------------------------------------------
  config.storePut(which, key, value)

  WHAT  : Sets (or with value nil, removes) one key in the cache or ledger.
  WHY   : Merge on write keeps other boxes' entries.
  WHERE : core.lua, engine.lua.
  HOW   : Load fresh, change one key, mq.pickle.
  WHEN  : Whenever one entry changes.
----------------------------------------------------------------------------]]
function config.storePut(which, key, value)
    local data = config.storeAll(which)        -- freshest copy from disk
    data[key] = value                          -- nil removes the key
    mq.pickle(config.paths[which], data)       -- write back
end

return config

--[[==========================================================================
  END OF FILE : defiantlooter/config.lua

  DEPENDENCIES : mq (configDir, pickle, gettime, TLO.EverQuest.Server).

  HOW TO EDIT SAFELY
    - A new setting goes in DEFAULTS with a comment. fillDefaults adds it to
      old files automatically.
    - Do not save config.runtime. The script must always open paused and in
      preview mode.
    - A new tier or family goes in TIERS or FAMILIES; the window and the name
      matcher both read these lists, so no other file needs a list change.
==========================================================================]]--
