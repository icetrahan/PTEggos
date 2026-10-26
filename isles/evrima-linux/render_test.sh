#!/bin/bash
# render_test.sh - prove the CANONICAL CONFIG actually reaches Game.ini and the
# pak's Engine.ini section on THIS egg.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS. Until 2026-09-05 this egg rendered Game.ini from EGG
# VARIABLES while the panel wrote the DATA PLANE (it stopped writing egg
# variables on 2026-08-10). Every one of the panel's 42 canonical fields
# returned a green 200 and changed nothing on the server. Nothing in either repo
# showed it, because each half was internally consistent - the only place the
# gap was visible is where the two meet, which is this file.
#
# It is a CONSUMER test: it asserts the bytes the GAME would read, never that a
# function returned something (hard rule 13, and [[readback-is-not-evidence]]).
#
# ⭐ THE PRE-FIX CONTROL. Run it against the wrapper as it shipped and it must
# FAIL - that failure is the evidence the lane was dead:
#
#     git show 887e576:isles/evrima-linux/start-evrima.sh > /tmp/old.sh
#     ./render_test.sh /tmp/old.sh          # expected: FAIL
#     ./render_test.sh ./start-evrima.sh    # expected: PASS
#
# HOW TO RUN. Inside the egg's OWN runtime image, so the shell, coreutils and
# curl are the ones a real boot uses:
#
#     docker run --rm --network none \
#       -v "$PWD:/egg:ro" -v "$PWD/.rt:/work" \
#       --entrypoint /bin/bash ghcr.io/icetrahan/steamcmd:debian \
#       /egg/render_test.sh /egg/start-evrima.sh
#
# It needs `_primal/jq` alongside it (the same pinned static build the wrapper
# fetches) at $JQ_BIN, default /work/jq.
# ─────────────────────────────────────────────────────────────────────────────
set -u
WRAPPER="${1:-$(dirname "$0")/start-evrima.sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
JQ_BIN="${JQ_BIN:-/work/jq}"
PASS=0; FAIL=0
# One folder per run, removed on exit: each case writes a 160 MB binary, which is not sparse on every filesystem.
RUN_T="$(mktemp -d "${TMPDIR:-/tmp}/render-test.XXXXXX")"
trap 'rm -rf "$RUN_T"' EXIT

ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
want() { # $1 label, $2 needle, $3 file
    if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1  (missing: $2)"; fi
}
nowant() { # $1 label, $2 needle, $3 file
    if grep -qF -- "$2" "$3" 2>/dev/null; then bad "$1  (present but must not be: $2)"; else ok "$1"; fi
}
wantline() { # $1 label, $2 the whole line, $3 file
    if tr -d '\r' < "$3" 2>/dev/null | grep -qxF -- "$2"; then ok "$1"; else bad "$1  (no line: $2)"; fi
}
session_body() { # the lines of the game-session section of $1
    awk '/^\[/ { on = ($0 == "[/script/theisle.tigamesession]"); next } on' "$1"
}
fleet_lines() { grep -cE '^[[:space:]]*(MassMigrationDisableTime|IndividualPatrolTime)[[:space:]]*=' "$1"; }
fleet_ok() { # $1 = Game.ini: both fleet constants in the game-session section, and no other line of either key
    [ "$(session_body "$1" | grep -cxE 'MassMigrationDisableTime=2700|IndividualPatrolTime=300')" = "2" ] \
        && [ "$(fleet_lines "$1")" = "2" ]
}

# ── the fixture. Every value is deliberately DIFFERENT from both the wrapper's
# built-in default AND the egg variable set below, so any of the three possible
# sources is distinguishable in the output.
render() { # $1 = tag, $2 = "canon" | "nocanon", $3.. = extra NAME=VALUE for the wrapper's env
    local T="$RUN_T/rt-$1"
    rm -rf "$T"; mkdir -p "$T/_primal" "$T/canon/v1" "$T/TheIsle/Binaries/Linux"
    cp "$WRAPPER" "$T/_primal/start-evrima.sh"
    cp "$HERE/Game.ini.tmpl" "$HERE/Engine.ini.tmpl" "$T/_primal/"
    cp "$JQ_BIN" "$T/_primal/jq"; chmod +x "$T/_primal/jq"
    [ "$2" = "canon" ] && cp "$HERE/boot-config.fixture.json" "$T/canon/v1/boot-config"
    # Section 4's two template states: no game-session header, and a hand-set line.
    [ "${RT_NO_SESSION:-}" = "1" ] && sed -i 's#^\[/script/theisle\.tigamesession\]#[/script/theisle.somethingelse]#' "$T/_primal/Game.ini.tmpl"
    [ -n "${RT_TMPL_EXTRA:-}" ] && sed -i "s#^bEnablePatrolZones=.*#&\n${RT_TMPL_EXTRA}#" "$T/_primal/Game.ini.tmpl"
    # The wrapper refuses to boot with no binary, and refuses one under 150 MB.
    # Both refusals are correct; a render-only test still has to get past them.
    truncate -s 160M "$T/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
    # A FAKE key, assembled at runtime: no phsk_-shaped literal may sit in a
    # file in this PUBLIC repo (rule 10 / #1064).
    env -i PATH="${RT_SHIM:+$RT_SHIM:}/usr/local/bin:/usr/bin:/bin" HOME=/tmp \
        PRIMAL_ROOT="$T" PRIMAL_RENDER_ONLY=1 PRIMAL_WRAPPER_AUTOUPDATE=0 \
        AUTO_UPDATE=0 UPDATE_GATE=0 PRIMAL_ALLOW_VANILLA=1 \
        ENABLE_PRIMAL_MOD=1 PHSK_KEY="phsk_$(printf 'a%.0s' $(seq 1 48))" \
        SERVER_PORT=7777 PRIMAL_DATA_BASE="file://$T/canon" \
        SERVER_NAME="EGGVAR-NAME" MAX_PLAYERS=99 AI_DENSITY=1 CORPSE_DECAY=3 \
        ADMIN_STEAM_IDS="76561199999999999" ALLOWED_CLASSES="Dryosaurus" "${@:3}" \
        bash "$T/_primal/start-evrima.sh" > "$T/boot.log" 2>&1
    echo "$T"
}

