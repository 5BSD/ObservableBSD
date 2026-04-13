/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Architecture: portable. Pure string parsing, no sysctls or
// hardware dependencies.

// MARK: - C-state types

/// One C-state level (e.g., C1, C2, C3).
struct CStateLevel: Sendable, Equatable {
    /// Name of the state (e.g., "C1", "C2", "C3").
    let name: String
    /// State type number from the kernel.
    let type: Int
    /// Entry latency in microseconds.
    let latencyUs: Int
}

/// Parsed residency percentages for one CPU.
struct CStateResidency: Sendable {
    /// Percentage of time in each C-state (parallel to supported levels).
    let percentages: [Double]
    /// Last idle duration string (e.g., "775us"), if reported.
    let lastDuration: String?
}

/// Complete C-state info for one CPU.
struct CStateInfo: Sendable {
    let cpu: Int
    let supported: [CStateLevel]
    let residency: CStateResidency?
    let transitionCounts: [UInt64]?
    let lowestAllowed: String?
}

// MARK: - Parser

/// Parses FreeBSD C-state sysctl strings into typed values.
///
/// All C-state sysctls are STRING-typed. Formats:
///   cx_supported:       "C1/1/1 C2/2/127 C3/3/1048"
///   cx_usage:           "100.00% 0.00% 0.00% last 775us"
///   cx_usage_counters:  "26644580 0 0"
///   cx_lowest:          "C1"
enum CStateParser {

    /// Parse `dev.cpu.N.cx_supported`.
    /// Format: space-separated tokens of "name/type/latency_us".
    static func parseSupported(_ s: String) -> [CStateLevel] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return trimmed.split(separator: " ").compactMap { token in
            let parts = token.split(separator: "/")
            guard parts.count == 3,
                  let type = Int(parts[1]),
                  let latency = Int(parts[2]) else {
                return nil
            }
            return CStateLevel(
                name: String(parts[0]),
                type: type,
                latencyUs: latency
            )
        }
    }

    /// Parse `dev.cpu.N.cx_usage`.
    /// Format: "100.00% 0.00% 0.00% last 775us"
    /// The trailing "last Xus" is optional.
    static func parseUsage(_ s: String) -> CStateResidency {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CStateResidency(percentages: [], lastDuration: nil)
        }

        let tokens = trimmed.split(separator: " ")
        var percentages: [Double] = []
        var lastDuration: String? = nil

        var i = 0
        while i < tokens.count {
            let token = String(tokens[i])
            if token.hasSuffix("%") {
                let numeric = token.dropLast()
                if let pct = Double(numeric) {
                    percentages.append(pct)
                }
            } else if token == "last" && i + 1 < tokens.count {
                lastDuration = String(tokens[i + 1])
                i += 1 // skip the duration value
            }
            i += 1
        }

        return CStateResidency(
            percentages: percentages,
            lastDuration: lastDuration
        )
    }

    /// Parse `dev.cpu.N.cx_usage_counters`.
    /// Format: "26644580 0 0" (space-separated integers).
    static func parseUsageCounters(_ s: String) -> [UInt64] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: " ").compactMap { UInt64($0) }
    }
}
