/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser
import Foundation
import Glibc
import OTelExport

// MARK: - hwtlm exec

/// `hwtlm exec` — run a command and report energy consumed and
/// temperature delta across the run.
struct ExecCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a command and report its energy and thermal impact.",
        discussion: """
            Reads RAPL energy counters and temperatures before and \
            after running the given command, then reports totals. \
            Works without RAPL (shows temps only). Requires root \
            for RAPL readings.

            Use '--' to separate hwtlm flags from the command:
              hwtlm exec --format json -- make -j8
            """
    )

    @Option(name: .customLong("format"), help: "Output format: text (default) or json.")
    var format: String = "text"

    @Flag(name: .customLong("per-core"), help: "Show per-core temperature deltas.")
    var perCore: Bool = false

    @Argument(parsing: .captureForPassthrough, help: "The command to run (after --).")
    var command: [String]

    private var args: [String] {
        if command.first == "--" { return Array(command.dropFirst()) }
        return command
    }

    func validate() throws {
        if args.isEmpty {
            throw ValidationError("provide a command to run after '--'")
        }
        if format != "text" && format != "json" {
            throw ValidationError("--format must be 'text' or 'json'")
        }
    }

    func run() throws {
        let cpuCount = CpuctlReader.detectCPUCount()
        let rapl = RAPLSampler()

        // Snapshot before
        let beforeCounters = try? rapl?.readCounters()
        let beforeSys = SysctlReader.snapshot(cpuCount: cpuCount)
        let beforeTime = Date()

        // Run the child process
        let exitCode = runChild(args)

        // Snapshot after
        let afterCounters = try? rapl?.readCounters()
        let afterSys = SysctlReader.snapshot(cpuCount: cpuCount)
        let afterTime = Date()
        let elapsed = afterTime.timeIntervalSince(beforeTime)

        // Compute RAPL energy deltas
        var powerResults: [(domain: RAPLDomain, joules: Double, watts: Double)] = []
        if let rapl, let before = beforeCounters, let after = afterCounters {
            for domain in rapl.domains {
                guard let b = before[domain], let a = after[domain] else { continue }
                let delta: UInt64 = a >= b ? a - b : (0x1_0000_0000 - b) + a
                let joules = rapl.units.joules(rawDelta: delta, domain: domain)
                let watts = elapsed > 0 ? joules / elapsed : 0
                powerResults.append((domain: domain, joules: joules, watts: watts))
            }
        }

        if format == "json" {
            emitJSON(power: powerResults, beforeSys: beforeSys, afterSys: afterSys,
                     elapsed: elapsed, exitCode: exitCode, rapl: rapl)
        } else {
            emitText(power: powerResults, beforeSys: beforeSys, afterSys: afterSys,
                     elapsed: elapsed, exitCode: exitCode, rapl: rapl, cpuCount: cpuCount)
        }

        if exitCode != 0 { throw ExitCode(Int32(exitCode)) }
    }

    // MARK: - Child process

    private func runChild(_ args: [String]) -> Int32 {
        let pid = fork()
        if pid == 0 {
            let cArgs = args.map { strdup($0) } + [nil]
            execvp(cArgs[0], cArgs)
            perror("hwtlm exec: \(args[0])")
            _exit(127)
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        if (status & 0x7F) == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }

    // MARK: - Text output

    private func emitText(
        power: [(domain: RAPLDomain, joules: Double, watts: Double)],
        beforeSys: SysctlReader.SystemSnapshot,
        afterSys: SysctlReader.SystemSnapshot,
        elapsed: Double,
        exitCode: Int32,
        rapl: RAPLSampler?,
        cpuCount: Int
    ) {
        if let rapl {
            FileHandle.standardError.write(Data("\nCPU: \(rapl.microarch.rawValue)\n".utf8))
        }
        FileHandle.standardError.write(Data("Elapsed: \(String(format: "%.3f", elapsed))s\n".utf8))
        if exitCode != 0 {
            FileHandle.standardError.write(Data("Exit code: \(exitCode)\n".utf8))
        }

        // Temperature summary or per-core
        if perCore {
            FileHandle.standardError.write(Data("\n".utf8))
            let beforeCores = beforeSys.cores
            let afterCores = afterSys.cores
            for after in afterCores {
                let before = beforeCores.first { $0.cpu == after.cpu }
                guard let afterTemp = after.temperatureC else { continue }
                let beforeTemp = before?.temperatureC ?? afterTemp
                let delta = afterTemp - beforeTemp
                let sign = delta >= 0 ? "+" : ""
                FileHandle.standardError.write(Data(
                    "CPU \(String(format: "%2d", after.cpu)): \(String(format: "%4.0f", beforeTemp))°C → \(String(format: "%4.0f", afterTemp))°C (\(sign)\(String(format: "%.0f", delta))°C)\n".utf8
                ))
            }
        } else {
            if let before = beforeSys.maxTemp, let after = afterSys.maxTemp {
                let delta = after - before
                let sign = delta >= 0 ? "+" : ""
                FileHandle.standardError.write(Data(
                    "Temp: \(String(format: "%.0f", before))°C → \(String(format: "%.0f", after))°C (\(sign)\(String(format: "%.0f", delta))°C)\n".utf8
                ))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))

        // Power table
        if !power.isEmpty {
            let nameWidth = max(10, power.map(\.domain.rawValue.count).max() ?? 10)
            let header = "\(pad("DOMAIN", nameWidth))  \(pad("ENERGY (J)", 12))  \(pad("AVG POWER (W)", 14))"
            print(header)
            print(String(repeating: "─", count: header.count))

            var totalJoules = 0.0
            for r in power {
                print("\(pad(r.domain.rawValue, nameWidth))  \(String(format: "%10.3f", r.joules))  \(String(format: "%12.3f", r.watts))")
                if r.domain == .package { totalJoules = r.joules }
            }
            print()
            if totalJoules > 0 {
                print("Total package energy: \(String(format: "%.3f", totalJoules)) J")
            }
        } else {
            print("(RAPL not available — no energy data)")
        }
    }

    // MARK: - JSON output

    private func emitJSON(
        power: [(domain: RAPLDomain, joules: Double, watts: Double)],
        beforeSys: SysctlReader.SystemSnapshot,
        afterSys: SysctlReader.SystemSnapshot,
        elapsed: Double,
        exitCode: Int32,
        rapl: RAPLSampler?
    ) {
        var parts: [String] = []
        parts.append("\"command\":\"\(escapeJSON(args.joined(separator: " ")))\"")
        parts.append("\"elapsed_seconds\":\(String(format: "%.6f", elapsed))")
        parts.append("\"exit_code\":\(exitCode)")

        if perCore {
            var coreParts: [String] = []
            let beforeCores = beforeSys.cores
            for after in afterSys.cores {
                let before = beforeCores.first { $0.cpu == after.cpu }
                var fields: [String] = []
                fields.append("\"cpu\":\(after.cpu)")
                if let bt = before?.temperatureC { fields.append("\"temp_before\":\(String(format: "%.1f", bt))") }
                if let at = after.temperatureC { fields.append("\"temp_after\":\(String(format: "%.1f", at))") }
                if let bf = before?.frequencyMHz { fields.append("\"freq_before\":\(bf)") }
                if let af = after.frequencyMHz { fields.append("\"freq_after\":\(af)") }
                coreParts.append("{\(fields.joined(separator: ","))}")
            }
            parts.append("\"cores\":[\(coreParts.joined(separator: ","))]")
        } else {
            if let before = beforeSys.maxTemp { parts.append("\"temp_before\":\(String(format: "%.1f", before))") }
            if let after = afterSys.maxTemp { parts.append("\"temp_after\":\(String(format: "%.1f", after))") }
        }

        if !power.isEmpty {
            var domainParts: [String] = []
            for r in power {
                domainParts.append(
                    "{\"\(r.domain.rawValue)\":{\"joules\":\(String(format: "%.6f", r.joules)),\"watts\":\(String(format: "%.6f", r.watts))}}"
                )
            }
            parts.append("\"domains\":[\(domainParts.joined(separator: ","))]")
        }

        print("{" + parts.joined(separator: ",") + "}")
    }

    private func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }
}
