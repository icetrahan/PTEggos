#!/bin/bash

#
# SigNoz Entrypoint for Pterodactyl
# All-in-one startup: ClickHouse + Query Service + OTEL Collector + Frontend
#

set -e

# Default the TZ environment variable to UTC
TZ=${TZ:-UTC}
export TZ

# Set environment variable that holds the Internal Docker IP
INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

# Switch to the container's working directory
cd /home/container || exit 1

# Set default values for SigNoz configuration
SIGNOZ_PORT=${SIGNOZ_PORT:-3301}
OTLP_GRPC_PORT=${OTLP_GRPC_PORT:-4317}
OTLP_HTTP_PORT=${OTLP_HTTP_PORT:-4318}
CLICKHOUSE_HTTP_PORT=${CLICKHOUSE_HTTP_PORT:-8123}
CLICKHOUSE_PORT=${CLICKHOUSE_PORT:-9000}
RETENTION_DAYS=${RETENTION_DAYS:-15}
SIGNOZ_TELEMETRY_DISABLED=${SIGNOZ_TELEMETRY_DISABLED:-true}

export SIGNOZ_PORT OTLP_GRPC_PORT OTLP_HTTP_PORT CLICKHOUSE_HTTP_PORT CLICKHOUSE_PORT RETENTION_DAYS SIGNOZ_TELEMETRY_DISABLED

# Create data directories
mkdir -p /home/container/data/clickhouse
mkdir -p /home/container/data/signoz
mkdir -p /home/container/logs

echo "==========================================="
echo " SigNoz Observability Platform"
echo "==========================================="
echo ""
echo " Web UI:         http://0.0.0.0:${SIGNOZ_PORT}"
echo " OTLP gRPC:      0.0.0.0:${OTLP_GRPC_PORT}"
echo " OTLP HTTP:      0.0.0.0:${OTLP_HTTP_PORT}"
echo " Data Retention: ${RETENTION_DAYS} days"
echo ""
echo "==========================================="
echo ""

# Function to start ClickHouse
start_clickhouse() {
    echo "[1/4] Starting ClickHouse..."
    
    # Update ClickHouse config with custom data path
    mkdir -p /home/container/data/clickhouse
    
    clickhouse-server --config-file=/opt/signoz/config/clickhouse-config.xml \
        --pid-file=/home/container/clickhouse.pid \
        -- --path=/home/container/data/clickhouse \
        --logger.log=/home/container/logs/clickhouse.log \
        --logger.errorlog=/home/container/logs/clickhouse-error.log \
        --http_port=${CLICKHOUSE_HTTP_PORT} \
        --tcp_port=${CLICKHOUSE_PORT} &
    
    # Wait for ClickHouse to be ready
    echo "    Waiting for ClickHouse to start..."
    for i in {1..30}; do
        if clickhouse-client --port=${CLICKHOUSE_PORT} --query="SELECT 1" 2>/dev/null; then
            echo "    ClickHouse is ready!"
            break
        fi
        sleep 1
    done
}

# Function to initialize ClickHouse databases
init_clickhouse_db() {
    echo "[2/4] Initializing SigNoz databases..."
    
    # Create signoz databases if they don't exist
    clickhouse-client --port=${CLICKHOUSE_PORT} --query="CREATE DATABASE IF NOT EXISTS signoz_traces"
    clickhouse-client --port=${CLICKHOUSE_PORT} --query="CREATE DATABASE IF NOT EXISTS signoz_logs"  
    clickhouse-client --port=${CLICKHOUSE_PORT} --query="CREATE DATABASE IF NOT EXISTS signoz_metrics"
    
    echo "    Databases initialized!"
}

# Function to start OTEL Collector
start_otel_collector() {
    echo "[3/4] Starting OTEL Collector..."
    
    # Generate config with correct ports
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
    
    /opt/signoz/bin/otel-collector --config=/home/container/otel-config.yaml \
        >> /home/container/logs/otel-collector.log 2>&1 &
    
    echo "    OTEL Collector started on ports ${OTLP_GRPC_PORT} (gRPC) and ${OTLP_HTTP_PORT} (HTTP)"
}

# Function to start Query Service
start_query_service() {
    echo "[4/4] Starting Query Service + Frontend..."
    
    export ClickHouseUrl="tcp://localhost:${CLICKHOUSE_PORT}"
    export STORAGE=clickhouse
    export SIGNOZ_LOCAL_DB_PATH=/home/container/data/signoz/signoz.db
    export TELEMETRY_ENABLED=${SIGNOZ_TELEMETRY_DISABLED}
    
    /opt/signoz/bin/query-service \
        -config /opt/signoz/config/prometheus.yml \
        >> /home/container/logs/query-service.log 2>&1 &
    
    # Start nginx for frontend
    cat > /home/container/nginx.conf << EOF
worker_processes 1;
error_log /home/container/logs/nginx-error.log;
pid /home/container/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /home/container/logs/nginx-access.log;
    
    server {
        listen ${SIGNOZ_PORT};
        root /opt/signoz/frontend;
        index index.html;
        
        location / {
            try_files \$uri \$uri/ /index.html;
        }
        
        location /api {
            proxy_pass http://localhost:8080;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host \$host;
            proxy_cache_bypass \$http_upgrade;
        }
    }
}
EOF

    nginx -c /home/container/nginx.conf -g "daemon off;" &
    
    echo "    Frontend available at http://0.0.0.0:${SIGNOZ_PORT}"
}

# Cleanup function
cleanup() {
    echo ""
    echo "Shutting down SigNoz..."
    
    # Kill all child processes
    pkill -P $$ 2>/dev/null || true
    
    # Stop services gracefully
    if [ -f /home/container/clickhouse.pid ]; then
        kill $(cat /home/container/clickhouse.pid) 2>/dev/null || true
    fi
    
    echo "SigNoz stopped."
    exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Start all services
start_clickhouse
init_clickhouse_db
start_otel_collector
start_query_service

echo ""
echo "==========================================="
echo " SigNoz is ready!"
echo " Open http://your-server:${SIGNOZ_PORT} in your browser"
echo "==========================================="
echo ""

# Keep the container running and wait for signals
wait
