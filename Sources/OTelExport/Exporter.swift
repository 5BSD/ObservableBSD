/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation

// MARK: - Exporter protocol

/// An exporter consumes events and aggregation snapshots from an
/// ObservableBSD tool's run loop and ships them to a destination —
/// stdout, a file, an HTTP collector, an archive, anywhere.
///
/// **This protocol is the architectural seam.** Adding a new output
/// format (Prometheus, Loki, OTLP-protobuf, S3, vendor APIs, …) is
/// a new file implementing `Exporter` plus a one-line registration
/// in the format registry. The tool cores never need to change.
///
/// v1 ships three conformances:
///   - `TextExporter` (line-oriented stdout)
///   - `JSONLExporter` (JSONL, one JSON object per event)
///   - `OTLPHTTPJSONExporter` (OTLP/HTTP logs + metrics)
public protocol Exporter: Sendable {

    /// CLI name. e.g. `"text"`, `"jsonl"`, `"otel"`.
    static var formatName: String { get }

    /// Called once before the run loop starts.
    func start() throws

    /// Called for every probe firing / event. Must return quickly
    /// because it may be invoked from a hot consumer callback.
    func emit(event: ProbeEvent) throws

    /// Called for every aggregation / metric snapshot.
    func emit(snapshot: AggregationSnapshot) throws

    /// Called periodically based on the exporter's flush cadence.
    /// Network exporters use this to flush batches; file exporters
    /// can no-op.
    func flush() throws

    /// Called on graceful shutdown. Must drain pending records
    /// before returning.
    func shutdown() throws
}

// MARK: - Typed event model

/// One probe firing or event, normalized into a typed Swift value
/// before it reaches any exporter. Every exporter sees the same shape.
public struct ProbeEvent: Sendable {
    /// Wall-clock timestamp of the firing (Unix epoch).
    public let timestamp: Date

    /// Profile / tool name that produced this event.
    public let profileName: String

    /// The probe that fired (provider:module:function:name) or event name.
    public let probeName: String

    /// PID of the firing process (0 for system-level events).
    public let pid: Int32

    /// `execname` of the firing process.
    public let execname: String

    /// The rendered text body, if any.
    /// `nil` for events that don't produce text output.
    public let printfBody: String?

    /// Kernel stack frames if captured.
    public let stack: [StackFrame]?

    /// User stack frames if captured.
    public let ustack: [StackFrame]?

    public init(
        timestamp: Date,
        profileName: String,
        probeName: String,
        pid: Int32,
        execname: String,
        printfBody: String?,
        stack: [StackFrame]? = nil,
        ustack: [StackFrame]? = nil
    ) {
        self.timestamp = timestamp
        self.profileName = profileName
        self.probeName = probeName
        self.pid = pid
        self.execname = execname
        self.printfBody = printfBody
        self.stack = stack
        self.ustack = ustack
    }
}

/// One snapshot of one named aggregation or metric. Aggregations
/// are sampled periodically (or at exit) and walked to produce
/// data points.
public struct AggregationSnapshot: Sendable {
    public let timestamp: Date
    public let profileName: String
    public let aggregationName: String
    public let kind: AggregationKind
    public let dataPoints: [DataPoint]

    public init(
        timestamp: Date,
        profileName: String,
        aggregationName: String,
        kind: AggregationKind,
        dataPoints: [DataPoint]
    ) {
        self.timestamp = timestamp
        self.profileName = profileName
        self.aggregationName = aggregationName
        self.kind = kind
        self.dataPoints = dataPoints
    }
}

/// What kind of aggregation function this snapshot came from. Each
/// kind maps to a different OTel metric shape (Sum, Gauge, Histogram,
/// etc.) — see the OTLP exporter for the mapping.
public enum AggregationKind: String, Sendable {
    case count
    case sum
    case min
    case max
    case avg
    case stddev
    case quantize
    case lquantize
    case llquantize
}

/// One data point in an aggregation snapshot. The `keys` are the
/// tuple key dimensions; the `value` is the bucket / scalar /
/// histogram payload.
///
/// Use `attributes` for named key-value pairs (e.g. `cpu_id=3`).
/// If `attributes` is non-empty, it takes precedence over `keys`
/// in OTLP output. `keys` are emitted as `key.0`, `key.1`, etc.
/// and exist for DTrace aggregation tuples where names aren't known.
public struct DataPoint: Sendable {
    public let keys: [String]
    public let attributes: [(name: String, value: String)]
    public let value: AggregationValue

    public init(keys: [String], value: AggregationValue) {
        self.keys = keys
        self.attributes = []
        self.value = value
    }

    public init(attributes: [(name: String, value: String)], value: AggregationValue) {
        self.keys = attributes.map(\.value)
        self.attributes = attributes
        self.value = value
    }
}

