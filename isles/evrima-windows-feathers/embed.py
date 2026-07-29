#!/usr/bin/env python3
"""Re-embed the loose wrapper/template files into the egg JSON's install script.

The install script writes start-evrima.ps1 / Game.ini.tmpl / Engine.ini.tmpl from
base64 blobs held inside `scripts.installation.script`. Editing the loose files is
the reviewable half; this puts them back into the blob that actually ships.

    python isles/evrima-windows-feathers/embed.py          # rewrite the JSON
    python isles/evrima-windows-feathers/embed.py --check   # report drift, write nothing

Then run verify.py, which is the gate (this script is the fixer, that one is the
judge -- never trust this script's own word that it worked).

Why this exists: the blob was hand-pasted before, and a 73 KB single-line JSON
string is not something a human can edit safely. It also updates verify.py's
recorded WRAPPER_SHA, which otherwise silently drifts into a "note" nobody acts on.

The JSON is rewritten through json.dump, so the install script's own escaping
(newlines, quotes, backslashes) is handled by the parser rather than by regex.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EGG = os.path.join(HERE, 'egg-evrima-windows-feathers.json')
VERIFY = os.path.join(HERE, 'verify.py')
# order matters: the order the install script writes them, same as verify.py
FILES = ['Engine.ini.tmpl', 'Game.ini.tmpl', 'start-evrima.ps1']
B64_RE = re.compile(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)")

ap = argparse.ArgumentParser()
ap.add_argument('--check', action='store_true', help='report drift, change nothing')
args = ap.parse_args()

with open(EGG, encoding='utf-8') as fh:
    egg = json.load(fh)
install = egg['scripts']['installation']['script']

found = B64_RE.findall(install)
if len(found) != len(FILES):
    print(f'FAIL: expected {len(FILES)} embedded blobs, found {len(found)}')
    sys.exit(1)

wanted = []
for name in FILES:
    with open(os.path.join(HERE, name), 'rb') as fh:
        raw = fh.read()
    wanted.append((name, raw, base64.b64encode(raw).decode('ascii')))

drift = [n for (n, _, b64), old in zip(wanted, found) if b64 != old]
for (name, raw, b64), old in zip(wanted, found):
    state = 'DRIFT' if b64 != old else 'ok   '
    print(f'{state} {name:<18} {len(raw):>6} B  sha256={hashlib.sha256(raw).hexdigest()}')

if args.check:
    print(f'{len(drift)} file(s) drifted' if drift else 'no drift')
    sys.exit(1 if drift else 0)

if not drift:
    print('no drift - egg JSON already matches the loose files, nothing written')
    sys.exit(0)

# Replace each blob positionally so a file whose base64 happens to be a substring
# of another cannot be swapped in for the wrong one.
out, cursor = [], 0
for (name, _raw, b64), match in zip(wanted, B64_RE.finditer(install)):
    out.append(install[cursor:match.start(1)])
    out.append(b64)
    cursor = match.end(1)
out.append(install[cursor:])
egg['scripts']['installation']['script'] = ''.join(out)

# ensure_ascii=True (the default) is DELIBERATE: the egg as exported by Ptero escapes
# non-ASCII as \uXXXX, and writing it back literally would touch unrelated lines (the
# description's ellipsis) for no reason. The diff must stay confined to the blob we
# actually changed, so a reviewer can see the whole change.
with open(EGG, 'w', encoding='utf-8', newline='\n') as fh:
    json.dump(egg, fh, indent=4, ensure_ascii=True)
    fh.write('\n')
print(f'rewrote {os.path.basename(EGG)}: re-embedded {", ".join(drift)}')

# Keep verify.py's recorded wrapper sha honest, so drift is a hard FAIL rather than
# an advisory note that survives three sessions.
wrapper_sha = hashlib.sha256(
    open(os.path.join(HERE, 'start-evrima.ps1'), 'rb').read()).hexdigest()
src = open(VERIFY, encoding='utf-8').read()
new_src, n = re.subn(r"WRAPPER_SHA = '[0-9a-f]{64}'",
                     f"WRAPPER_SHA = '{wrapper_sha}'", src)
if n == 1 and new_src != src:
    open(VERIFY, 'w', encoding='utf-8', newline='\n').write(new_src)
    print(f'updated verify.py WRAPPER_SHA -> {wrapper_sha}')
elif n != 1:
    print('WARNING: could not find WRAPPER_SHA in verify.py - update it by hand')

print('\nnow run:  python isles/evrima-windows-feathers/verify.py')