echo "render_test: wrapper = $WRAPPER"
echo
echo "── 1. THE CANONICAL RUNG: the plane's values reach the game ──"
T=$(render canon canon)
G="$T/TheIsle/Saved/Config/LinuxServer/Game.ini"
E="$T/TheIsle/Saved/Config/LinuxServer/Engine.ini"
L="$T/boot.log"

want "config source is FETCHED"            'source=fetched'                  "$L"
# Game.ini - scalars, from server_settings and NOT from the egg variables.
want "serverName from the plane"           'ServerName=CANON-NAME-FROM-PLANE' "$G"
nowant "the egg variable did NOT win"      'ServerName=EGGVAR-NAME'           "$G"
want "maxPlayers from the plane"           'MaxPlayerCount=42'                "$G"
nowant "egg MAX_PLAYERS did NOT win"       'MaxPlayerCount=99'                "$G"
want "corpseDecay from the plane"          'CorpseDecayMultiplier=7'          "$G"
want "aiDensity from the plane"            'AIDensity=5'                      "$G"
want "growthMultiplier from the plane"     'GrowthMultiplier=3'               "$G"
want "day/night from the plane"            'ServerDayLengthMinutes=11'        "$G"
want "booleans invert from the plane"      'bEnableHumans=False'              "$G"
want "rconPassword from the plane"         'RconPassword=canon-rcon'          "$G"
want "aiSpawnInterval renders when set"    'AISpawnInterval=600'              "$G"
# A836 - region spawning, the three keys the game session reads.
wantline "useRegionSpawning from the plane"  'bUseRegionSpawning=True'        "$G"
wantline "useRegionSpawnCooldown from the plane" 'bUseRegionSpawnCooldown=True' "$G"
wantline "regionSpawnCooldownSeconds from the plane" 'RegionSpawnCooldownTimeSeconds=300' "$G"
# Lists - the shape that made #1101 invisible for weeks.
want "admin #1 from the plane"             'AdminsSteamIDs=76561190000000001' "$G"
want "admin #2 from the plane"             'AdminsSteamIDs=76561190000000002' "$G"
nowant "the egg-var admin is GONE"         'AdminsSteamIDs=76561199999999999' "$G"
want "vip from the plane"                  'VIPs=76561190000000003'           "$G"
want "roster from the plane"               'AllowedClasses=Tyrannosaurus'     "$G"
nowant "egg ALLOWED_CLASSES did NOT win"   'AllowedClasses=Dryosaurus'        "$G"
# Engine.ini - the pak block. The two controls Ice ruled in on 2026-09-04.
want "AIMaxCount from mod_settings"        'AIMaxCount=77'                    "$E"
want "SpeciesCapEvery from mod_settings"   'SpeciesCapEvery=45'               "$E"
want "SpeciesCapList, malformed dropped"   'SpeciesCapList=Tyrannosaurus:2,Triceratops:5' "$E"
nowant "the malformed entry is NOT in the ini" 'BROKEN_NO_COLON'              "$E"
want "#1593 skip is reported out loud"     'SKIPPED malformed SpeciesCapList' "$L"
want "treeKnockdownOn from mod_settings"   'TreeKnockdownOn=True'             "$E"
want "bodySweepOn from mod_settings"       'BodySweepOn=False'                "$E"
want "bodyHoldSec formatted like egg 40"   'BodyHoldSec=25.0'                 "$E"
want "bodySweepLiftZ from mod_settings"    'BodySweepLiftZ=99000'             "$E"
# A168 - the animated-skins pak knobs. cap=3 is the acceptance fixture (a 4th armed
# pawn must log REFUSED); the rate is the plane's, not the pak default 20.
want "AnimMaxAnimated from mod_settings"  'AnimMaxAnimated=3'                 "$E"
want "AnimWriteHz from mod_settings"      'AnimWriteHz=5'                     "$E"
# #1071: a numeric pak key without its sentinel is SILENTLY INERT.
want "#1071 sentinel BodyHoldSet"          'BodyHoldSet=True'                 "$E"
want "#1071 sentinel BSLiftSet"            'BSLiftSet=True'                   "$E"
# The guard against the guard: a log line captured into the value would appear
# as an injected ini line. This is the defect the test caught on 2026-09-05.
nowant "no log text injected into the ini" '[primal]'                         "$E"
# Things the plane CHANGED on the way out must be said here too (rule 13).
want "entitlement clamp is reported"       'CLAMPED BY ENTITLEMENT'           "$L"
want "roster filter is reported"           'BROKEN SPECIES REMOVED'           "$L"
want "dead egg variables are named"        'NO LONGER READ'                   "$L"
# #3604: with the lever unset the game's own mass check is untouched, and the boot says so.
nowant "no MassMigrationTime unless asked" 'MassMigrationTime='               "$G"
want "the unset lever is said"             'MassMigrationTime left to the game (12 h) - PRIMAL_MASS_MIGRATION_TIME is empty' "$L"
# #3631: the two fleet timing constants, once each, in the game-session section, and said.
if fleet_ok "$G"; then ok "MassMigrationDisableTime=2700 and IndividualPatrolTime=300 are in the game-session section, once each"
else bad "the fleet timing constants are not both in the game-session section exactly once ($(fleet_lines "$G") line(s))"; fi
want "the fleet constants are said"        'Game.ini: MassMigrationDisableTime=2700 IndividualPatrolTime=300' "$L"

