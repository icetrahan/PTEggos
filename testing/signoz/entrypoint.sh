#!/bin/bash

#
# SigNoz Entrypoint for Pterodactyl
#

set -e

TZ=${TZ:-UTC}
export TZ

cd /home/container || exit 1

# Ports
SIGNOZ_PORT=${SIGNOZ_PORT:-3301}
OTLP_GRPC_PORT=${OTLP_GRPC_PORT:-4317}
OTLP_HTTP_PORT=${OTLP_HTTP_PORT:-4318}
CLICKHOUSE_PORT=${CLICKHOUSE_PORT:-9000}
RETENTION_DAYS=${RETENTION_DAYS:-15}

export SIGNOZ_PORT OTLP_GRPC_PORT OTLP_HTTP_PORT CLICKHOUSE_PORT RETENTION_DAYS

# Create directories
mkdir -p /home/container/data/clickhouse/tmp
mkdir -p /home/container/data/clickhouse/user_files
mkdir -p /home/container/data/clickhouse/format_schemas
mkdir -p /home/container/data/signoz
mkdir -p /home/container/logs

echo "==========================================="
echo " SigNoz Observability Platform"
echo "==========================================="
echo " Web UI:         http://0.0.0.0:${SIGNOZ_PORT}"
echo " OTLP gRPC:      0.0.0.0:${OTLP_GRPC_PORT}"
echo " OTLP HTTP:      0.0.0.0:${OTLP_HTTP_PORT}"
echo " Data Retention: ${RETENTION_DAYS} days"
echo "==========================================="
echo ""

# Start ClickHouse
start_clickhouse() {
    echo "[1/4] Starting ClickHouse..."
    
    clickhouse-server --config-file=/opt/signoz/config/clickhouse-config.xml &
    
    echo "    Waiting for ClickHouse..."
    for i in {1..60}; do
        if clickhouse-client --port=${CLICKHOUSE_PORT} --query="SELECT 1" 2>/dev/null; then
            echo "    ClickHouse ready!"
            return 0
        fi
        sleep 1
    done
    
    echo "    ERROR: ClickHouse failed to start"
    cat /home/container/logs/clickhouse-error.log 2>/dev/null || true
    return 1
}

# Initialize databases
init_db() {
    echo "[2/4] Initializing databases..."
    clickhouse-client --port=${CLICKHOUSE_PORT} --query="CREATE DATABASE IF NOT EXISTS signoz_traces" || true
    clickhouse-client --port=${CLICKHOUSE_PORT} --query="CREATE DATABASE IF NOT EXISTS signoz_logs" || true
    clickhouse-client --port=${CLICKHOUSE_PORT} --query="CREATE DATABASE IF NOT EXISTS signoz_metrics" || true
    echo "    Databases ready!"
}

# Start OTEL Collector
start_otel() {
    echo "[3/4] Starting OTEL Collector..."
    
    # Generate OTEL config with current ports
    cat > /home/container/otel-config.yaml << EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:${OTLP_GRPC_PORT}
      http:
        endpoint: 0.0.0.0:${OTLP_HTTP_PORT}

processors:
  batch:
    send_batch_size: 10000
    timeout: 10s

exporters:
  clickhousetraces:
    datasource: tcp://localhost:${CLICKHOUSE_PORT}/signoz_traces
  clickhouselogs:
    datasource: tcp://localhost:${CLICKHOUSE_PORT}/signoz_logs  
  clickhousemetricswrite:
    endpoint: tcp://localhost:${CLICKHOUSE_PORT}/signoz_metrics

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhousetraces]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouselogs]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhousemetricswrite]
EOF

    if [ -f "/opt/signoz/bin/otel-collector" ]; then
        /opt/signoz/bin/otel-collector --config=/home/container/otel-config.yaml \
            >> /home/container/logs/otel-collector.log 2>&1 &
        echo "    OTEL Collector started"
    else
        echo "    WARNING: OTEL Collector not found at /opt/signoz/bin/otel-collector"
    fi
}

# Start Query Service
start_query() {
    echo "[4/4] Starting Query Service..."
    
    export ClickHouseUrl="tcp://localhost:${CLICKHOUSE_PORT}"
    export STORAGE=clickhouse
    export SIGNOZ_LOCAL_DB_PATH=/home/container/data/signoz/signoz.db
    
    if [ -f "/opt/signoz/bin/query-service" ]; then
        /opt/signoz/bin/query-service >> /home/container/logs/query-service.log 2>&1 &
        echo "    Query Service started"
    else
        echo "    WARNING: Query Service not found at /opt/signoz/bin/query-service"
    fi
}

# Cleanup
cleanup() {
    echo "Shutting down..."
    pkill -P $$ 2>/dev/null || true
    pkill clickhouse 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

# Run
start_clickhouse && init_db && start_otel && start_query

echo ""
echo "==========================================="
echo " SigNoz running! Logs: /home/container/logs/"
echo "==========================================="
echo ""

wait
