/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser

// MARK: - hwtlm

/// Top-level `hwtlm` command. Routes to subcommands.
@main
struct Hwtlm: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "hwtlm",
        abstract: "Hardware telemetry for FreeBSD, with OpenTelemetry output.",
        discussion: """
            hwtlm collects CPU power consumption (Intel RAPL), \
            per-core temperatures (coretemp), frequencies, ACPI \
            thermal zones, and GPU state, and ships the results \
            as text, JSONL, or OTLP/HTTP metrics to your existing \
            OpenTelemetry collector.

            RAPL requires root and the cpuctl kernel module:
              sudo kldload cpuctl
            Temperatures require the coretemp module:
              sudo kldload coretemp
            """,
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            WatchCommand.self,
            ExecCommand.self,
        ],
        defaultSubcommand: nil
    )
}
