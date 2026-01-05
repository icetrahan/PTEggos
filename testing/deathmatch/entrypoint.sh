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

# Mod Update Check (ALWAYS runs, regardless of AUTO_UPDATE setting)
# This checks the Norden Cloud API for mod binary updates
echo -e "Checking for mod updates..."

MOD_API_URL="https://manage.norden.cloud/api/884851/1020410"
MOD_FILE_PATH="/home/container/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"

# Function to compute MD5 hash of a file
get_file_hash() {
    md5sum "$1" | awk '{ print $1 }'
}

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
fi

# Cleanup
rm -f "$RESPONSE_HEADERS" /home/container/response.bin

# Set the startup command
export STARTUP="/home/container/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping -QueryPort=$SERVER_PORT -Port=$SERVER_PORT  -ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=xyza7891gk5PRo3J7G9puCJGFJjmEguW -ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=pKWl6t5i9NJK8gTpVlAxzENZ65P8hYzodV8Dqe5Rlc8"

# Replace Startup Variables
MODIFIED_STARTUP=$(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo -e ":/home/container$ ${MODIFIED_STARTUP}"

# Run the Server
eval ${MODIFIED_STARTUP}