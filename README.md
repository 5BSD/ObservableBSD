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

# Check HWT/PT availability
bsdtrace list
```

### Output

```
  CALL      ld-elf.so.1:dlopen+0x1a
  RETURN    ld-elf.so.1:dlclose+0x42
  CALL      libc.so.7:exit
  SYSCALL   libsys.so.7+0x1234
  CJMP      libc.so.7:nanosleep+0x8
375467 instructions, 14240 calls, 3520 returns, 4 syscalls
```

Each trace produces two files:
- `bsdtrace-<pid>.pt` — raw Intel PT data (replayable)
- `bsdtrace-<pid>.meta` — binary mapping metadata (JSONL)

### Options

| Flag | Commands | Description |
|------|----------|-------------|
| `-f text\|json` | all | Output format (default: text) |
| `-s bufsize` | exec, trace | PT buffer size (default: 64m) |
| `-t timeout` | exec | Max trace duration in seconds (default: 30) |
| `-d duration` | trace | Trace duration (0 = until Ctrl-C) |
| `-m maxrec` | exec, trace | Stop after N HWT records |
| `-o ptfile` | exec, trace | Output path for .pt file |
| `-T tid` | exec, trace | Thread index to trace (default: 0) |
| `-b backend` | exec, trace | HWT backend (default: auto-detect) |
| `-n` | exec, trace | Dry run — validate setup without tracing |
| `-p` | exec, trace | Pause target on mmap/exec events |

### Roadmap

**Analysis — make traces useful:**
- **Call tree output** — aggregated, indented call tree with function
  counts and nesting depth.  "main -> init -> parse_config -> crash"
  instead of thousands of flat CALL/RETURN lines.
- **Function summary** — top functions by call count, unique call
  sites, hot path identification.
- **Timing from TSC** — PT timestamps (TSC/MTC/CYC packets) give
  wall-clock and cycle-accurate timing per function call.
- **Folded stacks output** — `--format collapsed` for piping to
  [flamegraph.pl](https://github.com/brendangregg/FlameGraph) or
  Speedscope.
- **Syscall name resolution** — map syscall IPs to names
  (`nanosleep`, `read`, `mmap`) instead of `libsys.so.7+0x1234`.

**Collection:**
- **Snapshot / flight recorder mode** — circular buffer with trigger
  capture (e.g., SIGUSR2).  Always keeps the most recent window of
  execution; dump on demand or on crash.

**Kernel patches — pt.ko improvements:**
- **PSB frequency control** — wire `psb_freq` into `RTIT_CTL` bits
  24-27 in `pt_backend_configure`.  Currently the hardware uses its
  default PSB interval, which is too infrequent for short IP-filtered
  traces.  Setting a higher PSB frequency (e.g. every 2-4 KB) ensures
  libipt can sync even on small filtered traces.  Needed to make `-r`
  work reliably on short-lived programs.
- **`pt_backend_stop` implementation** — add a proper stop op so
  `HWT_IOC_STOP` works without panicking.  Currently we close the
  context fd as a workaround, which forces full teardown.  A proper
  stop enables stop/restart on the same context, which is a
  prerequisite for snapshot/flight-recorder mode.
- **Timing packet config** — wire `mtc_freq` and `cyc_thresh` into
  `RTIT_CTL` to enable MTC and CYC timing packets.  Required for
  wall-clock and cycle-accurate function timing.

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

**Flame graphs** — once `--format collapsed` lands, pipe directly
to flamegraph.pl or open in Speedscope:
```sh
bsdtrace decode --format collapsed trace.pt | flamegraph.pl > trace.svg
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

The stock hwt.ko and pt.ko modules have race conditions, a data-loss
bug, and a critical buffer-position bug.  Seven patches are required
(bundled in `KernelConf/hwt-race-fixes.patch`):

**1. hwt_owner.c (hwt_owner_shutdown)** — Set `ctx->state = 0`
*before* calling `hwt_contexthash_remove()`, not after.  The original
ordering allows `hwt_switch_in` to see `state == CTX_STATE_RUNNING`
on a context that is being torn down, leading to a use-after-free of
the PT save area (GPF in `xrstors` during context switch).

