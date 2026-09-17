"""Render-only harness for start-legacy.ps1 (PRIMAL_RENDER_ONLY=1).

    python render_test.py start-legacy.ps1 <old-wrapper.ps1>
      old-wrapper = the pre-2026-09-13 wrapper (`git show b178ae1:isles/legacy-windows-feathers/start-legacy.ps1 > old.ps1`)
      or ANY wrapper build you want the new one measured against.

Fixture: render_fixture_envs.json = the three live Legacy servers' egg variables as read from the
Ptero application API 2026-09-13 (secrets replaced by lengths; admin ids by a count). Server names
and MOTDs are public server-browser facts.

Scenarios per server (egg env from legacy_env.json, secrets stripped):
  A  OLD wrapper, egg vars                       -> the Game.ini the box renders TODAY
  B  NEW wrapper, served JSON (backfilled row)   -> what the plane will make it render
  C  NEW wrapper, plane UNREACHABLE, no cache     -> egg-var rung; must equal A and SAY so
  D  NEW wrapper, served JSON with the plane DEFAULTS (no backfill) -> shows what a
     missing backfill would change (evidence, not an assertion)
  E  NEW wrapper, served JSON where one value differs -> the diff line + Game.ini carry it
Exit 1 on any FAIL. Prints the verdict line last.
"""
import io, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
NEW = os.path.abspath(sys.argv[1])
OLD = os.path.abspath(sys.argv[2])
ENVJ = json.load(open(os.path.join(HERE, 'render_fixture_envs.json')))

CATALOG_FILES = {
    'UniversalGrouping': ['TheIsle-WindowsServer_zUniversalGrouping'],
    'DietGrouping': ['TheIsle-WindowsServer_zDietGrouping'],
    'HerbieGrouping': ['TheIsle-WindowsServer_zHerbieGrouping'],
    'UniversalDevColors': ['TheIsle-WindowsServer_UniversalDevColors'],
    'AnkyBonebreak': ['TheIsle-WindowsServer_zzAnkyBonebreak'],
    'PachyBoneBreak': ['TheIsle-WindowsServer_zPachyBoneBreak'],
    'EnhancedPara': ['TheIsle-WindowsServer_zEnhancedPara_DefaultGrouping', 'TheIsle-WindowsServer_zEnhancedPara_DietHerbieGrouping', 'TheIsle-WindowsServer_zEnhancedPara_UniversalGrouping'],
    'EnhancedAustro': ['TheIsle-WindowsServer_zzEnhancedAustro_DefaultGrouping', 'TheIsle-WindowsServer_zzEnhancedAustro_UniversalDietGrouping'],
    'EnhancedBary': ['TheIsle-WindowsServer_zzEnhancedBary_DefaultGrouping', 'TheIsle-WindowsServer_zzEnhancedBary_UniversalDietGrouping'],
    'ExtremeUtah': ['TheIsle-WindowsServer_zExtremeUtah_DefaultGrouping', 'TheIsle-WindowsServer_zExtremeUtah_DietUniversalGrouping'],
    'UtahGore': ['TheIsle-WindowsServer_zUtahGore_DefaultGrouping', 'TheIsle-WindowsServer_zUtahGore_DietUniversalGrouping'],
}

