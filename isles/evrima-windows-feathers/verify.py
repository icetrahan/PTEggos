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
# order matters: this is the order the install script writes them
FILES = ['Engine.ini.tmpl', 'Game.ini.tmpl', 'start-evrima.ps1']
# the sha256 of the *committed* (rcon-scrubbed) wrapper. The live one is
# 03479537eced420aa0f5a2317c3e41d63139f940ebcda04794e39d0c1d194cbf; they differ
# by one line, on purpose -- see README.md "Scrubbed values".
WRAPPER_SHA = '2c1a8aa395d0ff017fa1fd1c940d2d73f21c9f3ae2a177071ef6ce2b8a4c8c51'

egg = json.load(open(EGG, encoding='utf-8'))
install = egg['scripts']['installation']['script']
blobs = re.findall(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)", install)

ok = True
if len(blobs) != len(FILES):
    print(f'FAIL: expected {len(FILES)} embedded blobs, found {len(blobs)}')
    sys.exit(1)

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
for name in FILES:
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
