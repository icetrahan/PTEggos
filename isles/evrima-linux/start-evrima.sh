#!/bin/bash
# Primal - The Isle: Evrima startup wrapper (LINUX / node 1, standard Wings).
#
# The Linux sibling of egg 40's start-evrima.ps1 (isles/evrima-windows-feathers).
# Each boot: self-update -> jq -> CANONICAL CONFIG from the data plane ->
# update gate -> SteamCMD -> MODDED BINARY from the Primal API -> RENDER
# Game.ini/Engine.ini FROM THE PLANE -> pak from R2 -> launch. Game.ini and the
# pak's Engine.ini section are DERIVED artifacts regenerated every boot; the
# customer edits the PANEL, never the file and no longer the egg variables.
#
# HARD DIFFERENCES FROM THE WINDOWS EGG, each deliberate:
#
#   * BINARY: the server binary is the MODDED Linux binary served by the Primal
#     backend (api.primalheaven.com /commands/binary/check). The vanilla
#     steamcmd binary is NEVER launched - Ice's rule. SteamCMD still runs first
#     because the backend keys the modded build off the vanilla md5 hash, and
#     because the game CONTENT comes from Steam; only the 200 MB Shipping
#     binary is replaced.
#   * NO SIGBYPASS LANE. On Windows the mod pak needs dsound.dll +
#     UniversalSigBypasser.asi or the engine refuses unsigned paks. On Linux the
#     signature bypass ships INSIDE the modded binary, which is the other half
#     of why vanilla is forbidden: pakchunk50 mounting on the Linux build was
#     proven 2026-08-04 ([BOOT] BUILD 78 ... tokenlen=53 on the listing-test
#     clone) while running the API's modded binary. Vanilla + our pak is
#     untested and stays that way.
#   * QUERY PORT == GAME PORT, BAKED. There is no QUERY_PORT variable on this
#     egg on purpose (Ice, 2026-08-04, from the warphosting listing work). Both
#     working Linux references run -QueryPort == Port; the one clone that split
#     them dropped off the community list until corrected.
#   * PORTS ARE EGG VARIABLES, not feathers SERVER_PORT_1/_2 injections -
#     standard Linux Wings only injects SERVER_PORT. QUEUE_PORT/RCON_PORT
#     default to game+1 / game+2.
#
# Settings, since 2026-09-05 (`egg42-parity-0905`) - and this is the whole point
# of that change:
#   1. DEFAULTS (below)              FIRST-BOOT FALLBACK ONLY, byte-matched to
#                                    egg 40's and to the plane's CONFIG_DEFAULTS
#   2. THE DATA PLANE                >> THE SINGLE SOURCE OF TRUTH.
#                                    `GET /v1/boot-config`, keyed by PHSK_KEY,
#                                    cached to _primal/boot-config.cache.json so
#                                    a plane outage cannot stop a boot
#   3. EGG VARIABLES ($ENV)          BOOTSTRAP ONLY (PHSK_KEY, ports,
#                                    AUTO_UPDATE, ENABLE_PRIMAL_MOD, ...). The
#                                    customer settings among them are NO LONGER
#                                    READ and the wrapper says so if one is set.
#   4. server-config.json overlay    NOT SUPPORTED here - see the render section.
#
#   THIRD HARD DIFFERENCE FROM EGG 40 (below) USED TO BE "config comes from egg
#   variables". It does not any more: this egg was the ONLY Evrima or Legacy egg
#   that never called /v1/boot-config, so all 42 of the panel's canonical fields
#   saved green and changed nothing here (#1101/#1799 shape, platform dimension).

# PRIMAL_ROOT exists for OFF-BOX TESTS ONLY (render-only smoke); production
# is always /home/container.
ROOT="${PRIMAL_ROOT:-/home/container}"
cd "$ROOT" || exit 1
export TZ=${TZ:-UTC}

log()  { echo "[primal] $*"; }
warn() { echo "[primal] WARN: $*" >&2; }
die()  { echo "[primal] FATAL: $*" >&2; exit 1; }

# Normalize 0/1/true/false/yes/on -> True|False (egg 40 renders capitalized).
to_bool() { # $1 = raw, $2 = fallback (already True/False)
    local v; v=$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$v" in
        1|true|yes|on)  echo "True"  ;;
        0|false|no|off) echo "False" ;;
        *)              echo "$2"    ;;
    esac
}
env_or() { # $1 = value, $2 = fallback
    if [ -n "${1:-}" ]; then echo "$1"; else echo "$2"; fi
}
md5_of() { [ -f "$1" ] && md5sum "$1" | awk '{print $1}' || echo ""; }
sha256_of() { [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo ""; }

# Manifest field extraction (no jq/python in the image; same grep pattern the
# proven entrypoints use). Arrays stay index-aligned because grep -o preserves
# document order.
m_field()  { grep -o "\"$2\" *: *\"[^\"]*\"" <<<"$1" | head -1 | sed 's/.*: *"//; s/"$//'; }
m_fields() { grep -o "\"$2\" *: *\"[^\"]*\"" <<<"$1" | sed 's/.*: *"//; s/"$//'; }

PRIM="$ROOT/_primal"
GAME_BINARY="$ROOT/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
CONFIG_DIR="$ROOT/TheIsle/Saved/Config/LinuxServer"
PAKS_DIR="$ROOT/TheIsle/Content/Paks"
R2_BASE="https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev"
mkdir -p "$PRIM" "$CONFIG_DIR"

# ---------------------------------------------------------------------------
# THE SERVER KEY, TRIMMED ONCE, USED EVERYWHERE (egg 40 lineage, #436/#411).
# Extract by shape (phsk_ + 48 hex); whatever surrounds it is discarded. Falls
# back to the trimmed raw value so a future key-format change degrades to
# today's behaviour instead of silently blanking the token. Never log the
# value - lengths only.
# ---------------------------------------------------------------------------
PHSK_RAW="${PHSK_KEY:-}"
PHSK=$(echo -n "$PHSK_RAW" | grep -oE 'phsk_[0-9a-fA-F]{48}' | head -1)
[ -z "$PHSK" ] && PHSK=$(echo -n "$PHSK_RAW" | tr -d '[:space:]')
log "phsk key: rawLen=${#PHSK_RAW} finalLen=${#PHSK}"

# ===========================================================================
# SELF-UPDATE: the wrapper (and the two .tmpl files) pull themselves from R2.
# Port of the live Windows wrapper's lane (primal-wrapper-evrima v1); Linux
# reads its own key. The egg's INSTALL script materialises these files exactly
# once, so without this lane every wrapper change is a fleet walk.
#
# BLAST RADIUS: a broken wrapper is a server that does not start, fleet-wide,
# because they all read one manifest. Hence: sha256 verified before anything is
# placed, every .sh is parse-checked (bash -n) before it may replace a live
# file, the outgoing wrapper is kept as start-evrima.sh.prev, and ANY failure
# logs and continues booting on the current version. PRIMAL_WRAPPER_PIN holds
# one server on one version; PRIMAL_WRAPPER_AUTOUPDATE=0 turns the lane off.
# RE-EXEC: if this file itself changed we exec the new copy, marked with
# PRIMAL_WRAPPER_REEXEC=1 so it runs at most once per boot and cannot loop.
# ===========================================================================
WRAP_SELF="$PRIM/start-evrima.sh"
WRAP_VER_FILE="$PRIM/primal-wrapper.version"
if [ "${PRIMAL_WRAPPER_REEXEC:-}" = "1" ]; then
    log "wrapper: running the freshly-pulled copy (re-exec); update lane skipped"
elif [ "${PRIMAL_WRAPPER_AUTOUPDATE:-1}" = "0" ]; then
    log "wrapper: self-update DISABLED for this server (PRIMAL_WRAPPER_AUTOUPDATE=0)"
else
    WRAP_MANIFEST_URL=$(env_or "${PRIMAL_WRAPPER_MANIFEST:-}" "$R2_BASE/primal-wrapper-evrima-linux/latest.json")
    WM=$(curl -fsS --max-time 20 "$WRAP_MANIFEST_URL" 2>/dev/null)
    if [ -z "$WM" ]; then
        log "wrapper: manifest unreachable ($WRAP_MANIFEST_URL) - continuing on the current version"
    else
        WM_VER=$(m_field "$WM" version)
        PIN=$(echo -n "${PRIMAL_WRAPPER_PIN:-}" | tr -d '[:space:]')
        if [ -n "$PIN" ] && [ "$PIN" != "$WM_VER" ]; then
            log "wrapper: PINNED to '$PIN', manifest offers '$WM_VER' - not updating"
        else
            mapfile -t W_NAMES < <(m_fields "$WM" name)
            mapfile -t W_URLS  < <(m_fields "$WM" url)
            mapfile -t W_SHAS  < <(m_fields "$WM" sha256)
            NEED_IDX=()
            for i in "${!W_NAMES[@]}"; do
                DST="$PRIM/${W_NAMES[$i]}"
                if [ ! -f "$DST" ] || [ "$(sha256_of "$DST")" != "$(echo "${W_SHAS[$i]}" | tr 'A-F' 'a-f')" ]; then
                    NEED_IDX+=("$i")
                fi
            done
            if [ "${#NEED_IDX[@]}" -eq 0 ]; then
                log "wrapper: up to date (v$WM_VER, ${#W_NAMES[@]} file(s) sha-verified in place)"
            else
                log "wrapper: updating ${#NEED_IDX[@]}/${#W_NAMES[@]} file(s) -> v$WM_VER ..."
                STAGE="$PRIM/wrapper-stage"
                rm -rf "$STAGE"; mkdir -p "$STAGE"
                OK=1
                for i in "${NEED_IDX[@]}"; do
                    TMPF="$STAGE/${W_NAMES[$i]}"
                    curl -fsS --max-time 120 -o "$TMPF" "${W_URLS[$i]}" 2>/dev/null
                    SHA=$(sha256_of "$TMPF")
                    if [ "$SHA" != "$(echo "${W_SHAS[$i]}" | tr 'A-F' 'a-f')" ]; then
                        log "wrapper: sha256 MISMATCH on ${W_NAMES[$i]} (got ${SHA:0:16}) - discarding this update"
                        OK=0; break
                    fi
                    # The check the other lanes do not need: a shell file that does
                    # not parse would brick this server, and every other one.
                    case "${W_NAMES[$i]}" in *.sh)
                        if ! bash -n "$TMPF" 2>/dev/null; then
                            log "wrapper: ${W_NAMES[$i]} FAILED bash -n parse - discarding this update"
                            OK=0; break
                        fi ;;
                    esac
                done
                if [ "$OK" != "1" ]; then
                    log "wrapper: update REJECTED - continuing on the current version"
                else
                    SELF_CHANGED=0
                    for i in "${NEED_IDX[@]}"; do
                        DST="$PRIM/${W_NAMES[$i]}"
                        if [ "${W_NAMES[$i]}" = "start-evrima.sh" ] && [ -f "$DST" ]; then
                            cp -f "$DST" "$DST.prev" 2>/dev/null
                            SELF_CHANGED=1
                        fi
                        mv -f "$STAGE/${W_NAMES[$i]}" "$DST"
                        log "wrapper: placed ${W_NAMES[$i]}"
                    done
                    echo "$WM_VER" > "$WRAP_VER_FILE"
                    if [ "$SELF_CHANGED" = "1" ]; then
                        log "wrapper: this script was replaced - restarting into v$WM_VER"
                        export PRIMAL_WRAPPER_REEXEC=1
                        exec bash "$WRAP_SELF"
                    fi
                fi
                rm -rf "$STAGE"
            fi
        fi
    fi
