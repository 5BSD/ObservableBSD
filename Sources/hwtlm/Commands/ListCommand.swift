/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser
import Foundation
import OTelExport

// MARK: - hwtlm list

struct ListCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show system hardware telemetry capabilities.",
        discussion: """
            Reports CPU identity, RAPL power domains (Intel), \
            per-core temperatures, frequencies, C-state support, \
            ACPI thermal zones, and GPU state. Works on any CPU \
            for sysctl-based sensors; RAPL requires Intel + cpuctl.
            """
    )

    @Option(name: .customLong("format"), help: "Output format: text (default) or json.")
    var format: String = "text"

    @Flag(name: .customLong("per-core"), help: "Show per-core detail instead of summary.")
    var perCore: Bool = false

    func validate() throws {
        if format != "text" && format != "json" {
            throw ValidationError("--format must be 'text' or 'json'")
        }
    }

    func run() throws {
        let cpuCount = CpuctlReader.detectCPUCount()
        let rapl = RAPLSampler()
        let sys = SysctlReader.snapshot(cpuCount: cpuCount)

        if format == "json" {
            emitJSON(rapl: rapl, sys: sys, cpuCount: cpuCount)
        } else {
            emitText(rapl: rapl, sys: sys, cpuCount: cpuCount)
        }
    }

    private func emitText(rapl: RAPLSampler?, sys: SysctlReader.SystemSnapshot, cpuCount: Int) {
        if let arch = rapl?.microarch {
            print("CPU:           \(arch.rawValue)")
        }
        print("Logical CPUs:  \(cpuCount)")
        print()

        // RAPL
        if let rapl {
            print("Energy unit:   \(String(format: "%.6f", rapl.units.energyUnit)) J")
            if let info = try? rapl.readPowerInfo() {
                print("Package TDP:   \(String(format: "%.1f", info.thermalSpecPower)) W")
                if info.minimumPower > 0 { print("Min power:     \(String(format: "%.1f", info.minimumPower)) W") }
                if info.maximumPower > 0 { print("Max power:     \(String(format: "%.1f", info.maximumPower)) W") }
            }
            print()
            print("RAPL domains:")
            let nameWidth = max(10, rapl.domains.map(\.rawValue.count).max() ?? 10)
            print("  \(pad("DOMAIN", nameWidth))  DESCRIPTION")
            print("  " + String(repeating: "─", count: nameWidth + 2 + 30))
            for domain in rapl.domains {
                print("  \(pad(domain.rawValue, nameWidth))  \(domain.label)")
            }
            print()
        } else {
            print("RAPL:          not available (Intel only, needs cpuctl)")
            print()
        }

        // Temperatures
        if perCore {
            print("Per-core temperatures:")
            for core in sys.cores {
                if let temp = core.temperatureC {
                    print("  CPU \(String(format: "%2d", core.cpu)): \(String(format: "%4.0f", temp))°C")
                }
            }
            if sys.throttled {
                print("  (thermal throttling has been logged since boot)")
            }
            print()
        } else {
            if let avg = sys.avgTemp, let min = sys.minTemp, let max = sys.maxTemp {
                print("Core temps:    \(String(format: "%.0f", min))°C min / \(String(format: "%.0f", avg))°C avg / \(String(format: "%.0f", max))°C max")
                if let tjmax = sys.tjMax { print("TjMax:         \(String(format: "%.0f", tjmax))°C") }
                if sys.throttled { print("Throttled:     YES") }
            } else {
                print("Core temps:    not available (try: kldload coretemp)")
            }
        }
        if let acpi = sys.acpiTemp {
            print("ACPI thermal:  \(String(format: "%.1f", acpi))°C")
        }
        print()

        // Frequencies
        if perCore {
            print("Per-core frequencies:")
            for core in sys.cores {
                if let freq = core.frequencyMHz {
                    print("  CPU \(String(format: "%2d", core.cpu)): \(freq) MHz")
                }
            }
            print()
        } else {
            if let avg = sys.avgFreq, let min = sys.minFreq, let max = sys.maxFreq {
                print("Core freq:     \(min) MHz min / \(avg) MHz avg / \(max) MHz max")
            }
        }

        // C-states
        if let firstCS = sys.cores.first(where: { $0.cstate != nil })?.cstate {
            let levels = firstCS.supported.map { "\($0.name) (\($0.latencyUs)µs)" }.joined(separator: "  ")
            print("C-states:      \(levels)")
            if let lowest = firstCS.lowestAllowed {
                print("Lowest:        \(lowest)")
            }

            if perCore {
                print()
                print("Per-core C-state residency:")
                let names = firstCS.supported.map(\.name)
                var header = "  " + pad("CPU", 4)
                for n in names { header += "  " + pad(n + "%", 7) }
                print(header)
                for core in sys.cores {
                    if let cstate = core.cstate, let residency = cstate.residency {
                        var line = "  " + pad(String(format: "%3d", core.cpu), 4)
                        for (i, _) in names.enumerated() {
                            if i < residency.percentages.count {
                                line += "  " + pad(String(format: "%5.1f", residency.percentages[i]), 7)
                            } else {
                                line += "  " + pad("   --", 7)
                            }
                        }
                        print(line)
                    }
                }
            }
            print()
        }

        // GPU
        if let gpuFreq = sys.gpuFreqMHz {
            print("GPU freq:      \(gpuFreq) MHz")
            if sys.gpuThrottled { print("GPU throttle:  YES") }
        }
        print()
    }

    private func emitJSON(rapl: RAPLSampler?, sys: SysctlReader.SystemSnapshot, cpuCount: Int) {
        var parts: [String] = []
        parts.append("\"logical_cpus\":\(cpuCount)")

        if let rapl {
            parts.append("\"cpu\":\"\(escapeJSON(rapl.microarch.rawValue))\"")
            parts.append("\"energy_unit\":\(rapl.units.energyUnit)")
            let domains = rapl.domains.map { d in
                "{\"name\":\"\(escapeJSON(d.rawValue))\",\"label\":\"\(escapeJSON(d.label))\"}"
            }
            parts.append("\"rapl_domains\":[\(domains.joined(separator: ","))]")
            if let info = try? rapl.readPowerInfo() {
                parts.append("\"tdp_watts\":\(String(format: "%.1f", info.thermalSpecPower))")
            }
        } else {
            parts.append("\"rapl_available\":false")
        }

        if let avg = sys.avgTemp, let min = sys.minTemp, let max = sys.maxTemp {
            parts.append("\"temp_min\":\(String(format: "%.1f", min))")
            parts.append("\"temp_avg\":\(String(format: "%.1f", avg))")
            parts.append("\"temp_max\":\(String(format: "%.1f", max))")
            if let tjmax = sys.tjMax { parts.append("\"tjmax\":\(String(format: "%.1f", tjmax))") }
            parts.append("\"throttled\":\(sys.throttled)")
        }
        if let acpi = sys.acpiTemp { parts.append("\"acpi_temp\":\(String(format: "%.1f", acpi))") }
        if let avg = sys.avgFreq, let min = sys.minFreq, let max = sys.maxFreq {
            parts.append("\"freq_min_mhz\":\(min)")
            parts.append("\"freq_avg_mhz\":\(avg)")
            parts.append("\"freq_max_mhz\":\(max)")
        }

        // C-state support
        if let firstCS = sys.cores.first(where: { $0.cstate != nil })?.cstate {
            let levels = firstCS.supported.map { l in
                "{\"name\":\"\(escapeJSON(l.name))\",\"latency_us\":\(l.latencyUs)}"
            }
            parts.append("\"cstates\":[\(levels.joined(separator: ","))]")
        }

        if let gpuFreq = sys.gpuFreqMHz {
            parts.append("\"gpu_freq_mhz\":\(gpuFreq)")
            parts.append("\"gpu_throttled\":\(sys.gpuThrottled)")
        }

        // Per-core array (if requested)
        if perCore {
            var coreParts: [String] = []
            for core in sys.cores {
                var fields: [String] = []
                fields.append("\"cpu\":\(core.cpu)")
                if let temp = core.temperatureC { fields.append("\"temp\":\(String(format: "%.1f", temp))") }
                if let freq = core.frequencyMHz { fields.append("\"freq_mhz\":\(freq)") }
                if let cstate = core.cstate, let residency = cstate.residency {
                    var csParts: [String] = []
                    for (i, level) in cstate.supported.enumerated() where i < residency.percentages.count {
                        csParts.append("\"\(escapeJSON(level.name))\":\(String(format: "%.2f", residency.percentages[i]))")
                    }
                    fields.append("\"cstate\":{\(csParts.joined(separator: ","))}")
                }
                coreParts.append("{\(fields.joined(separator: ","))}")
            }
            parts.append("\"cores\":[\(coreParts.joined(separator: ","))]")
        }

        print("{" + parts.joined(separator: ",") + "}")
    }

    private func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }
}
