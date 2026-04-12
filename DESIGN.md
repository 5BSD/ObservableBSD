# dtlm — Design Doc

> **dtlm is Apple Instruments for FreeBSD, with OpenTelemetry output.**
> It bundles a catalog of DTrace-backed profiling templates equivalent
> to Instruments' Time Profiler, System Trace, File Activity, Network,
> Allocations, Thread States, and Lock Contention — for both kernel
> events and your own USDT-instrumented applications — and ships the
> results as text, JSONL, or **OTLP/HTTP+JSON** to your existing
> OpenTelemetry collector with stack traces attached.
>
> It exists because FreeBSD has DTrace and nothing between it and the
> modern observability stack: no Instruments-equivalent profiling
> catalog, no OTel data source, no continuous-profiling story.

---

## 1. The pitch

```
.d profile  →  dtlm  →  libdtrace  →  events + aggregations + stacks  →  formatter  →  text / JSONL / OTLP
```

You write or pick a `.d` file. dtlm bundles ~40-50 of them, covering
both system observability (kernel events) and application
observability (USDT probes for common ports + a generic USDT wrapper
for your own probes). You run

```sh
dtlm watch postgres-query-time --pid 5123 \
     --with-ustack \
     --format otel \
     --endpoint http://collector:4318/v1/logs \
     --service postgres --instance prod-1
```

dtlm loads the script, applies your filter and parameter flags, runs
it via libdtrace, captures every probe firing, every aggregation
snapshot, and every stack trace, encodes the data as OTLP/HTTP+JSON
tagged with the right OTel resource attributes, and POSTs it to your
collector. The data shows up in Grafana / Tempo / Loki / your vendor
backend as **OTel logs** (one `LogRecord` per probe firing, with
stacks as attributes) and **typed OTel metrics** (counts as sums,
`quantize()` as `ExponentialHistogram`s, `min/max/avg` as `Gauge`s
— the right OTLP shape for each DTrace aggregation kind). W3C
`traceparent` propagation joins your USDT data into existing
distributed traces.

That's the entire product. One Swift binary. ~2150 LOC. ~50 bundled
profiles framed as Apple Instruments equivalents + a one-shot
generator that ships the full ~317-profile catalog via the FreeBSD
port. **Pluggable exporter architecture** so adding a Prometheus /
Loki / OTLP-protobuf / S3 / vendor-API exporter later is a new
file, not a rewrite.

---

## 2. Who it's for

Two equal audiences.

### Sysadmins

Operators running FreeBSD in production who want kernel observability
in the same dashboards they already have for Linux hosts and
applications. Today they have:

- `dwatch(1)` — text only, 85 profiles, no integration with anything
- Hand-rolled D scripts piped through `awk`
- Nothing structured for Grafana / Tempo / Loki

dtlm gives them ~25-30 ready-to-run **system profiles**, an
`--format otel` flag, and resource attribution (`--service`,
`--instance`) so the data is queryable in their existing tooling.

### Developers

Application developers (especially of FreeBSD-native services) who
have added USDT probes to their own code and want the data shipped
somewhere useful. Today they add USDT probes and the data goes
nowhere. dtlm gives them:

- **Probe discovery**: `dtlm probes --provider mywebapp --pid 1234`
  shows what's instrumented in their running process
- **Bundled USDT profiles** for ports that ship USDT (postgres, mysql,
  zfs, libc, libthr) — `dtlm watch postgres-query-time` works on day 1
- **A generic USDT wrapper**: `dtlm watch usdt-events
  --param provider=mywebapp --param probe=request_start --pid 1234`
- **The same OTel pipeline as the system half** — no separate agent,
  no separate format, no separate collector configuration

A developer who adds `MYWEBAPP_REQUEST_START(uid, path)` calls to their
C/C++/Swift/Rust code, ships the binary, and tells their ops team
"point dtlm at it" gets metrics + logs + stack traces in Grafana
without writing anything else.

**This is the dual story.** Same tool, same CLI, same output formats.
The difference between sysadmin and developer use is which `.d` file
in `dtlm list` you pick.

---

## 3. What dtlm IS and IS NOT

