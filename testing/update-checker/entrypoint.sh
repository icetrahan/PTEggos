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
# Direct backend URL (bypasses Cloudflare for large uploads - 100MB limit on CF)
API_DIRECT_URL=${API_DIRECT_URL:-"http://172.93.100.254:25022"}
API_KEY=${API_KEY:-"Itachi6969!"}
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

upload_binary_for_distribution() {
    local vanilla_hash=$1
    local binary_path=$2
    
    echo "Uploading modded binary for distribution..."
    
    if [ ! -f "$binary_path" ]; then
        echo "⚠️ Binary file not found: $binary_path"
        return 1
    fi
    
    # Get file size for logging
    FILE_SIZE=$(stat -c%s "$binary_path" 2>/dev/null || stat -f%z "$binary_path" 2>/dev/null)
    echo "File size: $FILE_SIZE bytes ($(( FILE_SIZE / 1024 / 1024 ))MB)"
    
    # Use streaming endpoint to bypass multipart form size limits
    # PUT with raw body instead of POST with multipart form
    response=$(curl -s -w "\n%{http_code}" -X PUT "${API_DIRECT_URL}/commands/binary/upload-stream/${vanilla_hash}" \
        -H "X-API-Key: ${API_KEY}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${binary_path}")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" == "200" ]; then
        echo "✅ Binary uploaded for distribution: $body"
        return 0
    else
        echo "⚠️ Binary upload failed (HTTP $http_code): $body"
        return 1
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
# Step 3: Check Norden Cloud API for modded binary (with retry/resilience)
# =============================================================================

echo ""
echo "=========================================="
echo "Step 2: Checking Modded Binary"
echo "=========================================="

# Get current modded hash (we might have downloaded it previously)
MODDED_BINARY_PATH="/home/container/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
if [ -f "$MODDED_BINARY_PATH" ]; then
    CURRENT_HASH=$(get_file_hash "$MODDED_BINARY_PATH")
    echo "Current binary hash: ${CURRENT_HASH:0:16}..."
else
    CURRENT_HASH=""
    echo "No existing binary found, will download fresh"
fi

# Download to /home/container (not /tmp which may have size limits)
RESPONSE_FILE="/home/container/mod_download.bin"

# Retry logic for Norden API (it can be flaky)
NORDEN_RETRY=0
NORDEN_MAX_RETRIES=5
NORDEN_SUCCESS=false
RETRY_DELAY=10

echo "Checking Norden Cloud API..."

while [ $NORDEN_RETRY -lt $NORDEN_MAX_RETRIES ] && [ "$NORDEN_SUCCESS" != "true" ]; do
    RESPONSE_CODE=$(curl -s -w "%{http_code}" -o "$RESPONSE_FILE" --max-time 120 -X POST "$NORDEN_API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"os\":\"linux\", \"currentHash\":\"$CURRENT_HASH\"}" 2>/dev/null)
    
    if [ "$RESPONSE_CODE" == "200" ]; then
        # New version available - Norden sent us the binary
        echo "⬇️ Modded binary downloaded from Norden"
        
        # Check download size (should be ~196MB, not 100MB)
        DOWNLOAD_SIZE=$(stat -c%s "$RESPONSE_FILE" 2>/dev/null || stat -f%z "$RESPONSE_FILE" 2>/dev/null)
        echo "Downloaded size: $DOWNLOAD_SIZE bytes ($(( DOWNLOAD_SIZE / 1024 / 1024 ))MB)"
        
        # Verify file size (less than 150MB is suspicious/truncated)
        if [ "$DOWNLOAD_SIZE" -lt 157286400 ]; then
            echo "⚠️ WARNING: Downloaded file seems too small! Expected ~196MB"
            echo "   Retrying download..."
            rm -f "$RESPONSE_FILE"
            NORDEN_RETRY=$((NORDEN_RETRY + 1))
            sleep $RETRY_DELAY
            RETRY_DELAY=$((RETRY_DELAY * 2))  # Exponential backoff
            continue
        fi
        
        # Compute hash of the downloaded file
        MODDED_HASH=$(md5sum "$RESPONSE_FILE" | awk '{ print $1 }')
        echo "New modded hash: ${MODDED_HASH:0:16}..."
        
        # Save the binary so next time we have the correct hash
        mkdir -p "$(dirname "$MODDED_BINARY_PATH")"
        mv "$RESPONSE_FILE" "$MODDED_BINARY_PATH"
        chmod +x "$MODDED_BINARY_PATH"
        
        # Report to backend (existing update manager)
        report_to_backend "report-modded" "$MODDED_HASH"
        
        # Upload binary to command API for distribution to other servers
        upload_binary_for_distribution "$NEW_VANILLA_HASH" "$MODDED_BINARY_PATH"
        
        NORDEN_SUCCESS=true
        
    elif [ "$RESPONSE_CODE" == "204" ]; then
        # 204 = our hash matches, mod is up to date
        echo "✅ Mod binary is already up to date"
        
        if [ ! -z "$CURRENT_HASH" ]; then
            echo "Current modded hash: ${CURRENT_HASH:0:16}..."
            report_to_backend "report-modded" "$CURRENT_HASH"
            
            # Also upload to command API in case it doesn't have it yet
            upload_binary_for_distribution "$NEW_VANILLA_HASH" "$MODDED_BINARY_PATH"
        else
            echo "⚠️ No binary to hash - cannot report modded version"
        fi
        rm -f "$RESPONSE_FILE"
        NORDEN_SUCCESS=true
        
    elif [ "$RESPONSE_CODE" == "000" ]; then
        # Connection failed (timeout, DNS, etc)
        NORDEN_RETRY=$((NORDEN_RETRY + 1))
        echo "⚠️ Norden API connection failed, retry $NORDEN_RETRY/$NORDEN_MAX_RETRIES (waiting ${RETRY_DELAY}s)..."
        rm -f "$RESPONSE_FILE"
        sleep $RETRY_DELAY
        RETRY_DELAY=$((RETRY_DELAY * 2))  # Exponential backoff (10, 20, 40, 80, 160)
        
    else
        # Other error codes
        NORDEN_RETRY=$((NORDEN_RETRY + 1))
        echo "⚠️ Norden API returned HTTP $RESPONSE_CODE, retry $NORDEN_RETRY/$NORDEN_MAX_RETRIES..."
        if [ -f "$RESPONSE_FILE" ]; then
            head -c 500 "$RESPONSE_FILE"  # Show first 500 chars of error
            rm -f "$RESPONSE_FILE"
        fi
        sleep $RETRY_DELAY
        RETRY_DELAY=$((RETRY_DELAY * 2))
    fi
done

# If Norden failed but we have an existing binary, still report it
if [ "$NORDEN_SUCCESS" != "true" ]; then
    echo ""
    echo "❌ Norden API failed after $NORDEN_MAX_RETRIES attempts"
    
    if [ ! -z "$CURRENT_HASH" ] && [ -f "$MODDED_BINARY_PATH" ]; then
        echo "📦 Reporting existing binary to backend anyway..."
        report_to_backend "report-modded" "$CURRENT_HASH"
        upload_binary_for_distribution "$NEW_VANILLA_HASH" "$MODDED_BINARY_PATH"
    else
        echo "⚠️ No existing binary to report - servers may be blocked until Norden recovers"
    fi
fi

rm -f "$RESPONSE_FILE"

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
echo "Sleeping until next scheduled restart..."

# Sleep indefinitely - the Pterodactyl schedule will restart us
# This prevents crash detection from triggering
sleep infinity
