#!/bin/bash

TZ=${TZ:-UTC}
export TZ

cd /home/container || exit 1

# Config
SIGNOZ_PORT=${SIGNOZ_PORT:-3301}
OTLP_GRPC_PORT=${OTLP_GRPC_PORT:-4317}
OTLP_HTTP_PORT=${OTLP_HTTP_PORT:-4318}

# Read config.toml for runtime settings
CONFIG_FILE="/opt/signoz/config/pterodactyl.toml"
RUN_MIGRATIONS="true"
if [ -f "$CONFIG_FILE" ]; then
    # Parse run_migrations from TOML (simple grep approach)
    if grep -q "run_migrations.*=.*false" "$CONFIG_FILE" 2>/dev/null; then
        RUN_MIGRATIONS="false"
        echo "[Config] Migrations disabled via config.toml"
    fi
fi

# Directories
mkdir -p /home/container/data/clickhouse/tmp
mkdir -p /home/container/data/clickhouse/user_files
mkdir -p /home/container/data/clickhouse/format_schemas
mkdir -p /home/container/data/clickhouse/coordination/log
mkdir -p /home/container/data/clickhouse/coordination/snapshots
mkdir -p /home/container/data/signoz
mkdir -p /home/container/data/signoz/active-queries
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

echo "[1/5] Starting ClickHouse..."
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

echo "[3/5] Schema migrations..."
if [ "$RUN_MIGRATIONS" = "false" ]; then
    echo "      SKIPPED (disabled in config.toml)"
elif [ -f /opt/signoz/bin/schema-migrator ]; then
    echo "      Running migrator..."
    echo "=== RUNNING MIGRATIONS ===" >> /home/container/logs/migrator.log
    /opt/signoz/bin/schema-migrator sync \
        --dsn="tcp://127.0.0.1:9000" \
        --replication=false \
        --cluster-name="cluster" \
        >> /home/container/logs/migrator.log 2>&1 || echo "      Migration completed or had warnings"
    echo "      Done!"
else
    echo "      WARNING: schema-migrator not found"
fi

# OTEL config - minimal working config for v0.129.12
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
    
  clickhouselogsexporter:
    dsn: tcp://127.0.0.1:9000/?database=signoz_logs
    timeout: 10s
    
  signozclickhousemetrics:
    endpoint: tcp://127.0.0.1:9000/?database=signoz_metrics

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
      exporters: [signozclickhousemetrics]
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

# Prometheus config (needed by SigNoz)
cat > /home/container/config/prometheus.yml << PROMEOF
global:
  scrape_interval: 60s
  evaluation_interval: 60s
PROMEOF

echo "[5/5] Starting SigNoz..."
cd /home/container

# Environment variables for SigNoz v0.106.0 (using correct env var names from deprecation warnings)
# Telemetry store (ClickHouse)
export SIGNOZ_TELEMETRYSTORE_PROVIDER=clickhouse
export SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_DSN="tcp://127.0.0.1:9000"
export SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_CLUSTER="cluster"

# SQLite store
export SIGNOZ_SQLSTORE_SQLITE_PATH=/home/container/data/signoz/signoz.db

# Tokenizer (JWT)
export SIGNOZ_TOKENIZER_JWT_SECRET="pterodactyl-signoz-secret-key-12345"

# Analytics/Telemetry
export SIGNOZ_ANALYTICS_ENABLED=false

# Web frontend - SigNoz expects files at /etc/signoz/web by default
export SIGNOZ_WEB_DIRECTORY=/etc/signoz/web
export SIGNOZ_WEB_ENABLED=true

# Log config for debugging
echo "=== SIGNOZ CONFIG ===" >> /home/container/logs/signoz.log
echo "SIGNOZ_WEB_DIRECTORY=/etc/signoz/web" >> /home/container/logs/signoz.log
echo "SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_DSN=tcp://127.0.0.1:9000" >> /home/container/logs/signoz.log
ls -la /etc/signoz/web/ >> /home/container/logs/signoz.log 2>&1 || echo "Web dir not found!" >> /home/container/logs/signoz.log

# Start SigNoz unified binary
/opt/signoz/bin/signoz server >> /home/container/logs/signoz.log 2>&1 &
SIGNOZ_PID=$!
echo "      SigNoz started (PID: $SIGNOZ_PID)!"

# Wait a moment for SigNoz to start
sleep 5

# Check if SigNoz is still running and what port it's on
if kill -0 $SIGNOZ_PID 2>/dev/null; then
    # Check what ports are listening
    echo "      Checking listening ports..."
    LISTENING=$(ss -tlnp 2>/dev/null | grep -E ":(${SIGNOZ_PORT}|8080|3301)" || netstat -tlnp 2>/dev/null | grep -E ":(${SIGNOZ_PORT}|8080|3301)" || echo "Unable to check ports")
    echo "      $LISTENING"
    echo "      SigNoz is running!"
    
    # If SigNoz is on 8080 and we need 3301, use socat to forward
    if [ "${SIGNOZ_PORT}" != "8080" ]; then
        echo "      Starting port forwarder (${SIGNOZ_PORT} -> 8080)..."
        socat TCP-LISTEN:${SIGNOZ_PORT},fork,reuseaddr TCP:127.0.0.1:8080 >> /home/container/logs/socat.log 2>&1 &
        SOCAT_PID=$!
        echo "      Port forwarder started (PID: $SOCAT_PID)!"
    fi
else
    echo "      WARNING: SigNoz crashed - dumping logs:"
    tail -30 /home/container/logs/signoz.log
fi

echo ""
echo "==========================================="
echo " SigNoz started!"
echo " Check signoz.log for port info"
echo " OTLP gRPC: ${OTLP_GRPC_PORT}"
echo " OTLP HTTP: ${OTLP_HTTP_PORT}"
echo "==========================================="
echo ""

# Keep container running and monitor processes
while true; do
    # Monitor SigNoz
    if ! kill -0 $SIGNOZ_PID 2>/dev/null; then
        echo "[WARN] SigNoz process died, restarting..."
        /opt/signoz/bin/signoz server >> /home/container/logs/signoz.log 2>&1 &
        SIGNOZ_PID=$!
        sleep 5
    fi
    
    # Monitor OTEL
    if ! kill -0 $OTEL_PID 2>/dev/null; then
        echo "[WARN] OTEL Collector process died, restarting..."
        /opt/signoz/bin/otel-collector --config=/home/container/otel-config.yaml >> /home/container/logs/otel.log 2>&1 &
        OTEL_PID=$!
        sleep 5
    fi
    
    sleep 30
done
