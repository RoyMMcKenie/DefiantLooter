--[[==========================================================================
  FILE        : defiantlooter/engine.lua
  PACKAGE     : Defiant Looter Lua  (MacroQuest / EverQuest)
  VERSION     : 1.1.0
  CHANGES     : 1.0.0  First release.
                1.0.1  No change in this file.
                1.1.0  Every augmentation collected; near miss names only in Debug trace.

  WHAT  : Watches the Advanced Loot window, decides for every listed item
          whether it is selected gear, and writes (or previews) the class
          Gear rule in MQ2AutoLoot's Loot.ini. Also runs the button jobs:
          Scan now, Learn from bags and bank, Convert existing Keep entries,
          Retire rules for unticked tiers, and Set NewItemDelay.

  WHY   : MQ2AutoLoot does the actual looting and passing out between boxes,
          and it already understands "only these classes take this item". It
          cannot read an item's Class line from the loot list on its own, so
          this engine supplies that one missing piece, for exactly the tiers
          and families you tick, and nothing else.

  WHERE : Required by ui.lua and init.lua. engine.tick runs on the main loop.

  HOW   : The decision for one item (engine.decide) goes:
            name -> tier and family ticked? -> Class list found?
            -> item type ticked? -> No Trade allowed?
            -> what is in Loot.ini now? -> write, replace, keep, or preview.
          Since 1.1.0 every augmentation is collected too, whatever its
          name: when Augmentations is ticked, any other name is looked up
          once (cache, owned copy, LinkDB) to see whether it is an augment.
          Augments with no Class line get a Gear rule for all classes.
          Every outcome goes to the decision log with its reason.
          Two switches control it:
            Start / Pause : whether the loot window is scanned automatically.
            Preview       : when on, nothing is EVER written to Loot.ini; the
                            log says what would have been written.
          The script always opens Paused with Preview on.

  WHEN  : engine.tick every main loop pass. The scan itself runs every
          settings.scanIntervalMs while items are listed.

  READING GUIDE (for future you)
    - "seen" remembers each item name for the life of one loot window so it
      is decided once, not 10 times a second. It is cleared when the loot
      window empties, when any checkbox changes, and on Start or Preview
      changes, so the new choices are applied to what is on screen.
    - The ledger (config stores) is the record of every entry this package
      wrote. Retire undoes exactly those entries; nothing else is removed.
==========================================================================]]--

local mq     = require('mq')                    -- MacroQuest API
local config = require('defiantlooter.config')  -- settings and stores
local core   = require('defiantlooter.core')    -- matching, items, Loot.ini

local engine = {}                               -- module table

--- State --------------------------------------------------------------------------
-- WHAT : Decision log, per window memory, startup snapshot, button requests.
-- WHY  : ui.lua draws these; button presses in the ImGui callback must not
--        run jobs there (jobs can wait), so they only set requests.
-- WHERE: This file; ui.lua reads log, conflicts and requests.
-- HOW  : Plain tables.
-- WHEN : Reset at startup.
engine.log       = {}    -- newest first: { time, item, result, reason, color }
engine.seen      = {}    -- item name -> { final = bool, at = ms, tries = n }
engine.conflicts = {}    -- item name -> { existing, rule, tier, family } (Convert list)
engine.snapshot  = {}    -- Loot.ini keys present at startup (core.snapKey form)
engine.requests  = {}    -- scan, learn, convert, retire, setDelay
engine.lastScan  = 0     -- mq.gettime() of the last scan
engine.counts    = { written = 0, previewed = 0, skipped = 0, unresolved = 0 }  -- session totals

local RETRY_MS  = 5000   -- wait before retrying an unresolved item
local MAX_TRIES = 3      -- unresolved attempts per loot window

-- Result colours for the log (r, g, b, a).
local COLORS = {
    write   = { 0.30, 0.90, 0.30, 1 },   -- green: rule written
    preview = { 0.40, 0.80, 1.00, 1 },   -- blue: would write
    keep    = { 0.90, 0.80, 0.30, 1 },   -- yellow: existing rule kept
    skip    = { 0.70, 0.70, 0.70, 1 },   -- grey: not selected
    problem = { 1.00, 0.45, 0.35, 1 },   -- red: could not decide
}
engine.COLORS = COLORS                   -- ui.lua uses the same colours

