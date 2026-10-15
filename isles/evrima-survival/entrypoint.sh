#!/bin/bash
# =============================================================================
# Primal Hosted — The Isle EVRIMA Survival Server
# =============================================================================
# Boot sequence:
#   1. Update gate      — ask the Primal backend if this server may start
#   2. SteamCMD         — update app 412680, branch 'evrima'
#   3. Modded binary    — the stock binary patched in place (PRIMAL LOCAL PATCH);
#                         the Primal binary lane as the fallback
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

# >>> PRIMAL LOCAL PATCH >>>
# The same bytes in isles/evrima-survival/entrypoint.sh and
# testing/deathmatch/entrypoint.sh; .github/scripts/test_image_localpatch.sh
# fails when they differ. Egg 42's start-evrima.sh runs the same rung.
#
# The stock binary SteamCMD installs is patched in place by our pattern patcher
# (patch_worker.py + patches_linux.json, the Linux voice tool on R2). The
# patterns find the two signature-gate sites in any game build, so a game
# update needs nothing new from us. Each file is sha256-checked against the
# tool's manifest and kept in _primal/patcher/ with it, so a boot without R2
# still patches. When lp_run returns 1, LP_WHY says why and the caller falls
# back to the binary lane, which has the same bytes for the builds it holds.
# Set GAME_BINARY and PRIMAL_BINARY_BASE before calling lp_run / lp_install.
LP_DIR=/home/container/_primal/patcher
LP_MANIFEST_URL="${PRIMAL_PATCHER_MANIFEST:-https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev/primal-voice-linux-tool/latest.json}"
LP_VER=""; LP_WHY=""; LP_DONE=""; LP_MODDED=""; LP_INSTALL_WHY=""

