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

# Directories - create all required paths
mkdir -p /home/container/data/clickhouse/tmp
mkdir -p /home/container/data/clickhouse/user_files
mkdir -p /home/container/data/clickhouse/format_schemas
mkdir -p /home/container/data/clickhouse/coordination/log
mkdir -p /home/container/data/clickhouse/coordination/snapshots
mkdir -p /home/container/data/signoz
mkdir -p /home/container/logs
mkdir -p /home/container/config

echo "==========================================="
echo " SigNoz Observability Platform"
echo "==========================================="
echo " Web UI:    http://0.0.0.0:${SIGNOZ_PORT}"
echo " OTLP gRPC: 0.0.0.0:${OTLP_GRPC_PORT}"
echo " OTLP HTTP: 0.0.0.0:${OTLP_HTTP_PORT}"
echo "==========================================="
echo ""

# ClickHouse config with Keeper - SINGLE NODE using localhost for internal RAFT
cat > /home/container/clickhouse-config.xml << 'CHEOF'
<?xml version="1.0"?>
<clickhouse>
    <logger>
        <level>information</level>
        <log>/home/container/logs/clickhouse.log</log>
        <errorlog>/home/container/logs/clickhouse-error.log</errorlog>
        <size>100M</size>
        <count>3</count>
    </logger>
    
    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <interserver_http_port>9009</interserver_http_port>
    
    <listen_host>0.0.0.0</listen_host>
    
    <path>/home/container/data/clickhouse/</path>
    <tmp_path>/home/container/data/clickhouse/tmp/</tmp_path>
    <user_files_path>/home/container/data/clickhouse/user_files/</user_files_path>
    <format_schema_path>/home/container/data/clickhouse/format_schemas/</format_schema_path>
    
    <max_connections>256</max_connections>
    <max_concurrent_queries>20</max_concurrent_queries>
    
    <max_thread_pool_size>100</max_thread_pool_size>
    <max_thread_pool_free_size>10</max_thread_pool_free_size>
    <thread_pool_queue_size>1000</thread_pool_queue_size>
    
    <background_pool_size>16</background_pool_size>
    <background_move_pool_size>2</background_move_pool_size>
    <background_schedule_pool_size>16</background_schedule_pool_size>
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
    
    <!-- Single-node cluster -->
    <remote_servers>
        <cluster>
            <shard>
                <internal_replication>true</internal_replication>
                <replica>
                    <host>localhost</host>
                    <port>9000</port>
                </replica>
            </shard>
        </cluster>
    </remote_servers>
    
    <macros>
        <cluster>cluster</cluster>
        <shard>01</shard>
        <replica>replica-01</replica>
    </macros>
    
    <!-- ClickHouse Keeper embedded - single node -->
    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>1</server_id>
        <log_storage_path>/home/container/data/clickhouse/coordination/log</log_storage_path>
        <snapshot_storage_path>/home/container/data/clickhouse/coordination/snapshots</snapshot_storage_path>
        
        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>information</raft_logs_level>
            <force_sync>false</force_sync>
        </coordination_settings>
        
        <raft_configuration>
            <server>
                <id>1</id>
                <hostname>localhost</hostname>
                <port>9234</port>
            </server>
        </raft_configuration>
    </keeper_server>
    
    <!-- Connect to embedded Keeper -->
    <zookeeper>
        <node>
            <host>localhost</host>
            <port>9181</port>
        </node>
        <session_timeout_ms>30000</session_timeout_ms>
    </zookeeper>
    
    <distributed_ddl>
        <path>/clickhouse/task_queue/ddl</path>
    </distributed_ddl>
    
</clickhouse>
CHEOF

# Start ClickHouse
echo "[1/4] Starting ClickHouse with embedded Keeper..."
clickhouse-server --config-file=/home/container/clickhouse-config.xml &
CLICKHOUSE_PID=$!

# Wait for ClickHouse TCP port
echo "      Waiting for ClickHouse to start..."
for i in {1..60}; do
    if clickhouse-client --port=9000 --query="SELECT 1" 2>/dev/null; then
        echo "      ClickHouse TCP ready!"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "      ERROR: ClickHouse failed to start"
        cat /home/container/logs/clickhouse-error.log 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

