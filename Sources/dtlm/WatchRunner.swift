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
/// Two backend paths:
///
/// 1. **Text mode** (`backend = .text`) — libdtrace writes its
///    formatted printf output directly to stdout via
///    `poll(to: stdout)`. The Phase 1 path. Proven, fast, no per-event
///    Swift overhead. ANSI color when stdout is a TTY. The Exporter's
///    `emit(event:)` is NOT called in this mode — `TextExporter` is
///    a no-op pass-through; libdtrace's stdio is the actual output.
///
/// 2. **Structured mode** (`backend = .structured`) — libdtrace's
///    formatted output is fprintf'd into a POSIX pipe, and a
///    background reader thread splits the byte stream on newlines
///    and turns each complete line into a typed `ProbeEvent` for
///    `exporter.emit(event:)`. Phase 2's `JSONLExporter` uses this.
///    Phase 3's `OTLPHTTPJSONExporter` will too.
///
/// The two paths share the run loop (compile / exec / go / poll /
/// sleep / aggregate / stop). They differ only in how output is
/// captured.
struct WatchRunner {

    /// Which output capture path to use.
    enum Backend: Sendable {
        /// Text — libdtrace writes directly to stdout via
        /// `poll(to: stdout)`. Used by `TextExporter`.
        case text
        /// Structured — libdtrace's buffered handler routes each
        /// formatted line through `exporter.emit(event:)`. Used by
        /// `JSONLExporter` (Phase 2) and `OTLPHTTPJSONExporter`
        /// (Phase 3).
        case structured
    }

    let profile: Profile
    let exporter: Exporter
    let backend: Backend
    let predicate: String
    let predicateAnd: String
    let parameters: [String: String]
    let withStack: Bool
    let withUstack: Bool
    let durationSeconds: Double?
    let bufsize: String?
    let switchrate: String?

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
        try handle.setBufferSize(bufsize ?? "4m")
        try handle.setAggregationBufferSize("4m")
        try handle.setSwitchRate(switchrate ?? "50ms")

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

        // Tell the exporter to start. TextExporter no-ops here.
        // Future network exporters (OTel, Prometheus) will use this
        // to open their connections.
        try exporter.start()

        // Install a SIGINT handler so Ctrl-C stops the loop cleanly
        // instead of bailing in the middle of a work() call. Shared
        // by both backends.
        let stopFlag = StopFlag()
        installSigintHandler(stopFlag)

        // Branch on backend. Both paths share compile/exec/go/poll/
        // stop, but differ in how libdtrace's output is captured.
        switch backend {
        case .text:
            try runTextBackend(handle: handle, stopFlag: stopFlag)
        case .structured:
            try runStructuredBackend(handle: handle, stopFlag: stopFlag)
        }