# the plane's server_settings defaults AFTER this change (must match CONFIG_DEFAULTS)
PLANE_DEFAULTS = {
    'serverName': '', 'maxPlayers': 150, 'serverPasswordEnabled': False, 'serverPassword': '',
    'rconEnabled': False, 'rconPassword': '', 'discordUrl': '', 'mapName': 'Gateway', 'queueEnabled': True,
    'adminSteamIds': [], 'vipSteamIds': [], 'allowedClasses': [], 'resolvedAdminSteamIds': [],
    'adminAllowSteamIds': [], 'adminDenySteamIds': [], 'whitelistEnabled': False, 'corpseDecay': 1,
    'enableHumans': True, 'dayLengthMin': 45, 'nightLengthMin': 20, 'growthMultiplier': 1,
    'enableGlobalChat': True, 'enableMutations': True, 'enableDiets': True, 'fallDamage': True,
    'dynamicWeather': False, 'enableAi': True, 'aiDensity': 0.25, 'aiSpawnInterval': '',
    'spawnFish': False, 'spawnPlants': False, 'plantMultiplier': 0, 'allowReplay': True,
    'enableMigration': True, 'enableMassMigration': True, 'enablePatrolZones': True,
    'legacyGameMode': 'Survival', 'legacyMap': 'Isle_V3', 'legacyMotd': '', 'legacyDisabledDinos': [],
    'legacyAllowChat': True, 'legacyNameTags': True, 'legacyGrowth': True, 'legacyTurnInPlace': True,
    'legacyNesting': True, 'legacyScent': False, 'legacyAiMax': 100, 'legacyAiRate': 1.5,
    'legacyAiPlayerSpawns': True, 'legacyDayLength': 30, 'legacyDynamicTime': False,
    'legacyStartingTime': 341, 'legacyDeadBodyTime': 200, 'legacyRespawnTime': 30, 'legacyLogoutTime': 60,
    'legacyFootprintLifetime': 60, 'legacyGroupingMod': 'none', 'legacyEnabledMods': [],
    'legacyBattleye': '', 'legacyExperimental': '', 'legacyTag': '', 'legacyDiscord': '',   # #2470 tri-state, '' = line omitted
}
# egg var -> (plane field, kind)
EGG_TO_PLANE = {
    'SERVER_NAME': ('serverName', 's'), 'MAX_PLAYERS': ('maxPlayers', 'n'), 'GAME_MODE': ('legacyGameMode', 's'),
    'MAP': ('legacyMap', 's'), 'MOTD': ('legacyMotd', 's'), 'DISABLED_DINOS': ('legacyDisabledDinos', 'l'),
    'ALLOW_CHAT': ('legacyAllowChat', 'b'), 'GLOBAL_CHAT': ('enableGlobalChat', 'b'), 'NAME_TAGS': ('legacyNameTags', 'b'),
    'GROWTH': ('legacyGrowth', 'b'), 'FALL_DAMAGE': ('fallDamage', 'b'), 'TURN_IN_PLACE': ('legacyTurnInPlace', 'b'),
    'ALLOW_REPLAY': ('allowReplay', 'b'), 'DEAD_BODY_TIME': ('legacyDeadBodyTime', 'n'), 'RESPAWN_TIME': ('legacyRespawnTime', 'n'),
    'LOGOUT_TIME': ('legacyLogoutTime', 'n'), 'FOOTPRINT_LIFETIME': ('legacyFootprintLifetime', 'n'), 'NESTING': ('legacyNesting', 'b'),
    'SCENT': ('legacyScent', 'b'), 'ENABLE_AI': ('enableAi', 'b'), 'AI_MAX': ('legacyAiMax', 'n'), 'AI_RATE': ('legacyAiRate', 'n'),
    'AI_PLAYER_SPAWNS': ('legacyAiPlayerSpawns', 'b'), 'STARTING_TIME': ('legacyStartingTime', 'n'), 'DYNAMIC_TIME': ('legacyDynamicTime', 'b'),
    'DAY_LENGTH': ('legacyDayLength', 'n'), 'GROUPING_MOD': ('legacyGroupingMod', 's'), 'ENABLED_MODS': ('legacyEnabledMods', 'l'),
    'BATTLEYE': ('legacyBattleye', 's'), 'EXPERIMENTAL': ('legacyExperimental', 's'), 'SERVER_TAG': ('legacyTag', 's'), 'SERVER_DISCORD': ('legacyDiscord', 's'),
}

def backfilled_row(env):
    row = dict(PLANE_DEFAULTS)
    for ev, (field, kind) in EGG_TO_PLANE.items():
        v = env.get(ev)
        if v is None: continue
        if kind == 's': row[field] = v
        elif kind == 'n': row[field] = float(v) if '.' in v else int(v)
        elif kind == 'b': row[field] = v in ('1', 'true', 'yes', 'on')
        elif kind == 'l': row[field] = [x.strip() for x in v.replace('\n', ',').split(',') if x.strip()]
    return row

def boot_config(row, admins):
    r = dict(row); r['adminSteamIds'] = admins
    return {'serverId': 0, 'config': {'server_settings': r, 'mod_settings': {}}, 'scope': {'server_settings': 'server', 'mod_settings': 'default'},
            'updatedAt': '2026-09-13T23:00:00.000Z', 'clamped': [], 'adminSources': {'hand': len(admins), 'resolved': 0, 'applied': len(admins)}}

