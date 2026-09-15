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

ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
want() { # $1 label, $2 needle, $3 file
    if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1  (missing: $2)"; fi
}
nowant() { # $1 label, $2 needle, $3 file
    if grep -qF -- "$2" "$3" 2>/dev/null; then bad "$1  (present but must not be: $2)"; else ok "$1"; fi
}

# ── the fixture. Every value is deliberately DIFFERENT from both the wrapper's
# built-in default AND the egg variable set below, so any of the three possible
# sources is distinguishable in the output.
render() { # $1 = tag, $2 = "canon" | "nocanon"
    local T="/tmp/rt-$1"
    rm -rf "$T"; mkdir -p "$T/_primal" "$T/canon/v1" "$T/TheIsle/Binaries/Linux"
    cp "$WRAPPER" "$T/_primal/start-evrima.sh"
    cp "$HERE/Game.ini.tmpl" "$HERE/Engine.ini.tmpl" "$T/_primal/"
    cp "$JQ_BIN" "$T/_primal/jq"; chmod +x "$T/_primal/jq"
    [ "$2" = "canon" ] && cp "$HERE/boot-config.fixture.json" "$T/canon/v1/boot-config"
    # The wrapper refuses to boot with no binary, and refuses one under 150 MB.
    # Both refusals are correct; a render-only test still has to get past them.
    truncate -s 160M "$T/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
    # A FAKE key, assembled at runtime: no phsk_-shaped literal may sit in a
    # file in this PUBLIC repo (rule 10 / #1064).
    env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp \
        PRIMAL_ROOT="$T" PRIMAL_RENDER_ONLY=1 PRIMAL_WRAPPER_AUTOUPDATE=0 \
        AUTO_UPDATE=0 UPDATE_GATE=0 PRIMAL_ALLOW_VANILLA=1 \
        ENABLE_PRIMAL_MOD=1 PHSK_KEY="phsk_$(printf 'a%.0s' $(seq 1 48))" \
        SERVER_PORT=7777 PRIMAL_DATA_BASE="file://$T/canon" \
        SERVER_NAME="EGGVAR-NAME" MAX_PLAYERS=99 AI_DENSITY=1 CORPSE_DECAY=3 \
        ADMIN_STEAM_IDS="76561199999999999" ALLOWED_CLASSES="Dryosaurus" \
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
want "non-identity keeps the built-in"     'AIDensity=0'                      "$G2"
nowant "egg AI_DENSITY did NOT win"        'AIDensity=1'                      "$G2"
nowant "egg CORPSE_DECAY did NOT win"      'CorpseDecayMultiplier=3'          "$G2"
want "no admins, and it says so"           'AdminsSteamIDs=0'                 "$G2"

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
# it talks to api.primalheaven.com.
# ---------------------------------------------------------------------------
BIN_PASS=0

bin_render() { # $1 tag, $2 lane-mode, $3 cache-mode
    local T="/tmp/bt-$1"
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
echo "render_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
