/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation

// MARK: - CollapsedStackExporter

/// Collapsed-stack exporter for flamegraph generation. Accumulates
/// stack traces during the run and emits folded stacks at shutdown
/// in the format consumed by flamegraph.pl, speedscope, and pprof:
///
///     execname;module`func;module`func 42
///     execname;module`func;module`func 17
///
/// Each unique stack path is one line, with a trailing count of how
/// many times that exact stack was observed. Pipe directly to:
///
///     dtlm watch sched-on-cpu --with-stack --format collapsed \
///         --duration 10 | flamegraph.pl > out.svg
///
/// Supports both kernel stacks (`--with-stack`) and user stacks
/// (`--with-ustack`). When both are present, the kernel stack is
/// placed below the user stack (bottom = kernel, top = userspace),
/// separated by a `--` marker frame.
public final class CollapsedStackExporter: Exporter, @unchecked Sendable {

    public static let formatName = "collapsed"

    private let output: FileHandle
    private let lock = NSLock()
    private var folded: [String: UInt64] = [:]

    public init(output: FileHandle = .standardOutput) {
        self.output = output
    }

    public func start() throws {}

    public func emit(event: ProbeEvent) throws {
        let stack = buildStackString(event)
        guard !stack.isEmpty else { return }

        lock.lock()
        folded[stack, default: 0] += 1
        lock.unlock()
    }

    public func emit(snapshot: AggregationSnapshot) throws {
        // Aggregations don't produce stacks.
    }

    public func flush() throws {
        // Collapsed output is emitted at shutdown, not incrementally.
    }

    public func shutdown() throws {
        lock.lock()
        let snapshot = folded
        lock.unlock()

        // Sort by stack path for stable output.
        let sorted = snapshot.sorted { $0.key < $1.key }
        for (stack, count) in sorted {
            let line = "\(stack) \(count)\n"
            if let data = line.data(using: .utf8) {
                output.write(data)
            }
        }
    }

    // MARK: - Private

    /// Build the semicolon-separated stack string for one event.
    ///
    /// Format: `execname;frame;frame;frame`
    ///
    /// When both kernel and user stacks are present:
    ///   `execname;kframe;kframe;--;uframe;uframe`
    ///
    /// Frames are formatted as `module`symbol` when available,
    /// falling back to hex addresses for stripped frames.
    private func buildStackString(_ event: ProbeEvent) -> String {
        let hasKStack = event.stack != nil && !event.stack!.isEmpty
        let hasUStack = event.ustack != nil && !event.ustack!.isEmpty

        guard hasKStack || hasUStack else { return "" }

        var parts: [String] = []

        // Process name as the root frame.
        parts.append(event.execname)

        // Kernel stack (bottom). Reversed because DTrace reports
        // stacks top-down (leaf first) but flamegraphs read
        // bottom-up (root first).
        if let kstack = event.stack, !kstack.isEmpty {
            for frame in kstack.reversed() {
                parts.append(formatFrame(frame))
            }
        }

        // Separator when both stacks are present.
        if hasKStack && hasUStack {
            parts.append("--")
        }

        // User stack (top).
        if let ustack = event.ustack, !ustack.isEmpty {
            for frame in ustack.reversed() {
                parts.append(formatFrame(frame))
            }
        }

        return parts.joined(separator: ";")
    }

    private func formatFrame(_ frame: StackFrame) -> String { frame.formatted }
}