echo
echo "── 2. THE DEFAULTS RUNG: no plane, no cache - it must SHOUT, not lie ──"
T2=$(render nocanon nocanon)
G2="$T2/TheIsle/Saved/Config/LinuxServer/Game.ini"
L2="$T2/boot.log"
want "unconfigured boot is shouted"        'THIS SERVER IS UNCONFIGURED'      "$L2"
want "source says defaults"                'source=defaults'                  "$L2"
# #2024: on THIS rung the three identity fields come from the egg env (what the
# provisioner pinned for this server), never the Heaven literals. The pre-fix
# control for this block: `git show b34f90c:isles/evrima-linux/start-evrima.sh`
# renders ServerName=Primal Heaven Evrima here and FAILS these four.
want "identity from the egg env (#2024)"   'ServerName=EGGVAR-NAME'           "$G2"
nowant "the Heaven literal did NOT render" 'ServerName=Primal Heaven Evrima'  "$G2"
want "slots from the egg env (#2024)"      'MaxPlayerCount=99'                "$G2"
want "#2024 seed is reported"              'identity seeded from the egg env' "$L2"
# ...and ONLY those three: a non-identity egg variable must still lose to the
# built-in default on this rung (#2023 - the panel owns config).
wantline "non-identity keeps the built-in" 'AIDensity=0.25'                   "$G2"
nowant "egg AI_DENSITY did NOT win"        'AIDensity=1'                      "$G2"
# #3326 #3331: with no plane and no cache the server still gets the plane's defaults.
for line in bSpawnAI=True bSpawnFish=True bSpawnPlants=True PlantSpawnMultiplier=1 \
            bEnableMigration=True bEnableMassMigration=True bEnablePatrolZones=True \
            bUseRegionSpawning=False bUseRegionSpawnCooldown=False RegionSpawnCooldownTimeSeconds=150; do
    wantline "no plane: $line" "$line" "$G2"
done
nowant "egg CORPSE_DECAY did NOT win"      'CorpseDecayMultiplier=3'          "$G2"
want "no admins, and it says so"           'AdminsSteamIDs=0'                 "$G2"
# #3631: the fleet constants do not come from the plane, so this rung has them too.
if fleet_ok "$G2"; then ok "the fleet timing constants are written with no plane"
else bad "the fleet timing constants are missing on the defaults rung ($(fleet_lines "$G2") line(s))"; fi
want "and said"                            'Game.ini: MassMigrationDisableTime=2700 IndividualPatrolTime=300' "$L2"
# A168 - no plane: no cap, half the pak's rate (Ice 09-21).
E2="$T2/TheIsle/Saved/Config/LinuxServer/Engine.ini"
want "no plane => AnimMaxAnimated=999"     'AnimMaxAnimated=999'               "$E2"
want "no plane => AnimWriteHz=10"          'AnimWriteHz=10'                    "$E2"

echo
echo "== 3. THE BINARY PAIRING LADDER (#2337) - PAIRED / CACHED / DIE =="
# ---------------------------------------------------------------------------
# WHY A curl SHIM AND NOT A NETWORK. The rungs below turn on the DIFFERENCE
# between "the lane did not answer" and "the lane answered something we cannot
# satisfy" - and that difference is invisible to a test that can only unplug the
# network. So the lane is stubbed by shadowing `curl` on PATH: the shim answers
# the binary-lane URLs from a canned file and `exec`s the real curl for
# everything else (the wrapper's own config fetch still rides file://).
#
# ⛔ The pre-fix control for this whole block is the wrapper as it shipped:
#     git show bdd15d6:isles/evrima-linux/start-evrima.sh > /tmp/old.sh
#     ./render_test.sh /tmp/old.sh        # section 3 must FAIL
# It cannot pass: it has no cache, no pairing record and no degraded rung, and
# it talks to the retired Heaven backend.
# ---------------------------------------------------------------------------
BIN_PASS=0

bin_render() { # $1 tag, $2 lane-mode, $3 cache-mode
    local T="$RUN_T/bt-$1"
    rm -rf "$T"; mkdir -p "$T/_primal/binary-cache" "$T/canon/v1" "$T/TheIsle/Binaries/Linux" "$T/shim"
    cp "$WRAPPER" "$T/_primal/start-evrima.sh"
    cp "$HERE/Game.ini.tmpl" "$HERE/Engine.ini.tmpl" "$T/_primal/"
    cp "$JQ_BIN" "$T/_primal/jq"; chmod +x "$T/_primal/jq"
    cp "$HERE/boot-config.fixture.json" "$T/canon/v1/boot-config"

    # The "vanilla" the wrapper will hash after SteamCMD, and a DIFFERENT
    # "modded" blob for the cache - same size, one byte apart, because size can
    # never distinguish them on the real thing either (#2341).
    local GB="$T/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
    truncate -s 160M "$GB"
    local VH; VH=$(md5sum "$GB" | awk '{print $1}')
    local BLOB="$T/_primal/binary-cache/modded.bin"
    cp "$GB" "$BLOB"; printf 'PRIMALMOD' | dd of="$BLOB" bs=1 seek=0 conv=notrunc status=none
    local MH; MH=$(md5sum "$BLOB" | awk '{print $1}')
    local SH; SH=$(sha256sum "$BLOB" | awk '{print $1}')
    local SZ; SZ=$(stat -c%s "$BLOB")
    mv "$BLOB" "$T/_primal/binary-cache/linux-${MH}"
    echo "$VH $MH" > "$T/hashes"

    case "$3" in
        none)  rm -rf "$T/_primal/binary-cache"; mkdir -p "$T/_primal/binary-cache" ;;
        match) printf '{"platform":"linux","vanilla_hash":"%s","modded_hash":"%s","sha256":"%s","size":%s,"cached_at":"2026-09-15T00:00:00Z"}\n' \
                   "$VH" "$MH" "$SH" "$SZ" > "$T/_primal/binary-pairing.json" ;;
        stale) printf '{"platform":"linux","vanilla_hash":"%s","modded_hash":"%s","sha256":"%s","size":%s,"cached_at":"2026-09-15T00:00:00Z"}\n' \
                   "deadbeefdeadbeefdeadbeefdeadbeef" "$MH" "$SH" "$SZ" > "$T/_primal/binary-pairing.json" ;;
    esac

    # The stub lane. `unreachable` writes no answer file, so the shim fails like
    # a dead host; every other mode answers that verdict.
    case "$2" in
        unreachable) : ;;
        up_to_date)  printf '{"status":"up_to_date","modded_hash":"%s","expected_modded_hash":"%s","download_url":null}' "$MH" "$MH" > "$T/lane_check" ;;
        update_available) printf '{"status":"update_available","modded_hash":"%s","expected_modded_hash":"%s","download_url":"/commands/binary/download/linux/%s"}' "$MH" "$MH" "$MH" > "$T/lane_check" ;;
        vanilla_unknown) printf '{"status":"vanilla_unknown","modded_hash":null,"expected_modded_hash":null,"download_url":null}' > "$T/lane_check"
                         printf '{"platform":"linux","available":true,"vanilla_hash":"%s","modded_hash":"%s"}' "$VH" "$MH" > "$T/lane_latest" ;;
    esac

    cat > "$T/shim/curl" <<SHIM
