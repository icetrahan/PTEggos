#!/bin/bash

#
# Copyright (c) 2021 Matthew Penner
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

# Wait for the container to fully initialize
sleep 1

# Default the TZ environment variable to UTC.
TZ=${TZ:-UTC}
export TZ

# Set environment variable that holds the Internal Docker IP
INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

# #2039: Wings hands the panel's "Startup Command" to this container as $STARTUP.
# Until 2026-09-06 this script overwrote it with its own hard-coded launch line
# (below) and said nothing, so anything typed into that field was dropped in
# silence (hard rule 13). Capture it HERE, before anything else can touch it.
PANEL_STARTUP_CMD="${STARTUP:-}"

# =============================================================================
# Update Manager Configuration
# =============================================================================
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
# No default: this is a PUBLIC repo (#1064) - the key comes from the egg env or
# not at all. The block below that needs it is guarded by SERVER_ID and says so.
API_KEY=${API_KEY:-""}
SERVER_ID=${SERVER_ID:-""}  # Set this in Pterodactyl egg variables
SERVER_NAME=${SERVER_NAME:-""}  # Human-readable name
PANEL_NAME=${PANEL_NAME:-""}  # Which panel: "gsh" or "primal"

# Function to compute MD5 hash of a file
get_file_hash() {
    if [ -f "$1" ]; then
        md5sum "$1" | awk '{ print $1 }'
    else
        echo ""
    fi
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

# =============================================================================
# Step 0: Check if server can start (read-only check, no writes)
# =============================================================================
# The modChecker is the ONLY service that writes update hashes.
# This script only READS the status and confirms its own startup for monitoring.
# =============================================================================
if [ ! -z "$SERVER_ID" ] && [ ! -z "$API_BASE_URL" ]; then
    echo "=========================================="
    echo "Checking update status with backend..."
    echo "=========================================="
    if [ -z "$API_KEY" ]; then
        echo "⚠️ API_KEY is EMPTY - the backend will answer 401 and this check will fail closed (exit 1) after $MAX_RETRIES tries. Set API_KEY in the egg/server env."
    fi
    
    RETRY_COUNT=0
    MAX_RETRIES=3
    BLOCKED=false
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        # Use the can-start endpoint for a simple check, or server-status for detailed info
        STATUS_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "${API_BASE_URL}/api/updates/server-status/${SERVER_ID}" \
            -H "X-API-Key: ${API_KEY}" 2>/dev/null)
        
        HTTP_CODE=$(echo "$STATUS_RESPONSE" | tail -n1)
        BODY=$(echo "$STATUS_RESPONSE" | sed '$d')
        
        if [ "$HTTP_CODE" == "200" ]; then
            # Parse blocked status and mod_pending from JSON
            BLOCKED=$(echo "$BODY" | grep -o '"blocked":[^,}]*' | cut -d':' -f2 | tr -d ' ')
            MOD_PENDING=$(echo "$BODY" | grep -o '"mod_pending":[^,}]*' | cut -d':' -f2 | tr -d ' ')
            BLOCK_REASON=$(echo "$BODY" | grep -o '"block_reason":"[^"]*"' | cut -d'"' -f4)
            
            if [ "$BLOCKED" == "true" ]; then
                echo "🚫 Server is BLOCKED"
                if [ "$MOD_PENDING" == "true" ]; then
                    echo "   Reason: Vanilla updated, waiting for mod to catch up"
                elif [ ! -z "$BLOCK_REASON" ]; then
                    echo "   Reason: $BLOCK_REASON"
                fi
                echo ""
                echo "Server will not start until mod is available."
                echo "Exiting... Pterodactyl will restart us when ready."
                exit 0
            else
                echo "✅ Server can start (mod_pending=false)"
                
                # Extract expected hashes for later verification
                EXPECTED_MODDED_HASH=$(echo "$BODY" | grep -o '"expected_modded_hash":"[^"]*"' | cut -d'"' -f4)
                echo "Expected modded hash: ${EXPECTED_MODDED_HASH:0:16}..."
            fi
            break
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            echo "⚠️ Backend check failed (HTTP $HTTP_CODE), retry $RETRY_COUNT/$MAX_RETRIES..."
            sleep 10
        fi
    done
    
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "❌ Could not reach backend after $MAX_RETRIES attempts"
        echo "🚫 Blocking startup for safety - Linux servers require mod"
        exit 1
    fi
