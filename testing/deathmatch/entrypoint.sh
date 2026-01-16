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

# =============================================================================
# Update Manager Configuration
# =============================================================================
API_BASE_URL=${API_BASE_URL:-"https://api.primalheaven.com"}
API_KEY=${API_KEY:-"Itachi6969!"}
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

# =============================================================================
# Step 0: Check if server is blocked (waiting for mod update)
# =============================================================================
if [ ! -z "$SERVER_ID" ] && [ ! -z "$API_BASE_URL" ]; then
    echo "=========================================="
    echo "Checking update status with backend..."
    echo "=========================================="
    
    RETRY_COUNT=0
    MAX_RETRIES=3
    BLOCKED=false
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        STATUS_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "${API_BASE_URL}/api/updates/server-status/${SERVER_ID}" \
            -H "X-API-Key: ${API_KEY}" 2>/dev/null)
        
        HTTP_CODE=$(echo "$STATUS_RESPONSE" | tail -n1)
        BODY=$(echo "$STATUS_RESPONSE" | sed '$d')
        
        if [ "$HTTP_CODE" == "200" ]; then
            # Parse blocked status from JSON
            BLOCKED=$(echo "$BODY" | grep -o '"blocked":[^,}]*' | cut -d':' -f2 | tr -d ' ')
            
            if [ "$BLOCKED" == "true" ]; then
                echo "🚫 Server is BLOCKED - waiting for mod update"
                echo "The game has updated but the mod is not ready yet."
                echo "Server will not start until mod is available."
                echo ""
                echo "Exiting... Pterodactyl will restart us when mod is ready."
                exit 0
            else
                echo "✅ Server is not blocked - proceeding with startup"
                
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

# Mod Update Check (ALWAYS runs, regardless of AUTO_UPDATE setting)
# This checks the Norden Cloud API for mod binary updates
echo -e "Checking for mod updates..."

MOD_API_URL="https://manage.norden.cloud/api/884851/1020410"

# Read current file hash if file exists
if [ -f "$MOD_FILE_PATH" ]; then
    CURRENT_HASH=$(get_file_hash "$MOD_FILE_PATH")
else
    CURRENT_HASH=""
fi

# Send POST request with hash to check for updates
RESPONSE_HEADERS=$(mktemp)
RESPONSE_CODE=$(curl -s -w "%{http_code}" -D "$RESPONSE_HEADERS" -o /home/container/response.bin -X POST "$MOD_API_URL" \
    -H "Content-Type: application/json" \
    -d "{\"os\":\"linux\", \"currentHash\":\"$CURRENT_HASH\"}")

# Handle response
if [ "$RESPONSE_CODE" == "200" ]; then
    echo -e "⬇️  New mod version available. Downloading..."
    mkdir -p "$(dirname "$MOD_FILE_PATH")"
    mv /home/container/response.bin "$MOD_FILE_PATH"
    chmod +x "$MOD_FILE_PATH"
    echo -e "✅ Mod binary downloaded and updated."
elif [ "$RESPONSE_CODE" == "204" ]; then
    echo -e "✅ Mod binary is already up to date."
else
    echo -e "❌ Mod update check failed with response code: $RESPONSE_CODE"
    if [ -f /home/container/response.bin ]; then
        cat /home/container/response.bin
    fi
    echo -e "🚫 Cannot proceed without mod - exiting"
    rm -f "$RESPONSE_HEADERS" /home/container/response.bin
    exit 1
fi

# Cleanup
rm -f "$RESPONSE_HEADERS" /home/container/response.bin

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

# Set the startup command
export STARTUP="/home/container/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping -QueryPort=$SERVER_PORT -Port=$SERVER_PORT  -ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=xyza7891gk5PRo3J7G9puCJGFJjmEguW -ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=pKWl6t5i9NJK8gTpVlAxzENZ65P8hYzodV8Dqe5Rlc8"

# Replace Startup Variables
MODIFIED_STARTUP=$(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo -e ":/home/container$ ${MODIFIED_STARTUP}"

# Run the Server
eval ${MODIFIED_STARTUP}