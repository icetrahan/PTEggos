#!/bin/bash
# Primal - The Isle: Evrima startup wrapper (LINUX / node 1, standard Wings).
#
# The Linux sibling of egg 40's start-evrima.ps1 (isles/evrima-windows-feathers).
# Each boot: self-update -> update gate -> SteamCMD -> MODDED BINARY from the
# Primal API -> RENDER Game.ini/Engine.ini from egg variables -> pak from R2 ->
# launch. Game.ini is a DERIVED artifact regenerated every boot; the customer
# edits egg VARIABLES, never the file (#356 T1(a)).
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
# Settings are layered, later overrides earlier:
#   1. DEFAULTS (below)              baseline (byte-matched to egg 40's)
#   2. EGG VARIABLES ($ENV)          >> THE SOURCE OF TRUTH for customer settings
#   3. server-config.json overlay    NOT SUPPORTED here - see the render section.

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
# RENDER Game.ini (defaults byte-matched to egg 40's; egg vars override)
# ---------------------------------------------------------------------------
DEFAULT_CLASSES="Dryosaurus,Hypsilophodon,Maiasaura,Pachycephalosaurus,Stegosaurus,Tenontosaurus,Carnotaurus,Ceratosaurus,Deinosuchus,Dilophosaurus,Herrerasaurus,Omniraptor,Pteranodon,Troodon,Beipiaosaurus,Gallimimus,Diabloceratops,Triceratops,Allosaurus,Tyrannosaurus,Kentrosaurus,Austroraptor"

CFG_ServerName=$(env_or "${SERVER_NAME:-}" "Primal Heaven Evrima")
CFG_MaxPlayers=$(env_or "${MAX_PLAYERS:-}" "150")
CFG_ServerPassword="${SERVER_PASSWORD:-}"
CFG_ServerPasswordEnabled=$(to_bool "${SERVER_PASSWORD_ENABLED:-}" "False")
CFG_RconEnabled=$(to_bool "${RCON_ENABLED:-}" "False")
CFG_RconPassword=$(env_or "${RCON_PASSWORD:-}" "CHANGEME")
CFG_Discord=$(env_or "${DISCORD_URL:-}" "https://discord.gg/primalheaven")
CFG_CorpseDecay=$(env_or "${CORPSE_DECAY:-}" "0.02")
CFG_EnableHumans=$(to_bool "${ENABLE_HUMANS:-}" "True")
CFG_DayLength=$(env_or "${SERVER_DAY_LENGTH:-}" "45")
CFG_NightLength=$(env_or "${SERVER_NIGHT_LENGTH:-}" "20")
CFG_GrowthMultiplier=$(env_or "${GROWTH_MULTIPLIER:-}" "1")
CFG_EnableGlobalChat=$(to_bool "${ENABLE_GLOBAL_CHAT:-}" "True")
CFG_EnableAI=$(to_bool "${ENABLE_AI:-}" "False")
CFG_AIDensity=$(env_or "${AI_DENSITY:-}" "0")
CFG_SpawnFish=$(to_bool "${SPAWN_FISH:-}" "False")
CFG_EnableMutations=$(to_bool "${ENABLE_MUTATIONS:-}" "True")
CFG_EnableDiets=$(to_bool "${ENABLE_DIETS:-}" "True")
CFG_FallDamage=$(to_bool "${FALL_DAMAGE:-}" "True")
CFG_AllowReplay=$(to_bool "${ALLOW_REPLAY:-}" "True")
CFG_DynamicWeather=$(to_bool "${DYNAMIC_WEATHER:-}" "False")
CFG_WhitelistEnabled=$(to_bool "${WHITELIST_ENABLED:-}" "False")
CFG_SpawnPlants=$(to_bool "${SPAWN_PLANTS:-}" "False")
CFG_PlantMultiplier=$(env_or "${PLANT_MULTIPLIER:-}" "0")
CFG_EnableMigration=$(to_bool "${ENABLE_MIGRATION:-}" "False")
CFG_EnableMassMigration=$(to_bool "${ENABLE_MASS_MIGRATION:-}" "False")
CFG_EnablePatrolZones=$(to_bool "${ENABLE_PATROL_ZONES:-}" "False")
CFG_MapName=$(env_or "${MAP_NAME:-}" "Gateway")
CFG_QueueEnabled=$(to_bool "${QUEUE_ENABLED:-}" "True")
CFG_AISpawnInterval="${AI_SPAWN_INTERVAL:-}"

