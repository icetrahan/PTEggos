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

# Switch to the container's working directory
cd /home/container || exit 1

# Set default values for Perforce server configuration
P4PORT=${P4PORT:-1666}
P4ROOT=${P4ROOT:-/home/container/p4root}
P4USER=${P4USER:-perforce}
P4NAME=${P4NAME:-master}
P4CASE=${P4CASE:-0}
P4UNICODE=${P4UNICODE:-0}

# Export Perforce environment variables
export P4PORT P4ROOT P4USER P4NAME P4CASE P4UNICODE

# Create P4ROOT directory if it doesn't exist
mkdir -p "$P4ROOT"

# Initialize Perforce server if not already initialized
if [ ! -f "$P4ROOT/server.locks/meta" ]; then
    echo "Initializing Perforce server..."
    
    # Set case sensitivity
    if [ "$P4CASE" = "1" ]; then
        CASE_FLAG="-C1"
    else
        CASE_FLAG="-C0"
    fi
    
    # Set unicode mode
    if [ "$P4UNICODE" = "1" ]; then
        UNICODE_FLAG="-xi"
    else
        UNICODE_FLAG=""
    fi
    
    # Initialize the server
    p4d -r "$P4ROOT" $CASE_FLAG $UNICODE_FLAG -p "$P4PORT" -d
    
    # Wait a moment for server to start
    sleep 2
    
    # Create initial user if specified
    if [ ! -z "$P4ADMIN_USER" ] && [ ! -z "$P4ADMIN_PASSWORD" ]; then
        echo "Creating admin user: $P4ADMIN_USER"
        
        # Create user spec
        echo "User: $P4ADMIN_USER
Email: $P4ADMIN_EMAIL
FullName: $P4ADMIN_FULLNAME
Type: standard" | p4 -p "localhost:$P4PORT" user -i -f
        
        # Set password
        echo "$P4ADMIN_PASSWORD" | p4 -p "localhost:$P4PORT" -u "$P4ADMIN_USER" passwd
        
        # Make user super user
        p4 -p "localhost:$P4PORT" -u "$P4ADMIN_USER" protect -o | \
        sed '/##$/a\\tsuper user * * //depot/...' | \
        p4 -p "localhost:$P4PORT" -u "$P4ADMIN_USER" protect -i
    fi
    
    # Stop the daemon for proper restart
    p4 -p "localhost:$P4PORT" admin stop
    sleep 2
fi

# Set the startup command
STARTUP="p4d -r $P4ROOT -p $P4PORT -d -v server=3"

# Add additional startup parameters if specified
if [ ! -z "$P4D_ARGS" ]; then
    STARTUP="$STARTUP $P4D_ARGS"
fi

echo "Starting Perforce server with command: $STARTUP"

# Start the Perforce server
exec $STARTUP