else
    echo "⚠️ SERVER_ID not set - skipping update manager check"
fi

# Set environment for Steam Proton
if [ -f "/usr/local/bin/proton" ]; then
    if [ ! -z ${SRCDS_APPID} ]; then
	    mkdir -p /home/container/.steam/steam/steamapps/compatdata/${SRCDS_APPID}
        export STEAM_COMPAT_CLIENT_INSTALL_PATH="/home/container/.steam/steam"
        export STEAM_COMPAT_DATA_PATH="/home/container/.steam/steam/steamapps/compatdata/${SRCDS_APPID}"
        # Fix for pipx with protontricks
        export PATH=$PATH:/root/.local/bin
    else
        echo -e "----------------------------------------------------------------------------------"
        echo -e "WARNING!!! Proton needs variable SRCDS_APPID, else it will not work. Please add it"
        echo -e "Server stops now"
        echo -e "----------------------------------------------------------------------------------"
        exit 0
        fi
fi

# Switch to the container's working directory
cd /home/container || exit 1

## just in case someone removed the defaults.
if [ "${STEAM_USER}" == "" ]; then
    echo -e "steam user is not set.\n"
    echo -e "Using anonymous user.\n"
    STEAM_USER=anonymous
    STEAM_PASS=""
    STEAM_AUTH=""
else
    echo -e "user set to ${STEAM_USER}"
fi

## if auto_update is not set or to 1 update
if [ -z ${AUTO_UPDATE} ] || [ "${AUTO_UPDATE}" == "1" ]; then 
    # Update Source Server
    if [ ! -z ${SRCDS_APPID} ]; then
	    if [ "${STEAM_USER}" == "anonymous" ]; then
            ./steamcmd/steamcmd.sh +force_install_dir /home/container +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} +app_update ${SRCDS_APPID} validate +quit
	    else
            ./steamcmd/steamcmd.sh +force_install_dir /home/container +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} +app_update ${SRCDS_APPID} validate +quit
	    fi
    else
        echo -e "No appid set. Starting Server"
    fi

else
    echo -e "Not updating game server as auto update was set to 0. Starting Server"
fi

# Get vanilla hash after SteamCMD update
MOD_FILE_PATH="/home/container/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
VANILLA_HASH=$(get_file_hash "$MOD_FILE_PATH")
echo "Vanilla hash after SteamCMD: ${VANILLA_HASH:0:16}..."

# =============================================================================
# Mod Update Check - the local patch, then the Primal binary lane. No verified binary, no boot:
# the Linux signature bypass is in the patch, so a stock boot tests nothing.
# =============================================================================
echo -e ""
echo -e "=========================================="
echo -e "Checking for mod updates..."
echo -e "=========================================="

# Read current file hash if file exists
if [ -f "$MOD_FILE_PATH" ]; then
    CURRENT_HASH=$(get_file_hash "$MOD_FILE_PATH")
else
    CURRENT_HASH=""
fi

MOD_DOWNLOADED=false
LANE_WHY=""

# -----------------------------------------------------------------------------
# Method 0: patch the stock binary in place (PRIMAL LOCAL PATCH above)
# -----------------------------------------------------------------------------
GAME_BINARY="$MOD_FILE_PATH"
lp_run && MOD_DOWNLOADED=true

# -----------------------------------------------------------------------------
# Method 1: the Primal binary lane, when the local patch did not run
# -----------------------------------------------------------------------------
[ "$MOD_DOWNLOADED" != "true" ] && echo -e "📡 Checking Primal Backend for modded binary..."

BACKEND_RETRY=0
BACKEND_MAX_RETRIES=3