# Ports: game/query = SERVER_PORT (query==game BAKED, no variable). Queue and
# rcon are egg variables because standard Wings injects no extra allocations.
GAME_PORT="${SERVER_PORT:?SERVER_PORT not set}"
CFG_QueuePort=$(env_or "${QUEUE_PORT:-}" "$((GAME_PORT + 1))")
CFG_RconPort=$(env_or "${RCON_PORT:-}" "$((GAME_PORT + 2))")

# The server-config.json OVERLAY IS NOT SUPPORTED ON THIS EGG.
# Egg variables are the single source of truth (#356 T1(a), FIELD_SPEC.md:49-51)
# and nothing on the platform writes the overlay. This image carries no JSON
# parser, and a homegrown half-parser that could misread a field silently is
# worse than an honest refusal (rule 13): if the file exists, say so LOUDLY and
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
GSB_A=$(render_id_lines "AdminsSteamIDs" "${ADMIN_STEAM_IDS:-}" "0")
GSB_V=$(render_id_lines "VIPs" "${VIP_STEAM_IDS:-}" "0")
CLASSES_RAW=$(env_or "${ALLOWED_CLASSES:-}" "$DEFAULT_CLASSES")
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

PAK_FORCE_DINO=$(echo -n "${PRIMAL_FORCE_DINO:-}" | tr -d '[:space:]')
# Trike corpse cleanup - ON by Ice's call 2026-08-01 (same defaults as egg 40).
# Key names + value forms are the PAK'S: True/False (not 1/0), csv (not array).
declare -A PAK_EXTRA=()
PAK_EXTRA_ORDER=("BodySweepOn" "BodySweepList" "BodyHoldSec")
PAK_EXTRA[BodySweepOn]="True"
PAK_EXTRA[BodySweepList]="Triceratops"
PAK_EXTRA[BodyHoldSec]="10.0"
# PRIMAL_MOD_INI="Key=Value;Other=1" overrides/extends with no script edit.
if [ -n "${PRIMAL_MOD_INI:-}" ]; then
    while IFS= read -r PAIR; do
        PAIR=$(echo -n "$PAIR" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -z "$PAIR" ] && continue
        case "$PAIR" in
            ?*=*)
                K="${PAIR%%=*}"; V="${PAIR#*=}"
                K=$(echo -n "$K" | sed 's/[[:space:]]*$//')
                V=$(echo -n "$V" | sed 's/^[[:space:]]*//')
                [ -n "${PAK_EXTRA[$K]+x}" ] || PAK_EXTRA_ORDER+=("$K")
                PAK_EXTRA[$K]="$V" ;;
            *) log "WARNING ignoring malformed PRIMAL_MOD_INI entry '$PAIR'" ;;
        esac
    done < <(echo "${PRIMAL_MOD_INI}" | tr ';' '\n')
fi

if [ "${ENABLE_PRIMAL_MOD:-0}" = "1" ] && [ -n "$PHSK" ]; then
    DATA_BASE=$(env_or "${PRIMAL_DATA_BASE:-}" "https://data.primalhosted.com")
    DATA_BASE="${DATA_BASE%/}"
    SESS_BLOCK="[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]"$'\n'
    SESS_BLOCK+="ApiToken=$PHSK"$'\n'
    SESS_BLOCK+="PollURL=$DATA_BASE/v1/commands/text"$'\n'
    [ -n "$PAK_FORCE_DINO" ] && SESS_BLOCK+="ForceDinoList=$PAK_FORCE_DINO"$'\n'
    for K in "${PAK_EXTRA_ORDER[@]}"; do
        SESS_BLOCK+="$K=${PAK_EXTRA[$K]}"$'\n'
    done
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
    log "Engine.ini: pak keys ForceDinoList=$PAK_FORCE_DINO $PAK_KV"
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
