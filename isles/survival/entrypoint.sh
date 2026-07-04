#!/bin/bash
# =============================================================================
# Primal Hosted — The Isle EVRIMA Survival Server
# =============================================================================
# Boot sequence:
#   1. Update gate      — ask the Primal backend if this server may start
#   2. SteamCMD         — update app 412680, branch 'evrima'
#   3. Modded binary    — fetch/verify from the Primal binary-distribution API
#                         (Primal infrastructure ONLY — no third-party sources)
#   4. Game.ini         — regenerated every boot from panel variables
#   5. Engine.ini       — Primal-managed block only; customer lines preserved
#   6. Confirm startup  — report hashes to the backend for monitoring
#   7. Launch
#
# All secrets (API key, EOS credentials) come from egg variables.
# Nothing sensitive is hardcoded in this script.
# =============================================================================

sleep 1
export TZ=${TZ:-UTC}
INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP
cd /home/container || exit 1

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[primal] $*"; }
warn() { echo "[primal] WARN: $*" >&2; }   # stderr: safe inside redirected blocks
die()  { echo "[primal] FATAL: $*" >&2; exit 1; }

# Normalize 0/1/true/false/True/False -> true|false (Evrima ini booleans)
bool() {
    case "$(echo "${1:-$2}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) echo "true" ;;
        *)             echo "false" ;;
    esac
}

get_file_hash() { [ -f "$1" ] && md5sum "$1" | awk '{print $1}' || echo ""; }

# Emit one ini line per Steam64 ID from a comma/space/newline separated list
emit_id_lines() {  # $1 = ini key, $2 = raw list
    local key="$1" raw="$2" id
    for id in $(echo "$raw" | tr ',;\n' '   '); do
        [[ "$id" =~ ^7656[0-9]{13}$ ]] && echo "${key}=${id}" || { [ -n "$id" ] && warn "skipping invalid Steam64 id for ${key}: ${id}"; }
    done
}

emit_value_lines() {  # $1 = ini key, $2 = raw list (non-steamid values, e.g. classes)
    local key="$1" raw="$2" v
    for v in $(echo "$raw" | tr ',;\n' '   '); do
        [ -n "$v" ] && echo "${key}=${v}"
    done
}

# ── Settings & defaults ──────────────────────────────────────────────────────

# Update manager / binary distribution (Primal infrastructure)
API_BASE_URL=${API_BASE_URL:-"https://api.primalheaven.com"}
API_KEY=${API_KEY:-""}
SERVER_ID=${SERVER_ID:-""}
PANEL_NAME=${PANEL_NAME:-"primal"}
UPDATE_GATE=${UPDATE_GATE:-"1"}
MODDED_BINARY=${MODDED_BINARY:-"1"}
MOD_REQUIRED=${MOD_REQUIRED:-"1"}
MANAGE_GAME_INI=${MANAGE_GAME_INI:-"1"}

# Ports (SERVER_PORT is allocated by Pterodactyl)
QUERY_PORT=${QUERY_PORT:-$SERVER_PORT}
QUEUE_PORT=${QUEUE_PORT:-$((SERVER_PORT + 1))}
RCON_PORT=${RCON_PORT:-$((SERVER_PORT + 2))}

GAME_BINARY="/home/container/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
CONFIG_DIR="/home/container/TheIsle/Saved/Config/LinuxServer"
GAME_INI="${CONFIG_DIR}/Game.ini"
ENGINE_INI="${CONFIG_DIR}/Engine.ini"

# ── Step 1: Update gate (may this server start?) ─────────────────────────────
# The backend blocks startup while a vanilla update is out but the mod hasn't
# caught up yet. Fail-open on network problems: the binary check below is the
# real enforcement (the backend's patch-signature verifier is authoritative).