while [ $BACKEND_RETRY -lt $BACKEND_MAX_RETRIES ] && [ "$MOD_DOWNLOADED" != "true" ]; do
    # Check if backend has a mod for our vanilla version
    CHECK_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${PRIMAL_BINARY_BASE}/commands/binary/check" \
        -H "Content-Type: application/json" \
        -d "{\"vanilla_hash\": \"${VANILLA_HASH}\", \"current_modded_hash\": \"${CURRENT_HASH}\"}" 2>/dev/null)

    HTTP_CODE=$(echo "$CHECK_RESPONSE" | tail -n1)
    BODY=$(echo "$CHECK_RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" == "200" ]; then
        # Parse response
        STATUS=$(echo "$BODY" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        DOWNLOAD_URL=$(echo "$BODY" | grep -o '"download_url":"[^"]*"' | cut -d'"' -f4)
        LANE_EXPECTED=$(echo "$BODY" | grep -o '"expected_modded_hash":"[^"]*"' | cut -d'"' -f4)

        echo "   Backend status: $STATUS"

        if [ "$STATUS" == "up_to_date" ]; then
            echo -e "✅ Mod binary is already up to date (verified by backend)"
            MOD_DOWNLOADED=true

        elif [ "$STATUS" == "update_available" ] && [ ! -z "$DOWNLOAD_URL" ]; then
            echo -e "⬇️  Downloading modded binary from backend..."

            # Download from backend
            DOWNLOAD_CODE=$(curl -s -w "%{http_code}" -o /home/container/mod_download.bin \
                "${PRIMAL_BINARY_BASE}${DOWNLOAD_URL}" 2>/dev/null)

            if [ "$DOWNLOAD_CODE" == "200" ]; then
                DOWNLOAD_SIZE=$(stat -c%s "/home/container/mod_download.bin" 2>/dev/null || echo 0)
                DOWNLOAD_HASH=$(get_file_hash /home/container/mod_download.bin)

                if [ "$DOWNLOAD_SIZE" -gt 157286400 ] && { [ -z "$LANE_EXPECTED" ] || [ "$DOWNLOAD_HASH" == "$LANE_EXPECTED" ]; }; then
                    mkdir -p "$(dirname "$MOD_FILE_PATH")"
                    if lp_install /home/container/mod_download.bin "$DOWNLOAD_HASH"; then
                        echo -e "✅ Mod binary downloaded from backend (${DOWNLOAD_SIZE} bytes, hash ${DOWNLOAD_HASH:0:16}..., read back from the binary's path)"
                        MOD_DOWNLOADED=true
                    else
                        LANE_WHY=$LP_INSTALL_WHY
                        echo -e "⚠️  Backend binary not installed: ${LANE_WHY}"
                    fi
                else
                    LANE_WHY="the download is not the lane's build (${DOWNLOAD_SIZE} bytes, hash ${DOWNLOAD_HASH:0:16})"
                    echo -e "⚠️  ${LANE_WHY}, not installed"
                    rm -f /home/container/mod_download.bin
                fi
            else
                LANE_WHY="the download failed (HTTP $DOWNLOAD_CODE)"
                echo -e "⚠️  Backend download failed (HTTP $DOWNLOAD_CODE)"
            fi

        else
            LANE_WHY="the lane has no modded binary for vanilla ${VANILLA_HASH:0:16} (${STATUS:-no status})"
            echo -e "⚠️  ${LANE_WHY}"
        fi

        break  # the lane answered: obey it, never retry an answer
    else
        BACKEND_RETRY=$((BACKEND_RETRY + 1))
        LANE_WHY="${PRIMAL_BINARY_BASE} did not answer (HTTP $HTTP_CODE, $BACKEND_RETRY/$BACKEND_MAX_RETRIES attempts)"
        echo -e "⚠️  Backend check failed (HTTP $HTTP_CODE), retry $BACKEND_RETRY/$BACKEND_MAX_RETRIES..."
        sleep 5
    fi
done

# Cleanup
rm -f /home/container/mod_download.bin

# -----------------------------------------------------------------------------
# Final check - do we have a valid mod?
# -----------------------------------------------------------------------------
if [ "$MOD_DOWNLOADED" != "true" ]; then
    echo "[primal] FATAL: MOD-BINARY-UNAVAILABLE: the local patch did not run (${LP_WHY:-no reason given}) and the binary lane supplied no verified build (${LANE_WHY:-no reason given}). This image does not boot the stock binary. The panel will retry." >&2
    exit 1
fi

# Get final modded hash
MODDED_HASH=$(get_file_hash "$MOD_FILE_PATH")
echo "Final modded hash: ${MODDED_HASH:0:16}..."

# Verify mod hash matches expected (if we got it from backend)
if [ ! -z "$EXPECTED_MODDED_HASH" ] && [ "$MODDED_HASH" != "$EXPECTED_MODDED_HASH" ]; then
    echo "⚠️ WARNING: Modded hash doesn't match expected!"
    echo "   Expected: ${EXPECTED_MODDED_HASH:0:16}..."
    echo "   Got:      ${MODDED_HASH:0:16}..."
    # Don't block - the mod API is authoritative, our checker might be behind
fi

# =============================================================================
# Report successful startup to backend
# =============================================================================
if [ ! -z "$SERVER_ID" ] && [ ! -z "$API_BASE_URL" ]; then
    echo "Reporting startup to backend..."
    
    # Get server name from environment or use ID
    SERVER_NAME=${SERVER_NAME:-$SERVER_ID}
    
    CONFIRM_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/updates/confirm-startup" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${API_KEY}" \
        -d "{
            \"server_id\": \"${SERVER_ID}\",
            \"server_name\": \"${SERVER_NAME}\",
            \"server_type\": \"deathmatch\",
            \"platform\": \"pterodactyl\",
            \"panel_name\": \"${PANEL_NAME}\",
            \"vanilla_hash\": \"${VANILLA_HASH}\",
            \"modded_hash\": \"${MODDED_HASH}\",
            \"pterodactyl_uuid\": \"${P_SERVER_UUID}\"
        }")
    
    HTTP_CODE=$(echo "$CONFIRM_RESPONSE" | tail -n1)
    
    if [ "$HTTP_CODE" == "200" ]; then
        echo "✅ Startup confirmed with backend"
    else
        echo "⚠️ Failed to confirm startup (HTTP $HTTP_CODE) - continuing anyway"
    fi