#!/bin/bash
# Stub for the binary lane only; everything else is the real curl.
for a in "\$@"; do
    case "\$a" in
        *"/commands/binary/check")        [ -f "$T/lane_check" ]  || exit 7; cat "$T/lane_check";  exit 0 ;;
        *"/api/binary/latest/linux")      [ -f "$T/lane_latest" ] || exit 7; cat "$T/lane_latest"; exit 0 ;;
        *"/commands/binary/download/"*)   exit 7 ;;
    esac
done
exec /usr/bin/curl "\$@"
SHIM
    chmod +x "$T/shim/curl"

    env -i PATH="$T/shim:/usr/local/bin:/usr/bin:/bin" HOME=/tmp \
        PRIMAL_ROOT="$T" PRIMAL_RENDER_ONLY=1 PRIMAL_WRAPPER_AUTOUPDATE=0 \
        AUTO_UPDATE=0 PRIMAL_ALLOW_VANILLA=0 \
        ENABLE_PRIMAL_MOD=0 SERVER_PORT=7777 PRIMAL_DATA_BASE="file://$T/canon" \
        SERVER_NAME="EGGVAR-NAME" MAX_PLAYERS=99 \
        bash "$T/_primal/start-evrima.sh" > "$T/boot.log" 2>&1
    echo $? > "$T/exit"
    echo "$T"
}

bexit() { cat "$1/exit"; }
bmd5()  { md5sum "$1/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping" | awk '{print $1}'; }
bmh()   { awk '{print $2}' "$1/hashes"; }

echo "-- 3a. lane UNREACHABLE, no cache -> must DIE naming the unreachable case --"
T=$(bin_render a unreachable none); L="$T/boot.log"
want "dies MOD-BINARY-UNAVAILABLE"        'MOD-BINARY-UNAVAILABLE'                 "$L"
want "names the UNREACHABLE cause"        'did not answer in 5 attempts'           "$L"
nowant "does NOT claim a mod-build outage" 'the lane ANSWERED'                     "$L"
[ "$(bexit "$T")" = "1" ] && ok "exit 1" || bad "exit $(bexit "$T"), want 1"

echo "-- 3b. lane UNREACHABLE, cache MATCHES -> the NAMED degraded line, and it boots --"
T=$(bin_render b unreachable match); L="$T/boot.log"
want "the named degraded line"            'primal-binary: R2 unreachable, booting last-known-good' "$L"
want "says it is NOT vanilla"             'THE SERVER IS NOT RUNNING VANILLA'      "$L"
nowant "did NOT die"                      'MOD-BINARY-UNAVAILABLE'                 "$L"
[ "$(bexit "$T")" = "0" ] && ok "exit 0 (boot proceeded)" || bad "exit $(bexit "$T"), want 0"
# ⭐ THE CONSUMER CHECK: the bytes on the launch path are the cached MODDED ones,
# not the vanilla the wrapper started this boot with (#2341 - a record-only
# cache would have left vanilla here and still printed the line above).
[ "$(bmd5 "$T")" = "$(bmh "$T")" ] && ok "the INSTALLED binary is the cached modded one" \
    || bad "installed binary is $(bmd5 "$T"), want the cached modded $(bmh "$T")"

echo "-- 3c. lane UNREACHABLE, cache is for a DIFFERENT vanilla -> must DIE --"
T=$(bin_render c unreachable stale); L="$T/boot.log"
want "dies rather than run a stale mod"   'MOD-BINARY-UNAVAILABLE'                 "$L"
nowant "no degraded line on a stale cache" 'booting last-known-good'               "$L"
[ "$(bexit "$T")" = "1" ] && ok "exit 1" || bad "exit $(bexit "$T"), want 1"

echo "-- 3d. lane ANSWERS vanilla_unknown with a WARM cache -> a VERDICT is obeyed --"
# ⭐ The assertion that keeps Ice's no-vanilla rule honest: a reachable lane
# that cannot pair us must still fail the boot, cache or no cache.
T=$(bin_render d vanilla_unknown match); L="$T/boot.log"
want "dies on the verdict"                'MOD-BINARY-UNAVAILABLE'                 "$L"
want "names it as a REAL mod-build outage" 'the lane ANSWERED'                     "$L"
nowant "did NOT fall back to the cache"   'booting last-known-good'                "$L"
[ "$(bexit "$T")" = "1" ] && ok "exit 1" || bad "exit $(bexit "$T"), want 1"