fi

# ===========================================================================
# THE JSON PARSER. `_primal/jq`, pinned by sha256, fetched from OUR R2.
#
# WHY A BINARY AND NOT A grep IDIOM. `m_field` above is fine for a flat
# manifest of quoted strings. `/v1/boot-config` is not that: it is a NESTED
# document whose values are numbers, booleans and ARRAYS OF STRINGS, and one of
# those arrays is `adminSteamIds`. A half-parser that silently misreads it is
# the #1101 shape with the safety off - and this wrapper already refuses to
# hand-parse `server-config.json` for exactly that reason, a refusal that would
# be a lie if the canonical config were hand-parsed two hundred lines later.
#
# NOT GitHub at boot. The release is verified ONCE, by hand, against jqlang's
# own sha256sum.txt, and the artifact is then mirrored into the SAME R2 bucket
# the wrapper, the pak and the mod binary already come from. A boot must not
# gain a new third-party dependency.
#
# x86_64 only - the static build is arch-specific and every node is amd64. On
# anything else we do not guess: HAVE_JQ stays 0 and the ladder below says so.
# ===========================================================================
JQ="$PRIM/jq"
JQ_VERSION="1.7.1"
JQ_SHA256="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
JQ_URL="$R2_BASE/primal-wrapper-evrima-linux/jq/$JQ_VERSION/jq-linux-amd64"
HAVE_JQ=0
if [ "$(uname -m)" != "x86_64" ]; then
    warn "jq: architecture $(uname -m) is not x86_64 - the pinned static build does not apply here."
elif [ -f "$JQ" ] && [ "$(sha256_of "$JQ")" = "$JQ_SHA256" ]; then
    chmod +x "$JQ" 2>/dev/null
else
    log "jq: fetching v$JQ_VERSION (pinned sha256 ${JQ_SHA256:0:16}...) ..."
    JQ_TMP="$PRIM/.jq.download"
    rm -f "$JQ_TMP"
    curl -fsS --max-time 120 -o "$JQ_TMP" "$JQ_URL" 2>/dev/null
    JQ_GOT=$(sha256_of "$JQ_TMP")
    if [ "$JQ_GOT" = "$JQ_SHA256" ]; then
        chmod +x "$JQ_TMP"; mv -f "$JQ_TMP" "$JQ"
        log "jq: installed v$JQ_VERSION"
    else
        rm -f "$JQ_TMP"
        warn "jq: sha256 MISMATCH or download failed (got '${JQ_GOT:0:16}') - NOT installed."
    fi
fi
# Rule 13: the download's own success is not evidence the parser WORKS. Ask the
# binary itself, and only then claim we have one.
if [ -x "$JQ" ] && "$JQ" --version >/dev/null 2>&1; then
    HAVE_JQ=1
    log "jq: ready ($("$JQ" --version 2>/dev/null))"
else
    warn "jq: NOT AVAILABLE - canonical config cannot be parsed on this boot."
fi

# ===========================================================================
# CANONICAL CONFIG - fetched from the data plane (Ice's ruling, 2026-08-10).
#
# THIS IS THE SINGLE SOURCE OF TRUTH. It supersedes DECISIONS #24/#356, under
# which egg VARIABLES were canonical - which is what this wrapper did until
# 2026-09-05.
#
# WHAT WAS ACTUALLY BROKEN (measured 2026-09-05, `egg42-parity-0905`). The panel
# stopped writing Ptero egg variables on 2026-08-10: it renders `CANON_FIELDS`
# and writes the DATA PLANE (`primal_billing` `lib/canonical-config.ts`,
# `app/api/panel/servers/[id]/config/route.ts`). `CanonEdition` is
# "evrima"|"legacy" with NO platform dimension, so a LINUX Evrima server is
# served all 42 fields. This wrapper read none of them: every one of those 42
# controls returned a green 200 and changed nothing on the server - the
# #1101/#1799 shape, one dimension over. Egg 40 (Windows) and egg 41 (Legacy)
# both call this endpoint; egg 42 was the only one that never did.
#
# THE FAIL-SAFE LADDER, AND ALL THREE RUNGS MUST STAY DISTINGUISHABLE.
# A server MUST boot when the plane is unreachable, but it must NEVER quietly
# render something other than what the owner saved. Hard rule 13: a skip is not
# a success, and an unconfigured boot with a clean log is a server with NO
# ADMINS. Each rung prints its own sentence and none of them says "ok".
#   1. FETCHED  -> render it, and cache it as last-known-good
#   2. CACHED   -> plane unreachable; render the cache and SAY how old it is
#   3. DEFAULTS -> no plane, no cache (first boot only); render defaults and SHOUT
# ===========================================================================
BOOT_CACHE="$PRIM/boot-config.cache.json"
CFG_SOURCE="defaults"
CANON=""
DATA_BASE=$(env_or "${PRIMAL_DATA_BASE:-}" "https://data.primalhosted.com")
DATA_BASE="${DATA_BASE%/}"

if [ "$HAVE_JQ" != "1" ]; then
    warn "config: no JSON parser - cannot fetch canonical config."
elif [ -z "$PHSK" ]; then
    log "config: no PHSK_KEY - cannot fetch canonical config"
else
    CANON_RAW=$(curl -fsS --max-time 20 -H "Authorization: Bearer $PHSK" \
        "$DATA_BASE/v1/boot-config" 2>/dev/null)
    # A 200 whose body is not the document we asked for is not a success
    # (rule 13). Require it to PARSE and to carry `config` before believing it.
    if [ -n "$CANON_RAW" ] && printf '%s' "$CANON_RAW" | "$JQ" -e 'has("config")' >/dev/null 2>&1; then
        CANON="$CANON_RAW"
        CFG_SOURCE="fetched"
        # Cache only a FETCH. Writing the cache on any other path would let a
        # degraded boot overwrite the last known-good with something worse.
        if ! printf '%s' "$CANON" > "$BOOT_CACHE" 2>/dev/null; then
            warn "config: could not write the boot-config cache"
        fi
    elif [ -f "$BOOT_CACHE" ] && "$JQ" -e 'has("config")' < "$BOOT_CACHE" >/dev/null 2>&1; then
        CANON=$(cat "$BOOT_CACHE")
        CFG_SOURCE="cache"
        CACHE_AGE_MIN=$(( ( $(date -u +%s) - $(stat -c %Y "$BOOT_CACHE" 2>/dev/null || echo 0) ) / 60 ))
        echo ""
        log "*** DATA PLANE UNREACHABLE - RENDERING FROM CACHE ***"
        log "    cache written ${CACHE_AGE_MIN} min ago (updatedAt=$(printf '%s' "$CANON" | "$JQ" -r '.updatedAt // "null"'))"
        log "    ANY PANEL CHANGE SINCE THEN IS NOT APPLIED ON THIS BOOT."
        echo ""
    elif [ -f "$BOOT_CACHE" ]; then
        warn "config: *** CACHE PRESENT BUT UNREADABLE - falling through to defaults ***"
    else
        log "config: plane unreachable and no cache"
    fi
