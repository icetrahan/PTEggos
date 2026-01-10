# Download binaries from GitHub releases
# https://github.com/SigNoz/signoz/releases
FROM        ubuntu:22.04

LABEL       author="Primal Heaven" maintainer="primalheaven@example.com"
LABEL       org.opencontainers.image.source="https://github.com/YOUR_ORG/signoz-pterodactyl"
LABEL       org.opencontainers.image.licenses=MIT

ENV         DEBIAN_FRONTEND=noninteractive

# Versions - update these to upgrade
ARG         SIGNOZ_VERSION=0.106.0
ARG         OTEL_VERSION=0.111.62

# Install dependencies
RUN         apt-get update && apt-get upgrade -y \
            && apt-get install -y \
                curl \
                wget \
                gnupg2 \
                ca-certificates \
                procps \
                net-tools \
                iproute2 \
                tini \
                nginx \
                locales \
            && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
            && locale-gen \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*

ENV         LANG=en_US.UTF-8
ENV         LANGUAGE=en_US:en
ENV         LC_ALL=en_US.UTF-8

# Install ClickHouse
RUN         curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg \
            && echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" > /etc/apt/sources.list.d/clickhouse.list \
            && apt-get update \
            && apt-get install -y clickhouse-server clickhouse-client \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*

# Create directories
RUN         mkdir -p /opt/signoz/bin /opt/signoz/frontend /opt/signoz/migrations

# Download SigNoz binary from GitHub releases
RUN         curl -fsSL "https://github.com/SigNoz/signoz/releases/download/v${SIGNOZ_VERSION}/signoz_linux_amd64.tar.gz" -o /tmp/signoz.tar.gz \
            && tar -xzf /tmp/signoz.tar.gz -C /opt/signoz/bin \
            && rm /tmp/signoz.tar.gz \
            && chmod +x /opt/signoz/bin/signoz

# Download OTEL Collector from GitHub releases
RUN         curl -fsSL "https://github.com/SigNoz/signoz-otel-collector/releases/download/v${OTEL_VERSION}/signoz-collector_linux_amd64.tar.gz" -o /tmp/otel.tar.gz \
            && tar -xzf /tmp/otel.tar.gz -C /opt/signoz \
            && mv /opt/signoz/signoz-collector /opt/signoz/bin/otel-collector || true \
            && rm /tmp/otel.tar.gz \
            && chmod +x /opt/signoz/bin/otel-collector || true

# Create directories and set permissions
RUN         mkdir -p /opt/signoz/config /opt/signoz/data \
            && useradd -m -d /home/container -s /bin/bash container \
            && chown -R container:container /opt/signoz \
            && mkdir -p /var/lib/clickhouse /var/log/clickhouse-server \
            && chown -R container:container /var/lib/clickhouse /var/log/clickhouse-server \
            && chown -R container:container /var/log/nginx /var/lib/nginx /run

USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

STOPSIGNAL SIGTERM

COPY        --chown=container:container entrypoint.sh /entrypoint.sh
RUN         chmod +x /entrypoint.sh
ENTRYPOINT  ["/usr/bin/tini", "-g", "--"]
CMD         ["/entrypoint.sh"]
