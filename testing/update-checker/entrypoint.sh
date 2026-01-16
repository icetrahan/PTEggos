#!/bin/bash

#
# Update Checker for Primal Heaven
# =================================
# This script checks for Isle vanilla and modded binary updates.
# Runs every 10 minutes via Pterodactyl schedule.
# Reports hashes to the backend API which orchestrates server restarts.
#

echo "=========================================="
echo "Primal Heaven Update Checker"
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

# Configuration from environment
API_BASE_URL=${API_BASE_URL:-"https://api.primalheaven.com"}
API_KEY=${API_KEY:-"update-checker-key"}
SRCDS_APPID=${SRCDS_APPID:-"1020410"}
NORDEN_API_URL=${NORDEN_API_URL:-"https://manage.norden.cloud/api/884851/1020410"}
STEAM_USER=${STEAM_USER:-"anonymous"}
STEAM_PASS=${STEAM_PASS:-""}

cd /home/container || exit 1

# =============================================================================
# Helper Functions
# =============================================================================

get_file_hash() {
    if [ -f "$1" ]; then
        md5sum "$1" | awk '{ print $1 }'
    else
        echo ""
    fi
}

report_to_backend() {
    local endpoint=$1
    local hash=$2
    
    echo "Reporting to $endpoint: ${hash:0:16}..."
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/updates/${endpoint}" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${API_KEY}" \
        -d "{\"hash\": \"${hash}\"}")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" == "200" ]; then
        echo "✅ Reported successfully: $body"
        return 0
    else
        echo "❌ Report failed (HTTP $http_code): $body"
        return 1
    fi
}

send_heartbeat() {
    echo "Sending heartbeat..."
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/updates/heartbeat" \
        -H "X-API-Key: ${API_KEY}")
    
    http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" == "200" ]; then
        echo "✅ Heartbeat sent"
    else
        echo "⚠️ Heartbeat failed (HTTP $http_code)"
    fi
}

# =============================================================================
# Step 1: Install/Update SteamCMD if needed
# =============================================================================

if [ ! -f "./steamcmd/steamcmd.sh" ]; then
    echo "Installing SteamCMD..."
    mkdir -p steamcmd
    cd steamcmd
    curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxvf -
    cd /home/container
fi

# =============================================================================
# Step 2: Run SteamCMD to get latest vanilla binary
# =============================================================================

echo ""
echo "=========================================="
echo "Step 1: Checking Vanilla Binary"
echo "=========================================="

# Store old hash for comparison
BINARY_PATH="/home/container/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
OLD_VANILLA_HASH=$(get_file_hash "$BINARY_PATH")

echo "Running SteamCMD update..."
./steamcmd/steamcmd.sh +force_install_dir /home/container \
    +login ${STEAM_USER} ${STEAM_PASS} \
    +app_update ${SRCDS_APPID} validate \
    +quit

# Get new hash
NEW_VANILLA_HASH=$(get_file_hash "$BINARY_PATH")

if [ -z "$NEW_VANILLA_HASH" ]; then
    echo "❌ Failed to get vanilla binary - file not found!"
else
    echo "Vanilla hash: ${NEW_VANILLA_HASH:0:16}..."
    
    if [ "$OLD_VANILLA_HASH" != "$NEW_VANILLA_HASH" ]; then
        echo "📦 Vanilla binary changed!"
    fi
    
    # Always report current hash - backend decides if it's new
    report_to_backend "report-vanilla" "$NEW_VANILLA_HASH"
fi

# =============================================================================
# Step 3: Check Norden Cloud API for modded binary
# =============================================================================

echo ""
echo "=========================================="
echo "Step 2: Checking Modded Binary"
echo "=========================================="

# Check what hash Norden has
# We send an empty hash to force it to tell us what the current version is
echo "Checking Norden Cloud API..."

RESPONSE_FILE=$(mktemp)
RESPONSE_CODE=$(curl -s -w "%{http_code}" -o "$RESPONSE_FILE" -X POST "$NORDEN_API_URL" \
    -H "Content-Type: application/json" \
    -d '{"os":"linux", "currentHash":"check-only"}')

if [ "$RESPONSE_CODE" == "200" ]; then
    # New version available - compute hash of downloaded file
    echo "⬇️ Modded binary available from Norden"
    
    # Move to temp location and hash it
    MODDED_HASH=$(md5sum "$RESPONSE_FILE" | awk '{ print $1 }')
    echo "Modded hash: ${MODDED_HASH:0:16}..."
    
    # Report to backend
    report_to_backend "report-modded" "$MODDED_HASH"
    
    # Clean up - we don't actually need the binary, just the hash
    rm -f "$RESPONSE_FILE"
    
elif [ "$RESPONSE_CODE" == "204" ]; then
    echo "ℹ️ Norden returned 204 - no binary to download"
    # This means we need to get the hash differently
    # Check if we have a previously stored modded hash
    if [ -f "/home/container/.modded_hash" ]; then
        MODDED_HASH=$(cat /home/container/.modded_hash)
        echo "Using cached modded hash: ${MODDED_HASH:0:16}..."
        report_to_backend "report-modded" "$MODDED_HASH"
    else
        echo "⚠️ No cached modded hash - need to download once to establish baseline"
        # Try with empty hash to force download
        RESPONSE_CODE=$(curl -s -w "%{http_code}" -o "$RESPONSE_FILE" -X POST "$NORDEN_API_URL" \
            -H "Content-Type: application/json" \
            -d '{"os":"linux", "currentHash":""}')
        
        if [ "$RESPONSE_CODE" == "200" ]; then
            MODDED_HASH=$(md5sum "$RESPONSE_FILE" | awk '{ print $1 }')
            echo "$MODDED_HASH" > /home/container/.modded_hash
            echo "Established modded hash: ${MODDED_HASH:0:16}..."
            report_to_backend "report-modded" "$MODDED_HASH"
        fi
    fi
    rm -f "$RESPONSE_FILE"
else
    echo "❌ Norden API returned HTTP $RESPONSE_CODE"
    if [ -f "$RESPONSE_FILE" ]; then
        cat "$RESPONSE_FILE"
        rm -f "$RESPONSE_FILE"
    fi
fi

# =============================================================================
# Step 4: Send heartbeat
# =============================================================================

echo ""
echo "=========================================="
echo "Step 3: Heartbeat"
echo "=========================================="

send_heartbeat

# =============================================================================
# Done
# =============================================================================

echo ""
echo "=========================================="
echo "Update check complete!"
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

# Exit cleanly - Pterodactyl will restart us on schedule
exit 0
