/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser
import Foundation
import Glibc
import OTelExport

private nonisolated(unsafe) var signalReceived = false

// MARK: - hwtlm watch

struct WatchCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Sample hardware telemetry and stream it.",
        discussion: """
            Reads RAPL power (Intel), per-core temperatures, \
            frequencies, and C-state residency at the given \
            interval. Works without RAPL on non-Intel CPUs.

            Output formats:
              text  — tabular stdout (default)
              json  — one JSONL object per sample interval
              otel  — OTLP/HTTP gauge metrics to a collector
            """
    )

    @Option(name: .customLong("interval"), help: "Sampling interval in seconds (default: 1.0).")
    var interval: Double = 1.0

    @Option(name: .customLong("duration"), help: "Run for at most this many seconds, then stop.")
    var duration: Double?

    @Flag(name: .customLong("per-core"), help: "Show per-core data instead of summary.")
    var perCore: Bool = false

    @Option(name: .customLong("format"), help: "Output format: text (default), json, or otel.")
    var format: HWOutputFormat = .text

    @Option(name: .customLong("endpoint"), help: "OTLP/HTTP collector base URL (default: http://localhost:4318).")
    var endpoint: String = "http://localhost:4318"

    func validate() throws {
        if interval <= 0 { throw ValidationError("--interval must be positive") }
        if let d = duration, d <= 0 { throw ValidationError("--duration must be positive") }
        if format == .otel {
            guard let url = URL(string: endpoint),
                  url.scheme == "http" || url.scheme == "https" else {
                throw ValidationError("--endpoint must be an http:// or https:// URL")
            }
        }
    }

    func run() throws {
        let cpuCount = CpuctlReader.detectCPUCount()
        let rapl = RAPLSampler()

        let count: Int?
        if let duration { count = max(1, Int(duration / interval)) }
        else { count = nil }

        signalReceived = false
        signal(SIGINT) { _ in signalReceived = true }
        signal(SIGTERM) { _ in signalReceived = true }

        // OTLP exporter
        let otelExporter: OTLPHTTPJSONExporter?
        if format == .otel {
            let otelEnv = OTelEnvironment()
            let resource = ResourceAttributes(
                serviceName: otelEnv.serviceName ?? "hwtlm",
                hostName: HostInfo.hostName,
                hostArch: HostInfo.machineArch,
                osName: "freebsd",
                osVersion: HostInfo.osVersion,
                serviceVersion: "0.1.0",
                custom: otelEnv.resourceAttributes
            )
            let endpointStr = otelEnv.endpoint ?? endpoint
            let timeout = otelEnv.timeoutMs.map { TimeInterval($0) / 1000.0 } ?? 10.0
            let exporter = OTLPHTTPJSONExporter(
                endpoint: URL(string: endpointStr)!,
                profileName: "hardware",
                resource: resource,
                batchSize: 50,
                flushInterval: Double(interval),
                exportTimeout: timeout,
                headers: otelEnv.headers
            )
            try exporter.start()
            otelExporter = exporter
            FileHandle.standardError.write(Data(
                "Exporting to \(endpoint)/v1/metrics\n".utf8
            ))
        } else {
            otelExporter = nil
        }

        // Header
        if format == .text {
            if let rapl {
                FileHandle.standardError.write(Data(
                    "CPU: \(rapl.microarch.rawValue) (\(cpuCount) logical CPUs)\n".utf8
                ))
            } else {
                FileHandle.standardError.write(Data(
                    "\(cpuCount) logical CPUs (RAPL not available)\n".utf8
                ))
            }
            FileHandle.standardError.write(Data(
                "Interval: \(String(format: "%.1f", interval))s\n\n".utf8
            ))
            if !perCore {
                print(HWFormatter.textHeader(raplDomains: rapl?.domains ?? []))
                print(HWFormatter.textSeparator(raplDomains: rapl?.domains ?? []))
            }
        }

        // Sampling loop
        if let rapl {
            do {
                try rapl.run(count: count, intervalSeconds: interval) { snapshot in
                    guard !signalReceived else { throw ExitCode.success }
                    let sys = SysctlReader.snapshot(cpuCount: cpuCount)
                    try emitSample(rapl: snapshot, sys: sys, otel: otelExporter)
                }
            } catch let code as ExitCode where code == .success { }
            catch {
                FileHandle.standardError.write(Data("hwtlm watch: \(error)\n".utf8))
                try? otelExporter?.shutdown()
                throw ExitCode.failure
            }
        } else {
            let intervalMicros = useconds_t(interval * 1_000_000)
            var taken = 0
            do {
                while count == nil || taken < count! {
                    usleep(intervalMicros)
                    guard !signalReceived else { throw ExitCode.success }
                    let sys = SysctlReader.snapshot(cpuCount: cpuCount)
                    try emitSample(rapl: nil, sys: sys, otel: otelExporter)
                    taken += 1
                }
            } catch let code as ExitCode where code == .success { }
            catch {
                FileHandle.standardError.write(Data("hwtlm watch: \(error)\n".utf8))
                try? otelExporter?.shutdown()
                throw ExitCode.failure
            }
        }

        try? otelExporter?.shutdown()
    }

    // MARK: - Emit

    private func emitSample(
        rapl: RAPLSnapshot?,
        sys: SysctlReader.SystemSnapshot,
        otel: OTLPHTTPJSONExporter?
    ) throws {
        switch format {
        case .otel:
            try emitOTLP(rapl: rapl, sys: sys, exporter: otel!)
        case .json:
            if perCore {
                print(HWFormatter.perCoreJsonLine(rapl: rapl, sys: sys))
            } else {
                print(HWFormatter.jsonLine(rapl: rapl, sys: sys))
            }
        case .text:
            if perCore {
                print(HWFormatter.perCoreTextBlock(rapl: rapl, sys: sys))
            } else {
                print(HWFormatter.textRow(rapl: rapl, sys: sys))
            }
        }
    }

    // MARK: - OTLP

    private func emitOTLP(
        rapl: RAPLSnapshot?,
        sys: SysctlReader.SystemSnapshot,
        exporter: OTLPHTTPJSONExporter
    ) throws {
        let now = Date()

        // RAPL power metrics
        if let rapl {
            for sample in rapl.samples {
                try exporter.emit(snapshot: AggregationSnapshot(
                    timestamp: sample.timestamp,
                    profileName: "power",
                    aggregationName: sample.domain.rawValue + "_watts",
                    kind: .avg,
                    dataPoints: [DataPoint(
                        keys: [sample.domain.rawValue],
                        value: .scalar(Int64(sample.watts * 1000))
                    )]
                ))
            }
        }

        if perCore {
            // Per-core metrics
            for core in sys.cores {
                let cpuKey = String(core.cpu)

                if let temp = core.temperatureC {
                    try exporter.emit(snapshot: AggregationSnapshot(
                        timestamp: now, profileName: "cpu",
                        aggregationName: "temp",
                        kind: .avg,
                        dataPoints: [DataPoint(keys: [cpuKey], value: .scalar(Int64(temp)))]
                    ))
                }

                if let freq = core.frequencyMHz {
                    try exporter.emit(snapshot: AggregationSnapshot(
                        timestamp: now, profileName: "cpu",
                        aggregationName: "freq_mhz",
                        kind: .avg,
                        dataPoints: [DataPoint(keys: [cpuKey], value: .scalar(Int64(freq)))]
                    ))
                }

                if let cstate = core.cstate, let residency = cstate.residency {
                    for (i, level) in cstate.supported.enumerated() where i < residency.percentages.count {
                        try exporter.emit(snapshot: AggregationSnapshot(
                            timestamp: now, profileName: "cpu",
                            aggregationName: "cstate_\(level.name.lowercased())_pct",
                            kind: .avg,
                            dataPoints: [DataPoint(keys: [cpuKey], value: .scalar(Int64(residency.percentages[i] * 100)))]
                        ))
                    }
                }
            }
        } else {
            // Summary metrics
            if let maxTemp = sys.maxTemp {
                try exporter.emit(snapshot: AggregationSnapshot(
                    timestamp: now, profileName: "system",
                    aggregationName: "cpu_temp_max", kind: .max,
                    dataPoints: [DataPoint(keys: ["cpu"], value: .scalar(Int64(maxTemp)))]
                ))
            }
            if let maxFreq = sys.maxFreq {
                try exporter.emit(snapshot: AggregationSnapshot(
                    timestamp: now, profileName: "system",
                    aggregationName: "cpu_freq_max_mhz", kind: .max,
                    dataPoints: [DataPoint(keys: ["cpu"], value: .scalar(Int64(maxFreq)))]
                ))
            }
            if let gpuFreq = sys.gpuFreqMHz {
                try exporter.emit(snapshot: AggregationSnapshot(
                    timestamp: now, profileName: "system",
                    aggregationName: "gpu_freq_mhz", kind: .avg,
                    dataPoints: [DataPoint(keys: ["gpu"], value: .scalar(Int64(gpuFreq)))]
                ))
            }
        }

        try exporter.flush()
    }

    // MARK: - Helpers

}