--[[--------------------------------------------------------------------------
  engine.addLog(item, result, reason, kind)

  WHAT  : Adds one line to the decision log and, for writes and problems,
          echoes it to chat.
  WHY   : You asked to see why each item was accepted or rejected.
  WHERE : Every decision path below.
  HOW   : Inserts at the front, trims to settings.logSize.
  WHEN  : Each decision.
----------------------------------------------------------------------------]]
function engine.addLog(item, result, reason, kind)
    table.insert(engine.log, 1, {                       -- newest at the top
        time = os.date('%H:%M:%S'),                     -- wall clock time
        item = item, result = result, reason = reason,  -- what and why
        color = COLORS[kind] or COLORS.skip,            -- colour by kind
    })
    while #engine.log > (config.settings.logSize or 200) do table.remove(engine.log) end  -- trim oldest
    if kind == 'write' then core.good('%s: %s', item, reason) end      -- chat for real changes
    if kind == 'problem' then core.warn('%s: %s', item, reason) end    -- chat for problems
    core.debug('%s | %s | %s', item, result, reason)                    -- full trace when debugging
end

--[[--------------------------------------------------------------------------
  engine.reset(why)

  WHAT  : Forgets which items were decided so they are decided again.
  WHY   : After a checkbox, Start or Preview change, what is on screen must
          follow the new choices.
  WHERE : ui.lua on any change, init.lua on settings sync, commands.
  HOW   : Clears seen and conflicts.
  WHEN  : On change.
----------------------------------------------------------------------------]]
function engine.reset(why)
    engine.seen = {}                       -- decide everything again
    engine.conflicts = {}                  -- rebuilt by the next scan
    core.debug('Re-evaluating: %s', why or 'change')  -- trace only
end

--[[--------------------------------------------------------------------------
  myClass()

  WHAT  : Returns this character's 3 letter class, e.g. 'CLR'.
  WHY   : The log says whether the character running the script can use it.
  WHERE : engine.decide.
  HOW   : mq.TLO.Me.Class.ShortName().
  WHEN  : Each decision.
----------------------------------------------------------------------------]]
local function myClass()
    return (core.safe(function() return mq.TLO.Me.Class.ShortName() end) or '?'):upper()  -- '?' if unknown
end

--[[--------------------------------------------------------------------------
  contains(list, value)

  WHAT  : True when value is in list.
  WHY   : Class list membership.
  WHERE : engine.decide.
  HOW   : Linear search.
  WHEN  : Each decision.
----------------------------------------------------------------------------]]
local function contains(list, value)
    for _, v in ipairs(list) do if v == value then return true end end  -- found
    return false                                                         -- not found
end