EXPECTED_MODDED_HASH=""
if [ "$UPDATE_GATE" == "1" ] && [ -n "$SERVER_ID" ]; then
    log "Checking update status with backend..."
    for ATTEMPT in 1 2 3; do
        RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 30 \
            -H "X-API-Key: ${API_KEY}" \
            "${API_BASE_URL}/api/updates/server-status/${SERVER_ID}" 2>/dev/null)
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | sed '$d')

        if [ "$HTTP_CODE" == "200" ]; then
            BLOCKED=$(echo "$BODY" | grep -o '"blocked":[^,}]*' | cut -d':' -f2 | tr -d ' ')
            if [ "$BLOCKED" == "true" ]; then
                MOD_PENDING=$(echo "$BODY" | grep -o '"mod_pending":[^,}]*' | cut -d':' -f2 | tr -d ' ')
                REASON=$(echo "$BODY" | grep -o '"block_reason":"[^"]*"' | cut -d'"' -f4)
                [ "$MOD_PENDING" == "true" ] && REASON="vanilla updated, waiting for mod"
                log "Server is BLOCKED by update manager (${REASON:-no reason given})."
                log "Exiting; the panel will restart this server when it is cleared."
                exit 0
            fi
            EXPECTED_MODDED_HASH=$(echo "$BODY" | grep -o '"expected_modded_hash":"[^"]*"' | cut -d'"' -f4)
            log "Update gate: clear to start."
            break
        elif [ "$HTTP_CODE" == "404" ]; then
            warn "update-manager endpoint not available on backend (404) — continuing."
            break
        else
            warn "update gate check failed (HTTP ${HTTP_CODE:-none}), attempt ${ATTEMPT}/3"
            sleep 5
        fi
    done
else
    log "Update gate disabled or SERVER_ID unset — skipping."
fi

# ── Step 2: SteamCMD update ──────────────────────────────────────────────────

STEAM_USER=${STEAM_USER:-anonymous}
[ "$STEAM_USER" == "anonymous" ] && { STEAM_PASS=""; STEAM_AUTH=""; }
SRCDS_APPID=${SRCDS_APPID:-412680}
STEAM_BRANCH=${STEAM_BRANCH:-evrima}

if [ -z "$AUTO_UPDATE" ] || [ "$AUTO_UPDATE" == "1" ]; then
    log "Running SteamCMD update (app ${SRCDS_APPID}, branch ${STEAM_BRANCH})..."
    ./steamcmd/steamcmd.sh +force_install_dir /home/container \
        +login "${STEAM_USER}" ${STEAM_PASS} ${STEAM_AUTH} \
        +app_update "${SRCDS_APPID}" -beta "${STEAM_BRANCH}" validate +quit
else
    log "AUTO_UPDATE=0 — skipping SteamCMD."
fi

[ -f "$GAME_BINARY" ] || die "game binary not found after install: ${GAME_BINARY}"
VANILLA_HASH=$(get_file_hash "$GAME_BINARY")
log "Binary hash after SteamCMD: ${VANILLA_HASH:0:16}..."

# ── Step 3: Modded binary from Primal binary distribution ───────────────────
# POST /commands/binary/check  -> up_to_date | update_available | no_mod_available
# Downloads are served by the same API. There is NO third-party fallback.

if [ "$MODDED_BINARY" == "1" ]; then
    log "Checking Primal binary distribution for modded binary..."
    MOD_READY=false

    for ATTEMPT in 1 2 3 4 5; do
        CURRENT_HASH=$(get_file_hash "$GAME_BINARY")
        CHECK=$(curl -s -w "\n%{http_code}" --max-time 60 -X POST \
            -H "Content-Type: application/json" \
            -H "X-API-Key: ${API_KEY}" \
            -d "{\"platform\":\"linux\",\"vanilla_hash\":\"${VANILLA_HASH}\",\"current_modded_hash\":\"${CURRENT_HASH}\"}" \
            "${API_BASE_URL}/commands/binary/check" 2>/dev/null)
        HTTP_CODE=$(echo "$CHECK" | tail -n1)
        BODY=$(echo "$CHECK" | sed '$d')

        if [ "$HTTP_CODE" != "200" ]; then
            warn "binary check failed (HTTP ${HTTP_CODE:-none}), attempt ${ATTEMPT}/5"
            sleep 10
            continue
        fi

        STATUS=$(echo "$BODY" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        DOWNLOAD_URL=$(echo "$BODY" | grep -o '"download_url":"[^"]*"' | cut -d'"' -f4)
        EXPECTED_MODDED_HASH=$(echo "$BODY" | grep -o '"expected_modded_hash":"[^"]*"' | cut -d'"' -f4)
        log "Binary distribution status: ${STATUS}"

        case "$STATUS" in
            up_to_date)
                MOD_READY=true
                break
                ;;
            update_available)
                log "Downloading modded binary..."
                TMP_BIN="/home/container/.primal_mod_download"
                DL_CODE=$(curl -s -w "%{http_code}" --max-time 900 -o "$TMP_BIN" \
                    -H "X-API-Key: ${API_KEY}" \
                    "${API_BASE_URL}${DOWNLOAD_URL}" 2>/dev/null)
                DL_SIZE=$(stat -c%s "$TMP_BIN" 2>/dev/null || echo 0)
                DL_HASH=$(get_file_hash "$TMP_BIN")

                if [ "$DL_CODE" == "200" ] && [ "$DL_SIZE" -gt 157286400 ] && \
                   { [ -z "$EXPECTED_MODDED_HASH" ] || [ "$DL_HASH" == "$EXPECTED_MODDED_HASH" ]; }; then
                    mv "$TMP_BIN" "$GAME_BINARY"
                    chmod +x "$GAME_BINARY"
                    log "Modded binary installed (${DL_SIZE} bytes, hash ${DL_HASH:0:16}...)."
                    MOD_READY=true
                    break
                fi
                warn "download invalid (HTTP ${DL_CODE}, size ${DL_SIZE}, hash ${DL_HASH:0:16}) — retrying"
                rm -f "$TMP_BIN"
                sleep 10
                ;;
            no_mod_available)
                warn "backend has no mod for this vanilla version yet."
                break
                ;;
            *)
                warn "unexpected status '${STATUS}' — retrying"
                sleep 10
                ;;
        esac
    done

    if [ "$MOD_READY" != "true" ]; then
        if [ "$MOD_REQUIRED" == "1" ]; then
            log "Mod is required but not available. Exiting; the panel will retry."
            exit 0
        fi
        warn "continuing WITHOUT verified modded binary (MOD_REQUIRED=0)."
    fi