fi

if [ -z "$CANON" ]; then
    echo ""
    log "*** NO CANONICAL CONFIG AND NO CACHE - THIS SERVER IS UNCONFIGURED ***"
    log "    Booting on built-in defaults: NO ADMINS, NO VIPs, default dino roster."
    log "    Expected only on a server's FIRST boot. Otherwise the plane or the key is wrong."
    echo ""
fi
log "config: canonical config source=$CFG_SOURCE"

# Read the canonical document. Every reader prints NOTHING when the field is
# absent, so each call site can use the same "apply only when the block carries
# it" test - a plane that ships a NEW field before this wrapper knows about it
# can never blank an old one.
cj()     { printf '%s' "$CANON" | "$JQ" -r "$1" 2>/dev/null; }
c_has()  { [ -n "$CANON" ] && printf '%s' "$CANON" | "$JQ" -e --arg f "$2" ".config.$1 | type == \"object\" and has(\$f)" >/dev/null 2>&1; }
c_str()  { cj ".config.$1.$2 // empty"; }
c_bool() { cj "if .config.$1.$2 then \"True\" else \"False\" end"; }
c_list() { cj ".config.$1.$2 // [] | .[]? | tostring"; }
c_count(){ cj ".config.$1.$2 // [] | length"; }

# #1097 - the seat cap. The plane REFUSES an over-cap write, but it can only
# CLAMP on read (a server must boot), so it reports what it clamped. Never let
# that pass silently: a player count the owner did not choose is exactly the
# "saved, but not what you asked for" class this whole lane exists to kill.
if [ -n "$CANON" ]; then
    while IFS= read -r CL; do
        [ -z "$CL" ] && continue
        log "config: *** CLAMPED BY ENTITLEMENT: $CL (your plan's limit)"
    done < <(cj '.clamped // [] | .[] | "\(.key).\(.field) stored=\(.stored) -> applied=\(.applied)"')
    # The roster filter is something the plane CHANGED on the way out. Rule 13 -
    # report it here too, not only in the plane's own log.
    RF=$(cj '.rosterFiltered.dropped // [] | join(",")')
    [ -n "$RF" ] && log "config: *** BROKEN SPECIES REMOVED BY THE PLANE: $RF (they cannot be enabled)"
fi

# ---------------------------------------------------------------------------
# UPDATE GATE (may this server start?). Fail-open on network problems - the
# modded-binary check below is the real enforcement.
# ---------------------------------------------------------------------------
API_BASE_URL=$(env_or "${API_BASE_URL:-}" "https://api.primalheaven.com")
if [ "${UPDATE_GATE:-1}" = "1" ] && [ -n "${SERVER_ID:-}" ] && [ -n "${API_KEY:-}" ]; then
    log "update gate: checking with backend..."
    GATE=$(curl -fsS --max-time 30 -H "X-API-Key: ${API_KEY}" \
        "${API_BASE_URL}/api/updates/server-status/${SERVER_ID}?platform=linux" 2>/dev/null)
    if [ -n "$GATE" ]; then
        BLOCKED=$(grep -o '"blocked": *[a-z]*' <<<"$GATE" | head -1 | grep -o '[a-z]*$')
        if [ "$BLOCKED" = "true" ]; then
            REASON=$(m_field "$GATE" block_reason)
            log "update gate: server is BLOCKED (${REASON:-no reason given})."
            log "update gate: exiting; the panel restarts this server when it is cleared."
            exit 0
        fi
        log "update gate: clear to start."
    else
        warn "update gate unreachable - continuing (fail-open; the binary check enforces)."
    fi
else
    log "update gate: skipped (disabled, or SERVER_ID/API_KEY unset)."
fi

# ---------------------------------------------------------------------------
# STEAMCMD UPDATE (game content + the vanilla binary the mod build is keyed on)
# ---------------------------------------------------------------------------
if [ "${AUTO_UPDATE:-1}" != "0" ] && [ -f ./steamcmd/steamcmd.sh ]; then
    # FORCE_CLEAN_UPDATE: the Isle devs periodically ship an update SteamCMD
    # refuses to apply cleanly (stale appmanifest) - the server keeps booting the
    # OLD code while `validate` reports "up to date". Set 1, restart once, set 0.
    if [ "${FORCE_CLEAN_UPDATE:-0}" = "1" ]; then
        log "update: FORCE_CLEAN_UPDATE=1 - deleting TheIsle/Binaries + steamapps for a clean re-pull..."
        rm -rf "$ROOT/TheIsle/Binaries" "$ROOT/steamapps"
    fi
    log "update: validating The Isle: Evrima (412680, evrima)..."
    ./steamcmd/steamcmd.sh +force_install_dir "$ROOT" +login anonymous \
        +app_update 412680 -beta evrima validate +quit
    # SELF-HEAL: corrupt appmanifest / half-written 'downloading' wedges the
    # update so the binary never lands. Only worth a clean re-fetch if Steam is
    # actually reachable (#346: on a dead link the partial is fine).
    if [ ! -f "$GAME_BINARY" ]; then
        if curl -fsS --max-time 10 -o /dev/null "https://steamcdn-a.akamaihd.net" 2>/dev/null; then
            log "update: (self-heal) binary missing after update - deleting TheIsle/Binaries + steamapps and retrying once..."
            rm -rf "$ROOT/TheIsle/Binaries" "$ROOT/steamapps"
            ./steamcmd/steamcmd.sh +force_install_dir "$ROOT" +login anonymous \
                +app_update 412680 -beta evrima validate +quit
        else
            log "update: (self-heal) SKIPPED - Steam unreachable, partial is not corrupt (#346)."
        fi
    fi
    BID=$(grep -o '"buildid"[[:space:]]*"[0-9]*"' "$ROOT/steamapps/appmanifest_412680.acf" 2>/dev/null | grep -o '[0-9]*')
    [ -n "$BID" ] && log "update: installed buildid = $BID"
else
    log "update: skipped (AUTO_UPDATE=0 or steamcmd missing)"
fi

# The gate is the binary this wrapper launches (#346: check the consumer's own
# path; nothing infers success from the absence of an error).
[ -f "$GAME_BINARY" ] || die "NO-BOOTABLE-BINARY: $GAME_BINARY missing after update. Reinstall, or read the steamcmd output above."
VSIZE=$(stat -c%s "$GAME_BINARY")
[ "$VSIZE" -gt 157286400 ] || die "TRUNCATED-BINARY: $GAME_BINARY is $VSIZE bytes (<150MB) - the pull is incomplete."
VANILLA_HASH=$(md5_of "$GAME_BINARY")
log "binary hash after SteamCMD: ${VANILLA_HASH:0:16}... ($VSIZE bytes)"