--[[--------------------------------------------------------------------------
  advFilterNote(adv)

  WHAT  : Returns a warning when the item has an EverQuest Advanced Loot
          filter (Always Need, Always Greed, Never or Auto Roll), else nil.
  WHY   : MQ2AutoLoot's documentation says those filters take precedence
          over Loot.ini, so a correct rule would appear not to work.
  WHERE : engine.decide.
  HOW   : advlootitem AlwaysNeed, AlwaysGreed, Never, AutoRoll members.
  WHEN  : Each decision that has a loot list entry.
----------------------------------------------------------------------------]]
local function advFilterNote(adv)
    if not adv then return nil end                                         -- bag learning: no list entry
    local set = {}                                                         -- filter names found
    if core.safe(function() return adv.AlwaysNeed() end) then set[#set + 1] = 'Always Need' end    -- AN
    if core.safe(function() return adv.AlwaysGreed() end) then set[#set + 1] = 'Always Greed' end  -- AG
    if core.safe(function() return adv.Never() end) then set[#set + 1] = 'Never' end              -- NV
    if core.safe(function() return adv.AutoRoll() end) then set[#set + 1] = 'Auto Roll' end        -- dice
    if #set == 0 then return nil end                                       -- no override
    return 'EverQuest loot filter "' .. table.concat(set, ', ') .. '" overrides MQ2AutoLoot for this item'
end

--[[--------------------------------------------------------------------------
  writeOrPreview(name, adv, info, rec)

  WHAT  : Builds the Gear rule for an identified item, compares it with
          Loot.ini, and writes it (or logs Would write in Preview).
  WHY   : Defiant gear and augmentations share every step after the item has
          been identified, so the shared steps live in one place.
  WHERE : engine.decide.
  HOW   : rec = { label, tier, family, kind } where kind is 'gear' or
          'augment'. Steps: No Trade check, rule text, existing value check
          (same rule / your own Gear rule / our older rule / new plugin
          default / anything else kept for Convert), then Preview or write
          plus a ledger record for Retire.
  WHEN  : Once per identified item per loot window, and on Learn.
----------------------------------------------------------------------------]]
local function writeOrPreview(name, adv, info, rec)
    local s = config.settings                                              -- live settings
    local nodrop = info.nodrop or (adv and core.safe(function() return adv.NoDrop() end) == true)  -- No Trade?
    if nodrop and not s.includeNoTrade then
        engine.counts.skipped = engine.counts.skipped + 1                  -- tally
        engine.addLog(name, 'Skipped', 'No Trade item; tick "Include No Trade items" to collect it', 'skip')
        return 'final'
    end
    local rule = core.gearRule(info.classes, s.copiesPerItem)              -- the rule text
    local me = myClass()                                                   -- this character's class
    local who                                                              -- log note about classes
    if info.allClasses then
        who = 'augment with no class limit; every box can loot one'        -- class free augment
    else
        who = contains(info.classes, me) and (me .. ' can use it') or (me .. ' cannot use it; an eligible box will take it')
    end
    if info.reqLevel and info.reqLevel > 0 then who = who .. ', required level ' .. info.reqLevel end  -- future level gear is still collected
    local note = advFilterNote(adv)                                        -- EverQuest filter warning
    local existing = core.readEntry(name)                                  -- Loot.ini now
    local ledger = config.storeAll('ledger')[name]                         -- did we write it before?
    local previous = nil                                                   -- value we replace, for Retire
    if existing == rule then
        engine.addLog(name, 'Rule in place', rec.label .. '; ' .. who .. (note and ('. ' .. note) or ''), note and 'problem' or 'keep')
        return 'final'                                                     -- nothing to change
    elseif existing and existing:lower():match('^gear|') and not ledger then
        engine.addLog(name, 'Existing rule kept', 'Loot.ini already has your Gear rule: ' .. existing, 'keep')
        return 'final'                                                     -- your own Gear rule wins
    elseif existing and existing:lower():match('^gear|') and ledger then
        previous = ledger.previous                                         -- our older rule (copies changed)
    elseif existing and core.isPluginDefault(existing) and not engine.snapshot[core.snapKey(name)] and s.replacePluginDefaults then
        previous = existing                                                -- MQ2AutoLoot's new item default
    elseif existing then
        engine.conflicts[name] = { existing = existing, rule = rule, tier = rec.tier, family = rec.family, kind = rec.kind }  -- for Convert
        engine.addLog(name, 'Existing rule kept', 'Loot.ini already says "' .. existing .. '". Use Convert to change it.', 'keep')
        return 'final'                                                     -- never overwrite silently
    end
    if config.runtime.preview then                                         -- preview or write
        engine.counts.previewed = engine.counts.previewed + 1              -- tally
        engine.addLog(name, 'Would write', rule .. '  (' .. who .. ')' .. (note and ('. ' .. note) or ''), 'preview')
        return 'final'
    end
    core.writeEntry(name, rule)                                            -- the one real change
    config.storePut('ledger', name, {                                      -- remember it for Retire
        tier = rec.tier, family = rec.family, kind = rec.kind, value = rule,
        previous = previous,                                               -- nil = there was no entry
        at = os.time(), by = core.safe(function() return mq.TLO.Me.CleanName() end),  -- who wrote it, when
    })
    engine.counts.written = engine.counts.written + 1                      -- tally
    engine.addLog(name, 'Rule written', rule .. '  (' .. who .. ')' .. (note and ('. ' .. note) or ''), note and 'problem' or 'write')
    return 'final'
end

--[[--------------------------------------------------------------------------
  engine.decide(name, adv)

  WHAT  : Makes and logs the decision for one item name. Returns 'final' or
          'retry' (retry = the item could not be identified yet).
  WHY   : The heart of the package. Two kinds of item are collected:
          Defiant family gear chosen by name (tier + family words), and,
          since 1.1.0, every augmentation whatever its name.
  WHERE : engine.scan for loot list items (adv = advlootitem) and
          engine.learnFromBags for owned items (adv = nil).
  HOW   : 1. Name. A tier + family name may be gear or an augment. Any
             other name can only be an augment, so it is looked up only
             when Augmentations is ticked; the item cache makes that a one
             time lookup per item name. Items that turn out not to be ours
             are silent (Debug trace shows them).
          2. core.resolveItem reads the Class list, type and No Trade.
          3. Augments: only the Augmentations checkbox decides.
             Gear: tier, family and item type checkboxes decide, and a
             Class line is required.
          4. writeOrPreview does the rest.
  WHEN  : Once per item per loot window, and on Learn.
----------------------------------------------------------------------------]]
function engine.decide(name, adv)
    local s = config.settings                                              -- live settings
    local tier, fam, near = core.matchName(name)                           -- step 1: the name
    local wantAugs = s.groups.augments == true                             -- any name could be an augment
    if not tier and not wantAugs then
        if near then core.debug('%s: tier word, but not a Defiant family name', name) end  -- near miss, debug only
        return 'final'                                                     -- not our gear
    end
    if tier and not wantAugs and not s.tiers[tier] then
        engine.counts.skipped = engine.counts.skipped + 1                  -- tally
        engine.addLog(name, 'Skipped', 'Tier ' .. tier .. ' is unticked', 'skip')  -- tier off
        return 'final'
    end
    if tier and not wantAugs and not s.families[fam] then
        engine.counts.skipped = engine.counts.skipped + 1                  -- tally
        engine.addLog(name, 'Skipped', 'Family ' .. core.familyLabel(fam) .. ' is unticked', 'skip')  -- family off
        return 'final'
    end
    local info, why = core.resolveItem(name)                               -- step 2: identify it
    if not info then
        if not tier then                                                   -- ordinary name: maybe an augment
            core.debug('%s: could not check whether it is an augment (%s)', name, tostring(why))  -- quiet
            return 'retry'                                                 -- try again shortly
        end
        engine.counts.unresolved = engine.counts.unresolved + 1            -- tally
        engine.addLog(name, 'Undecided', 'Item not found: ' .. tostring(why) .. '. No rule written.', 'problem')
        return 'retry'                                                     -- try again shortly
    end
    if info.group == 'augments' then                                       -- step 3a: augmentation
        if not wantAugs then
            engine.counts.skipped = engine.counts.skipped + 1              -- tally
            engine.addLog(name, 'Skipped', 'Augmentations is unticked', 'skip')
            return 'final'
        end
        return writeOrPreview(name, adv, info, { label = 'Augmentation', kind = 'augment' })  -- rule for an augment
    end
    if not tier then                                                       -- ordinary item, not an augment
        if near then core.debug('%s: tier word, but not a Defiant family name', name) end  -- near miss, debug only
        return 'final'                                                     -- not ours: silent
    end
    local label = tier .. ' ' .. core.familyLabel(fam)                     -- step 3b: Defiant gear
    if not s.tiers[tier] then
        engine.counts.skipped = engine.counts.skipped + 1                  -- tally
        engine.addLog(name, 'Skipped', 'Tier ' .. tier .. ' is unticked', 'skip')  -- tier off
        return 'final'
    end
    if not s.families[fam] then
        engine.counts.skipped = engine.counts.skipped + 1                  -- tally
        engine.addLog(name, 'Skipped', 'Family ' .. core.familyLabel(fam) .. ' is unticked', 'skip')  -- family off
        return 'final'
    end
    if #info.classes == 0 then                                             -- gear needs a Class line
        engine.counts.unresolved = engine.counts.unresolved + 1            -- tally
        engine.addLog(name, 'Undecided', 'Item has no Class line. No rule written.', 'problem')
        return 'final'                                                     -- retrying will not change it
    end
    if not s.groups[info.group] then                                       -- item type
        engine.counts.skipped = engine.counts.skipped + 1                  -- tally
        engine.addLog(name, 'Skipped', 'Item type "' .. info.group .. '" is unticked', 'skip')
        return 'final'
    end
    return writeOrPreview(name, adv, info, { label = label, tier = tier, family = fam, kind = 'gear' })  -- rule for gear
end

--[[--------------------------------------------------------------------------
  handle(name, adv, now)

  WHAT  : Calls engine.decide for one listed item unless it was already
          decided in this loot window.
  WHY   : The scan runs twice a second; each item must be decided once, and
          an unresolved item retried a few times, not spammed.
  WHERE : engine.scan.
  HOW   : seen[name] holds final or retry state with a time and try count.
  WHEN  : Each scan, for each listed item.
----------------------------------------------------------------------------]]
local function handle(name, adv, now)
    if not name or name == '' or name == 'NULL' then return end            -- empty row
    local st = engine.seen[name]                                           -- earlier decision
    if st and st.final then return end                                     -- already decided
    if st and (now - st.at < RETRY_MS or st.tries >= MAX_TRIES) then return end  -- wait or give up
    local result = engine.decide(name, adv)                                -- decide now
    engine.seen[name] = { final = (result ~= 'retry'), at = now, tries = (st and st.tries or 0) + 1 }  -- remember
end

--[[--------------------------------------------------------------------------
  engine.scan()

  WHAT  : Reads the personal and shared Advanced Loot lists once.
  WHY   : Each listed item may need a rule before MQ2AutoLoot acts on it.
  WHERE : engine.tick.
  HOW   : AdvLoot.PCount / PList(i) and SCount / SList(i). An empty window
          clears seen, so the next corpse is decided fresh.
  WHEN  : Every scanIntervalMs while Started, or once on Scan now.
----------------------------------------------------------------------------]]
function engine.scan()
    local now = mq.gettime()                                                     -- milliseconds
    local pc = tonumber(core.safe(function() return mq.TLO.AdvLoot.PCount() end)) or 0  -- personal list size
    local sc = tonumber(core.safe(function() return mq.TLO.AdvLoot.SCount() end)) or 0  -- shared list size
    if pc + sc == 0 then engine.seen = {} return 0 end                           -- window empty
    for i = 1, pc do
        local adv = mq.TLO.AdvLoot.PList(i)                                      -- personal item i
        handle(core.safe(function() return adv.Name() end), adv, now)            -- decide it
    end
    for i = 1, sc do
        local adv = mq.TLO.AdvLoot.SList(i)                                      -- shared item i
        handle(core.safe(function() return adv.Name() end), adv, now)            -- decide it
    end
    return pc + sc                                                               -- items seen
end

--[[--------------------------------------------------------------------------
  eachOwnedItem(fn)

  WHAT  : Calls fn(item) for every item worn, in bags, and in the bank.
  WHY   : Learn from bags and bank.
  WHERE : engine.learnFromBags.
  HOW   : Me.Inventory(0..34) covers worn slots and the top level pack
          slots; any container's Item(1..Container()) is walked too.
          Me.Bank(1..24) is walked the same way; bank reads that fail are
          skipped quietly.
  WHEN  : On Learn.
----------------------------------------------------------------------------]]
local function eachOwnedItem(fn)
    local function visit(item)                                                  -- one slot
        if not core.safe(function() return item.ID() end) then return end      -- empty slot
        fn(item)                                                                -- the item itself
        local slots = tonumber(core.safe(function() return item.Container() end)) or 0  -- bag size
        for j = 1, slots do
            local inner = item.Item(j)                                          -- item inside the bag
            if core.safe(function() return inner.ID() end) then fn(inner) end  -- not empty
        end
    end
    for slot = 0, 34 do visit(mq.TLO.Me.Inventory(slot)) end                    -- worn and packs
    for slot = 1, 24 do visit(mq.TLO.Me.Bank(slot)) end                         -- bank slots
end

--[[--------------------------------------------------------------------------
  engine.learnFromBags()

  WHAT  : Learns every matching item (Defiant family gear with a Class
          line, and any augmentation) this character owns into the item
          cache, then decides each one (which writes the rule when Preview
          is off).
  WHY   : Rules written ahead of time mean the next drop of that item is
          handled instantly, with no item window lookup and no race against
          MQ2AutoLoot.
  WHERE : Learn button and /dloot learn.
  HOW   : eachOwnedItem, core.matchName, core.readItem, config.storePut,
          then engine.decide(name, nil).
  WHEN  : On request, on the main loop.
----------------------------------------------------------------------------]]
function engine.learnFromBags()
    local found = {}                                                            -- name -> facts
    eachOwnedItem(function(item)
        local name = core.safe(function() return item.Name() end)               -- item name
        if name and not found[name] then
            local info = core.readItem(item, 'owned')                           -- Class line, type, No Trade
            local ours = info and (core.matchName(name) and #info.classes > 0 or info.group == 'augments')  -- Defiant gear or any augment
            if ours then found[name] = info end                                 -- keep the first copy
        end
    end)
    local n = 0                                                                 -- items learned
    for name, info in pairs(found) do
        config.storePut('cache', name, info)                                    -- share with every box
        engine.decide(name, nil)                                                -- rule or preview
        n = n + 1                                                               -- tally
    end
    core.echo('Learned %d matching item(s) from worn slots, bags and bank.', n) -- summary
end

--[[--------------------------------------------------------------------------
  engine.convertConflicts()

  WHAT  : Replaces existing Keep or Quest|N entries for ticked gear (the
          Convert list) with the class Gear rule.
  WHY   : Entries MQ2AutoLoot wrote before this script existed make every
          box loot the item regardless of class. They are never changed
          automatically, only by this explicit, confirmed button.
  WHERE : Convert button (after its confirmation popup).
  HOW   : For each conflict whose value is a plugin default, write the rule
          and record the old value in the ledger. Other values (Ignore,
          Sell, Destroy and so on) are left alone and reported.
  WHEN  : On request. Respects Preview.
----------------------------------------------------------------------------]]
function engine.convertConflicts()
    for name, c in pairs(engine.conflicts) do
        if not core.isPluginDefault(c.existing) then                            -- Ignore, Sell, Destroy and so on: hands off
            engine.addLog(name, 'Existing rule kept', '"' .. c.existing .. '" is not Keep or Quest; change it by hand if you want', 'keep')
        elseif config.runtime.preview then                                      -- Preview: log only
            engine.addLog(name, 'Would convert', c.existing .. '  ->  ' .. c.rule, 'preview')   -- preview only
        else
            core.writeEntry(name, c.rule)                                       -- the change
            config.storePut('ledger', name, { tier = c.tier, family = c.family, kind = c.kind, value = c.rule, previous = c.existing, at = os.time(),
                by = core.safe(function() return mq.TLO.Me.CleanName() end) })  -- undo record
            engine.addLog(name, 'Converted', c.existing .. '  ->  ' .. c.rule, 'write')
        end
    end
    engine.reset('convert')                                                     -- redecide on screen items
end

--[[--------------------------------------------------------------------------
  engine.retireList()

  WHAT  : Returns ledger entries whose tier or family is now unticked, and
          augment entries when Augmentations is unticked.
  WHY   : The Retire confirmation popup lists exactly what will change.
  WHERE : ui.lua and engine.retireUnticked.
  HOW   : Filters config.storeAll('ledger').
  WHEN  : When the popup opens and when Retire runs.
----------------------------------------------------------------------------]]
function engine.retireList()
    local out = {}                                                              -- name -> ledger entry
    local s = config.settings                                                   -- live settings
    for name, e in pairs(config.storeAll('ledger')) do
        if e.kind == 'augment' then                                             -- augment rule (1.1.0)
            if not s.groups.augments then out[name] = e end                     -- Augmentations unticked
        elseif not s.tiers[e.tier] or not s.families[e.family] then out[name] = e end  -- tier or family unticked
    end
    return out
end

--[[--------------------------------------------------------------------------
  engine.retireUnticked()

  WHAT  : Undoes the Loot.ini entries this package wrote for tiers or
          families you have since unticked.
  WHY   : Unticking a tier only stops NEW rules; rules already written keep
          working until retired. This is the explicit undo.
  WHERE : Retire button (after its confirmation popup), /dloot retire.
  HOW   : For each entry from retireList: if Loot.ini still holds the value
          we wrote, put back the previous value (or delete the key when there
          was none) and drop the ledger entry. If you changed the entry by
          hand since, it is left alone and only the ledger entry is dropped.
  WHEN  : On request. Respects Preview.
----------------------------------------------------------------------------]]
function engine.retireUnticked()
    local n = 0                                                                 -- entries changed
    for name, e in pairs(engine.retireList()) do
        local now = core.readEntry(name)                                        -- what is there now
        if now ~= e.value then
            if not config.runtime.preview then config.storePut('ledger', name, nil) end  -- yours now, forget it
            engine.addLog(name, 'Left alone', 'Entry was changed by hand since; ledger entry dropped', 'keep')
        elseif config.runtime.preview then
            engine.addLog(name, 'Would retire', e.previous and ('restore "' .. e.previous .. '"') or 'remove the entry', 'preview')
        else
            core.writeEntry(name, e.previous)                                   -- nil previous deletes the key
            config.storePut('ledger', name, nil)                                -- no longer ours
            engine.addLog(name, 'Retired', e.previous and ('restored "' .. e.previous .. '"') or 'entry removed', 'write')
            n = n + 1                                                           -- tally
        end
    end
    core.echo('Retire finished: %d entr%s changed.', n, n == 1 and 'y' or 'ies')  -- summary
    engine.reset('retire')                                                      -- redecide on screen items
end

--[[--------------------------------------------------------------------------
  engine.start()

  WHAT  : One time setup: takes the Loot.ini snapshot.
  WHY   : The snapshot separates entries that existed before this session
          from MQ2AutoLoot defaults created during it.
  WHERE : init.lua startup.
  HOW   : core.snapshot.
  WHEN  : Once.
----------------------------------------------------------------------------]]
function engine.start()
    engine.snapshot = core.snapshot()     -- keys present right now
end

--[[--------------------------------------------------------------------------
  engine.tick()

  WHAT  : Runs any requested button job, then the automatic scan if due.
  WHY   : Jobs may wait (item window lookups), so they run here on the main
          loop and never in the ImGui callback.
  WHERE : init.lua main loop.
  HOW   : Requests are taken one at a time and cleared before running.
          The automatic scan runs only while Started.
  WHEN  : Every main loop pass.
----------------------------------------------------------------------------]]
function engine.tick()
    local r = engine.requests                                                   -- shorthand
    if r.setDelay then
        mq.cmdf('/autoloot newitemdelay %d', r.setDelay)                        -- MQ2AutoLoot documented command
        r.setDelay = nil
    end
    if r.learn then r.learn = false engine.learnFromBags() end                  -- Learn button
    if r.convert then r.convert = false engine.convertConflicts() end           -- Convert button
    if r.retire then r.retire = false engine.retireUnticked() end               -- Retire button
    if r.scan then                                                              -- Scan now button
        r.scan = false
        engine.reset('scan now')                                                -- decide everything shown
        local n = engine.scan()                                                 -- one pass
        if n == 0 then core.echo('Scan: the Advanced Loot window has no items.') end
    end
    if not config.runtime.running then return end                               -- Paused: no automatic scan
    local now = mq.gettime()                                                    -- milliseconds
    if now - engine.lastScan < (config.settings.scanIntervalMs or 500) then return end  -- not due
    engine.lastScan = now                                                       -- next scan later
    engine.scan()                                                               -- automatic pass
end

return engine

--[[==========================================================================
  END OF FILE : defiantlooter/engine.lua

  DEPENDENCIES : mq, defiantlooter.config, defiantlooter.core.

  HOW TO EDIT SAFELY
    - Every path that writes Loot.ini must check config.runtime.preview
      first. That check is the promise that Preview never changes anything.
    - Never overwrite an entry that existed before startup without the
      Convert button. That is how your own rules stay safe.
    - A new decision step belongs in engine.decide, with its own log reason.
==========================================================================]]--
