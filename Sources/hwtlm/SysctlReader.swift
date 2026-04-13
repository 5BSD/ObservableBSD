/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Architecture: portable. All data comes from FreeBSD sysctls
// that work on any architecture with the appropriate kernel
// drivers loaded (coretemp, cpufreq, acpi_thermal, drm).

import Foundation
import FreeBSDKit

// MARK: - Sysctl reader

/// Reads system telemetry from FreeBSD sysctls: per-core temperature
/// and frequency, C-state residency, ACPI thermal zones, and GPU
/// state. Uses FreeBSDKit's BSDSysctl for all kernel queries.
enum SysctlReader {

    // MARK: - Per-core data

    /// Per-core temperature in °C. Requires `kldload coretemp`.
    ///
    /// The kernel stores temperatures as deciKelvin (Int32).
    /// e.g. 3301 → 57.0°C (3301 / 10 - 273.15).
    static func coreTemperatures(cpuCount: Int) -> [Int: Double] {
        var temps: [Int: Double] = [:]
        for cpu in 0..<cpuCount {
            if let deciK: Int32 = try? BSDSysctl.get("dev.cpu.\(cpu).temperature") {
                temps[cpu] = Double(deciK) / 10.0 - 273.15
            }
        }
        return temps
    }

    /// Per-core frequency in MHz (Int32).
    static func coreFrequencies(cpuCount: Int) -> [Int: Int] {
        var freqs: [Int: Int] = [:]
        for cpu in 0..<cpuCount {
            if let mhz: Int32 = try? BSDSysctl.get("dev.cpu.\(cpu).freq") {
                freqs[cpu] = Int(mhz)
            }
        }
        return freqs
    }

    /// Per-core TjMax in °C.
    static func coreTjMax(cpu: Int = 0) -> Double? {
        guard let deciK: Int32 = try? BSDSysctl.get("dev.cpu.\(cpu).coretemp.tjmax") else {
            return nil
        }
        return Double(deciK) / 10.0 - 273.15
    }

    /// Per-core throttle log and aggregate flag in one pass.
    static func throttleLog(cpuCount: Int) -> (perCore: [Int: Bool], any: Bool) {
        var perCore: [Int: Bool] = [:]
        var any = false
        for cpu in 0..<cpuCount {
            if let val: Int32 = try? BSDSysctl.get("dev.cpu.\(cpu).coretemp.throttle_log") {
                let throttled = val != 0
                perCore[cpu] = throttled
                if throttled { any = true }
            }
        }
        return (perCore, any)
    }

    // MARK: - C-state data

    /// Read C-state info for all CPUs. All cx_* sysctls are
    /// STRING-typed and require parsing via CStateParser.
    static func cstateInfo(cpuCount: Int) -> [Int: CStateInfo] {
        var result: [Int: CStateInfo] = [:]
        for cpu in 0..<cpuCount {
            let supported: [CStateLevel]
            if let s = try? BSDSysctl.getString("dev.cpu.\(cpu).cx_supported") {
                supported = CStateParser.parseSupported(s)
            } else {
                continue // No C-state support on this CPU
            }

            let residency: CStateResidency?
            if let s = try? BSDSysctl.getString("dev.cpu.\(cpu).cx_usage") {
                residency = CStateParser.parseUsage(s)
            } else {
                residency = nil
            }

            let counters: [UInt64]?
            if let s = try? BSDSysctl.getString("dev.cpu.\(cpu).cx_usage_counters") {
                counters = CStateParser.parseUsageCounters(s)
            } else {
                counters = nil
            }

            let lowest = try? BSDSysctl.getString("dev.cpu.\(cpu).cx_lowest")

            result[cpu] = CStateInfo(
                cpu: cpu,
                supported: supported,
                residency: residency,
                transitionCounts: counters,
                lowestAllowed: lowest?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    // MARK: - ACPI thermal

    /// ACPI thermal zone temperature in °C (deciKelvin in kernel).
    static func acpiTemperature(zone: Int = 0) -> Double? {
        guard let deciK: Int32 = try? BSDSysctl.get("hw.acpi.thermal.tz\(zone).temperature") else {
            return nil
        }
        return Double(deciK) / 10.0 - 273.15
    }

    // MARK: - GPU

    /// GPU actual frequency in MHz (Intel DRM, string-typed sysctl).
    static func gpuFrequency() -> Int? {
        getStringInt("sys.class.drm.card0.gt.gt0.rps_act_freq_mhz")
    }

    /// GPU RC6 (idle) residency in milliseconds.
    static func gpuRC6ResidencyMs() -> Int? {
        getStringInt("sys.class.drm.card0.gt.gt0.rc6_residency_ms")
    }

    /// Whether the GPU is being thermally throttled.
    static func gpuThrottled() -> Bool {
        if let val = getStringInt("sys.class.drm.card0.gt.gt0.throttle_reason_status") {
            return val != 0
        }
        return false
    }

    // MARK: - CPU count

    static func cpuCount() -> Int {
        if let n: Int32 = try? BSDSysctl.get("hw.ncpu") {
            return Int(n)
        }
        return 1
    }

    // MARK: - Aggregate snapshot

    /// A complete system telemetry snapshot.
    struct SystemSnapshot: Sendable {
        let timestamp: Date
        let temperatures: [Int: Double]
        let frequencies: [Int: Int]
        let cstates: [Int: CStateInfo]
        let perCoreThrottled: [Int: Bool]
        let acpiTemp: Double?
        let tjMax: Double?
        let throttled: Bool
        let gpuFreqMHz: Int?
        let gpuRC6Ms: Int?
        let gpuThrottled: Bool

        var minTemp: Double? { temperatures.values.min() }
        var maxTemp: Double? { temperatures.values.max() }
        var avgTemp: Double? {
            guard !temperatures.isEmpty else { return nil }
            return temperatures.values.reduce(0, +) / Double(temperatures.count)
        }
        var minFreq: Int? { frequencies.values.min() }
        var maxFreq: Int? { frequencies.values.max() }
        var avgFreq: Int? {
            guard !frequencies.isEmpty else { return nil }
            return frequencies.values.reduce(0, +) / frequencies.count
        }

        /// Ordered per-core snapshots.
        var cores: [CoreSnapshot] {
            let cpuIDs = Set(temperatures.keys)
                .union(frequencies.keys)
                .union(cstates.keys)
                .sorted()
            return cpuIDs.map { cpu in
                CoreSnapshot(
                    cpu: cpu,
                    temperatureC: temperatures[cpu],
                    frequencyMHz: frequencies[cpu],
                    cstate: cstates[cpu],
                    throttled: perCoreThrottled[cpu] ?? false
                )
            }
        }
    }

    /// Take a complete system telemetry snapshot.
    static func snapshot(cpuCount: Int) -> SystemSnapshot {
        let throttle = throttleLog(cpuCount: cpuCount)
        return SystemSnapshot(
            timestamp: Date(),
            temperatures: coreTemperatures(cpuCount: cpuCount),
            frequencies: coreFrequencies(cpuCount: cpuCount),
            cstates: cstateInfo(cpuCount: cpuCount),
            perCoreThrottled: throttle.perCore,
            acpiTemp: acpiTemperature(),
            tjMax: coreTjMax(),
            throttled: throttle.any,
            gpuFreqMHz: gpuFrequency(),
            gpuRC6Ms: gpuRC6ResidencyMs(),
            gpuThrottled: gpuThrottled()
        )
    }

    // MARK: - Helpers

    private static func getStringInt(_ name: String) -> Int? {
        guard let s = try? BSDSysctl.getString(name) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
