/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Architecture: x86-only at runtime. Intel RAPL energy counters.
// On non-Intel or without cpuctl, init?() returns nil gracefully.

import Foundation
import Glibc

// MARK: - Sample types

/// 32-bit RAPL counter delta with rollover handling.
func raplCounterDelta(_ cur: UInt64, _ prev: UInt64) -> UInt64 {
    cur >= prev ? cur - prev : (0x1_0000_0000 - prev) + cur
}

/// One power reading for a single domain at a single point in time.
struct RAPLSample: Sendable {
    let cpu: Int
    let domain: RAPLDomain
    let timestamp: Date
    let joules: Double
    let elapsed: Double
    var watts: Double { elapsed > 0 ? joules / elapsed : 0 }
}

/// A complete snapshot across all domains for one sampling interval.
struct RAPLSnapshot: Sendable {
    let timestamp: Date
    let samples: [RAPLSample]
}

// MARK: - RAPLSampler

/// Reads RAPL energy counters at a configurable interval and
/// produces `RAPLSnapshot` values with per-domain power in watts.
/// Returns nil from `init?()` if RAPL is not available (non-Intel,
/// cpuctl not loaded, unknown model).
final class RAPLSampler {
    let microarch: IntelMicroarch
    let domains: [RAPLDomain]
    let units: RAPLPowerUnit

    private let packageCPU: Int = 0
    private var previous: [RAPLDomain: UInt64] = [:]
    private var previousTime: Date?

    /// Returns nil if RAPL is not available on this system.
    init?() {
        guard let arch = CpuctlReader.detectMicroarch() else {
            return nil
        }
        self.microarch = arch
        self.domains = arch.supportedDomains

        guard let reader = try? CpuctlReader(cpu: packageCPU),
              let rawUnit = try? reader.readMSR(MSR.raplPowerUnit) else {
            return nil
        }
        self.units = RAPLPowerUnit(
            raw: rawUnit,
            usesFixedDRAMUnit: arch.usesFixedDRAMUnit
        )
    }

    /// Read the current raw energy counters for all supported domains.
    func readCounters() throws -> [RAPLDomain: UInt64] {
        let reader = try CpuctlReader(cpu: packageCPU)
        var counters: [RAPLDomain: UInt64] = [:]
        for domain in domains {
            let raw = try reader.readMSR(domain.energyMSR)
            counters[domain] = raw & 0xFFFF_FFFF
        }
        return counters
    }

    /// Take a single snapshot. First call primes and returns nil.
    func sampleOnce() throws -> RAPLSnapshot? {
        let now = Date()
        let counters = try readCounters()

        defer {
            previous = counters
            previousTime = now
        }

        guard let prevTime = previousTime else {
            return nil
        }

        let elapsed = now.timeIntervalSince(prevTime)
        var samples: [RAPLSample] = []

        for domain in domains {
            guard let cur = counters[domain],
                  let prev = previous[domain] else { continue }

            let delta = raplCounterDelta(cur, prev)

            let joules = units.joules(rawDelta: delta, domain: domain)

            samples.append(RAPLSample(
                cpu: packageCPU,
                domain: domain,
                timestamp: now,
                joules: joules,
                elapsed: elapsed
            ))
        }

        return RAPLSnapshot(timestamp: now, samples: samples)
    }

    /// Sample at the given interval until the deadline (or forever
    /// if nil). The deadline is a wall-clock bound — the loop stops
    /// after the first sample whose timestamp exceeds it.
    func run(
        deadline: Date?,
        intervalSeconds: Double = 1.0,
        handler: (RAPLSnapshot) throws -> Void
    ) throws {
        _ = try sampleOnce()

        let intervalMicros = useconds_t(intervalSeconds * 1_000_000)

        while true {
            usleep(intervalMicros)
            guard let snapshot = try sampleOnce() else { continue }
            try handler(snapshot)
            if let deadline, Date() >= deadline { break }
        }
    }

    /// Read the package power info register (TDP, min/max power).
    func readPowerInfo() throws -> PowerInfo {
        let reader = try CpuctlReader(cpu: packageCPU)
        let raw = try reader.readMSR(MSR.pkgPowerInfo)
        return PowerInfo(raw: raw, powerUnit: units.powerUnit)
    }
}

// MARK: - Power info

struct PowerInfo: Sendable {
    let thermalSpecPower: Double
    let minimumPower: Double
    let maximumPower: Double

    init(raw: UInt64, powerUnit: Double) {
        self.thermalSpecPower = Double(raw & 0x7FFF) * powerUnit
        self.minimumPower     = Double((raw >> 16) & 0x7FFF) * powerUnit
        self.maximumPower     = Double((raw >> 32) & 0x7FFF) * powerUnit
    }
}
