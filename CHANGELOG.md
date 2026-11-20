<!--
  FILE    : defiantlooter/CHANGELOG.md
  PACKAGE : Defiant Looter Lua (MacroQuest / EverQuest)
  VERSION : 1.1.0
  WHAT    : Version history.
  WHY     : dev/doc_audit.py checks every file's VERSION against the newest
            heading here, and future you needs to know what changed.
  WHERE   : Package root.
  WHEN    : Add a heading on every release.
-->

# Changelog

## 1.1.0

- Every augmentation is collected, whatever its name, when the new
  "Augmentations (any name)" item type is ticked (on by default). Augments
  are found by their augment type (Item.AugType above 0), not by name.
- Augments show no Class line in game, so one with no class limit gets a
  Gear rule for all 16 classes; each box can loot one (lore is still checked
  by MQ2AutoLoot). Found live with Crude Defiant Stone Fragment, which 1.0.1
  logged as Undecided.
- Items that turn out not to be ours are remembered in the item cache, so
  each item name is looked up only once.
- Near miss names such as Rough Silk no longer fill the decision log; they
  show in chat only with "Debug trace in chat" ticked.
- Retire also removes augment rules when Augmentations is unticked.

## 1.0.1

- Chat colour codes now render. 1.0.0 wrote them with a doubled backslash,
  so chat showed the letters (\at, \ax) as text. Found in the first live run.

## 1.0.0

First release.

- Tier checkboxes Crude through Transcendent; family checkboxes Defiant,
  Adept's, Combatant's; armor, weapons and shields groups.
- Writes MQ2AutoLoot `Gear|Classes|...|NumberToLoot|N|` rules from the item's
  real Class list.
- Class lookup from cache, owned items, bank, open item window and MQ2LinkDB.
- Starts Paused with Preview on; Start and Pause buttons; decision log.
- Replace plugin defaults written after start; confirmed Convert for older
  Keep and Quest entries; confirmed Retire that restores or removes.
- Settings shared across boxes on the same server.
- Delete uses a bare NULL with /ini, because MacroQuest writes a quoted
  "NULL" as text (found in the source audit before release).

<!--
  END OF FILE : defiantlooter/CHANGELOG.md
-->
