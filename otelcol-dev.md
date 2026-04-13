# Dev OTel Collector for dtlm

A local OpenTelemetry Collector instance used as a test target for
dtlm's `OTLPHTTPJSONExporter`. Paired with
[`otelcol-dev.yaml`](./otelcol-dev.yaml) in the project root.

This is **not** a production deployment. It has no TLS, no auth, no
persistence, no backend. Every record that arrives gets pretty-printed
to stdout and discarded. That is the feature.

## Why this exists

`OTLPHTTPJSONExporter` turns typed DTrace events into OTLP/HTTP+JSON
and POSTs them to
an OpenTelemetry Collector. You can't write that exporter without
something on the other end of the wire accepting the POSTs, parsing
them, and telling you what arrived. This collector is that something.

The feedback loop is:

```
dtlm (under development) ──POST──> otelcol-contrib ──> stdout (tailable)
```

When the exporter emits a malformed LogRecord, you see it immediately
in `/tmp/otelcol-dev.log` with the exact field the collector disliked.
When it emits a well-formed one, you see every attribute, every
resource key, every timestamp, fully decoded. That is the fastest
possible debugging loop for an OTel exporter.

## What's installed

One FreeBSD package:

```sh
sudo pkg install otelcol-contrib
```

Version at time of setup: **0.138.0**. The `otelcol-contrib`
distribution is the upstream "full" build — it includes every
receiver, processor, and exporter in the `opentelemetry-collector-contrib`
repository, not just the core subset in `otelcol`. Using contrib means
we don't have to rebuild anything when we later want to wire up the
`grafana-tempo`, `grafana-loki`, or `prometheusremotewrite` exporters.

The package lays down only four things:
- `/usr/local/bin/otelcol-contrib` — the binary
- `/usr/local/share/otelcol-contrib/config.yaml` — a stock sample
  config we ignored (it references a nonexistent nginx endpoint
  and only has a gRPC listener)
- `/usr/local/share/otelcol-contrib/README.md`
- License files

There is no `rc.d` script, no `/usr/local/etc/otelcol-contrib/`
config directory, and no service user. The port leaves all of that
to the operator — appropriate for a collector that's equally likely
to run as root, as a user, or inside a container.

## The config, explained section by section

See [`otelcol-dev.yaml`](./otelcol-dev.yaml). An OTel Collector config
has six top-level keys; ours uses five of them. Here is what each one
does and why it's set the way it is.

### `receivers:`

How data gets **into** the collector.

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
      grpc:
        endpoint: 0.0.0.0:4317
```

One receiver, `otlp`, with both transports enabled.

- **Port 4318** is the standard OTLP/HTTP port. It accepts POSTs to
  `/v1/logs`, `/v1/metrics`, and `/v1/traces`. Payloads can be either
  protobuf (`Content-Type: application/x-protobuf`) or JSON
  (`Content-Type: application/json`). dtlm and hwtlm use JSON
  on this port via `OTLPHTTPJSONExporter`.
- **Port 4317** is the standard OTLP/gRPC port. We enabled it even
  though dtlm doesn't target gRPC today, because it's free — the
  receiver exposes both transports by default and disabling gRPC
  takes more config than leaving it on. It's useful if you later
  want to verify the same payload encoded as protobuf.
- **`0.0.0.0`** means "listen on all interfaces," not just loopback.
  For a dev box that's fine; for anything else bind to `127.0.0.1`.

### `processors:`

Transformations applied between receipt and export.

```yaml
processors:
  batch:
    timeout: 200ms
    send_batch_size: 64
```

The `batch` processor groups small records into larger batches before
they hit any exporter. In production this is essential — unbatched
OTLP traffic is one HTTP POST per record and it will melt your
collector. In dev, batching is still required (the collector refuses
to start without it on most pipelines), so we include it with
aggressive settings:

- **`timeout: 200ms`** — flush after 200 ms of accumulated records
  even if the batch isn't full. Production default is 200 ms to 10 s
  depending on workload; 200 ms is fine for dev. Lower values reduce
  latency to stdout (so your `tail -f` shows the record sooner);
  higher values amortize more.
- **`send_batch_size: 64`** — flush immediately once 64 records have
  accumulated. Low cap so nothing sits around during interactive
  testing.

No `memory_limiter` processor. In production you want one to prevent
OOM under backpressure; in dev we won't push enough data to matter.

### `exporters:`

How data gets **out** of the collector.

```yaml
exporters:
  debug:
    verbosity: detailed
