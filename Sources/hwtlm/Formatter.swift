/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Architecture: portable. No hardware dependencies.

import Foundation
import OTelExport

// MARK: - Output formatting

/// Formats hardware telemetry snapshots for display.
enum HWFormatter {

    // MARK: - Summary text output

    static func textHeader(raplDomains: [RAPLDomain]) -> String {
        var line = pad("TIME", 12)
        for domain in raplDomains {
            line += "  " + pad(domain.rawValue.uppercased() + " (W)", 14)
        }
        line += "  " + pad("TEMP (°C)", 10)
        line += "  " + pad("FREQ (MHz)", 11)
        return line
    }

    static func textSeparator(raplDomains: [RAPLDomain]) -> String {
        let width = 12 + raplDomains.count * 16 + 10 + 11 + 4
        return String(repeating: "─", count: width)
    }

    static func textRow(
        rapl: RAPLSnapshot?,
        sys: SysctlReader.SystemSnapshot
    ) -> String {
        var line = pad(timeStr(sys.timestamp), 12)

        if let rapl {
            for sample in rapl.samples {
                line += "  " + pad(String(format: "%8.3f", sample.watts), 14)
            }
        }

        if let max = sys.maxTemp {
            line += "  " + pad(String(format: "%5.0f", max), 10)
        } else {
            line += "  " + pad("--", 10)
        }
        if let max = sys.maxFreq {
            line += "  " + pad(String(format: "%5d", max), 11)
        } else {
            line += "  " + pad("--", 11)
        }
        return line
    }

    // MARK: - Per-core text output

    static func perCoreTextBlock(
        rapl: RAPLSnapshot?,
        sys: SysctlReader.SystemSnapshot
    ) -> String {
        var out = "── \(timeStr(sys.timestamp)) "
        out += String(repeating: "─", count: 50)
        out += "\n"

        // Determine C-state column names from first core that has them
        let cstateNames: [String]
        if let first = sys.cores.first(where: { $0.cstate != nil }),
           let cstate = first.cstate {
            cstateNames = cstate.supported.map(\.name)
        } else {
            cstateNames = []
        }

        // Header
        out += pad("CPU", 4)
        out += "  " + pad("TEMP", 5)
        out += "  " + pad("FREQ", 5)
        for name in cstateNames {
            out += "  " + pad(name + "%", 7)
        }
        out += "\n"

        // Per-core rows
        for core in sys.cores {
            out += pad(String(format: "%3d", core.cpu), 4)

            if let temp = core.temperatureC {
                out += "  " + pad(String(format: "%4.0f", temp), 5)
            } else {
                out += "  " + pad("  --", 5)
            }

            if let freq = core.frequencyMHz {
                out += "  " + pad(String(format: "%5d", freq), 5)
            } else {
                out += "  " + pad("   --", 5)
            }

            if let cstate = core.cstate, let residency = cstate.residency {
                for (i, _) in cstateNames.enumerated() {
                    if i < residency.percentages.count {
                        out += "  " + pad(String(format: "%5.1f", residency.percentages[i]), 7)
                    } else {
                        out += "  " + pad("   --", 7)
                    }
                }
            } else {
                for _ in cstateNames {
                    out += "  " + pad("   --", 7)
                }
            }

            out += "\n"
        }

        // RAPL summary line if available
        if let rapl {
            out += "\n"
            for sample in rapl.samples {
                out += "  \(sample.domain.rawValue): \(String(format: "%.1f", sample.watts))W"
            }
            out += "\n"
        }

        return out
    }

    // MARK: - Summary JSON output

    static func jsonLine(
        rapl: RAPLSnapshot?,
        sys: SysctlReader.SystemSnapshot
    ) -> String {
        var parts: [String] = []
        parts.append("\"time\":\"\(iso8601(sys.timestamp))\"")

        if let rapl {
            for sample in rapl.samples {
                let key = escapeJSON(sample.domain.rawValue)
                parts.append("\"\(key)_watts\":\(String(format: "%.6f", sample.watts))")
                parts.append("\"\(key)_joules\":\(String(format: "%.6f", sample.joules))")
            }
        }

        if let max = sys.maxTemp { parts.append("\"temp_max\":\(String(format: "%.1f", max))") }
        if let avg = sys.avgTemp { parts.append("\"temp_avg\":\(String(format: "%.1f", avg))") }
        if let max = sys.maxFreq { parts.append("\"freq_max_mhz\":\(max)") }
        if let avg = sys.avgFreq { parts.append("\"freq_avg_mhz\":\(avg)") }
        if let gpu = sys.gpuFreqMHz { parts.append("\"gpu_freq_mhz\":\(gpu)") }

        return "{" + parts.joined(separator: ",") + "}"
    }

    // MARK: - Per-core JSON output

    static func perCoreJsonLine(
        rapl: RAPLSnapshot?,
        sys: SysctlReader.SystemSnapshot
    ) -> String {
        var parts: [String] = []
        parts.append("\"time\":\"\(iso8601(sys.timestamp))\"")

        // Per-core array
        var coreParts: [String] = []
        for core in sys.cores {
            var fields: [String] = []
            fields.append("\"cpu\":\(core.cpu)")
            if let temp = core.temperatureC {
                fields.append("\"temp\":\(String(format: "%.1f", temp))")
            }
            if let freq = core.frequencyMHz {
                fields.append("\"freq_mhz\":\(freq)")
            }
            if let cstate = core.cstate, let residency = cstate.residency {
                var csParts: [String] = []
                for (i, level) in cstate.supported.enumerated() {
                    if i < residency.percentages.count {
                        csParts.append("\"\(escapeJSON(level.name))\":\(String(format: "%.2f", residency.percentages[i]))")
                    }
                }
                fields.append("\"cstate\":{\(csParts.joined(separator: ","))}")
            }
            coreParts.append("{\(fields.joined(separator: ","))}")
        }
        parts.append("\"cores\":[\(coreParts.joined(separator: ","))]")

        // RAPL summary
        if let rapl {
            for sample in rapl.samples {
                let key = escapeJSON(sample.domain.rawValue)
                parts.append("\"\(key)_watts\":\(String(format: "%.6f", sample.watts))")
            }
        }

        return "{" + parts.joined(separator: ",") + "}"
    }

    // MARK: - Helpers

    private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    // Cached formatters — DateFormatter is expensive to construct
    // and these are called on every sample interval.
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let iso8601Fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static func timeStr(_ date: Date) -> String {
        timeFmt.string(from: date)
    }

    private static func iso8601(_ date: Date) -> String {
        iso8601Fmt.string(from: date)
    }
}
