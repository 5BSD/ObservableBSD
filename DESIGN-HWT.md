# dtlm — HWT Integration Design

> **Companion to [`DESIGN.md`](./DESIGN.md).** This document covers
> adding FreeBSD's `hwt(4)` Hardware Trace Framework to dtlm as a
> second telemetry *source* alongside libdtrace, and shipping its data
> through the existing `Exporter` framework (text / JSONL / OTLP) with
> the same CLI, the same resource attribution, and the same OTel
> pipeline.

---

## 1. The pitch

```
hwt CTX  →  /dev/hwt_*  →  decoder (Intel PT / CoreSight / SPE)  →
            ProbeEvent + AggregationSnapshot  →  Exporter  →  text / JSONL / OTLP
```

dtlm today is a DTrace tool. It loads `.d` files, runs them via
libdtrace, and ships the result as OpenTelemetry. hwt integration
adds a **second ingest path** that drives `/dev/hwt`, consumes the
raw trace buffers from whichever backend the running kernel has
(Intel PT on amd64, ARM CoreSight or SPE on arm64), decodes them
into the same typed event model the rest of dtlm already uses, and
hands them to the same exporters.

After integration, this works:

```sh
# CPU profile via Intel PT on amd64, shipped to OTel with function
# names resolved from ELF symbols — no sampling loss, full call flow
sudo dtlm watch hwt-cpu-profile --pid 5123 --with-ustack \
     --format otel --endpoint https://collector:4318/v1/logs \
     --service mywebapp --instance api-1

# ARM SPE statistical profile, latency histogram to OTel metrics
sudo dtlm watch hwt-spe-latency --cpu 0-7 --format otel ...

# Function entry/exit trace of one function via Intel PT range filter
sudo dtlm watch hwt-function-trace --pid 5123 \
     --param func=pg_parse_query --duration 30s --format json
```

The pitch is **"parca-agent on FreeBSD, for free, using the hardware
unit the CPU already has."** dtlm's OTel pipeline, stack plumbing,
and resource attribution all exist already. hwt is the missing
ingest side: an observer that doesn't need probes in the target
code and doesn't pay the libdtrace per-event overhead.

---

## 2. Why hwt belongs in dtlm (not a separate tool)

Two things make this the right home:

1. **The output half is already built.** dtlm already has a typed
   event model, a pluggable Exporter protocol, OTLP/HTTP+JSON with
   auth and backoff, resource attribution, traceparent correlation,
   graceful shutdown, and an `rc.d/dtlm` wrapper. A standalone
   `hwt-otel` tool would reimplement all of it. Integrating hwt into
   dtlm means the hardware-trace path gets `--format otel
   --endpoint ... --auth-bearer-file ... --service ... --instance ...
   --with-ustack --sample 1/N --duration 60s` on day one, for free.

