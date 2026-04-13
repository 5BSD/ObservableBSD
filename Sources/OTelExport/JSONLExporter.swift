/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation

// MARK: - JSONLExporter

/// Line-oriented JSON exporter (JSONL). Wraps every event as one
/// JSON object on its own line so the output is pipe-friendly for
/// `jq`, Loki, Vector, Splunk, fluentd, etc.
public final class JSONLExporter: Exporter, @unchecked Sendable {

    public static let formatName = "json"

    private let output: FileHandle
    private let resource: ResourceAttributes
    private let profileName: String
    private let timestampFormatter: ISO8601DateFormatter

    public init(
        profileName: String,
        output: FileHandle = .standardOutput,
        resource: ResourceAttributes
    ) {
        self.profileName = profileName
        self.output = output
        self.resource = resource
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = f
    }

    public func start() throws {}

    public func emit(event: ProbeEvent) throws {
        let body = event.printfBody ?? ""
        guard !body.isEmpty else { return }

        let timeStr = timestampFormatter.string(from: event.timestamp)

        var line = "{"
        line += "\"time\":\"\(escapeJSON(timeStr))\","
        line += "\"profile\":\"\(escapeJSON(event.profileName))\","
        line += "\"body\":\"\(escapeJSON(body))\""

        if let stack = event.stack, !stack.isEmpty {
            line += ",\"stack\":["
            line += stack.map { "\"\(escapeJSON(formatFrame($0)))\"" }
                .joined(separator: ",")
            line += "]"
        }
        if let ustack = event.ustack, !ustack.isEmpty {
            line += ",\"ustack\":["
            line += ustack.map { "\"\(escapeJSON(formatFrame($0)))\"" }
                .joined(separator: ",")
            line += "]"
        }

        line += "}\n"

        try write(line)
    }

    public func emit(snapshot: AggregationSnapshot) throws {}

    public func flush() throws {}

    public func shutdown() throws {}

    // MARK: - Private

    private func write(_ line: String) throws {
        guard let data = line.data(using: .utf8) else { return }
        output.write(data)
    }

    private func formatFrame(_ frame: StackFrame) -> String { frame.formatted }
}
