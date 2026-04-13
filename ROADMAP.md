# ObservableBSD Roadmap

## Vision

ObservableBSD is an **OpenTelemetry producer for FreeBSD**. The kernel
already has the instrumentation — DTrace, hwt(4), cpuctl(4), sysctl —
but nothing connects it to the modern observability stack. We are
that connection.

Every tool in ObservableBSD shares a single OTel export pipeline. The
instrumentation sources are interchangeable; the OTel output is the
product.

---

## OTel Integration Roadmap

### Shipped (v0.1.0)

- OTLP/HTTP+JSON exporter (logs + metrics)
- Hand-rolled JSON envelope (zero dependencies)
- gzip compression (libz)
- Async sender with retry/backoff
- Resource attributes (service.name, host.name, os.type, os.version)
- Drop counter attribute (dtlm.drops)

### Next: Production OTel (v0.2.0)

| Feature | Why | Size |
|---------|-----|------|
| **OTLP/HTTP+Protobuf** | 3-10x smaller wire format than JSON. What production collectors expect. Protobuf encoding can be hand-rolled like the JSON — no external dep needed. | ~400 LOC |
| **OTel environment variables** | Standard configuration: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_EXPORTER_OTLP_HEADERS`. Every OTel-aware tool respects these. | ~100 LOC |
| **TLS support** | `https://` endpoints with system CA bundle. Required for any non-localhost collector. | ~50 LOC (URLSession handles it) |
| **Auth headers** | `--auth-bearer-file`, `--auth-header` for token-based auth. Grafana Cloud, Datadog, Honeycomb all require this. | ~50 LOC |
| **OTel semantic conventions** | Use standard attribute names: `process.pid`, `process.executable.name`, `host.arch`, `os.description`. Currently we use some standard names and some custom ones. Full compliance. | ~100 LOC |
| **`rc.d/dtlm` wrapper** | Run as a daemon: `service dtlm start`. Config in `/usr/local/etc/dtlm.conf`. Continuous telemetry, not just ad-hoc. | ~150 LOC |

### Future: Advanced OTel (v0.3.0+)

| Feature | Why | Size |
|---------|-----|------|
| **OTLP/gRPC+Protobuf** | Streaming transport — lower per-request overhead for high-rate producers. Required by some collectors (Tempo, Jaeger native). | ~300 LOC + grpc dep |
| **OTel Traces signal** | Span export for HWT function entry/exit and DTrace probe pairing. POST to `/v1/traces`. | ~450 LOC |
| **Prometheus remote write** | Direct export to Prometheus without a collector middleman. For metrics-heavy deployments. | ~200 LOC |
| **OTLP file exporter** | Write OTLP to disk as `.jsonl` or `.pb` for offline analysis, replay, or batch upload. | ~100 LOC |
| **Exemplars on metrics** | Link metrics to specific log records (e.g. "this histogram bucket spike was caused by this query"). OTel exemplars spec. | ~100 LOC |
| **Baggage propagation** | Carry context (tenant ID, request ID) from upstream services into dtlm's telemetry. | ~100 LOC |

### Shared OTelExport Library

The `OTelExport` module (already extracted in Package.swift) is the
shared foundation. Every ObservableBSD tool depends on it:

```
OTelExport (library)
├── Exporter protocol
├── TextExporter
├── JSONLExporter
├── OTLPHTTPJSONExporter
├── (future) OTLPHTTPProtobufExporter
├── (future) OTLPGRPCExporter
├── (future) PrometheusRemoteWriteExporter
├── Typed event model (ProbeEvent, AggregationSnapshot, FunctionSpan)
├── Resource attributes + auto-detection
├── OTel environment variable handling
└── Auth + TLS configuration
```

Adding a new tool (hwtlm, bptrace, or anything else) means writing
the instrumentation source and calling `exporter.emit()`. The entire
OTel pipeline — transport, encoding, compression, retry, auth,
resource attribution — comes for free.

---

## Tool Roadmap

### dtlm — DTrace Instruments

**Shipped.** 118 profiles, text/JSONL/OTLP output, typed metrics
from aggregations.

| Next | What |
|------|------|
| More USDT profiles | Redis, nginx (if USDT-enabled), Java (via USDT), Erlang/BEAM |
| `dtlm record` / `dtlm replay` | Record a session to disk, replay through exporters later |
| Continuous mode | `rc.d/dtlm` running a set of profiles as a daemon |

### hwtlm — Hardware Telemetry

**Shipped.** CPU power, temperatures, frequencies as OTel metrics.

| Next | What |
|------|------|
| GPU telemetry | AMD/Intel GPU temperature, frequency, utilization via sysctl |
| Disk health | SMART attributes via `libata` / `camcontrol` |
| Network interface stats | Bytes/packets/errors per interface as OTel metrics |

### bptrace — Hardware Trace (HWT)

**Planned.** Intel PT / ARM CoreSight / ARM SPE process tracing.

See [DESIGN-HWT.md](./DESIGN-HWT.md) for the full architecture.
First milestone: `bptrace watch --pid <pid> --format otel` producing
CPU profile data from Intel PT on amd64.

---

## Efficiency Targets

| Format | Wire size (1000 log records) | Status |
|--------|------------------------------|--------|
| OTLP/HTTP+JSON | ~500 KB | Shipped (gzip: ~50 KB) |
| OTLP/HTTP+JSON+gzip | ~50 KB | Shipped |
| OTLP/HTTP+Protobuf | ~50 KB | Planned |
| OTLP/HTTP+Protobuf+gzip | ~15 KB | Planned |
| OTLP/gRPC+Protobuf | ~50 KB + streaming | Future |

Protobuf encoding is the single biggest efficiency win. The hand-rolled
approach works the same way as our current JSON — walk the data model,
write bytes — but the output is binary varint-encoded instead of text.
No protobuf compiler dependency needed; we encode the wire format
directly.

---

## Non-Goals

- **Not a collector.** ObservableBSD produces OTel data. It doesn't
  receive, route, or store it. Use otelcol-contrib, Grafana Alloy,
  or any OTel-compatible collector for that.
- **Not a dashboard.** Use Grafana, Datadog, or any OTel-compatible
  frontend.
- **Not a replacement for dtrace(1).** dtlm wraps DTrace for
  structured export. For interactive debugging, `dtrace -n '...'`
  is still the right tool.
- **Not cross-platform.** FreeBSD only. The kernel interfaces we
  depend on don't exist elsewhere.
