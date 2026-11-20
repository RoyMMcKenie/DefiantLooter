<!--
  FILE    : defiantlooter/README.md
  PACKAGE : Defiant Looter Lua (MacroQuest / EverQuest)
  VERSION : 1.1.0
  WHAT    : Install, use and troubleshooting guide for the package.
  WHY     : So the package can be set up and tuned without reading the code.
  WHERE   : Lives beside init.lua in <MacroQuest>/lua/defiantlooter/.
  WHEN    : Read before first run and when something misbehaves.
-->

# Defiant Looter

A MacroQuest Lua package that makes MQ2AutoLoot loot Defiant, Adept's and
Combatant's gear for the classes that can actually use it, and every
augmentation that drops. You tick the tiers (Crude through Transcendent) and
families you want, and the script writes a MQ2AutoLoot `Gear` rule for each
matching item, using the class list printed on the item itself.

It never equips, sells, destroys or trades anything. It only adds or changes
the Loot.ini entries for the items you asked it to manage, and it leaves every
other loot rule alone.

## How it works

1. An item drops and shows up in the Advanced Loot window.
2. The script checks the name: first word must be a ticked tier (for example
   `Elegant`), second word a ticked family (`Defiant`, `Adept's`,
   `Combatant's`). Item type must be a ticked group (armor, weapons, shields).
3. It finds the item's real Class list: from its cache, from a copy you own
   (bags or bank), from an open item window, or from MQ2LinkDB.
4. It writes `Gear|Classes|CLR|DRU|...|NumberToLoot|99|` into Loot.ini under
   the item's first letter.
5. MQ2AutoLoot reads Loot.ini fresh for every decision, so every box in the
   group follows the new rule: a box loots it when its class is on the list
   and it carries fewer than the copies limit.

Augmentations are found by their augment type, not their name, so any
augment counts when "Augmentations (any name)" is ticked. Augments show no
Class line, so they get a rule for all classes and each box can loot one.
To know whether an ordinary item is an augment, the script looks it up once
(owned copy or MQ2LinkDB) and remembers the answer.

Required level is never checked, so a character can collect gear for later.
Slot is never checked, so a character can collect several items for the same
slot and duplicates of wrist or ring items. The copies limit only counts the
exact same item.

## Requirements

- MacroQuest with Lua and ImGui (current Live, Test or emulator build).
- MQ2AutoLoot loaded on every box: `/plugin mq2autoloot`.
- Strongly recommended: MQ2LinkDB with a filled database, so the script can
  read class lists for items nobody in the group owns yet. Load it with
  `/plugin mq2linkdb`, then run `/link /update` once. That downloads the
  RedGuides items.txt and imports it (MQ2LinkDB source, `/update`). If you
  already have items.txt in `<MacroQuest>/resources`, `/link /import` imports
  it without downloading. `/link` on its own prints how many links the
  database holds. With an empty database, first time drops show as
  Undecided and MQ2AutoLoot's default (Keep) applies to them.
- EverQuest Advanced Loot in use (MQ2AutoLoot drives it).

## Install

1. Copy the `defiantlooter` folder into `<MacroQuest>/lua/`, so you have
   `<MacroQuest>/lua/defiantlooter/init.lua`.
2. In game: `/lua run defiantlooter`.
3. Run it on one box per group (the master looter is best). Settings are
   shared by every box on the same server through
   `<MacroQuest>/config/defiantlooter_<server>.lua`.

## First run

The script always starts Paused with Preview on. In that state it only logs
what it would do.

1. Tick the tiers and families you want.
2. Press `Set NewItemDelay to 5`. This runs the MQ2AutoLoot command
   `/autoloot newitemdelay 5`, which makes the master looter wait five
   seconds on a brand new item so the script can write its rule first.
   With a delay of 0 the plugin may write `Keep` and loot the item before the
   script sees it.
3. Press `Learn from my gear, bags and bank` on each box once. It records the
   class lists of Defiant gear you already own and, once Preview is off,
   writes their rules ahead of the next drop.