        try exporter.flush()
        try exporter.shutdown()
    }

    // MARK: - Text backend (Phase 1)

    /// Text mode: libdtrace writes formatted printf output directly
    /// to stdout via `poll(to: stdout)`. ANSI color when stdout is
    /// a TTY. `TextExporter.emit(event:)` is NOT called — the
    /// exporter is a no-op pass-through and libdtrace owns the
    /// output stream.
    private func runTextBackend(handle: borrowing DTraceHandle, stopFlag: StopFlag) throws {
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
            // Cyan for live event output.
            fputs("\u{001B}[36m", Glibc.stdout)
            fflush(Glibc.stdout)
        }

        // Start the trace.
        try handle.go()

        // Poll loop. work() returns .okay while the trace is still
        // running, .done when an `exit()` action fires, .error on
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

        // Snapshot any aggregations the script declared.
        if useColor {
            // Reset before the aggregation table so we can color it
            // separately (magenta) for visual distinction.
            fputs("\u{001B}[0m\u{001B}[35m", Glibc.stdout)
            fflush(Glibc.stdout)
        }
        do {
            try handle.aggregateSnap()
            try handle.aggregatePrint()
        } catch {
            FileHandle.standardError.write(Data(
                "dtlm: aggregation snapshot failed: \(error)\n".utf8
            ))
        }

        // Reset the terminal color and final flush.
        if useColor {
            fputs("\u{001B}[0m", Glibc.stdout)
        }
        fflush(Glibc.stdout)
    }

    // MARK: - Structured backend (Phase 2 / Phase 3)

    /// Structured mode: route libdtrace's formatted output through a
    /// pipe and read each line on a background thread, wrapping it
    /// as a `ProbeEvent` for `exporter.emit(event:)`.
    ///
    /// **Why a pipe and not the buffered handler?**
    /// `dtrace_handle_buffered` is for **structured aggregation
    /// introspection** — it's called with `AGGKEY`/`AGGVAL`/`AGGFORMAT`/
    /// `AGGLAST` flagged fragments so consumers can walk aggregation
    /// data without going through the formatted-text path. It does
    /// NOT receive `printf` output; printf flows through
    /// `dt_print_format` → `fprintf(fp, …)` directly to the FILE*
    /// the consumer passed to `dtrace_work`. So Phase 2's per-event
    /// printf capture has to go through the FILE* path. Phase 3's
    /// Uses `onBufferedOutput` to intercept libdtrace's formatted
    /// printf/printa output directly in-process, bypassing the POSIX
    /// pipe that Phase 2 used. Each callback invocation delivers one
    /// formatted string from one probe firing (or one aggregation
    /// fragment). No pipe, no reader thread, no line splitting — the
    /// string goes straight from libdtrace's consumer into the
    /// exporter.
    ///
    /// This is significantly faster than the pipe path because it
    /// eliminates the write(2)/read(2) syscall pair and the byte-
    /// scanning loop per event. On a 20-CPU `sched-on-cpu` run that's
    /// hundreds of thousands fewer syscalls per second.
    private func runStructuredBackend(handle: borrowing DTraceHandle, stopFlag: StopFlag) throws {
        // Bigger principal buffer for the structured path. The
        // buffered handler is faster than the old pipe path, but
        // high-rate probes on many CPUs can still outpace the
        // consumer. 16m per-CPU gives headroom before kernel drops.
        //
        // If the operator passed --bufsize, that already took effect
        // in run() — only override to 16m if they didn't specify one.
        if bufsize == nil {
            try handle.setBufferSize("16m")
        }

        // Register a drop handler that LOGS the drop but returns
        // .continue so libdtrace doesn't abort the session. This
        // matches dtrace(1)'s default drop behavior — when probe
        // rates exceed the consumer's drain rate, the kernel drops
        // records and we keep running with whatever made it through.
        // Without this handler, libdtrace defaults to "abort on
        // first drop" and the very next dtrace_work() call returns
        // .error with the message "Abort due to drop".
        try handle.onDrop { drop in
            fputs(
                "dtlm: dropped \(drop.drops) record(s) (\(drop.message))\n",
                stderr
            )
            return true
        }

        // Capture state the handler closure needs.
        let exporterRef = exporter
        let profileName = profile.name
        let errorBox = HandlerErrorBox()

        // Register the buffered output handler. libdtrace calls this
        // synchronously from dtrace_work() for every printf/printa
        // action output instead of writing to the FILE*. The handler
        // runs on the same thread as poll(), so emit() must be fast
        // (the async sender in OTLPHTTPJSONExporter ensures this).
        try handle.onBufferedOutput { data in
            // Skip aggregation fragments — they're captured as typed
            // metrics via aggregateWalkTyped(), not as log lines.
            if data.isAggregationKey || data.isAggregationValue
                || data.isAggregationFormat || data.isAggregationLast {
                return true
            }

            let text = data.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }

            let event = ProbeEvent(
                timestamp: Date(),
                profileName: profileName,
                probeName: "",
                pid: 0,
                execname: "",
                printfBody: text,
                stack: nil,
                ustack: nil
            )
            do {
                try exporterRef.emit(event: event)
            } catch {
                errorBox.error = error
                return false  // abort consume
            }
            return true
        }

        // Start the trace and run the poll loop. pollBuffered()
        // passes NULL as the FILE* to dtrace_work(), which tells
        // libdtrace to route printf/printa output through the
        // buffered handler instead of writing to a file.
        try handle.go()

        loop: while !stopFlag.isSet {
            let status = handle.pollBuffered()
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
            if errorBox.error != nil {
                break loop
            }
        }

        // Snapshot aggregations and walk them as typed records.
        // aggregateSnap() triggers the kernel snapshot, then
        // aggregateWalkTyped() iterates each record with parsed
        // name, action type, keys, and values. We group records
        // by (name, action) into AggregationSnapshot values and
        // emit them to the exporter.
        do {
            try handle.aggregateSnap()

            var snapshots: [String: AggregationSnapshot] = [:]

            try handle.aggregateWalkTyped(sorted: false) { record in
                let kind = mapAction(record.action)
                let key = "\(record.name):\(kind.rawValue)"

                let dataPoint: DataPoint
                switch record.action {
                case .quantize, .lquantize, .llquantize:
                    let buckets = record.buckets.map {
                        HistogramBucket(upperBound: $0.upperBound, count: $0.count)
                    }
                    dataPoint = DataPoint(
                        keys: record.keys,
                        value: .histogram(buckets: buckets)
                    )
                default:
                    dataPoint = DataPoint(
                        keys: record.keys,
                        value: .scalar(record.value)
                    )
                }

                if var existing = snapshots[key] {
                    existing = AggregationSnapshot(
                        timestamp: existing.timestamp,
                        profileName: existing.profileName,
                        aggregationName: existing.aggregationName,
                        kind: existing.kind,
                        dataPoints: existing.dataPoints + [dataPoint]
                    )
                    snapshots[key] = existing
                } else {
                    snapshots[key] = AggregationSnapshot(
                        timestamp: Date(),
                        profileName: profileName,
                        aggregationName: record.name,
                        kind: kind,
                        dataPoints: [dataPoint]
                    )
                }
                return .next
            }

            for snapshot in snapshots.values {
                do {
                    try exporterRef.emit(snapshot: snapshot)
                } catch {
                    errorBox.error = error
                }
            }
        } catch {
            FileHandle.standardError.write(Data(
                "dtlm: aggregation snapshot failed: \(error)\n".utf8
            ))
        }

        // Surface any error the handler captured from the exporter.
        if let err = errorBox.error {
            throw err
        }
    }

    /// Map DTraceCore's AggregationAction to dtlm's AggregationKind.
    private func mapAction(_ action: DTraceHandle.AggregationAction) -> AggregationKind {
        switch action {
        case .count:     return .count
        case .sum:       return .sum
        case .min:       return .min
        case .max:       return .max
        case .avg:       return .avg
        case .stddev:    return .stddev
        case .quantize:  return .quantize
        case .lquantize: return .lquantize
        case .llquantize: return .llquantize
        }
    }
}

/// Locked ref-typed box so the structured-backend reader thread
/// can surface a thrown exporter error to the main poll loop. The
/// reader writes from a background queue while the main thread polls
/// `error` between `dtrace_work` calls — without the lock, the
/// optional Error read/write is a torn-pointer data race.
private final class HandlerErrorBox: @unchecked Sendable {
    private var _error: Error?
    private let lock = NSLock()

    var error: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _error
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _error = newValue
        }
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
