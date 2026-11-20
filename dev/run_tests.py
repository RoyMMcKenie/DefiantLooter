"""
=============================================================================
  FILE        : defiantlooter/dev/run_tests.py
  PACKAGE     : Defiant Looter Lua  (MacroQuest / EverQuest)
  VERSION     : 1.0.0
  CHANGES     : 1.0.0  First version.

  WHAT  : Runs offline scenarios against the real package files using the
          fake MacroQuest in dev/harness.lua, and prints PASS or FAIL for
          each.

  WHY   : Proves the safety and decision logic after every change: Preview
          never writes, unticked tiers and families never get rules, your
          existing Loot.ini entries are never overwritten without Convert,
          the Gear rule text is exact, Retire undoes only what this package
          wrote. It does NOT prove client behaviour; TESTING.md covers the
          live checks.

  WHERE : defiantlooter/dev/. Needs Python 3 and lupa (pip install lupa),
          which embeds LuaJIT 2.1 like MQ2Lua.

  HOW   : Each scenario gets a fresh LuaJIT runtime and temp config folder.
          A temporary folder with a link named defiantlooter points at the
          package, so require('defiantlooter.<file>') resolves exactly as in
          MacroQuest. The scenario sets up the fake world and Loot.ini,
          schedules steps, runs init.lua, and checks the results.

  WHEN  : After every code change, before committing or packaging.

  USAGE : python dev/run_tests.py     (from the package folder)
=============================================================================
"""
import os          # paths
import shutil      # temp folder cleanup
import sys         # exit code
import tempfile    # per scenario folders

from lupa.luajit21 import LuaRuntime   # same Lua dialect as MQ2Lua

PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # package folder
ROOT = tempfile.mkdtemp(prefix='dl_tests_')                         # holds the link
os.symlink(PKG, os.path.join(ROOT, 'defiantlooter'))                 # require name

CLOAK = "Transcendent Adept's Cloak"           # from the user's screenshot
PAULDRONS = "Transcendent Combatant's Pauldrons"
BRACER = 'Simple Defiant Leather Bracer'
CASTERS = ['CLR', 'DRU', 'SHM', 'NEC', 'WIZ', 'MAG', 'ENC']
MELEE = ['WAR', 'PAL', 'RNG', 'SHD', 'MNK', 'BRD', 'ROG', 'BST', 'BER']
CLOAK_RULE = 'Gear|Classes|CLR|DRU|SHM|NEC|WIZ|MAG|ENC|NumberToLoot|99|'


