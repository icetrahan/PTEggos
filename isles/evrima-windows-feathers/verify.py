#!/usr/bin/env python3
"""Prove the extracted files still match the base64 blobs inside the egg JSON.

The install script writes start-evrima.ps1 / Game.ini.tmpl / Engine.ini.tmpl from
embedded base64. The loose copies next to this script exist only so those blobs
are reviewable -- which is worth nothing if the two drift. Run this after any
change to either representation.

    python isles/evrima-windows-feathers/verify.py

Exits non-zero on drift, on a secret leak, or if the JSON no longer parses.
"""
import base64
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EGG = os.path.join(HERE, 'egg-evrima-windows-feathers.json')
INSTALL = os.path.join(HERE, 'install.ps1')
# order matters: this is the order the install script writes them
FILES = ['Engine.ini.tmpl', 'Game.ini.tmpl', 'start-evrima.ps1']
# the sha256 of the *committed* (rcon-scrubbed) wrapper. The live one differs by
# one line, on purpose -- see README.md "Scrubbed values". Updated for the pak
# deploy lane (BUILD 39, #411): the DLL lane was replaced by the pak lane, the
# sig-bypass drop was added, and Engine.ini now carries the mod's session block.
WRAPPER_SHA = '0cec5d848761854e1b9e0f53f949781a341e2dedcce948a1e094465d5ad568c6'

egg = json.load(open(EGG, encoding='utf-8'))
install = egg['scripts']['installation']['script']
blobs = re.findall(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)", install)

ok = True
if len(blobs) != len(FILES):
    print(f'FAIL: expected {len(FILES)} embedded blobs, found {len(blobs)}')
    sys.exit(1)

# --- the install script itself ------------------------------------------------
# It is a loose file for the same reason the wrapper is: an 80 KB single-line JSON
# string cannot be reviewed. Prove the shipped copy still equals the reviewable one.
loose_install = open(INSTALL, encoding='utf-8', newline='').read()
if loose_install == install:
    print(f'ok    {"install.ps1":<18} {len(loose_install.encode("utf-8")):>6} B  '
          f'sha256={hashlib.sha256(loose_install.encode("utf-8")).hexdigest()}')
else:
    ok = False
    print(f'FAIL  install.ps1        differs from the egg JSON install script '
          f'({len(loose_install)} chars vs {len(install)} chars) -> run embed.py')

# The install script runs on the feathers node under the same CP1252 decode as the
# wrapper, so the same ASCII-only rule applies (BUGS #448 killed a boot this way).
non_ascii = [(i, l) for i, l in enumerate(loose_install.split('\n'), 1)
             if any(ord(c) > 127 for c in l)]
if non_ascii:
    ok = False
    print(f'FAIL  install.ps1 has {len(non_ascii)} non-ASCII line(s), first at '
          f'line {non_ascii[0][0]} -- PS 5.1 decodes those as quote chars')

# --- BUGS #346 regression pins ------------------------------------------------
# The install script reported 'Install complete.' with exit 0 after five failed
# steamcmd attempts and no game files, and it checked the 0.23 MB thin launcher
# instead of the 177 MB binary start-evrima.ps1 actually launches. Ice made both an
# explicit customer-#3 onboarding gate. A comment saying "don't undo this" has
# already failed elsewhere in this workspace, so the properties are asserted.
GATE_EXE = 'TheIsle\\Binaries\\Win64\\TheIsleServer-Win64-Shipping.exe'
if GATE_EXE not in loose_install:
    ok = False
    print(f'FAIL  install.ps1 no longer gates on {GATE_EXE} (#346) -- the root '
          f'TheIsleServer.exe is a 0.23 MB launcher and proves nothing')
if not re.search(r'^\s*exit 1\s*$', loose_install, re.M):
    ok = False
    print('FAIL  install.ps1 has no failing exit path (#346) -- a missing binary '
          'must exit 1 so the panel marks the install failed')
# Exactly one reachable success line. Two would mean a path prints it on the way to
# a failure; zero would mean a healthy install never reports itself.
success_lines = re.findall(r"^\s*Write-Output 'Install complete\.'\s*$",
                           loose_install, re.M)
if len(success_lines) != 1:
    ok = False
    print(f'FAIL  install.ps1 has {len(success_lines)} executable '
          f"\"Install complete.\" lines, expected exactly 1 (#346)")

for name, b64 in zip(FILES, blobs):
    embedded = base64.b64decode(b64)
    on_disk = open(os.path.join(HERE, name), 'rb').read()
    sha = hashlib.sha256(on_disk).hexdigest()
    if embedded == on_disk:
        print(f'ok    {name:<18} {len(on_disk):>6} B  sha256={sha}')
    else:
        ok = False
        print(f'FAIL  {name:<18} embedded blob != file on disk '
              f'({len(embedded)} B vs {len(on_disk)} B)')

wrapper_sha = hashlib.sha256(
    open(os.path.join(HERE, 'start-evrima.ps1'), 'rb').read()).hexdigest()
if wrapper_sha != WRAPPER_SHA:
    print(f'note  start-evrima.ps1 sha256 moved off the recorded value\n'
          f'      recorded {WRAPPER_SHA}\n      actual   {wrapper_sha}\n'
          f'      -> update WRAPPER_SHA here and the shas in README.md')

# rule 10: no secret VALUES in repo files. phsk_ appears as the PHSK_KEY
# variable's *name* ("Server Key (phsk_)"), so it is not swept for here.
blob = open(EGG, encoding='utf-8').read()
for name in FILES + ['install.ps1']:
    blob += open(os.path.join(HERE, name), encoding='utf-8', errors='replace').read()
for pat in ('phdk_', 'ptlc_', 'ptla_'):
    if pat in blob:
        ok = False
        print(f'FAIL  secret prefix {pat} present in a committed file')
if re.search(r'RconPassword\s*=\s*\'(?!CHANGEME\')', blob):
    ok = False
    print("FAIL  start-evrima.ps1 RconPassword fallback is not the placeholder")

print('PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