# ---------------------------------------------------------------------------
# MODDED BINARY from the Primal binary-distribution API. MANDATORY.
#
# There is NO vanilla fallback on this egg - Ice's rule, twice over: the sig
# bypass our pak needs on Linux lives inside this binary, and running vanilla
# would silently ship a server without the mod's whole surface. If the backend
# has no build for today's vanilla hash, this boot FAILS LOUDLY rather than
# degrading (rule 13). PRIMAL_ALLOW_VANILLA=1 exists for diagnostics only and
# shouts when used.
# ---------------------------------------------------------------------------
MOD_READY=0
for ATTEMPT in 1 2 3 4 5; do
    CURRENT_HASH=$(md5_of "$GAME_BINARY")
    CHECK=$(curl -fsS --max-time 60 -X POST -H "Content-Type: application/json" \
        -d "{\"platform\":\"linux\",\"vanilla_hash\":\"${VANILLA_HASH}\",\"current_modded_hash\":\"${CURRENT_HASH}\"}" \
        "${API_BASE_URL}/commands/binary/check" 2>/dev/null)
    if [ -z "$CHECK" ]; then
        warn "binary check unreachable, attempt ${ATTEMPT}/5"
        sleep 10; continue
    fi
    STATUS=$(m_field "$CHECK" status)
    DOWNLOAD_URL=$(m_field "$CHECK" download_url)
    EXPECTED_MODDED=$(m_field "$CHECK" expected_modded_hash)
    log "binary distribution status: ${STATUS}"
    case "$STATUS" in
        up_to_date)
            MOD_READY=1; break ;;
        update_available)
            log "downloading modded binary..."
            TMP_BIN="$ROOT/.primal_mod_download"
            curl -fsS --max-time 900 -o "$TMP_BIN" "${API_BASE_URL}${DOWNLOAD_URL}" 2>/dev/null
            DL_SIZE=$(stat -c%s "$TMP_BIN" 2>/dev/null || echo 0)
            DL_HASH=$(md5_of "$TMP_BIN")
            if [ "$DL_SIZE" -gt 157286400 ] && { [ -z "$EXPECTED_MODDED" ] || [ "$DL_HASH" = "$EXPECTED_MODDED" ]; }; then
                mv -f "$TMP_BIN" "$GAME_BINARY"
                chmod +x "$GAME_BINARY"
                log "modded binary installed (${DL_SIZE} bytes, hash ${DL_HASH:0:16}...)."
                MOD_READY=1; break
            fi
            warn "download invalid (size ${DL_SIZE}, hash ${DL_HASH:0:16}) - retrying"
            rm -f "$TMP_BIN"
            sleep 10 ;;
        no_mod_available)
            warn "backend has no modded binary for vanilla ${VANILLA_HASH:0:16} yet."
            break ;;
        vanilla_unknown)
            # Two very different states share this answer: (a) the game just
            # updated and no pairing exists yet, or (b) the binary on disk is
            # ALREADY the modded one (SteamCMD left it in place, so the "vanilla"
            # hash we sent is really a modded hash the pairing table does not key
            # on). Disambiguate against the backend's own latest record.
            LATEST=$(curl -fsS --max-time 30 "${API_BASE_URL}/api/binary/latest/linux" 2>/dev/null)
            LATEST_MODDED=$(m_field "$LATEST" modded_hash)
            if [ -n "$LATEST_MODDED" ] && [ "$CURRENT_HASH" = "$LATEST_MODDED" ]; then
                log "on-disk binary IS the current modded binary (${CURRENT_HASH:0:16}) - up to date."
                MOD_READY=1
            else
                warn "backend does not recognize vanilla ${VANILLA_HASH:0:16} and the on-disk binary is not the current modded build."
            fi
            break ;;
        *)
            warn "unexpected status '${STATUS}' - retrying"
            sleep 10 ;;
    esac
done
if [ "$MOD_READY" != "1" ]; then
    if [ "${PRIMAL_ALLOW_VANILLA:-0}" = "1" ]; then
        warn "=============================================================="
        warn "PRIMAL_ALLOW_VANILLA=1: LAUNCHING THE VANILLA BINARY."
        warn "The mod pak will NOT mount and no Primal feature will work."
        warn "This is a diagnostics-only state - unset the variable after."
        warn "=============================================================="
    else
        die "MOD-BINARY-UNAVAILABLE: no verified modded binary for vanilla ${VANILLA_HASH:0:16} and vanilla is forbidden on this egg. The panel will retry; if this repeats, the mod build lags a game update - check ${API_BASE_URL}/api/binary/status."
    fi
fi
MODDED_HASH=$(md5_of "$GAME_BINARY")
log "launch binary hash: ${MODDED_HASH:0:16}..."

# ---------------------------------------------------------------------------
# RENDER Game.ini  (defaults byte-matched to egg 40's; THE DATA PLANE overrides)
# ---------------------------------------------------------------------------
DEFAULT_CLASSES="Dryosaurus,Hypsilophodon,Maiasaura,Pachycephalosaurus,Stegosaurus,Tenontosaurus,Carnotaurus,Ceratosaurus,Deinosuchus,Dilophosaurus,Herrerasaurus,Omniraptor,Pteranodon,Troodon,Beipiaosaurus,Gallimimus,Diabloceratops,Triceratops,Allosaurus,Tyrannosaurus,Kentrosaurus,Austroraptor"

# THESE ARE FIRST-BOOT FALLBACKS, NOT THE SOURCE OF TRUTH. They are byte-matched
# to egg 40's `$cfg` table AND to the plane's own
# `CONFIG_DEFAULTS.server_settings` - move all three or none. A server renders
# them only when the canonical fetch AND the cache both failed, which the ladder
# above has already shouted about.
CFG_ServerName="Primal Heaven Evrima"
CFG_MaxPlayers="150"
CFG_ServerPassword=""
CFG_ServerPasswordEnabled="False"
CFG_RconEnabled="False"
CFG_RconPassword="CHANGEME"
CFG_Discord="https://discord.gg/primalheaven"
# platform default RULED 1 (Ice 2026-08-25, #1574) - was the vendor's hostile 0.02.
CFG_CorpseDecay="1"
CFG_EnableHumans="True"
CFG_DayLength="45"
CFG_NightLength="20"
CFG_GrowthMultiplier="1"
CFG_EnableGlobalChat="True"
CFG_EnableAI="False"
CFG_AIDensity="0"
CFG_SpawnFish="False"
CFG_EnableMutations="True"
CFG_EnableDiets="True"
CFG_FallDamage="True"
CFG_AllowReplay="True"
CFG_DynamicWeather="False"
CFG_WhitelistEnabled="False"
CFG_SpawnPlants="False"
CFG_PlantMultiplier="0"
CFG_EnableMigration="False"
CFG_EnableMassMigration="False"
CFG_EnablePatrolZones="False"
CFG_MapName="Gateway"
CFG_QueueEnabled="True"
CFG_AISpawnInterval=""
CFG_AdminIds=""
CFG_VipIds=""
CFG_Classes=""

# --- THE CANONICAL BLOCK OVERRIDES, FIELD BY FIELD --------------------------
# Every field is applied ONLY when the block actually carries it (`c_has`), so a
# plane that ships a NEW field before this wrapper knows about it cannot blank an
# old one, and a wrapper newer than the plane keeps its own default.
if [ -n "$CANON" ]; then
    c_has server_settings serverName            && CFG_ServerName=$(c_str  server_settings serverName)
    c_has server_settings maxPlayers            && CFG_MaxPlayers=$(c_str  server_settings maxPlayers)
    c_has server_settings serverPassword        && CFG_ServerPassword=$(c_str server_settings serverPassword)
    c_has server_settings serverPasswordEnabled && CFG_ServerPasswordEnabled=$(c_bool server_settings serverPasswordEnabled)
    c_has server_settings rconEnabled           && CFG_RconEnabled=$(c_bool server_settings rconEnabled)
    c_has server_settings rconPassword          && CFG_RconPassword=$(c_str  server_settings rconPassword)
    c_has server_settings discordUrl            && CFG_Discord=$(c_str      server_settings discordUrl)
    c_has server_settings corpseDecay           && CFG_CorpseDecay=$(c_str  server_settings corpseDecay)
    c_has server_settings enableHumans          && CFG_EnableHumans=$(c_bool server_settings enableHumans)
    c_has server_settings dayLengthMin          && CFG_DayLength=$(c_str    server_settings dayLengthMin)
    c_has server_settings nightLengthMin        && CFG_NightLength=$(c_str  server_settings nightLengthMin)
    c_has server_settings growthMultiplier      && CFG_GrowthMultiplier=$(c_str server_settings growthMultiplier)
    c_has server_settings enableGlobalChat      && CFG_EnableGlobalChat=$(c_bool server_settings enableGlobalChat)
    c_has server_settings enableAi              && CFG_EnableAI=$(c_bool    server_settings enableAi)
    c_has server_settings aiDensity             && CFG_AIDensity=$(c_str    server_settings aiDensity)
    c_has server_settings spawnFish             && CFG_SpawnFish=$(c_bool   server_settings spawnFish)
    c_has server_settings enableMutations       && CFG_EnableMutations=$(c_bool server_settings enableMutations)
    c_has server_settings enableDiets           && CFG_EnableDiets=$(c_bool server_settings enableDiets)
    c_has server_settings fallDamage            && CFG_FallDamage=$(c_bool  server_settings fallDamage)
    c_has server_settings allowReplay           && CFG_AllowReplay=$(c_bool server_settings allowReplay)
    c_has server_settings dynamicWeather        && CFG_DynamicWeather=$(c_bool server_settings dynamicWeather)
    c_has server_settings whitelistEnabled      && CFG_WhitelistEnabled=$(c_bool server_settings whitelistEnabled)
    c_has server_settings spawnPlants           && CFG_SpawnPlants=$(c_bool server_settings spawnPlants)
    c_has server_settings plantMultiplier       && CFG_PlantMultiplier=$(c_str server_settings plantMultiplier)
    c_has server_settings enableMigration       && CFG_EnableMigration=$(c_bool server_settings enableMigration)
    c_has server_settings enableMassMigration   && CFG_EnableMassMigration=$(c_bool server_settings enableMassMigration)
    c_has server_settings enablePatrolZones     && CFG_EnablePatrolZones=$(c_bool server_settings enablePatrolZones)
    c_has server_settings mapName               && CFG_MapName=$(c_str      server_settings mapName)
    c_has server_settings queueEnabled          && CFG_QueueEnabled=$(c_bool server_settings queueEnabled)
    # Empty is NOT zero: it omits the Game.ini line so the game's own default stands.
    c_has server_settings aiSpawnInterval       && CFG_AISpawnInterval=$(c_str server_settings aiSpawnInterval)
    # Lists. An EMPTY array is a legitimate value meaning "none" (admins/vips);
    # for allowedClasses it means "use the built-in roster", which is why only a
    # NON-empty list replaces DEFAULT_CLASSES below.
    c_has server_settings adminSteamIds  && CFG_AdminIds=$(c_list  server_settings adminSteamIds)
    c_has server_settings vipSteamIds    && CFG_VipIds=$(c_list    server_settings vipSteamIds)
    c_has server_settings allowedClasses && CFG_Classes=$(c_list   server_settings allowedClasses)
    log "config: canonical $(echo "$CFG_SOURCE" | tr '[:lower:]' '[:upper:]') (admins=$(c_count server_settings adminSteamIds) vips=$(c_count server_settings vipSteamIds) classes=$(c_count server_settings allowedClasses) players=$CFG_MaxPlayers scope=$(cj '.scope.server_settings // "?"') updatedAt=$(cj '.updatedAt // "null"'))"
