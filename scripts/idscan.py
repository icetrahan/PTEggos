#!/usr/bin/env python3
"""idscan.py — refuse id-shaped numbers and key-shaped strings BEFORE they land in a repo.

BACKLOG A264 (`audit-exposure`), BUGS #2451 (customer Steam64s in the trackers, rendered into a
published artifact), rule 10 (a live phdk_ key was pushed inside MOD_REFERENCE.md, 2026-07-22).
The standing rule is old and explicit: no customer Steam64, Discord user id or email in any committed
file; secrets by NAME only. Measured 2026-09-26: 1,452 distinct Steam64s in the meta repo, 87 in the
plane's tests, 28 in tenant_web's — every one written by a session doing the right thing (carrying its
proof) that did not mask on the way past. A rule nobody checks is a wish. This checks.

What it flags (each with a synthetic-by-shape rule, so fixtures do not need an allowlist entry):
  steam64     7656119 + 10 digits.   SYNTHETIC: below 76561197960265729 (an impossible account id) or
              the documented test tail 76561199999xxxxxx.
  snowflake   17-19 digits that DECODE to a Discord timestamp between 2015 and a year from now
              (a 19-digit ns timestamp or a 17-digit round number is not a snowflake).
              SYNTHETIC: <= 3 distinct digits, or a straight ascending/descending run.
  key         ptlc_/ptla_ (Ptero) - phsk_/phdk_/phck_ (ours) - sk_live_/sk_test_/rk_live_/whsec_ (Stripe)
              - gho_/ghp_/github_pat_ - xox?- (Slack) - AKIA (AWS) - re_ (Resend, 28+) - Discord
              webhook URLs - Discord bot tokens.   SYNTHETIC: a body of <= 2 distinct characters (xxxx...).
  A line carrying the marker `idscan-ok` or `scan-ok` is skipped (the marker sits next to the "secret",
  so a reviewer sees it). `.idscan-allow` at the repo root: one entry per line — a literal value, a glob
  on the value (`7650000000*`), or `path:<glob>` for whole files (fixtures that are synthetic by policy).

Modes (the gate scans ADDED LINES only, so history does not block today's commit — that backlog is the
audit's FIX list, measured with --full):
  --staged              pre-commit: the staged diff                     (.githooks/pre-commit)
  --diff-base <ref>     CI pull_request: added lines vs merge-base       (git diff -U0 <ref>...HEAD)
  --range <a>..<b>      CI push: added lines in that commit range
  --full [paths...]     every tracked file (the census); add --report to never fail
Exit: 0 clean - 1 findings (the gate) - 2 the tool could not do its job (rule 13: a scan that scanned
nothing says so and is never green). Findings are printed MASKED — this tool never echoes an id or key.
Stdlib only; runs the same on the workstation hook and on a GitHub runner.

Canonical copy: primal-everything-meta/scripts/idscan.py — product repos carry a verbatim copy.
"""
import argparse
import fnmatch
import os
import re
import subprocess
import sys
import time

STEAM64 = re.compile(r"(?<![0-9A-Za-z])(7656119\d{10})(?![0-9A-Za-z])")
SNOWFLAKE = re.compile(r"(?<![0-9A-Za-z._-])(\d{17,19})(?![0-9A-Za-z._-])")
KEY = re.compile(
    r"(ptlc_[A-Za-z0-9]{20,}|ptla_[A-Za-z0-9]{20,}|phsk_[A-Za-z0-9]{16,}|phdk_[A-Za-z0-9]{16,}"
    r"|phck_[A-Za-z0-9]{16,}|sk_live_[A-Za-z0-9]{20,}|sk_test_[A-Za-z0-9]{20,}|rk_live_[A-Za-z0-9]{20,}"
    r"|whsec_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"
    r"|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|re_[A-Za-z0-9]{28,}"
    r"|https://discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]{30,}"
    r"|[MN][A-Za-z0-9_-]{23,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,})")