```

One exporter, `debug`, which prints every record to the collector's
own stdout in a human-readable format. The `verbosity: detailed`
setting controls how much of each record is printed:

- `basic` — just counts ("1 log record received")
- `normal` — counts + resource attributes
- `detailed` — full record: resource, scope, body, attributes, trace
  ID, span ID, flags, every field

We use `detailed` because the point of a dev collector is seeing
exactly what arrived, including fields dtlm might be setting wrong.

No retry policy, no queuing, no network — `debug` writes to the same
stdout the collector itself uses, so its only failure mode is "stdout
is closed." Nothing to configure.

### `extensions:`

Out-of-band components that aren't part of a data pipeline.

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
```

One extension, `health_check`, which exposes an HTTP endpoint that
returns **200 OK** when the collector is running and ready, and a
non-2xx status otherwise. The standard port is 13133.

This is how `curl -sf http://localhost:13133` becomes a useful
liveness probe. Scripts that want to know "is the collector up?"
use this endpoint. Systemd-style supervisors use it to decide when
the collector has finished starting up. We enable it so the bring-up
sequence in this doc can verify the collector is actually serving
before running the first real POST test.

### `service:`

The top-level wiring — which receivers feed which exporters, through
which processors, for which **signal**.

```yaml
service:
  extensions: [health_check]
  pipelines:
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
```

OTel has **three telemetry signals**: logs, metrics, and traces.
Each signal has its own independent pipeline — receivers and
exporters that can't process a given signal are silently excluded
from that pipeline. All three of our pipelines have the same shape
(`otlp → batch → debug`) because:

- **Logs** — dtlm emits one `LogRecord` per DTrace probe firing.
  This is the primary signal volume.
- **Metrics** — dtlm emits `Sum` / `Gauge` / `Histogram` /
  `ExponentialHistogram` data points from DTrace aggregations
  (`@ = count()`, `quantize()`, etc.) and from hwt per-function
  counts. See `DESIGN.md` §9 for the full mapping table.
- **Traces** — dtlm emits `Span`s from hwt function entry/exit
  pairs once the `hwt-function-trace` capability lands. None from
  the DTrace side in v1.

We enable all three now so the exporter author doesn't have to
touch the collector config to test a new signal — it'll already
be wired up.

`extensions: [health_check]` under `service:` is the "activate this
extension" list. Without it, the extension is defined but not
started.

## Starting, stopping, and verifying

### Start

```sh
/usr/local/bin/otelcol-contrib --config ~/Projects/ObservableBSD/otelcol-dev.yaml \
    > /tmp/otelcol-dev.log 2>&1 &
```

Runs in background. All collector output — including the pretty-
printed records from the `debug` exporter — goes to `/tmp/otelcol-dev.log`.

### Verify

```sh
# 1. Is the health endpoint up?
curl -sf http://localhost:13133 && echo UP

# 2. Are the receiver ports listening?
sockstat -l4 | grep -E '4317|4318|13133'

# 3. Does a minimal OTLP POST succeed?
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X POST http://localhost:4318/v1/logs \
    -H 'Content-Type: application/json' \
    -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"dtlm-test"}}]},"scopeLogs":[{"scope":{"name":"dtlm"},"logRecords":[{"body":{"stringValue":"hello"},"severityText":"INFO"}]}]}]}'
```

A passing run prints `HTTP 200` and a corresponding block in
`/tmp/otelcol-dev.log` showing the decoded payload.

### Stop

```sh
pkill -f otelcol-contrib
```

### Live tail of incoming data

```sh
tail -f /tmp/otelcol-dev.log
```

Every record dtlm POSTs shows up here within `batch.timeout` (200 ms
in our config) of arrival, fully pretty-printed.

### Validate config after edits

