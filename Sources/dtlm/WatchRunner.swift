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
///    `poll(to: stdout)`. ANSI color when stdout is a TTY. The
///    Exporter's `emit(event:)` is NOT called — `TextExporter` is
///    a pass-through; libdtrace's stdio is the actual output.
///
/// 2. **Structured mode** (`backend = .structured`) — libdtrace's
///    formatted output is intercepted via `onBufferedOutput` and
///    delivered as typed `ProbeEvent` values to
///    `exporter.emit(event:)`. Used by `JSONLExporter` and
///    `OTLPHTTPJSONExporter`. Aggregations are walked via
///    `aggregateWalkTyped` and emitted as `AggregationSnapshot`.
///
/// Both paths share the run loop (compile / exec / go / poll /
/// sleep / aggregate / stop). They differ in how output is captured.
struct WatchRunner {

    /// Which output capture path to use.
    enum Backend: Sendable {
        /// Text — libdtrace writes directly to stdout via
        /// `poll(to: stdout)`. Used by `TextExporter`.
        case text
        /// Structured — `onBufferedOutput` handler routes each
        /// formatted line through `exporter.emit(event:)`. Used by
        /// `JSONLExporter` and `OTLPHTTPJSONExporter`.
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

    // MARK: - Text backend

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

    // MARK: - Structured backend

    /// Structured mode: intercept libdtrace's formatted printf/printa
    /// output via `onBufferedOutput` and deliver each string directly
    /// to the exporter as a `ProbeEvent`.
    ///
    /// `pollBuffered()` passes NULL as the FILE* to `dtrace_work()`,
    /// which tells libdtrace to route output through the registered
    /// handler instead of writing to a file. Aggregation fragments
    /// (flagged AGGKEY/AGGVAL/AGGLAST) are filtered out here since
    /// they're captured as typed metrics via `aggregateWalkTyped()`.
    ///
    /// **Limitation:** the handler only receives the formatted text.
    /// Probe metadata (probeName, pid, execname) is not available;
    /// those fields are zeroed in the ProbeEvent. The actual values
    /// are embedded in the printf body string.
    private func runStructuredBackend(handle: borrowing DTraceHandle, stopFlag: StopFlag) throws {
        // 16m per-CPU buffer gives headroom before kernel drops
        // at high probe rates on many CPUs.
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
        try handle.onDrop { [exporterRef = exporter] drop in
            fputs(
                "dtlm: dropped \(drop.drops) record(s) (\(drop.message))\n",
                stderr
            )
            // Report drops to the OTLP exporter so the next batch
            // includes a dtlm.drops attribute.
            if let otlp = exporterRef as? OTLPHTTPJSONExporter {
                otlp.reportDrops(drop.drops)
            }
            return true
        }

        // Capture state the handler closure needs.
        let exporterRef = exporter
        let profileName = profile.name
        let errorBox = HandlerErrorBox()

        // Accumulator for grouping printf body + subsequent stack
        // frames into a single ProbeEvent. DTrace delivers each
        // stack() / ustack() frame as a separate buffered output
        // callback with whitespace-prefixed text. We detect these
        // by checking if the line starts with whitespace, then
        // flush the accumulated event when the next non-stack
        // line arrives.
        var pendingBody: String? = nil
        var pendingKStack: [StackFrame] = []
        var pendingUStack: [StackFrame] = []
        var pendingTimestamp = Date()
        var inUStack = false  // track which stack section we're in

        // Flush the pending event to the exporter.
        func flushPending() {
            guard let body = pendingBody else { return }
            // Best-effort execname extraction from the printf body.
            // Most profiles format as "execname[pid/...]: ..." so
            // the text before the first '[' is the process name.
            let parsedExecname: String
            if let bracket = body.firstIndex(of: "[") {
                parsedExecname = String(body[body.startIndex..<bracket])
            } else {
                parsedExecname = ""
            }
            let event = ProbeEvent(
                timestamp: pendingTimestamp,
                profileName: profileName,
                probeName: "",
                pid: 0,
                execname: parsedExecname,
                printfBody: body,
                stack: pendingKStack.isEmpty ? nil : pendingKStack,
                ustack: pendingUStack.isEmpty ? nil : pendingUStack
            )
            pendingBody = nil
            pendingKStack = []
            pendingUStack = []
            inUStack = false
            do {
                try exporterRef.emit(event: event)
            } catch {
                errorBox.error = error
            }
        }

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

            // libdtrace may deliver multiple lines in a single
            // callback (especially for stack() output). Split into
            // individual lines and process each one.
            let lines = data.output.split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            for line in lines {
                let raw = String(line)
                let trimmed = raw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty else { continue }

                // Stack frames from DTrace start with whitespace and
                // typically contain ` (backtick) or 0x (hex address).
                let isStackFrame = raw.first?.isWhitespace == true
                    && (trimmed.contains("`") || trimmed.hasPrefix("0x"))

                if isStackFrame {
                    let frame = Self.parseStackFrame(trimmed)
                    if inUStack {
                        pendingUStack.append(frame)
                    } else {
                        pendingKStack.append(frame)
                    }
                } else if trimmed == "__DTLM_USTACK__" {
                    // Marker between stack() and ustack() output.
                    inUStack = true
                } else {
                    // Non-stack line — flush any pending event,
                    // start accumulating a new one.
                    flushPending()
                    pendingBody = trimmed
                    pendingTimestamp = Date()
                }
            }

            if errorBox.error != nil { return false }
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

        // Flush any pending event that was still accumulating
        // when the poll loop ended (last event before shutdown).
        flushPending()

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

    /// Parse a DTrace stack frame line into a StackFrame.
    ///
    /// DTrace formats stack frames as:
    ///   `module\`symbol+0xoffset`
    ///   `symbol+0xoffset`
    ///   `0xdeadbeef`
    static func parseStackFrame(_ line: String) -> StackFrame {
        let s = line.trimmingCharacters(in: .whitespaces)

        // Try module`symbol+0xoffset
        if let btIdx = s.firstIndex(of: "`") {
            let module = String(s[s.startIndex..<btIdx])
            let rest = String(s[s.index(after: btIdx)...])

            if let plusIdx = rest.lastIndex(of: "+"),
               rest[rest.index(after: plusIdx)...].hasPrefix("0x") {
                let symbol = String(rest[rest.startIndex..<plusIdx])
                let hexStr = String(rest[rest.index(plusIdx, offsetBy: 3)...])
                let offset = UInt64(hexStr, radix: 16) ?? 0
                return StackFrame(address: 0, module: module, symbol: symbol, offset: offset)
            }
            return StackFrame(address: 0, module: module, symbol: rest)
        }

        // Try bare hex address
        if s.hasPrefix("0x"), let addr = UInt64(s.dropFirst(2), radix: 16) {
            return StackFrame(address: addr)
        }

        // Fallback: treat as symbol name
        return StackFrame(address: 0, symbol: s)
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
