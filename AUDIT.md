<!--
  FILE    : defiantlooter/AUDIT.md
  PACKAGE : Defiant Looter Lua (MacroQuest / EverQuest)
  VERSION : 1.0.0
  WHAT    : Interface ledger. Every game data call (TLO), MacroQuest Lua
            function, ImGui call, slash command and plugin behaviour used by
            the package, matched to the definition, documentation page or
            source that defines it.
  WHY     : To show that no command or interface was made up, and to record
            what still needs confirming in a live client.
  WHERE   : Package root.
  WHEN    : Performed 2026-11-20 against the commits pinned below. Repeat
            whenever a command, TLO member or ImGui call is added or changed.
-->

# Defiant Looter interface audit

## Reference sources

| Source | Pin |
|---|---|
| [MacroQuest](https://github.com/macroquest/macroquest) | commit 3eb3297 (2026-11-16) |
| [mq-definitions](https://github.com/macroquest/mq-definitions) | commit 67f2248 (2026-06-07) |
| [MQ2AutoLoot](https://github.com/RedGuides/MQ2AutoLoot) | commit b6270a1 (2026-11-11) |
| [MQ2AutoLoot docs](https://www.redguides.com/docs/projects/mq2autoloot/) | read 2026-11-20 |
| [MQ2LinkDB docs](https://www.redguides.com/docs/projects/mq2linkdb/) | read 2026-11-20 |

## Slash commands

| Command | Used in | Source |
|---|---|---|
| `/ini "file" "section" "key" "value"` | core.writeEntry | MacroQuest src/main/MQCommands.cpp `IniOutput`: WritePrivateProfileString; path through GetMacroIni (absolute paths kept) |
| `/ini "file" "section" "key" NULL` | core.writeEntry (delete) | Same function: only a bare NULL deletes; a quoted "NULL" is written as text |
| `/executelink <link>` | core fromLinkDB | MacroQuest src/main/MQCommandAPI.cpp registers `/executelink`; MQCommands.cpp usage text |
| `/autoloot newitemdelay N` | engine.tick | MQ2AutoLoot.cpp line 1705 and help text line 1910 |

## Game data (TLO)

| Interface | Used in | Source |
|---|---|---|
| AdvLoot.PCount, PList(i), SCount, SList(i) | engine.scan | mq-definitions mq/tlo/_AdvLoot.lua |
| advlootitem Name, NoDrop, AlwaysNeed, AlwaysGreed, Never, AutoRoll | engine | mq-definitions mq/datatype/_advlootitem.lua (no class data, hence this package) |
| item Name, ID, Classes, Class(i), NoDrop, RequiredLevel, Type, WornSlot, Container, Item(n) | core.readItem, engine | mq-definitions mq/datatype/_item.lua |
| class ShortName, Name | core, engine | mq-definitions mq/datatype/_class.lua |
| FindItem('=name'), FindItemBank('=name') | core.resolveItem | mq-definitions mq/mq.lua |
| DisplayItem(name), DisplayItem(name).Window.DoClose() | core | MacroQuest src/plugins/itemdisplay/MQ2ItemDisplay.cpp `FindItemWndByString` (exact name, case insensitive), Window member, inheritance from item; mq-definitions _window.lua DoClose |
| LinkDB('=name') | core fromLinkDB | MQ2LinkDB docs: `${LinkDB[=name]}` returns the exact match link |
| Plugin(name).IsLoaded | core.pluginLoaded | mq-definitions mq/datatype/_plugin.lua |
| AutoLoot.Active | ui | mq-definitions mq/plugins/AutoLoot/_datatypes.lua |
| Me.CleanName, Me.Class, Me.Inventory(n), Me.Bank(n) | engine, config | mq-definitions _character.lua / _spawn.lua |
| EverQuest.Server, MacroQuest.GameState | config, init | mq-definitions _everquest.lua, _macroquest.lua |

## MacroQuest Lua

`mq.bind`, `mq.unbind`, `mq.cmdf`, `mq.delay`, `mq.gettime`, `mq.imgui.init`,
`mq.pickle`, `mq.configDir`: mq-definitions mq/mq.lua.

## ImGui

Begin, End, BeginChild, EndChild, BeginDisabled, EndDisabled,
BeginPopupModal, OpenPopup, CloseCurrentPopup, EndPopup, BeginTable,
EndTable, TableSetupColumn, TableHeadersRow, TableNextRow, TableNextColumn,
TableSetColumnIndex, Button, Checkbox, InputInt, SameLine, SeparatorText,
SetNextItemWidth, SetNextWindowSize, IsItemHovered, SetTooltip, Text,
TextColored, TextWrapped, PushStyleColor, PopStyleColor. Enums ImGuiCol,
ImGuiCond, ImGuiChildFlags, ImGuiTableFlags, ImGuiTableColumnFlags,
ImGuiWindowFlags: mq-definitions mq/imgui. The test harness checks the
Begin/End and Push/Pop stack is balanced on every frame.

## MQ2AutoLoot behaviour relied on

| Behaviour | Source (MQ2AutoLoot.cpp) |
|---|---|
| Loot.ini path is `lootini=` under [CharName] in MQ2AutoLoot.ini, default `<config>\Loot.ini` | lines 73 to 76 |
| Section is the first character of the item name; value read with GetPrivateProfileString on every decision | ParseLootEntry, lines 824 to 829 |
| NewItemDelay above 0: master looter writes the default entry and waits that many seconds | lines 832 to 840 |
| New item default is Keep, or Quest|N | InitialLootEntry, line 1034 onward |
| Gear rule: class list compared to the character's short class name, then NumberToLoot against FindItemCount (carried only), lore and space | lines 940 to 1015 |
| A Gear entry with no classes loots for everyone | lines 960 to 966 |

## Fixed during this audit

- Delete wrote `"NULL"` quoted, which MacroQuest stores as the text NULL.
  Fixed to a bare NULL; the harness now models the difference and test s14
  catches a regression.

## Not yet confirmed in a live client

See TESTING.md. In short: LinkDB link opens a window DisplayItem can find;
DoClose closes it; Class(i).ShortName on that window; `/ini` with an absolute
Windows path; the master looter honours a rule written during NewItemDelay;
item Type strings for armor, weapons and shields.

<!--
  END OF FILE : defiantlooter/AUDIT.md
-->
