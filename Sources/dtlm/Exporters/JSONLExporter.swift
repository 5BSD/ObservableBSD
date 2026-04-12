/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation

// MARK: - JSONLExporter

/// Line-oriented JSON exporter (JSONL). Wraps every probe firing as
/// one JSON object on its own line so the output is pipe-friendly
/// for `jq`, Loki, Vector, Splunk, fluentd, etc.
///
/// Each line of libdtrace's formatted output (the rendered `printf`
/// from one probe firing) becomes one JSON record:
///
/// ```jsonl
/// {"time":"2026-04-11T20:53:11.234Z","profile":"kill","body":"nginx[4123]: signal 15 to pid 4567"}
/// {"time":"2026-04-11T20:53:11.246Z","profile":"kill","body":"sshd[3210]: signal 1 to pid 4321"}
/// ```
///
/// Aggregation tables (e.g., `printa()` rows from `systop` on END)
/// flow through the same handler — one row per JSON line. The OTLP
/// exporter uses `aggregateWalkTyped` for proper metric attribution;
/// JSONL keeps line-oriented output since that's what users pipe to
/// log shippers.
///
/// **This exporter uses libdtrace's `onBufferedOutput` handler path**
/// (vs the `TextExporter` direct-to-stdout path). The handler
/// receives each formatted line synchronously when libdtrace produces
/// it. dtlm wraps that line in a JSON object, escapes the body
/// string, and writes it to the configured output.
/// `@unchecked Sendable`: the cached `ISO8601DateFormatter` is the
/// only piece of mutable reference state and is touched solely by
/// the structured-backend reader thread (a single producer). Adding
/// a lock would be pure overhead.
final class JSONLExporter: Exporter, @unchecked Sendable {

    static let formatName = "json"

    private let output: FileHandle
    private let resource: ResourceAttributes
    private let profileName: String
    private let timestampFormatter: ISO8601DateFormatter

    init(
        profileName: String,
        output: FileHandle = .standardOutput,
        resource: ResourceAttributes
    ) {
        self.profileName = profileName
        self.output = output
        self.resource = resource
        // One formatter per exporter instead of one per emit() —
        // ISO8601DateFormatter is expensive to construct (~µs) and
        // dominates per-event cost at 100k events/sec. The exporter
        // is invoked from a single reader thread so no locking
        // needed.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = f
    }

    func start() throws {
        // No banner; JSONL output is meant to be machine-parsed.
    }

    func emit(event: ProbeEvent) throws {
        let body = event.printfBody ?? ""
        guard !body.isEmpty else { return }

        let timeStr = timestampFormatter.string(from: event.timestamp)

        // Build the JSON object manually so we don't pay
        // JSONEncoder's reflection cost per probe firing. Order
        // is fixed (time, profile, body) for stable diffs.
        var line = "{"
        line += "\"time\":\"\(escapeJSON(timeStr))\","
        line += "\"profile\":\"\(escapeJSON(event.profileName))\","
        line += "\"body\":\"\(escapeJSON(body))\""

        // Stack arrays attach if captured.
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

    func emit(snapshot: AggregationSnapshot) throws {
        // No-op: aggregation rows arrive as formatted text lines
        // via the buffered handler and are emitted as JSONL records
        // through emit(event:). Typed metric output is handled by
        // OTLPHTTPJSONExporter.
    }

    func flush() throws {
        // FileHandle writes are unbuffered; nothing to flush.
    }

    func shutdown() throws {
        // No pending state.
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

    /// Escape a string for inclusion as a JSON string literal value.
    /// Handles the seven mandatory escapes per RFC 8259: `\"`, `\\`,
    /// `\b`, `\f`, `\n`, `\r`, `\t`, plus the `\u00XX` form for
    /// other control characters below 0x20.
    func escapeJSON(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if ch.value < 0x20 {
                    out.append(String(format: "\\u%04x", ch.value))
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }
}