else
    log "Modded binary disabled (MODDED_BINARY=0) — running vanilla."
fi

MODDED_HASH=$(get_file_hash "$GAME_BINARY")

# ── Step 4: Generate Game.ini from panel variables ──────────────────────────
# The whole file is owned by the panel: it is regenerated on every boot, so a
# game update can never wipe customer settings — they live in egg variables.

mkdir -p "$CONFIG_DIR"

if [ "$MANAGE_GAME_INI" == "1" ]; then
    log "Writing Game.ini from panel variables..."

    HAS_PASSWORD="false"
    [ -n "$SERVER_PASSWORD" ] && HAS_PASSWORD="true"

    RCON_ON=$(bool "$RCON_ENABLED" "false")
    if [ "$RCON_ON" == "true" ] && [ -z "$RCON_PASSWORD" ]; then
        warn "RCON enabled but RCON_PASSWORD is empty — disabling RCON."
        RCON_ON="false"
    fi

    {
        echo "; GENERATED BY PRIMAL HOSTED — do not edit by hand."
        echo "; Change these settings from your panel; they are re-applied on every restart."
        echo "[/Script/TheIsle.TIGameSession]"
        echo "ServerName=${SERVER_NAME:-Primal Hosted Evrima Server}"
        echo "MapName=${MAP_NAME:-Gateway}"
        echo "MaxPlayerCount=${MAX_PLAYER_COUNT:-100}"
        echo "bEnableHumans=$(bool "$ENABLE_HUMANS" "false")"
        echo "bQueueEnabled=$(bool "$QUEUE_ENABLED" "true")"
        echo "QueuePort=${QUEUE_PORT}"
        echo "bServerPassword=${HAS_PASSWORD}"
        echo "ServerPassword=${SERVER_PASSWORD}"
        echo "bRconEnabled=${RCON_ON}"
        echo "RconPort=${RCON_PORT}"
        echo "RconPassword=${RCON_PASSWORD}"
        echo "bServerDynamicWeather=$(bool "$DYNAMIC_WEATHER" "true")"
        echo "ServerDayLengthMinutes=${DAY_LENGTH_MINUTES:-45}"
        echo "ServerNightLengthMinutes=${NIGHT_LENGTH_MINUTES:-25}"
        echo "bServerWhitelist=$(bool "$WHITELIST_ENABLED" "false")"
        echo "bEnableGlobalChat=$(bool "$GLOBAL_CHAT" "true")"
        echo "bSpawnPlants=$(bool "$SPAWN_PLANTS" "true")"
        echo "PlantSpawnMultiplier=${PLANT_SPAWN_MULTIPLIER:-1}"
        echo "bSpawnAI=$(bool "$SPAWN_AI" "true")"
        echo "AISpawnInterval=${AI_SPAWN_INTERVAL:-40}"
        echo "AIDensity=${AI_DENSITY:-1}"
        echo "bEnableMigration=$(bool "$ENABLE_MIGRATION" "true")"
        echo "bEnableMutations=$(bool "$ENABLE_MUTATIONS" "true")"
        echo "GrowthMultiplier=${GROWTH_MULTIPLIER:-1}"
        echo "CorpseDecayMultiplier=${CORPSE_DECAY_MULTIPLIER:-1}"
        echo "bAllowRecordingReplay=$(bool "$ALLOW_REPLAY" "true")"
        [ -n "$DISCORD_URL" ] && echo "Discord=${DISCORD_URL}"
        echo ""
        echo "[/Script/TheIsle.TIGameStateBase]"
        emit_id_lines "AdminsSteamIDs" "$ADMIN_STEAM_IDS"
        emit_id_lines "VIPs" "$VIP_STEAM_IDS"
        emit_id_lines "WhitelistIDs" "$WHITELIST_IDS"
        emit_value_lines "AllowedClasses" "$ALLOWED_CLASSES"
    } > "$GAME_INI"

    log "Game.ini written ($(grep -c '=' "$GAME_INI") settings)."
