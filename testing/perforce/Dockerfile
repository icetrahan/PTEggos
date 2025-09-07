FROM        --platform=$TARGETOS/$TARGETARCH debian:bookworm-slim

LABEL       author="Matthew Penner" maintainer="matthew@pterodactyl.io"

LABEL       org.opencontainers.image.source="https://github.com/pterodactyl/yolks"
LABEL       org.opencontainers.image.licenses=MIT

ENV         DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN         apt-get update \
            && apt-get upgrade -y \
            && apt-get install -y \
                curl \
                wget \
                gnupg2 \
                software-properties-common \
                ca-certificates \
                apt-transport-https \
                lsb-release \
                procps \
                net-tools \
                iproute2 \
                tini \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*

# Add Perforce package repository
RUN         wget -qO - https://package.perforce.com/perforce.pubkey | apt-key add - \
            && echo "deb http://package.perforce.com/apt/ubuntu/ $(lsb_release -cs) release" > /etc/apt/sources.list.d/perforce.list

# Install Perforce server
RUN         apt-get update \
            && apt-get install -y helix-p4d \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN         sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
            locale-gen
ENV         LANG=en_US.UTF-8
ENV         LANGUAGE=en_US:en
ENV         LC_ALL=en_US.UTF-8

## Setup user and working directory
RUN         useradd -m -d /home/container -s /bin/bash container
USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

STOPSIGNAL SIGTERM

COPY        --chown=container:container entrypoint.sh /entrypoint.sh
RUN         chmod +x /entrypoint.sh
ENTRYPOINT  ["/usr/bin/tini", "-g", "--"]
CMD         ["/entrypoint.sh"]
