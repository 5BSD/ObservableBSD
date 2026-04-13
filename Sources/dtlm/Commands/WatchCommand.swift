/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser
import Foundation
import Glibc

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
        // Resolve the profile from either the registry or an
        // explicit -f path.
        let profileToRun: Profile
        if let file {
            do {
                profileToRun = try ProfileLoader.loadExplicit(path: file)
            } catch {
                FileHandle.standardError.write(Data(
                    "dtlm watch: \(error)\n".utf8
                ))
                throw ExitCode.failure
            }
        } else if let name = profile {
            let loader = ProfileLoader()
            for warning in loader.shadowingWarnings {
                FileHandle.standardError.write(Data((warning + "\n").utf8))
            }
            guard let resolved = loader.lookup(name) else {
                throw ValidationError("unknown profile '\(name)'. Try `dtlm list`.")
            }
            profileToRun = resolved
        } else {
            throw ValidationError("internal: no profile resolved")
        }

        // Build the parameter map from the --param key=value entries.
        var params: [String: String] = [:]
        for raw in paramArgs {
            let parts = raw.split(separator: "=", maxSplits: 1)
            params[String(parts[0])] = String(parts[1])
        }

        let resource = ResourceAttributes(
            serviceName: "dtlm",
            serviceInstanceId: nil,
            hostName: ProcessInfo.processInfo.hostName,
            osName: "freebsd",
            osVersion: ProcessInfo.processInfo.osVersionString,
            serviceVersion: "0.1.0",
            custom: [:]
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
            guard let url = URL(string: otel.endpoint),
                  url.scheme == "http" || url.scheme == "https" else {
                throw ValidationError("--endpoint must be an http:// or https:// URL, got: '\(otel.endpoint)'")
            }
            exporter = OTLPHTTPJSONExporter(
                endpoint: url,
                profileName: profileToRun.name,
                resource: resource
            )
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

private extension ProcessInfo {
    /// Best-effort hostname for OTel resource attribution. Falls
    /// back to "localhost" if `gethostname(2)` fails.
    var hostName: String {
        var buf = [CChar](repeating: 0, count: 256)
        guard Glibc.gethostname(&buf, buf.count) == 0 else {
            return "localhost"
        }
        // Truncate at the first NUL and decode as UTF-8.
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Kernel version string from `uname(2)` (e.g. "15.0-RELEASE-p5").
    var osVersionString: String {
        var uts = utsname()
        guard Glibc.uname(&uts) == 0 else { return "" }
        return withUnsafePointer(to: &uts.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(SYS_NMLN)) {
                String(cString: $0)
            }
        }
    }
}