echo "-- 3e. lane ANSWERS update_available, cache holds it -> install locally, 0 bytes --"
T=$(bin_render e update_available match); L="$T/boot.log"
want "installed from the on-volume cache" 'FROM THE ON-VOLUME CACHE (0 bytes fetched)' "$L"
nowant "did not attempt the download"     'downloading modded binary'              "$L"
[ "$(bmd5 "$T")" = "$(bmh "$T")" ] && ok "the INSTALLED binary is the cached modded one" \
    || bad "installed binary is $(bmd5 "$T"), want $(bmh "$T")"
[ "$(bexit "$T")" = "0" ] && ok "exit 0" || bad "exit $(bexit "$T"), want 0"

echo "-- 3f. the lane host is NAMED every boot, and Heaven is nowhere --"
T=$(bin_render f up_to_date match); L="$T/boot.log"
want "the host is logged with its source" 'binary: pairing lane = https://binaries.primalhosted.com (built-in default)' "$L"
nowant "no Heaven host anywhere in a boot" 'api.primalheaven.com'                  "$L"
nowant "no Heaven update gate"            'update gate'                            "$L"
nowant "no Heaven confirm-startup"        'startup confirmed with backend'         "$L"
# ⭐ The boot-log checks above PASS on the pre-fix wrapper too - it simply never
# printed the host - so they cannot detect the defect on their own. This one can:
# it reads the WRAPPER UNDER TEST and fails if Heaven survives in live code.
if grep -vE '^\s*#' "$WRAPPER" | grep -qE 'api\.primalheaven\.com|API_BASE_URL|/api/updates/'; then
    bad "the wrapper still references Heaven OUTSIDE comments"
else
    ok "the wrapper has no Heaven reference outside comments"
fi

echo
echo "== 4. THE MASS-CHECK LEVER (#3604) - PRIMAL_MASS_MIGRATION_TIME reaches Game.ini or is refused by name =="
# The pre-fix control: sections 1, 2 and 4 FAIL on the wrapper before the lever,
#     git show 863cea0:isles/evrima-linux/start-evrima.sh > /tmp/old.sh
# and the fleet-constant checks alone FAIL on the wrapper with the lever only (283913c).
mass_lines() { grep -cE '^[[:space:]]*MassMigrationTime[[:space:]]*=' "$1"; }
# Section 4's boots answer the binary lane at once: the lever is downstream of it, and an
# unreachable lane costs five 10 s retries per boot.
RT_SHIM="$RUN_T/rt-shim"; rm -rf "$RT_SHIM"; mkdir -p "$RT_SHIM"
cat > "$RT_SHIM/curl" <<'SHIM'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *"/commands/binary/check") printf '{"status":"up_to_date","modded_hash":null,"expected_modded_hash":null,"download_url":null}'; exit 0 ;;
    esac
done
exec /usr/bin/curl "$@"
SHIM
chmod +x "$RT_SHIM/curl"

echo "-- 4a. a park value, on both config rungs --"
for RUNG in canon nocanon; do
    T=$(render "m-$RUNG" "$RUNG" PRIMAL_MASS_MIGRATION_TIME=172800)
    G="$T/TheIsle/Saved/Config/LinuxServer/Game.ini"; L="$T/boot.log"
    if session_body "$G" | grep -qx 'MassMigrationTime=172800'; then ok "$RUNG: the key is in the game-session section"
    else bad "$RUNG: MassMigrationTime=172800 is not in the game-session section"; fi
    [ "$(mass_lines "$G")" = "1" ] && ok "$RUNG: exactly one MassMigrationTime line" || bad "$RUNG: $(mass_lines "$G") MassMigrationTime lines, want 1"
    want "$RUNG: the boot says what it wrote"  'Game.ini: MassMigrationTime=172800 (PRIMAL_MASS_MIGRATION_TIME)' "$L"
    nowant "$RUNG: and does not also say 12 h" 'left to the game'             "$L"
    if fleet_ok "$G"; then ok "$RUNG: the fleet constants stand beside it"; else bad "$RUNG: the lever disturbed the fleet constants ($(fleet_lines "$G") line(s))"; fi
    # Nothing else moved: the render with the lever, less its one line, is the render without it.
    T0=$(render "m0-$RUNG" "$RUNG")
    if diff <(grep -v '^MassMigrationTime=172800$' "$G") "$T0/TheIsle/Saved/Config/LinuxServer/Game.ini" >/dev/null; then
        ok "$RUNG: every other line of Game.ini is unchanged"
    else
        bad "$RUNG: the lever changed more than its own line"
    fi
done

echo "-- 4b. surrounding blanks are trimmed; the edges of the range --"
T=$(render m-ws canon "PRIMAL_MASS_MIGRATION_TIME= 172800 ")
want "a padded value is written"           'MassMigrationTime=172800'         "$T/TheIsle/Saved/Config/LinuxServer/Game.ini"
T=$(render m-lo canon PRIMAL_MASS_MIGRATION_TIME=86401)
want "86401 is written"                    'MassMigrationTime=86401'          "$T/TheIsle/Saved/Config/LinuxServer/Game.ini"
T=$(render m-hi canon PRIMAL_MASS_MIGRATION_TIME=31536000)
want "31536000 is written"                 'MassMigrationTime=31536000'       "$T/TheIsle/Saved/Config/LinuxServer/Game.ini"

echo "-- 4c. anything else is REFUSED by name, and the game's own check stands --"
N=0
for BAD in 86400 43200 0 31536001 0172800 172800.5 -172800 1e5 abc '172800;id' '172800 MassMigrationTime=5' '172800x'; do
    N=$((N+1))
    T=$(render "m-bad$N" canon "PRIMAL_MASS_MIGRATION_TIME=$BAD")
    G="$T/TheIsle/Saved/Config/LinuxServer/Game.ini"; L="$T/boot.log"
    if [ "$(mass_lines "$G")" = "0" ] && grep -qF "PRIMAL_MASS_MIGRATION_TIME='" "$L" \
            && grep -qF 'REFUSED (want a whole number of seconds, 86401 to 31536000)' "$L" \
            && ! grep -qF '(PRIMAL_MASS_MIGRATION_TIME) - the game' "$L"; then
        ok "refused, nothing written: '$BAD'"
    else
        bad "'$BAD' was not refused cleanly ($(mass_lines "$G") line(s) in Game.ini)"
    fi
