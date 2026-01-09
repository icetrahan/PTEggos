# SigNoz Pterodactyl Egg

Open-source observability platform with distributed tracing, metrics, and logs.

## Setup

### 1. Create GitHub Repository

Create a new repo (e.g., `signoz-pterodactyl`) and push these files.

### 2. Update References

Replace `YOUR_ORG` in these files with your GitHub org/username:
- `egg-signoz.json` (docker_images section)
- `Dockerfile` (LABEL)
- `.github/workflows/build.yml` will auto-detect

### 3. Enable GitHub Packages

Go to repo Settings → Actions → General:
- Enable "Read and write permissions" for workflows

### 4. Push & Build

```bash
git add .
git commit -m "Initial SigNoz egg"
git push origin main
```

GitHub Actions will automatically build and push to `ghcr.io/YOUR_ORG/signoz-pterodactyl:latest`

### 5. Import into Pterodactyl

1. Go to Pterodactyl Admin → Nests → Import Egg
2. Upload `egg-signoz.json`
3. Create a server using the egg

---

## Requirements

- **RAM**: 4GB minimum, 8GB recommended
- **Disk**: 20GB minimum
- **CPU**: 2+ cores recommended

---

## Ports to Allocate

| Port | Purpose | Required |
|------|---------|----------|
| 3301 | Web UI | ✅ Yes |
| 4317 | OTLP gRPC (traces/logs/metrics) | ✅ Yes |
| 4318 | OTLP HTTP (alternative) | Optional |
| 8123 | ClickHouse HTTP | Internal |
| 9000 | ClickHouse Native | Internal |

---

## Sending Traces to SigNoz

### Python

```bash
pip install opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp
```

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor

provider = TracerProvider()
exporter = OTLPSpanExporter(
    endpoint="http://YOUR_SIGNOZ_SERVER:4317",
    insecure=True
)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

tracer = trace.get_tracer(__name__)
with tracer.start_as_current_span("my-operation"):
    # your code here
    pass
```

### Environment Variables

Set these in your services:

```env
OTEL_EXPORTER_OTLP_ENDPOINT=http://YOUR_SIGNOZ_SERVER:4317
OTEL_SERVICE_NAME=my-service
```

---

## Files

```
signoz/
├── .github/
│   └── workflows/
│       └── build.yml        # GitHub Actions build workflow
├── config/
│   ├── clickhouse-config.xml
│   ├── nginx.conf
│   └── otel-collector-config.yaml
├── Dockerfile               # Multi-arch Docker image
├── egg-signoz.json          # Pterodactyl egg (import this!)
├── entrypoint.sh            # Startup script
└── README.md                # This file
```

---

## Troubleshooting

### Container won't start
- Check logs in Pterodactyl console
- Ensure ports 3301, 4317 are allocated

### No data in UI
- Verify services are sending to correct endpoint
- Check OTLP port is accessible
- Look at `/home/container/logs/otel-collector.log`

### High memory usage
- ClickHouse can be memory-hungry
- Consider increasing RAM allocation
- Reduce retention period

### Web UI not loading
- Check nginx logs: `/home/container/logs/nginx-error.log`
- Verify port 3301 is allocated and accessible

---

## Data Retention

Default: 15 days

Change via Pterodactyl panel variable `RETENTION_DAYS`.

Data is stored in `/home/container/data/` which persists across restarts.
