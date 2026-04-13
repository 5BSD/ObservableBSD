/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser
import Foundation
import Glibc
import OTelExport

// MARK: - dtlm watch

/// `dtlm watch` — load a profile (by name from the catalog or by
/// `-f` from an explicit path), apply CLI filter / parameter /
/// duration flags, run it via libdtrace, and stream the output
/// through the chosen exporter.
///
/// `--format text` (default) writes libdtrace's formatted printf
/// output directly to stdout. `--format json` wraps each probe
/// firing as one JSONL record on stdout. `--format otel` POSTs
/// logs and metrics to an OTLP/HTTP collector.
struct WatchCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Run a profile and stream its events to stdout.",
        discussion: """
            Pass a profile name from `dtlm list`, or `-f /path/to/script.d` \
            for an arbitrary D file. Filter flags (--pid, --execname, etc.) \
            are injected at the profile's `/* @dtlm-predicate */` marker if \
            present. --duration N injects an equivalent `tick-Ns { exit(0); }` \
            clause. --param key=value substitutes ${key} placeholders in the \
            source.
            """
    )

    @Argument(
        help: ArgumentHelp(
            "Name of the profile to run, or a path to a .d file.",
            discussion: "Use `dtlm list` to see every available profile."
        )
    )
    var profile: String?

    @Option(
        name: .customShort("f"),
        help: "Path to an explicit .d file to run instead of a named profile."
    )
    var file: String?

    @Option(
        name: .customLong("param"),
        parsing: .upToNextOption,
        help: ArgumentHelp(
            "Substitute ${name} placeholders in the .d source.",
            discussion: "Repeatable. Use as `--param name=value --param other=42`."
        )
    )
    var paramArgs: [String] = []

    @OptionGroup
    var filter: FilterOptions

    @OptionGroup
    var duration: DurationOption

    @OptionGroup
    var stack: StackOptions

    @OptionGroup
    var format: FormatOption

    @OptionGroup
    var otel: OTelOptions

    @OptionGroup
    var dtrace: DTraceOptions

    func validate() throws {
        if profile == nil && file == nil {
            throw ValidationError("provide a profile name or `-f /path/to/script.d`.")
        }
        if profile != nil && file != nil {
            throw ValidationError("pass either a profile name or `-f`, not both.")
        }
        // Reject malformed --param key=value entries up front.
        for raw in paramArgs where !raw.contains("=") {
            throw ValidationError("--param expects key=value, got '\(raw)'")
        }
    }

    func run() throws {
        let profileToRun: Profile
        do {
            profileToRun = try ProfileLoader.resolve(name: profile, file: file)
        } catch {
            FileHandle.standardError.write(Data(
                "dtlm watch: \(error)\n".utf8
            ))
            throw ExitCode.failure
        }

        let params = ProfileLoader.parseParams(paramArgs)

        let otelEnv = OTelEnvironment()
        let resource = ResourceAttributes(
            serviceName: otelEnv.serviceName ?? "dtlm",
            serviceInstanceId: nil,
            hostName: HostInfo.hostName,
            hostArch: HostInfo.machineArch,
            osName: "freebsd",
            osVersion: HostInfo.osVersion,
            serviceVersion: "0.1.0",
            custom: otelEnv.resourceAttributes
        )

        // Pick the exporter and the run-loop backend based on the
        // --format flag. The two backends share compile/exec/go/poll
        // but differ in how libdtrace's output is captured.
        let exporter: Exporter
        let backend: WatchRunner.Backend
        switch format.format {
        case .text:
            exporter = TextExporter(resource: resource)
            backend = .text
        case .json:
            exporter = JSONLExporter(
                profileName: profileToRun.name,
                resource: resource
            )
            backend = .structured
        case .otel:
            // OTEL_EXPORTER_OTLP_ENDPOINT overrides the CLI default
            // but not an explicit --endpoint flag.
            let endpointStr = otelEnv.endpoint ?? otel.endpoint
            guard let url = URL(string: endpointStr),
                  url.scheme == "http" || url.scheme == "https" else {
                throw ValidationError("--endpoint must be an http:// or https:// URL, got: '\(endpointStr)'")
            }
            let timeout = otelEnv.timeoutMs.map { TimeInterval($0) / 1000.0 } ?? 10.0
            exporter = OTLPHTTPJSONExporter(
                endpoint: url,
                profileName: profileToRun.name,
                resource: resource,
                exportTimeout: timeout,
                headers: otelEnv.headers
            )
            backend = .structured
        case .collapsed:
            if !stack.withStack && !stack.withUstack {
                throw ValidationError("--format collapsed requires --with-stack and/or --with-ustack")
            }
            exporter = CollapsedStackExporter()
            backend = .structured
        }

        let runner = WatchRunner(
            profile: profileToRun,
            exporter: exporter,
            backend: backend,
            predicate: filter.renderPredicate(),
            predicateAnd: filter.renderPredicateAnd(),
            parameters: params,
            withStack: stack.withStack,
            withUstack: stack.withUstack,
            durationSeconds: duration.durationSeconds,
            bufsize: dtrace.bufsize,
            switchrate: dtrace.switchrate
        )

        do {
            try runner.run()
        } catch {
            FileHandle.standardError.write(Data(
                "dtlm watch: \(error)\n".utf8
            ))
            throw ExitCode.failure
        }
    }
}