4. Press Start and watch the decision log. When the log looks right, untick
   Preview. From then on rules are written.

## Window

| Control | What it does |
|---|---|
| Start / Pause | Green Start begins watching the Advanced Loot window; red Pause stops it. |
| Preview | On: decisions are logged, nothing is written. Starts on every run. |
| Tier checkboxes | Crude, Simple, Rough, Ornate, Flawed, Intricate, Elaborate, Elegant, Transcendent. |
| Family checkboxes | Defiant, Adept's, Combatant's. |
| Item types | Armor and jewelry, weapons, shields, Augmentations (any name). |
| Include No Trade | Off by default. No Trade items cannot be passed to another box later. |
| Copies per item | NumberToLoot in the rule (1 to 999, default 99). Counts what a character carries, not the bank. |
| Replace plugin defaults | Replaces `Keep` or `Quest|N` entries that MQ2AutoLoot writes for a new item after the script started. |
| Use MQ2LinkDB | Look up items nobody owns. Close it after closes the item window it opened. |
| Debug trace in chat | Extra detail in chat, including near miss names such as Rough Silk. |
| Scan now | Decides the current loot list once. |
| Convert | Lists Keep and Quest entries that existed before the script started and asks before converting them. |
| Retire | For tiers you have unticked, restores the old value or removes the entry, after a confirm. |
| Decision log | Every decision with the reason. Clear log empties it. |

Any other value already in Loot.ini (Ignore, Sell, Destroy, Deposit, Barter,
your own Gear rules) is never touched.

## Commands

| Command | Action |
|---|---|
| `/dloot` | Show or hide the window |
| `/dloot start` | Start |
| `/dloot pause` | Pause |
| `/dloot preview on` or `off` | Preview on or off |
| `/dloot scan` | Scan now |
| `/dloot learn` | Learn from gear you own |
| `/dloot tier <Name> on` or `off` | Tick or untick a tier, e.g. `/dloot tier Elegant on` |
| `/dloot status` | One line summary in chat |
| `/dloot quit` | Save and end |
| `/dloot help` | List commands |

## Files it creates

All in `<MacroQuest>/config/`:

- `defiantlooter_<server>.lua` settings shared by your boxes.
- `defiantlooter_<server>_ledger.lua` what the script wrote, and the value it
  replaced, so Retire can restore it.
- `defiantlooter_itemcache.lua` class lists it has learned.

Loot.ini itself is the file named by `lootini=` in MQ2AutoLoot.ini, or
`<MacroQuest>/config/Loot.ini`.

## Limitations

- Race restrictions are not supported: MQ2AutoLoot Gear rules only test class.
- NumberToLoot counts items a character carries, not its bank. Default 99
  effectively means "always loot".
- An item nobody owns and that MQ2LinkDB does not know cannot be checked.
  Defiant gear is logged as Undecided; an ordinary name stays with your other
  rules. An imported MQ2LinkDB database matters more since 1.1.0, because
  every new item name is checked for being an augment.
- Each first lookup through MQ2LinkDB briefly opens and closes an item
  window.
- EverQuest's own Always Need, Always Greed, Never and Auto Roll filters act
  before MQ2AutoLoot; the log warns when one is set on a managed item.
- Not yet confirmed in a live client. See TESTING.md for the checks.

## Testing

Offline tests (28 scenarios) run against a fake MacroQuest with real Loot.ini files:
`python3 dev/run_tests.py` (needs Python 3 with lupa). Documentation standard:
`python3 dev/doc_audit.py`.

## Credits

Built on [MQ2AutoLoot](https://www.redguides.com/docs/projects/mq2autoloot/)
and [MQ2LinkDB](https://www.redguides.com/docs/projects/mq2linkdb/). Every
interface used is listed with its source in AUDIT.md.

## License

MIT. See LICENSE.

<!--
  END OF FILE : defiantlooter/README.md
-->
