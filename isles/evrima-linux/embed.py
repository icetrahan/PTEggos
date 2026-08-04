#!/usr/bin/env python3
"""embed.py - put the loose files back into install.sh, and install.sh back
into the egg JSON (the fixer; verify.py is the judge).

Two levels of nesting, same as egg 40:
    start-evrima.sh / Game.ini.tmpl / Engine.ini.tmpl
        -> base64 blobs inside install.sh (between B64_* heredoc markers,
           with a sha256 recorded beside each so the installer can verify
           its own decode)
        -> install.sh verbatim into egg-evrima-linux.json
           scripts.installation.script (through a real JSON parser - never
           a string splice).

Run after editing ANY loose file. Then run verify.py.
"""
import base64
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EGG_JSON = HERE / "egg-evrima-linux.json"
INSTALL = HERE / "install.sh"

# blob heredoc marker -> (loose file, sha placeholder token used at authoring time)
BLOBS = {
    "B64_START_EVRIMA": ("start-evrima.sh", "__SHA_START_EVRIMA__"),
    "B64_GAME_TMPL": ("Game.ini.tmpl", "__SHA_GAME_TMPL__"),
    "B64_ENGINE_TMPL": ("Engine.ini.tmpl", "__SHA_ENGINE_TMPL__"),
}


def wrap76(s: str) -> str:
    return "\n".join(s[i : i + 76] for i in range(0, len(s), 76))


def main() -> int:
    # LF-normalize the shell/tmpl sources first: they execute on Linux, and a
    # CR in Engine.ini.tmpl would end up inside the token (401).
    for fname, _ in BLOBS.values():
        p = HERE / fname
        raw = p.read_bytes()
        if b"\r" in raw:
            p.write_bytes(raw.replace(b"\r\n", b"\n").replace(b"\r", b"\n"))
            print(f"(embed) normalized CRLF -> LF in {fname}")

    text = INSTALL.read_text(encoding="utf-8")
    if "\r" in text:
        text = text.replace("\r\n", "\n").replace("\r", "\n")

    for marker, (fname, sha_token) in BLOBS.items():
        data = (HERE / fname).read_bytes()
        sha = hashlib.sha256(data).hexdigest()
        b64 = wrap76(base64.b64encode(data).decode("ascii"))

        # Replace the heredoc body: <<'MARKER'\n ... \nMARKER
        pat = re.compile(rf"(<<'{marker}'\n).*?(\n{marker}\n)", re.DOTALL)
        if not pat.search(text):
            print(f"ERROR: heredoc marker {marker} not found in install.sh")
            return 1
        text = pat.sub(lambda m: m.group(1) + b64 + m.group(2), text, count=1)

        # Replace the recorded sha (both the comment line and the write_blob
        # argument). First run replaces the authoring placeholder; later runs
        # replace the previous sha, located via the BLOB: comment line.
        if sha_token in text:
            text = text.replace(sha_token, sha)
        else:
            # BLOB:<fname> sha256=<old>   +   write_blob "...<fname>" "<old>"
            text = re.sub(
                rf"(# BLOB:{re.escape(fname)} sha256=)[0-9a-f]{{64}}",
                rf"\g<1>{sha}",
                text,
            )
            text = re.sub(
                rf'(write_blob "\$PRIM/{re.escape(fname)}" ")[0-9a-f]{{64}}(")',
                rf"\g<1>{sha}\g<2>",
                text,
            )
        print(f"(embed) {fname}: {len(data)} B, sha256 {sha[:16]}...")

    INSTALL.write_bytes(text.encode("utf-8"))
    print(f"(embed) install.sh rewritten ({len(text)} chars)")

    egg = json.loads(EGG_JSON.read_text(encoding="utf-8"))
    egg["scripts"]["installation"]["script"] = text
    EGG_JSON.write_text(
        json.dumps(egg, indent=4, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"(embed) egg JSON updated: {EGG_JSON.name}")
    print("(embed) done - now run verify.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