class Run:
    """
    WHAT  : One scenario run: Lua runtime, temp config folder and helpers.
    WHY   : Keeps every scenario independent.
    WHERE : Every scenario function.
    HOW   : __init__ builds the runtime; go() runs init.lua.
    WHEN  : Once per scenario.
    """

    def __init__(self, loot_ini='', settings=None):
        """
        WHAT  : Prepares the runtime, harness, config folder and Loot.ini.
        WHY   : Scenarios start from a known state.
        WHERE : Scenario functions.
        HOW   : lupa runtime, package.path to ROOT, dofile harness.
        WHEN  : Scenario start.
        """
        self.cfg = tempfile.mkdtemp(prefix='cfg_', dir=ROOT)              # fake config folder
        self.lua = LuaRuntime(unpack_returned_tuples=True)                # fresh Lua
        self.lua.execute("package.path = '%s/?.lua;%s/?/init.lua;' .. package.path" % (ROOT, ROOT))
        self.H = self.lua.eval("dofile('%s/dev/harness.lua')" % PKG)      # the fake MacroQuest
        self.H.mq.configDir = self.cfg                                     # config folder
        self.loot = self.cfg + '\\Loot.ini'                               # same path rule as core.lootIniPath
        self.H.lootIni = self.loot
        with open(self.loot, 'w') as fh:
            fh.write(loot_ini)                                             # starting Loot.ini
        if settings:
            self.lua.execute(settings_lua(self.cfg, settings))             # pre saved team settings

    def spec(self, name, classes, **kw):
        """
        WHAT  : Builds a Lua item spec table.
        WHY   : Short scenario code.
        WHERE : Scenarios.
        HOW   : Lua table constructor via eval.
        WHEN  : While building the world.
        """
        t = self.lua.table(name=name, classes=self.lua.table(*classes), **kw)  # spec table
        if 'slots' in kw:
            t.slots = self.lua.table(**kw['slots'])                         # worn slots
        return t

    def row(self, name, **kw):
        """
        WHAT  : Adds a row to the fake Advanced Loot shared list.
        WHY   : Simulates a drop.
        WHERE : Scenarios.
        HOW   : Appends to H.world.slist.
        WHEN  : While building the world or in a step.
        """
        sl = self.H.world.slist
        sl[len(sl) + 1] = self.lua.table(name=name, **kw)                   # one listed item

    def at(self, ms, py):
        """
        WHAT  : Schedules a Python callable at a fake time.
        WHY   : Drive buttons and drops during the run.
        WHERE : Scenarios.
        HOW   : H.at with a Lua wrapper.
        WHEN  : Before go().
        """
        self.H.at(ms, py)

    def go(self, until=6000):
        """
        WHAT  : Runs init.lua until the given fake time, then quits.
        WHY   : Exercises the real main loop.
        WHERE : Scenarios.
        HOW   : Schedules /dloot quit, dofile init.lua.
        WHEN  : Once per scenario.
        """
        self.at(until, lambda: self.H.slash('quit'))                        # clean end
        self.lua.execute("dofile('%s/init.lua')" % PKG)                     # the real package
        return self

    def entry(self, name):
        """
        WHAT  : Returns the Loot.ini value for an item, or None.
        WHY   : Check what was written.
        WHERE : Scenario checks.
        HOW   : Plain text search of the file.
        WHEN  : After go().
        """
        with open(self.loot) as fh:
            for line in fh:
                if line.lower().startswith(name.lower() + '='):
                    return line.rstrip('\n').split('=', 1)[1]                # value part
        return None

    def ini_cmds(self):
        """
        WHAT  : Every /ini command the package sent to Loot.ini items.
        WHY   : Preview must send none.
        WHERE : Scenario checks.
        HOW   : Filters H.cmds.
        WHEN  : After go().
        """
        return [c for c in self.H.cmds.values() if c.startswith('/ini ')]

    def log(self):
        """
        WHAT  : Decision log as a list of (item, result, reason).
        WHY   : Check reasons shown to the user.
        WHERE : Scenario checks.
        HOW   : Reads engine.log through package.loaded.
        WHEN  : After go().
        """
        eng = self.lua.eval("package.loaded['defiantlooter.engine']")
        return [(e.item, e.result, e.reason) for e in eng.log.values()]

    def results(self, name):
        """
        WHAT  : Results logged for one item.
        WHY   : Short checks.
        WHERE : Scenario checks.
        HOW   : Filters log().
        WHEN  : After go().
        """
        return [r for (i, r, _) in self.log() if i == name]


def settings_lua(cfg, s):
    """
    WHAT  : Lua code that writes a team settings file before init.lua runs.
    WHY   : Scenarios start with given checkboxes ticked.
    WHERE : Run.__init__.
    HOW   : mq.pickle of a merged table.
    WHEN  : Scenario start.
    """
    tiers = ', '.join('%s = true' % t for t in s.get('tiers', []))
    extra = s.get('extra', '')
    return ("local mq = require('mq') mq.pickle('%s/defiantlooter_test_server.lua', "
            "{ tiers = { %s }, families = { Defiant = %s, Adepts = %s, Combatants = %s }, %s })"
            % (cfg, tiers, *[str(s.get('fam', {}).get(k, True)).lower() for k in ('Defiant', 'Adepts', 'Combatants')], extra))


SCENARIOS = []


def scenario(fn):
    """
    WHAT  : Registers a scenario function.
    WHY   : Ordered list for the report.
    WHERE : Decorator on each scenario.
    HOW   : Appends to SCENARIOS.
    WHEN  : Import time.
    """
    SCENARIOS.append(fn)
    return fn


