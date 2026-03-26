FROM ghcr.io/parkervcp/yolks:debian

LABEL author="Primal Heaven" maintainer="ice@primalheaven.com"

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        lib32gcc-s1 \
        lib32stdc++6 \
        curl \
        ca-certificates \
        jq \
        python3 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN id -u container &>/dev/null || useradd -m -d /home/container -s /bin/bash container

USER container
ENV USER=container HOME=/home/container

WORKDIR /home/container

COPY --chown=container:container entrypoint.sh /entrypoint.sh
COPY --chown=container:container patcher/ /home/container/patcher/
RUN chmod +x /entrypoint.sh

CMD ["/bin/bash", "/entrypoint.sh"]