MARKERS = ("idscan-ok", "scan-ok")
STEAM_FLOOR = 76561197960265729          # account id 1
STEAM_TEST_TAIL = re.compile(r"^76561199999\d{6}$")
DISCORD_EPOCH_MS = 1420070400000
SNOW_MIN_MS = 1420070400000              # 2015-01-01
SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".svg", ".pak", ".dll", ".exe", ".zip", ".7z",
            ".gz", ".tar", ".mp4", ".wav", ".mp3", ".ogg", ".ttf", ".otf", ".woff", ".woff2", ".pdf", ".bin",
            ".uasset", ".umap", ".so", ".pyc", ".lock", ".map", ".wasm", ".sqlite", ".db", ".pem"}
SKIP_DIRS = ("node_modules/", ".git/", "dist/", ".next/", "__pycache__/")
MAX_FILE_BYTES = 8_000_000


# ---------------------------------------------------------------- pure (tested)

def low_entropy(digits):
    if len(set(digits)) <= 3:
        return True
    steps = {(int(b) - int(a)) % 10 for a, b in zip(digits, digits[1:])}
    return steps in ({1}, {9})


def is_snowflake(value, now_ms=None):
    """True when a 17-19 digit number decodes to a plausible Discord timestamp."""
    now_ms = now_ms or int(time.time() * 1000)
    ts = (int(value) >> 22) + DISCORD_EPOCH_MS
    return SNOW_MIN_MS <= ts <= now_ms + 366 * 86400 * 1000


def synthetic_steam(value):
    return int(value) < STEAM_FLOOR or bool(STEAM_TEST_TAIL.match(value))


def synthetic_key(value):
    body = value.split("_", 1)[1] if "_" in value[:12] else value
    if value.startswith("https://"):
        body = value.rsplit("/", 1)[-1]
    return len(set(body)) <= 2


def load_allow(root):
    """.idscan-allow -> (value literals/globs, path globs). Missing file = empty allowlist."""
    values, paths = [], []
    try:
        with open(os.path.join(root, ".idscan-allow"), encoding="utf-8-sig") as fh:
            for raw in fh:
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                if line.startswith("path:"):
                    paths.append(line[5:].strip())
                else:
                    values.append(line)
    except OSError:
        pass
    return values, paths


def allowed_value(value, allow_values):
    return any(value == a or fnmatch.fnmatchcase(value, a) for a in allow_values)


def skip_path(path, allow_paths):
    p = path.replace("\\", "/")
    if any(seg in p for seg in SKIP_DIRS) or os.path.splitext(p)[1].lower() in SKIP_EXT:
        return True
    return any(fnmatch.fnmatchcase(p, g) or fnmatch.fnmatchcase(os.path.basename(p), g) for g in allow_paths)


def mask(kind, value):
    if kind == "key":
        head = value[:6] if not value.startswith("https://") else value[:40]
        return head + "...(%d chars)" % len(value)
    return value[:4] + "..." + value[-2:] + "(%dd)" % len(value)


def scan_line(line, allow_values=(), now_ms=None):
    """-> [(kind, masked)] for one text line. Pure; the seam every mode feeds."""
    if any(m in line for m in MARKERS):
        return []
    out = []
    keys = [m.group(1) for m in KEY.finditer(line)]
    for v in keys:
        if not synthetic_key(v) and not allowed_value(v, allow_values):
            out.append(("key", mask("key", v)))
    stripped = KEY.sub(" ", line)                      # a key body never doubles as an id
    steam = set()
    for m in STEAM64.finditer(stripped):
        v = m.group(1)
        steam.add(v)
        if not synthetic_steam(v) and not allowed_value(v, allow_values):
            out.append(("steam64", mask("steam64", v)))
    for m in SNOWFLAKE.finditer(stripped):
        v = m.group(1)
        if v in steam or low_entropy(v) or not is_snowflake(v, now_ms) or allowed_value(v, allow_values):
            continue
        out.append(("snowflake", mask("snowflake", v)))
    return out


def parse_added(diff_text):
    """git diff -U0 -> [(path, lineno, line)] for ADDED lines only."""
    rows, path, lineno = [], None, 0
    for raw in diff_text.split("\n"):
        if raw.startswith("+++ "):
            path = None if raw.startswith("+++ /dev/null") else raw[4:].strip()
            path = path[2:] if path and path.startswith("b/") else path
        elif raw.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", raw)
            lineno = int(m.group(1)) if m else 0
        elif raw.startswith("+") and not raw.startswith("+++") and path is not None:
            rows.append((path, lineno, raw[1:]))
            lineno += 1
        elif raw.startswith(" "):
            lineno += 1
    return rows


