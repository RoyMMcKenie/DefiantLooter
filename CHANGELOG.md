<!--
  FILE    : defiantlooter/CHANGELOG.md
  PACKAGE : Defiant Looter Lua (MacroQuest / EverQuest)
  VERSION : 1.0.0
  WHAT    : Version history.
  WHY     : dev/doc_audit.py checks every file's VERSION against the newest
            heading here, and future you needs to know what changed.
  WHERE   : Package root.
  WHEN    : Add a heading on every release.
-->

# Changelog

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