**dtlm IS:**
- A loader for `.d` files (bundled, system, or per-user)
- A thin wrapper around `libdtrace` (via FreeBSDKit's `DTraceCore`)
- **A pluggable exporter framework** that turns DTrace events,
  aggregation snapshots, and stack traces into one of three v1 output
  formats — **text**, **JSONL**, or **OTLP/HTTP+JSON** — and is
  designed so adding a fourth (Prometheus, Loki, OTLP-protobuf, S3
  archive, vendor API) is a new `Exporter` conformance, not a core
  rewrite
- A first-class **stack capture** path: `--with-stack` and
  `--with-ustack` plumb stack arrays into every output format
- **A catalog of profiling templates equivalent to Apple Instruments**
  — Time Profiler, System Trace, File Activity, Network Activity,
  Allocations, Thread States, Lock Contention, etc. — for both
  kernel events and your own USDT-instrumented applications
- A one-shot generator that ships the full ~296-profile
  `DBlocks.Dwatch.*` catalog as `.d` files via the FreeBSD port,
  layered on top of the hand-authored Instruments-equivalent set
- An OTel exporter that produces **logs** (one `LogRecord` per probe
  firing) and **typed metrics** (sums/gauges/histograms via the right
  OTLP shape per DTrace aggregation kind), with stack traces attached
  as attributes
- A production-deployable daemon (`rc.d/dtlm`) with sampling,
  graceful shutdown, OTel resource attribution, **HTTPS + bearer
  token auth** for OTLP, **W3C `traceparent` propagation** for
  joining USDT data into existing distributed traces, and exponential
  backoff on collector failures

**dtlm is NOT:**
- A replacement for `dtrace(1)` — it depends on it
- A replacement for OpenTelemetry — it produces OTel data, doesn't
  replace the Collector or any backend
- A general APM SDK — you don't add dtlm calls to your application
  code; you add USDT probes and dtlm reads them
- A flame-graph SVG renderer — `--with-ustack | flamegraph.pl`
  already works
- A profile playground — there is **no** inline `--probe` /
  `--print` mode; profiles are files
- DBlocks — dtlm uses `DTraceCore` directly; the typed Swift DSL is
  for programs that *construct* scripts, not load them

---

## 4. The problem and the gap

A FreeBSD operator today has two extreme choices and nothing in
between:

| Tool | What it gives you | What it doesn't |
|---|---|---|
| `dtrace(1)` | Total power. Write D, get any kernel event. | Text output. You write the parser. You write the dashboard. |
| `dwatch(1)` | 85 pre-made templates. One command, see output. | Text output. No structured fields. No OTel. No stacks in output. No app/USDT story. |

**In the middle: nothing.** There is no FreeBSD-native tool that takes
DTrace events and ships them as OpenTelemetry data. There is no tool
that bundles USDT-aware application profiles for FreeBSD ports. There
is no equivalent to the parca / pyroscope / opentelemetry-ebpf-profiler
stack that Linux operators take for granted.

**dtlm is that bridge.** It produces OTel logs (from probe events) and
OTel metrics (from aggregations), with stack traces attached as
attribute arrays — for both kernel observability and application
observability — through one CLI.

---

## 5. The contract: what's in a profile, what's in the CLI

A profile is a **`.d` file**. The filename is the profile name. The
first `/* … */` comment is the description. An optional
`/* @dtlm-predicate */` marker tells dtlm where to inject CLI filter
predicates. Everything else is plain D, handed to libdtrace verbatim.

Example, `Profiles/kill.d`:

```d
/* Print every kill(2) syscall */
syscall::kill:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: signal %d to pid %d",
           execname, pid, (int)arg1, (pid_t)arg0);
}
```

That file gives you `dtlm watch kill`, `dtlm watch kill --execname
nginx`, `dtlm watch kill --duration 30s`, `dtlm watch kill --format
otel --endpoint …`, etc. **No JSON wrapper. No metadata blocks. No
schema. No DBlocks Codable payload.**

### The script provides

- Probe specifications (`syscall::kill:entry`,
  `mywebapp$pid:::request_start`, `kinst::vm_fault:4`, etc.)
- Optional predicates (the part between `/…/` and `{`)
- Actions (`printf`, `count`, `quantize`, `assign`, `tracemem`,
  `stack`, `ustack`, …)
- Aggregation declarations
- Anything else valid D supports

### dtlm provides

- **Filter injection**: `--pid` / `--execname` / `--uid` / `--gid` /
  `--jail` get composed into a predicate that dtlm substitutes at the
  `/* @dtlm-predicate */` marker. Profiles without the marker still
  work; they just don't get filter-flag support.
- **Parameter substitution**: `${name}` placeholders in the .d file
  get replaced by `--param name=value` at load time, before the
  script reaches libdtrace.
- **Duration bound**: `--duration N` injects an equivalent
  `tick-Ns { exit(0); }` clause if the profile doesn't have one.
- **Output formatting**: text, JSONL, or OTLP/HTTP+JSON.
- **Stack capture**: `--with-stack` / `--with-ustack` add the
  appropriate `stack()` / `ustack()` action to every clause and
  surface the result in every output format.
- **Resource attribution** for OTel: `--service`, `--instance`,
  `--resource key=value,...`, plus auto-detected `host.name`,
  `os.name=freebsd`, `os.version`, `dtlm.version`.
- **Sampling**: `--sample 1/N` for high-frequency probes.
- **Production resilience**: graceful shutdown, pending-record flush
  on SIGTERM, exponential backoff on collector failures.

The script is the WHAT. dtlm is the HOW (filters), HOW LONG (duration),
HOW MUCH (sampling), WHERE (output format and destination), and
attribution.

---

## 6. The bundled catalog: Apple Instruments equivalents

dtlm ships ~40-50 hand-authored `.d` files framed around the
templates Apple's Instruments app provides. The framing is the
audience-facing pitch: anyone who has used Instruments on macOS
already knows what each profile does. For DTrace power users the
underlying probes are the same — the framing is a renaming, not a
reinvention. Both audiences get profiles in the same `Profiles/`
directory loaded by the same loader.

### Instruments-equivalent umbrella profiles

These are the headline templates — each is a single profile name a
user can run with `dtlm watch <name>` and immediately get
Instruments-shaped output:

| dtlm profile | Apple Instruments equivalent | What it does |
|---|---|---|
| `time-profiler` | **Time Profiler** | Sample at 99 Hz, capture user stacks, count by `ustack()`. The "where is time going?" tool. |
| `system-trace` | **System Trace** | Composes syscall entries, sched on/off-cpu transitions, and VM events into one combined view. |
| `file-activity` | **File Activity** | Combines `vop_*` and `syscall::open/read/write/...` for all filesystem activity, with paths and process attribution. |
| `network-activity` | **Network** | Combines `tcp:::*`, `udp:::*`, `ip:::*` for full network stack visibility. |
| `allocations` | **Allocations** | USDT-based malloc/free tracking via libc, with the requesting stack. |
| `thread-states` | **Thread States** | sched on-cpu / off-cpu / sleep / wakeup transitions per thread. |
| `lock-contention` | **Spin/Mutex Contention** | `lockstat:::adaptive-block`, `lockstat:::adaptive-spin`, `lockstat:::rw-block`, with the contending stack. |
| `system-calls` | **System Calls** | `syscall::: entry/return` aggregated by name, count, and slowness. |
| `process-activity` | **Activity Monitor** | `proc:::exec-success`, `proc:::exit`, per-process resource attribution. |

These compose smaller per-event profiles. Each umbrella profile is
typically 10-30 lines of D that enables the right probes and prints
or aggregates them in a useful way. The umbrella names are the
recommended starting point; the per-event profiles below are for
users who want narrower scope.

### Per-event system profiles (the supporting cast)

For users who want to scope their data more tightly than the umbrella
templates allow:

| Group | Profiles |
|---|---|
| Syscalls | `syscall-counts`, `slow-syscalls`, `errno-tracer`, `read-write` |
| Networking | `tcp-events`, `tcp-retransmits`, `udp-flows`, `ip-traffic` |
| Filesystem | `file-opens`, `vop-create`, `vop-unlink`, `slow-fs-ops` |
| Process | `proc-exec`, `proc-exit`, `proc-signals`, `zombie-watch` |
| Memory | `page-faults`, `swap-activity`, `vm-pressure` |
| Locks | `mutex-contention`, `rw-lock-contention` |
| Block I/O | `block-io`, `disk-latency`, `io-wait` |
| Scheduler | `sched-cpu-time`, `sched-wakeup-latency` |
| Misc | `kill`, `nanosleep`, `chmod`, `systop` (the dwatch parity baseline) |

### Application / USDT profiles (~15-20)

The Instruments framing is **primarily about profiling your own
application**, not the system. This is where dtlm goes beyond
"kernel observability" and becomes a real application profiler:

| Provider | Profiles |
|---|---|
| Generic USDT | `usdt-events` (parameterized: `--param provider=…`) — the "point at any USDT-instrumented process" tool |
| Discovery | (`dtlm probes --provider … --pid …`) |
| PostgreSQL | `postgres-query-time`, `postgres-deadlocks` |
| MySQL/MariaDB | `mysql-slow-queries` |
| ZFS | `zfs-arc-stats`, `zfs-zil-flushes` |
| libc | `malloc-tracer`, `realloc-watch` |
| libthr | `pthread-mutex-contention` |

A developer who has added USDT probes to their own application gets
immediate Instruments-style telemetry without writing a single line
of D — they pick the generic wrapper or one of the bundled
per-provider profiles and point dtlm at their process.

### Catalog growth

The bundled set is hand-authored. Adding a profile is a one-file
commit: drop a new `.d` file in `Profiles/` and ship. There is no
schema, no JSON wrapper, no metadata block to maintain.

The full ~296-profile catalog from FreeBSDKit's `DBlocks.Dwatch.*`
is shipped via a one-shot `Scripts/regen_catalog.swift` generator
in Phase 7 — one `.d` file per `Dwatch.*` function, installed by
the FreeBSD port into `/usr/local/share/dtlm/profiles/`. The
generated catalog layers underneath the hand-authored
Instruments-equivalent set; users see both in `dtlm list`.

---

## 7. Stack capture: first-class

`--with-stack` (kernel) and `--with-ustack` (user) plumb DTrace's
`stack()` and `ustack()` actions into every output format:

- **Text**: stack frames printed below the event line, indented
- **JSON**: `stack` and `ustack` fields containing arrays of frame
  strings
- **OTel**: `dtlm.stack` / `dtlm.ustack` attribute arrays on each
  `LogRecord`

This is what makes the OTel data actually useful. parca and pyroscope
built whole companies around continuous profiling — stacks tied to
metrics give you "where is time going" in addition to "how much is
happening." dtlm delivers that for FreeBSD: `dtlm watch cpu-profile
--with-ustack --duration 30s --format otel ...` is the FreeBSD
equivalent of running `parca-agent` on a Linux host.

For high-frequency stack capture, `--sample 1/N` reduces volume.

Stack symbolication uses libdtrace's resolver. Stripped binaries get
addresses; binaries with symbols get function names. dtlm doesn't
ship its own symbolication.

---

## 8. CLI surface

Four subcommands. One real run loop (`watch`). Three output formats.

```
dtlm list                                      # all bundled + system + user profiles
dtlm watch <name[+name…]|-f path>              # run one or more profiles in one libdtrace handle
  [--pid PID] [--execname NAME] [--uid UID] [--gid GID] [--jail JID]
  [--with-stack] [--with-ustack]
  [--duration SECONDS]
  [--sample 1/N]                               # sample 1 in N firings
  [--param key=value …]                        # placeholder substitution
  [--format text|json|otel]                    # default text
  [--endpoint URL]                             # required for --format otel
  [--auth-bearer TOKEN] [--auth-bearer-file PATH]   # OTLP auth
  [--insecure]                                 # allow plaintext OTLP for dev
  [--service NAME] [--instance ID]             # OTel resource attributes
  [--resource KEY=VALUE,...]                   # additional resource attributes
  [--traceparent HEX|--traceparent-from-env]   # join an existing W3C trace
  [--output PATH|-]                            # default stdout
dtlm generate <name[+name…]|-f path>           # print rendered .d source (with composition applied)
dtlm probes [--provider NAME] [--regex PATTERN] [--pid PID] [--json]
```

That's the entire CLI surface. No `snapshot`, `export`, `flame`,
`validate`, `dashboard`, `convert`, `daemon`, or `perf` subcommands.
The previous design had eight subcommands; this one has four.

### Sysadmin examples

```sh
# Live tail of TCP retransmits to terminal
dtlm watch tcp-retransmits --duration 60s

# Slow syscalls to JSONL for later jq analysis
dtlm watch slow-syscalls --format json > slow.jsonl

# CPU profile with user stacks, ship to OTel collector
dtlm watch cpu-profile --with-ustack --duration 60s \
     --format otel --endpoint http://collector:4318/v1/logs \
     --service kernel --instance host-01

# Continuous mutex contention monitoring as a daemon
dtlm watch mutex-contention --format otel \
     --endpoint http://collector:4318/v1/logs \
     --service kernel --instance host-01
```

### Developer examples

```sh
# Discover what's instrumented in a running process
dtlm probes --provider mywebapp --pid 1234 --json

# Live tail of postgres slow queries
dtlm watch postgres-query-time --pid 5123

# Ship application USDT events to OTel with stacks
dtlm watch usdt-events \
     --param provider=mywebapp --param probe=request_start \
     --pid 1234 --with-ustack --format otel \
     --endpoint http://collector:4318/v1/logs \
     --service mywebapp --instance api-1

# Application crash diagnostics: capture every libc malloc with stacks
dtlm watch malloc-tracer --pid 1234 --with-ustack \
     --format json > malloc-trace.jsonl

# KINST: trace one instruction inside vm_fault
dtlm watch kinst --param func=vm_fault --param offset=4 --duration 30s
```

---

## 9. Output: the Exporter framework + the three v1 exporters

Output is the part of dtlm most likely to grow over time. Today the
three formats users actually need are text, JSONL, and OTLP/HTTP+JSON.
Tomorrow somebody will want Prometheus exposition, or Loki push, or
S3 archive, or a vendor API. **The architecture has to make adding
the next exporter trivial — it must not require touching the run loop
or any of the existing exporters.** That seam is the `Exporter`
protocol.

### The Exporter framework

A Swift protocol every output format implements:

```swift
public protocol Exporter: Sendable {
    /// CLI name. e.g. "text", "jsonl", "otlp-http-json".
    static var formatName: String { get }

    /// Optional CLI flags this exporter accepts (--endpoint, --auth-bearer, ...).
    static var commandLineOptions: [ExporterOption] { get }

    /// Validate options and create the exporter, ready to receive events.
    init(options: ExporterOptionValues, resource: ResourceAttributes) throws

    /// Called once before the run loop starts.
    func start() async throws

    /// Called for every probe firing. Must return quickly (called from
    /// the libdtrace consume callback).
    func emit(event: ProbeEvent) async throws

    /// Called for every aggregation snapshot.
    func emit(snapshot: AggregationSnapshot) async throws

    /// Called periodically based on the exporter's flush interval.
    func flush() async throws

    /// Called on graceful shutdown. Must drain pending records before
    /// returning.
    func shutdown() async throws
}
```

Every exporter consumes the same typed event/snapshot model. The
core dtlm run loop never sees OTLP-specific or Loki-specific concepts;
it only knows about `ProbeEvent` and `AggregationSnapshot`.

The data model the framework hands to every exporter:

```swift
public struct ProbeEvent: Sendable {
    public let timestamp: Date            // walltimestamp, Unix epoch
    public let profileName: String        // which profile fired
    public let probeName: String          // syscall::kill:entry
    public let pid: Int32
    public let execname: String
    public let printfBody: String?        // rendered printf line if any
    public let fields: [String: AnyValue] // extracted probe args
    public let stack: [StackFrame]?       // kernel stack if --with-stack
    public let ustack: [StackFrame]?      // user stack if --with-ustack
}

public struct AggregationSnapshot: Sendable {
    public let timestamp: Date
    public let profileName: String
    public let aggregationName: String
    public let kind: AggregationKind      // count/sum/min/max/avg/quantize/lquantize/llquantize/stddev
    public let dataPoints: [DataPoint]    // one per tuple key
}

public struct ResourceAttributes: Sendable {
    public let serviceName: String        // mandatory in OTel mode
    public let serviceInstanceId: String?
    public let hostName: String           // auto from gethostname()
    public let osName: String             // "freebsd"
    public let osVersion: String          // auto from uname
    public let dtlmVersion: String        // build constant
    public let custom: [String: String]   // from --resource k=v,k=v
}
```

**What lives in the framework (shared by all exporters):**
- The data model above
- Resource attribute composition (auto-detect + CLI override)
- Sampling decision (`--sample 1/N`) — applied **before** the event
  reaches any exporter, so all exporters see the same sampled stream
- Run-loop integration: libdtrace consume callback → typed event →
  exporter
- Graceful shutdown coordination — waits for all exporters to finish
  draining

**What each exporter implements:**
- Wire format encoding
- Connection lifecycle (HTTP client, file descriptor, etc.)
- Batching policy (text streams, JSONL streams, OTLP batches)
- Retry policy (network exporters need it, file exporters don't)
- Endpoint configuration

**v1 ships three Exporter conformances**: `TextExporter`,
`JSONLExporter`, `OTLPHTTPJSONExporter`. Adding a fourth (Prometheus,
Loki, OTLP/protobuf, OTLP/gRPC, S3, vendor API) is one new file
implementing `Exporter` plus a one-line registration in the format
registry. **No core changes. No data-model changes. No CLI grammar
changes.**

This is the load-bearing architectural decision. It's why dtlm can
honestly claim to be "designed for outputs other than OTel in the
future" — the seam exists from day 1, even though only three exporters
ship in v1.

### `text` exporter (default)

Line-oriented stdout, like dwatch. Whatever the script's `printf`s
produce, dtlm prints. Aggregations are dumped at exit (or on every
`--duration`). Stack frames indent below event lines. Streams every
event immediately — no batching. Doesn't implement retry. ~150 LOC.

### `jsonl` exporter

One JSON object per probe firing. One JSON object per aggregation
snapshot. Stack arrays land in `stack` / `ustack` fields. Mechanical
mapping; no schema invention.

```jsonl
{"time":"2026-04-11T16:30:11.123Z","profile":"kill","pid":4123,"execname":"nginx","fields":{"signal":15,"target_pid":4567},"ustack":["main+0x42","libc.so.7`kill+0x12"]}
{"time":"2026-04-11T16:30:42.000Z","profile":"systop","aggregation":"@","kind":"count","rows":[{"key":["nginx","read"],"value":1247},{"key":["nginx","write"],"value":523}]}
```

Streams every record immediately. Doesn't implement retry. ~250 LOC.

### `otel` exporter (OTLP/HTTP+JSON)

POST to a configurable endpoint, batched with periodic flush, retried
with exponential backoff on collector failures, optionally over HTTPS
with bearer token authentication.

**Two OTel signals are produced (logs and metrics):**

| dtlm event | OTel signal | OTLP shape |
|---|---|---|
| `ProbeEvent` (probe firing) | **Logs** | `LogRecord` with `severity_text=INFO`, body = rendered printf line, attributes = pid + execname + per-arg fields + `dtlm.profile`, plus `dtlm.stack` / `dtlm.ustack` arrays if captured |
| `AggregationSnapshot` with `kind=count` | **Metrics** | `Sum` (monotonic, cumulative) named `dtlm.<profile>.<aggregation_name>`, key columns → data-point attributes |
| `AggregationSnapshot` with `kind=sum` | **Metrics** | `Sum` (non-monotonic) |
| `AggregationSnapshot` with `kind=min`/`max`/`avg` | **Metrics** | `Gauge` |
| `AggregationSnapshot` with `kind=quantize` | **Metrics** | `ExponentialHistogram` (scale 0, base 2 — matches DTrace's power-of-two buckets exactly) |
| `AggregationSnapshot` with `kind=lquantize` | **Metrics** | `Histogram` with explicit bucket bounds |
| `AggregationSnapshot` with `kind=llquantize` | **Metrics** | `ExponentialHistogram` |
| `AggregationSnapshot` with `kind=stddev` | **Metrics** | `Summary` with the rolling mean and the dispersion as a single-quantile data point |

**Trace spans (the third OTel signal) are NOT produced in v1.** Span
pairing requires per-profile metadata declaring which clauses pair
into entry/return spans, and the sidecar file format that pairing
needs reintroduces the structured-profile-metadata complexity that
the rest of dtlm goes out of its way to avoid. v1 ships logs and
metrics (with stacks) which is 95% of what users want. Spans become
a single-feature post-v1 addition once there's user demand to design
the sidecar format against.

**Trace context propagation** — `--traceparent HEX` or
`--traceparent-from-env` (reads `TRACEPARENT`) is plumbed through to
**log records** as the OTel `trace_id` / `span_id` fields on the
`LogRecord`, so dtlm-emitted logs join an existing distributed trace
in collectors that correlate logs with traces by ID. Spans are
deferred but the trace correlation works for logs in v1.

**Authentication** — `--auth-bearer TOKEN` or `--auth-bearer-file
PATH` adds an `Authorization: Bearer …` header to every OTLP POST.
HTTPS endpoints use the system trust store via libcurl/Foundation's
`URLSession`. Plaintext `http://` endpoints require `--insecure` to
prevent accidental token leakage.

**Resource attributes** — auto-detected (`host.name`,
`os.name=freebsd`, `os.version` from `uname`, `dtlm.version`) and
overrideable via `--service` (mandatory in OTel mode — dtlm refuses to
start without it), `--instance`, `--resource key=value,...`.

**Backoff and reliability** — OTLP POST failures retry with
exponential backoff (1s, 2s, 4s, …, capped at 30s). After 5 minutes
of continuous failures, dtlm logs a warning to stderr but **keeps
collecting locally** — when the collector recovers, no new kernel
data is lost beyond the in-memory batch.

**Wire format** — OTLP 1.10. JSON encoding lowerCamelCase. 64-bit
ints as decimal strings. Trace IDs as hex strings (not base64).
Verified against the official `opentelemetry-proto` examples.

~900 LOC.

---

## 10. Production deployment

dtlm is designed to run as a service, not just a one-shot CLI.

- **Graceful shutdown**: SIGTERM/SIGINT triggers a clean stop —
  drain the exporter's send queue, flush pending records, call
  `dtrace_stop()`, exit cleanly. Required for `rc.d` and systemd-style
  supervision.
- **`rc.d/dtlm` wrapper**: a ~30-line shell script that runs
  `dtlm watch` under `daemon(8)` with logging, PID file, and SIGTERM
  forwarding. Drop into `/usr/local/etc/rc.d/dtlm`, configure via
  `/etc/rc.conf`:

  ```
  dtlm_enable="YES"
  dtlm_profile="time-profiler"
  dtlm_endpoint="https://collector.example.com:4318/v1/logs"
  dtlm_auth_bearer_file="/usr/local/etc/dtlm/token"
  dtlm_service="prod"
  dtlm_instance="host-01"
  dtlm_flags="--with-ustack --sample 1/4"
  ```

  For deployments that want kernel + app telemetry correlated, run
  two `dtlm` processes side-by-side with different `--service` tags
  pointing at the same collector. The collector correlates them by
  `host.name`/`instance.id` automatically. Multi-profile composition
  in a single process is a post-v1 add — it requires collision
  policy work that's better deferred until there's a real
  deployment that needs it.
- **Resource attribution**: required for the OTel data to be useful
  in Grafana / Tempo / etc. dtlm auto-populates `host.name`,
  `os.name`, `os.version`, `dtlm.version` and requires `--service` in
  OTel mode (refuses to start without it). Without resource
  attributes, OTel data shows up in collectors as unattributed garbage
  and the project's value evaporates.
- **Sampling**: `--sample 1/N` reduces volume for high-frequency
  probes. dtlm maintains a per-probe counter in the framework layer
  and decides BEFORE the event reaches any exporter, so all formats
  see the same sampled stream. Implemented in dtlm, not in D, so the
  sampling decision is uniform regardless of which exporter is active.
- **Backoff on collector failures**: OTLP POST failures retry with
  exponential backoff (1s, 2s, 4s, …, cap at 30s). After 5 minutes of
  continuous failures, dtlm logs a warning to stderr but **keeps
  running and keeps collecting** — when the collector recovers, no
  new kernel data is lost beyond the in-memory batch.
- **HTTPS + auth for OTLP**: `--auth-bearer TOKEN` /
  `--auth-bearer-file PATH` for bearer-token authentication. HTTPS
  endpoints use the system trust store. Plaintext `http://` endpoints
  require `--insecure` to prevent accidental token leakage.
- **Trace context propagation**: `--traceparent HEX` /
  `--traceparent-from-env` reads a W3C `traceparent` header and sets
  it as the parent on every emitted OTel span. Lets a developer join
  dtlm-produced spans into an existing distributed trace.

These seven things are what turn dtlm from "a tool you run by hand"
into "infrastructure you can deploy." They're not nice-to-haves;
they're required for the OTel pitch to work in any production
environment.

---

## 11. KINST — kernel instruction tracing

Kernel-instruction tracing on **amd64, aarch64, riscv** (the
`man dtrace_kinst` manpage still says "amd64 only"; that's stale,
verified against `freebsd-src/stable/15/sys/cddl/dev/kinst/`).

dtlm ships one parameterized profile, `kinst.d`:

```d
/* Trace one instruction inside a kernel function via kinst */
kinst::${func}:${offset}
/* @dtlm-predicate */
{
    printf("%s[%d]: ${func}+${offset}", execname, pid);
}
```

Usage:

```sh
dtlm watch kinst --param func=vm_fault --param offset=4 --duration 30s
```

The `${param}` substitution is plain text replace at load time. Each
placeholder must have a matching `--param key=value` or dtlm refuses
to load the profile. ~30 LOC of substitution + the .d file.

The unique value here is largely **discovery and correct
documentation**. Most FreeBSD users don't know KINST exists at all,
and the in-tree man page is wrong about architecture support. dtlm
shipping a `kinst` profile in `dtlm list` puts KINST on people's
radar.

---

## 12. The DBlocks question, answered

**dtlm does not depend on DBlocks.** DBlocks is FreeBSDKit's typed
Swift DSL for *constructing* DTrace scripts in code. dtlm doesn't
construct scripts — it loads `.d` files from disk and hands them to
libdtrace verbatim. The runtime path uses `DTraceCore` (the
lower-level libdtrace bindings in FreeBSDKit) directly.

**What dtlm uses from FreeBSDKit:**
- `DTraceCore`: open handle, compile program from string, go,
  consume callback, aggregation snapshot, walk, stop, close.

**What dtlm does NOT use from FreeBSDKit:**
- DBlocks's typed result-builder DSL
- DBlocks's Codable JSON schema
- DBlocks's `Dwatch.*` profile catalog (we hand-author our own .d
  files)