fi

# --- #2024: on the DEFAULTS rung ONLY, identity comes from the egg env --------
# The built-in defaults above are Primal HEAVEN's (they are byte-matched to egg 40
# and to the plane's CONFIG_DEFAULTS - move all three or none). On a Primal HOSTED
# node a first/keyless boot that renders them announces itself as "Primal Heaven
# Evrima" / 150 slots / RconPassword=CHANGEME in the EOS browser (#2024, measured on
# eu1 2026-09-05). The egg env is exactly what the provisioner pinned for THIS
# server, so on this rung the three identity fields come from it. Every other field
# stays on the built-in default so #2023's property (the panel owns config) holds -
# and on the fetched/cache rungs the env is NOT consulted at all (see DEAD_SET below).
if [ -z "$CANON" ]; then
    ID_SEEDED=""
    if [ -n "${SERVER_NAME:-}" ];   then CFG_ServerName="$SERVER_NAME";     ID_SEEDED="$ID_SEEDED ServerName"; fi
    if [ -n "${MAX_PLAYERS:-}" ];   then CFG_MaxPlayers="$MAX_PLAYERS";     ID_SEEDED="$ID_SEEDED MaxPlayerCount"; fi
    if [ -n "${RCON_PASSWORD:-}" ]; then CFG_RconPassword="$RCON_PASSWORD"; ID_SEEDED="$ID_SEEDED RconPassword"; fi
    if [ -n "$ID_SEEDED" ]; then
        log "config: defaults rung - identity seeded from the egg env (#2024):$ID_SEEDED"
    else
        log "config: defaults rung - egg env carries no identity; rendering the built-in name/slots (#2024)"
    fi
fi

# --- LEGACY EGG VARIABLES: no longer read, and deliberately not silently -----
# Until 2026-09-05 this wrapper rendered Game.ini from these. It does not any
# more (the panel stopped writing them on 2026-08-10). If one is still set,
# say so ONCE and loudly rather than letting someone edit a dead field for a
# week - hard rule 13. Only when we actually have canon: on the defaults rung
# the ladder has already shouted, and adding a second scary block there would
# bury it.
if [ -n "$CANON" ]; then
    DEAD_SET=""
    for DV in SERVER_NAME MAX_PLAYERS ADMIN_STEAM_IDS VIP_STEAM_IDS ALLOWED_CLASSES \
              SERVER_PASSWORD SERVER_PASSWORD_ENABLED RCON_ENABLED RCON_PASSWORD DISCORD_URL \
              CORPSE_DECAY ENABLE_HUMANS SERVER_DAY_LENGTH SERVER_NIGHT_LENGTH GROWTH_MULTIPLIER \
              ENABLE_GLOBAL_CHAT ENABLE_AI AI_DENSITY SPAWN_FISH ENABLE_MUTATIONS ENABLE_DIETS \
              FALL_DAMAGE ALLOW_REPLAY DYNAMIC_WEATHER WHITELIST_ENABLED SPAWN_PLANTS \
              PLANT_MULTIPLIER ENABLE_MIGRATION ENABLE_MASS_MIGRATION ENABLE_PATROL_ZONES \
              MAP_NAME QUEUE_ENABLED AI_SPAWN_INTERVAL PRIMAL_MOD_INI PRIMAL_FORCE_DINO; do
        [ -n "$(echo -n "${!DV:-}" | tr -d '[:space:]')" ] && DEAD_SET="$DEAD_SET $DV"
    done
    if [ -n "$DEAD_SET" ]; then
        log "config: NOTE these legacy egg variable(s) are still set and are NO LONGER READ (config comes from the panel):"
        log "config:     $(echo "$DEAD_SET" | sed 's/^ //')"
    fi
fi

# Ports: game/query = SERVER_PORT (query==game BAKED, no variable). Queue and
# rcon are egg variables because standard Wings injects no extra allocations.
GAME_PORT="${SERVER_PORT:?SERVER_PORT not set}"
CFG_QueuePort=$(env_or "${QUEUE_PORT:-}" "$((GAME_PORT + 1))")
CFG_RconPort=$(env_or "${RCON_PORT:-}" "$((GAME_PORT + 2))")

# The server-config.json OVERLAY IS NOT SUPPORTED ON THIS EGG, and never will be.
# It is the file from #1101: nothing on the platform can write it, and on Dino
# Vibes it silently OUTRANKED the customer's panel. The data plane is the single
# source of truth now (fetched above). If the file exists, say so LOUDLY and
# apply NOTHING from it.
if [ -f "$PRIM/server-config.json" ]; then
    warn "=============================================================="
    warn "_primal/server-config.json EXISTS but the overlay lane is NOT"
    warn "supported on the Linux egg. NOTHING in it was applied."
    warn "Move its values into the egg variables (the source of truth)."
    warn "=============================================================="
fi

render_id_lines() { # $1 = ini key, $2 = raw csv/newline list, $3 = emptyline
    local key="$1" raw="$2" out="" id n=0
    while IFS= read -r id; do
        id=$(echo -n "$id" | tr -d '[:space:]')
        [ -z "$id" ] && continue
        out+="${key}=${id}"$'\n'; n=$((n+1))
    done < <(echo "$raw" | tr ',;' '\n')
    if [ "$n" -eq 0 ] && [ -n "$3" ]; then out="${key}=${3}"$'\n'; fi
    printf '%s' "$out"
}

# Joined with explicit newlines: $(...) strips the trailing newline, so a
# plain += would weld the next block onto the previous line (caught by the
# render smoke - "VIPs=0" landed inside an AdminsSteamIDs line).
GSB_A=$(render_id_lines "AdminsSteamIDs" "$CFG_AdminIds" "0")
GSB_V=$(render_id_lines "VIPs" "$CFG_VipIds" "0")
# An EMPTY roster is not "no dinos" - it means use the built-in one. Matches
# egg 40, and matters because the plane's broken-species filter CAN empty a
# roster that listed only broken species.
CLASSES_RAW=$(env_or "$CFG_Classes" "$DEFAULT_CLASSES")
GSB_C=$(render_id_lines "AllowedClasses" "$CLASSES_RAW" "")
GSB="$GSB_A"$'\n'"$GSB_V"$'\n'"$GSB_C"
N_CLASSES=$(grep -c '^AllowedClasses=' <<<"$GSB" || true)