# Wait for Keeper to be ready (check system.zookeeper)
echo "      Waiting for Keeper to elect leader..."
for i in {1..30}; do
    if clickhouse-client --port=9000 --query="SELECT * FROM system.zookeeper WHERE path='/'" 2>/dev/null | grep -q clickhouse; then
        echo "      Keeper is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "      WARNING: Keeper may not be fully ready, continuing anyway..."
    fi
    sleep 1
done

# Create databases - use ON CLUSTER for distributed DDL
echo "[2/4] Creating databases..."
clickhouse-client --port=9000 --query="CREATE DATABASE IF NOT EXISTS signoz_traces ON CLUSTER 'cluster'" || \
    clickhouse-client --port=9000 --query="CREATE DATABASE IF NOT EXISTS signoz_traces"
clickhouse-client --port=9000 --query="CREATE DATABASE IF NOT EXISTS signoz_logs ON CLUSTER 'cluster'" || \
    clickhouse-client --port=9000 --query="CREATE DATABASE IF NOT EXISTS signoz_logs"
clickhouse-client --port=9000 --query="CREATE DATABASE IF NOT EXISTS signoz_metrics ON CLUSTER 'cluster'" || \
    clickhouse-client --port=9000 --query="CREATE DATABASE IF NOT EXISTS signoz_metrics"

echo "      Databases created!"

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
    datasource: tcp://127.0.0.1:9000/signoz_traces
  clickhouselogsexporter:
    dsn: tcp://127.0.0.1:9000/signoz_logs
  clickhousemetricswrite:
    endpoint: tcp://127.0.0.1:9000/signoz_metrics

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhousetraces]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouselogsexporter]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhousemetricswrite]
EOF

# Start OTEL Collector
echo "[3/4] Starting OTEL Collector..."
/opt/signoz/bin/otel-collector --config=/home/container/otel-config.yaml >> /home/container/logs/otel.log 2>&1 &

# Create nginx temp directories
mkdir -p /home/container/nginx/body
mkdir -p /home/container/nginx/proxy
mkdir -p /home/container/nginx/fastcgi
mkdir -p /home/container/nginx/uwsgi
mkdir -p /home/container/nginx/scgi

# Nginx config
cat > /home/container/nginx.conf << EOF
worker_processes 1;
error_log /home/container/logs/nginx-error.log;
pid /home/container/nginx.pid;
daemon off;

events {
    worker_connections 1024;
}

http {
    client_body_temp_path /home/container/nginx/body;
    proxy_temp_path /home/container/nginx/proxy;
    fastcgi_temp_path /home/container/nginx/fastcgi;
    uwsgi_temp_path /home/container/nginx/uwsgi;
    scgi_temp_path /home/container/nginx/scgi;

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

# Prometheus config for query-service
cat > /home/container/config/prometheus.yml << PROMEOF
global:
  scrape_interval: 60s
  evaluation_interval: 60s
PROMEOF

# Create active queries directory
mkdir -p /home/container/data/signoz/active-queries

# Start Query Service
echo "[4/4] Starting Query Service + Frontend..."
cd /home/container
export ClickHouseUrl="tcp://127.0.0.1:9000"
export STORAGE=clickhouse
export SIGNOZ_LOCAL_DB_PATH=/home/container/data/signoz/signoz.db
export TELEMETRY_ENABLED=false
export SIGNOZ_JWT_SECRET="pterodactyl-signoz-secret-$(date +%s)"
export DEPLOYMENT_TYPE="docker-standalone"

/opt/signoz/bin/query-service >> /home/container/logs/query-service.log 2>&1 &

# Start Nginx
nginx -p /home/container/ -c /home/container/nginx.conf 2>/dev/null &

echo ""
echo "==========================================="
echo " SigNoz is ready!"
echo "==========================================="
echo ""
echo " Keeper status check:"
clickhouse-client --port=9000 --query="SELECT * FROM system.zookeeper WHERE path='/'" 2>/dev/null || echo "  (Keeper query failed)"
echo ""

# Cleanup on exit
cleanup() {
    echo "Shutting down..."
    pkill -P $$ 2>/dev/null || true
    kill $CLICKHOUSE_PID 2>/dev/null || true
    pkill nginx 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

wait
