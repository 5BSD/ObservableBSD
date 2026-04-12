/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser

// MARK: - dtlm

/// Top-level `dtlm` command. Routes to one of the four Phase 1
/// subcommands.
@main
struct Dtlm: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "dtlm",
        abstract: "Apple Instruments for FreeBSD, with OpenTelemetry output.",
        discussion: """
            dtlm bundles a catalog of DTrace-backed profiling templates \
            equivalent to Apple Instruments — Time Profiler, System Trace, \
            File Activity, Network Activity, Allocations, Thread States, \
            Lock Contention — for both kernel events and your own \
            USDT-instrumented applications, and ships the results as \
            text, JSONL, or OTLP/HTTP+JSON to your existing OpenTelemetry \
            collector with stack traces attached.

            Phase 1 (this build) ships the .d profile loader, ~21 bundled \
            profiles, the four core subcommands, filter and duration \
            flags, and text output via the Exporter framework. JSON, \
            OTel, and the rest of the catalog land in subsequent phases. \
            See DESIGN.md.
            """,
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            WatchCommand.self,
            GenerateCommand.self,
            ProbesCommand.self,
        ],
        defaultSubcommand: nil
    )
}
