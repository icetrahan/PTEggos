# Download everything from GitHub releases
# SigNoz: https://github.com/SigNoz/signoz/releases
# OTEL: https://github.com/SigNoz/signoz-otel-collector/releases
FROM        ubuntu:22.04

LABEL       author="Primal Heaven" maintainer="primalheaven@example.com"
LABEL       org.opencontainers.image.source="https://github.com/YOUR_ORG/signoz-pterodactyl"
LABEL       org.opencontainers.image.licenses=MIT

ENV         DEBIAN_FRONTEND=noninteractive

# Versions - update these to upgrade
# SigNoz: https://github.com/SigNoz/signoz/releases
# OTEL: https://github.com/SigNoz/signoz-otel-collector/releases
ARG         SIGNOZ_VERSION=0.106.0
ARG         OTEL_VERSION=0.129.12

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
# Structure: signoz_linux_amd64/bin/signoz (binary), signoz_linux_amd64/web/* (frontend), signoz_linux_amd64/conf/* (config)
RUN         curl -fsSL "https://github.com/SigNoz/signoz/releases/download/v${SIGNOZ_VERSION}/signoz_linux_amd64.tar.gz" -o /tmp/signoz.tar.gz \
            && mkdir -p /tmp/signoz-extract \
            && tar -xzf /tmp/signoz.tar.gz -C /tmp/signoz-extract \
            && ls -la /tmp/signoz-extract/signoz_linux_amd64/bin/ \
            && cp /tmp/signoz-extract/signoz_linux_amd64/bin/signoz /opt/signoz/bin/signoz \
            && chmod +x /opt/signoz/bin/signoz \
            && cp -r /tmp/signoz-extract/signoz_linux_amd64/web/* /opt/signoz/frontend/ \
            && cp -r /tmp/signoz-extract/signoz_linux_amd64/conf /opt/signoz/config \
            && rm -rf /tmp/signoz.tar.gz /tmp/signoz-extract

# Download OTEL Collector from GitHub releases
RUN         curl -fsSL "https://github.com/SigNoz/signoz-otel-collector/releases/download/v${OTEL_VERSION}/signoz-otel-collector_linux_amd64.tar.gz" -o /tmp/otel.tar.gz \
            && mkdir -p /tmp/otel-extract \
            && tar -xzf /tmp/otel.tar.gz -C /tmp/otel-extract \
            && ls -la /tmp/otel-extract/ \
            && find /tmp/otel-extract -type f | head -20 \
            && OTEL_BIN=$(find /tmp/otel-extract -type f \( -name "signoz-otel-collector" -o -name "otelcol*" \) ! -name "*.txt" | head -1) \
            && if [ -z "$OTEL_BIN" ]; then OTEL_BIN=$(find /tmp/otel-extract -type f -perm /111 | head -1); fi \
            && echo "Found OTEL binary: $OTEL_BIN" \
            && cp "$OTEL_BIN" /opt/signoz/bin/otel-collector \
            && chmod +x /opt/signoz/bin/otel-collector \
            && rm -rf /tmp/otel.tar.gz /tmp/otel-extract

# Download Schema Migrator from GitHub releases  
RUN         curl -fsSL "https://github.com/SigNoz/signoz-otel-collector/releases/download/v${OTEL_VERSION}/signoz-schema-migrator_linux_amd64.tar.gz" -o /tmp/migrator.tar.gz \
            && mkdir -p /tmp/migrator-extract \
            && tar -xzf /tmp/migrator.tar.gz -C /tmp/migrator-extract \
            && ls -la /tmp/migrator-extract/ \
            && find /tmp/migrator-extract -type f | head -20 \
            && MIGRATOR_BIN=$(find /tmp/migrator-extract -type f \( -name "signoz-schema-migrator" -o -name "*migrator" \) ! -name "*.txt" | head -1) \
            && if [ -z "$MIGRATOR_BIN" ]; then MIGRATOR_BIN=$(find /tmp/migrator-extract -type f -perm /111 | head -1); fi \
            && echo "Found migrator binary: $MIGRATOR_BIN" \
            && cp "$MIGRATOR_BIN" /opt/signoz/bin/schema-migrator \
            && chmod +x /opt/signoz/bin/schema-migrator \
            && rm -rf /tmp/migrator.tar.gz /tmp/migrator-extract

# Verify binaries exist
RUN         ls -la /opt/signoz/bin/ && echo "=== Verifying binaries ===" \
            && (test -f /opt/signoz/bin/signoz && echo "✓ signoz binary found" || echo "✗ signoz binary MISSING") \
            && (test -f /opt/signoz/bin/otel-collector && echo "✓ otel-collector binary found" || echo "✗ otel-collector binary MISSING") \
            && (test -f /opt/signoz/bin/schema-migrator && echo "✓ schema-migrator binary found" || echo "✗ schema-migrator binary MISSING")

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
