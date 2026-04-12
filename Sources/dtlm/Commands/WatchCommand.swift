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
/// Phase 1 supports `--format text` only. JSON and OTel exporters
/// land in Phases 2 and 3 by adding new `Exporter` conformances —
/// the run loop in `WatchRunner` doesn't change.
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

        // Phase 1 only ships the text exporter. Future phases register
        // additional formats here behind a --format flag.
        let resource = ResourceAttributes(
            serviceName: "dtlm",
            serviceInstanceId: nil,
            hostName: ProcessInfo.processInfo.hostName,
            osName: "freebsd",
            osVersion: "",
            dtlmVersion: "0.1.0",
            custom: [:]
        )
        let exporter = TextExporter(resource: resource)

        let runner = WatchRunner(
            profile: profileToRun,
            exporter: exporter,
            predicate: filter.renderPredicate(),
            predicateAnd: filter.renderPredicateAnd(),
            parameters: params,
            withStack: stack.withStack,
            withUstack: stack.withUstack,
            durationSeconds: duration.durationSeconds
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
}