done

echo "-- 4d. no game-session section: said, never claimed --"
T=$(RT_NO_SESSION=1 render m-nosec canon PRIMAL_MASS_MIGRATION_TIME=172800)
G="$T/TheIsle/Saved/Config/LinuxServer/Game.ini"; L="$T/boot.log"
want "the miss is said"                    'MassMigrationTime=172800 NOT WRITTEN' "$L"
nowant "the write is not claimed"          '(PRIMAL_MASS_MIGRATION_TIME) - the game' "$L"
[ "$(mass_lines "$G")" = "0" ] && ok "and nothing was added" || bad "a MassMigrationTime line was added outside the session section"
want "the fleet constants' miss is said"   'MassMigrationDisableTime / IndividualPatrolTime NOT WRITTEN' "$L"
nowant "and their write is not claimed"    'Game.ini: MassMigrationDisableTime=2700 IndividualPatrolTime=300' "$L"
[ "$(fleet_lines "$G")" = "0" ] && ok "and neither was added" || bad "a fleet timing line was added outside the session section"

echo "-- 4e. a MassMigrationTime line already in the template is replaced, never doubled --"
T=$(RT_TMPL_EXTRA='MassMigrationTime=43200' render m-dup canon PRIMAL_MASS_MIGRATION_TIME=172800)
G="$T/TheIsle/Saved/Config/LinuxServer/Game.ini"
if [ "$(mass_lines "$G")" = "1" ] && grep -qx 'MassMigrationTime=172800' "$G"; then ok "one line, the lever's"
else bad "$(mass_lines "$G") MassMigrationTime line(s) after a template that already had one"; fi
# ...and with the lever unset that template line is left exactly as written.
T=$(RT_TMPL_EXTRA='MassMigrationTime=43200' render m-dup0 canon)
want "unset leaves a template line alone"  'MassMigrationTime=43200'          "$T/TheIsle/Saved/Config/LinuxServer/Game.ini"

echo "-- 4f. fleet timing lines already in the template are replaced by the constants (#3631) --"
T=$(RT_TMPL_EXTRA='IndividualPatrolTime=1200\nMassMigrationDisableTime=7200' render m-fleetdup canon)
G="$T/TheIsle/Saved/Config/LinuxServer/Game.ini"
if fleet_ok "$G"; then ok "one line each, the constants"; else bad "$(fleet_lines "$G") fleet timing line(s) after a template that already had both"; fi
nowant "the template's patrol value is gone" 'IndividualPatrolTime=1200'      "$G"
nowant "the template's mass length is gone"  'MassMigrationDisableTime=7200'  "$G"

echo
echo "== 5. A REFUSED START IS REPORTED, WITH THE SERVER'S OWN KEY (#2353) =="
# ---------------------------------------------------------------------------
# The data plane is stubbed the way the lane is: the shim writes down every
# argument of the request it was handed and answers from the plane-mode. It
# prints what the wrapper's own `-w '\n%{http_code}'` would: body, newline, code.
#
# ⛔ The pre-fix control is the wrapper before `refuse` existed:
#     git show 863cea0:isles/evrima-linux/start-evrima.sh > /tmp/old.sh
#     ./render_test.sh /tmp/old.sh        # section 4 must FAIL
# ---------------------------------------------------------------------------
# A FAKE key, assembled at runtime (rule 10 / #1064).
REP_KEY="phsk_$(printf 'b%.0s' $(seq 1 48))"

rep_render() { # $1 tag, $2 lane-mode, $3 plane-mode, $4 binary (ok|missing|short|runs), $5 = extra env words
    local T="$RUN_T/rp-$1"
    rm -rf "$T"; mkdir -p "$T/_primal/binary-cache" "$T/canon/v1" "$T/TheIsle/Binaries/Linux" "$T/shim"
    cp "$WRAPPER" "$T/_primal/start-evrima.sh"
    cp "$HERE/Game.ini.tmpl" "$HERE/Engine.ini.tmpl" "$T/_primal/"
    cp "$JQ_BIN" "$T/_primal/jq"; chmod +x "$T/_primal/jq"
    cp "$HERE/boot-config.fixture.json" "$T/canon/v1/boot-config"

    local GB="$T/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
    case "$4" in
        missing) : ;;
        short)   truncate -s 1M "$GB" ;;
        runs)    printf '#!/bin/bash\necho FAKE-GAME-LAUNCHED\nexit 0\n' > "$GB"; truncate -s 160M "$GB"; chmod +x "$GB" ;;
        *)       truncate -s 160M "$GB" ;;
    esac
    local MH=""; [ -f "$GB" ] && MH=$(md5sum "$GB" | awk '{print $1}')

    case "$2" in
        unreachable) : ;;
        up_to_date)  printf '{"status":"up_to_date","modded_hash":"%s","expected_modded_hash":"%s","download_url":null}' "$MH" "$MH" > "$T/lane_check" ;;
        vanilla_unknown) printf '{"status":"vanilla_unknown","modded_hash":null,"expected_modded_hash":null,"download_url":null}' > "$T/lane_check"
                         printf '{"platform":"linux","available":true,"vanilla_hash":"%s","modded_hash":"%s"}' "feedfacefeedfacefeedfacefeedface" "deadbeefdeadbeefdeadbeefdeadbeef" > "$T/lane_latest" ;;
    esac
    echo "$3" > "$T/plane_mode"
    echo 0 > "$T/plane_calls"

    cat > "$T/shim/curl" <<SHIM
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        *"/commands/binary/check")        [ -f "$T/lane_check" ]  || exit 7; cat "$T/lane_check";  exit 0 ;;
        *"/api/binary/latest/linux")      [ -f "$T/lane_latest" ] || exit 7; cat "$T/lane_latest"; exit 0 ;;
        *"/commands/binary/download/"*)   exit 7 ;;
        *"/v1/boot-report")
            n=\$(( \$(cat "$T/plane_calls") + 1 )); echo \$n > "$T/plane_calls"
            printf '%s\n' "\$@" > "$T/plane_req.\$n"
            case "\$(cat "$T/plane_mode")" in
                recorded) printf '{"ok":true,"recorded":true,"alert":"event_watch","paged":false}\n200'; exit 0 ;;
                http503)  printf '{"ok":false,"code":"not_recorded"}\n503'; exit 0 ;;
                lying200) printf '{"ok":false}\n200'; exit 0 ;;
                *)        printf '\n000'; exit 7 ;;
            esac ;;
    esac
