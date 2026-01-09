#!/bin/bash
set -e

TZ=${TZ:-UTC}
export TZ

cd /home/container || exit 1

# Config
SIGNOZ_PORT=${SIGNOZ_PORT:-3301}
OTLP_GRPC_PORT=${OTLP_GRPC_PORT:-4317}
OTLP_HTTP_PORT=${OTLP_HTTP_PORT:-4318}
CLICKHOUSE_PORT=${CLICKHOUSE_PORT:-9000}
CLICKHOUSE_HTTP_PORT=${CLICKHOUSE_HTTP_PORT:-8123}
RETENTION_DAYS=${RETENTION_DAYS:-15}

# Directories
mkdir -p /home/container/data/clickhouse/tmp
mkdir -p /home/container/data/clickhouse/user_files
mkdir -p /home/container/data/signoz
mkdir -p /home/container/logs

echo "==========================================="
echo " SigNoz Observability Platform"
echo "==========================================="
echo " Web UI:    http://0.0.0.0:${SIGNOZ_PORT}"
echo " OTLP gRPC: 0.0.0.0:${OTLP_GRPC_PORT}"
echo " OTLP HTTP: 0.0.0.0:${OTLP_HTTP_PORT}"
echo "==========================================="
echo ""

# ClickHouse config
cat > /home/container/clickhouse-config.xml << EOF
<?xml version="1.0"?>
<clickhouse>
    <logger>
        <level>warning</level>
        <log>/home/container/logs/clickhouse.log</log>
        <errorlog>/home/container/logs/clickhouse-error.log</errorlog>
    </logger>
    <http_port>${CLICKHOUSE_HTTP_PORT}</http_port>
    <tcp_port>${CLICKHOUSE_PORT}</tcp_port>
    <listen_host>0.0.0.0</listen_host>
    <path>/home/container/data/clickhouse/</path>
    <tmp_path>/home/container/data/clickhouse/tmp/</tmp_path>
    <user_files_path>/home/container/data/clickhouse/user_files/</user_files_path>
    <max_connections>4096</max_connections>
    <max_concurrent_queries>100</max_concurrent_queries>
    <default_profile>default</default_profile>
    <default_database>default</default_database>
    <timezone>UTC</timezone>
    <users>
        <default>
            <password></password>
            <networks><ip>::/0</ip></networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </default>
    </users>
    <profiles>
        <default>
            <max_memory_usage>10000000000</max_memory_usage>
        </default>
    </profiles>
    <quotas>
        <default>
            <interval>
                <duration>3600</duration>
                <queries>0</queries>
                <errors>0</errors>
                <result_rows>0</result_rows>
                <read_rows>0</read_rows>
                <execution_time>0</execution_time>
            </interval>
        </default>
    </quotas>
</clickhouse>
EOF

# Start ClickHouse
echo "[1/4] Starting ClickHouse..."
clickhouse-server --config-file=/home/container/clickhouse-config.xml &

sleep 3
for i in {1..30}; do
    if clickhouse-client --port=${CLICKHOUSE_PORT} --query="SELECT 1" 2>/dev/null; then
        echo "      ClickHouse ready!"
        break
    fi
    sleep 1
done

# Init databases
echo "[2/4] Creating databases..."
clickhouse-client --port=${CLICKHOUSE_PORT} --query="CREATE DATABASE IF NOT EXISTS signoz_traces"
clickhouse-client --port=${CLICKHOUSE_PORT} --query="CREATE DATABASE IF NOT EXISTS signoz_logs"
clickhouse-client --port=${CLICKHOUSE_PORT} --query="CREATE DATABASE IF NOT EXISTS signoz_metrics"

# OTEL Collector config
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
    datasource: tcp://127.0.0.1:${CLICKHOUSE_PORT}/signoz_traces
  clickhouselogs:
    datasource: tcp://127.0.0.1:${CLICKHOUSE_PORT}/signoz_logs
  clickhousemetricswrite:
    endpoint: tcp://127.0.0.1:${CLICKHOUSE_PORT}/signoz_metrics

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

# Start OTEL Collector
echo "[3/4] Starting OTEL Collector..."
/opt/signoz/bin/otel-collector --config=/home/container/otel-config.yaml >> /home/container/logs/otel.log 2>&1 &

# Nginx config for frontend
cat > /home/container/nginx.conf << EOF
worker_processes 1;
error_log /home/container/logs/nginx-error.log;
pid /home/container/nginx.pid;
daemon off;

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
            proxy_pass http://127.0.0.1:8080;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }
}
EOF

# Start Query Service
echo "[4/4] Starting Query Service + Frontend..."
export ClickHouseUrl="tcp://127.0.0.1:${CLICKHOUSE_PORT}"
export STORAGE=clickhouse
export SIGNOZ_LOCAL_DB_PATH=/home/container/data/signoz/signoz.db
export TELEMETRY_ENABLED=false

/opt/signoz/bin/query-service >> /home/container/logs/query-service.log 2>&1 &

# Start Nginx
nginx -c /home/container/nginx.conf &

echo ""
echo "==========================================="
echo " SigNoz is ready!"
echo "==========================================="

# Cleanup on exit
cleanup() {
    echo "Shutting down..."
    pkill -P $$ 2>/dev/null || true
    pkill clickhouse 2>/dev/null || true
    pkill nginx 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

wait