lp_log()  { echo "[primal] $*"; }
lp_warn() { echo "[primal] WARN: $*" >&2; }
lp_md5()  { [ -f "$1" ] && md5sum "$1" | awk '{print $1}' || echo ""; }
lp_sha256() { [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo ""; }
lp_field()  { grep -o "\"$2\" *: *\"[^\"]*\"" <<<"$1" | head -1 | sed 's/.*: *"//; s/"$//'; }
lp_fields() { grep -o "\"$2\" *: *\"[^\"]*\"" <<<"$1" | sed 's/.*: *"//; s/"$//'; }

lp_entry() { # $1 = manifest, $2 = file name -> "<sha256> <url>"; 1 when absent, malformed, or the arrays do not line up
    local -a n u s; local i sha
    mapfile -t n < <(lp_fields "$1" name)
    mapfile -t u < <(lp_fields "$1" url)
    mapfile -t s < <(lp_fields "$1" sha256)
    [ "${#n[@]}" -gt 0 ] && [ "${#n[@]}" = "${#u[@]}" ] && [ "${#n[@]}" = "${#s[@]}" ] || return 1
    for i in "${!n[@]}"; do
        [ "${n[$i]}" = "$2" ] || continue
        # An empty sha would equal the sha of a missing file.
        sha=$(echo "${s[$i]}" | tr 'A-F' 'a-f')
        [[ "$sha" =~ ^[0-9a-f]{64}$ ]] && [ -n "${u[$i]}" ] || return 1
        printf '%s %s\n' "$sha" "${u[$i]}"; return 0
    done
    return 1
}

# The kept copy stands in only when R2 cannot be read, and only while it still
# matches the manifest it came with.
lp_get() {
    local tm src=r2 f ent stage="$LP_DIR/stage"
    mkdir -p "$LP_DIR" || { LP_WHY="cannot create $LP_DIR"; return 1; }
    tm=$(curl -fsS --max-time 20 "$LP_MANIFEST_URL" 2>/dev/null)
    if [ -z "$tm" ]; then
        tm=$(cat "$LP_DIR/manifest.json" 2>/dev/null)
        [ -n "$tm" ] || { LP_WHY="the tool manifest is unreachable and no copy is kept ($LP_MANIFEST_URL)"; return 1; }
        src=kept
    fi
    LP_VER=$(lp_field "$tm" version)
    for f in patch_worker.py patches_linux.json; do
        lp_entry "$tm" "$f" >/dev/null || { LP_WHY="the tool manifest has no valid entry for $f"; return 1; }
    done
    rm -rf "$stage"; mkdir -p "$stage"
    for f in patch_worker.py patches_linux.json; do
        ent=$(lp_entry "$tm" "$f")
        [ "$(lp_sha256 "$LP_DIR/$f")" = "${ent%% *}" ] && continue
        [ "$src" = kept ] && { LP_WHY="the kept $f does not match its manifest"; rm -rf "$stage"; return 1; }
        curl -fsS --max-time 60 -o "$stage/$f" "${ent#* }" 2>/dev/null
        [ "$(lp_sha256 "$stage/$f")" = "${ent%% *}" ] || { LP_WHY="$f failed its sha256 check"; rm -rf "$stage"; return 1; }
    done
    for f in "$stage"/*; do [ -f "$f" ] && mv -f "$f" "$LP_DIR/"; done
    rm -rf "$stage"
    for f in patch_worker.py patches_linux.json; do
        ent=$(lp_entry "$tm" "$f")
        [ "$(lp_sha256 "$LP_DIR/$f")" = "${ent%% *}" ] || { LP_WHY="$f could not be placed"; return 1; }
    done
    if [ "$src" = r2 ]; then
        printf '%s\n' "$tm" > "$LP_DIR/manifest.json"
    else
        lp_log "binary: tool manifest unreachable - patching with the copy kept from an earlier boot (tool v${LP_VER:-?})"
    fi
    return 0
}

lp_summary() { # one line naming each rule's outcome
    if [ ! -s "$LP_DIR/last-report.json" ]; then
        printf 'no report: %s' "$(tail -n1 "$LP_DIR/last-stderr.txt" 2>/dev/null | cut -c1-120)"
        return
    fi
    python3 - "$LP_DIR/last-report.json" 2>/dev/null <<'PY' || printf 'see %s' "$LP_DIR/last-report.json"
import json, sys
r = json.load(open(sys.argv[1]))
print(" ".join("%s=%s%s" % (p.get("name"), p.get("status"), "@%s" % p["patch_offset"] if p.get("patch_offset") else "")
               for p in r.get("patches") or []), end="")
PY
}

lp_patch() { # 0 with LP_DONE=patched|already and LP_MODDED; 1 with LP_WHY
    command -v python3 >/dev/null 2>&1 || { LP_WHY="python3 is not in this server's image"; return 1; }
    lp_get || return 1
    local out="$LP_DIR/patched.bin" rep="$LP_DIR/last-report.json" rc cur size omd5
    cur=$(lp_md5 "$GAME_BINARY"); size=$(stat -c%s "$GAME_BINARY" 2>/dev/null)
    [ -n "$cur" ] || { LP_WHY="there is no binary at $GAME_BINARY"; return 1; }
    rm -f "$out" "$rep"
    python3 "$LP_DIR/patch_worker.py" "$GAME_BINARY" "$out" \
        --spec "$LP_DIR/patches_linux.json" --report "$rep" >/dev/null 2>"$LP_DIR/last-stderr.txt"
    rc=$?
    # Exit 0 is not the verdict: the report must say success and the output must exist (rule 13).
    if [ "$rc" != 0 ] || [ ! -f "$out" ] || ! grep -Eq '"success"[[:space:]]*:[[:space:]]*true' "$rep" 2>/dev/null; then
        LP_WHY="the patcher (tool v${LP_VER:-?}) did not patch this build: exit $rc, $(lp_summary)"
        rm -f "$out"; return 1
    fi
    [ "$(stat -c%s "$out" 2>/dev/null)" = "$size" ] || { LP_WHY="the patcher's output is not the binary's size"; rm -f "$out"; return 1; }
    omd5=$(lp_md5 "$out")
    if [ "$omd5" = "$cur" ]; then
        rm -f "$out"; LP_MODDED=$omd5; LP_DONE=already; return 0
    fi
    chmod --reference="$GAME_BINARY" "$out" 2>/dev/null || chmod +x "$out"
    mv -f "$out" "$GAME_BINARY" || { LP_WHY="the patched binary could not be moved into place"; rm -f "$out"; return 1; }
    [ "$(lp_md5 "$GAME_BINARY")" = "$omd5" ] || { LP_WHY="the installed binary does not read back as the patcher's output"; rm -f "$out"; return 1; }
    LP_MODDED=$omd5; LP_DONE=patched; return 0
}

lp_run() { # 0 = the binary on disk is patched; 1 = it is not, LP_WHY says why
    LP_WHY=""; LP_DONE=""; LP_MODDED=""
    local stock xc xs
    stock=$(lp_md5 "$GAME_BINARY")
    if ! lp_patch; then
        lp_warn "=============================================================="
        lp_warn "binary: LOCAL PATCH NOT APPLIED - $LP_WHY"
        lp_warn "  Falling back to the binary lane (${PRIMAL_BINARY_BASE}): the same"
        lp_warn "  bytes, but only for game builds the lane already holds."
        lp_warn "=============================================================="
        return 1
    fi
    if [ "$LP_DONE" = already ]; then
        lp_log "binary: already patched (${LP_MODDED:0:16}): every site is in its patched form, nothing written ($(lp_summary))"
        return 0
    fi
    lp_log "binary: PATCHED LOCALLY (tool v${LP_VER:-?}): ${stock:0:16} -> ${LP_MODDED:0:16} ($(lp_summary))"
    # Log-only: the lane's own build for this stock binary is the cross-check
    # that the two paths agree. Nothing here can stop the boot.
    xc=$(curl -fsS --max-time 15 -X POST -H "Content-Type: application/json" \
        -d "{\"platform\":\"linux\",\"vanilla_hash\":\"${stock}\",\"current_modded_hash\":\"${LP_MODDED}\"}" \
        "${PRIMAL_BINARY_BASE}/commands/binary/check" 2>/dev/null)
    xs=$(lp_field "$xc" status)
    case "$xs" in
        up_to_date)       lp_log "binary: the lane's build for this vanilla is the same bytes" ;;
        update_available) lp_warn "binary: the lane's build for this vanilla is $(lp_field "$xc" expected_modded_hash | cut -c1-16), NOT ${LP_MODDED:0:16} - booting the local patch; the two paths disagree" ;;
        "")               lp_log "binary: the lane did not answer the cross-check (not needed to boot)" ;;
        *)                lp_log "binary: the lane holds no build for this vanilla ($xs) - the local patch does not need one" ;;
    esac
    return 0
}

lp_install() { # $1 = a downloaded binary, $2 = its md5. Installed = the binary's own path reads back as it (#3875); the caller removes $1.
    local got
    LP_INSTALL_WHY=""
    if mv -f "$1" "$GAME_BINARY" 2>/dev/null && chmod +x "$GAME_BINARY" 2>/dev/null \
        && [ "$(lp_md5 "$GAME_BINARY")" = "$2" ]; then
        return 0
    fi
    got=$(lp_md5 "$GAME_BINARY"); got=${got:0:16}
    LP_INSTALL_WHY="the download ${2:0:16} did not land: the binary reads back as ${got:-nothing}"
    return 1
}
# <<< PRIMAL LOCAL PATCH <<<

# ── Settings & defaults ──────────────────────────────────────────────────────

# Update manager / binary distribution (Primal infrastructure)
API_BASE_URL=${API_BASE_URL:-"https://api.primalheaven.com"}
# ── THE BINARY LANE IS THE PRODUCT'S, NOT THE GAME COMMUNITY'S (#2337) ───────
# Split from API_BASE_URL on purpose. The modded-binary check/download move to
# Primal Hosted's own lane (repo primal_binaries, R2-backed on the Cloudflare
# edge), which speaks the identical wire shapes. api.primalheaven.com went down
# on 2026-09-14 and boot-looped a paying customer's only server for nine hours;
# no server's boot should depend on that box again.
#
# API_BASE_URL below stays ONLY for Heaven's update-manager calls
# (/api/updates/server-status, /api/updates/confirm-startup). The product lane
# deliberately does NOT serve those - they are Primal HEAVEN fleet management,
# they are guarded by SERVER_ID, and no live server on this image sets it, so
# they never fire. ⛔ Do not "fix" that by setting SERVER_ID: for a server not
# in Heaven's registry the route returns Heaven's own global modPending flag as
# `blocked`, which would hand Heaven a kill switch over this server (#2342).
PRIMAL_BINARY_BASE=${PRIMAL_BINARY_BASE:-"https://binaries.primalhosted.com"}
PRIMAL_BINARY_BASE="${PRIMAL_BINARY_BASE%/}"
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

# ── Step 3: Modded binary: patched locally, the binary lane as the fallback ──
# The lane: POST /commands/binary/check -> up_to_date | update_available |
# no_mod_available | vanilla_unknown; downloads come from the same lane.
# There is NO third-party fallback.

if [ "$MODDED_BINARY" == "1" ]; then
    MOD_READY=false
    LANE_WHY=""
    lp_run && MOD_READY=true

    if [ "$MOD_READY" != "true" ]; then
        log "Checking Primal binary distribution for modded binary..."
        for ATTEMPT in 1 2 3 4 5; do
            CURRENT_HASH=$(get_file_hash "$GAME_BINARY")
            CHECK=$(curl -s -w "\n%{http_code}" --max-time 60 -X POST \
                -H "Content-Type: application/json" \
                -H "X-API-Key: ${API_KEY}" \
                -d "{\"platform\":\"linux\",\"vanilla_hash\":\"${VANILLA_HASH}\",\"current_modded_hash\":\"${CURRENT_HASH}\"}" \
                "${PRIMAL_BINARY_BASE}/commands/binary/check" 2>/dev/null)
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
                        "${PRIMAL_BINARY_BASE}${DOWNLOAD_URL}" 2>/dev/null)
                    DL_SIZE=$(stat -c%s "$TMP_BIN" 2>/dev/null || echo 0)
                    DL_HASH=$(get_file_hash "$TMP_BIN")

                    if [ "$DL_CODE" == "200" ] && [ "$DL_SIZE" -gt 157286400 ] && \
                       { [ -z "$EXPECTED_MODDED_HASH" ] || [ "$DL_HASH" == "$EXPECTED_MODDED_HASH" ]; }; then
                        if lp_install "$TMP_BIN" "$DL_HASH"; then
                            log "Modded binary installed (${DL_SIZE} bytes, hash ${DL_HASH:0:16}..., read back from the binary's path)."
                            MOD_READY=true
                            break
                        fi
                        LANE_WHY=$LP_INSTALL_WHY
                        warn "binary: ${LANE_WHY} — retrying"
                    else
                        LANE_WHY=""
                        warn "download invalid (HTTP ${DL_CODE}, size ${DL_SIZE}, hash ${DL_HASH:0:16}) — retrying"
                    fi
                    rm -f "$TMP_BIN"
                    sleep 10
                    ;;
                no_mod_available|vanilla_unknown)
                    LANE_WHY=""
                    warn "the lane has no modded binary for vanilla ${VANILLA_HASH:0:16} (${STATUS})."
                    break
                    ;;
                *)
                    warn "unexpected status '${STATUS}' — retrying"
                    sleep 10
                    ;;
            esac
        done
    fi

    if [ "$MOD_READY" != "true" ]; then
        if [ "$MOD_REQUIRED" == "1" ]; then
            log "Mod is required but not available (local patch: ${LP_WHY}${LANE_WHY:+; lane: ${LANE_WHY}}). Exiting; the panel will retry."
            exit 0
        fi
        warn "continuing WITHOUT verified modded binary (MOD_REQUIRED=0; local patch: ${LP_WHY})."
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
