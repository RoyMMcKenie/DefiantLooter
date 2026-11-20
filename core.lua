--[[==========================================================================
  FILE        : defiantlooter/core.lua
  PACKAGE     : Defiant Looter Lua  (MacroQuest / EverQuest)
  VERSION     : 1.1.0
  CHANGES     : 1.0.0  First release.
                1.0.1  Chat colour codes fixed (single backslash).
                1.1.0  Augments found by AugType; class free augments get all classes; items with no Class line cached too.

  WHAT  : The building blocks the engine uses:
            1. Chat output helpers.
            2. Item name matching (tier word + family word).
            3. Reading an item's Class list, No Trade flag, required level
               and type group from any MacroQuest item object.
            4. Resolving an item NAME to those facts: cache, bags, bank, an
               open item window, then MQ2LinkDB.
            5. MQ2AutoLoot's Loot.ini: finding it, reading entries read only,
               writing entries with the MacroQuest /ini command, and building
               the Gear rule text.
            6. Plugin presence checks.

  WHY   : The Advanced Loot list only tells MacroQuest an item's name, ID,
          stack size, No Trade flag and loot states. It does NOT give the
          Class line from the item window. The Class line is what decides who
          should get the item, so this file finds it by other documented
          routes and writes it into the Gear rule MQ2AutoLoot already
          understands:  Name=Gear|Classes|WAR|PAL|...|NumberToLoot|99|
          MQ2AutoLoot then lets only those classes take the item.

  WHERE : Required by engine.lua, ui.lua and init.lua.

  HOW   : Every game read is wrapped in pcall so a missing TLO or a NULL
          returns nil instead of stopping the script. Loot.ini is READ with
          plain Lua file reads (never modified by Lua io) and WRITTEN only
          through /ini, which uses the same Windows profile call MQ2AutoLoot
          uses, so one key is changed and every other line is left alone.

  WHEN  : Called by the engine on the main loop. resolveItem may wait up to
          two seconds for an item window, so it must never be called from
          the ImGui callback.

  READING GUIDE (for future you)
    - Interfaces used, and where each one is documented, are listed in
      AUDIT.md. Nothing here is a guessed command.
    - MQ2AutoLoot puts each item in a section named by the FIRST CHARACTER
      of the item name, e.g. [S] for Simple Defiant Leather Bracer. That is
      copied exactly from its source (ParseLootEntry).
==========================================================================]]--

local mq     = require('mq')                    -- MacroQuest API
local config = require('defiantlooter.config')  -- settings, stores, paths

local core = {}                                 -- module table

--[[==========================================================================
  1. CHAT OUTPUT
==========================================================================]]--

local PREFIX = '\at[DefiantLooter]\ax '          -- teal tag on every line

--[[--------------------------------------------------------------------------
  core.echo(fmt, ...) / core.good / core.warn / core.debug

  WHAT  : Print formatted lines to the MacroQuest chat window.
  WHY   : One consistent prefix and colour scheme.
  WHERE : Every module.
  HOW   : string.format then print. MacroQuest colour codes: \ag green,
          \ay yellow, \ax reset. debug prints only when settings.debug.
          In Lua source they are written with ONE backslash ('\ag'), which
          Lua turns into the bell character MacroQuest reads as a colour
          code. A doubled backslash ('\\ag') prints the letters as text
          (seen live in 1.0.0), as ClericFood's working utils.lua shows.
  WHEN  : Any time.
----------------------------------------------------------------------------]]
function core.echo(fmt, ...) print(PREFIX .. string.format(fmt, ...)) end                -- plain line
function core.good(fmt, ...) print(PREFIX .. '\ag' .. string.format(fmt, ...) .. '\ax') end  -- green line
function core.warn(fmt, ...) print(PREFIX .. '\ay' .. string.format(fmt, ...) .. '\ax') end  -- yellow line
-- debug lines appear only when the Debug checkbox is ticked
function core.debug(fmt, ...)
    if config.settings and config.settings.debug then print(PREFIX .. '\a-w' .. string.format(fmt, ...) .. '\ax') end  -- grey line