**2. pt.c (pt_cpu_start)** — Replace `MPASS(cpu->ctx != NULL)` with
a runtime NULL check that returns early.  Belt-and-suspenders guard
against any path that leaves a stale per-CPU context pointer.

**3. pt.c (pt_send_buffer_record)** — Add a `cpu->ctx == NULL` guard
before dereferencing.  A queued SWI from a PT buffer-overflow PMI can
fire after teardown sets `cpu->ctx = NULL`, causing a NULL deref
panic.

**4. pt.c (pt_backend_enable)** — Restore the per-CPU context pointer
from the thread's private data before calling `pt_cpu_start()`.  The
switch-out hook clears `cpu->ctx` on every context switch, but the
switch-in hook never restored it.  Without this fix, PT tracing
silently stops after the first scheduler preemption.

**5. pt.c (pt_update_buffer)** — Read the buffer position from the
XSAVE save area instead of the MSR.  XSAVES stores the correct value
in the save area then sets `IA32_RTIT_OUTPUT_MASK_PTRS.MaskOrTable-
Offset` to `0x7f` (Intel SDM 36.3.5.2).  The old code read the MSR
after XSAVES, so the page index was always 0 — only the within-page
offset survived.  Every trace captured at most one page of PT data
regardless of buffer size.

**6. pt.c (pt_topa_intr, ctx NULL)** — Replace `KASSERT(ctx != NULL)`
with a runtime NULL check.  A PMI can race with context teardown; the
KASSERT panics in debug builds and blindly dereferences NULL in
release builds.

**7. pt.c (pt_topa_intr, topa_hw NULL)** — Replace
`KASSERT(buf->topa_hw != NULL)` with a runtime NULL check.  Same
teardown race — `pt_deinit_ctx` frees `topa_hw` and zeroes the struct
while a PMI is in flight.

Apply from `/usr/src`:

```sh
doas patch -p1 < KernelConf/hwt-race-fixes.patch
```

Rebuild and install:

```sh
doas sh reload-hwt.sh
```

#### Future kernel patches (hwt.ko + pt.ko enhancements)

**4. Buffer page zeroing** (fixes stale data between traces)

`/usr/src/sys/dev/hwt/hwt_vm.c`, line ~155 in `hwt_vm_alloc_pages()`.
The page zeroing code is disabled behind `#if 0`:

```c
#if 0
    /* TODO: could not clean device memory on arm64. */
    if ((m->flags & PG_ZERO) == 0)
        pmap_zero_page(m);
#endif
```

Although `VM_ALLOC_ZERO` is in `pflags`, `vm_page_alloc_noobj_contig`
doesn't guarantee zeroed pages — it sets `PG_ZERO` only if the page
happened to be pre-zeroed by the VM idle thread.  On second and
subsequent traces, buffer pages are recycled from previous allocations
with stale PT data still present.  This causes userspace to
misinterpret old data as valid trace output.

Fix for x86 (arm64 needs a separate solution per the TODO):

```c
#ifdef __amd64__
    if ((m->flags & PG_ZERO) == 0)
        pmap_zero_page(m);
#endif
```

This ensures every buffer page starts clean.  The cost is one
memset per page at allocation time (~16K pages for a 64 MB buffer,
~1 ms total).

The code snippets below are based on the kernel source and verified
against the defines in `/usr/src/sys/x86/include/specialreg.h`.
The PSB/MTC/CYC encoding values (e.g. "every 2^(N+1) KiB") should
be verified against the Intel SDM (Volume 3, Chapter 32) for
your specific CPU model.  All changes are in
`/usr/src/sys/amd64/pt/pt.c` inside `pt_backend_configure()`
unless noted otherwise.  The `pt_cpu_config` struct already has the
fields — the kernel just doesn't read them yet.

**1. PSB frequency control** (fixes `-r` on short traces)

The hardware emits PSB (Packet Stream Boundary) sync markers at
intervals controlled by `RTIT_CTL` bits 27:24.  libipt cannot
decode without at least one PSB.  The default interval is
implementation-specific and too infrequent for IP-filtered traces
of short-lived programs (e.g. 166 bytes with no PSB).

