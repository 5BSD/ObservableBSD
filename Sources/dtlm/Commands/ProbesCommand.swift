/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser
import DTraceCore
import Foundation

// MARK: - dtlm probes

/// `dtlm probes` — list every DTrace probe (built-in or USDT) the
/// kernel currently knows about.
///
/// Filters by provider, by regex on the full name, or by attaching to
/// a specific PID first (which is what surfaces a process's USDT
/// providers). This is the discovery story for application developers
/// shipping USDT probes.
struct ProbesCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "probes",
        abstract: "List DTrace probes available on this system, including USDT.",
        discussion: """
            Requires root, like everything that opens a libdtrace handle. \
            With --provider, restrict to one provider's probes. With \
            --pid, attach to that process first so its USDT providers \
            show up. With --regex, post-filter the names. --json emits \
            one record per probe so you can pipe to jq.
            """
    )

    @Option(
        name: .long,
        help: "Restrict to one provider (e.g. syscall, fbt, tcp, mywebapp)."
    )
    var provider: String?

    @Option(
        name: .long,
        help: "Restrict to probes whose full name matches this regular expression."
    )
    var regex: String?

    @Option(
        name: .long,
        help: "Attach to this PID first so its USDT providers are visible."
    )
    var pid: Int32?

    @Flag(
        name: .long,
        help: "Emit one JSONL record per probe instead of a text table."
    )
    var json: Bool = false

    func run() throws {
        // Compile the regex up front so a bad pattern fails before we
        // open a libdtrace handle.
        let pattern: NSRegularExpression?
        if let regex {
            do {
                pattern = try NSRegularExpression(pattern: regex)
            } catch {
                throw ValidationError("Invalid --regex pattern: \(error)")
            }
        } else {
            pattern = nil
        }

        let handle: DTraceHandle
        do {
            handle = try DTraceHandle.open()
        } catch {
            FileHandle.standardError.write(Data(
                "dtlm probes: failed to open libdtrace (\(error)). Are you root?\n".utf8
            ))
            throw ExitCode.failure
        }

        // We need to keep the ProcessHandle alive across listProbes
        // so its USDT providers stay loaded into the libdtrace
        // handle. Use a Holder so the ~Copyable proc handle outlives
        // its enclosing scope.
        let listingPattern = provider.map { "\($0):::" }
        let probes: [DTraceProbeDescription]
        do {
            if let pid {
                let proc = try handle.grabProcess(pid: pid)
                probes = try handle.listProbes(matching: listingPattern)
                _ = consume proc   // explicit lifetime extension
            } else {
                probes = try handle.listProbes(matching: listingPattern)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "dtlm probes: listProbes failed: \(error)\n".utf8
            ))
            throw ExitCode.failure
        }

        // Apply the regex post-filter ourselves.
        let filtered: [DTraceProbeDescription]
        if let pattern {
            filtered = probes.filter { probe in
                let full = probe.fullName
                let range = NSRange(full.startIndex..<full.endIndex, in: full)
                return pattern.firstMatch(in: full, range: range) != nil
            }
        } else {
            filtered = probes
        }

        if json {
            try emitJSONL(filtered)
        } else {
            emitTable(filtered)
        }
    }

    private func emitTable(_ probes: [DTraceProbeDescription]) {
        for probe in probes {
            print(probe.fullName)
        }
        FileHandle.standardError.write(Data(
            "\n\(probes.count) probe\(probes.count == 1 ? "" : "s")\n".utf8
        ))
    }

    private func emitJSONL(_ probes: [DTraceProbeDescription]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for probe in probes {
            let row = ProbeRow(
                id: probe.id,
                provider: probe.provider,
                module: probe.module,
                function: probe.function,
                name: probe.name,
                fullName: probe.fullName
            )
            let data = try encoder.encode(row)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private struct ProbeRow: Encodable {
        let id: UInt32
        let provider: String
        let module: String
        let function: String
        let name: String
        let fullName: String
    }
}