done
exec /usr/bin/curl "\$@"
SHIM
    chmod +x "$T/shim/curl"

    # shellcheck disable=SC2086
    env -i PATH="$T/shim:/usr/local/bin:/usr/bin:/bin" HOME=/tmp \
        PRIMAL_ROOT="$T" PRIMAL_WRAPPER_AUTOUPDATE=0 AUTO_UPDATE=0 PRIMAL_ALLOW_VANILLA=0 \
        ENABLE_PRIMAL_MOD=0 SERVER_PORT=7777 PRIMAL_DATA_BASE="file://$T/canon" \
        SERVER_NAME="EGGVAR-NAME" MAX_PLAYERS=99 PHSK_KEY="$REP_KEY" $5 \
        bash "$T/_primal/start-evrima.sh" > "$T/boot.log" 2>&1
    echo $? > "$T/exit"
    echo "$T"
}
rcalls() { cat "$1/plane_calls"; }
rbody()  { awk 'prev == "-d" { print; exit } { prev = $0 }' "$1/plane_req.${2:-1}" 2>/dev/null; }
rjq()    { rbody "$1" "${3:-1}" | "$JQ_BIN" -e "$2" >/dev/null 2>&1; }

echo "-- 5a. the lane ANSWERS and has no modded binary -> reported, by code, with the server's key --"
T=$(rep_render a vanilla_unknown recorded ok ""); L="$T/boot.log"
want "the FATAL line is still printed"     'FATAL: MOD-BINARY-UNAVAILABLE: the lane ANSWERED' "$L"
want "the log says the plane RECORDED it"  'this refused start is RECORDED by the data plane (mod_binary_unavailable)' "$L"
[ "$(rcalls "$T")" = "1" ] && ok "exactly one report was sent" || bad "$(rcalls "$T") report(s) sent, want 1"
want "it went to the boot-report route"    '/v1/boot-report'                       "$T/plane_req.1"
want "with the server's OWN key"           "Authorization: Bearer $REP_KEY"        "$T/plane_req.1"
rjq "$T" '.stage == "start" and .ok == false and .game == "evrima" and .platform == "linux" and .code == "mod_binary_unavailable"' \
    && ok "the body is JSON: stage start, ok false, the code" || bad "the body is not the refused-start report: $(rbody "$T")"
rjq "$T" '.reason | startswith("MOD-BINARY-UNAVAILABLE: the lane ANSWERED")' \
    && ok "the reason is the FATAL line" || bad "the reason is not the FATAL line: $(rbody "$T")"
nowant "the key is NOT in the boot log"    "$REP_KEY"                              "$L"
[ -f "$T/_primal/boot-refused.pending" ] && ok "a pending marker is left for the next boot" || bad "no pending marker"
[ "$(bexit "$T")" = "1" ] && ok "exit 1" || bad "exit $(bexit "$T"), want 1"

echo "-- 5b. the lane is UNREACHABLE and nothing is cached -> its own code --"
T=$(rep_render b unreachable recorded ok "")
rjq "$T" '.code == "mod_binary_lane_unreachable" and .ok == false' && ok "code mod_binary_lane_unreachable" || bad "wrong body: $(rbody "$T")"

echo "-- 5c. no game binary / a short one -> their own codes --"
T=$(rep_render c1 up_to_date recorded missing "")
rjq "$T" '.code == "binary_missing"' && ok "code binary_missing" || bad "wrong body: $(rbody "$T")"
T=$(rep_render c2 up_to_date recorded short "")
rjq "$T" '.code == "binary_truncated"' && ok "code binary_truncated" || bad "wrong body: $(rbody "$T")"

echo "-- 5d. the plane answers 503 -> tried twice, and the log says NOBODY was told --"
T=$(rep_render d vanilla_unknown http503 ok ""); L="$T/boot.log"
[ "$(rcalls "$T")" = "2" ] && ok "two attempts" || bad "$(rcalls "$T") attempt(s), want 2"
want "says it was NOT reported, and why"   'was NOT reported to the data plane (HTTP 503) - NOBODY HAS BEEN TOLD' "$L"
nowant "does NOT claim it was recorded"    'is RECORDED by the data plane'         "$L"
[ "$(bexit "$T")" = "1" ] && ok "exit 1" || bad "exit $(bexit "$T"), want 1"

echo "-- 5e. a 200 whose body does not say recorded is not a report (rule 13) --"
T=$(rep_render e vanilla_unknown lying200 ok ""); L="$T/boot.log"
want "says it was NOT reported"            'was NOT reported to the data plane (HTTP 200 without recorded:true)' "$L"
nowant "does NOT claim it was recorded"    'is RECORDED by the data plane'         "$L"

echo "-- 5f. the plane does not answer -> said, and the refusal still exits 1 --"
T=$(rep_render f vanilla_unknown down ok ""); L="$T/boot.log"
want "names the plane that did not answer" 'was NOT reported to the data plane (no answer from' "$L"
[ "$(bexit "$T")" = "1" ] && ok "exit 1" || bad "exit $(bexit "$T"), want 1"