In `pt_backend_configure()`, after the existing `pt_configure_ranges()`
call, add:

The valid PSB frequency values are CPU-specific.
`CPUID.(EAX=14H, ECX=1):EAX[2:0]` reports the number of
configurable values.  The kernel already queries this leaf at
init and stores it in `pt_info.l1_eax`.  Follow the same pattern
as `pt_configure_ranges()` — check the capability before using it:

```c
/* PSB frequency: RTIT_CTL bits [27:24] (RTIT_CTL_PSB_FREQ_S = 24).
 * Value N means emit PSB every 2^(N+1) KiB of output (per Intel SDM).
 * Valid range of N depends on CPUID leaf 14H, subleaf 1, EAX[2:0].
 * Uses existing macros from <x86/specialreg.h>. */
if (cfg->psb_freq != 0) {
    int psb_max = pt_info.l1_eax & 0x7;  /* supported PSB values */
    int psb_val = cfg->psb_freq;
    if (psb_val > psb_max) {
        printf("%s: psb_freq %d exceeds CPU max %d, clamping\n",
            __func__, psb_val, psb_max);
        psb_val = psb_max;
    }
    pt_ext->rtit_ctl |= ((uint64_t)(psb_val & 0xf) << RTIT_CTL_PSB_FREQ_S);
}
```

Then in userspace (`hwt.c:hwt_ctx_set_config_pt`), set
`ptcfg.psb_freq` when `-r` is active to get frequent sync points:

```c
if (ctx->filter.nranges > 0)
    ptcfg.psb_freq = 0;  /* most frequent PSB interval */
```

**2. `pt_backend_stop` implementation** (enables `HWT_IOC_STOP`)

Currently `pt_ops.hwt_backend_stop` is NULL, so `HWT_IOC_STOP`
dereferences NULL and panics.  bsdtrace works around this by
closing the context fd.

Add a new function modeled on `pt_backend_disable()` but without
tearing down the context:

```c
static void
pt_backend_stop_op(struct hwt_context *ctx, int cpu_id)
{
    struct pt_cpu *cpu;

    if (ctx->mode == HWT_MODE_CPU)
        return;
    KASSERT(curcpu == cpu_id,
        ("%s: wrong cpu", __func__));

    cpu = &pt_pcpu[cpu_id];
    pt_cpu_set_state(cpu_id, PT_INACTIVE);
    while (atomic_cmpset_int(&cpu->in_pcint_handler, 1, 0))
        ;
    pt_cpu_stop(NULL);
    CPU_CLR(cpu_id, &ctx->cpu_map);
    /* NOTE: do NOT set cpu->ctx = NULL — context stays alive
     * for restart or buffer read. */
}
```

Wire it into `pt_ops`:

```c
static struct hwt_backend_ops pt_ops = {
    ...
    .hwt_backend_stop = pt_backend_stop_op,
    ...
};
```

Once this works, bsdtrace can issue `HWT_IOC_STOP` then
`HWT_IOC_BUFPTR_GET` then `HWT_IOC_START` on the same context —
prerequisite for snapshot/flight-recorder mode.

The HWT state machine is a simple `STOPPED <-> RUNNING` toggle
(`hwt_context.h`).  `HWT_IOC_START` only rejects if already
`CTX_STATE_RUNNING`.  After `HWT_IOC_STOP` sets `CTX_STATE_STOPPED`,
a subsequent `HWT_IOC_START` will pass the guard and call
`hwt_backend_configure` + `hwt_backend_enable` again.  So the
stop→start cycle works at the framework level — the backend just
needs to leave hardware resources intact (don't free the ToPA or
save area).

**Note**: `HWT_IOC_STOP` does not take `HWT_CTX_LOCK`, while
`HWT_IOC_START` does.  This is a locking asymmetry in the
framework that could race under concurrent access, but is fine
for single-threaded bsdtrace usage.

**3. Timing packet configuration** (enables function timing)

MTC (Mini Time Counter) and CYC (cycle-accurate) packets provide
wall-clock and cycle timing.  Controlled by `RTIT_CTL` bits and
the `mtc_freq` / `cyc_thresh` config fields.