- DBlocks's typed `ProviderArgs`, `Translator`, `DExpr`
- DBlocks's `validate()` and `lint()`

If a future version of dtlm wants to construct scripts programmatically
or expose DBlocks's typed catalog, the dependency can be added then.
Today, dtlm is intentionally minimal.

---

## 13. Architecture

```
        ┌──────────────────────┐
        │  .d profile file     │
        │  (bundled / system / │
        │   user)              │
        └──────────┬───────────┘
                   │  load text
                   │  substitute ${param}
                   │  inject filter at @dtlm-predicate marker
                   │  inject --duration tick-Ns
                   ▼
        ┌──────────────────────┐
        │  DTraceCore          │
        │  open / compile /    │
        │  go / consume /      │
        │  aggregate / stop    │
        └──────────┬───────────┘
                   │ raw events, aggregations, stacks
                   ▼
        ┌──────────────────────┐
        │  framework layer     │
        │  - sampling (1/N)    │
        │  - resource attrs    │
        │  - traceparent prop  │
        │  - typed event model │
        └──────────┬───────────┘
                   │ ProbeEvent / AggregationSnapshot
                   ▼
        ┌──────────────────────┐
        │  Exporter (one of)   │
        │  ├─ TextExporter     │
        │  ├─ JSONLExporter    │
        │  └─ OTLPHTTPJSONExp. │
        │  (post-v1: more)     │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │  stdout / file /     │
        │  OTLP collector /    │
        │  (post-v1: anywhere) │
        └──────────────────────┘
```

