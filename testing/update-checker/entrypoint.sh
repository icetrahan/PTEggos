#!/bin/bash

#
# Primal Heaven Update Checker
# =============================
# Self-contained binary update & patching pipeline for Linux + Windows.
# Replaces the old Norden Cloud dependency.
#
# Flow:
#   1. SteamCMD → download Linux vanilla binary
#   2. SteamCMD → download Windows vanilla binary (cross-platform)
#   3. Compare vanilla hashes against last-known to detect updates
#   4. Patch both platforms using patch_worker.py + JSON specs
#   5. Upload patched binaries to backend for distribution
#   6. Report vanilla + modded hashes for both platforms
#   7. Heartbeat
#   8. Sleep until Pterodactyl schedule restarts us
#

echo "=========================================="
echo "Primal Heaven Update Checker"
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

# ─── Configuration ────────────────────────────────────────────────────────────

API_BASE_URL=${API_BASE_URL:-"https://api.primalheaven.com"}
API_DIRECT_URL=${API_DIRECT_URL:-"http://172.93.100.254:25022"}
API_KEY=${API_KEY:-""}
SRCDS_APPID=${SRCDS_APPID:-"1020410"}
STEAM_USER=${STEAM_USER:-"anonymous"}
STEAM_PASS=${STEAM_PASS:-""}
STEAM_BETA=${STEAM_BETA:-"evrima"}

PATCHER_DIR="/home/container/patcher"
LINUX_INSTALL="/home/container/isle_linux"
WINDOWS_INSTALL="/home/container/isle_windows"

LINUX_BINARY_REL="TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
WINDOWS_BINARY_REL="TheIsle/Binaries/Win64/TheIsleServer-Win64-Shipping.exe"

LINUX_BINARY="${LINUX_INSTALL}/${LINUX_BINARY_REL}"
WINDOWS_BINARY="${WINDOWS_INSTALL}/${WINDOWS_BINARY_REL}"

LINUX_PATCHED="/home/container/patched_linux"
WINDOWS_PATCHED="/home/container/patched_windows"

HASH_CACHE="/home/container/.last_vanilla_hashes"

cd /home/container || exit 1

# ─── Helpers ──────────────────────────────────────────────────────────────────

get_file_hash() {
    if [ -f "$1" ]; then
        md5sum "$1" | awk '{ print $1 }'
    else
        echo ""
    fi
}

load_cached_hashes() {
    CACHED_LINUX_HASH=""
    CACHED_WINDOWS_HASH=""
    if [ -f "$HASH_CACHE" ]; then
        CACHED_LINUX_HASH=$(grep '^linux=' "$HASH_CACHE" 2>/dev/null | cut -d= -f2)
        CACHED_WINDOWS_HASH=$(grep '^windows=' "$HASH_CACHE" 2>/dev/null | cut -d= -f2)
    fi
}

save_cached_hashes() {
    echo "linux=${LINUX_VANILLA_HASH}" > "$HASH_CACHE"
    echo "windows=${WINDOWS_VANILLA_HASH}" >> "$HASH_CACHE"
}

report_hash() {
    local endpoint=$1
    local hash=$2
    local platform=$3

    echo "  Reporting ${endpoint} (${platform}): ${hash:0:16}..."

    local json="{\"hash\": \"${hash}\", \"platform\": \"${platform}\"}"

    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${API_BASE_URL}/api/updates/${endpoint}" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${API_KEY}" \
        -d "$json")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" == "200" ]; then
        echo "  ✅ Reported: $body"
        return 0
    else
        echo "  ❌ Failed (HTTP $http_code): $body"
        return 1
    fi
}

