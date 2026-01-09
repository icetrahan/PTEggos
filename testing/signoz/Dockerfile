FROM        --platform=$TARGETOS/$TARGETARCH ubuntu:22.04

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

# Download SigNoz Query Service binary
ARG         SIGNOZ_VERSION=0.55.0
ARG         TARGETARCH
RUN         mkdir -p /opt/signoz/bin \
            && cd /opt/signoz/bin \
            && if [ "$TARGETARCH" = "arm64" ]; then \
                 wget -q "https://github.com/SigNoz/signoz/releases/download/v${SIGNOZ_VERSION}/query-service_${SIGNOZ_VERSION}_linux_arm64.tar.gz" -O query-service.tar.gz; \
               else \
                 wget -q "https://github.com/SigNoz/signoz/releases/download/v${SIGNOZ_VERSION}/query-service_${SIGNOZ_VERSION}_linux_amd64.tar.gz" -O query-service.tar.gz; \
               fi \
            && tar -xzf query-service.tar.gz \
            && rm query-service.tar.gz \
            && chmod +x query-service

# Download SigNoz OTEL Collector binary
ARG         OTEL_VERSION=0.102.12
RUN         cd /opt/signoz/bin \
            && if [ "$TARGETARCH" = "arm64" ]; then \
                 wget -q "https://github.com/SigNoz/signoz-otel-collector/releases/download/v${OTEL_VERSION}/signoz-otel-collector_${OTEL_VERSION}_linux_arm64.tar.gz" -O otel.tar.gz; \
               else \
                 wget -q "https://github.com/SigNoz/signoz-otel-collector/releases/download/v${OTEL_VERSION}/signoz-otel-collector_${OTEL_VERSION}_linux_amd64.tar.gz" -O otel.tar.gz; \
               fi \
            && tar -xzf otel.tar.gz \
            && rm otel.tar.gz \
            && mv signoz-otel-collector otel-collector || mv signoz-otel-collector_* otel-collector || true \
            && chmod +x otel-collector

# Download SigNoz Frontend
RUN         mkdir -p /opt/signoz/frontend \
            && cd /opt/signoz/frontend \
            && wget -q "https://github.com/SigNoz/signoz/releases/download/v${SIGNOZ_VERSION}/frontend-${SIGNOZ_VERSION}.tar.gz" -O frontend.tar.gz \
            && tar -xzf frontend.tar.gz \
            && rm frontend.tar.gz

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
