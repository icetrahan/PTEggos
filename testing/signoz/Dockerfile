# Download SigNoz from GitHub releases, OTEL from Docker image
# https://github.com/SigNoz/signoz/releases
FROM        signoz/signoz-otel-collector:latest AS otel-source

FROM        ubuntu:22.04

LABEL       author="Primal Heaven" maintainer="primalheaven@example.com"
LABEL       org.opencontainers.image.source="https://github.com/YOUR_ORG/signoz-pterodactyl"
LABEL       org.opencontainers.image.licenses=MIT

ENV         DEBIAN_FRONTEND=noninteractive

# Versions - update these to upgrade
# SigNoz: https://github.com/SigNoz/signoz/releases
# OTEL: Docker image signoz/signoz-otel-collector (see FROM above)
ARG         SIGNOZ_VERSION=0.106.0

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
# Structure: signoz_linux_amd64/signoz (binary), signoz_linux_amd64/web/* (frontend), signoz_linux_amd64/conf/* (config)
RUN         curl -fsSL "https://github.com/SigNoz/signoz/releases/download/v${SIGNOZ_VERSION}/signoz_linux_amd64.tar.gz" -o /tmp/signoz.tar.gz \
            && mkdir -p /tmp/signoz-extract \
            && tar -xzf /tmp/signoz.tar.gz -C /tmp/signoz-extract \
            && ls -la /tmp/signoz-extract/signoz_linux_amd64/ \
            && cp /tmp/signoz-extract/signoz_linux_amd64/signoz /opt/signoz/bin/signoz \
            && chmod +x /opt/signoz/bin/signoz \
            && cp -r /tmp/signoz-extract/signoz_linux_amd64/web/* /opt/signoz/frontend/ \
            && cp -r /tmp/signoz-extract/signoz_linux_amd64/conf /opt/signoz/config \
            && rm -rf /tmp/signoz.tar.gz /tmp/signoz-extract

# Copy OTEL Collector from Docker image
COPY        --from=otel-source /signoz-collector /opt/signoz/bin/otel-collector
COPY        --from=otel-source /signoz-collector-migrations /opt/signoz/migrations
RUN         chmod +x /opt/signoz/bin/otel-collector

# Verify binaries exist
RUN         ls -la /opt/signoz/bin/ && echo "=== Verifying binaries ===" \
            && (test -f /opt/signoz/bin/signoz && echo "✓ signoz binary found" || echo "✗ signoz binary MISSING") \
            && (test -f /opt/signoz/bin/otel-collector && echo "✓ otel-collector binary found" || echo "✗ otel-collector binary MISSING")

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