The **framework layer** is the seam. It owns sampling, resource
attribution, and trace context propagation — the things that have
to behave consistently regardless of which exporter is active. The
**exporter** owns wire encoding, batching, and retry — the things
that are inherently format-specific.

Total runtime path: **~2150 LOC of Swift**, plus ~46 hand-authored
`.d` files, plus a one-shot `Scripts/regen_catalog.swift` that ships
~296 generated `.d` files via the FreeBSD port. One Swift binary.
One library dependency on FreeBSDKit (`DTraceCore` only — no
DBlocks). One external Swift package (`swift-argument-parser`).
HTTPS uses Foundation's `URLSession` and the system trust store.

---

## 14. Phase plan

| Phase | Scope | LOC |
|---|---|---|
| **1** | CLI scaffold (`list`/`watch`/`generate`/`probes`), `.d` profile loader (bundled SwiftPM resources + `/usr/local/share/dtlm/profiles/` + `~/.dtlm/profiles/`), filter injection via `@dtlm-predicate` marker, `${param}` substitution, `--duration`, stack capture flags plumbed to text output, ~9 Instruments-equivalent umbrella profiles + ~12 supporting per-event system profiles (~21 total), KINST profile, **`Exporter` protocol designed and `TextExporter` shipping as the first conformance** | ~700 |
| **2** | **`JSONLExporter`** (Exporter conformance) — JSONL events + aggregation snapshots, stack arrays in records, framework-level sampling (`--sample 1/N`) | ~400 |
| **3** | **`OTLPHTTPJSONExporter`** — `LogRecord`s from probe events, **typed metric mapping** (`count`→`Sum` monotonic, `quantize`→`ExponentialHistogram`, `lquantize`→`Histogram`, `min/max/avg`→`Gauge`, `stddev`→`Summary`), stack attribute arrays, periodic flush, exponential backoff on collector failures, **resource attribution** (`--service` mandatory + `--instance` + `--resource` + auto host.name/os.name/dtlm.version), **HTTPS + bearer-token auth** (`--auth-bearer` / `--auth-bearer-file` / `--insecure`), **W3C `traceparent` propagation** plumbed to log records (`--traceparent` / `--traceparent-from-env`), **graceful shutdown** with pending-record flush | ~900 |
| **4** | **~25 more bundled system profiles** (vminfo, lockstat, vop, expanded networking, sched) — `.d` files only, no Swift | ~0 LOC |
| **5** | **~15-20 application/USDT profiles** (postgres, mysql, zfs, libc, libthr, generic USDT wrapper) + USDT discovery improvements in `dtlm probes` | ~150 LOC |
| **6** | **`rc.d/dtlm`** wrapper script with sample `rc.conf` knobs | ~30 LOC |
| **7** | **`Scripts/regen_catalog.swift`** — one-shot Swift script that walks `DBlocks.Dwatch.*` and emits the full ~296-profile catalog as `.d` files into a target directory; FreeBSD port packaging that installs them into `/usr/local/share/dtlm/profiles/`. Note: this script is the **only** part of the dtlm repo that depends on `DBlocks`; the dtlm runtime binary still depends only on `DTraceCore`. | ~200 LOC |

