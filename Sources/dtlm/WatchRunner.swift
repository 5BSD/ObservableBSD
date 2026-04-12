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
    /// typed metric mapping WILL use the buffered handler — that's
    /// what it's actually for.
    ///
    /// The pipe lets us reuse the proven `poll(to:)` /
    /// `aggregatePrint(to:)` path (same one Phase 1 text mode uses)
    /// but redirected into our process instead of stdout. A background
    /// reader thread accumulates the bytes, splits on newlines, and
    /// hands each complete line to the exporter.
    ///
    /// **Historical note:** this path silently produced zero output
    /// until FreeBSDKit commit d606daf. libdtrace's default chew
    /// callbacks (`dt_nullrec`) return `DTRACE_CONSUME_NEXT`, which
    /// makes the per-record loop in `dt_consume_cpu` `continue` and
    /// skip the `dtrace_fprintf` call. dtrace(1) avoids this by
    /// always passing its own chew/chewrec; DTraceCore now substitutes
    /// "always THIS" defaults in `cdtrace_work` when callers pass nil.
    private func runStructuredBackend(handle: borrowing DTraceHandle, stopFlag: StopFlag) throws {
        // Bigger principal buffer for the structured path. The pipe
        // we're writing into is small (16-64KB on FreeBSD by default)
        // and the in-process reader thread is slower than direct-to-
        // TTY stdout, so libdtrace's fwrite() can block and the
        // kernel buffer fills up faster than we'd like. 16m gives the
        // consumer more headroom before kernel drops start happening.
        // Text mode keeps the dtrace(1) default of 4m because TTY
        // writes are fast enough to drain at line rate.
        try handle.setBufferSize("16m")

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

        // Set up a raw POSIX pipe. libdtrace's poll(to: writeFP)
        // will fprintf into the write end; the reader thread drains
        // the read end and emits one event per newline-terminated
        // line.
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw DtlmRunError.compileFailed(
                profile: profile.name,
                source: "",
                underlying: NSError(
                    domain: "dtlm", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey:
                        "pipe(2) failed: \(String(cString: strerror(errno)))"]
                )
            )
        }
        let readFD = fds[0]
        let writeFD = fds[1]

        // Wrap the write fd in a FILE* for libdtrace. fdopen takes
        // ownership of the fd — fclose(writeFP) will close writeFD.
        guard let writeFP = fdopen(writeFD, "w") else {
            close(readFD)
            close(writeFD)
            throw DtlmRunError.compileFailed(
                profile: profile.name,
                source: "",
                underlying: NSError(
                    domain: "dtlm", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey:
                        "fdopen(write end) failed: \(String(cString: strerror(errno)))"]
                )
            )
        }

        // Unbuffered: every fwrite from libdtrace goes straight to
        // the pipe fd so the reader thread sees data without waiting
        // for a stdio flush.
        setvbuf(writeFP, nil, _IONBF, 0)

        // Capture state the reader thread needs.
        let exporterRef = exporter
        let profileName = profile.name
        let errorBox = HandlerErrorBox()
        let readerDone = DispatchSemaphore(value: 0)

        // Once the reader thread is dispatched and writeFP is open,
        // any control-flow exit from this function MUST close writeFP
        // (so the reader sees EOF on the pipe and unblocks from
        // read(2)) and then wait for the reader to finish. Without
        // this, an early throw from handle.go() / aggregateSnap()
        // would leak the reader thread, both pipe FDs, and the
        // exporter capture. Use a flag to make the cleanup
        // idempotent: the happy path also closes writeFP and waits,
        // and we don't want to double-close.
        var writeFPClosed = false
        func closeWriterAndJoinReader() {
            if !writeFPClosed {
                writeFPClosed = true
                fflush(writeFP)
                fclose(writeFP)
                readerDone.wait()
            }
        }
        defer { closeWriterAndJoinReader() }

        // Reader thread: drain the pipe until EOF, splitting on
        // newlines and emitting each complete line as a ProbeEvent.
        // Single-pass scan over each chunk; carry-over bytes between
        // chunks live in `tail`. Avoids the O(n²) Data.removeSubrange
        // pattern that turns into a death-spiral once the buffer
        // grows past a megabyte at high probe rates.
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                close(readFD)
                readerDone.signal()
            }

            let chunkSize = 8192
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            var tail: [UInt8] = []   // bytes left over from the previous chunk

            @inline(__always)
            func emit(_ bytes: ArraySlice<UInt8>) {
                guard !bytes.isEmpty,
                      let line = String(bytes: bytes, encoding: .utf8)
                else { return }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let event = ProbeEvent(
                    timestamp: Date(),
                    profileName: profileName,
                    probeName: "",
                    pid: 0,
                    execname: "",
                    printfBody: trimmed,
                    stack: nil,
                    ustack: nil
                )
                do {
                    try exporterRef.emit(event: event)
                } catch {
                    errorBox.error = error
                }
            }

            while true {
                let n = read(readFD, &chunk, chunkSize)
                if n <= 0 { break }

                // Single-pass split: walk the chunk, emit each line
                // as soon as we hit a newline. Bytes after the last
                // newline carry over to `tail` for next iteration.
                var lineStart = 0
                for i in 0..<n where chunk[i] == 0x0A {
                    if tail.isEmpty {
                        emit(chunk[lineStart..<i])
                    } else {
                        // Combine carryover with the slice from the
                        // current chunk to form one complete line.
                        tail.append(contentsOf: chunk[lineStart..<i])
                        emit(tail[tail.startIndex..<tail.endIndex])
                        tail.removeAll(keepingCapacity: true)
                    }
                    lineStart = i + 1
                }
                if lineStart < n {
                    tail.append(contentsOf: chunk[lineStart..<n])
                }
            }

            // Flush any final partial line that didn't end with \n.
            if !tail.isEmpty {
                emit(tail[tail.startIndex..<tail.endIndex])
            }
        }

        // Start the trace and run the poll loop, writing to the pipe.
        do {
            try handle.go()

            loop: while !stopFlag.isSet {
                let status = handle.poll(to: writeFP)
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

            // Snapshot aggregations to the pipe. printa()/printf
            // output from END handlers and the aggregation table
            // itself flow through here.
            do {
                try handle.aggregateSnap()
                try handle.aggregatePrint(to: writeFP)
            } catch {
                FileHandle.standardError.write(Data(
                    "dtlm: aggregation snapshot failed: \(error)\n".utf8
                ))
            }
        }

        // Close the write end so the reader sees EOF and unblocks,
        // then wait for it. The defer above guarantees this also runs
        // on the early-throw path; running it explicitly here means
        // the reader has finished by the time we check errorBox below.
        closeWriterAndJoinReader()

        // Surface any error the reader thread captured from the
        // exporter.
        if let err = errorBox.error {
            throw err
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
