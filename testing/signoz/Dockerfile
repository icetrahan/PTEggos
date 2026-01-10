# SigNoz unified image (v0.104.0+)
FROM        signoz/signoz:0.106.0 AS signoz-source
FROM        signoz/signoz-otel-collector:0.106.0 AS otel-source

FROM        ubuntu:22.04

LABEL       author="Primal Heaven" maintainer="primalheaven@example.com"
LABEL       org.opencontainers.image.source="https://github.com/YOUR_ORG/signoz-pterodactyl"
LABEL       org.opencontainers.image.licenses=MIT

ENV         DEBIAN_FRONTEND=noninteractive

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

# Copy from unified SigNoz image
RUN         mkdir -p /opt/signoz/bin /opt/signoz/frontend

# Copy signoz binary (unified query-service)
COPY        --from=signoz-source /signoz /opt/signoz/bin/signoz

# Copy frontend static files from unified image
COPY        --from=signoz-source /etc/signoz/web /opt/signoz/frontend

# Copy OTEL collector binary and migrations
COPY        --from=otel-source /signoz-collector /opt/signoz/bin/otel-collector
COPY        --from=otel-source /signoz-collector-migrations /opt/signoz/migrations

# Make binaries executable
RUN         chmod +x /opt/signoz/bin/signoz /opt/signoz/bin/otel-collector

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