**v1 = end of Phase 7.** ~2380 LOC of Swift + ~46 hand-authored `.d`
files + ~296 generated `.d` files shipped via the FreeBSD port.

**Earliest usable version**: end of Phase 3. That's a working OTel
exporter with **logs + typed metrics + stacks**, auth, traceparent
log correlation, and the Instruments-equivalent bundled set — already
enough to deploy in a real production environment with HTTPS against
a real OTel collector. Phases 4-7 ship continuously thereafter.

**Deferred to post-v1** (each becomes a single-feature addition once
v1 ships and users actually ask for it):
- **Span pairing** for the OTel traces signal (~300 LOC + sidecar
  metadata format design)
- **Multi-profile composition** in one libdtrace handle (~400 LOC
  + collision policy). Workaround: run two `dtlm` processes against
  the same collector, the collector correlates by `host.name` /
  `instance.id`.
- **Additional Exporter conformances**: Prometheus, OTLP-protobuf,
  Loki, S3, vendor APIs — all single-file additions to the framework.

---

## 15. What we're explicitly NOT shipping (in v1)

| Removed | Why |
|---|---|
| **Span pairing for OTel traces** | The third OTel signal needs sidecar metadata declaring entry/return clause pairing — reintroduces structured profile metadata complexity. ~300 LOC. Defer until users actually ask. v1 ships logs + metrics, which is 95% of what users want. |
| **Multi-profile composition** (`dtlm watch a+b+c`) | ~400 LOC of collision policy. Workaround: run two `dtlm` processes against the same collector with different `--service` tags. The collector correlates them automatically. |
| JSON profile format (the `.json` wrapper around DBlocks Codable) | `.d` files are simpler |
| Sidecar `.dtlm.json` metadata files | not needed without span pairing |
| DBlocks runtime dependency | `DTraceCore` is enough; only `Scripts/regen_catalog.swift` touches DBlocks, and that runs once outside the binary |
| `dtlm snapshot` / `export` / `flame` subcommands | folded into `watch` + format flags |
| `dtlm validate` subcommand | `dtrace -e -s foo.d` already does this |
| Inline `--probe` / `--print` mode | `.d` files cover this |
| `--format prometheus` (separate exporter) | OTel collector already covers Prometheus via the `prometheus` exporter; adding a `PrometheusExporter` is a post-v1 file drop into the framework if anyone asks |
| `--format otlp-protobuf` / `--format otlp-grpc` | OTLP/HTTP+JSON has the same reach with zero extra deps; protobuf is a post-v1 Exporter conformance |
| SVG flame renderer | pipe to `flamegraph.pl` |
| Capacity guards (`--max-events` / `--max-bytes`) | `--duration` + in-script `tick-Ns` are enough |
| Templated profiles beyond `${param}` | sufficient for KINST and USDT |
| `dtlm dashboard` (auto-Grafana-dashboards) | downstream tool's job |
| Loki / Datadog / S3 / vendor exporters | post-v1 — the `Exporter` framework makes these one-file additions; we ship none of them in v1 |
| Performance metadata block (`category` smart defaults) | category alone is enough; no separate block |