def start_write(r, at=200):
    """
    WHAT  : Presses Start and unticks Preview at a fake time.
    WHY   : Most scenarios need writing enabled.
    WHERE : Scenarios.
    HOW   : Queues the button and checkbox presses.
    WHEN  : Before go().
    """
    r.at(at, lambda: (r.H.press('Start##dl_start'), r.H.toggle('Preview only##dl_preview')))


@scenario
def s01_starts_paused_preview_no_writes():
    """Opens paused with Preview on; a matching drop is not even scanned."""
    r = Run(settings={'tiers': ['Transcendent']})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS)
    r.row(CLOAK)
    r.go()
    rt = r.lua.eval("package.loaded['defiantlooter.config'].runtime")
    assert rt.running is False and rt.preview is True, 'must start paused in preview'
    assert r.ini_cmds() == [], 'nothing written'
    assert r.results(CLOAK) == [], 'paused: not scanned'


@scenario
def s02_preview_logs_would_write():
    """Start with Preview on logs the exact rule but writes nothing."""
    r = Run(settings={'tiers': ['Transcendent']})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS, req=100)
    r.row(CLOAK)
    r.at(200, lambda: r.H.press('Start##dl_start'))
    r.go()
    assert r.ini_cmds() == [], 'preview wrote something'
    reasons = [x for (i, res, x) in r.log() if i == CLOAK and res == 'Would write']
    assert reasons and CLOAK_RULE in reasons[0], reasons
    assert 'CLR can use it, required level 100' in reasons[0], reasons[0]


@scenario
def s03_writes_exact_gear_rule_and_ledger():
    """Preview off: writes Gear|Classes|...|NumberToLoot|99| in section [T]."""
    r = Run(settings={'tiers': ['Transcendent']})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS)
    r.row(CLOAK)
    start_write(r)
    r.go()
    assert r.entry(CLOAK) == CLOAK_RULE, r.entry(CLOAK)
    assert any('"T"' in c for c in r.ini_cmds()), 'section must be first letter'
    with open(r.loot) as fh:
        assert '[T]' in fh.read()
    led = r.lua.eval("package.loaded['defiantlooter.config'].storeAll('ledger')")
    assert led[CLOAK].value == CLOAK_RULE and led[CLOAK].previous is None


@scenario
def s04_melee_box_writes_rule_but_notes_class():
    """A cleric box writes the pauldrons rule for melee classes and says CLR cannot use it."""
    r = Run(settings={'tiers': ['Transcendent']})
    r.H.world.bags[PAULDRONS] = r.spec(PAULDRONS, MELEE)
    r.row(PAULDRONS)
    start_write(r)
    r.go()
    assert r.entry(PAULDRONS) == 'Gear|Classes|' + '|'.join(MELEE) + '|NumberToLoot|99|'
    assert any('CLR cannot use it' in x for (_, _, x) in r.log())


@scenario
def s05_unticked_tier_skipped():
    """Tier unticked: logged as skipped, nothing written."""
    r = Run(settings={'tiers': ['Elegant']})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS)
    r.row(CLOAK)
    start_write(r)
    r.go()
    assert r.entry(CLOAK) is None
    assert 'Skipped' in r.results(CLOAK)


@scenario
def s06_unticked_family_skipped():
    """Family unticked: skipped."""
    r = Run(settings={'tiers': ['Transcendent'], 'fam': {'Adepts': False}})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS)
    r.row(CLOAK)
    start_write(r)
    r.go()
    assert r.entry(CLOAK) is None
    assert any("Family Adept's is unticked" in x for (_, _, x) in r.log())


@scenario
def s07_unrelated_item_ignored_silently():
    """An unrelated item is not logged and not written."""
    r = Run(settings={'tiers': ['Transcendent']})
    r.row('Rusty Dagger')
    start_write(r)
    r.go()
    assert r.results('Rusty Dagger') == [] and r.ini_cmds() == []


