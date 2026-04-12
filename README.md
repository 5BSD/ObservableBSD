# ObservableBSD

**Convert FreeBSD's instrumentation surface to OpenTelemetry telemetry.**

ObservableBSD is the umbrella project for tools that bridge
FreeBSD-native instrumentation — DTrace probes, hardware-trace
frameworks, kernel counters, log streams — into the modern
observability stack via OpenTelemetry. It exists because FreeBSD
has rich instrumentation built into the kernel and almost nothing
between it and Grafana / Tempo / Loki / Datadog / etc.

The first (and currently only) executable in the package is
[`dtlm`](#dtlm), which handles the DTrace half of that gap. As
ObservableBSD grows, additional sources and shared infrastructure
will land in this same Swift package as new targets — FreeBSDKit
style.

---

## What's in the package today

| Target | Kind | Purpose | Status |
|---|---|---|---|
| `dtlm` | executable | DTrace → OTel telemetry CLI. Apple Instruments-equivalent profile catalog, structured output (text / JSONL / OTLP), stack capture, USDT discovery. | Phase 1 complete (99 bundled profiles, 54 tests, full dwatch parity verified against live kernel) |

## What's planned

| Target | Kind | Purpose | When |
|---|---|---|---|
| `dtlm` (HWT integration) | inside the `dtlm` executable | Add the FreeBSD `hwt(4)` Hardware Trace Framework as a second `TelemetrySource` next to libdtrace, sharing dtlm's existing Exporter framework, OTel push, resource attribution, and `rc.d/dtlm` wrapper. See [`DESIGN-HWT.md`](./DESIGN-HWT.md) for the architecture. | Post-v1 of the DTrace path |
| `ObservableBSDCore` (tentative name) | library | If/when a second tool is added, the Exporter framework, OTel encoders, and resource attribution helpers are extracted from `dtlm` into a shared library that other ObservableBSD tools depend on. | When the second tool needs them |
| Future tools (TBD) | executables | Possible future telemetry sources include syslog/log-file tailers, sysctl-based metric exporters, and an `hwpmc(4)` hardware-perf-counter exporter. None are committed work — they're the natural shape if there's user demand. | Speculative |

The point of the umbrella is that **the OTel pipeline only gets
built once.** Every new ObservableBSD telemetry source plugs into
the same Exporter framework, the same `--format text|json|otel`
flags, the same `--service`/`--instance` resource attribution,
the same `rc.d` wrapper, the same documentation conventions.

---

## dtlm

**Apple Instruments for FreeBSD, with OpenTelemetry output.**

`dtlm` bundles a catalog of DTrace-backed profiling templates
equivalent to Instruments' Time Profiler, System Trace, File
Activity, Network Activity, Allocations, Thread States, and Lock
Contention — for both kernel events and your own USDT-instrumented
applications — and ships the results as text, JSONL, or
OTLP/HTTP+JSON to your existing OpenTelemetry collector with stack
traces attached.

It exists because FreeBSD has DTrace and nothing between it and the
modern observability stack: no Instruments-equivalent profiling
catalog, no OTel data source, no continuous-profiling story.

See [`DESIGN.md`](./DESIGN.md) for the full dtlm/DTrace design and
[`DESIGN-HWT.md`](./DESIGN-HWT.md) for the planned hardware-trace
integration.

### How dtlm profiles work

A profile is a `.d` file. Filename = profile name. The first
`/* … */` comment is the description. An optional
`/* @dtlm-predicate */` marker is where dtlm injects CLI filter
predicates. `${param}` placeholders get substituted from
`--param key=value` flags. Everything else is plain D, handed to
libdtrace verbatim.

Profiles load from three places, scanned in order with shadowing:

1. **Bundled SwiftPM resources** inside the `dtlm` binary —
   ~99 profiles covering full dwatch parity plus the Apple
   Instruments umbrella set, always present
2. **`/usr/local/share/dtlm/profiles/`** — system, where the
   FreeBSD port drops the rest of the catalog
3. **`~/.dtlm/profiles/`** — per-user

There is **no** JSON profile format, no Codable schema, no DBlocks
runtime dependency. dtlm uses `DTraceCore` (the libdtrace bindings
in FreeBSDKit) directly. Adding a profile is a one-file drop.

### dtlm status

**Phase 1 complete.** ~99 bundled profiles, full dwatch parity
verified end-to-end against a live FreeBSD 15 kernel via libdtrace,
54 unit + integration tests passing, the `Exporter` framework in
place with `TextExporter` as the first conformance, ANSI color
when stdout is a TTY, marker-based filter injection, `${param}`
substitution, `--with-stack` / `--with-ustack` plumbed through,
`--duration` tick injection, sub-second per-subprocess timeout in
the integration test sweep.

Subsequent phases:

- **Phase 2**: `JSONLExporter` + sampling
- **Phase 3**: `OTLPHTTPJSONExporter` (logs + typed metrics + stacks
  + auth + traceparent + resource attribution + graceful shutdown)
- **Phase 4**: ~25 more bundled system profiles
- **Phase 5**: ~15-20 application/USDT profiles
- **Phase 6**: `rc.d/dtlm` wrapper
- **Phase 7**: `Scripts/regen_catalog.swift` + FreeBSD port
  packaging for the full ~296-profile `DBlocks.Dwatch` catalog
- **Post-v1**: hwt(4) integration per `DESIGN-HWT.md`

---

## Requirements

- FreeBSD 13.0 or later
- Swift 6.3 or later
- DTrace enabled in the running kernel (default on `GENERIC`)
- Root or `sudo` to actually run probes (libdtrace requires it)

## Building

```sh
swift build
```

The dtlm binary lands at `.build/debug/dtlm`.

## Quick start

```sh
# List every bundled profile
.build/debug/dtlm list

# Print the rendered D source for a profile (no root needed)
.build/debug/dtlm generate kill

# Watch every kill(2) syscall (Ctrl-C or --duration to stop)
sudo .build/debug/dtlm watch kill

# Watch every open() from nginx, for 60 seconds
sudo .build/debug/dtlm watch open --execname nginx --duration 60

# Run a kinst probe with parameter substitution
sudo .build/debug/dtlm watch kinst --param func=vm_fault --param offset=4 --duration 30

# Run an arbitrary .d file
sudo .build/debug/dtlm watch -f /path/to/myscript.d

# Discover DTrace probes (USDT included if --pid is given)
sudo .build/debug/dtlm probes --provider tcp
```

## Testing

```sh
# Unit + structural tests (no root required)
swift test

# Full integration sweep, including the libdtrace compile-check
# of every bundled profile (requires root)
sudo swift test

# After running tests as root, restore .build ownership
sudo chown -R $(id -un):$(id -gn) .build
```

## License

BSD-2-Clause.