---

## 16. Open questions

1. **Stack symbolication for stripped binaries.** libdtrace's resolver
   is what we have. Some binaries will produce raw addresses. Trust
   libdtrace for v1; revisit if it turns out to be a real problem in
   the field.
2. **OTel resource attribute conventions.** The OTel semantic
   conventions evolve. We pin `host.name`, `os.name`, `os.version`,
   `service.name`, `service.instance.id`, `dtlm.version`. If the
   semantic conventions move, we follow.
3. **`dtlm` namespace renaming in DBlocks.** `DBlocks.Dwatch.*`
   predates dtlm. Renaming would require a future FreeBSDKit major
   version. dtlm doesn't expose the namespace, so it doesn't matter
   for v1.
4. **Post-v1 priority ordering.** Once v1 ships, several additions
   become obvious based on user demand. Likely priority order:
   (1) **span pairing** for the OTel traces signal (sidecar `.dtlm.json`
   format design + ~300 LOC), (2) **multi-profile composition**
   (collision policy + ~400 LOC), (3) `OTLPHTTPProtobufExporter` for
   collectors that don't accept JSON, (4) `PrometheusExporter` for
   direct Prometheus scrape integration, (5) `S3ArchiveExporter` for
   forensic logging at rest, (6) `LokiExporter` for direct Loki push
   without a collector hop. None of these block v1 shipping; all of
   them become additive features once there's user demand to design
   them against.