else
    log "MANAGE_GAME_INI=0 — leaving Game.ini untouched."
fi

# ── Step 5: Engine.ini managed block ─────────────────────────────────────────
# We own ONLY the marked block (mod/stats integration). Anything the customer
# or an operator adds outside the markers is preserved across every boot.

BLOCK_BEGIN="; >>> PRIMAL MANAGED BLOCK - DO NOT EDIT (regenerated at boot) >>>"
BLOCK_END="; <<< PRIMAL MANAGED BLOCK END <<<"

touch "$ENGINE_INI"
# Strip any previous managed block (exact-line match, everything else preserved)
awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' \
    "$ENGINE_INI" > "${ENGINE_INI}.tmp" && mv "${ENGINE_INI}.tmp" "$ENGINE_INI"

if [ -n "$STATS_API_BASE" ]; then
    log "Writing Primal managed block to Engine.ini (stats integration)..."
    {
        echo "$BLOCK_BEGIN"
        echo "[/Game/Mods/GSVQueue/BP_QueueWorker.BP_QueueWorker_C]"
        echo "PayloadRateSeconds=0.05"
        echo "TickRateSeconds=0.05"
        echo "UseEvents=True"
        echo "UseJoinEvents=True"
        echo "PrintJoinEvents=True"
        echo ""
        echo "[/Game/Mods/GSVQueue/Workset/Modules/AC_StatsDumper.AC_StatsDumper_C]"
        echo "APIPlayers=\"${STATS_API_BASE}/pstats\""
        echo "APIAI=\"${STATS_API_BASE}/astats\""
        echo "APINests=\"${STATS_API_BASE}/nstats\""
        echo "APIGroups=\"${STATS_API_BASE}/gstats\""
        echo "PlayersRate=3"
        echo "AIRate=30"
        echo "NestRate=30.0"
        echo "GroupsRate=60.0"
        echo "$BLOCK_END"
    } >> "$ENGINE_INI"
fi

# ── Step 6: Confirm startup with backend (best-effort) ───────────────────────

if [ -n "$SERVER_ID" ]; then
    CONFIRM_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X POST \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${API_KEY}" \
        -d "{
            \"server_id\": \"${SERVER_ID}\",
            \"server_name\": \"${SERVER_NAME:-$SERVER_ID}\",
            \"server_type\": \"survival\",
            \"platform\": \"pterodactyl\",
            \"panel_name\": \"${PANEL_NAME}\",
            \"vanilla_hash\": \"${VANILLA_HASH}\",
            \"modded_hash\": \"${MODDED_HASH}\",
            \"pterodactyl_uuid\": \"${P_SERVER_UUID}\"
        }" \
        "${API_BASE_URL}/api/updates/confirm-startup" 2>/dev/null)
    [ "$CONFIRM_CODE" == "200" ] && log "Startup confirmed with backend." \
                                 || warn "startup confirmation failed (HTTP ${CONFIRM_CODE}) — continuing."
fi

# ── Step 7: Launch ───────────────────────────────────────────────────────────
# EOS credentials are passed as command-line ini overrides (never written to
# disk). They come from egg variables — required for the server to register.

[ -n "$EOS_CLIENT_ID" ] && [ -n "$EOS_CLIENT_SECRET" ] || die "EOS_CLIENT_ID / EOS_CLIENT_SECRET are not set (egg variables)."

log "Launching The Isle Evrima (port ${SERVER_PORT}, query ${QUERY_PORT}, queue ${QUEUE_PORT})..."
exec "$GAME_BINARY" \
    -Port="${SERVER_PORT}" \
    -QueryPort="${QUERY_PORT}" \
    "-ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=${EOS_CLIENT_ID}" \
    "-ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=${EOS_CLIENT_SECRET}" \
    -Log