end

--[[--------------------------------------------------------------------------
  safe(fn)

  WHAT  : Runs fn in pcall and returns its value, or nil on any error.
  WHY   : TLO chains can fail when a window or plugin is missing.
  WHERE : Every game read in this file.
  HOW   : pcall wrapper.
  WHEN  : On every TLO read.
----------------------------------------------------------------------------]]
local function safe(fn)
    local ok, v = pcall(fn)     -- never let a NULL stop the script
    if ok then return v end     -- good read
    return nil                  -- failed read counts as unknown
end
core.safe = safe                -- engine.lua and ui.lua use it too

--[[==========================================================================
  2. NAME MATCHING
==========================================================================]]--

--[[--------------------------------------------------------------------------
  core.normalize(name)

  WHAT  : Lower cases a name and turns curly or back tick apostrophes into
          a straight apostrophe.
  WHY   : Item names can carry the typographic apostrophe; matching must not
          depend on which one the client uses.
  WHERE : core.matchName.
  HOW   : gsub on the UTF-8 bytes of U+2019 and on the back tick.
  WHEN  : Every name match.
----------------------------------------------------------------------------]]
function core.normalize(name)
    local s = tostring(name or ''):lower()     -- case insensitive
    s = s:gsub('\226\128\153', "'")            -- U+2019 right single quote
    s = s:gsub('`', "'")                       -- back tick
    return s
end