upload_binary() {
    local platform=$1
    local vanilla_hash=$2
    local binary_path=$3

    if [ ! -f "$binary_path" ]; then
        echo "  ⚠️ Binary not found: $binary_path"
        return 1
    fi

    local file_size
    file_size=$(stat -c%s "$binary_path" 2>/dev/null || stat -f%z "$binary_path" 2>/dev/null)
    echo "  Uploading ${platform} modded binary ($(( file_size / 1024 / 1024 ))MB)..."

    response=$(curl -s -w "\n%{http_code}" -X PUT \
        "${API_DIRECT_URL}/api/binary/upload/${platform}/${vanilla_hash}" \
        -H "X-API-Key: ${API_KEY}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${binary_path}")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" == "200" ]; then
        echo "  ✅ Upload OK: $body"
        return 0
    else
        echo "  ⚠️ Upload failed (HTTP $http_code): $body"
        return 1
    fi
}

send_heartbeat() {
    echo "Sending heartbeat..."
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${API_BASE_URL}/api/updates/heartbeat" \
        -H "X-API-Key: ${API_KEY}")
    http_code=$(echo "$response" | tail -n1)
    if [ "$http_code" == "200" ]; then
        echo "✅ Heartbeat OK"
    else
        echo "⚠️ Heartbeat failed (HTTP $http_code)"
    fi
}

run_patcher() {
    local input_path=$1
    local output_path=$2
    local report_path=$3

    mkdir -p "$(dirname "$output_path")"
    python3 "${PATCHER_DIR}/patch_worker.py" "$input_path" "$output_path" --report "$report_path"
    return $?
}

# ─── Step 0: Install SteamCMD ────────────────────────────────────────────────

if [ ! -f "./steamcmd/steamcmd.sh" ]; then
    echo ""
    echo "=========================================="
    echo "Installing SteamCMD..."
    echo "=========================================="
    mkdir -p steamcmd
    cd steamcmd
    curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxvf -
    cd /home/container
fi

# Load previously seen vanilla hashes so we can detect changes
load_cached_hashes

# ─── Step 1: Download Linux Vanilla ──────────────────────────────────────────

echo ""
echo "=========================================="
echo "Step 1: Downloading Linux Vanilla Binary"
echo "=========================================="

echo "Running SteamCMD (linux)..."
./steamcmd/steamcmd.sh \
    +force_install_dir "${LINUX_INSTALL}" \
    +login ${STEAM_USER} ${STEAM_PASS} \
    +app_update ${SRCDS_APPID} -beta ${STEAM_BETA} validate \
    +quit

LINUX_VANILLA_HASH=$(get_file_hash "$LINUX_BINARY")

if [ -z "$LINUX_VANILLA_HASH" ]; then
    echo "❌ Linux binary not found after SteamCMD!"
    LINUX_OK=false
else
    echo "Linux vanilla hash: ${LINUX_VANILLA_HASH:0:16}..."
    if [ "$CACHED_LINUX_HASH" != "$LINUX_VANILLA_HASH" ]; then
        echo "📦 Linux vanilla binary changed!"
        LINUX_CHANGED=true
    else
        LINUX_CHANGED=false
    fi
    report_hash "report-vanilla" "$LINUX_VANILLA_HASH" "linux"
    LINUX_OK=true
fi

# ─── Step 2: Download Windows Vanilla ────────────────────────────────────────

echo ""
echo "=========================================="
echo "Step 2: Downloading Windows Vanilla Binary"
echo "=========================================="

echo "Running SteamCMD (windows cross-download)..."
./steamcmd/steamcmd.sh \
    +@sSteamCmdForcePlatformType windows \
    +force_install_dir "${WINDOWS_INSTALL}" \
    +login ${STEAM_USER} ${STEAM_PASS} \
    +app_update ${SRCDS_APPID} -beta ${STEAM_BETA} validate \
    +quit

WINDOWS_VANILLA_HASH=$(get_file_hash "$WINDOWS_BINARY")

if [ -z "$WINDOWS_VANILLA_HASH" ]; then
    echo "❌ Windows binary not found after SteamCMD!"
    WINDOWS_OK=false
else
    echo "Windows vanilla hash: ${WINDOWS_VANILLA_HASH:0:16}..."
    if [ "$CACHED_WINDOWS_HASH" != "$WINDOWS_VANILLA_HASH" ]; then
        echo "📦 Windows vanilla binary changed!"
        WINDOWS_CHANGED=true
    else
        WINDOWS_CHANGED=false
    fi
    WINDOWS_OK=true