```sh
/usr/local/bin/otelcol-contrib validate --config ~/Projects/ObservableBSD/otelcol-dev.yaml
```

Silent exit = config valid. No restart needed to validate; restart
only when you want the changes to apply.

## Using this from the dtlm exporter

When `OTLPHTTPJSONExporter.swift` is being written, the minimum
contract between dtlm and this collector is:

1. POST to `http://localhost:4318/v1/logs` for log records,
   `/v1/metrics` for metrics, `/v1/traces` for spans.
2. `Content-Type: application/json`.
3. Body is the JSON encoding of an `ExportLogsServiceRequest`,
   `ExportMetricsServiceRequest`, or `ExportTraceServiceRequest`
   from [`opentelemetry-proto`](https://github.com/open-telemetry/opentelemetry-proto).
4. On success the collector returns **HTTP 200** with an empty JSON
   body `{}`. On rejection it returns **HTTP 400** with a
   `google.rpc.Status`-shaped JSON body describing what's wrong.
5. Standard OTel JSON encoding rules: `lowerCamelCase` field names,
   64-bit integers as decimal strings, byte fields as base64, trace
   IDs and span IDs as hex strings (**not** base64).

Point the exporter at `http://localhost:4318`, run
`dtlm watch <profile> --format otel --endpoint http://localhost:4318
--service dtlm-test --instance dev-box`, and watch the output in
`tail -f /tmp/otelcol-dev.log`. That's the loop.

## Performance tuning for OTLP export

At high probe rates (`sched-on-cpu`, `sched-enqueue` on many CPUs),
libdtrace's per-CPU kernel buffers can overflow. The following
mitigations are in place:

- **`onBufferedOutput` handler** — libdtrace delivers formatted
  strings directly in-process via `pollBuffered()`. No pipe, no
  reader thread, no syscall overhead per event.
- **Async sender thread** — HTTP POSTs run on a dedicated
  `DispatchQueue`, decoupled from the handler. The handler appends
  to the batch and returns immediately.
- **Time-based flush** — a 500 ms `DispatchSourceTimer` ensures
  low-rate profiles flush periodically, not only at shutdown.
- **`--bufsize` / `--switchrate` CLI flags** — let operators tune
  libdtrace's per-CPU buffer size (default 16 MB for structured
  mode) and buffer drain cadence (default 50 ms).
- **gzip compression** — POST bodies are compressed via libz
  (`Content-Encoding: gzip`).
- **Retry/backoff** — failed POSTs retry up to 2 times with
  exponential backoff (100 ms, 200 ms) before discarding.
- **Drop counter** — when drops occur, `dtlm.drops` is attached
  as an attribute on the next OTLP log batch.

### Not yet implemented

- Connection pooling / HTTP/2 tuning (URLSession handles this
  internally).
- `--batch-size` CLI flag (currently hardcoded to 200).

## What's deliberately not set up yet

- **No `rc.d/otelcol-contrib` wrapper.** A reboot kills the
  collector; restart it by hand. Switch to an `rc.d` script once
  the config stabilizes.
- **No TLS, no auth, no bind-to-127.0.0.1 hardening.** Dev-only.
  For anything that leaves the local host, change `0.0.0.0` to
  `127.0.0.1` in the receiver endpoints, add a TLS cert, and use
  a `bearertokenauth` extension.
- **No `file` exporter.** Only `debug` is wired up. Adding a `file`
  exporter that writes to `otelcol-received.jsonl` is three lines
  if you'd rather `jq` the received data than read the pretty-printed
  debug format. Not done yet because `debug` was enough to prove
  the pipeline works.
- **No backends (Grafana / Tempo / Loki / Prometheus).** The debug
  exporter is the terminus. When dtlm's OTel exporter is working
  and you want the full visual loop, the next step is:
  - `pkg install grafana grafana-tempo grafana-loki prometheus`
  - Rewire the `exporters:` block to `otlphttp/tempo`, `loki`,
    `prometheusremotewrite`
  - Point Grafana data sources at those three backends
  All four packages are in FreeBSD ports; none of this requires
  building from source.
- **No `memory_limiter` processor.** See the `processors:` section
  above.
