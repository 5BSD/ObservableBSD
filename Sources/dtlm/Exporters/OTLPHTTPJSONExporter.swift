/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OTLPHTTPJSONExporter

/// OTLP/HTTP+JSON exporter (Phase 3 + 3.5). Batches probe events as
/// OpenTelemetry LogRecords and POSTs them to an OTLP/HTTP collector's
/// `/v1/logs` endpoint.
///
/// The JSON envelope is built by hand (same pattern as `JSONLExporter`)
/// to keep the dep count at zero and avoid `JSONEncoder` reflection
/// overhead on the flush path.
///
/// **Batching**: count-based (default 200) plus a time-based flush
/// timer (default 500 ms). At high probe rates the count threshold
/// triggers first; at low rates the timer ensures events don't sit
/// until shutdown.
///
/// **Async sender**: `emit()` is called from the structured-backend
/// reader thread. When a batch is full, the records are handed off
/// to a dedicated serial `DispatchQueue` that builds the JSON envelope
/// and POSTs synchronously. This decouples HTTP latency from the
/// reader thread so the pipe never stalls waiting on the network.
///
/// `@unchecked Sendable`: mutable `batch` array is protected by
/// `lock`; `URLSession` and the sender queue are thread-safe.
final class OTLPHTTPJSONExporter: Exporter, @unchecked Sendable {

    static let formatName = "otel"

    private let endpoint: URL
    private let resource: ResourceAttributes
    private let profileName: String
    private let batchSize: Int
    private let flushInterval: Double   // seconds; 0 = no timer
    private let lock = NSLock()
    private var batch: [LogRecord] = []
    private let session: URLSession

    /// Dedicated serial queue for HTTP POSTs. Batches are dispatched
    /// here from `emit()` so the reader thread returns immediately.
    private let senderQueue = DispatchQueue(
        label: "dtlm.otlp.sender",
        qos: .utility
    )

    /// Timer that flushes the current batch periodically, ensuring
    /// low-rate profiles don't hold events until shutdown.
    private var flushTimer: DispatchSourceTimer?

    init(
        endpoint: URL,
        profileName: String,
        resource: ResourceAttributes,
        batchSize: Int = 200,
        flushInterval: Double = 0.5,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.profileName = profileName
        self.resource = resource
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        // Allow injecting a custom session for testing; default is
        // an ephemeral session (no disk cache, no cookies).
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    func start() throws {
        guard flushInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: senderQueue)
        let interval = UInt64(flushInterval * 1_000_000_000)
        timer.schedule(
            deadline: .now() + flushInterval,
            repeating: .nanoseconds(Int(interval))
        )
        timer.setEventHandler { [weak self] in
            self?.timerFlush()
        }
        timer.resume()
        flushTimer = timer
    }

    func emit(event: ProbeEvent) throws {
        let body = event.printfBody ?? ""
        guard !body.isEmpty else { return }

        let record = LogRecord(
            timeUnixNano: dateToUnixNano(event.timestamp),
            severityNumber: 9, // INFO
            body: body,
            attributes: buildAttributes(event: event)
        )

        lock.lock()
        batch.append(record)
        let shouldFlush = batch.count >= batchSize
        let pending: [LogRecord]?
        if shouldFlush {
            pending = batch
            batch = []
        } else {
            pending = nil
        }
        lock.unlock()

        if let pending {
            asyncPost(pending)
        }
    }

    func emit(snapshot: AggregationSnapshot) throws {
        // No-op for Phase 3. Aggregation data still flows through the
        // pipe as text lines and becomes LogRecords via emit(event:).
        // Typed metric mapping is Phase 4.
    }

    func flush() throws {
        lock.lock()
        let pending = batch
        batch = []
        lock.unlock()

        guard !pending.isEmpty else { return }
        // Synchronous flush — used by shutdown() to drain before exit.
        postBatch(pending)
    }

    func shutdown() throws {
        flushTimer?.cancel()
        flushTimer = nil
        // Drain any in-flight async POSTs, then flush remaining batch.
        senderQueue.sync { }
        try flush()
        session.invalidateAndCancel()
    }

    // MARK: - Internal types

    /// Lightweight log record — not Codable, serialized by hand.
    struct LogRecord {
        let timeUnixNano: UInt64
        let severityNumber: Int
        let body: String
        let attributes: [(key: String, value: AttributeValue)]
    }

    /// OTLP attribute values are typed. We support string and int.
    enum AttributeValue {
        case string(String)
        case int(Int64)
    }

    // MARK: - Private

