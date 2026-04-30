# ObservableBSD

**Convert FreeBSD's instrumentation surface to OpenTelemetry telemetry.**

ObservableBSD bridges FreeBSD-native instrumentation — DTrace probes,
hardware-trace frameworks, kernel counters — into the modern
observability stack via OpenTelemetry.  FreeBSD has rich instrumentation
built into the kernel; this project connects it to Grafana, Jaeger,
Loki, Prometheus, and any OTel-compatible backend.

## Scope

| Tool | Domain | Status |
|------|--------|--------|
| [`bsdinstruments`](#bsdinstruments) | DTrace-based profiling — the FreeBSD equivalent of Apple Instruments | Shipped (v0.1.0) |
| [`hwtlm`](#hwtlm) | Hardware telemetry — CPU power (Intel RAPL), temperatures, frequencies, GPU state | Shipped (v0.1.0) |
| [`bsdtrace`](#bsdtrace) | Hardware-assisted execution tracing — understand what your software does | In progress |

All tools emit OpenTelemetry-native output so their data flows into the
same collectors, dashboards, and alerting pipelines.

---

## bsdinstruments

**Apple Instruments for FreeBSD, with OpenTelemetry output.**

`bsdinstruments` bundles 171 DTrace profiling templates covering the equivalent
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
- Drop counter attribute (`bsdinstruments.drops`) on data loss
- Typed metrics from DTrace aggregations (count/sum -> Sum, min/max/avg -> Gauge, quantize -> Histogram)

### Profile catalog (171 profiles)

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
.build/debug/bsdinstruments list

# Watch kill(2) syscalls system-wide
sudo .build/debug/bsdinstruments watch kill

# Filter by process, run for 60 seconds
sudo .build/debug/bsdinstruments watch open --execname nginx --duration 60

# JSONL output, pipe to jq
sudo .build/debug/bsdinstruments watch tcp-connect --format json | jq .

# Send to an OpenTelemetry collector
sudo .build/debug/bsdinstruments watch syscall-counts --format otel --duration 10

# Custom endpoint
sudo .build/debug/bsdinstruments watch sched-on-cpu --format otel --endpoint http://collector:4318 --duration 5

# Trace malloc in a specific process
sudo .build/debug/bsdinstruments watch malloc-trace --param pid=1234

# Trace PostgreSQL queries
sudo .build/debug/bsdinstruments watch postgresql-queries --param pid=$(pgrep postgres)

# Measure time in a kernel function
sudo .build/debug/bsdinstruments watch kfunc-time --param func=tcp_output --duration 10

# Trace a user-space function with stacks
sudo .build/debug/bsdinstruments watch func-trace --param pid=5678 --param func=SSL_read --with-ustack

# Discover USDT probes in a running process
sudo .build/debug/bsdinstruments watch usdt-list --param pid=1234 --duration 1

# Run an arbitrary .d file
sudo .build/debug/bsdinstruments watch -f /path/to/myscript.d

# Tune DTrace buffers for high-rate profiles
sudo .build/debug/bsdinstruments watch sched-on-cpu --format otel --bufsize 64m --switchrate 10ms --duration 5

# Print rendered D source (no root needed)
.build/debug/bsdinstruments generate kill --pid 1234

# List available DTrace probes
sudo .build/debug/bsdinstruments probes --provider tcp
```

### Custom profiles

Drop a `.d` file into `~/.bsdinstruments/profiles/` and bsdinstruments picks it up automatically:

```sh
mkdir -p ~/.bsdinstruments/profiles

cat > ~/.bsdinstruments/profiles/my-trace.d << 'EOF'
/*
 * Count syscalls by name for a specific process
 */
syscall:::entry
/* @bsdinstruments-predicate */
{
    @[probefunc] = count();
}

dtrace:::END
{
    printa("%-30s %@d\n", @);
}
EOF

# It shows up in the catalog
bsdinstruments list | grep my-trace

# Run it with filters
sudo bsdinstruments watch my-trace --execname nginx --duration 30 --format otel
```

**Profile markers:**
- `/* @bsdinstruments-predicate */` — replaced with `--pid`/`--execname`/`--where` filters
- `/* @bsdinstruments-predicate-and */` — appended to an existing predicate
- `/* @bsdinstruments-stack */` / `/* @bsdinstruments-ustack */` — replaced with `stack()`/`ustack()` when `--with-stack`/`--with-ustack` is set
- `${name}` — substituted from `--param name=value`

**Profile sources** (higher priority shadows lower):
1. `~/.bsdinstruments/profiles/` (user)
2. `/usr/local/share/bsdinstruments/profiles/` (system)
3. Bundled in the binary

### DTrace buffer tuning

| Flag | Default | Effect |
|------|---------|--------|
| `--bufsize` | 4m (text), 16m (json/otel) | Per-CPU trace buffer size |
| `--switchrate` | 50ms | Buffer drain cadence |

For extreme probe rates (`sched-on-cpu` on many CPUs), increase buffers:
```sh
sudo bsdinstruments watch sched-on-cpu --format otel --bufsize 64m --switchrate 10ms
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

## bsdtrace

**Understand what your software does — hardware-assisted execution tracing for FreeBSD.**

`bsdtrace` uses Intel Processor Trace (PT) via FreeBSD's HWT framework
to capture every branch a program takes, then decodes the trace into
symbolized control-flow events: function calls, returns, jumps, and
syscalls.  Traces are saved for offline analysis — capture once,
analyze as many times as you need.

### Subcommands

| Command | Purpose |
|---------|---------|
| `bsdtrace exec` | Run a command under tracing |
| `bsdtrace trace` | Attach to a running process |
| `bsdtrace list` | Show HWT availability and backend capabilities |
| `bsdtrace decode` | Offline re-decode a saved `.pt` + `.meta` file pair |

### Quick start

```sh
# Trace a command (saves .pt + .meta files for offline analysis)
doas bsdtrace exec -t 5 -- /bin/sleep 1

# Attach to a running process for 10 seconds
doas bsdtrace trace -d 10 $(pidof nginx)

# Trace all threads simultaneously
doas bsdtrace trace -T all -d 5 $(pidof myserver)

# Trace with timing data (MTC + cycle-accurate packets)
doas bsdtrace exec -C -P 3 -t 5 -- ./mybench

# Call tree view
doas bsdtrace exec -f tree -t 5 -- ./myapp

# Per-function profile
doas bsdtrace exec -f profile -t 5 -- ./myapp

# Check HWT/PT availability
bsdtrace list
```

### Output

```
  CALL      ld-elf.so.1:dlopen+0x1a
  RETURN    ld-elf.so.1:dlclose+0x42
  CALL      libc.so.7:exit
  SYSCALL   write (libsys.so.7:__sys_write)
  CJMP      libc.so.7:nanosleep+0x8
375467 instructions, 14240 calls, 3520 returns, 8192 branches, 4 syscalls
```

Each trace produces two files:
- `bsdtrace-<pid>.pt` — raw Intel PT data (replayable)
- `bsdtrace-<pid>.meta` — binary mapping metadata (JSONL)

With `-T all`, additional per-thread files are saved:
- `bsdtrace-<pid>-tid<N>.pt` — per-thread PT data
- `bsdtrace-<pid>-tid<N>.meta` — per-thread mapping metadata for offline replay

### Options

| Flag | Commands | Description |
|------|----------|-------------|
| `-f format` | all | Output format: text (default), json, profile, tree, or collapsed |
| `-d seconds` | exec, trace | Trace duration (`-t` also accepted; exec default: 30) |
| `-s size` | exec, trace | PT buffer size, e.g. 8m, 64m (default: 64m) |
| `-o file` | exec, trace | Output path for .pt file |
| `-r range` | exec, trace | IP filter: `0xstart:0xend` or `function_name` (up to 2); prefix with `stop:` for TraceStop |
| `-T tid` | exec, trace | Thread index (default: 0), comma list (`0,1,3`), or `all` |
| `-P freq` | exec, trace | PSB sync frequency 0-15 (lower = more sync points, 0 = default) |
| `-C` | exec, trace | Enable timing packets (MTC + cycle-accurate) |
| `-M freq` | exec, trace | Explicit MTC frequency 1-15 |
| `-Y thresh` | exec, trace | Explicit CYC threshold 1-15 |
| `-W` | exec, trace | Enable PTWRITE trace markers |
| `-K` | exec, trace | Include OS/kernel-mode tracing |
| `-m count` | exec, trace | Stop after N HWT records |
| `-b backend` | exec, trace | HWT backend (default: auto-detect) |
| `-A` | exec | Disable ASLR for the child process |
| `-n` | exec, trace | Dry run — validate setup without tracing |
| `-p` | exec, trace | Pause target on mmap/exec events |
| `-p pid` | list | Show threads for a process |
| `-h` | all | Per-command help |

### Output formats

| Format | Flag | Description |
|--------|------|-------------|
| Text | `-f text` (default) | Symbolized control-flow events (CALL, RETURN, CJMP, SYSCALL) |
| JSON | `-f json` | Line-oriented JSON. Live tracing emits HWT records (`kind`) followed by decoded instruction events (`insn`). |
| Profile | `-f profile` | Per-function call/return/branch counts with TSC timing when `-C` is used |
| Tree | `-f tree` | Indented call tree with counts and TSC timing |
| Collapsed | `-f collapsed` | Folded stacks for [flamegraph.pl](https://github.com/brendangregg/FlameGraph) / Speedscope |

Typical decoded instruction JSON includes fields such as `insn`, `ip`,
`sym`, `off`, `bin`, `tid`, and `tsc` when timing data is available.

### PTWRITE helper

The source tree includes [`Sources/bsdtrace/bsdtrace_ptwrite.h`](Sources/bsdtrace/bsdtrace_ptwrite.h),
a small x86_64 helper for emitting PTWRITE markers from traced code:

```c
#include "bsdtrace_ptwrite.h"

bsdtrace_ptwrite(0x123456789abcdef0ULL);
bsdtrace_ptwrite32(0x89abcdefU);
```

Use it only from code you know will run under `bsdtrace -W`.  The
instruction will fault if PTWRITE is not supported by the CPU or if the
current process is not being traced with PTWRITE enabled.

### Using bsdtrace with other tools

bsdtrace produces trace data.  Use standard tools for analysis it
doesn't cover:

**Binary inspection** — use `readelf`, `nm`, or `objdump` to examine
ELF layout, symbol tables, and disassembly before tracing:
```sh
readelf -lS /usr/local/bin/myapp    # segments and sections
nm -C /usr/local/bin/myapp          # symbols (with C++ demangling)
objdump -d /usr/local/bin/myapp     # disassembly
```

**Source-level symbolication** — pipe bsdtrace JSON output through
`llvm-symbolizer` to resolve IPs to source file and line number.
This also handles split debug info (`.gnu_debuglink`,
`/usr/lib/debug/`) automatically:
```sh
bsdtrace decode -f json trace.pt | \
  jq -r 'select(.sym) | .ip' | \
  llvm-symbolizer --obj=./myapp
```

**Flame graphs** — pipe folded stacks to flamegraph.pl or Speedscope:
```sh
bsdtrace decode -f collapsed trace.pt | flamegraph.pl > trace.svg
```

**Filtering** — use `jq` on JSON output instead of built-in filters:
```sh
# Only CALL events
bsdtrace decode -f json trace.pt | jq 'select(.insn == "CALL")'

# Only events in a specific function
bsdtrace decode -f json trace.pt | jq 'select(.sym == "malloc")'

# Count calls per function
bsdtrace decode -f json trace.pt | \
  jq -r 'select(.insn == "CALL") | .sym // .ip' | sort | uniq -c | sort -rn
```

### Kernel setup

Requires a kernel with `options HWT_HOOKS` and two kernel modules:

```sh
doas kldload hwt
doas kldload pt
```

The custom kernel config lives at `KernelConf/GENERIC-HWT`.

A convenience script rebuilds and hot-reloads the patched modules:

```sh
doas sh reload-hwt.sh
```

#### Kernel patches (required)

The stock `hwt.ko` and `pt.ko` modules need local fixes for stable
tracing.  The project keeps them in `KernelConf/`, and the normal way to
apply them is the idempotent helper script:

```sh
# Apply remaining patches (TAILQ_FIRST fix + timing) and rebuild
doas sh KernelConf/apply-remaining-patches.sh
```

Or apply from a clean `/usr/src` tree:

```sh
doas patch -p1 < KernelConf/hwt-race-fixes.patch
doas sh KernelConf/apply-pmi-fix.sh
doas sh KernelConf/pt-stop-impl.sh
doas sh KernelConf/apply-remaining-patches.sh
doas sh reload-hwt.sh
```

Today those patches cover:

- teardown and race fixes in `hwt_owner.c` and `pt.c`
- reliable stop/snapshot support for `HWT_IOC_STOP`
- correct PT buffer position tracking from XSAVE state
- per-thread tracing fixes for `-T all` and explicit thread lists
- timing control support for `-P`, `-C`, `-M`, and `-Y`
- PTWRITE / FUPONPTW support for `-W`
- TraceStop / per-range filter modes for `stop:...`
- overflow and wrap reporting improvements
- hooks and metadata fixes needed for offline replay

#### Crash dump inspection

If HWT or bsdtrace testing panics the kernel:
```sh
doas cat /var/crash/info.last
doas cat /var/crash/core.txt.last
```

### How it works

1. **Collection**: HWT allocates a PT context for the target process.
   The CPU's PT hardware records every branch into a circular buffer.
   HWT kernel hooks generate metadata records (EXEC, MMAP, MUNMAP)
   as the process loads binaries.
2. **Snapshot**: Before teardown, the PT buffer is mmap'd and saved
   to disk alongside the metadata records.
3. **Decode**: The raw PT data is fed to libipt's instruction decoder.
   ELF program headers (parsed via libelf/gelf) build a binary image
   so libipt can resolve compressed IPs.  Attach mode seeds the
   target's current executable mappings up front, then resets that
   image state on a later `exec` so offline decode follows the same
   address space transitions as the live trace.
4. **Symbolize**: ELF symbol tables (`.dynsym` / `.symtab`) provide
   function names.  A sorted symbol table with ASLR-adjusted addresses
   maps IPs to `binary:function+offset`.

---

## OTel Configuration

All tools respect standard OpenTelemetry environment variables:

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
sudo bsdinstruments watch syscall-counts --format otel --duration 60
```

---

## Requirements

- FreeBSD 15.0 or later
- Swift 6.3 or later
- DTrace enabled in the running kernel (default on `GENERIC`)
- Root for bsdinstruments probes and hwtlm RAPL/cpuctl access
- For bsdtrace: kernel with `options HWT_HOOKS` + patched hwt/pt modules
- For OTLP output: an OpenTelemetry collector (e.g. `otelcol-contrib`)

## Building

```sh
swift build
```

Builds the main executables into `.build/debug/`:
`bsdinstruments`, `hwtlm`, and `bsdtrace`.

The `bsdtrace` integration script compiles its helper targets directly
with `cc` during `test-bsdtrace.sh` rather than through SwiftPM.

## Testing

```sh
# Unit + structural tests (no root needed, 152 tests)
swift test

# Full integration sweep including libdtrace compilation of
# every bundled profile (requires root)
sudo swift test

# After root tests, restore .build ownership
sudo chown -R $(id -un):$(id -gn) .build

# bsdtrace hardware integration tests (requires root + HWT modules)
doas sh test-bsdtrace.sh
```

The `bsdtrace` integration suite (`test-bsdtrace.sh`) has two tiers:
- **No-root**: CLI/help surface, list output, header compile checks, decode error handling
- **Root**: exec, trace, offline replay, threads, timing, PTWRITE, overflow, and TraceStop on real PT hardware

## Dependencies

- [FreeBSDKit](https://github.com/SwiftBSD/FreeBSDKit) >= 0.2.6
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) >= 1.2.0
- libz (system, for gzip compression)
- libipt (system, for Intel PT decoding)
- libelf (system, for ELF parsing)
- cpuctl(4) kernel module (for hwtlm RAPL access)
- hwt(4) + pt(4) kernel modules (for bsdtrace)

## License

BSD-2-Clause.