def run(wrapper, env, extra_env, root):
    for d in ('server', '_primal'):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    mods = os.path.join(root, '_mods')
    for folder, files in CATALOG_FILES.items():
        os.makedirs(os.path.join(mods, folder), exist_ok=True)
        for f in files:
            for ext in ('pak', 'sig'):
                open(os.path.join(mods, folder, f + '.' + ext), 'wb').write(b'x')
    e = {k: v for k, v in os.environ.items() if not k.startswith('PRIMAL_') and k not in EGG_TO_PLANE and k not in ('PHSK_KEY', 'ADMIN_STEAM_IDS', 'SERVER_PASSWORD', 'SERVER_PORT', 'SERVER_PORT_1')}
    for k, v in env.items():
        if v is None: continue
        if k in ('SERVER_PASSWORD', 'PHSK_KEY', 'ADMIN_STEAM_IDS'): continue   # secrets never enter the harness
        e[k] = v
    e['ADMIN_STEAM_IDS'] = '76500000000000001,76500000000000002'  # synthetic ids for the egg rung
    e['PRIMAL_RENDER_ONLY'] = '1'
    e.update(extra_env)
    r = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', wrapper], cwd=root, env=e, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120)
    gi = os.path.join(root, 'server', 'TheIsle', 'Saved', 'Config', 'WindowsServer', 'Game.ini')
    motd = os.path.join(root, 'server', 'TheIsle', 'Saved', 'MOTD.txt')
    paks = sorted(os.listdir(os.path.join(root, 'server', 'TheIsle', 'Content', 'Paks'))) if os.path.isdir(os.path.join(root, 'server', 'TheIsle', 'Content', 'Paks')) else []
    return {'rc': r.returncode, 'out': r.stdout + r.stderr,
            'ini': io.open(gi, encoding='ascii', errors='replace').read() if os.path.exists(gi) else None,
            'motd': io.open(motd, encoding='utf-8-sig').read() if os.path.exists(motd) else None, 'paks': paks}

fails = []; n = 0
def ok(c, m):
    global n; n += 1
    print(('ok   ' if c else 'FAIL ') + m)
    if not c: fails.append(m)

