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

# Primal Isles — Legacy Survival (non-Evrima)
# The Isle Dedicated Server = Steam app 412680.
# Legacy lives on the DEFAULT "public" branch; Evrima is -beta evrima.
# We pin -beta public and refuse evrima so this never pulls the Evrima build.

sleep 1

TZ=${TZ:-UTC}
export TZ

SRCDS_APPID=${SRCDS_APPID:-412680}
export SRCDS_APPID

# Force the Legacy (public) branch. Ignore any Evrima override.
STEAM_BRANCH=${STEAM_BRANCH:-public}
if [ "${STEAM_BRANCH}" = "evrima" ] || [ "${SRCDS_BETAID}" = "evrima" ]; then
    echo "⚠️  Evrima branch requested but this egg installs Legacy only — forcing 'public'"
    STEAM_BRANCH=public
fi
unset SRCDS_BETAID SRCDS_BETAPASS STEAM_BETA
export STEAM_BRANCH

INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

if [ -f "/usr/local/bin/proton" ]; then
    if [ ! -z ${SRCDS_APPID} ]; then
        mkdir -p /home/container/.steam/steam/steamapps/compatdata/${SRCDS_APPID}
        export STEAM_COMPAT_CLIENT_INSTALL_PATH="/home/container/.steam/steam"
        export STEAM_COMPAT_DATA_PATH="/home/container/.steam/steam/steamapps/compatdata/${SRCDS_APPID}"
        export PATH=$PATH:/root/.local/bin
    else
        echo -e "----------------------------------------------------------------------------------"
        echo -e "WARNING!!! Proton needs variable SRCDS_APPID, else it will not work. Please add it"
        echo -e "Server stops now"
        echo -e "----------------------------------------------------------------------------------"
        exit 0
    fi
fi

cd /home/container || exit 1

if [ "${STEAM_USER}" == "" ]; then
    echo -e "steam user is not set.\n"
    echo -e "Using anonymous user.\n"
    STEAM_USER=anonymous
    STEAM_PASS=""
    STEAM_AUTH=""
else
    echo -e "user set to ${STEAM_USER}"
fi

if [ -z ${AUTO_UPDATE} ] || [ "${AUTO_UPDATE}" == "1" ]; then
    if [ ! -z ${SRCDS_APPID} ]; then
        echo -e "Updating Legacy Isle (app ${SRCDS_APPID}, -beta ${STEAM_BRANCH})..."
        ./steamcmd/steamcmd.sh +force_install_dir /home/container +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} +app_update ${SRCDS_APPID} -beta ${STEAM_BRANCH} validate +quit
    else
        echo -e "No appid set. Starting Server"
    fi
else
    echo -e "Not updating game server as auto update was set to 0. Starting Server"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ini_bool() {
    case "${1,,}" in
        1|true|yes|on) echo "True" ;;
        *) echo "False" ;;
    esac
}

resolve_map_path() {
    case "${1}" in
        isle_v3) echo "/Game/TheIsle/Maps/Landscape3/Isle_V3" ;;
        isle_v4) echo "/Game/TheIsle/Maps/Landscape4/Landscape_04" ;;
        region2) echo "/Game/Region2/Isle_Region2" ;;
        region2_redwoods) echo "/Game/Region2/Isle_Region2_Redwoods" ;;
        dv_testlevel) echo "/Game/TheIsle/Maps/Developer/DV_TestLevel" ;;
        thenyaw) echo "/Game/TheIsle/Maps/Thenyaw_Island/Thenyaw_Island" ;;
        *)
            echo "Unknown map '${1}', defaulting to Thenyaw Island" >&2
            echo "/Game/TheIsle/Maps/Thenyaw_Island/Thenyaw_Island"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Config defaults (match legacy Game.ini conventions)
# ---------------------------------------------------------------------------
SERVER_NAME=${SERVER_NAME:-"The Isle Legacy Server"}
MAP=${MAP:-thenyaw}
MAX_PLAYERS=${MAX_PLAYERS:-125}
SERVER_PASSWORD=${SERVER_PASSWORD:-}
QUERY_PORT=${QUERY_PORT:-${SERVER_PORT}}
SERVER_DISCORD=${SERVER_DISCORD:-}
SERVER_ADMINS=${SERVER_ADMINS:-}
SERVER_DAY_LENGTH=${SERVER_DAY_LENGTH:-30}
SERVER_STARTING_TIME=${SERVER_STARTING_TIME:-341}
B_SERVER_DYNAMIC_TIME_OF_DAY=${B_SERVER_DYNAMIC_TIME_OF_DAY:-0}

