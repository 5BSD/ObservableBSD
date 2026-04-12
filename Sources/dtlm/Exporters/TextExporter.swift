/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation

// MARK: - TextExporter

/// Line-oriented stdout exporter, dwatch-style. The default for
/// `dtlm watch`. Whatever the script's `printf` action produces,
/// dtlm prints. Stack frames indent below event lines. Aggregation
/// snapshots are printed as a tabular dump.
///
/// This is the simplest possible Exporter conformance — no batching,
/// no retry, no network — and serves as the reference implementation
/// of the protocol. JSONL and OTLP exporters layer the same shape on
/// top.
final class TextExporter: Exporter {

    static let formatName = "text"

    private let output: FileHandle
    private let resource: ResourceAttributes

    init(output: FileHandle = .standardOutput, resource: ResourceAttributes) {
        self.output = output
        self.resource = resource
    }

    func start() throws {
        // Text mode is silent at startup — operators expect line
        // output to start when probes fire, not a banner. The
        // resource attributes still get attached on each line via
        // execname/pid (DTrace already includes them in the
        // probe context); we don't print them as a header.
    }

    func emit(event: ProbeEvent) throws {
        // Format: `<execname>[<pid>]: <printf body>`
        // matches the dwatch convention. If the script didn't
        // printf anything, fall back to printing the probe name.
        let body = event.printfBody ?? event.probeName
        var line = "\(event.execname)[\(event.pid)]: \(body)\n"

        // If the event includes a stack, indent it below.
        if let stack = event.stack, !stack.isEmpty {
            for frame in stack {
                line += "    [k] \(formatFrame(frame))\n"
            }
        }
        if let ustack = event.ustack, !ustack.isEmpty {
            for frame in ustack {
                line += "    [u] \(formatFrame(frame))\n"
            }
        }

        try write(line)
    }

    func emit(snapshot: AggregationSnapshot) throws {
        // Header line for the aggregation.
        var out = "\n--- aggregation: @\(snapshot.aggregationName) "
        out += "(\(snapshot.kind.rawValue))"
        out += " profile=\(snapshot.profileName) ---\n"

        for point in snapshot.dataPoints {
            let keys = point.keys.joined(separator: ", ")
            switch point.value {
            case .scalar(let n):
                out += "  [\(keys)] \(n)\n"
            case .histogram(let buckets):
                out += "  [\(keys)]\n"
                for bucket in buckets where bucket.count > 0 {
                    out += "    <= \(bucket.upperBound): \(bucket.count)\n"
                }
            }
        }
        out += "\n"

        try write(out)
    }

    func flush() throws {
        // FileHandle writes are unbuffered for stdout; nothing to do.
    }

    func shutdown() throws {
        // No pending state to drain.
    }

    // MARK: - Private

    private func write(_ line: String) throws {
        guard let data = line.data(using: .utf8) else { return }
        output.write(data)
    }

    private func formatFrame(_ frame: StackFrame) -> String {
        if let module = frame.module, let symbol = frame.symbol {
            if let offset = frame.offset {
                return "\(module)`\(symbol)+0x\(String(offset, radix: 16))"
            }
            return "\(module)`\(symbol)"
        }
        if let symbol = frame.symbol {
            return symbol
        }
        return String(format: "0x%016llx", frame.address)
    }
}
