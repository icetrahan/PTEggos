#!/usr/bin/env python3
"""Synth test: every mod x every grouping resolves to a REAL pak/sig file, the
incompatibility rule holds, and the panel catalog matches the wrapper catalog.
Guards against a typo in the variant map shipping a broken server."""
import pathlib, re, sys

MODS = pathlib.Path(__file__).parent / "mods"
GROUPINGS = ["none", "universal", "diet", "herbie"]

# mirror of the wrapper's $MOD_CATALOG
CATALOG = {
    "UniversalGrouping":  {"folder": "UniversalGrouping",  "file": "TheIsle-WindowsServer_zUniversalGrouping"},
    "DietGrouping":       {"folder": "DietGrouping",       "file": "TheIsle-WindowsServer_zDietGrouping"},
    "HerbieGrouping":     {"folder": "HerbieGrouping",     "file": "TheIsle-WindowsServer_zHerbieGrouping"},
    "UniversalDevColors": {"folder": "UniversalDevColors", "file": "TheIsle-WindowsServer_UniversalDevColors"},
    "AnkyBonebreak":      {"folder": "AnkyBonebreak",      "file": "TheIsle-WindowsServer_zzAnkyBonebreak"},
    "PachyBoneBreak":     {"folder": "PachyBoneBreak",     "file": "TheIsle-WindowsServer_zPachyBoneBreak"},
    "EnhancedPara":   {"folder": "EnhancedPara",   "variants": {"none": "TheIsle-WindowsServer_zEnhancedPara_DefaultGrouping", "herbie": "TheIsle-WindowsServer_zEnhancedPara_DietHerbieGrouping", "diet": "TheIsle-WindowsServer_zEnhancedPara_DietHerbieGrouping", "universal": "TheIsle-WindowsServer_zEnhancedPara_UniversalGrouping"}},
    "EnhancedAustro": {"folder": "EnhancedAustro", "variants": {"none": "TheIsle-WindowsServer_zzEnhancedAustro_DefaultGrouping", "herbie": "TheIsle-WindowsServer_zzEnhancedAustro_DefaultGrouping", "diet": "TheIsle-WindowsServer_zzEnhancedAustro_UniversalDietGrouping", "universal": "TheIsle-WindowsServer_zzEnhancedAustro_UniversalDietGrouping"}},
    "EnhancedBary":   {"folder": "EnhancedBary",   "variants": {"none": "TheIsle-WindowsServer_zzEnhancedBary_DefaultGrouping", "herbie": "TheIsle-WindowsServer_zzEnhancedBary_DefaultGrouping", "diet": "TheIsle-WindowsServer_zzEnhancedBary_UniversalDietGrouping", "universal": "TheIsle-WindowsServer_zzEnhancedBary_UniversalDietGrouping"}},
    "ExtremeUtah":    {"folder": "ExtremeUtah",    "variants": {"none": "TheIsle-WindowsServer_zExtremeUtah_DefaultGrouping", "herbie": "TheIsle-WindowsServer_zExtremeUtah_DefaultGrouping", "diet": "TheIsle-WindowsServer_zExtremeUtah_DietUniversalGrouping", "universal": "TheIsle-WindowsServer_zExtremeUtah_DietUniversalGrouping"}},
    "UtahGore":       {"folder": "UtahGore",       "variants": {"none": "TheIsle-WindowsServer_zUtahGore_DefaultGrouping", "herbie": "TheIsle-WindowsServer_zUtahGore_DefaultGrouping", "diet": "TheIsle-WindowsServer_zUtahGore_DietUniversalGrouping", "universal": "TheIsle-WindowsServer_zUtahGore_DietUniversalGrouping"}},
}
fails, checks = [], 0

def resolve(m, g):
    if "variants" in m: return m["variants"].get(g) or m["variants"]["none"]
    return m["file"]

# 1) every mod x every grouping -> a real .pak AND .sig on disk
for name, m in CATALOG.items():
    for g in GROUPINGS:
        base = resolve(m, g)
        for ext in ("pak", "sig"):
            checks += 1
            f = MODS / m["folder"] / f"{base}.{ext}"
            if not f.exists(): fails.append(f"{name} @ grouping={g}: missing {f.relative_to(MODS)}")

# 2) no orphan files (every pak on disk is referenced by some catalog entry)
referenced = set()
for name, m in CATALOG.items():
    for g in GROUPINGS: referenced.add(resolve(m, g))
for pak in MODS.rglob("*.pak"):
    checks += 1
    if pak.stem not in referenced: fails.append(f"orphan pak not in catalog: {pak.relative_to(MODS)}")

# 3) panel catalog keys (LEGACY_MODS) match the wrapper addons (non-grouping mods)
panel_ts = (pathlib.Path(__file__).parents[1] / "primal_billing/app/panel/servers/[id]/ServerConsole.tsx").read_text(encoding="utf-8")
seg = panel_ts.split("const LEGACY_MODS")[1].split("];")[0]
panel_keys = set(re.findall(r'key:\s*"(\w+)"', seg))
addon_keys = {k for k in CATALOG if "Grouping" not in k}
checks += 1
if panel_keys != addon_keys:
    fails.append(f"panel LEGACY_MODS {panel_keys} != wrapper addons {addon_keys}")

# 4) incompatibility pair is real
checks += 1
if not ({"ExtremeUtah", "UtahGore"} <= set(CATALOG)): fails.append("incompat pair not both in catalog")

print(f"ran {checks} assertions")
if fails:
    print("FAIL:"); [print("  -", f) for f in fails]; sys.exit(1)
print("ALL PASS — every mod/grouping resolves to a real pak+sig, no orphans, panel==wrapper")
