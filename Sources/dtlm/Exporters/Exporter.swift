/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation

// MARK: - Exporter protocol

/// An exporter consumes events and aggregation snapshots from
/// dtlm's run loop and ships them to a destination — stdout, a
/// file, an HTTP collector, an archive, anywhere.
///
/// **This protocol is the architectural seam.** Adding a new output
/// format (Prometheus, Loki, OTLP-protobuf, S3, vendor APIs, …) is
/// a new file implementing `Exporter` plus a one-line registration
/// in the format registry. The dtlm core never needs to change.
///
/// v1 ships three conformances:
///   - `TextExporter` (line-oriented stdout, dwatch-style)
///   - `JSONLExporter` (Phase 2, structured pipe)
///   - `OTLPHTTPJSONExporter` (Phase 3, the OTel bridge)
///
/// Post-v1 conformances are anticipated for Prometheus, OTLP/protobuf,
/// Loki, S3 archive, and vendor APIs. None of them require core
/// changes.
protocol Exporter: Sendable {

    /// CLI name. e.g. `"text"`, `"jsonl"`, `"otel"`.
    static var formatName: String { get }

    /// Called once before the run loop starts.
    func start() throws

    /// Called for every probe firing. Must return quickly because
    /// it's invoked from the libdtrace consume callback.
    func emit(event: ProbeEvent) throws

    /// Called for every aggregation snapshot.
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

/// One probe firing, normalized into a typed Swift value before it
/// reaches any exporter. Every exporter sees the same shape.
struct ProbeEvent: Sendable {
    /// Wall-clock timestamp of the firing (Unix epoch).
    let timestamp: Date

    /// Profile name (filename minus `.d`) that produced this event.
    let profileName: String

    /// The probe that fired (provider:module:function:name).
    let probeName: String

    /// PID of the firing process.
    let pid: Int32

    /// `execname` of the firing process.
    let execname: String

    /// The rendered text from the script's `printf` action, if any.
    /// `nil` for events that don't `printf` (counted-only events).
    let printfBody: String?

    /// Kernel stack frames if `--with-stack` was passed and the
    /// script captured `stack()`.
    let stack: [StackFrame]?

    /// User stack frames if `--with-ustack` was passed and the
    /// script captured `ustack()`.
    let ustack: [StackFrame]?
}

/// One snapshot of one named aggregation. Aggregations don't fire
/// per-event — they're sampled periodically (or at exit) and walked
/// to produce data points.
struct AggregationSnapshot: Sendable {
    let timestamp: Date
    let profileName: String
    let aggregationName: String
    let kind: AggregationKind
    let dataPoints: [DataPoint]
}

/// What kind of aggregation function this snapshot came from. Each
/// kind maps to a different OTel metric shape (Sum, Gauge, Histogram,
/// etc.) — see the OTLP exporter for the mapping.
enum AggregationKind: String, Sendable {
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
/// tuple key dimensions (e.g. `["execname", "probefunc"]` for
/// `@[execname, probefunc] = count()`); the `value` is the bucket /
/// scalar / histogram payload.
struct DataPoint: Sendable {
    let keys: [String]
    let value: AggregationValue
}

/// The actual numeric payload of a data point. Variant per
/// aggregation kind.
enum AggregationValue: Sendable {
    case scalar(Int64)
    case histogram(buckets: [HistogramBucket])
}

struct HistogramBucket: Sendable {
    let upperBound: Int64
    let count: Int64
}

/// One frame from a stack trace. Stack capture is best-effort —
/// stripped binaries produce raw addresses, symbols-present binaries
/// produce function names with offsets.
struct StackFrame: Sendable {
    let address: UInt64
    let module: String?
    let symbol: String?
    let offset: UInt64?
}

// MARK: - Resource attributes

/// OTel resource attributes that get attached to every record from
/// every exporter (the OTLP exporter sends them as the `resource`
/// field; the JSONL exporter inlines them; the text exporter prints
/// them once at startup).
struct ResourceAttributes: Sendable {
    let serviceName: String
    let serviceInstanceId: String?
    let hostName: String
    let osName: String
    let osVersion: String
    let dtlmVersion: String
    let custom: [String: String]
}