@scenario
def s08_existing_keep_kept_then_convert():
    """A Keep entry present at startup is kept; Convert replaces it and records the old value."""
    r = Run(loot_ini="[T]\n%s=Keep\n" % CLOAK, settings={'tiers': ['Transcendent']})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS)
    r.row(CLOAK)
    start_write(r)
    r.at(2000, lambda: r.H.press('Convert existing entries (1)##dl_conv'))
    r.at(2300, lambda: r.H.press('Confirm##Convert entries##dl_conv_pop'))
    r.go()
    assert r.entry(CLOAK) == CLOAK_RULE, r.entry(CLOAK)
    assert 'Existing rule kept' in r.results(CLOAK) and 'Converted' in r.results(CLOAK)
    led = r.lua.eval("package.loaded['defiantlooter.config'].storeAll('ledger')")
    assert led[CLOAK].previous == 'Keep'


@scenario
def s09_plugin_default_after_start_replaced():
    """Keep written by MQ2AutoLoot after startup is replaced automatically."""
    r = Run(settings={'tiers': ['Transcendent']})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS)
    start_write(r)

    def drop():
        r.H.iniWrite(r.loot, 'T', CLOAK, 'Keep')      # what MQ2AutoLoot does for a new item
        r.row(CLOAK)
    r.at(1000, drop)
    r.go()
    assert r.entry(CLOAK) == CLOAK_RULE
    led = r.lua.eval("package.loaded['defiantlooter.config'].storeAll('ledger')")
    assert led[CLOAK].previous == 'Keep'


@scenario
def s10_ignore_entry_never_converted():
    """An Ignore entry is kept and Convert leaves it alone."""
    r = Run(loot_ini="[T]\n%s=Ignore\n" % CLOAK, settings={'tiers': ['Transcendent']})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS)
    r.row(CLOAK)
    start_write(r)
    r.at(2000, lambda: r.H.press('Convert existing entries (1)##dl_conv'))
    r.at(2300, lambda: r.H.press('Confirm##Convert entries##dl_conv_pop'))
    r.go()
    assert r.entry(CLOAK) == 'Ignore'


@scenario
def s11_no_trade_skipped_by_default_included_when_ticked():
    """No Trade skipped by default; written when Include No Trade is ticked."""
    r = Run(settings={'tiers': ['Transcendent']})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS, nodrop=True)
    r.row(CLOAK)
    start_write(r)
    r.go()
    assert r.entry(CLOAK) is None
    r2 = Run(settings={'tiers': ['Transcendent'], 'extra': 'includeNoTrade = true'})
    r2.H.world.bags[CLOAK] = r2.spec(CLOAK, CASTERS, nodrop=True)
    r2.row(CLOAK)
    start_write(r2)
    r2.go()
    assert r2.entry(CLOAK) == CLOAK_RULE


@scenario
def s12_linkdb_lookup_reads_window_and_caches():
    """Unowned item: MQ2LinkDB link opens the item window, Class line read, window closed, cached."""
    r = Run(settings={'tiers': ['Transcendent']})
    r.H.world.linkdb[CLOAK] = r.spec(CLOAK, CASTERS)
    r.row(CLOAK)
    start_write(r)
    r.go()
    assert r.entry(CLOAK) == CLOAK_RULE
    assert any(c.startswith('/executelink LINK:') for c in r.H.cmds.values())
    assert r.H.world.closed == 1, 'window not closed'
    cache = r.lua.eval("package.loaded['defiantlooter.config'].storeAll('cache')")
    assert cache[CLOAK].source == 'linkdb'


@scenario
def s13_unresolved_retries_three_times_and_writes_nothing():
    """No source has the Class line: Undecided three times, no rule."""
    r = Run(settings={'tiers': ['Transcendent']})
    r.row(CLOAK)
    start_write(r)
    r.go(until=30000)
    assert r.entry(CLOAK) is None
    assert r.results(CLOAK).count('Undecided') == 3, r.results(CLOAK)