    private func buildAttributes(event: ProbeEvent) -> [(key: String, value: AttributeValue)] {
        var attrs: [(key: String, value: AttributeValue)] = []
        attrs.append((key: "dtlm.profile", value: .string(event.profileName)))
        attrs.append((key: "dtlm.probe", value: .string(event.probeName)))
        attrs.append((key: "process.pid", value: .int(Int64(event.pid))))
        attrs.append((key: "process.executable.name", value: .string(event.execname)))
        return attrs
    }

    /// Convert a `Date` to nanoseconds since Unix epoch as a `UInt64`.
    private func dateToUnixNano(_ date: Date) -> UInt64 {
        let seconds = date.timeIntervalSince1970
        return UInt64(seconds * 1_000_000_000)
    }

    /// Build the full OTLP JSON envelope for a batch of log records.
    func buildEnvelope(_ records: [LogRecord]) -> String {
        var json = "{\"resourceLogs\":[{\"resource\":{\"attributes\":["
        json += resourceAttributesJSON()
        json += "]},\"scopeLogs\":[{\"scope\":{\"name\":\"dtlm\",\"version\":\"\(escapeJSON(resource.dtlmVersion))\"},"
        json += "\"logRecords\":["
        for (i, record) in records.enumerated() {
            if i > 0 { json += "," }
            json += buildRecordJSON(record)
        }
        json += "]}]}]}"
        return json
    }

    private func resourceAttributesJSON() -> String {
        var attrs: [(String, String)] = [
            ("service.name", resource.serviceName),
            ("host.name", resource.hostName),
            ("os.type", resource.osName),
            ("os.version", resource.osVersion),
            ("service.version", resource.dtlmVersion),
        ]
        if let instanceId = resource.serviceInstanceId {
            attrs.append(("service.instance.id", instanceId))
        }
        for (k, v) in resource.custom {
            attrs.append((k, v))
        }
        return attrs.map { k, v in
            "{\"key\":\"\(escapeJSON(k))\",\"value\":{\"stringValue\":\"\(escapeJSON(v))\"}}"
        }.joined(separator: ",")
    }

    private func buildRecordJSON(_ record: LogRecord) -> String {
        var json = "{"
        // OTLP JSON encodes 64-bit integers as decimal strings.
        json += "\"timeUnixNano\":\"\(record.timeUnixNano)\","
        json += "\"severityNumber\":\(record.severityNumber),"
        json += "\"body\":{\"stringValue\":\"\(escapeJSON(record.body))\"},"
        json += "\"attributes\":["
        for (i, attr) in record.attributes.enumerated() {
            if i > 0 { json += "," }
            json += "{\"key\":\"\(escapeJSON(attr.key))\",\"value\":{"
            switch attr.value {
            case .string(let s):
                json += "\"stringValue\":\"\(escapeJSON(s))\""
            case .int(let n):
                // OTLP JSON encodes int64 as decimal strings.
                json += "\"intValue\":\"\(n)\""
            }
            json += "}}"
        }
        json += "]}"
        return json
    }

    /// Dispatch a batch to the sender queue for async POST.
    /// Called from `emit()` on the reader thread — returns immediately.
    private func asyncPost(_ records: [LogRecord]) {
        senderQueue.async { [self] in
            postBatch(records)
        }
    }

    /// Timer callback: drain the current batch if non-empty. Runs on
    /// the sender queue so it serializes naturally with async POSTs.
    private func timerFlush() {
        lock.lock()
        let pending = batch
        batch = []
        lock.unlock()

        guard !pending.isEmpty else { return }
        postBatch(pending)
    }

    /// POST a batch of records to the collector's /v1/logs endpoint.
    /// Synchronous — called on the sender queue (async path) or the
    /// calling thread (shutdown path). Errors are logged to stderr,
    /// not fatal.
    private func postBatch(_ records: [LogRecord]) {
        let body = buildEnvelope(records)
        guard let bodyData = body.data(using: .utf8) else { return }

        let url = endpoint.appendingPathComponent("v1/logs")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let sem = DispatchSemaphore(value: 0)
        let errorBox = ErrorBox()

        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                errorBox.value = "otlp: POST failed: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                errorBox.value = "otlp: POST /v1/logs returned \(http.statusCode)"
            }
            sem.signal()
        }
        task.resume()
        sem.wait()

        if let msg = errorBox.value {
            FileHandle.standardError.write(Data((msg + "\n").utf8))
        }
    }

    /// Thread-safe box for passing an error string out of a
    /// `@Sendable` closure. The semaphore guarantees the write
    /// in the completion handler happens-before the read on the
    /// calling thread, so no lock is needed.
    private final class ErrorBox: @unchecked Sendable {
        var value: String?
    }

    /// Escape a string for inclusion as a JSON string literal value.
    /// Same implementation as JSONLExporter — RFC 8259 compliant.
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
