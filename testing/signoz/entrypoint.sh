#!/bin/bash

TZ=${TZ:-UTC}
export TZ

cd /home/container || exit 1

# Config
SIGNOZ_PORT=${SIGNOZ_PORT:-3301}
OTLP_GRPC_PORT=${OTLP_GRPC_PORT:-4317}
OTLP_HTTP_PORT=${OTLP_HTTP_PORT:-4318}

# Directories
mkdir -p /home/container/data/clickhouse/tmp
mkdir -p /home/container/data/clickhouse/user_files
mkdir -p /home/container/data/clickhouse/format_schemas
mkdir -p /home/container/data/clickhouse/coordination/log
mkdir -p /home/container/data/clickhouse/coordination/snapshots
mkdir -p /home/container/data/signoz
mkdir -p /home/container/logs
mkdir -p /home/container/config
mkdir -p /home/container/nginx/body
mkdir -p /home/container/nginx/proxy
mkdir -p /home/container/nginx/fastcgi
mkdir -p /home/container/nginx/uwsgi
mkdir -p /home/container/nginx/scgi
mkdir -p /home/container/data/signoz/active-queries

echo "==========================================="
echo " SigNoz Observability Platform"
echo "==========================================="
echo " Web UI:    http://0.0.0.0:${SIGNOZ_PORT}"
echo " OTLP gRPC: 0.0.0.0:${OTLP_GRPC_PORT}"
echo " OTLP HTTP: 0.0.0.0:${OTLP_HTTP_PORT}"
echo "==========================================="
echo ""

# ClickHouse config
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

echo "[1/4] Starting ClickHouse..."
clickhouse-server --config-file=/home/container/clickhouse-config.xml >> /home/container/logs/clickhouse-stdout.log 2>&1 &
CLICKHOUSE_PID=$!

echo "      Waiting for ClickHouse (PID: $CLICKHOUSE_PID)..."

# Wait for port 9000 to be listening
COUNTER=0
while [ $COUNTER -lt 60 ]; do
    # Check if port is open using /dev/tcp
    if (echo > /dev/tcp/127.0.0.1/9000) 2>/dev/null; then
        echo "      Port 9000 open!"
        sleep 2
        echo "      ClickHouse ready!"
        break
    fi
    COUNTER=$((COUNTER + 1))
    sleep 1
done

if [ $COUNTER -eq 60 ]; then
    echo "      WARNING: ClickHouse may not be ready after 60s"
fi

echo "      Waiting for Keeper election..."
sleep 5

echo "[2/5] Creating databases..."
clickhouse-client --port=9000 --query="CREATE DATABASE IF NOT EXISTS signoz_traces" || echo "      traces failed"
clickhouse-client --port=9000 --query="CREATE DATABASE IF NOT EXISTS signoz_logs" || echo "      logs failed"
clickhouse-client --port=9000 --query="CREATE DATABASE IF NOT EXISTS signoz_metrics" || echo "      metrics failed"
echo "      Databases done!"

echo "[3/5] Running schema migrations..."
if [ -f /opt/signoz/bin/schema-migrator ]; then
    echo "      Migrating traces schema..."
    /opt/signoz/bin/schema-migrator sync --dsn="tcp://127.0.0.1:9000" --replication=false >> /home/container/logs/migrator.log 2>&1 || echo "      Migration warning (check migrator.log)"
    echo "      Schema migrations complete!"
else
    echo "      WARNING: schema-migrator not found, tables may need manual creation"
fi

# OTEL config - with migrations enabled
cat > /home/container/otel-config.yaml << 'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    send_batch_size: 10000
    timeout: 10s

exporters:
  clickhousetraces:
    datasource: tcp://127.0.0.1:9000/?database=signoz_traces
    docker_multi_node_cluster: false
    use_new_schema: true
    low_cardinal_exception_grouping: false
    migrations_folder: /opt/signoz/migrations/traces
    
  clickhouselogsexporter:
    dsn: tcp://127.0.0.1:9000/?database=signoz_logs
    docker_multi_node_cluster: false
    timeout: 10s
    migrations_folder: /opt/signoz/migrations/logs
    
  clickhousemetricswrite:
    endpoint: tcp://127.0.0.1:9000/?database=signoz_metrics
    resource_to_telemetry_conversion:
      enabled: true
    enable_exp_histogram: true
    migrations_folder: /opt/signoz/migrations/metrics

service:
  telemetry:
    metrics:
      address: 0.0.0.0:8888
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

echo "[4/5] Starting OTEL Collector..."
export SIGNOZ_COMPONENT=otel-collector
export ClickHouseUrl="tcp://127.0.0.1:9000"

echo "      Running migrations and starting collector..."
/opt/signoz/bin/otel-collector --config=/home/container/otel-config.yaml >> /home/container/logs/otel.log 2>&1 &
OTEL_PID=$!
echo "      OTEL started (PID: $OTEL_PID)!"

# Give OTEL collector time to start
sleep 3

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

# Prometheus config
cat > /home/container/config/prometheus.yml << PROMEOF
global:
  scrape_interval: 60s
  evaluation_interval: 60s
PROMEOF

echo "[5/5] Starting SigNoz + Nginx..."
cd /home/container
export SIGNOZ_CLICKHOUSE_DSN="tcp://127.0.0.1:9000"
export SIGNOZ_STORAGE_TYPE=clickhouse
export SIGNOZ_SQLITE_PATH=/home/container/data/signoz/signoz.db
export SIGNOZ_TELEMETRY_ENABLED=false
export SIGNOZ_JWT_SECRET="pterodactyl-signoz-secret-key-12345"
export SIGNOZ_WEB_PREFIX=/opt/signoz/frontend

/opt/signoz/bin/signoz >> /home/container/logs/signoz.log 2>&1 &
SIGNOZ_PID=$!
echo "      SigNoz started (PID: $SIGNOZ_PID)!"

echo "      Starting Nginx..."
nginx -p /home/container/ -c /home/container/nginx.conf >> /home/container/logs/nginx-stdout.log 2>&1 &
echo "      Nginx started!"

echo ""
echo "==========================================="
echo " SigNoz is ready!"
echo "==========================================="
echo ""

# Keep container running
while true; do
    sleep 60
done