fi

# Persist vanilla hashes for next run
save_cached_hashes

# ─── Step 3: Patch Linux Binary ──────────────────────────────────────────────

echo ""
echo "=========================================="
echo "Step 3: Patching Linux Binary"
echo "=========================================="

LINUX_MODDED_HASH=""
if [ "$LINUX_OK" == "true" ]; then
    LINUX_OUTPUT="${LINUX_PATCHED}/TheIsleServer-Linux-Shipping"
    LINUX_REPORT="${LINUX_PATCHED}/patch_report_linux.json"

    run_patcher "$LINUX_BINARY" "$LINUX_OUTPUT" "$LINUX_REPORT"
    PATCH_EXIT=$?

    if [ $PATCH_EXIT -eq 0 ]; then
        chmod +x "$LINUX_OUTPUT"
        LINUX_MODDED_HASH=$(get_file_hash "$LINUX_OUTPUT")
        echo "✅ Linux patch successful. Modded hash: ${LINUX_MODDED_HASH:0:16}..."

        report_hash "report-modded" "$LINUX_MODDED_HASH" "linux"
        upload_binary "linux" "$LINUX_VANILLA_HASH" "$LINUX_OUTPUT"
    else
        echo "❌ Linux patch FAILED (exit $PATCH_EXIT). See report:"
        if [ -f "$LINUX_REPORT" ]; then
            cat "$LINUX_REPORT"
        fi
        echo ""
        echo "⚠️ Signature may have changed. Manual re-discovery needed."
    fi
else
    echo "⏭️ Skipping — Linux vanilla not available"
fi

# ─── Step 4: Patch Windows Binary ────────────────────────────────────────────

echo ""
echo "=========================================="
echo "Step 4: Patching Windows Binary"
echo "=========================================="

WINDOWS_MODDED_HASH=""
if [ "$WINDOWS_OK" == "true" ]; then
    WINDOWS_OUTPUT="${WINDOWS_PATCHED}/TheIsleServer-Win64-Shipping.exe"
    WINDOWS_REPORT="${WINDOWS_PATCHED}/patch_report_windows.json"

    run_patcher "$WINDOWS_BINARY" "$WINDOWS_OUTPUT" "$WINDOWS_REPORT"
    PATCH_EXIT=$?

    if [ $PATCH_EXIT -eq 0 ]; then
        WINDOWS_MODDED_HASH=$(get_file_hash "$WINDOWS_OUTPUT")
        echo "✅ Windows patch successful. Modded hash: ${WINDOWS_MODDED_HASH:0:16}..."

        report_hash "report-modded" "$WINDOWS_MODDED_HASH" "windows"
        upload_binary "windows" "$WINDOWS_VANILLA_HASH" "$WINDOWS_OUTPUT"
    else
        echo "❌ Windows patch FAILED (exit $PATCH_EXIT). See report:"
        if [ -f "$WINDOWS_REPORT" ]; then
            cat "$WINDOWS_REPORT"
        fi
        echo ""
        echo "⚠️ Signature may have changed. Manual re-discovery needed."
    fi
else
    echo "⏭️ Skipping — Windows vanilla not available"
fi

# ─── Step 5: Heartbeat ───────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "Step 5: Heartbeat"
echo "=========================================="

send_heartbeat

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "Update Checker Summary"
echo "=========================================="
echo "Linux  vanilla : ${LINUX_VANILLA_HASH:-(not available)}"
echo "Linux  modded  : ${LINUX_MODDED_HASH:-(not patched)}"
echo "Linux  changed : ${LINUX_CHANGED:-N/A}"
echo "Windows vanilla: ${WINDOWS_VANILLA_HASH:-(not available)}"
echo "Windows modded : ${WINDOWS_MODDED_HASH:-(not patched)}"
echo "Windows changed: ${WINDOWS_CHANGED:-N/A}"
echo ""
echo "$(date '+%Y-%m-%d %H:%M:%S') — Done."
echo "=========================================="
echo "Sleeping until next scheduled restart..."

sleep infinity