/// The actual numeric payload of a data point.
public enum AggregationValue: Sendable {
    case scalar(Int64)
    case histogram(buckets: [HistogramBucket])
}

public struct HistogramBucket: Sendable {
    public let upperBound: Int64
    public let count: Int64

    public init(upperBound: Int64, count: Int64) {
        self.upperBound = upperBound
        self.count = count
    }
}

/// One frame from a stack trace.
public struct StackFrame: Sendable {
    public let address: UInt64
    public let module: String?
    public let symbol: String?
    public let offset: UInt64?

    public init(address: UInt64, module: String? = nil, symbol: String? = nil, offset: UInt64? = nil) {
        self.address = address
        self.module = module
        self.symbol = symbol
        self.offset = offset
    }
}

// MARK: - Resource attributes

/// OTel resource attributes attached to every record.
public struct ResourceAttributes: Sendable {
    public let serviceName: String
    public let serviceInstanceId: String?
    public let hostName: String
    public let hostArch: String
    public let osName: String
    public let osVersion: String
    public let serviceVersion: String
    public let custom: [String: String]

    public init(
        serviceName: String,
        serviceInstanceId: String? = nil,
        hostName: String,
        hostArch: String = "",
        osName: String,
        osVersion: String,
        serviceVersion: String,
        custom: [String: String] = [:]
    ) {
        self.serviceName = serviceName
        self.serviceInstanceId = serviceInstanceId
        self.hostName = hostName
        self.hostArch = hostArch
        self.osName = osName
        self.osVersion = osVersion
        self.serviceVersion = serviceVersion
        self.custom = custom
    }
}

// MARK: - OTel environment variable support

/// Read OTel-standard environment variables and apply them as
/// overrides to the resource and exporter configuration.
///
/// Supports:
///   - `OTEL_SERVICE_NAME` — overrides `service.name`
///   - `OTEL_RESOURCE_ATTRIBUTES` — comma-separated `key=value` pairs
///     merged into resource custom attributes
///   - `OTEL_EXPORTER_OTLP_ENDPOINT` — base URL for the collector
///   - `OTEL_EXPORTER_OTLP_HEADERS` — comma-separated `key=value`
///     pairs sent as HTTP headers (auth tokens, etc.)
///   - `OTEL_EXPORTER_OTLP_COMPRESSION` — `gzip` or `none`
///   - `OTEL_EXPORTER_OTLP_TIMEOUT` — export timeout in milliseconds
public struct OTelEnvironment: Sendable {
    public let serviceName: String?
    public let resourceAttributes: [String: String]
    public let endpoint: String?
    public let headers: [String: String]
    public let compression: String?
    public let timeoutMs: Int?

    public init() {
        let env = ProcessInfo.processInfo.environment
        self.serviceName = env["OTEL_SERVICE_NAME"]
        self.endpoint = env["OTEL_EXPORTER_OTLP_ENDPOINT"]
        self.compression = env["OTEL_EXPORTER_OTLP_COMPRESSION"]

        if let timeoutStr = env["OTEL_EXPORTER_OTLP_TIMEOUT"] {
            self.timeoutMs = Int(timeoutStr)
        } else {
            self.timeoutMs = nil
        }

        // Parse key=value pairs from OTEL_RESOURCE_ATTRIBUTES
        var resAttrs: [String: String] = [:]
        if let raw = env["OTEL_RESOURCE_ATTRIBUTES"] {
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    resAttrs[String(parts[0])] = String(parts[1])
                }
            }
        }
        self.resourceAttributes = resAttrs

        // Parse key=value pairs from OTEL_EXPORTER_OTLP_HEADERS
        var hdrs: [String: String] = [:]
        if let raw = env["OTEL_EXPORTER_OTLP_HEADERS"] {
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    hdrs[String(parts[0])] = String(parts[1])
                }
            }
        }
        self.headers = hdrs
    }
}

// MARK: - JSON utilities

/// Escape a string for inclusion as a JSON string literal value.
/// Handles the seven mandatory escapes per RFC 8259.
public func escapeJSON(_ s: String) -> String {
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

// MARK: - Stack frame formatting

extension StackFrame {
    /// Format as `module\`symbol+0xoffset`, `symbol`, or `0xaddress`.
    public var formatted: String {
        if let module, let symbol {
            if let offset {
                return "\(module)`\(symbol)+0x\(String(offset, radix: 16))"
            }
            return "\(module)`\(symbol)"
        }
        if let symbol { return symbol }
        return String(format: "0x%016llx", address)
    }
}

// MARK: - Host detection

public enum HostInfo {
    public static var hostName: String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "localhost" }
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static var osVersion: String {
        var uts = utsname()
        guard uname(&uts) == 0 else { return "" }
        return withUnsafePointer(to: &uts.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }

    public static var machineArch: String {
        var uts = utsname()
        guard uname(&uts) == 0 else { return "" }
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
}
