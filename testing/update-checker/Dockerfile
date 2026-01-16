FROM ghcr.io/parkervcp/yolks:debian

LABEL author="Primal Heaven" maintainer="ice@primalheaven.com"

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies: steamcmd, curl, jq
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        lib32gcc-s1 \
        lib32stdc++6 \
        curl \
        ca-certificates \
        jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create container user and directories
RUN useradd -m -d /home/container -s /bin/bash container

USER container
ENV USER=container HOME=/home/container

WORKDIR /home/container

COPY --chown=container:container entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/bin/bash", "/entrypoint.sh"]
