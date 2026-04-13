/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation

// MARK: - TextExporter

/// Line-oriented stdout exporter. Whatever the event's text body
/// produces, this exporter prints. Stack frames indent below event
/// lines. Aggregation snapshots are printed as a tabular dump.
///
/// This is the simplest possible Exporter conformance — no batching,
/// no retry, no network — and serves as the reference implementation
/// of the protocol.
public final class TextExporter: Exporter {

    public static let formatName = "text"

    private let output: FileHandle
    private let resource: ResourceAttributes

    public init(output: FileHandle = .standardOutput, resource: ResourceAttributes) {
        self.output = output
        self.resource = resource
    }

    public func start() throws {}

    public func emit(event: ProbeEvent) throws {
        let body = event.printfBody ?? ""
        guard !body.isEmpty else { return }
        var line = body + "\n"

        if let stack = event.stack, !stack.isEmpty {
            for frame in stack {
                line += "    [k] \(frame.formatted)\n"
            }
        }
        if let ustack = event.ustack, !ustack.isEmpty {
            for frame in ustack {
                line += "    [u] \(frame.formatted)\n"
            }
        }

        try write(line)
    }

    public func emit(snapshot: AggregationSnapshot) throws {
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

    public func flush() throws {}

    public func shutdown() throws {}

    // MARK: - Private

    private func write(_ line: String) throws {
        guard let data = line.data(using: .utf8) else { return }
        output.write(data)
    }

}
