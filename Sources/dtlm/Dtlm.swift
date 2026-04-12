/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser

// MARK: - dtlm

/// Top-level `dtlm` command. Routes to subcommands.
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
