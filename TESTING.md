<!--
  FILE    : defiantlooter/TESTING.md
  PACKAGE : Defiant Looter Lua (MacroQuest / EverQuest)
  VERSION : 1.0.1
  WHAT    : Offline test instructions and the live checklist.
  WHY     : The offline harness proves the logic; only the client can prove
            the interfaces. Each live check names what it confirms.
  WHERE   : Package root.
  WHEN    : Before every release, and after any MacroQuest or MQ2AutoLoot
            update.
-->

# Testing

## Offline

```
pip install lupa
python3 dev/run_tests.py     # 24 scenarios, real INI files, fake MacroQuest
python3 dev/doc_audit.py     # documentation standard
```

## Live checklist (one batch)

Run with Preview on first; nothing is written.

1. `/lua run defiantlooter`: window opens Paused, Preview on; status shows
   MQ2AutoLoot and MQ2LinkDB loaded and the Loot.ini path.
2. Learn on a box wearing Defiant gear: log shows the items and class lists
   (confirms Me.Inventory, Container/Item, Classes, Class(i).ShortName).
3. `/dloot status` matches the window.
4. Kill something that drops a ticked tier while Started: log shows
   Would write with the right classes (confirms AdvLoot lists).
5. A drop nobody owns: log shows the LinkDB lookup and an item window opens
   and closes (confirms LinkDB, /executelink, DisplayItem, DoClose).
6. Untick Preview, NewItemDelay 5, next drop: Loot.ini gets the Gear line
   under the right letter and the right class box loots it (confirms /ini and
   MQ2AutoLoot honouring the rule).
7. Untick that tier, Retire: the entry is restored or removed, not set to the
   text NULL.
8. A pre-existing Keep entry: shown under Convert; converting changes only
   that line.
9. Pause stops scanning; `/dloot quit` ends cleanly.

Record results in the matching GitHub issue.

<!--
  END OF FILE : defiantlooter/TESTING.md
-->