B_SERVER_GLOBAL_CHAT=${B_SERVER_GLOBAL_CHAT:-true}
B_SERVER_AI=${B_SERVER_AI:-true}
SERVER_AI_MAX=${SERVER_AI_MAX:-100}
SERVER_AI_RATE=${SERVER_AI_RATE:-1.5}
B_SERVER_AI_PLAYER_SPAWNS=${B_SERVER_AI_PLAYER_SPAWNS:-true}
B_SERVER_GROWTH=${B_SERVER_GROWTH:-true}
B_SERVER_NESTING=${B_SERVER_NESTING:-true}
B_SERVER_SCENT=${B_SERVER_SCENT:-false}
B_SERVER_ALLOW_TURN_IN_PLACE=${B_SERVER_ALLOW_TURN_IN_PLACE:-false}
B_SERVER_FALL_DAMAGE=${B_SERVER_FALL_DAMAGE:-true}
B_SERVER_ALLOW_REPLAY_RECORDING=${B_SERVER_ALLOW_REPLAY_RECORDING:-true}
SERVER_DEAD_BODY_TIME=${SERVER_DEAD_BODY_TIME:-1200}
SERVER_RESPAWN_TIME=${SERVER_RESPAWN_TIME:-5}
SERVER_LOGOUT_TIME=${SERVER_LOGOUT_TIME:-26}

MAP_PATH=$(resolve_map_path "${MAP}")

# Strip discord.gg/ prefix if the panel user pasted a full invite URL
SERVER_DISCORD="${SERVER_DISCORD#https://discord.gg/}"
SERVER_DISCORD="${SERVER_DISCORD#http://discord.gg/}"
SERVER_DISCORD="${SERVER_DISCORD#discord.gg/}"

# ---------------------------------------------------------------------------
# Write Game.ini
# ---------------------------------------------------------------------------
GAME_INI_DIR="/home/container/TheIsle/Saved/Config/LinuxServer"
mkdir -p "${GAME_INI_DIR}"

cat > "${GAME_INI_DIR}/Game.ini" << GAMEINI_HEADER
[/Script/TheIsle.IGameSession]
ServerName=${SERVER_NAME}
ServerPassword=${SERVER_PASSWORD}
ServerSteamGroup=
bFamilySharing=false
bServerDatabase=true
bServerAllowChat=True
bServerBattleye=false
bServerGlobalChat=$(ini_bool "${B_SERVER_GLOBAL_CHAT}")
bServerNameTags=false
bServerExperimental=false
bServerAI=$(ini_bool "${B_SERVER_AI}")
ServerAIMax=${SERVER_AI_MAX}
ServerAIRate=${SERVER_AI_RATE}
bServerAIPlayerSpawns=$(ini_bool "${B_SERVER_AI_PLAYER_SPAWNS}")
bServerGrowth=$(ini_bool "${B_SERVER_GROWTH}")
bServerNesting=$(ini_bool "${B_SERVER_NESTING}")
bServerScent=$(ini_bool "${B_SERVER_SCENT}")
bServerAllowTurnInPlace=$(ini_bool "${B_SERVER_ALLOW_TURN_IN_PLACE}")
bServerFallDamage=$(ini_bool "${B_SERVER_FALL_DAMAGE}")
bServerAllowReplayRecording=$(ini_bool "${B_SERVER_ALLOW_REPLAY_RECORDING}")
ServerDeadBodyTime=${SERVER_DEAD_BODY_TIME}
ServerRespawnTime=${SERVER_RESPAWN_TIME}
ServerLogoutTime=${SERVER_LOGOUT_TIME}
ServerFootprintLifetime=60
ServerDiscord=${SERVER_DISCORD}
GAMEINI_HEADER

if [ -n "${SERVER_ADMINS}" ]; then
    IFS=$'\n,'
    for admin_id in ${SERVER_ADMINS}; do
        admin_id=$(echo "${admin_id}" | tr -d '[:space:]')
        if [ -n "${admin_id}" ]; then
            echo "ServerAdmins=${admin_id}" >> "${GAME_INI_DIR}/Game.ini"
        fi
    done
    unset IFS
fi

cat >> "${GAME_INI_DIR}/Game.ini" << GAMEINI_FOOTER

BannedUsers=(UserName="0",UniqueID="0")

[/Script/Engine.GameSession]
MaxPlayers=${MAX_PLAYERS}

[/script/theisle.igamemode]
ServerStartingTime=${SERVER_STARTING_TIME}
bServerDynamicTimeOfDay=${B_SERVER_DYNAMIC_TIME_OF_DAY}
ServerDayLength=${SERVER_DAY_LENGTH}
GAMEINI_FOOTER

echo "✅ Game.ini written to ${GAME_INI_DIR}/Game.ini"

# ---------------------------------------------------------------------------
# Startup command
# ---------------------------------------------------------------------------
EOS_CLIENT_ID="xyza7891gk5PRo3J7G9puCJGFJjmEguW"
EOS_CLIENT_SECRET="pKWl6t5i9NJK8gTpVlAxzENZ65P8hYzodV8Dqe5Rlc8"

if [ -z "${STARTUP}" ]; then
    export STARTUP="/home/container/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping ${MAP_PATH}?Port=${SERVER_PORT}?QueryPort=${QUERY_PORT}?MaxPlayers=${MAX_PLAYERS}?game=Survival?listen -log -ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=${EOS_CLIENT_ID} -ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=${EOS_CLIENT_SECRET}"
fi

MODIFIED_STARTUP=$(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo -e ":/home/container$ ${MODIFIED_STARTUP}"

eval ${MODIFIED_STARTUP}