---

## 17. TL;DR

| | |
|---|---|
| **What is it?** | **Apple Instruments for FreeBSD, with OpenTelemetry output.** A catalog of DTrace-backed profiling templates equivalent to Instruments' Time Profiler / System Trace / File Activity / Network / Allocations / Thread States / Lock Contention — for both kernel events and your own USDT-instrumented applications — that ships its data as text, JSONL, or OTLP/HTTP+JSON to your existing OpenTelemetry collector with stack traces attached. |
| **What's it called?** | `dtlm` |
| **Who's it for?** | (1) Anyone who has used Apple's Instruments and wants the same templates on FreeBSD. (2) Sysadmins who want kernel telemetry in their existing OTel pipeline. (3) Developers who instrument their apps with USDT and want logs + typed metrics + stacks shipped to OTel without writing a separate observability agent. |
| **What does it do?** | Loads `.d` files, runs them via libdtrace, captures events + aggregation snapshots + stacks, hands them to a typed event model, and ships them through one of three v1 exporters (text / JSONL / OTLP/HTTP+JSON). |
| **What's the architecture seam for the future?** | A pluggable `Exporter` protocol. Adding span pairing, multi-profile composition, Prometheus / Loki / OTLP-protobuf / S3 / vendor exporters post-v1 is additive — the core never changes. |
| **What format are profiles in?** | `.d` files. The first comment is the description. An optional `/* @dtlm-predicate */` marker is where dtlm injects CLI filter predicates. **No JSON profile wrapper, no Codable schema, no sidecar metadata.** |
| **What's bundled?** | ~46 hand-authored `.d` profiles framed as Instruments equivalents — ~9 umbrella templates (`time-profiler`, `system-trace`, `file-activity`, `network-activity`, `allocations`, `thread-states`, `lock-contention`, `system-calls`, `process-activity`) plus ~12 supporting per-event system profiles plus ~15-20 application/USDT profiles plus the parameterized `kinst` profile. The FreeBSD port additionally installs ~296 generated `.d` files from the `Scripts/regen_catalog.swift` walk of `DBlocks.Dwatch.*`. |
| **What does it depend on?** | `DTraceCore` from FreeBSDKit (the libdtrace bindings — no DBlocks at runtime). `swift-argument-parser`. Foundation (URLSession). Glibc. The catalog generator script depends on DBlocks but it runs once, outside the binary. |
| **How big is it?** | **~2380 LOC of Swift** + ~46 hand-authored `.d` files + ~296 generated `.d` files (post-Phase-7). v1 = end of Phase 7. |
| **What's the killer feature for sysadmins?** | OTLP/HTTP+JSON push of kernel telemetry (events + typed metrics + stacks) over HTTPS with bearer auth — nothing else on FreeBSD does this. |
| **Killer feature for developers?** | Instruments-equivalent templates + USDT discovery + bundled USDT profiles + generic USDT wrapper + stack capture + W3C `traceparent` log correlation → `pkg install dtlm`, point at your process, immediately get the Instruments-shaped telemetry you're used to from macOS, in your OTel pipeline. |
| **Earliest usable version?** | End of Phase 3. Working OTel exporter with logs + typed metrics + stacks, auth, traceparent log correlation, and the Instruments-equivalent bundled set. Already deployable in production. |
| **What's NOT in v1?** | Span pairing (third OTel signal), multi-profile composition, Prometheus exporter, OTLP/protobuf, OTLP/gRPC, Loki / Datadog / S3 exporters, JSON profile format, SVG flame renderer, capacity guards. All deferable, all additive once v1 ships. |
| **License?** | BSD-2-Clause. |