for sid, s in ENVJ.items():
    env = s['env']
    print(f"\n== {sid} {s['name']} ==")
    row = backfilled_row(env)
    served = boot_config(row, ['76500000000000001', '76500000000000002'])
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, 'A')); os.makedirs(os.path.join(td, 'B')); os.makedirs(os.path.join(td, 'C')); os.makedirs(os.path.join(td, 'D')); os.makedirs(os.path.join(td, 'E'))
        A = run(OLD, env, {}, os.path.join(td, 'A'))
        jb = os.path.join(td, 'served.json'); json.dump(served, open(jb, 'w'))
        B = run(NEW, env, {'PRIMAL_BOOT_CONFIG_FILE': jb}, os.path.join(td, 'B'))
        C = run(NEW, env, {'PHSK_KEY': 'phsk_synthetic_not_a_real_key', 'PRIMAL_DATA_BASE': 'http://127.0.0.1:9'}, os.path.join(td, 'C'))
        jd = os.path.join(td, 'defaults.json'); json.dump(boot_config(dict(PLANE_DEFAULTS), ['76500000000000001', '76500000000000002']), open(jd, 'w'))
        D = run(NEW, env, {'PRIMAL_BOOT_CONFIG_FILE': jd}, os.path.join(td, 'D'))
        row2 = dict(row); row2['legacyDeadBodyTime'] = 999; row2['legacyMap'] = 'Thenyaw' if row['legacyMap'] != 'Thenyaw' else 'Isle_V3'; row2['legacyEnabledMods'] = ['AnkyBonebreak']; row2['legacyGroupingMod'] = 'universal'
        row2['legacyBattleye'] = 'true'; row2['legacyExperimental'] = 'false'; row2['legacyTag'] = '0'; row2['legacyDiscord'] = 'https://discord.gg/noobz'   # #2470: set on E only
        je = os.path.join(td, 'edited.json'); json.dump(boot_config(row2, ['76500000000000001', '76500000000000002']), open(je, 'w'))
        E = run(NEW, env, {'PRIMAL_BOOT_CONFIG_FILE': je}, os.path.join(td, 'E'))

    for name, R in (('A', A), ('B', B), ('C', C), ('D', D), ('E', E)):
        ok(R['rc'] == 0 and R['ini'] is not None, f'{name}: wrapper exited 0 and rendered Game.ini (rc={R["rc"]})')
    ok(A['ini'] == B['ini'], 'B == A: served (backfilled) row renders the SAME Game.ini as the old wrapper from egg vars')
    if A['ini'] != B['ini']:
        import difflib; print('\n'.join(difflib.unified_diff(A['ini'].splitlines(), B['ini'].splitlines(), 'A-old-eggvars', 'B-new-served', lineterm='')))
    ok(A['motd'] == B['motd'], 'B == A: MOTD identical')
    ok(A['paks'] == B['paks'], f'B == A: mod paks identical ({len(A["paks"])} files)')
    ok(A['ini'] == C['ini'] and A['motd'] == C['motd'] and A['paks'] == C['paks'], 'C == A: plane unreachable + no cache renders the egg vars (Game.ini, MOTD, paks identical)')
    ok('DATA PLANE UNREACHABLE AND NO CACHE - RENDERING EGG VARIABLES' in C['out'], 'C: the log SAYS the egg-var rung was used')
    ok('rendered Legacy Game.ini from eggvars' in C['out'], 'C: the render line names its source (eggvars)')
    ok('rendered Legacy Game.ini from file' in B['out'] and 'TEST HATCH' in B['out'], 'B: the render line names its source (file) and the hatch shouted')
    ok('ServerDeadBodyTime=999' in E['ini'], 'E: an edited plane value reaches Game.ini')
    # #2470 - the four tri-state keys: absent from A/B/C/D (unset = no line), present on E, Discord trimmed to its code
    for R, nm in ((A, 'A'), (B, 'B'), (C, 'C'), (D, 'D')):
        ok(all(k not in R['ini'] for k in ('bServerBattleye=', 'bServerExperimental=', 'ServerTag=', 'ServerDiscord=')), f'{nm}: no session-extra line when the keys are unset (#2470)')
    for want in ('bServerBattleye=true', 'bServerExperimental=false', 'ServerTag=0', 'ServerDiscord=noobz'):
        ok(want in E['ini'].splitlines(), f'E: `{want}` rendered from the plane (#2470)')
    ok('ServerDiscord=https' not in E['ini'], 'E: a pasted discord.gg URL is trimmed to the invite code')
    ok('session-extras=battleye+experimental+tag+discord' in E['out'], 'E: the render line names the session extras it rendered')
    ok('session-extras=none' in B['out'], 'B: the render line says none when nothing is set')
    ok('legacyDeadBodyTime egg=[' in E['out'], 'E: the superseded-egg-var NOTE names the changed key')
    ok(any('zzAnkyBonebreak' in p for p in E['paks']) and any('zUniversalGrouping' in p for p in E['paks']), 'E: the plane mod list drives the pak sync (Anky + Universal grouping installed)')
    ok(not any('EnhancedPara' in p for p in E['paks']), 'E: a mod dropped from the plane list is removed from Paks')
    ok('ServerAdmins=76500000000000001' in B['ini'], 'B: served admins rendered')
    ok(f"map={env['MAP']} " in B['out'] and f"mode={env['GAME_MODE']} " in B['out'], 'B: the launch map + mode come from the served row (not in Game.ini - read off the config line)')
    ok(f"(render-only) done source=file map=" in B['out'], 'B: the render-only line reports its source')
    # D is evidence only
    changed = [l for l in D['ini'].splitlines() if l not in A['ini'].splitlines()]
    print(f'   D (plane DEFAULTS, no backfill) would change {len(changed)} Game.ini line(s) on this server: ' + '; '.join(changed[:6]))
    print('   B log tail:'); print('\n'.join('     ' + l for l in B['out'].splitlines() if l.startswith('(config)') or l.startswith('(admins)') or l.startswith('(mods)')))

print(f'\nVERDICT: {n - len(fails)}/{n} passed' + ('' if not fails else ' — FAILS: ' + ' | '.join(fails)))
sys.exit(1 if fails else 0)
