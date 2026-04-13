# ARM Support in hwtlm

## What works on ARM today

hwtlm's sysctl-based sensors are architecture-agnostic and work on
ARM/aarch64 FreeBSD if the appropriate kernel drivers are loaded:

- **CPU frequencies** — `dev.cpu.N.freq` via cpufreq(4). Works on
  ARM platforms with frequency scaling support (Raspberry Pi,
  Ampere, AWS Graviton).

- **C-state residency** — `dev.cpu.N.cx_usage` via ACPI. Works if
  the platform firmware exposes ACPI C-states.

- **ACPI thermal zones** — `hw.acpi.thermal.tz0.temperature`. Works
  on platforms with ACPI thermal zone support.

- **CPU temperatures** — `dev.cpu.N.temperature`. Requires a
  platform-specific temperature driver (coretemp is Intel-only;
  ARM equivalents depend on the SoC).

## What does NOT work on ARM

**RAPL energy counters** — Intel MSR-based, requires cpuctl(4).
`RAPLSampler.init?()` returns nil on non-Intel systems and all
power/energy columns are omitted. This is correct behavior.

**Intel GPU metrics** — DRM sysctl paths are i915-specific. The
GPU frequency and throttle readings will return nil on ARM.

## Path to ARM power monitoring

FreeBSD 15.0 has partial SCMI (System Control and Management
Interface) support in `sys/dev/firmware/arm/`:

- SCMI core transport layer (mailbox, SMC, VirtIO) — **present**
- SCMI Clock protocol — **implemented** (`scmi_clk.c`)
- SCMI Sensor protocol (0x15) — **header only, no driver**
- SCMI Power Domain protocol (0x11) — **header only, no driver**
- SCMI Performance protocol (0x13) — **header only, no driver**

When FreeBSD gains SCMI Sensor and Power Domain drivers, hwtlm
can add an `SCMIPowerSampler` that reads power data through
sysctl or device interfaces those drivers expose.

### Suggested architecture for multi-platform power

Extract a `PowerSampler` protocol from `RAPLSampler`'s interface:

```swift
protocol PowerSampler {
    var domains: [String] { get }
    func sampleOnce() throws -> PowerSnapshot?
    func run(count: Int?, intervalSeconds: Double,
             handler: (PowerSnapshot) throws -> Void) throws
}
```

Then provide platform-specific conformances:
- `RAPLSampler: PowerSampler` (Intel x86, via cpuctl MSRs)
- `SCMIPowerSampler: PowerSampler` (ARM, via SCMI — future)

The `WatchCommand` would call `PowerSampler.detect()` which tries
each backend in order and returns the first that succeeds, or nil.

### Other ARM power sources to watch

- **ARM AMU** (Activity Monitors Unit, ARMv8.4) — per-core
  cycle/instruction/stall counters. FreeBSD has no AMU support
  today but Linux does (`CONFIG_ARM64_AMU_EXTN`).

- **CPPC** (Collaborative Processor Performance Control) — requires
  AMU on ARM, not functional in FreeBSD 15.0.

- **Platform PMIC** (Power Management IC) — SoC-specific, accessed
  via I2C/SPI device drivers. No generic FreeBSD interface.
