#!/usr/bin/env python3
"""Rebuild egg 40 (Evrima) as an importable PTDL_v2 JSON with the expanded config:
new Game.ini.tmpl + start-evrima.ps1 (base64-swapped into the original install
script) + 19 new gameplay egg variables on top of the existing 12."""
import base64, json, re, datetime, pathlib

here = pathlib.Path(__file__).parent
prim = here / "_primal"
install = (here / "install.ps1").read_text(encoding="utf-8")

def b64(p): return base64.b64encode((prim / p).read_bytes()).decode()

# swap the two payloads we changed (Engine.ini.tmpl is unchanged)
for name in ("Game.ini.tmpl", "start-evrima.ps1"):
    new = b64(name)
    pat = re.compile(re.escape(name) + r"'\),\s*\[Convert\]::FromBase64String\('([A-Za-z0-9+/=]+)'\)")
    m = pat.search(install)
    assert m, f"could not find install-script payload for {name}"
    install = install[:m.start(1)] + new + install[m.end(1):]
    print(f"  swapped {name} -> {len(new)} b64 chars")

# ── existing 12 variables (from egg 40) ──
existing = [
 ("Server Name","SERVER_NAME","Primal Heaven Evrima","required|string|max:80"),
 ("Auto Update","AUTO_UPDATE","1","required|string|in:0,1"),
 ("Max Players","MAX_PLAYERS","150","required|integer|between:1,300"),
 ("Password Protected","SERVER_PASSWORD_ENABLED","0","required|string|in:0,1"),
 ("Server Password","SERVER_PASSWORD","","nullable|string|max:64"),
 ("RCON Enabled","RCON_ENABLED","0","required|string|in:0,1"),
 # SANITISED on import to this public repo (2026-08-09, #1064): the unversioned
 # workspace copy shipped a real Primal Heaven RCON password as this default.
 # Canonical egg-40 and evrima-linux both use "" - match them, never a live value.
 ("RCON Password","RCON_PASSWORD","","nullable|string|max:64"),
 ("Discord URL","DISCORD_URL","https://discord.gg/primalheaven","nullable|string|max:120"),
 ("Corpse Decay Multiplier","CORPSE_DECAY","0.02","required|numeric"),
 ("Admin Steam64 IDs","ADMIN_STEAM_IDS","","nullable|string"),
 ("VIP Steam64 IDs","VIP_STEAM_IDS","","nullable|string"),
 ("Allowed Dino Classes","ALLOWED_CLASSES","","nullable|string"),
]
# ── 19 NEW gameplay knobs ──
new_vars = [
 ("Enable Humans","ENABLE_HUMANS","1","required|string|in:0,1"),
 ("Day Length (min)","SERVER_DAY_LENGTH","45","required|integer|between:1,240"),
 ("Night Length (min)","SERVER_NIGHT_LENGTH","20","required|integer|between:1,240"),
 ("Growth Multiplier","GROWTH_MULTIPLIER","1","required|numeric"),
 ("Global Chat","ENABLE_GLOBAL_CHAT","1","required|string|in:0,1"),
 ("Spawn AI","ENABLE_AI","0","required|string|in:0,1"),
 ("AI Density","AI_DENSITY","0","required|integer|between:0,10"),
 ("Spawn Fish","SPAWN_FISH","0","required|string|in:0,1"),
 ("Enable Mutations","ENABLE_MUTATIONS","1","required|string|in:0,1"),
 ("Enable Diets","ENABLE_DIETS","1","required|string|in:0,1"),
 ("Fall Damage","FALL_DAMAGE","1","required|string|in:0,1"),
 ("Allow Replay Recording","ALLOW_REPLAY","1","required|string|in:0,1"),
 ("Dynamic Weather","DYNAMIC_WEATHER","0","required|string|in:0,1"),
 ("Whitelist Enabled","WHITELIST_ENABLED","0","required|string|in:0,1"),
 ("Spawn Plants","SPAWN_PLANTS","0","required|string|in:0,1"),
 ("Plant Spawn Multiplier","PLANT_MULTIPLIER","0","required|numeric"),
 ("Enable Migration","ENABLE_MIGRATION","0","required|string|in:0,1"),
 ("Enable Mass Migration","ENABLE_MASS_MIGRATION","0","required|string|in:0,1"),
 ("Enable Patrol Zones","ENABLE_PATROL_ZONES","0","required|string|in:0,1"),
 # ── ops: update recovery + multihome ──
 ("Force Clean Update","FORCE_CLEAN_UPDATE","0","required|string|in:0,1"),        # 1 = delete /TheIsle/Binaries + /steamapps before update (fixes stuck Isle updates); reset to 0 after
 ("Multihome IP","MULTIHOME_IP","","nullable|string"),                            # bind/advertise a specific public IP (per-server DDoS isolation); blank = allocation SERVER_IP / all interfaces
 # ── Primal DLL mod (IsleModRebuild) auto-deploy ──
 ("Enable Primal Mod","ENABLE_PRIMAL_MOD","0","required|string|in:0,1"),          # 1 = download + inject IsleModRebuild.dll on boot
 ("Primal Mod Manifest","PRIMAL_MOD_MANIFEST","","nullable|string"),             # override the latest.json URL (blank = prod default)
 ("Server Key (phsk_)","PHSK_KEY","","nullable|string"),  # per-server data-plane key; set at provision time. Mod auths + fetches only THIS server's commands.
]
def var(name, env, default, rules):
    return {"name":name,"description":f"{name} (rendered into Game.ini each boot).",
            "env_variable":env,"default_value":default,"user_viewable":True,
            "user_editable":True,"rules":rules,"field_type":"text"}