@scenario
def s14_retire_restores_previous_or_deletes():
    """Untick the tier, Retire: restored Keep for one, removed for the other."""
    r = Run(loot_ini="[T]\n%s=Keep\n" % CLOAK, settings={'tiers': ['Transcendent']})
    r.H.world.bags[CLOAK] = r.spec(CLOAK, CASTERS)
    r.H.world.bags[PAULDRONS] = r.spec(PAULDRONS, MELEE)
    r.row(CLOAK)
    r.row(PAULDRONS)
    start_write(r)
    r.at(1500, lambda: r.H.press('Convert existing entries (1)##dl_conv'))
    r.at(1800, lambda: r.H.press('Confirm##Convert entries##dl_conv_pop'))
    r.at(2500, lambda: r.H.toggle('Transcendent##dl_tier_Transcendent'))
    r.at(3000, lambda: r.H.press('Retire unticked (2)##dl_ret'))
    r.at(3300, lambda: r.H.press('Confirm##Retire rules##dl_ret_pop'))
    r.go()
    assert r.entry(CLOAK) == 'Keep', r.entry(CLOAK)
    assert r.entry(PAULDRONS) is None
    led = r.lua.eval("package.loaded['defiantlooter.config'].storeAll('ledger')")
    assert len(list(led.keys())) == 0


@scenario
def s15_item_type_groups():
    """Weapons unticked: weapon skipped, shield and armor written."""
    r = Run(settings={'tiers': ['Elegant'], 'extra': 'groups = { weapons = false, armor = true, shields = true }'})
    sword, shield, helm = 'Elegant Defiant Long Sword', 'Elegant Defiant Round Shield', 'Elegant Defiant Plate Helm'
    r.H.world.bags[sword] = r.spec(sword, MELEE, type='1H Slashing', slots={'primary': True, 'secondary': True})
    r.H.world.bags[shield] = r.spec(shield, MELEE, type='Shield', slots={'secondary': True})
    r.H.world.bags[helm] = r.spec(helm, MELEE, type='Armor')
    for n in (sword, shield, helm):
        r.row(n)
    start_write(r)
    r.go()
    assert r.entry(sword) is None and r.entry(shield) and r.entry(helm)


@scenario
def s16_curly_apostrophe_matches():
    """Typographic apostrophe in the name still matches Adept's."""
    name = 'Transcendent Adept\u2019s Cloak'
    r = Run(settings={'tiers': ['Transcendent']})
    r.H.world.bags[name] = r.spec(name, CASTERS)
    r.row(name)
    start_write(r)
    r.go()
    assert r.entry(name) == CLOAK_RULE


@scenario
def s17_near_miss_logged():
    """Tier word with an unknown second word is logged as Not matched."""
    r = Run(settings={'tiers': ['Elegant']})
    r.row('Elegant Silk Robe')
    r.at(200, lambda: r.H.press('Start##dl_start'))
    r.go()
    assert 'Not matched' in r.results('Elegant Silk Robe')


@scenario
def s18_settings_follow_other_box():
    """Another box ticks a tier in the shared file; this box picks it up."""
    r = Run(settings={'tiers': []})
    r.H.world.bags[BRACER] = r.spec(BRACER, ['WAR', 'CLR'])
    r.row(BRACER)
    start_write(r)
    r.at(2000, lambda: r.lua.execute(settings_lua(r.cfg, {'tiers': ['Simple']})))
    r.go(until=9000)
    assert r.entry(BRACER) == 'Gear|Classes|WAR|CLR|NumberToLoot|99|', r.entry(BRACER)


@scenario
def s19_learn_from_bags_preseeds():
    """Learn writes rules for owned matching gear with no loot window."""
    r = Run(settings={'tiers': ['Simple']})
    r.H.world.bags[BRACER] = r.spec(BRACER, ['WAR', 'CLR'])
    r.H.world.bags['Rusty Dagger'] = r.spec('Rusty Dagger', ['WAR'])
    r.at(200, lambda: r.H.toggle('Preview only##dl_preview'))
    r.at(500, lambda: r.H.press('Learn from my gear, bags and bank##dl_learn'))
    r.go()
    assert r.entry(BRACER) == 'Gear|Classes|WAR|CLR|NumberToLoot|99|'
    assert r.entry('Rusty Dagger') is None


@scenario
def s20_copies_setting_and_update_own_rule():
    """Copies changed to 2: our earlier rule is updated, previous kept as none."""
    r = Run(settings={'tiers': ['Simple']})
    r.H.world.bags[BRACER] = r.spec(BRACER, ['WAR', 'CLR'])
    r.row(BRACER)
    start_write(r)

    def two():
        r.H.inputs = r.lua.table(**{'Copies per exact item##dl_copies': 2})
    r.at(2000, two)
    r.go()
    assert r.entry(BRACER) == 'Gear|Classes|WAR|CLR|NumberToLoot|2|', r.entry(BRACER)
    led = r.lua.eval("package.loaded['defiantlooter.config'].storeAll('ledger')")
    assert led[BRACER].previous is None