--[[--------------------------------------------------------------------------
  core.matchName(name)

  WHAT  : Decides whether an item name is one of ours, and which tier and
          family it belongs to.
  WHY   : Name is the only thing the Advanced Loot list gives for free, so it
          is the cheap first filter before any class lookup.
  WHERE : engine.lua for every listed item; engine learnFromBags.
  HOW   : The first word must be a tier from config.TIERS and the second word
          one of a family's words. Returns tier, familyKey on a match.
          Returns nil, nil, 'near' when the first word is a tier but the
          second word is not a known family, so the log can show items that
          might need a new family added.
  WHEN  : Once per item per loot window.
----------------------------------------------------------------------------]]
function core.matchName(name)
    local words = {}                                           -- the words of the name
    for w in core.normalize(name):gmatch('%S+') do words[#words + 1] = w end  -- split on spaces
    if #words < 2 then return nil end                          -- too short to be gear
    local tier = nil                                           -- tier word as configured
    for _, t in ipairs(config.TIERS) do
        if words[1] == t:lower() then tier = t break end       -- first word is a tier
    end
    if not tier then return nil end                            -- not tiered gear
    for _, fam in ipairs(config.FAMILIES) do
        for _, w in ipairs(fam.words) do
            if words[2] == w then return tier, fam.key end     -- tier + family = ours
        end
    end
    return nil, nil, 'near'                                    -- tier word but unknown family
end

--[[--------------------------------------------------------------------------
  core.familyLabel(key)

  WHAT  : Returns the display label for a family key (Adepts -> Adept's).
  WHY   : Log lines and the window show the label, settings store the key.
  WHERE : engine.lua, ui.lua.
  HOW   : Linear search of config.FAMILIES.
  WHEN  : When a line is shown.
----------------------------------------------------------------------------]]
function core.familyLabel(key)
    for _, fam in ipairs(config.FAMILIES) do
        if fam.key == key then return fam.label end   -- found
    end
    return tostring(key)                              -- unknown key shown as is
end

--[[==========================================================================
  3. READING ITEM FACTS
==========================================================================]]--

--[[--------------------------------------------------------------------------
  core.itemGroup(item)

  WHAT  : Puts an item in 'augments', 'shields', 'weapons' or 'armor'.
  WHY   : The Item types checkboxes.
  WHERE : core.readItem.
  HOW   : AugType above 0 -> augments (MacroQuest MQ2ItemType.cpp returns
          the item's augment type, 0 for anything that is not an augment).
          Type 'Shield' -> shields. Otherwise, if the item can go in the
          primary, secondary or range slot and its Type is not Armor or
          Jewelry, it is a weapon. Everything else (armor, jewelry, cloaks,
          belts and other worn items) is armor.
  WHEN  : Once per item read.
----------------------------------------------------------------------------]]
function core.itemGroup(item)
    local aug = tonumber(safe(function() return item.AugType() end)) or 0       -- 0 = not an augment
    if aug > 0 then return 'augments' end                                       -- any augmentation, any name
    local itype = safe(function() return item.Type() end) or ''                 -- e.g. Armor, Shield, 1H Slashing
    if itype == 'Shield' then return 'shields' end                              -- shields first
    if itype == 'Armor' or itype == 'Jewelry' then return 'armor' end           -- worn armor and jewelry
    local held = safe(function() return item.WornSlot('primary')() end)         -- main hand
        or safe(function() return item.WornSlot('secondary')() end)            -- off hand
        or safe(function() return item.WornSlot('range')() end)                -- range slot
    if held then return 'weapons' end                                           -- held, not armor: a weapon
    return 'armor'                                                              -- anything else worn
end

--[[--------------------------------------------------------------------------
  core.readItem(item, source)

  WHAT  : Reads the facts this package needs from any MacroQuest item object
          and returns a plain table, or nil when there is no item. The class
          list may be empty (tradeskill items and the like); an augment with
          no Class line gets every class (allClasses = true).
  WHY   : The Class line in the item window is exactly Item.Classes (the
          count) and Item.Class(N) (each class). This is the attribute you
          pointed out in the item screenshots.
  WHERE : core.resolveItem, engine.learnFromBags.
  HOW   : Classes() gives N; Class(i).ShortName() gives WAR, CLR and so on
          for i = 1..N. Also NoDrop, RequiredLevel and itemGroup.
  WHEN  : Whenever an item object is available.
----------------------------------------------------------------------------]]
function core.readItem(item, source)
    local name = safe(function() return item.Name() end)                -- confirms the object is valid
    if not name or name == '' or name == 'NULL' then return nil end     -- no item here
    local n = tonumber(safe(function() return item.Classes() end)) or 0 -- how many classes may use it
    local classes = {}                                                  -- 3 letter class names
    for i = 1, n do
        local sn = safe(function() return item.Class(i).ShortName() end)  -- e.g. 'CLR'
        if sn and sn ~= '' and sn ~= 'NULL' then classes[#classes + 1] = sn:upper() end  -- keep valid names
    end
    local group = core.itemGroup(item)                                  -- armor, weapons, shields, augments
    local all = false                                                   -- filled in for class free augments
    if #classes == 0 and group == 'augments' then                       -- augments show no Class line in game
        for i, c in ipairs(config.ALL_CLASSES) do classes[i] = c end    -- usable by everyone
        all = true                                                      -- remembered for the log
    end
    return {
        name     = name,                                                -- exact item name
        classes  = classes,                                             -- who may use it
        nodrop   = safe(function() return item.NoDrop() end) == true,   -- No Trade?
        reqLevel = tonumber(safe(function() return item.RequiredLevel() end)) or 0,  -- 0 = none
        group    = group,                                               -- armor, weapons, shields or augments
        allClasses = all,                                               -- true = augment with no Class line
        source   = source,                                              -- where it was learned
        learned  = os.time(),                                           -- when
    }
end

--[[==========================================================================
  4. RESOLVING AN ITEM NAME
==========================================================================]]--

--[[--------------------------------------------------------------------------
  core.pluginLoaded(name)

  WHAT  : True when a MacroQuest plugin is loaded.
  WHY   : MQ2AutoLoot and MQ2LinkDB are both needed for the full workflow.
  WHERE : core.resolveItem, engine status, ui.lua.
  HOW   : mq.TLO.Plugin(name).IsLoaded().
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function core.pluginLoaded(name)
    return safe(function() return mq.TLO.Plugin(name).IsLoaded() end) == true  -- nil counts as not loaded
end

--[[--------------------------------------------------------------------------
  fromLinkDB(name)

  WHAT  : Opens the item's window through MQ2LinkDB and reads it.
  WHY   : The only documented way to see the Class line of an item nobody on
          this box owns and nobody has clicked.
  WHERE : core.resolveItem, last step.
  HOW   : mq.TLO.LinkDB('=' .. name) returns the exact match link text.
          /executelink opens it like clicking a link in chat. Wait up to two
          seconds for mq.TLO.DisplayItem(name) to show that item, read it,
          then close that window with Window.DoClose() if configured.
  WHEN  : Only when every cheaper route failed. Main loop only (mq.delay).
----------------------------------------------------------------------------]]
local function fromLinkDB(name)
    if not config.settings.useLinkDB then return nil, 'LinkDB lookups are turned off' end         -- option off
    if not core.pluginLoaded('mq2linkdb') then return nil, 'MQ2LinkDB is not loaded' end           -- plugin missing
    local link = safe(function() return mq.TLO.LinkDB('=' .. name)() end)                         -- exact match link
    if not link or link == '' or link == 'NULL' then return nil, 'MQ2LinkDB has no link for it' end  -- not in database
    mq.cmdf('/executelink %s', link)                                                              -- open the item window
    local function shown()                                                                        -- is it open yet?
        return safe(function() return mq.TLO.DisplayItem(name).Name() end) == name
    end
    mq.delay(2000, shown)                                                                         -- up to 2 s
    if not shown() then return nil, 'item window did not open' end                                -- gave up
    local info = core.readItem(mq.TLO.DisplayItem(name), 'linkdb')                                -- read the Class line
    if config.settings.closeItemWindow then
        safe(function() return mq.TLO.DisplayItem(name).Window.DoClose() end)                     -- tidy up
    end
    if not info then return nil, 'item window could not be read' end                              -- unusable read
    return info
end

--[[--------------------------------------------------------------------------
  core.resolveItem(name)

  WHAT  : Returns the facts for an item name, or nil plus a reason.
  WHY   : The Gear rule needs the item's Class list.
  WHERE : engine.lua.
  HOW   : In order, cheapest first:
            1. Item cache file (any box may have learned it before).
            2. FindItem('=name')      your bags and worn slots.
            3. FindItemBank('=name')  your bank.
            4. DisplayItem(name)      an item window already open.
            5. MQ2LinkDB              see fromLinkDB.
          Anything found in steps 2 to 5 is saved to the cache, including
          items with no Class line, so an item that is not ours is looked
          up only once ever (1.1.0: needed now that every drop is checked
          for being an augment).
  WHEN  : Once per new item; the cache makes later sightings instant.
----------------------------------------------------------------------------]]
function core.resolveItem(name)
    local cached = config.storeAll('cache')[name]                          -- 1. cache
    if cached and type(cached.classes) == 'table' and cached.group then return cached end  -- known item, even with no classes
    local info = core.readItem(mq.TLO.FindItem('=' .. name), 'bags')       -- 2. bags and worn
        or core.readItem(mq.TLO.FindItemBank('=' .. name), 'bank')         -- 3. bank
    if not info and safe(function() return mq.TLO.DisplayItem(name).Name() end) == name then
        info = core.readItem(mq.TLO.DisplayItem(name), 'window')           -- 4. open item window
    end
    local why = nil                                                        -- reason when not found
    if not info then info, why = fromLinkDB(name) end                      -- 5. MQ2LinkDB
    if not info then return nil, why or 'no source had the Class line' end -- unresolved
    config.storePut('cache', name, info)                                   -- share with every box
    return info
end

--[[==========================================================================
  5. MQ2AutoLoot Loot.ini
==========================================================================]]--

--[[--------------------------------------------------------------------------
  parseIni(text)

  WHAT  : Parses INI text into section -> key -> value, all lower case keys.
  WHY   : Read only view of Loot.ini and MQ2AutoLoot.ini. Windows profile
          lookups are case insensitive, so this view is too.
  WHERE : core.lootIniPath, core.readEntry, core.snapshot, core.newItemDelay.
  HOW   : Line by line: [Section] starts a section, key=value adds a key
          (first '=' splits; item names never contain '='). Lines starting
          with ; or # are comments. Original key spelling is kept too.
  WHEN  : On demand.
----------------------------------------------------------------------------]]
local function parseIni(text)
    local data, section = {}, nil                                    -- result and current section
    for line in (text or ''):gmatch('[^\r\n]+') do                   -- every line
        local s = line:match('^%s*%[(.-)%]%s*$')                     -- [Section] header?
        if s then
            section = s:lower()                                      -- section names compare lower case
            data[section] = data[section] or {}                      -- create once
        elseif section and not line:match('^%s*[;#]') then           -- skip comment lines
            local k, v = line:match('^([^=]+)=(.*)$')                -- key=value
            if k then k = k:match('^%s*(.-)%s*$') data[section][k:lower()] = { key = k, value = v } end  -- trimmed, original spelling kept
        end
    end
    return data
end

--[[--------------------------------------------------------------------------
  core.lootIniPath()

  WHAT  : Returns the full path of the Loot.ini this character uses.
  WHY   : MQ2AutoLoot lets each character point at its own file.
  WHERE : core.readEntry, core.writeEntry, core.snapshot.
  HOW   : Same rule as MQ2AutoLoot's own startup: [CharacterName]
          lootini= in <config>/MQ2AutoLoot.ini, otherwise <config>\Loot.ini.
  WHEN  : On demand (cheap).
----------------------------------------------------------------------------]]
function core.lootIniPath()
    local me = (safe(function() return mq.TLO.Me.CleanName() end) or ''):lower()   -- character name
    local plugin = parseIni(config.readText(mq.configDir .. '/MQ2AutoLoot.ini'))     -- plugin settings
    local entry = plugin[me] and plugin[me]['lootini']                              -- per character path
    if entry and entry.value ~= '' then return entry.value end                       -- configured path
    return mq.configDir .. '\\Loot.ini'                                             -- plugin default
end

--[[--------------------------------------------------------------------------
  core.readEntry(name)

  WHAT  : Returns the current Loot.ini value for an item, or nil.
  WHY   : Decide whether to write, keep or replace.
  WHERE : engine.lua.
  HOW   : Reads and parses the file fresh (it can change between items),
          section = first character of the name, key = the name.
  WHEN  : Once per decision.
----------------------------------------------------------------------------]]
function core.readEntry(name)
    local data = parseIni(config.readText(core.lootIniPath()))     -- fresh view
    local sec = data[name:sub(1, 1):lower()]                       -- [S] for Simple ...
    local e = sec and sec[name:lower()]                            -- the item key
    return e and e.value or nil                                    -- nil = no entry
end

--[[--------------------------------------------------------------------------
  core.snapshot()

  WHAT  : Returns a set of every item key present in Loot.ini right now.
  WHY   : Lets the engine tell entries you or earlier sessions made (never
          touched automatically) from Keep entries MQ2AutoLoot creates on its
          own for new items while this script runs (replaceable).
  WHERE : engine.start (once at startup).
  HOW   : parseIni of the whole file; keys are 'section|lower name'.
  WHEN  : Once at startup.
----------------------------------------------------------------------------]]
function core.snapshot()
    local set = {}                                                     -- key -> true
    for sec, keys in pairs(parseIni(config.readText(core.lootIniPath()))) do
        for k in pairs(keys) do set[sec .. '|' .. k] = true end        -- every existing entry
    end
    return set
end

--[[--------------------------------------------------------------------------
  core.snapKey(name)

  WHAT  : Builds the snapshot key for an item name.
  WHY   : Same format in core.snapshot and the engine.
  WHERE : engine.lua.
  HOW   : first character + '|' + name, lower case.
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function core.snapKey(name)
    return name:sub(1, 1):lower() .. '|' .. name:lower()   -- e.g. 's|simple defiant leather bracer'
end

--[[--------------------------------------------------------------------------
  core.writeEntry(name, value)

  WHAT  : Writes (or with value nil, deletes) one Loot.ini entry.
  WHY   : Only way this package changes MQ2AutoLoot behaviour.
  WHERE : engine.lua.
  HOW   : MacroQuest /ini "file" "section" "key" "value". The MacroQuest
          source passes these to WritePrivateProfileString. To delete, the
          value must be a BARE NULL: MQCommands.cpp IniOutput says a quoted
          "NULL" is written as the text NULL. So a value is quoted, a delete
          is not. Absolute paths are used as given (GetMacroIni).
  WHEN  : Only when Start is active and Preview is off.
----------------------------------------------------------------------------]]
function core.writeEntry(name, value)
    local path, section = core.lootIniPath(), name:sub(1, 1)               -- file and section
    if value == nil then                                                    -- delete the key
        mq.cmdf('/ini "%s" "%s" "%s" NULL', path, section, name)            -- bare NULL deletes
    else                                                                    -- write the key
        mq.cmdf('/ini "%s" "%s" "%s" "%s"', path, section, name, value)     -- quoted value
    end
end

--[[--------------------------------------------------------------------------
  core.gearRule(classes, copies)

  WHAT  : Builds the MQ2AutoLoot Gear rule text.
  WHY   : Exact format from the MQ2AutoLoot README and source:
          Gear|Classes|WAR|PAL|NumberToLoot|2|
  WHERE : engine.lua.
  HOW   : Joins the class list with '|' and appends NumberToLoot.
  WHEN  : Each time a rule is written or previewed.
----------------------------------------------------------------------------]]
function core.gearRule(classes, copies)
    return string.format('Gear|Classes|%s|NumberToLoot|%d|', table.concat(classes, '|'), copies)  -- plugin format
end

--[[--------------------------------------------------------------------------
  core.isPluginDefault(value)

  WHAT  : True when a value looks like one MQ2AutoLoot writes for a new item.
  WHY   : Only those may be replaced automatically, and only when they
          appeared after startup.
  WHERE : engine.lua.
  HOW   : Keep, or Quest|N (its No Trade default), case insensitive.
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function core.isPluginDefault(value)
    local v = tostring(value or ''):lower()            -- compare lower case
    return v == 'keep' or v:match('^quest|%d+$') ~= nil  -- InitialLootEntry defaults
end

--[[--------------------------------------------------------------------------
  core.newItemDelay()

  WHAT  : Returns MQ2AutoLoot's NewItemDelay setting (seconds), or nil.
  WHY   : With 0, the master looter takes a brand new item at once, before
          this script can write the class rule. The window warns about it.
  WHERE : ui.lua status area.
  HOW   : [Settings] NewItemDelay in Loot.ini.
  WHEN  : When the window draws (cached by ui.lua).
----------------------------------------------------------------------------]]
function core.newItemDelay()
    local data = parseIni(config.readText(core.lootIniPath()))     -- read only view
    local e = data['settings'] and data['settings']['newitemdelay'] -- the setting
    return e and tonumber(e.value) or nil                          -- nil when unknown
end

return core

--[[==========================================================================
  END OF FILE : defiantlooter/core.lua

  DEPENDENCIES : mq, defiantlooter.config. Plugins: MQ2AutoLoot (required to
                 act on the rules), MQ2LinkDB (optional, for unseen items).

  HOW TO EDIT SAFELY
    - Never write Loot.ini with Lua io. Two boxes and MQ2AutoLoot share that
      file; /ini changes one key and leaves the rest alone.
    - resolveItem can wait. Keep it off the ImGui callback.
    - If MQ2AutoLoot ever changes its section rule (first character of the
      name), change core.readEntry, core.snapKey and core.writeEntry together.
==========================================================================]]--
