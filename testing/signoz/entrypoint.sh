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

# ClickHouse config - tuned for limited Pterodactyl resources
cat > /home/container/clickhouse-config.xml << EOF
<?xml version="1.0"?>
<clickhouse>
    <logger>
        <level>warning</level>
        <log>/home/container/logs/clickhouse.log</log>
        <errorlog>/home/container/logs/clickhouse-error.log</errorlog>
        <size>100M</size>
        <count>3</count>
    </logger>
    
    <http_port>${CLICKHOUSE_HTTP_PORT}</http_port>
    <tcp_port>${CLICKHOUSE_PORT}</tcp_port>
    <listen_host>0.0.0.0</listen_host>
    
    <path>/home/container/data/clickhouse/</path>
    <tmp_path>/home/container/data/clickhouse/tmp/</tmp_path>
    <user_files_path>/home/container/data/clickhouse/user_files/</user_files_path>
    
    <!-- Reduced resource limits for Pterodactyl -->
    <max_connections>256</max_connections>
    <max_concurrent_queries>20</max_concurrent_queries>
    
    <!-- Thread pool tuning - CRITICAL for low-resource environments -->
    <max_thread_pool_size>100</max_thread_pool_size>
    <max_thread_pool_free_size>10</max_thread_pool_free_size>
    <thread_pool_queue_size>1000</thread_pool_queue_size>
    
    <!-- Background pool settings - reduced for Pterodactyl -->
    <background_pool_size>4</background_pool_size>
    <background_move_pool_size>2</background_move_pool_size>
    <background_schedule_pool_size>4</background_schedule_pool_size>
    <background_fetches_pool_size>2</background_fetches_pool_size>
    <background_common_pool_size>4</background_common_pool_size>
    <background_buffer_flush_schedule_pool_size>2</background_buffer_flush_schedule_pool_size>
    <background_message_broker_schedule_pool_size>2</background_message_broker_schedule_pool_size>
    <background_distributed_schedule_pool_size>2</background_distributed_schedule_pool_size>
    
    <!-- Memory limits -->
    <max_server_memory_usage_to_ram_ratio>0.8</max_server_memory_usage_to_ram_ratio>
    <total_memory_profiler_step>4194304</total_memory_profiler_step>
    
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
            <max_memory_usage>4000000000</max_memory_usage>
            <max_threads>8</max_threads>
            <max_insert_threads>2</max_insert_threads>
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
    
    <!-- Merge tree settings for lower resource usage -->
    <merge_tree>
        <max_suspicious_broken_parts>5</max_suspicious_broken_parts>
        <parts_to_throw_insert>300</parts_to_throw_insert>
        <parts_to_delay_insert>150</parts_to_delay_insert>
        <max_delay_to_insert>1</max_delay_to_insert>
    </merge_tree>
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

# ClickHouse config - tuned for Pterodactyl's limited resources
cat > /home/container/clickhouse-config.xml << EOF
<?xml version="1.0"?>
<clickhouse>
    <logger>
        <level>warning</level>
        <log>/home/container/logs/clickhouse.log</log>
        <errorlog>/home/container/logs/clickhouse-error.log</errorlog>
        <size>100M</size>
        <count>3</count>
    </logger>
    
    <http_port>${CLICKHOUSE_HTTP_PORT}</http_port>
    <tcp_port>${CLICKHOUSE_PORT}</tcp_port>
    <listen_host>0.0.0.0</listen_host>
    
    <path>/home/container/data/clickhouse/</path>
    <tmp_path>/home/container/data/clickhouse/tmp/</tmp_path>
    <user_files_path>/home/container/data/clickhouse/user_files/</user_files_path>
    
    <!-- Reduced for Pterodactyl -->
    <max_connections>256</max_connections>
    <max_concurrent_queries>20</max_concurrent_queries>
    
    <!-- CRITICAL: Thread pool settings to prevent "Not enough threads" crash -->
    <max_thread_pool_size>100</max_thread_pool_size>
    <max_thread_pool_free_size>10</max_thread_pool_free_size>
    <thread_pool_queue_size>1000</thread_pool_queue_size>
    
    <!-- Background pools - reduced from defaults (512!) to fit container limits -->
    <!-- Must be >= 10 so that pool_size * 2 >= 20 (number_of_free_entries_in_pool_to_execute_mutation default) -->
    <background_pool_size>16</background_pool_size>
    <background_move_pool_size>2</background_move_pool_size>
    <background_schedule_pool_size>4</background_schedule_pool_size>
    <background_fetches_pool_size>2</background_fetches_pool_size>
    <background_common_pool_size>4</background_common_pool_size>
    <background_buffer_flush_schedule_pool_size>2</background_buffer_flush_schedule_pool_size>
    <background_message_broker_schedule_pool_size>2</background_message_broker_schedule_pool_size>
    <background_distributed_schedule_pool_size>2</background_distributed_schedule_pool_size>
    
    <max_server_memory_usage_to_ram_ratio>0.8</max_server_memory_usage_to_ram_ratio>
    
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
            <max_memory_usage>4000000000</max_memory_usage>
            <max_threads>8</max_threads>
            <max_insert_threads>2</max_insert_threads>
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
    
    <merge_tree>
        <max_suspicious_broken_parts>5</max_suspicious_broken_parts>
        <parts_to_throw_insert>300</parts_to_throw_insert>
        <parts_to_delay_insert>150</parts_to_delay_insert>
        <number_of_free_entries_in_pool_to_execute_mutation>4</number_of_free_entries_in_pool_to_execute_mutation>
        <number_of_free_entries_in_pool_to_lower_max_size_of_merge>4</number_of_free_entries_in_pool_to_lower_max_size_of_merge>
    </merge_tree>
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
