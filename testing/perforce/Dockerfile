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

# Download and install Perforce server directly
RUN         cd /tmp \
            && wget -O p4d https://cdist2.perforce.com/perforce/r23.2/bin.linux26x86_64/p4d \
            && wget -O p4 https://cdist2.perforce.com/perforce/r23.2/bin.linux26x86_64/p4 \
            && chmod +x p4d p4 \
            && mv p4d /usr/local/bin/ \
            && mv p4 /usr/local/bin/ \
            && cd / \
            && rm -rf /tmp/*

# Set the locale
RUN         apt-get update && apt-get install -y locales \
            && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
            && locale-gen \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*
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