fi

# =============================================================================
# The launch line (#2039)
# =============================================================================
# This image has ALWAYS launched with its own built-in line (QueryPort == Port ==
# SERVER_PORT, the public EOS dedicated-server client id/secret every Isle host
# uses). Servers already on this image (NA2, Skin Creator, Builder) carry panel
# Startup Commands that differ from it - one of them would change ports if the
# field were honoured outright - so the BUILT-IN LINE STAYS THE DEFAULT and the
# panel field is honoured only when a server opts in:
#     env  PANEL_STARTUP=1                       (needs an egg variable), or
#     file /home/container/.panel-startup        (creatable from the panel's File
#                                                 Manager on any server today)
# Either way the log below says which line ran and, when the panel field is
# ignored, prints it so nobody spends a boot cycle on a field that does nothing.
# For an Engine.ini key on this egg the read path is the volume file
# /home/container/TheIsle/Saved/Config/LinuxServer/Engine.ini (nothing rewrites it).
BUILTIN_STARTUP="/home/container/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping -QueryPort=$SERVER_PORT -Port=$SERVER_PORT  -ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=xyza7891gk5PRo3J7G9puCJGFJjmEguW -ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=pKWl6t5i9NJK8gTpVlAxzENZ65P8hYzodV8Dqe5Rlc8"
HONOUR_PANEL=false
[ "${PANEL_STARTUP:-0}" = "1" ] && HONOUR_PANEL=true
[ -f /home/container/.panel-startup ] && HONOUR_PANEL=true
if [ "$HONOUR_PANEL" = "true" ] && [ -n "$PANEL_STARTUP_CMD" ]; then
    echo "(launch) #2039: using the PANEL Startup Command (opt-in via PANEL_STARTUP=1 / .panel-startup)"
    export STARTUP="$PANEL_STARTUP_CMD"
else
    if [ "$HONOUR_PANEL" = "true" ]; then
        echo "(launch) #2039: panel opt-in set but the panel Startup Command is EMPTY - using the image's built-in launch line"
    else
        echo "(launch) #2039: the panel Startup Command is IGNORED by this image - using the built-in launch line."
        echo "(launch)        panel field was: ${PANEL_STARTUP_CMD:-<empty>}"
        echo "(launch)        to honour it on this server: create /home/container/.panel-startup (or set PANEL_STARTUP=1) and restart"
    fi
    export STARTUP="$BUILTIN_STARTUP"
fi

# Replace Startup Variables
MODIFIED_STARTUP=$(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo -e ":/home/container$ ${MODIFIED_STARTUP}"

# Run the Server
eval ${MODIFIED_STARTUP}