```c
/* MTC frequency: RTIT_CTL bits [17:14] (RTIT_CTL_MTC_FREQ_S = 14).
 * Controls how often MTC packets are emitted.
 * Requires CPUPT_MTC support (already checked in pt_backend_configure). */
if (cfg->mtc_freq != 0) {
    pt_ext->rtit_ctl |= RTIT_CTL_MTCEN;
    pt_ext->rtit_ctl |= ((uint64_t)(cfg->mtc_freq & 0xf) << RTIT_CTL_MTC_FREQ_S);
}

/* CYC threshold: RTIT_CTL bits [22:19] (RTIT_CTL_CYC_THRESH_S = 19).
 * Controls cycle-accurate mode threshold. */
if (cfg->cyc_thresh != 0) {
    pt_ext->rtit_ctl |= RTIT_CTL_CYCEN;
    pt_ext->rtit_ctl |= ((uint64_t)(cfg->cyc_thresh & 0xf) << RTIT_CTL_CYC_THRESH_S);
}
```

All macros (`RTIT_CTL_CYCEN`, `RTIT_CTL_MTCEN`, `RTIT_CTL_MTC_FREQ_S`,
`RTIT_CTL_CYC_THRESH_S`, `RTIT_CTL_PSB_FREQ_S`) are already defined in
`<x86/specialreg.h>`.  `RTIT_CTL_CYCEN` (bit 1) and `RTIT_CTL_MTCEN`
(bit 9) need to be added to `PT_SUPPORTED_FLAGS` at the top of pt.c
so they aren't masked out.  libipt decodes MTC/CYC packets
automatically when present in the stream.

#### Crash dump inspection

If HWT or bsdtrace testing panics the kernel, inspect the latest
crash dump with:
```sh
doas cat /var/crash/info.last

doas lldb -c /var/crash/vmcore.last /boot/kernel/kernel \
  -o 'bt' \
  -o 'frame select 9' \
  -o 'frame variable dev dsw ref com' \
  -o 'expr -f hex -- dev' \
  -o 'expr -f hex -- dev->si_devsw' \
  -o 'expr -f hex -- ((struct cdevsw *)dev->si_devsw)->d_ioctl' \
  -o 'expr -f hex -- ((struct cdevsw *)dev->si_devsw)->d_name' \
  -o 'quit'
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
   so libipt can resolve compressed IPs.  The dynamic linker is
   resolved via PT_INTERP.
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

Builds all executables into `.build/debug/`:
`bsdinstruments`, `hwtlm`, `bsdtrace`, and the test helper programs
(`bsdtrace-testprog`, `bsdtrace-attachprog`, `bsdtrace-floodprog`).

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

The bsdtrace test suite (`test-bsdtrace.sh`) has two tiers:
- **No-root**: version, list, decode error handling
- **Root**: exec, trace, decode with real PT hardware

Current PT/HWT workaround:
- After a failed or truncated hardware trace, the backend can retain stale
  state and the next `bsdtrace exec`/suite run may decode only loader events
  or `0 instructions`.
- `test-bsdtrace.sh` now performs a warmup `bsdtrace exec` before the root HWT
  tier to clear that stale state.
- If you are running commands manually, the equivalent warmup is:

```sh
cc -O0 -o /tmp/bsdtrace-testprog Tests/bsdtrace/testprog/main.c
.build/x86_64-unknown-freebsd/debug/bsdtrace exec -t 5 \
  -o /tmp/bsdtrace-warmup.pt -- /tmp/bsdtrace-testprog
```

This is a workaround for backend/test instability, not a real fix for the
underlying PT teardown issue.

Known limitations:
- Back-to-back root `bsdtrace` runs can still be flaky on some patched PT/HWT
  kernels.  The warmup trace is only a best-effort reset, not a guarantee.
- When the backend gets into a bad state, a run may decode only loader events
  or `0 instructions`; rerunning the suite or manually running one successful
  `bsdtrace exec` can still recover it.
- The most reliable workflow remains: capture once, then analyze the saved
  `.pt` + `.meta` files offline.

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