# ---------------------------------------------------------------- git + modes

def git(root, *args):
    r = subprocess.run(["git", "-C", root, *args], capture_output=True)
    if r.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args[:3]), r.stderr.decode("utf-8", "replace").strip()[:300]))
    return r.stdout.decode("utf-8", "replace")


def added_lines(root, mode, ref):
    common = ("diff", "-U0", "--no-color", "--no-ext-diff", "--diff-filter=AM")
    if mode == "staged":
        return git(root, *common, "--cached")
    if mode == "diff-base":
        return git(root, *common, ref + "...HEAD")
    if mode == "range":
        a, b = ref.split("..", 1)
        if not a.strip("0"):                           # push of a brand-new branch: before = 0000...
            root_commit = git(root, "rev-list", "--max-parents=0", b).split()[-1]
            return git(root, *common, root_commit, b)
        return git(root, *common, a, b)
    raise ValueError(mode)


def scan_rows(rows, allow_values, allow_paths):
    findings, seen = [], 0
    for path, lineno, line in rows:
        if skip_path(path, allow_paths):
            continue
        seen += 1
        for kind, masked in scan_line(line, allow_values):
            findings.append((path, lineno, kind, masked))
    return findings, seen


def full_rows(root, paths):
    files = git(root, "ls-files", "-z", "--", *paths).split("\0") if paths else git(root, "ls-files", "-z").split("\0")
    for f in files:
        if not f:
            continue
        p = os.path.join(root, f)
        try:
            if os.path.getsize(p) > MAX_FILE_BYTES:
                continue
            with open(p, "rb") as fh:
                text = fh.read().decode("utf-8", "replace")
        except OSError:
            continue
        for i, line in enumerate(text.split("\n"), 1):
            yield f, i, line


def main(argv=None):
    for s in (sys.stdout, sys.stderr):                 # Windows consoles default to cp1252
        if hasattr(s, "reconfigure"):
            s.reconfigure(errors="replace")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--staged", action="store_true")
    g.add_argument("--diff-base", metavar="REF")
    g.add_argument("--range", metavar="A..B")
    g.add_argument("--full", nargs="*", metavar="PATH")
    ap.add_argument("--root", default=None, help="repo root (default: git rev-parse --show-toplevel)")
    ap.add_argument("--report", action="store_true", help="never exit 1; print the census")
    ap.add_argument("--max-print", type=int, default=60)
    a = ap.parse_args(argv)
    try:
        root = a.root or git(".", "rev-parse", "--show-toplevel").strip()
        allow_values, allow_paths = load_allow(root)
        if a.full is not None:
            mode, rows = "full", full_rows(root, a.full)
        else:
            mode = "staged" if a.staged else ("diff-base" if a.diff_base else "range")
            rows = parse_added(added_lines(root, mode, a.diff_base or a.range))
        findings, seen = scan_rows(rows, allow_values, allow_paths)
    except (RuntimeError, ValueError, OSError) as e:
        print("idscan: ERROR - could not scan (%s). This is not a pass." % e)
        return 2
    by_kind = {}
    files = set()
    for path, lineno, kind, masked in findings:
        by_kind[kind] = by_kind.get(kind, 0) + 1
        files.add(path)
    for path, lineno, kind, masked in findings[:a.max_print]:
        print("  %s:%d  %-9s %s" % (path, lineno, kind, masked))
    if len(findings) > a.max_print:
        print("  ... %d more" % (len(findings) - a.max_print))
    summary = ", ".join("%s=%d" % kv for kv in sorted(by_kind.items())) or "none"
    print("idscan: mode=%s scanned=%d lines allow=%d values/%d paths findings=%d in %d file(s) [%s]%s"
          % (mode, seen, len(allow_values), len(allow_paths), len(findings), len(files), summary,
             " (REPORT ONLY - not a gate)" if a.report else ""))
    if findings and not a.report:
        print("idscan: REFUSED. Mask the id (7656119...NN / 1234...56), replace a fixture with a synthetic one "
              "(a Steam64 below 76561197960265729 is impossible, 76561199999xxxxxx is the test tail), "
              "or add `# idscan-ok` / an `.idscan-allow` entry WITH a reason. A key never gets an entry: rotate it.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
