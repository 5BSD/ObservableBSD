/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation
import DTraceCore
import Glibc

// MARK: - WatchRunner

/// The orchestrator that ties a loaded `Profile`, libdtrace (via
/// `DTraceCore`), and an `Exporter` together. Owns the run loop.
///
/// Phase 1 is text-format-only. The flow is:
///   1. Render the profile's `.d` source with parameters, filter
///      predicate, and `--duration` injection applied.
///   2. Open a libdtrace handle and compile the rendered source.
///   3. Install a buffered-output handler that captures every line
///      libdtrace would have written to stdout and routes it through
///      the chosen `Exporter` instead.
///   4. Start the trace (`go`) and poll until done or until the user
///      hits Ctrl-C.
///   5. Snapshot any aggregations and walk them through the
///      exporter at exit.
///   6. Stop and close cleanly.
///
/// Phases 2 and 3 will add structured field extraction (JSONL) and
/// OTLP push (otel) by adding more `Exporter` conformances. The
/// orchestrator itself doesn't need to change.
struct WatchRunner {

    let profile: Profile
    let exporter: Exporter
    let predicate: String
    let predicateAnd: String
    let parameters: [String: String]
    let withStack: Bool
    let withUstack: Bool
    let durationSeconds: Double?

    /// Render the profile, hand it to libdtrace, run it, and stream
    /// output through the exporter.
    func run() throws {
        let rendered = try profile.render(
            parameters: parameters,
            predicate: predicate,
            predicateAnd: predicateAnd,
            withStack: withStack,
            withUstack: withUstack,
            durationSeconds: durationSeconds
        )

        // Open the libdtrace handle.
        let handle: DTraceHandle = try DTraceHandle.open()
        defer {
            // Best-effort cleanup. We don't propagate errors here
            // because the run is already over by the time we hit it.
            try? handle.stop()
        }

        // dtrace(1)-equivalent option defaults. Without these,
        // dtrace_go() refuses to start with "Enabling exceeds size
        // of buffer" because the principal buffer hasn't been
        // sized.
        //
        //   - bufsize=4m  : per-CPU principal buffer for trace data
        //   - aggsize=4m  : aggregation buffer for @-aggregations
        //   - switchrate=50ms : how often the kernel swaps buffers
        //                       so the consumer can read them, AND
        //                       the maximum latency between an
        //                       in-script exit(0) firing and dtlm
        //                       noticing the session is done. We use
        //                       50ms (vs dtrace(1)'s 1sec default)
        //                       to keep --duration short profiles
        //                       responsive — a profile with
        //                       --duration 0.1 should take ~150ms,
        //                       not ~1.1s.
        try handle.setBufferSize("4m")
        try handle.setAggregationBufferSize("4m")
        try handle.setSwitchRate("50ms")

        // Quiet mode: suppress libdtrace's default banner. The
        // script's printfs still come through the buffered-output
        // handler.
        try handle.setQuiet()

        // Compile the rendered source.
        let program: DTraceProgram
        do {
            program = try handle.compile(rendered)
        } catch {
            throw DtlmRunError.compileFailed(
                profile: profile.name,
                source: rendered,
                underlying: error
            )
        }

        _ = try handle.exec(program)

        // Tell the exporter to start. v1's TextExporter no-ops here.
        // Future network exporters (OTel, Prometheus) will use this
        // to open their connections. v2's JSONLExporter will capture
        // events via DTraceCore.consume() instead of letting
        // libdtrace write directly to stdout.
        try exporter.start()

        // Phase 1 text mode: let libdtrace write its formatted
        // printf output directly to stdout. This is the same path
        // DBlocks's `Session.process()` uses, and it's the simplest
        // working route.
        //
        // The Exporter protocol exists for Phase 2+'s structured
        // capture (JSONL, OTLP) where we'll need the typed event
        // model — but for text mode the lowest-friction approach is
        // "let libdtrace format the line, write it where stdout
        // goes." TextExporter accordingly is a no-op pass-through
        // in Phase 1.
        //
        // Set stdout to line-buffered so each printf line shows up
        // immediately rather than waiting for an exit-time flush.
        setvbuf(Glibc.stdout, nil, _IOLBF, 0)

        // ANSI color: only when stdout is an interactive terminal.
        // We wrap the entire libdtrace output stream in a single
        // color escape so the user-visible probe firings are
        // visually distinct from any surrounding shell output.
        // When stdout is piped (e.g., into jq, less, a file, or a
        // test subprocess), we emit nothing — keeps the output
        // grep-friendly.
        let useColor = isatty(STDOUT_FILENO) != 0
        if useColor {
            // Cyan for live event output. Reset is emitted after
            // the run loop and after the aggregation print.
            fputs("\u{001B}[36m", Glibc.stdout)
            fflush(Glibc.stdout)
        }

        // Start the trace.
        try handle.go()

        // Install a SIGINT handler so Ctrl-C stops the loop cleanly
        // instead of bailing in the middle of a work() call.
        let stopFlag = StopFlag()
        installSigintHandler(stopFlag)

        // Poll loop. work() returns .okay while the trace is still
        // running, .done when an `exit()` action fires, .errored on
        // failure. We sleep between rounds so we don't burn a CPU.
        loop: while !stopFlag.isSet {
            let status = handle.poll()
            switch status {
            case .okay:
                handle.sleep()
            case .done:
                break loop
            case .error:
                FileHandle.standardError.write(Data(
                    "dtlm: libdtrace work() failed: \(handle.lastErrorMessage)\n".utf8
                ))
                break loop
            }
        }

        // Snapshot any aggregations the script declared and walk
        // them through libdtrace's default formatter to stdout.
        // Profiles that use printa() inside END blocks will already
        // have printed; profiles that don't get a tabular dump from
        // aggregatePrint().
        //
        // Phase 2 will switch to aggregateWalk() and build typed
        // AggregationSnapshot values for the JSONL/OTel exporters.
        // For Phase 1's text mode, aggregatePrint matches what
        // `dtrace -s foo.d` would produce.
        if useColor {
            // Reset before the aggregation table so we can color it
            // separately (magenta) for visual distinction from the
            // event stream.
            fputs("\u{001B}[0m\u{001B}[35m", Glibc.stdout)
            fflush(Glibc.stdout)
        }
        do {
            try handle.aggregateSnap()
            try handle.aggregatePrint()
        } catch {
            // Aggregation snap/print failures are non-fatal — the
            // event stream may have been the only data the script
            // produced.
            FileHandle.standardError.write(Data(
                "dtlm: aggregation snapshot failed: \(error)\n".utf8
            ))
        }

        // Reset the terminal color and final flush so anything
        // still buffered in stdio reaches the terminal before we
        // exit.
        if useColor {
            fputs("\u{001B}[0m", Glibc.stdout)
        }
        fflush(Glibc.stdout)

        try exporter.flush()
        try exporter.shutdown()
    }
}

// MARK: - Stop flag for SIGINT handling

/// Tiny class wrapping a flag so the SIGINT handler can flip it.
/// Reference type so the closure capture writes through.
final class StopFlag: @unchecked Sendable {
    private var _flag: Bool = false
    var isSet: Bool { _flag }
    func set() { _flag = true }
}

// Global slot for the active StopFlag, because signal handlers
// can't capture state. Only one WatchRunner runs at a time per
// process so this is safe.
nonisolated(unsafe) private var globalStopFlag: StopFlag?

private func installSigintHandler(_ flag: StopFlag) {
    globalStopFlag = flag
    var sa = sigaction()
    sa.__sigaction_u.__sa_handler = { _ in
        globalStopFlag?.set()
    }
    sigemptyset(&sa.sa_mask)
    sa.sa_flags = 0
    _ = sigaction(SIGINT, &sa, nil)
    _ = sigaction(SIGTERM, &sa, nil)
}

// MARK: - Errors

enum DtlmRunError: Error, CustomStringConvertible {
    case compileFailed(profile: String, source: String, underlying: Error)

    var description: String {
        switch self {
        case .compileFailed(let profile, _, let underlying):
            return "profile '\(profile)' failed to compile: \(underlying)"
        }
    }
}
