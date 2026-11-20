<!--
  FILE    : defiantlooter/ARCHITECTURE.md
  PACKAGE : Defiant Looter Lua (MacroQuest / EverQuest)
  VERSION : 1.1.0
  WHAT    : Maintainer's map of the package: what each file does, how a loot
            decision flows through them, the documentation standard, and
            recipes for common changes.
  WHY     : So the code can be picked up years later without rediscovering
            how the pieces fit.
  WHERE   : Beside init.lua in <MacroQuest>/lua/defiantlooter/.
  WHEN    : Read before changing any code.
-->

# Defiant Looter architecture

## Start here

1. `init.lua` loads settings, takes a snapshot of Loot.ini, registers the
   window and `/dloot`, then loops.
2. The window (`ui.lua`) never waits. Buttons only set flags in
   `engine.requests`.
3. Each loop pass, `engine.tick` runs requested jobs (Learn, Convert, Retire,
   NewItemDelay, Scan) and, while Started, scans the Advanced Loot lists.
4. `engine.decide` is the single place a decision is made. It calls `core`
   for name matching, the Class list and Loot.ini.
5. `core.writeEntry` is the only function that changes Loot.ini, and it is
   reached only when Started and Preview is off.

## Module map

| File | One line job | Requires |
|---|---|---|
| `init.lua` | Startup, `/dloot` command, main loop | mq, config, core, engine, ui |
| `ui.lua` | ImGui window, never waits | mq, ImGui, config, core, engine |
| `engine.lua` | Decisions, scan, jobs, log, ledger | mq, config, core |
| `core.lua` | Chat, name matching, item reading, LinkDB, Loot.ini read and write | mq, config |
| `config.lua` | Defaults, settings file, box sync, ledger and cache stores | mq |

Nothing requires `ui` or `init`, so there are no circular requires.

## Decision flow (`engine.decide`)

1. Name: `core.matchName` looks for tier word + family word. Any other name
   can only be an augment, so it is looked up only while Augmentations is
   ticked (once per name, thanks to the cache). Non augments are silent;
   near misses appear only in Debug trace.
2. Class list: `core.resolveItem` tries cache, `FindItem`, `FindItemBank`,
   `DisplayItem`, then MQ2LinkDB. Not found: logged Undecided, retried a few
   times in this loot window.
3. Augments (`Item.AugType` above 0): only the Augmentations checkbox
   decides; no Class line means all classes (`config.ALL_CLASSES`).
   Gear: tier, family and item type group, and a Class line is required.
4. No Trade (skipped unless Include No Trade is ticked).
5. Existing Loot.ini value:
   - same rule: Rule in place;
   - your own Gear rule (not in the ledger): kept;
   - our older Gear rule: replaced (copies changed);
   - Keep or Quest|N that appeared after startup: replaced if Replace
     plugin defaults is on;
   - anything else: kept, and Keep or Quest entries are offered to Convert.
6. Preview on: Would write. Off: `core.writeEntry` and a ledger record of the
   value replaced, with kind `gear` or `augment` for Retire.

Steps 4 to 6 are `writeOrPreview`, shared by gear and augments.

Required level and slot are logged but never block a rule.

## Shared state between boxes

- Settings: `config.sync` compares the settings file text every 3 seconds and
  reloads if another box changed it.
- Ledger and item cache: `config.storePut` re-reads the file, merges one key
  and writes, so boxes do not erase each other's entries.
- Runtime switches (Started, Preview) are never saved. Every run starts
  Paused with Preview on.

## Documentation standard

Every Lua file has a header (FILE, PACKAGE, VERSION, CHANGES, WHAT, WHY,
WHERE, HOW, WHEN) and an END OF FILE footer. Every function has a block
stating WHAT, WHY, WHERE, HOW and WHEN. Every code line has a comment on it or
within three lines above. `python3 dev/doc_audit.py` checks all of this and
that each VERSION matches the newest CHANGELOG heading.

## Tests

`dev/harness.lua` is a fake MacroQuest: TLOs, `mq.cmdf`, a working `/ini`
that edits a real INI file (bare NULL deletes, quoted NULL is text, as in the
MacroQuest source), item windows, LinkDB and ImGui stack checks.
`dev/run_tests.py` runs 28 scenarios through lupa (LuaJIT).

## Recipes

- New tier word: add it to `config.TIERS` in order. The checkbox and command
  follow automatically.
- New family: add to `config.FAMILIES` with its spellings in
  `core.normalize` / `core.matchName`.
- New item group: `core.itemGroup` and `config.GROUPS`.
- Change the rule format: `core.gearRule` only, then rerun dev/run_tests.py and update the expected rule text there.
- Release: bump VERSION and CHANGES in every file, add a CHANGELOG heading,
  run both dev scripts.

<!--
  END OF FILE : defiantlooter/ARCHITECTURE.md
-->