egg = {
 "_comment":"PRIMAL HOSTED — The Isle: Evrima, expanded config (2026-07-10).",
 "meta":{"version":"PTDL_v2","update_url":None},
 "exported_at":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
 "name":"The Isle: Evrima (Windows / feathers)","author":"admin@primalhosted.com",
 "description":"The Isle EVRIMA dedicated server (app 412680 -beta evrima). Renders Game.ini every boot from egg variables incl. full gameplay knobs (day/night, growth, weather, AI, mutations, diets…) + admin/VIP Steam IDs + allowed-dino toggles.",
 "features":None,"docker_images":{"Windows SteamCMD":"windows/steamcmd"},"file_denylist":[],
 "startup":"powershell -NoProfile -ExecutionPolicy Bypass -File _primal\\start-evrima.ps1",
 "config":{"files":"{}","startup":"{\"done\": [\"Session started succesfully!\"]}","logs":"{}","stop":"^C"},
 "scripts":{"installation":{"script":install,"container":"windows/steamcmd","entrypoint":"powershell"}},
 "variables":[var(*v) for v in existing] + [var(*v) for v in new_vars],
}

# Ops/infra variables the CUSTOMER must not see or edit — the per-server data-plane
# key, mod controls, the clean-update button, and the multihome IP. Pterodactyl has no
# partial-mask, so admin-only = fully hidden + locked in the customer UI; admin (and AI)
# still manage them from the panel admin area. Everything else stays customer-editable.
ADMIN_ONLY = {"PHSK_KEY", "ENABLE_PRIMAL_MOD", "PRIMAL_MOD_MANIFEST", "FORCE_CLEAN_UPDATE", "MULTIHOME_IP"}
for v in egg["variables"]:
    if v["env_variable"] in ADMIN_ONLY:
        v["user_viewable"] = False
        v["user_editable"] = False
out = here / "egg40-evrima-updated.json"
out.write_text(json.dumps(egg, indent=4), encoding="utf-8")
print(f"wrote {out} ({out.stat().st_size} bytes)")
print(f"variables: {len(egg['variables'])} ({len(existing)} existing + {len(new_vars)} new)")