2. **The dual audience is the same.** dtlm's two audiences are
   sysadmins doing kernel observability and developers profiling
   their own applications. hwt's two modes — **CPU mode** (all
   activity on a cpuset) and **Thread mode** (one process's threads)
   — map exactly onto those audiences. Sysadmins get system-wide
   continuous profiling; developers get per-process call-flow
   reconstruction. Both land in the same `dtlm list`, the same OTel
   collector, the same Grafana.

The alternative — shipping this as `hwt-otel(1)` — splits the user
story, duplicates the exporter, and means ops teams configure two
daemons in `rc.d` when they could configure one.

---

## 3. What HWT integration IS and IS NOT

**IS:**
- A second ingest path next to libdtrace, behind a `TelemetrySource`
  protocol the run loop calls uniformly
- A `TraceBackend` abstraction with three conformances — Intel PT
  (amd64), CoreSight (arm64), SPE (arm64) — each owning the
  backend-specific decoder and the specific ioctl config calls
- A symbolizer (libelf + libdwarf) built into dtlm for resolving
  user-space PCs out of the hwt trace buffer, plus `/boot/kernel`
  plus `.symtab` for kernel PCs
- A small set of **hand-authored hwt profiles** declared in Swift,
  not `.d` — because hwt has no script language, the "profile" is a
  typed config struct
- A new event flavor (`HWTSample`, `HWTBranchRecord`, `HWTFunctionSpan`)
  that normalizes into the existing `ProbeEvent` /
  `AggregationSnapshot` / future `Span` shape before reaching any
  exporter
- A first real user of the deferred OTel **span** signal — function
  entry/exit from hwt produces genuine spans without needing the
  sidecar metadata that made DTrace span pairing a non-starter

**IS NOT:**
- A replacement for `hwt(4)` — it depends on it
- A new trace decoder — dtlm wraps `libipt` (Intel),
  `OpenCSD`/`libopencsd` (CoreSight), and a small in-tree SPE record
  walker. None of those decoders are reimplemented.
- A kernel patch — everything happens in userspace against the
  `/dev/hwt` interface already present in FreeBSD 15.0+
- A flame-graph renderer — same policy as the DTrace side: pipe
  stack output to `flamegraph.pl` or to parca/pyroscope via OTel
- A replacement for `hwt(8)` — it is what `hwt(8)` would have been,
  because `hwt(8)` does not exist in `/usr/src` yet (the `hwt.4`
  man page references it but there is no userland tool checked in)
- A DTrace-plus-hwt merge — the two sources run as separate dtlm
  processes if you want both signals. Merging into one process is
  post-v1, same policy as DTrace multi-profile composition.

---

## 4. Where hwt plugs into the existing architecture

The seam is at the **framework layer** that already sits between
`DTraceCore` and the exporters:

```
        ┌──────────────────────┐    ┌──────────────────────┐
        │  .d profile file     │    │  hwt profile (Swift) │
        │  (bundled / system / │    │  mode, backend,      │
        │   user)              │    │  filters, outputs    │
        └──────────┬───────────┘    └──────────┬───────────┘
                   │                           │
                   ▼                           ▼
        ┌──────────────────────┐    ┌──────────────────────┐
        │  DTraceCore source   │    │  HWTSource           │
        │  (libdtrace)         │    │  /dev/hwt ioctl +    │
        │                      │    │  TraceBackend decode │
        └──────────┬───────────┘    └──────────┬───────────┘
                   │                           │
                   └─────────────┬─────────────┘
                                 │  typed events
                                 ▼
                    ┌──────────────────────┐
                    │  framework layer     │
                    │  - sampling (1/N)    │
                    │  - resource attrs    │
                    │  - traceparent prop  │
                    │  - symbolizer        │  ← new in HWT work
                    │  - typed event model │
                    └──────────┬───────────┘
                               │ ProbeEvent / AggSnapshot / Span
                               ▼
                    ┌──────────────────────┐
                    │  Exporter (unchanged)│
                    │  ├─ TextExporter     │
                    │  ├─ JSONLExporter    │
                    │  └─ OTLPHTTPJSONExp. │
                    └──────────────────────┘
```

The `TelemetrySource` protocol — new in this work — is what the
run loop iterates over:

```swift
public protocol TelemetrySource: Sendable {
    /// CLI name of the profile this source is executing.
    var profileName: String { get }

    /// Open whatever kernel interface the source needs.
    func start() async throws

    /// Yield typed events until cancelled.
    func events() -> AsyncStream<SourceEvent>

    /// Clean shutdown — release kernel resources.
    func stop() async throws
}

public enum SourceEvent: Sendable {
    case probe(ProbeEvent)
    case aggregation(AggregationSnapshot)
    case span(FunctionSpan)           // new in HWT work
}
```

Today there is effectively one implicit source: the libdtrace run
loop in `WatchRunner.swift`. This work extracts that into a
`DTraceSource: TelemetrySource` (mechanical refactor, no behavior
change) and adds `HWTSource: TelemetrySource` next to it. The
exporters never learn that hwt exists.

---

## 5. The profile model for hwt

DTrace profiles are `.d` files because libdtrace has a compiler. hwt
has no script language — configuration is a set of ioctls and, on
Intel PT and CoreSight, a small set of address-range filter
registers. There is nothing to parse. So an hwt profile is a **Swift
value** declared in source, not a file on disk:

```swift
public struct HWTProfile: Sendable {
    public let name: String                 // "hwt-cpu-profile"
    public let description: String          // one-line, shown in `dtlm list`
    public let mode: HWTMode                 // .cpu(cpuset) or .thread
    public let backend: HWTBackendRequirement // .intelPT, .coresight, .spe, .any
    public let outputs: Set<HWTOutputKind>   // .pcSamples, .branches, .spans, .latency
    public let defaultFilters: [HWTFilter]   // address ranges, etc.
    public let parameters: [ParameterSpec]   // same ${name} shape as .d profiles
}
```

Profiles live in `Sources/dtlm/Profiles/HWT/` as ordinary Swift
files. Adding one is the same one-file drop as a `.d` profile; it
just happens to be Swift because there's no script to parse.

**System-installed hwt profiles** (`/usr/local/share/dtlm/profiles/hwt/`)
and **per-user** (`~/.dtlm/profiles/hwt/`) work via a small TOML
loader, since operators shouldn't need a Swift compiler to add a
profile. The Swift bundled profiles are canonical; the TOML is a
shallow deserializer into the same `HWTProfile` struct. The TOML
loader is ~150 LOC; skipping it is defensible for v1 if we're
scope-constrained.

**The `.d` profile loader is untouched.** hwt profiles are loaded
by a second loader that runs after the `.d` loader and merges into
the same `dtlm list` output. Filename-collision policy: hwt profiles
and `.d` profiles can share a prefix (`hwt-*`) so collisions are
impossible in practice.

---

## 6. CLI surface additions

No new subcommands. `dtlm watch` learns hwt profile names, and a few
hwt-specific flags are added behind the existing `[--param k=v]`
substitution mechanism plus a small set of new top-level flags that
only apply to hwt profiles:

```
dtlm watch <hwt-profile-name>
  [--pid PID]                # required for thread-mode profiles
  [--cpu CPUSET]             # required for cpu-mode profiles (e.g. 0-7, 0,2,4)
  [--with-ustack]            # for hwt this is effectively free
  [--with-stack]             # kernel symbolization
  [--range START:END@BIN]    # address-range filter (Intel PT / CoreSight)
  [--param key=value …]      # e.g. --param func=pg_parse_query
  [--duration SECONDS]
  [--sample 1/N]             # applied in the framework layer, post-decode
  [--format text|json|otel]
  ... (all existing OTel/auth/resource flags unchanged)
```

Three flag additions: `--cpu`, `--range`, and that's it. Everything
else is reused verbatim from the DTrace path. `--pid` already exists.

`dtlm probes` gains one invocation:

```
dtlm probes --hwt             # prints which backends the running kernel supports
```

This reads `/dev/hwt` availability plus `sysctl kern.hwt.backends`
(new sysctl introduced as part of this work, optional), and prints
something like:

```
backend         arch    available   notes
intel_pt        amd64   yes         Intel PT available (family 0x6 model 0xba)
coresight       arm64   n/a         not amd64
spe             arm64   n/a         not amd64
```

That's the whole CLI delta. Four new things in `--help`.

---

## 7. Data model: hwt events → dtlm typed events

hwt backends produce three fundamentally different record shapes.
dtlm normalizes them into one of the existing three event flavors:

| hwt record | Backend | Normalized to | Notes |
|---|---|---|---|
| PC sample (periodic or on-demand) | Intel PT PSB/TIP, SPE record | `ProbeEvent` with `fields.pc`, optional `ustack` | Equivalent to a DTrace `profile-99` firing — one event per sample, resolved to a function name by the symbolizer |
| Branch taken/not-taken | Intel PT TNT/TIP | **Aggregated only** — never one `ProbeEvent` per branch | Emitted as an `AggregationSnapshot` of kind `.count` keyed by (from\_func, to\_func); raw branches are orders of magnitude too high-volume to ship as individual log records |
| SPE latency / stall record | SPE | `AggregationSnapshot` of kind `.quantize` (→ OTel `ExponentialHistogram`) | SPE's native unit already looks like a histogram input |
| Function entry/exit pair (reconstructed from call/ret flow) | Intel PT, CoreSight | `FunctionSpan` → future OTel span signal | The first real use of the deferred span signal; see §10 |
| `exec`/`mmap` record from the hwt hook layer | All | `ProbeEvent` with `profileName = "hwt:meta"` | Used by the symbolizer to know which ELF object a PC belongs to, but also surfaced as a regular event so users can see process lifecycle |

Critically, **PC samples and branches do not pay the libdtrace
per-event round trip**. The consume callback path through the
framework layer is:

1. Backend decoder (libipt/OpenCSD/SPE walker) drains the shared
   buffer from `/dev/hwt_${ident}_${d}`.
2. Decoder emits typed hwt records at C-speed.
3. dtlm's framework layer applies `--sample 1/N`, attaches resource
   attributes, resolves symbols, and constructs a `ProbeEvent` /
   `AggregationSnapshot` / `FunctionSpan`.
4. Existing exporter receives the typed event. It has no idea this
   data came from hwt rather than libdtrace.

The per-event overhead budget is **≤500 ns per PC sample** end-to-end
on a modern amd64 box before backpressure matters. That's achievable
because libipt decodes PT at ~1 GB/s on a single core, and the
framework layer after decode is pure arithmetic and a dictionary
lookup.

---

## 8. The `TraceBackend` abstraction

The backend seam is a Swift protocol the hwt source uses internally:

```swift
protocol TraceBackend: Sendable {
    static var name: String { get }                  // "intel_pt", "coresight", "spe"
    static var supportedArch: Set<CPUArch> { get }
    static var requiredDevice: String { get }         // "intel_pt" / "coresight" / "spe"

    /// Called once after HWT_IOC_ALLOC to apply backend-specific
    /// HWT_IOC_SET_CONFIG parameters (filter regs, trace flags).
    func configure(ctx: HWTContext, profile: HWTProfile) throws

    /// Drain and decode the shared buffer. Yields hwt-level records
    /// that the source then normalizes.
    func decode(buffer: UnsafeRawBufferPointer,
                elfMap: ELFAddressMap) -> AsyncStream<HWTRecord>
}
```

Three conformances in v1:

- `IntelPTBackend` — wraps `libipt` (system dep: `devel/libipt`
  port). ~600 LOC of Swift + C shim. This is the only backend that
  matters for the FreeBSD/amd64 install base in 2026.
- `CoreSightBackend` — wraps `libopencsd`. ~500 LOC. Scoped but
  **deferred to a later phase** — amd64 first, arm64 second.
- `SPEBackend` — SPE records have a simple self-describing layout;
  no external decoder library needed. ~300 LOC. Deferred to the
  same arm64 phase as CoreSight.

Backend selection at run time: a profile declares
`backend: .intelPT | .coresight | .spe | .any`. If `.any`, dtlm picks
whichever backend the running kernel has (`sysctl
kern.hwt.backends` or by probing `device` availability). If the
profile requires a specific backend that isn't present, `dtlm
watch` refuses to start with a clear error pointing at the
`hwt.4` man page.

---

## 9. Symbolication

hwt emits raw PCs. libdtrace's symbolizer is not in the loop, so
dtlm needs its own. v1 scope:

- **User PCs**: resolve via the ELF object the `HWT_IOC_RECORD_GET`
  hook records told us about. One `ELFAddressMap` per
  `(pid, load_address)` pair. Uses libelf's `.symtab`/`.dynsym`
  directly; no libdwarf line-number resolution in v1.
- **Kernel PCs**: resolve via `/boot/kernel/kernel` and every
  `.ko` in the running kldstat output. Same path, libelf only.
- **Stripped binaries**: produce `module+0xOFFSET` strings, same as
  the DTrace path does today. Users who want function names strip
  less.
- **DWARF line numbers / inlined frames**: deferred. Phase out to a
  post-v1 feature when a user actually asks. Function-level
  attribution is 95% of what continuous profiling pipelines want.

The symbolizer is a framework-layer component, not an hwt-source
component, because once it exists dtlm can optionally use it on the
DTrace side too (for `ustack()` strings that come back unresolved
because libdtrace couldn't find the file). That's a side benefit,
not the driver.

Symbol cache: in-memory, per-process, keyed by `(inode, mtime)` so
the cache survives `mmap` remaps of the same object. ~300 LOC total.

---

## 10. Output mapping per exporter

The existing exporters don't change. What they receive for hwt
profiles, in OTel-mode:

| hwt output | Text exporter | JSONL exporter | OTel exporter |
|---|---|---|---|
| PC sample (pid, execname, func, ustack) | One line per sample: `pid execname func+off` plus indented stack | One JSON object per sample | `LogRecord` (unchanged shape — this is why the mapping works); `dtlm.source=hwt` attribute |
| Aggregated branch count (from\_func → to\_func) | Tabular dump at `--duration` end | One JSON object per snapshot | `Sum` (monotonic) `dtlm.<profile>.branches` with `from`/`to` data-point attrs |
| SPE latency histogram | Histogram dump at exit | One object per snapshot | `ExponentialHistogram` (same code path as DTrace `quantize`) |
| Function span (from §7) | Lines indented by depth | One object per span | **OTel Span** — first real user of the deferred span signal. See below. |
| hwt meta event (`exec`, `mmap`) | One info line | One JSON object | `LogRecord` tagged `dtlm.source=hwt`, `dtlm.kind=meta` |

**Span pairing is trivial for hwt.** The thing that made DTrace span
pairing a scope-management disaster was needing sidecar metadata to
declare which clauses pair into entry/return. hwt gives you the
pairing for free: the decoder emits `FunctionEnter(pc, ts)` and
`FunctionExit(pc, ts)` from the PT/CoreSight flow. Span construction
is mechanical. So the OTel **traces** signal ships for hwt profiles
in the same phase that hwt ships, even though it remains deferred
for DTrace profiles. This is a nice side-effect: hwt gets dtlm to
three OTel signals (logs + metrics + spans) at the same time.

W3C `traceparent` propagation already works — same flag as the
DTrace path.

---

## 11. Bundled hwt profiles

Phase-1 hwt set — small on purpose, high leverage:

| Profile | Mode | Backend | Outputs | What it does |
|---|---|---|---|---|
| `hwt-cpu-profile` | thread | any | `.pcSamples`, `.spans` | The "Time Profiler on real hardware" profile. Continuous sampling of a target pid; emits OTel metrics keyed by function plus function-entry/exit spans. The headline profile. |
| `hwt-system-profile` | cpu | any | `.pcSamples` | Same but system-wide on a cpuset. The operator-facing counterpart. |
| `hwt-function-trace` | thread | intelPT | `.spans` | Address-range-filtered trace of one function (via `--param func=NAME`). Produces one OTel span per invocation with the full nested call tree as child spans. The "parca for my hot path" profile. |
| `hwt-branch-mix` | thread | intelPT | `.branches` | Aggregated (from, to) branch counts. Ships as OTel `Sum`s. Debugging branch prediction / hot-loop analysis. |
| `hwt-spe-latency` | cpu | spe | `.latency` | ARM SPE latency histogram. arm64-only. |

Five profiles. Enough to demonstrate every integration path
(thread/cpu × all three output kinds × all three backends). This is
the **minimum** hwt set — the expanded capability catalog in §12
layers on top of it.

---

## 12. Capability catalog

Beyond the five foundational profiles in §11, hwt unlocks a set of
concrete capabilities that are each a thin layer over the shared
decoder + symbolizer + exporter pipeline. Each row is one profile
file plus (in some cases) one small piece of framework work. None of
them re-enter the core architecture.

| # | Profile | Mode | What it provides | New code | Kernel patch |
|---|---|---|---|---|---|
| 1 | `hwt-cpu-profile` | thread / cpu | Continuous function-level CPU profile. The flagship. "parca-agent for FreeBSD." Already in §11. | PC extraction + aggregation (existing). Adds **pprof** and **folded-stack** exporters (§13). | none |
| 2 | `hwt-function-trace` | thread | Automatic OTel spans for any function in any binary — no code changes. Range filter + decoder pair on CALL/RET. Already in §11. | Span constructor pairs `FunctionEnter`/`FunctionExit` from the PT call flow. | none |
| 3 | `hwt-coverage` | thread | Code coverage for a stripped binary at near-line-rate. Basic-block set diffed against the target's static BB enumeration. Output: JSONL "new-coverage" events plus **afl++/honggfuzz bitmap** format for fuzzer harnesses. | Static BB walk via Capstone, live BB-set tracker during decode, diff emitter. ~400 LOC. | none |
| 4 | `hwt-ringbuffer` | thread / cpu | Post-mortem "what happened just before the crash." PT runs in circular mode with no normal drain; a trigger (SIGSEGV on target, SIGUSR1, periodic) snapshots the ring to a `.pt.bin` sidecar file. **`dtlm replay`** subcommand decodes the sidecar offline. | Ringbuffer profile + file-format spec + replay subcommand. ~300 + ~500 LOC. Touches core(5) integration in §13. | none |
| 5 | `hwt-latency-attribution` | thread | Exact cycle-accurate latency attribution for a hot path. Per-invocation cycle accounting, self-time breakdown down the call tree. Output: OTel `ExponentialHistogram` + JSONL per invocation. | Cycle accounting during decode, self-time attribution algorithm. ~300 LOC. | **CYCEN whitelist** (K1 below) |
| 6 | `hwt-kernel-bench` | cpu | Kernel fast-path microbenchmarking. Range-filter to one kernel function, cycle + instruction count per invocation. **`dtlm diff`** subcommand compares two JSONL runs for regression detection. | Profile + kernel-symbol → address-filter lowering via libelf on `/boot/kernel/kernel` + diff subcommand. ~200 + ~150 LOC. | **CYCEN whitelist** (K1 below) |
| 7 | `hwt-cfi` | thread | Control-flow integrity monitor. v1 scope: return-address sanity (every `RET` must target a known function epilogue). Alerts as OTel logs at `WARN`. | Static policy extractor via Capstone + live comparison during decode. ~400 LOC. | none |
| 8 | `hwt-hang-analysis` | thread | Hang / livelock forensics. One-shot: attach for N ms, decode, find the longest repeating basic-block substring, print the inner loop with frequencies. | Cycle detection + longest-repeating-substring analysis on the BB sequence. ~200 LOC. | none |

**Two new subcommands** fall out of the catalog, beyond the four in
`DESIGN.md` §8:

- **`dtlm replay`** — offline decode of a saved `.pt.bin` sidecar
  file against an ELF map. Reads the sidecar, walks records, emits
  an annotated execution trace to text / JSONL / OTel. Required for
  capability #4.
- **`dtlm diff`** — compares two hwt JSONL outputs (typically from
  `hwt-kernel-bench`) and reports statistical differences with
  p-values. Required for capability #6.

Both are small and additive; neither perturbs `watch`/`list`/
`generate`/`probes`.

**One kernel patch** — `K1` — is load-bearing across capabilities
#5 and #6: adding `RTIT_CTL_CYCEN` and `RTIT_CTL_TSCEN` to
`PT_SUPPORTED_FLAGS` at `/usr/src/sys/amd64/pt/pt.c:83`, plus the
corresponding `pt_cpu_config` plumbing. ~20 lines of kernel. Worth
contributing upstream as its own PR independent of dtlm. Without
K1, capabilities #5 and #6 degrade to packet-boundary timing — still
useful, but not cycle-accurate.

---

## 13. Base-system integration

The capability catalog in §12 gains most of its leverage through
three cheap output-format additions and one file-format hook into
the base crash-dump flow. Everything here is additive to the
`Exporter` framework — no core changes.

### In scope

| Integration | Unlocks | Size |
|---|---|---|
| **libxo output routing** for the text exporter | Every FreeBSD base tool that emits structured output (`ps`, `netstat`, `ifconfig`, `top`, `systat`, …) uses libxo to produce text / JSON / XML / HTML from one format string. Routing the dtlm text exporter through libxo gives `dtlm watch foo --libxo json` and composition with every other base tool's JSON out. **The single biggest "integrates with FreeBSD" move.** | ~100 LOC, one base dep |
| **Folded-stack exporter** (`--format folded`) | `benchmarks/flamegraph`'s `flamegraph.pl` is the canonical FreeBSD flame-graph renderer. `dtlm watch hwt-cpu-profile --format folded \| flamegraph.pl > out.svg` is what users expect. | ~50 LOC |
| **pprof exporter** (`--format pprof`, `.pb.gz` output) | Opens the entire Linux/Go profiling ecosystem — `go tool pprof`, `speedscope`, `hotspot`, Pyroscope, Phlare, Chrome profile viewer. No new runtime dependency; pprof is a protobuf dtlm hand-encodes. | ~300 LOC |
| **gprof `.prof` exporter** (`--format gprof`) | `pmcstat(8)`-compatible gmon.out output. Existing `pmcstat -O foo.prof \| gprof` pipelines get a drop-in replacement path to dtlm. Migration lever for sysadmins who already script around pmcstat. | ~200 LOC |
| **savecore / core(5) sidecar hook** for capability #4 | When a target process cores, `hwt-ringbuffer` catches SIGSEGV via kevent, drains the ring, and writes `hwt.${execname}.${pid}.${ts}.pt.bin` next to the core file in the directory `kern.corefile` resolved to. For kernel panics, a parallel daemon in CPU mode snapshots to `/var/crash/hwt.vmcore.${N}.pt.bin` so `savecore(8)` / `crashinfo(8)` naturally pick it up as an adjacent artifact. Users get "the last few hundred million instructions before the crash" alongside the existing dump flow. | ~150 LOC + 1-page sidecar file-format spec |

### Post-v1

| Integration | Why deferred |
|---|---|
| **`kgdb(1)` extension for PT-ring replay** | Python plugin for `devel/gdb` that reads the `.pt.bin` sidecar + its core file and exposes `reverse-stepi` / `reverse-continue` over the recorded trace. "rr for FreeBSD." Realistic but ambitious: ~500 LOC of Python + libipt bindings or a `dtlm replay --gdb-mi` subprocess mode. Keep out of initial scope; revisit once #4's sidecar format has stabilized. |
| **DTrace + hwt correlation in one `dtlm watch`** | Same underlying feature as DTrace multi-profile composition in `DESIGN.md` §15. The architecture in §4 supports it via two `TelemetrySource`s in one process, but the collision policy work isn't worth doing until a user asks. Workaround: two dtlm processes, same collector, same `host.name` / `instance.id`. |
| **`perf.data` output** | pprof + folded-stack already cover 90% of the `perf report` / `hotspot` / `flamegraph` workflow with a fraction of the encoder complexity. Revisit only if bidirectional recording sharing with Linux users becomes a real ask. |

### Explicitly not doing

- **`ktrace(1)` / `kdump(1)` / `truss(1)` parity.** Syscall-focused
  tools. No overlap with instruction tracing — don't blur the line.
- **Replacing `pmcstat(8)`.** pmcstat does sampled PMC events
  (cache misses, branch mispredicts, LLC loads) that hwt-via-PT
  does not directly cover. It's a complement, not a replacement.
  The gprof output compatibility above is the only integration
  worth pursuing.
- **`procstat -kk` parity.** procstat already prints kernel stacks
  via `kinfo_kstack`. Not worth duplicating; optionally
  cross-reference as a starting-state snapshot when an hwt profile
  attaches.

---

## 14. Phase plan

| Phase | Scope | LOC |
|---|---|---|
| **H1** | `TelemetrySource` refactor: extract the current `WatchRunner` loop into `DTraceSource: TelemetrySource`, route existing profiles through it unchanged. No behavior change. Pure refactor. Must land first so H2 has a seam to plug into. | ~200 |
| **H2** | `HWTSource` skeleton: drives `HWT_IOC_ALLOC`, opens `/dev/hwt_${ident}_${d}`, mmaps the shared buffer, exposes it to a (stub) `TraceBackend`. No decoder yet — just verifies the lifecycle from `dtlm watch` through `HWT_IOC_START`/`STOP` works. Text exporter prints "got N bytes from hwt". | ~300 |
| **H3** | `IntelPTBackend` wrapping `libipt`. C shim in `Sources/CLibipt` plus Swift wrapper. Emits `HWTRecord` values for PC samples and branches. First real data lands in the text exporter. amd64-only. | ~600 |
| **H4** | Symbolizer (user + kernel, libelf only, function-level). Framework layer, usable by both `HWTSource` and (optionally) `DTraceSource`. PC → `func+0xOFFSET`. Symbol cache. | ~300 |
| **H5** | Normalization: hwt records → `ProbeEvent` / `AggregationSnapshot` / `FunctionSpan`. `--sample 1/N` in the framework layer. Text + JSONL exporters work end-to-end for the three Phase-1 profiles that don't need span output. | ~250 |
| **H6** | OTel exporter: new `dtlm.source=hwt` attribute, PC samples as `LogRecord`s, branches as `Sum`, SPE latency as `ExponentialHistogram`. Reuses every existing OTel code path. | ~100 |
| **H7** | **OTel spans for hwt**: `FunctionSpan` → OTLP `Span` with parent/child nesting from the PT call tree. First real user of the OTel traces signal. ~450 LOC of span construction + OTLP span encoding (the deferred work from the DTrace side). | ~450 |
| **H8** | Five bundled hwt profiles (see §11). Swift source. | ~200 |
| **H9** | (arm64) `SPEBackend` + `CoreSightBackend`. Ships whenever an arm64 board is on the bench. Not on the amd64 critical path. | ~800 |
| **H10** | Optional: TOML loader for system/user hwt profiles in `/usr/local/share/dtlm/profiles/hwt/` and `~/.dtlm/profiles/hwt/`. Skippable for v1 of the hwt work. | ~150 |
| **H11** | **Output-format expansion** for §13 base-system integration: **libxo** routing for the text exporter, **folded-stack** exporter, **pprof** exporter, **gprof** exporter. All are `Exporter` conformances in the existing framework — no core changes. | ~650 |
| **H12** | **Capability profiles #3, #5, #6, #7, #8** from §12 (coverage, latency-attribution, kernel-bench, CFI, hang-analysis). Includes the **`dtlm diff`** subcommand. Depends on K1 landing for #5 and #6 at cycle-accurate fidelity; profiles work at packet-boundary fidelity without it. | ~1500 |
| **H13** | **Capability profile #4** (ringbuffer) from §12: circular-mode PT, SIGSEGV / SIGUSR1 / periodic triggers, sidecar file format spec, **`dtlm replay`** subcommand, savecore / core(5) sidecar hook from §13. | ~950 |

Separately, **K1 (out of band)**: add `RTIT_CTL_CYCEN` and
`RTIT_CTL_TSCEN` to `PT_SUPPORTED_FLAGS` at
`/usr/src/sys/amd64/pt/pt.c:83` plus the matching `pt_cpu_config`
plumbing. ~20 LOC kernel patch. Ships upstream to FreeBSD as its
own PR, independent of the dtlm repo. Unlocks cycle-accurate
timing for capabilities #5 and #6; without it they degrade
gracefully to packet-boundary timing.

**Earliest usable version of hwt integration**: end of H6. That's
`dtlm watch hwt-cpu-profile --pid ... --format otel ...` producing
real OTel metrics and logs on amd64, with function names resolved,
going into a real collector. Spans (H7) and arm64 (H9) ship
thereafter. The full capability catalog from §12 lands at the end
of H13, with H11 shippable independently as "integrate dtlm output
with every existing FreeBSD / Linux profiling tool" — worth a
release on its own.

**Runtime dependency delta** against the dtlm runtime today:
- **`devel/libipt`** (new, system dep, ports: `devel/intel-pt`) —
  pulled only when `IntelPTBackend` is compiled in. Build option.
- **libelf** — already available in base.
- `libopencsd` for CoreSight — arm64 only, Phase H9.
- No new Swift package dependencies.

---

## 15. What's explicitly NOT in v1 of the hwt work

| Removed | Why |
|---|---|
| **DWARF line-number resolution** for PC samples | Function-level is 95% of the value. libdwarf adds ~500 LOC and complicates symbolizer caching. Defer until a user actually asks. |
| **Inline frame expansion** | Same reason. |
| **Unified DTrace-plus-hwt profile in one process** | Same policy as DTrace multi-profile composition in the main `DESIGN.md` — run two `dtlm` processes with different `--service` tags against the same collector. |
| **Span pairing for DTrace profiles** | Unchanged from `DESIGN.md` §15. Only hwt profiles produce spans in v1. |
| **A kernel-side `hwt(8)` userland tool** | Out of scope. dtlm is not replacing any missing upstream userland — it builds directly on `/dev/hwt` ioctls. The missing `hwt(8)` is worth contributing upstream separately, but it's not a dtlm deliverable. |
| **Continuous SPE on amd64** / **Intel PT on arm64** | Hardware gating; the backends do not exist on those platforms. |
| **Ring-3 (non-root) operation** | `/dev/hwt` requires root. Same policy as DTrace — dtlm refuses to start without it and points at `sudo`. |
| **`kgdb(1)` PT-ring replay extension** | Post-v1. Once the `.pt.bin` sidecar format from H13 has stabilized, a gdb Python plugin with `reverse-stepi`/`reverse-continue` becomes achievable. Ambitious but additive. See §13. |
| **`perf.data` output format** | Post-v1. The pprof + folded-stack exporters from H11 already cover 90% of the `perf report` / `hotspot` workflow. Revisit only on user demand. |
| **Full indirect-call CFI whitelisting** | Post-v1. v1 of capability #7 ships return-address sanity only; full indirect-call target whitelisting needs a static-analysis pipeline (LLVM CFI or hand-rolled) that's a separate project. |

---

## 16. Open questions

1. **libipt availability on FreeBSD.** The `devel/intel-pt` port
   tracks upstream Intel reasonably well but is not in the base
   system. The dtlm port will need a build-time option to compile
   out `IntelPTBackend` for users who don't want the dep. Decision:
   default **on** for amd64 packages, **off** for source builds
   that don't set `WITH_HWT_INTEL_PT`.
2. **Symbol cache invalidation across `exec`.** The hwt hook layer
   already emits `exec` records. On `exec`, drop the cached
   `ELFAddressMap` for that pid. Straightforward, just needs
   plumbing.
3. **Buffer-drain pacing.** Intel PT buffers fill fast. The mmap
   ring buffer exposed by `/dev/hwt_*` needs a userland drainer
   running on a dedicated thread at higher-than-default priority,
   or the kernel will overwrite data. Needs a measurement pass on
   real hardware (the FreeBSD ADL-P laptop, per the freebsd-thunderbolt
   bench) once H3 lands.
4. **SPE record format stability.** SPE records are
   micro-architecture-dependent. The in-tree SPE walker needs a
   small amount of per-CPU conditional logic. Manageable, but
   flagged here because H9 is the one phase that can't be tested
   without arm64 hardware.
5. **Span volume.** A hot function called 10⁶ times/sec produces
   10⁶ spans/sec. The OTel exporter already has `--sample 1/N` at
   the framework layer, which applies uniformly. But span sampling
   is semantically different from event sampling (you want
   head-based sampling so the parent/child tree stays consistent).
   Decision: in v1, `--sample 1/N` on hwt span profiles is **head
   sampling at the outermost span**; all descendants of a kept
   parent are kept. ~50 LOC in the span constructor.
6. **Running alongside DTrace.** Nothing in hwt conflicts with
   libdtrace, but the kernel hooks for hwt and dtrace do share
   thread-level state (`td->td_dtrace`). No observed conflict in
   the current tree, but worth a smoke test before declaring H6
   done.

---

## 17. TL;DR

| | |
|---|---|
| **What is it?** | A second telemetry *source* inside dtlm that drives FreeBSD's `hwt(4)` Hardware Trace Framework, decodes Intel PT / CoreSight / SPE buffers, and ships the result as text / JSONL / OTel through the existing dtlm exporters. |
| **Why inside dtlm and not a separate tool?** | dtlm already has the OTel pipeline, resource attribution, auth, graceful shutdown, and `rc.d` wrapper. A standalone `hwt-otel` would reimplement all of it. The sysadmin/developer audience is also identical — hwt's CPU and Thread modes map onto dtlm's two audiences exactly. |
| **What's the architecture seam?** | A new `TelemetrySource` protocol above the Exporter framework. `DTraceSource` is a mechanical extraction of today's run loop; `HWTSource` is new. Exporters are unchanged. |
| **What's the backend seam?** | A `TraceBackend` protocol with three conformances: `IntelPTBackend` (libipt, amd64, Phase H3), `SPEBackend` (in-tree decoder, arm64, Phase H9), `CoreSightBackend` (libopencsd, arm64, Phase H9). |
| **What new CLI is there?** | Four things: `--cpu CPUSET`, `--range START:END@BIN`, `dtlm probes --hwt`, and hwt profile names in `dtlm watch`. That's it. |
| **What new output is there?** | **OTel spans from hwt function entry/exit**, in addition to the existing logs + metrics. hwt is the first real user of the deferred traces signal because PT/CoreSight give you entry/exit pairing natively — no sidecar metadata. |
| **What's bundled?** | Five foundational hwt profiles (§11) plus a capability catalog of eight (§12): `hwt-cpu-profile`, `hwt-system-profile`, `hwt-function-trace`, `hwt-branch-mix`, `hwt-spe-latency`, `hwt-coverage`, `hwt-ringbuffer`, `hwt-latency-attribution`, `hwt-kernel-bench`, `hwt-cfi`, `hwt-hang-analysis`. |
| **What subcommands are new?** | Two beyond the four in `DESIGN.md` §8: **`dtlm replay`** (offline decode of a saved PT ring for capability #4) and **`dtlm diff`** (benchmarking regression detection for capability #6). |
| **What base-system integration?** | libxo-routed text output (composes with every other FreeBSD base tool), folded-stack exporter (`flamegraph.pl`), pprof exporter (Go/Linux profiling ecosystem), gprof exporter (`pmcstat` migration path), savecore / core(5) sidecar hook for saved PT rings. See §13. |
| **What does it depend on?** | `/dev/hwt` in the running kernel (FreeBSD 15.0+), `devel/intel-pt` (libipt, amd64 only, build-option gated), libelf (base), libxo (base), Capstone for static disassembly in capabilities #3 and #7 (`devel/capstone`), libopencsd (arm64 later). No new Swift packages. |
| **How big is it?** | **~5500 LOC of Swift + C shim** across thirteen phases (H1–H13), plus the full capability catalog. Same order of magnitude as the DTrace side of dtlm. Separately, **~20 LOC kernel patch (K1)** upstream to FreeBSD for cycle-accurate timing. |
| **Earliest usable version?** | End of Phase H6. Working `hwt-cpu-profile` on amd64, shipping OTel metrics + logs with resolved function names to a real collector. Phase H11 (output-format expansion) is independently shippable and turns dtlm into a first-class citizen of both the FreeBSD base tooling (libxo) and the Linux profiling ecosystem (pprof, folded, gprof). Full capability catalog at H13. |
| **Killer feature?** | Continuous, zero-overhead, full-fidelity CPU profiling on FreeBSD that lands in the same OTel collector as the rest of your observability data. "parca-agent for FreeBSD" via the hardware unit the CPU already has. |
| **What's deferred?** | DWARF line numbers, inline frame expansion, unified DTrace+hwt in one process, retained buffers for post-mortem replay, arm64 (H9 is later but not blocking amd64 ship). |
| **License?** | BSD-2-Clause, same as the rest of dtlm. |
