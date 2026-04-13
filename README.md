# ObservableBSD

**Convert FreeBSD's instrumentation surface to OpenTelemetry telemetry.**

ObservableBSD bridges FreeBSD-native instrumentation — DTrace probes,
hardware-trace frameworks, kernel counters — into the modern
observability stack via OpenTelemetry. FreeBSD has rich instrumentation
built into the kernel; this project connects it to Grafana, Jaeger,
Loki, Prometheus, and any OTel-compatible backend.

## Scope

ObservableBSD aims to provide a complete observability toolkit for
FreeBSD, covering four areas:

| Tool | Domain | Status |
|------|--------|--------|
| [`dtlm`](#dtlm) | DTrace-based instruments and profiling — the FreeBSD equivalent of Apple Instruments | Shipped (v0.1.0) |
| [`hwtlm`](#hwtlm) | Hardware telemetry — CPU power (Intel RAPL), temperatures, frequencies, GPU state | Shipped (v0.1.0) |
| `bptrace` | Process tracing via Hardware Trace (HWT) — Intel PT and ARM CoreSight | Planned |

All tools emit OpenTelemetry-native output so their data flows into the
same collectors, dashboards, and alerting pipelines.

---

## dtlm

**Apple Instruments for FreeBSD, with OpenTelemetry output.**

`dtlm` bundles 118 DTrace profiling templates covering the equivalent
of Instruments' Time Profiler, System Trace, File Activity, Network
Activity, Allocations, Thread States, and Lock Contention — for both
kernel events and USDT-instrumented applications — and ships the
results as text, JSONL, or OTLP/HTTP+JSON to an OpenTelemetry
collector.

### Output formats

| Format | Flag | Description |
|--------|------|-------------|
| Text | `--format text` (default) | dwatch-style line output to stdout |
| JSONL | `--format json` | One JSON object per probe firing, pipe to `jq`/Loki/Vector |
| OTLP | `--format otel` | POST logs to `/v1/logs`, metrics to `/v1/metrics` on an OTel collector |

The OTLP exporter includes:
- Async sender thread (HTTP doesn't block the DTrace consumer)
- gzip compression via libz
- Retry with exponential backoff (2 attempts)
- Drop counter attribute (`dtlm.drops`) on data loss
- Typed metrics from DTrace aggregations (count/sum -> Sum, min/max/avg -> Gauge, quantize -> Histogram)

### Profile catalog (118 profiles)

| Category | Count | Examples |
|----------|-------|---------|
| Syscall | 24 | `open`, `kill`, `read-write`, `syscall-counts`, `slow-syscalls` |
| Scheduler | 18 | `sched-on-cpu`, `sched-off-cpu`, `sched-sleep`, `sched-wakeup` |
| TCP | 16 | `tcp-connect`, `tcp-send`, `tcp-state-change`, `tcp-io` |
| Process | 11 | `proc-create`, `proc-exec-success`, `proc-exit`, `proc-signal` |
| VFS | 9 | `vop_create`, `vop_lookup`, `vop_rename`, `vop_remove` |
| UDP | 6 | `udp-send`, `udp-receive`, `udplite` |
| Memory | 3 | `malloc-trace`, `malloc-counts`, `malloc-leaks` |
| VM | 3 | `vm-fault`, `vm-pgfault`, `vm-activity` |
| I/O | 3 | `io-start`, `io-done`, `io` |
| IP | 3 | `ip-send`, `ip-receive`, `ip` |
| Lock | 2 | `lock-contention`, `mutex-contention` |
| Function | 5 | `func-trace`, `func-time`, `kfunc-trace`, `kfunc-time`, `lib-calls` |
| USDT Apps | 9 | `postgresql-queries`, `mysql-queries`, `python-calls`, `node-http`, `ruby-calls` |
| Composite | 6 | `system-trace`, `file-activity`, `network-activity`, `thread-states` |

### Quick start

```sh
# Build
swift build

# List every bundled profile
.build/debug/dtlm list

# Watch kill(2) syscalls system-wide
sudo .build/debug/dtlm watch kill

# Filter by process, run for 60 seconds
sudo .build/debug/dtlm watch open --execname nginx --duration 60

# JSONL output, pipe to jq
sudo .build/debug/dtlm watch tcp-connect --format json | jq .

# Send to an OpenTelemetry collector
sudo .build/debug/dtlm watch syscall-counts --format otel --duration 10

# Custom endpoint
sudo .build/debug/dtlm watch sched-on-cpu --format otel --endpoint http://collector:4318 --duration 5

# Trace malloc in a specific process
sudo .build/debug/dtlm watch malloc-trace --param pid=1234

# Trace PostgreSQL queries
sudo .build/debug/dtlm watch postgresql-queries --param pid=$(pgrep postgres)

# Measure time in a kernel function
sudo .build/debug/dtlm watch kfunc-time --param func=tcp_output --duration 10

# Trace a user-space function with stacks
sudo .build/debug/dtlm watch func-trace --param pid=5678 --param func=SSL_read --with-ustack

# Discover USDT probes in a running process
sudo .build/debug/dtlm watch usdt-list --param pid=1234 --duration 1

# Run an arbitrary .d file
sudo .build/debug/dtlm watch -f /path/to/myscript.d

# Tune DTrace buffers for high-rate profiles
sudo .build/debug/dtlm watch sched-on-cpu --format otel --bufsize 64m --switchrate 10ms --duration 5

# Print rendered D source (no root needed)
.build/debug/dtlm generate kill --pid 1234

# List available DTrace probes
sudo .build/debug/dtlm probes --provider tcp
```

### Custom profiles

Drop a `.d` file into `~/.dtlm/profiles/` and dtlm picks it up automatically:

```sh
mkdir -p ~/.dtlm/profiles

cat > ~/.dtlm/profiles/my-trace.d << 'EOF'
/*
 * Count syscalls by name for a specific process
 */
syscall:::entry
/* @dtlm-predicate */
{
    @[probefunc] = count();
}

dtrace:::END
{
    printa("%-30s %@d\n", @);
}
EOF

# It shows up in the catalog
dtlm list | grep my-trace

# Run it with filters
sudo dtlm watch my-trace --execname nginx --duration 30 --format otel
```

**Profile markers:**
- `/* @dtlm-predicate */` — replaced with `--pid`/`--execname`/`--where` filters
- `/* @dtlm-predicate-and */` — appended to an existing predicate
- `/* @dtlm-stack */` / `/* @dtlm-ustack */` — replaced with `stack()`/`ustack()` when `--with-stack`/`--with-ustack` is set
- `${name}` — substituted from `--param name=value`

**Profile sources** (higher priority shadows lower):
1. `~/.dtlm/profiles/` (user)
2. `/usr/local/share/dtlm/profiles/` (system)
3. Bundled in the binary

### DTrace buffer tuning

| Flag | Default | Effect |
|------|---------|--------|
| `--bufsize` | 4m (text), 16m (json/otel) | Per-CPU trace buffer size |
| `--switchrate` | 50ms | Buffer drain cadence |

For extreme probe rates (`sched-on-cpu` on many CPUs), increase buffers:
```sh
sudo dtlm watch sched-on-cpu --format otel --bufsize 64m --switchrate 10ms
```

---

## hwtlm

**Hardware telemetry for FreeBSD, with OpenTelemetry output.**

`hwtlm` collects CPU power consumption (Intel RAPL), per-core
temperatures, frequencies, C-state residency, ACPI thermal zones,
and GPU state — and ships them as text, JSONL, or OTLP metrics.

```sh
# List available sensors
hwtlm list

# Sample every 2 seconds, text output
sudo hwtlm watch --interval 2

# Per-core breakdown
sudo hwtlm watch --per-core --interval 1

# Send to OTel collector
sudo hwtlm watch --format otel --endpoint http://localhost:4318 --interval 5

# Measure energy cost of running a command
sudo hwtlm exec -- make -j20

# Run for 30 seconds
sudo hwtlm watch --duration 30
```

Requires the `cpuctl` kernel module for RAPL power data and
`coretemp` for temperature readings:
```sh
sudo kldload cpuctl
sudo kldload coretemp
```

Gracefully degrades on non-Intel systems — sysctl-based sensors
(temperatures, frequencies) work on all architectures.

---

## OTel Configuration

Both tools respect standard OpenTelemetry environment variables:

| Variable | Purpose |
|----------|---------|
| `OTEL_SERVICE_NAME` | Override `service.name` resource attribute |
| `OTEL_RESOURCE_ATTRIBUTES` | Extra resource attributes (`key=value,key=value`) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector base URL (overrides `--endpoint` default) |
| `OTEL_EXPORTER_OTLP_HEADERS` | Auth headers (`key=value,key=value`) |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | Export timeout in milliseconds (default 10000) |

Example with Grafana Cloud:
```sh
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp-gateway-prod-us-east-0.grafana.net/otlp
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic $(echo -n '<instance>:<token>' | base64)"
sudo dtlm watch syscall-counts --format otel --duration 60
```

---

## Requirements

- FreeBSD 15.0 or later
- Swift 6.3 or later
- DTrace enabled in the running kernel (default on `GENERIC`)
- Root for dtlm probes and hwtlm RAPL/cpuctl access
- For OTLP output: an OpenTelemetry collector (e.g. `otelcol-contrib`)

## Building

```sh
swift build
```

Builds both `dtlm` and `hwtlm` into `.build/debug/`.

## Testing

```sh
# Unit + structural tests (no root needed, 152 tests)
swift test

# Full integration sweep including libdtrace compilation of
# every bundled profile (requires root)
sudo swift test

# After root tests, restore .build ownership
sudo chown -R $(id -un):$(id -gn) .build
```

## Dependencies

- [FreeBSDKit](https://github.com/SwiftBSD/FreeBSDKit) >= 0.2.6
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) >= 1.2.0
- libz (system, for gzip compression)
- cpuctl(4) kernel module (for hwtlm RAPL access)

## License

BSD-2-Clause.
