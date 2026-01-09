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
                openjdk-11-jre-headless \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*

# Install ClickHouse
RUN         curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg \
            && echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" > /etc/apt/sources.list.d/clickhouse.list \
            && apt-get update \
            && apt-get install -y clickhouse-server clickhouse-client \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*

# Download SigNoz binaries
ARG         SIGNOZ_VERSION=0.38.0
RUN         mkdir -p /opt/signoz/bin \
            && cd /opt/signoz/bin \
            # Query Service
            && wget -q "https://github.com/SigNoz/signoz/releases/download/v${SIGNOZ_VERSION}/query-service-linux-amd64" -O query-service \
            && chmod +x query-service \
            # OTEL Collector  
            && wget -q "https://github.com/SigNoz/signoz-otel-collector/releases/download/v0.88.11/signoz-otel-collector_0.88.11_linux_amd64.tar.gz" -O otel.tar.gz \
            && tar -xzf otel.tar.gz \
            && mv signoz-otel-collector otel-collector \
            && chmod +x otel-collector \
            && rm otel.tar.gz

# Download SigNoz Frontend
RUN         mkdir -p /opt/signoz/frontend \
            && cd /opt/signoz/frontend \
            && wget -q "https://github.com/SigNoz/signoz/releases/download/v${SIGNOZ_VERSION}/frontend.tar.gz" -O frontend.tar.gz \
            && tar -xzf frontend.tar.gz \
            && rm frontend.tar.gz

# Install nginx for frontend
RUN         apt-get update \
            && apt-get install -y nginx \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN         apt-get update && apt-get install -y locales \
            && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
            && locale-gen \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*
ENV         LANG=en_US.UTF-8
ENV         LANGUAGE=en_US:en
ENV         LC_ALL=en_US.UTF-8

# Create config directory
RUN         mkdir -p /opt/signoz/config

# Copy configuration files
COPY        config/otel-collector-config.yaml /opt/signoz/config/otel-collector-config.yaml
COPY        config/clickhouse-config.xml /opt/signoz/config/clickhouse-config.xml
COPY        config/nginx.conf /opt/signoz/config/nginx.conf

## Setup user and working directory
RUN         useradd -m -d /home/container -s /bin/bash container \
            && chown -R container:container /opt/signoz \
            && mkdir -p /var/lib/clickhouse /var/log/clickhouse-server \
            && chown -R container:container /var/lib/clickhouse /var/log/clickhouse-server \
            && chown -R container:container /var/log/nginx /var/lib/nginx

USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

STOPSIGNAL SIGTERM

COPY        --chown=container:container entrypoint.sh /entrypoint.sh
RUN         chmod +x /entrypoint.sh
ENTRYPOINT  ["/usr/bin/tini", "-g", "--"]
CMD         ["/entrypoint.sh"]