GI=$(cat "$PRIM/Game.ini.tmpl") || die "Game.ini.tmpl missing from _primal/ (reinstall the egg)"
GI=${GI//'{{ServerName}}'/$CFG_ServerName}
GI=${GI//'{{MaxPlayers}}'/$CFG_MaxPlayers}
GI=${GI//'{{ServerPasswordEnabled}}'/$CFG_ServerPasswordEnabled}
GI=${GI//'{{ServerPassword}}'/$CFG_ServerPassword}
GI=${GI//'{{RconEnabled}}'/$CFG_RconEnabled}
GI=${GI//'{{RconPassword}}'/$CFG_RconPassword}
GI=${GI//'{{Discord}}'/$CFG_Discord}
GI=${GI//'{{CorpseDecay}}'/$CFG_CorpseDecay}
GI=${GI//'{{EnableHumans}}'/$CFG_EnableHumans}
GI=${GI//'{{DayLength}}'/$CFG_DayLength}
GI=${GI//'{{NightLength}}'/$CFG_NightLength}
GI=${GI//'{{GrowthMultiplier}}'/$CFG_GrowthMultiplier}
GI=${GI//'{{EnableGlobalChat}}'/$CFG_EnableGlobalChat}
GI=${GI//'{{EnableAI}}'/$CFG_EnableAI}
GI=${GI//'{{AIDensity}}'/$CFG_AIDensity}
GI=${GI//'{{SpawnFish}}'/$CFG_SpawnFish}
GI=${GI//'{{EnableMutations}}'/$CFG_EnableMutations}
GI=${GI//'{{EnableDiets}}'/$CFG_EnableDiets}
GI=${GI//'{{FallDamage}}'/$CFG_FallDamage}
GI=${GI//'{{AllowReplay}}'/$CFG_AllowReplay}
GI=${GI//'{{DynamicWeather}}'/$CFG_DynamicWeather}
GI=${GI//'{{WhitelistEnabled}}'/$CFG_WhitelistEnabled}
GI=${GI//'{{SpawnPlants}}'/$CFG_SpawnPlants}
GI=${GI//'{{PlantMultiplier}}'/$CFG_PlantMultiplier}
GI=${GI//'{{EnableMigration}}'/$CFG_EnableMigration}
GI=${GI//'{{EnableMassMigration}}'/$CFG_EnableMassMigration}
GI=${GI//'{{EnablePatrolZones}}'/$CFG_EnablePatrolZones}
GI=${GI//'{{MapName}}'/$CFG_MapName}
GI=${GI//'{{QueueEnabled}}'/$CFG_QueueEnabled}
GI=${GI//'{{AISpawnInterval}}'/$CFG_AISpawnInterval}
GI=${GI//'{{GamePort}}'/$GAME_PORT}
GI=${GI//'{{QueuePort}}'/$CFG_QueuePort}
GI=${GI//'{{RconPort}}'/$CFG_RconPort}
GI=${GI//'{{GAMESTATEBASE}}'/$GSB}

# AISpawnInterval is OPT-IN: an unset variable removes the line entirely rather
# than pinning a guessed engine default (same idiom as egg 40). Stripped by
# name, never "drop all empty values" - ServerPassword= legitimately renders
# empty.
if [ -z "$(echo -n "$CFG_AISpawnInterval" | tr -d '[:space:]')" ]; then
    GI=$(sed '/^[[:space:]]*AISpawnInterval[[:space:]]*=[[:space:]]*$/d' <<<"$GI")
fi

printf '%s\n' "$GI" | tr -d '\r' > "$CONFIG_DIR/Game.ini"
log "rendered Game.ini (players=$CFG_MaxPlayers, classes=$N_CLASSES, port=$GAME_PORT query=$GAME_PORT queue=$CFG_QueuePort rcon=$CFG_RconPort)"

# ---------------------------------------------------------------------------
# RENDER Engine.ini: static template + the Primal mod's config section.
#
# The pak reads its per-server key as a UE Config property on the game session
# BP class - Engine.ini under that class's section is the SOLE token source
# (-PrimalToken stays off, #436; GetCommandLine() returns nothing in a cooked
# server, #501; config ARRAYS do not load, #572 - every value is one csv
# string). Written with LF endings: a CR lands inside the token -> 401.
# ---------------------------------------------------------------------------
ENG=$(cat "$PRIM/Engine.ini.tmpl") || die "Engine.ini.tmpl missing from _primal/ (reinstall the egg)"

# ---------------------------------------------------------------------------
# THE PAK'S CONFIG SECTION - per-server, from the plane's `mod_settings` block.
#
# Until 2026-09-05 the three keys below were FLEET-WIDE LITERALS here and the
# escape hatch was `PRIMAL_MOD_INI`, a generic "Key=Value;..." setter. Both are
# gone, for the reasons egg 40 already recorded:
#   * the literals mean changing one key for one customer costs a public-repo
#     commit, a CI rebuild of 4 ghcr images and an egg import;
#   * a GENERIC key setter can write ANY key under a name no allowlist checks -
#     including keys the panel gates - so it is the panel's authority with the
#     safety off. #1094 removed it on Windows. (It was DECLARED in this egg, so
#     unlike egg 40's it could actually fire.) The replacement for "a pak key
#     with no field" is to add it to the plane's `mod_settings` block.
#
# Key names + value forms are the PAK'S: True/False (not 1/0), csv (not array)
# - config ARRAYS silently do not load on a BP class (#572).
# ---------------------------------------------------------------------------

# Format a number the way egg 40's ModNum does, so the two eggs render the same
# bytes: BodyHoldSec 10 -> "10.0", AIMaxCount 40 -> "40". LC_ALL=C because a
# comma decimal separator in Engine.ini is a key the pak cannot read.
mod_num() { # $1 = raw, $2 = decimals, $3 = fallback
    local out
    out=$(LC_ALL=C printf "%.$2f" "$1" 2>/dev/null)
    if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$3"; fi
}

# #1593 DEFENSIVE SKIP - the LAST line of defence, and deliberately the weakest.
#
# On 2026-08-26 a paying customer's server was down 1h40m because
# `speciesCapList` held a single entry `5`. Entries are `Species:N`; with no
# colon the pak's species half parses EMPTY, the cap tick builds a package name
# with a double slash, and UE aborts - fatal one `SpeciesCapEvery` tick after
# map load, and RE-ARMED by every restart.
#
# THE REAL FIX IS AT THE PLANE (`config.ts` ENTRY_SHAPES), which refuses a
# malformed entry BY NAME so the owner is told. This is NOT that and must never
# be mistaken for it: by the time we are here the customer is not present, the
# boot is - so the only correct behaviour left is skip-and-SAY-SO. A fully
# skipped list renders EMPTY, which OMITS the line, so the pak's own default
# stands: the safe outcome, and not a silent one.
mod_csv_shaped() { # $1 = newline list, $2 = label, $3 = 1 when <Species>:<N> is required
    local kept="" idx=0 e bad
    while IFS= read -r e; do
        e=$(printf '%s' "$e" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -z "$e" ] && continue
        idx=$((idx + 1))
        bad=""
        if [ "$3" = "1" ]; then
            [[ "$e" =~ ^[A-Za-z0-9_]{1,64}:[0-9]{1,9}$ ]] || bad="not <Species>:<N>"
        else
            [[ "$e" =~ ^[A-Za-z0-9_]{1,64}$ ]] || bad="not a plain species name"
        fi
        if [ -n "$bad" ]; then
            # >&2 IS LOAD-BEARING. This function's stdout IS its return
            # value (it is called inside a command substitution), so a
            # message printed on stdout is APPENDED TO THE INI VALUE:
            # SpeciesCapList= gets the log line, then a newline, then the
            # list. That is the Engine.ini line injection this guard exists
            # to prevent, caused by the guard itself. The render test caught
            # it on 2026-09-05; it is why that test exists.
            log "config: SKIPPED malformed $2 entry $idx ('$e') - $bad. BUGS #1593; the line is rendered WITHOUT it. Fix it in the panel." >&2
            continue
        fi
        [ -n "$kept" ] && kept="$kept,"
        kept="$kept$e"
    done <<< "$1"
    printf '%s' "$kept"
}

declare -A PAK_EXTRA=()
# Order is egg 40's `$modDefaults` order - the cutover proof is a byte-diff and
# a reordering diff is noise that hides a real one.
PAK_EXTRA_ORDER=("BodySweepOn" "BodySweepList" "BodyHoldSec" "BodySweepLiftZ" "TreeKnockdownOn" "AIMaxCount" "SpeciesCapEvery")
PAK_EXTRA[BodySweepOn]="True"
PAK_EXTRA[BodySweepList]="Triceratops"
PAK_EXTRA[BodyHoldSec]="10.0"
PAK_EXTRA[BodySweepLiftZ]="150000"
PAK_EXTRA[TreeKnockdownOn]="False"
PAK_EXTRA[AIMaxCount]="40"
PAK_EXTRA[SpeciesCapEvery]="30"

if [ -n "$CANON" ]; then
    c_has mod_settings bodySweepOn     && PAK_EXTRA[BodySweepOn]=$(c_bool mod_settings bodySweepOn)
    c_has mod_settings treeKnockdownOn && PAK_EXTRA[TreeKnockdownOn]=$(c_bool mod_settings treeKnockdownOn)
    c_has mod_settings bodySweepList   && PAK_EXTRA[BodySweepList]=$(mod_csv_shaped "$(c_list mod_settings bodySweepList)" "BodySweepList" 0)
    c_has mod_settings bodyHoldSec     && PAK_EXTRA[BodyHoldSec]=$(mod_num "$(c_str mod_settings bodyHoldSec)" 1 "10.0")
    c_has mod_settings bodySweepLiftZ  && PAK_EXTRA[BodySweepLiftZ]=$(mod_num "$(c_str mod_settings bodySweepLiftZ)" 0 "150000")
    c_has mod_settings aiMaxCount      && PAK_EXTRA[AIMaxCount]=$(mod_num "$(c_str mod_settings aiMaxCount)" 0 "40")
    c_has mod_settings speciesCapEvery && PAK_EXTRA[SpeciesCapEvery]=$(mod_num "$(c_str mod_settings speciesCapEvery)" 0 "30")
fi

# #1071 WIRE SENTINELS, DERIVED - never a panel field, never authored.
# The pak reads a numeric key as UNSET (keeping its baked default) unless the
# paired `*Set=True` is present too. Emitting the number without its sentinel
# ships a setting that SILENTLY does nothing - which is what this egg did until
# 2026-09-05 for BodyHoldSec. Inserted immediately AFTER their numeric so the
# rendered byte order matches egg 40's.
PAK_ORDER_NEW=()
for K in "${PAK_EXTRA_ORDER[@]}"; do
    PAK_ORDER_NEW+=("$K")
    if [ "$K" = "BodyHoldSec" ];    then PAK_ORDER_NEW+=("BodyHoldSet"); PAK_EXTRA[BodyHoldSet]="True"; fi
    if [ "$K" = "BodySweepLiftZ" ]; then PAK_ORDER_NEW+=("BSLiftSet");   PAK_EXTRA[BSLiftSet]="True";   fi
done
PAK_EXTRA_ORDER=("${PAK_ORDER_NEW[@]}")

# EMPTY IS NOT ZERO: these two OMIT their line so the pak's own default holds.
PAK_SPECIES_CAP=""
if [ -n "$CANON" ] && c_has mod_settings speciesCapList; then
    PAK_SPECIES_CAP=$(mod_csv_shaped "$(c_list mod_settings speciesCapList)" "SpeciesCapList" 1)
fi
[ -n "$PAK_SPECIES_CAP" ] && { PAK_EXTRA_ORDER+=("SpeciesCapList"); PAK_EXTRA[SpeciesCapList]="$PAK_SPECIES_CAP"; }

# ForceDinoList: same omit-when-empty idiom. The value lands on the game's
# LAUNCH LINE, where Compsognathus/Pterodactylus are an instant client crash and
# a bricked character (#378), so the panel validates it against an allow-list
# before it ever reaches the plane. This script renders what that gated writer
# stored - it does NOT re-derive the list, and there is deliberately NO
# hardcoded fallback (one silently force-RE-ADDED Baryonyx/Oviraptor after they
# were stripped from the roster).
PAK_FORCE_DINO=""
if [ -n "$CANON" ] && c_has mod_settings forceDinoList; then
    PAK_FORCE_DINO=$(mod_csv_shaped "$(c_list mod_settings forceDinoList)" "ForceDinoList" 0)
fi

if [ "${ENABLE_PRIMAL_MOD:-0}" = "1" ] && [ -n "$PHSK" ]; then
    SESS_BLOCK="[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]"$'\n'
    SESS_BLOCK+="ApiToken=$PHSK"$'\n'
    SESS_BLOCK+="PollURL=$DATA_BASE/v1/commands/text"$'\n'
    [ -n "$PAK_FORCE_DINO" ] && SESS_BLOCK+="ForceDinoList=$PAK_FORCE_DINO"$'\n'
    for K in "${PAK_EXTRA_ORDER[@]}"; do
        SESS_BLOCK+="$K=${PAK_EXTRA[$K]}"$'\n'
    done

    # --- CARRY FORWARD every hand-set pak key this script does not own (#1137) -
    # The emit REPLACES the whole section, so any key not re-emitted is destroyed
    # on every boot. Until now this egg destroyed all of them, which makes a new
    # pak knob unsettable from this box (BUILD 120's IrisCensus* scalars are the
    # pattern: hand-added, worked for one boot, then reverted).
    #
    # The set below is "keys this script OWNS", NOT "keys it emitted this boot",
    # and that distinction is the whole correctness of this block: ForceDinoList
    # and SpeciesCapList are deliberately OMITTED when empty, so judging by what
    # was emitted would carry their OLD value forward for ever and make them
    # silently un-clearable.
    #
    # A carried key is operator-writable through the file manager, so the pak
    # must never read a key whose VALUE is a console command - config selects
    # from a CLOSED SET the pak owns. That rule lives with the pak; it is stated
    # here because this is where the persistence it depends on is introduced.
    PAK_MANAGED=" apitoken polluri pollurl forcedinolist speciescaplist "
    for K in "${PAK_EXTRA_ORDER[@]}"; do
        PAK_MANAGED="$PAK_MANAGED$(echo "$K" | tr '[:upper:]' '[:lower:]') "
    done
    CARRIED=""
    CARRIED_N=0
    if [ -f "$CONFIG_DIR/Engine.ini" ]; then
        # Scoped to the pak's OWN section: a bare whole-file scan would match a
        # same-named key in [Core.Log] and silently promote it in here.
        while IFS= read -r LN; do
            case "$LN" in ''|\;*|\#*|\[*) continue ;; esac
            case "$LN" in *=*) : ;; *) continue ;; esac
            CK="${LN%%=*}"
            CK=$(printf '%s' "$CK" | sed 's/[[:space:]]*$//')
            [ -z "$CK" ] && continue
            case "$PAK_MANAGED" in *" $(echo "$CK" | tr '[:upper:]' '[:lower:]') "*) continue ;; esac
            CARRIED+="$LN"$'\n'
            CARRIED_N=$((CARRIED_N + 1))
        done < <(awk 'BEGIN{inb=0}
            /^[[:space:]]*\[\/Game\/TheIsle\/Core\/Session\/BP_TIGameSession\.BP_TIGameSession_C\]/{inb=1; next}
            /^[[:space:]]*\[/{inb=0}
            inb' "$CONFIG_DIR/Engine.ini")
    fi
    [ -n "$CARRIED" ] && SESS_BLOCK+="$CARRIED"

    # Idempotent: strip any existing copy of the section from the template
    # first (UE takes the first copy, so a duplicate would silently win with
    # the wrong value), then append ours.
    ENG=$(awk 'BEGIN{skip=0}
        /^\[\/Game\/TheIsle\/Core\/Session\/BP_TIGameSession\.BP_TIGameSession_C\]/{skip=1; next}
        /^\[/{skip=0}
        !skip' <<<"$ENG")
    ENG="$(printf '%s' "$ENG" | sed -e 's/[[:space:]]*$//')"$'\n\n'"$SESS_BLOCK"
    log "Engine.ini: Primal session block set (tokenlen=${#PHSK}, poll=$DATA_BASE/v1/commands/text)"
    PAK_KV=""
    for K in "${PAK_EXTRA_ORDER[@]}"; do PAK_KV+="$K=${PAK_EXTRA[$K]} "; done
    log "Engine.ini: pak keys (source=$CFG_SOURCE) ForceDinoList=$PAK_FORCE_DINO $PAK_KV"
    [ "$CARRIED_N" -gt 0 ] && log "Engine.ini: carried forward $CARRIED_N hand-set pak key(s) this script does not own (#1137)"
else
    log "Engine.ini: no Primal session block (mod disabled or no PHSK_KEY)"
fi

printf '%s\n' "$ENG" | tr -d '\r' > "$CONFIG_DIR/Engine.ini"
log "wrote Engine.ini (LF endings; a CR would land inside the token - 401)"

# ---------------------------------------------------------------------------
# PRIMAL PAK MOD (pakchunk50-Windows_P.{pak,ucas,utoc} - the Windows-named
# triplet mounts fine on the Linux build, proven 2026-08-04). Same lane as egg
# 40: fetch manifest, and if the version changed OR any placed file's sha
# differs, re-download ALL files to a stage, sha-verify EACH, and only when
# EVERY file verifies move the set into Content/Paks. A partial triplet is
# NEVER placed. sha is the authority, version only the fast path (#410).
# Fail-soft: a customer server must still start if the manifest is unreachable
# - it boots with whatever pak is already on disk (possibly none).
# ---------------------------------------------------------------------------
PAK_VER_FILE="$PRIM/primal-pak.version"
if [ "${ENABLE_PRIMAL_MOD:-0}" = "1" ]; then
    PAK_MANIFEST_URL=$(env_or "${PRIMAL_MOD_MANIFEST:-}" "$R2_BASE/primal-mod-evrima-pak/latest.json")
    PM=$(curl -fsS --max-time 20 "$PAK_MANIFEST_URL" 2>/dev/null)
    if [ -z "$PM" ]; then
        log "primal-pak: manifest unreachable ($PAK_MANIFEST_URL) - booting with existing pak (if any)"
    else
        PM_VER=$(m_field "$PM" version)
        PM_BUILD=$(m_field "$PM" build)
        mapfile -t P_NAMES < <(m_fields "$PM" name)
        mapfile -t P_URLS  < <(m_fields "$PM" url)
        mapfile -t P_SHAS  < <(m_fields "$PM" sha256)
        HAVE_VER=$(cat "$PAK_VER_FILE" 2>/dev/null | tr -d '[:space:]')
        NEEDS=0
        [ "$PM_VER" != "$HAVE_VER" ] && NEEDS=1
        if [ "$NEEDS" = "0" ]; then
            for i in "${!P_NAMES[@]}"; do
                DST="$PAKS_DIR/${P_NAMES[$i]}"
                if [ ! -f "$DST" ] || [ "$(sha256_of "$DST")" != "$(echo "${P_SHAS[$i]}" | tr 'A-F' 'a-f')" ]; then
                    NEEDS=1; break
                fi
            done
        fi
        if [ "$NEEDS" = "1" ]; then
            log "primal-pak: updating '$HAVE_VER' -> '$PM_VER' (${#P_NAMES[@]} files)..."
            mkdir -p "$PAKS_DIR"
            STAGE="$PRIM/pak-stage"
            rm -rf "$STAGE"; mkdir -p "$STAGE"
            ALL_OK=1
            for i in "${!P_NAMES[@]}"; do
                TMPF="$STAGE/${P_NAMES[$i]}"
                curl -fsS --max-time 600 -o "$TMPF" "${P_URLS[$i]}" 2>/dev/null
                SHA=$(sha256_of "$TMPF")
                if [ "$SHA" != "$(echo "${P_SHAS[$i]}" | tr 'A-F' 'a-f')" ]; then
                    log "primal-pak: sha256 MISMATCH on ${P_NAMES[$i]} (got ${SHA:0:16}) - discarding this update"
                    ALL_OK=0; break
                fi
            done
            if [ "$ALL_OK" = "1" ]; then
                for i in "${!P_NAMES[@]}"; do
                    mv -f "$STAGE/${P_NAMES[$i]}" "$PAKS_DIR/${P_NAMES[$i]}"
                done
                echo "$PM_VER" > "$PAK_VER_FILE"
                log "primal-pak: pak $PM_VER ready ($PM_BUILD) -> $PAKS_DIR"
            else
                log "primal-pak: update discarded on verify failure - keeping the existing pak (if any)"
            fi
            rm -rf "$STAGE"
        else
            log "primal-pak: up to date ($HAVE_VER)"
        fi
    fi
    [ -z "$PHSK" ] && log "primal-pak: WARNING: no PHSK_KEY set - the pak will load but cannot authenticate to the data plane"
    # NO SIGBYPASS LANE ON LINUX - deliberate, not an omission. The Windows egg
    # places dsound.dll + UniversalSigBypasser.asi; here the signature bypass is
    # inside the modded binary fetched above (which is why vanilla is forbidden).
    log "sigbypass: not needed on Linux (built into the modded binary; see README)"
else
    log "primal-pak: disabled (ENABLE_PRIMAL_MOD != 1)"
fi

# ---------------------------------------------------------------------------
# CONFIRM STARTUP with the backend (best-effort monitoring)
# ---------------------------------------------------------------------------
if [ -n "${SERVER_ID:-}" ] && [ -n "${API_KEY:-}" ]; then
    CONF=$(curl -fsS -o /dev/null -w "%{http_code}" --max-time 30 -X POST \
        -H "Content-Type: application/json" -H "X-API-Key: ${API_KEY}" \
        -d "{\"server_id\":\"${SERVER_ID}\",\"server_name\":\"${SERVER_NAME:-$SERVER_ID}\",\"server_type\":\"survival\",\"platform\":\"linux\",\"panel_name\":\"${PANEL_NAME:-primal}\",\"vanilla_hash\":\"${VANILLA_HASH}\",\"modded_hash\":\"${MODDED_HASH}\",\"pterodactyl_uuid\":\"${P_SERVER_UUID:-}\"}" \
        "${API_BASE_URL}/api/updates/confirm-startup" 2>/dev/null)
    [ "$CONF" = "200" ] && log "startup confirmed with backend." || warn "startup confirmation failed (HTTP ${CONF:-none}) - continuing."
fi

# Dry-run hook: render the configs and stop (local tests + config preview).
if [ "${PRIMAL_RENDER_ONLY:-0}" = "1" ]; then log "(render-only) done"; exit 0; fi

# ---------------------------------------------------------------------------
# LAUNCH. exec, foreground - the Linux Shipping binary does not detach, so
# Wings tracks the real server process (no supervision loop needed, unlike the
# Windows wrapper).
#
# Arg shape matches the PROVEN Linux launch (testing:deathmatch / the clone):
#   -QueryPort=$PORT -Port=$PORT -ini:Engine:[EpicOnlineServices]:...
# QUERY PORT == GAME PORT, always - baked, no variable, Ice's rule.
# ---------------------------------------------------------------------------
EOS_ID=$(env_or "${EOS_CLIENT_ID:-}" "xyza7891gk5PRo3J7G9puCJGFJjmEguW")
EOS_SECRET=$(env_or "${EOS_CLIENT_SECRET:-}" "pKWl6t5i9NJK8gTpVlAxzENZ65P8hYzodV8Dqe5Rlc8")

EXTRA_ARGS=()
# ---------------------------------------------------------------------------
# 🔴 MULTIHOME IS OPT-IN HERE, AND MUST NOT DEFAULT TO $SERVER_IP.
#
# Egg 40 defaults it to the allocation IP that feathers injects as SERVER_IP,
# and that is correct THERE: on the native-Windows node the public IP really is
# on the box's own interface. In a Docker container it is NOT - the container
# sees only its bridge address, so `-MULTIHOME=<public ip>` makes UE try to bind
# an address it does not have:
#
#   LogNet: Warning: Could not create socket for bind address 172.93.100.254,
#           got error BSD IPv4/6: binding to port 25053 failed (21)
#   LogNet: Error: LoadMap: failed to Listen(...Gateway?Name=Player?listen)
#
# The server then never listens, never creates an EOS session, and therefore can
# NEVER be ingested into the in-game community list - which is the entire reason
# this egg exists (#652). Measured on the proving server 2026-08-04; carrying the
# egg-40 line over unchanged is what produced it.
#
# The proven-working Linux references (egg 17 / the listing-test clone) pass no
# -MULTIHOME at all and are listed, so all-interfaces is the right default here.
# MULTIHOME_IP survives as an ADMIN escape hatch for a future multi-IP node, and
# only takes effect when someone sets it deliberately.
# ---------------------------------------------------------------------------
MULTIHOME=$(echo -n "${MULTIHOME_IP:-}" | tr -d '[:space:]')
if [ -n "$MULTIHOME" ] && [ "$MULTIHOME" != "0.0.0.0" ] && [[ "$MULTIHOME" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    # Refuse an address this container cannot actually bind, rather than letting
    # UE fail to listen and look like a mysterious "server won't start".
    if ip -4 addr show 2>/dev/null | grep -q "inet ${MULTIHOME}/"; then
        EXTRA_ARGS+=("-MULTIHOME=$MULTIHOME")
        export EOS_OVERRIDE_HOST_IP="$MULTIHOME"
        log "start: MULTIHOME=$MULTIHOME + EOS_OVERRIDE_HOST_IP (advertise this IP to the server browser)"
    else
        warn "MULTIHOME_IP=$MULTIHOME is NOT on any interface in this container - IGNORING it."
        warn "Binding it would fail (BSD error 21) and the server would never listen or"
        warn "create an EOS session. Binding all interfaces instead."
    fi
elif [ -n "${SERVER_IP:-}" ]; then
    log "start: multihome not set - binding all interfaces (SERVER_IP=${SERVER_IP} is deliberately NOT used; a container cannot bind it)"
fi
# -PrimalForceDino is INERT in a cooked server (#501) - the Engine.ini
# ForceDinoList key above is what the pak loads. Passed anyway for parity with
# egg 40's launch line. Per #387 treat it as single-species.
if [ -n "$PAK_FORCE_DINO" ]; then
    EXTRA_ARGS+=("-PrimalForceDino=$PAK_FORCE_DINO")
    log "start: PrimalForceDino=$PAK_FORCE_DINO (force-enabled species; ini key is the live path)"
fi
# -PrimalToken is DISABLED BY DEFAULT (#436): with the flag AND Engine.ini both
# set, the token read 54 bytes for a 53-byte key. Engine.ini is the single
# token source. PRIMAL_TOKEN_ARG=1 puts the flag back for diagnostics.
if [ "${PRIMAL_TOKEN_ARG:-0}" = "1" ] && [ "${ENABLE_PRIMAL_MOD:-0}" = "1" ] && [ -n "$PHSK" ]; then
    EXTRA_ARGS+=("-PrimalToken=$PHSK")
    log "start: PrimalToken set (len=${#PHSK}) - launch-flag token path ENABLED"
elif [ "${ENABLE_PRIMAL_MOD:-0}" = "1" ] && [ -n "$PHSK" ]; then
    log "start: PrimalToken flag omitted - Engine.ini is the single token source (len=${#PHSK})"
fi

log "start: launching on port $GAME_PORT (query $GAME_PORT, queue $CFG_QueuePort, rcon $CFG_RconPort)..."
exec "$GAME_BINARY" \
    -QueryPort="$GAME_PORT" -Port="$GAME_PORT" \
    "${EXTRA_ARGS[@]}" \
    "-ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=${EOS_ID}" \
    "-ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=${EOS_SECRET}"