echo "-- 5g. no server key -> nothing is sent, and the log says so --"
T=$(rep_render g vanilla_unknown recorded ok "PHSK_KEY="); L="$T/boot.log"
[ "$(rcalls "$T")" = "0" ] && ok "no request without a key" || bad "$(rcalls "$T") request(s), want 0"
want "says why nobody was told"            'was NOT reported to the data plane (no PHSK_KEY)' "$L"

echo "-- 5h. an off-box render-only run reports nothing --"
T=$(rep_render h vanilla_unknown recorded ok "PRIMAL_RENDER_ONLY=1"); L="$T/boot.log"
[ "$(rcalls "$T")" = "0" ] && ok "no request from a render-only run" || bad "$(rcalls "$T") request(s), want 0"
want "and says so"                         '(render-only) an off-box run reports no refused start' "$L"

echo "-- 5i. a reason carrying quotes and backslashes is still valid JSON --"
T=$(rep_render i unreachable recorded ok 'PRIMAL_BINARY_BASE=https://lane.invalid/a"b\c')
rjq "$T" '.code == "mod_binary_lane_unreachable" and (.reason | contains("https://lane.invalid/abc"))' \
    && ok "the body parses and the two characters are gone" || bad "the body does not parse: $(rbody "$T")"

echo "-- 5j. the launch AFTER a refusal says so, and clears the marker --"
T=$(rep_render j1 vanilla_unknown recorded runs ""); # the refusal
echo recorded > "$T/plane_mode"; echo 0 > "$T/plane_calls"; rm -f "$T"/plane_req.*
MH=$(md5sum "$T/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping" | awk '{print $1}')
printf '{"status":"up_to_date","modded_hash":"%s","expected_modded_hash":"%s","download_url":null}' "$MH" "$MH" > "$T/lane_check"
env -i PATH="$T/shim:/usr/local/bin:/usr/bin:/bin" HOME=/tmp PRIMAL_ROOT="$T" PRIMAL_WRAPPER_AUTOUPDATE=0 AUTO_UPDATE=0 \
    PRIMAL_ALLOW_VANILLA=0 ENABLE_PRIMAL_MOD=0 SERVER_PORT=7777 PRIMAL_DATA_BASE="file://$T/canon" PHSK_KEY="$REP_KEY" \
    bash "$T/_primal/start-evrima.sh" > "$T/boot2.log" 2>&1
echo $? > "$T/exit"; L="$T/boot2.log"
[ "$(rcalls "$T")" = "1" ] && ok "one report on the launch" || bad "$(rcalls "$T") report(s), want 1"
rjq "$T" '.stage == "start" and .ok == true and (has("code") | not)' && ok "the body says ok true, with no code" || bad "wrong body: $(rbody "$T")"
want "with the server's OWN key"           "Authorization: Bearer $REP_KEY"        "$T/plane_req.1"
want "the log says the plane was told"     'told the data plane this server is launching again after a refused start' "$L"
[ ! -f "$T/_primal/boot-refused.pending" ] && ok "the marker is gone" || bad "the marker is still there"
want "⭐ and the game was launched"         'FAKE-GAME-LAUNCHED'                    "$L"
[ "$(bexit "$T")" = "0" ] && ok "exit 0" || bad "exit $(bexit "$T"), want 0"

echo "-- 5k. the next launch, with no marker, sends nothing --"
echo 0 > "$T/plane_calls"
env -i PATH="$T/shim:/usr/local/bin:/usr/bin:/bin" HOME=/tmp PRIMAL_ROOT="$T" PRIMAL_WRAPPER_AUTOUPDATE=0 AUTO_UPDATE=0 \
    PRIMAL_ALLOW_VANILLA=0 ENABLE_PRIMAL_MOD=0 SERVER_PORT=7777 PRIMAL_DATA_BASE="file://$T/canon" PHSK_KEY="$REP_KEY" \
    bash "$T/_primal/start-evrima.sh" > "$T/boot3.log" 2>&1
[ "$(rcalls "$T")" = "0" ] && ok "a server that did not refuse reports nothing" || bad "$(rcalls "$T") report(s), want 0"
want "and it launched"                     'FAKE-GAME-LAUNCHED'                    "$T/boot3.log"

echo "-- 5l. a launch the plane could not be told about KEEPS the marker, and still launches --"
T=$(rep_render l1 vanilla_unknown recorded runs "")
echo down > "$T/plane_mode"
MH=$(md5sum "$T/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping" | awk '{print $1}')
printf '{"status":"up_to_date","modded_hash":"%s","expected_modded_hash":"%s","download_url":null}' "$MH" "$MH" > "$T/lane_check"
env -i PATH="$T/shim:/usr/local/bin:/usr/bin:/bin" HOME=/tmp PRIMAL_ROOT="$T" PRIMAL_WRAPPER_AUTOUPDATE=0 AUTO_UPDATE=0 \
    PRIMAL_ALLOW_VANILLA=0 ENABLE_PRIMAL_MOD=0 SERVER_PORT=7777 PRIMAL_DATA_BASE="file://$T/canon" PHSK_KEY="$REP_KEY" \
    bash "$T/_primal/start-evrima.sh" > "$T/boot2.log" 2>&1
want "says the plane could NOT be told"    'could NOT tell the data plane this server is launching again' "$T/boot2.log"
[ -f "$T/_primal/boot-refused.pending" ] && ok "the marker is kept for the next boot" || bad "the marker was dropped"
want "the game still launched"             'FAKE-GAME-LAUNCHED'                    "$T/boot2.log"

echo "-- 5m. no exit that leaves the server down bypasses the report --"
if grep -vE '^\s*#' "$WRAPPER" | grep -qE '(\|\||&&|;|^)\s*die "'; then
    bad "the wrapper still has a bare die call"
else
    ok "every fatal exit goes through refuse"
fi

echo
echo "render_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
