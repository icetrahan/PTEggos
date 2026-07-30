#!/usr/bin/env python3
"""Discrimination test for egg 40's install gate (BUGS #346).

Extracts the REAL helper functions + terminal gate out of install.ps1, stubs only
the three probes that need the network/disk, and drives it through the states the
2026-07-28 incident and its neighbours actually produce.

The point is not "does exit 1 happen" - it is that each state gets its OWN class,
and that the state the old script called 'Install complete.' now fails.
"""
import io
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'install.ps1')
src = io.open(SRC, encoding='utf-8', newline='').read()
lines = src.split('\n')

# --- extract, failing loudly if the anchors moved -------------------------
try:
    f_start = next(i for i, l in enumerate(lines) if l.startswith('function Test-Tcp'))
    f_end = next(i for i, l in enumerate(lines) if l.startswith("Write-Output 'Downloading SteamCMD"))
    g_start = next(i for i, l in enumerate(lines) if 'TERMINAL GATE' in l)
except StopIteration:
    sys.exit('FAIL: anchors moved in install.ps1 - update gate_test.py deliberately')

funcs = '\n'.join(lines[f_start:f_end])
gate = '\n'.join(lines[g_start - 1:])          # include the banner line above
for needed in ('function Fail-Install', 'function Get-FreeGb', 'function Test-Dns'):
    if needed not in funcs:
        sys.exit('FAIL: %s not inside the extracted function block' % needed)
if 'INCOMPLETE-PULL' not in gate or "Write-Output 'Install complete.'" not in gate:
    sys.exit('FAIL: extracted gate is missing its own body')

HARNESS = """$ErrorActionPreference = 'Stop'
%(funcs)s
# --- stubs: the ONLY things replaced are the three environment probes ---
function Test-Tcp  { param([string]$Target,[int]$Port=443,[int]$TimeoutMs=6000)
  if ($Target -eq '1.1.1.1') { return $%(generic)s }
  return $%(steam)s }
function Test-Dns  { param([string]$Target) return $%(dns)s }
function Get-FreeGb { param([string]$PathOnDisk) return %(free)s }
# --- state under test ---
$root         = '%(root)s'
$game         = Join-Path $root 'server'
$launcherExe  = Join-Path $game 'TheIsleServer.exe'
$serverExe    = Join-Path $game 'TheIsle\\Binaries\\Win64\\TheIsleServer-Win64-Shipping.exe'
$bootstrapExit = 0
$steamExits    = @(%(exits)s)
$maxTries      = 5
%(gate)s
"""

# launcher: None = absent, int = size. shipping: same.
SCENARIOS = [
    # name,                      launcher, shipping,  generic, steam, dns,  free, exits,        expect_code, expect_class
    ('healthy install',          242176,   185213952, 'true',  'true','true', 400, '0,0',        0, 'Install complete.'),
    ('#346 verbatim: no outbound', None,   None,      'false', 'false','false', 400, '0,0,0,0,0', 1, 'NO-OUTBOUND'),
    ('partial pull (was "complete")', 242176, None,   'true',  'true','true', 400, '0,0,0,0,0',  1, 'INCOMPLETE-PULL'),
    ('truncated shipping binary',  242176, 0,         'true',  'true','true', 400, '0,0',        1, 'TRUNCATED-BINARY'),
    ('steam down, box online',     None,   None,      'true',  'false','true', 400, '0,0,0,0,0', 1, 'STEAM-UNREACHABLE'),
    ('dns broken',                 None,   None,      'true',  'false','false', 400, '0,0,0,0,0',1, 'DNS-BROKEN'),
    ('disk full',                  None,   None,      'true',  'true','true',   3, '0,0,0,0,0',  1, 'DISK-FULL'),
    ('steamcmd produced nothing',  None,   None,      'true',  'true','true', 400, '1,1,1,1,1',  1, 'STEAMCMD-FAILED'),
    ('unmeasurable disk is NOT full', 242176, None,   'true',  'true','true',  -1, '0,0',        1, 'INCOMPLETE-PULL'),
]

passed = failed = 0
for (name, launcher, shipping, generic, steam, dns, free, exits, exp_code, exp_class) in SCENARIOS:
    vol = tempfile.mkdtemp(prefix='egg40_')
    binwin = os.path.join(vol, 'server', 'TheIsle', 'Binaries', 'Win64')
    os.makedirs(binwin)
    if launcher is not None:
        with open(os.path.join(vol, 'server', 'TheIsleServer.exe'), 'wb') as fh:
            fh.write(b'\0' * launcher)
    if shipping is not None:
        with open(os.path.join(binwin, 'TheIsleServer-Win64-Shipping.exe'), 'wb') as fh:
            fh.write(b'\0' * min(shipping, 4096))   # size asserted below, not written in full
    ps = HARNESS % dict(funcs=funcs, gate=gate, root=vol.replace('\\', '\\\\'),
                        generic=generic, steam=steam, dns=dns, free=free, exits=exits)
    path = os.path.join(vol, 'harness.ps1')
    io.open(path, 'w', encoding='utf-8', newline='\r\n').write(ps)
    p = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path],
                       capture_output=True, text=True)
    out = (p.stdout or '') + (p.stderr or '')
    code_ok = p.returncode == exp_code
    class_ok = exp_class in out
    # a failing install must NEVER print the success line
    purity_ok = True
    if exp_code == 1 and "\nInstall complete." in out:
        purity_ok = False
    if code_ok and class_ok and purity_ok:
        passed += 1
        print('  ok    %-34s exit=%d  %s' % (name, p.returncode, exp_class))
    else:
        failed += 1
        print('  FAIL  %-34s exit=%d (want %d) class_seen=%s purity=%s'
              % (name, p.returncode, exp_code, class_ok, purity_ok))
        print('        ---- output ----')
        for l in out.strip().split('\n')[-25:]:
            print('        ' + l.rstrip())

print('\n%d/%d passed' % (passed, passed + failed))
sys.exit(0 if failed == 0 else 1)