@scenario
def s21_advloot_filter_warning():
    """Always Need set in EverQuest: rule written with a warning in the log."""
    r = Run(settings={'tiers': ['Simple']})
    r.H.world.bags[BRACER] = r.spec(BRACER, ['WAR', 'CLR'])
    r.row(BRACER, an=True)
    start_write(r)
    r.go()
    assert r.entry(BRACER)
    assert any('overrides MQ2AutoLoot' in x for (_, _, x) in r.log())


@scenario
def s22_pause_stops_scanning():
    """Items that drop after Pause are not decided."""
    r = Run(settings={'tiers': ['Simple']})
    r.H.world.bags[BRACER] = r.spec(BRACER, ['WAR', 'CLR'])
    start_write(r)
    r.at(1000, lambda: r.H.press('Pause##dl_pause'))
    r.at(1500, lambda: r.row(BRACER))
    r.go()
    assert r.entry(BRACER) is None and r.results(BRACER) == []


@scenario
def s23_preview_retire_writes_nothing():
    """Retire with Preview on only logs."""
    r = Run(settings={'tiers': ['Simple']})
    r.H.world.bags[BRACER] = r.spec(BRACER, ['WAR', 'CLR'])
    r.row(BRACER)
    start_write(r)
    r.at(1500, lambda: r.H.toggle('Preview only##dl_preview'))     # back on
    r.at(2000, lambda: r.H.toggle('Simple##dl_tier_Simple'))
    r.at(2500, lambda: r.H.press('Retire unticked (1)##dl_ret'))
    r.at(2800, lambda: r.H.press('Confirm##Retire rules##dl_ret_pop'))
    r.go()
    assert r.entry(BRACER) == 'Gear|Classes|WAR|CLR|NumberToLoot|99|'
    assert 'Would retire' in r.results(BRACER)


@scenario
def s24_imgui_stack_balanced_and_commands():
    """Window stack balanced on every frame; /dloot commands work."""
    r = Run(settings={'tiers': ['Simple']})
    r.H.world.bags[BRACER] = r.spec(BRACER, ['WAR', 'CLR'])
    r.row(BRACER)
    r.at(300, lambda: r.H.slash('tier elegant on'))
    r.at(400, lambda: r.H.slash('preview off'))
    r.at(500, lambda: r.H.slash('start'))
    r.at(900, lambda: r.H.slash('status'))
    r.at(1000, lambda: r.H.press('Set to 5##dl_delay'))
    r.go()
    assert r.H.frames > 10 and r.H.stackErrors == 0, (r.H.frames, r.H.stackErrors)
    assert r.entry(BRACER), 'start via command'
    assert r.entry('NewItemDelay') == '5', 'Set to 5'
    cfg = r.lua.eval("package.loaded['defiantlooter.config'].settings")
    assert cfg.tiers.Elegant is True


def main():
    """
    WHAT  : Runs every scenario and prints the report.
    WHY   : Entry point.
    WHERE : Bottom of this file.
    HOW   : Catches assertion and Lua errors per scenario.
    WHEN  : When run.
    """
    failed = 0
    for fn in SCENARIOS:
        try:
            fn()
            print('PASS', fn.__name__, '-', fn.__doc__.strip())
        except Exception as exc:      # report and continue
            failed += 1
            print('FAIL', fn.__name__, '-', fn.__doc__.strip(), '\n     ', repr(exc)[:600])
    print('%d of %d scenarios passed' % (len(SCENARIOS) - failed, len(SCENARIOS)))
    shutil.rmtree(ROOT, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()

# =============================================================================
#   END OF FILE : defiantlooter/dev/run_tests.py
#
#   HOW TO EDIT SAFELY
#     - One scenario per behaviour, with its docstring saying what it proves.
#     - Button labels in scenarios must match ui.lua exactly, including ##ids.
# =============================================================================
