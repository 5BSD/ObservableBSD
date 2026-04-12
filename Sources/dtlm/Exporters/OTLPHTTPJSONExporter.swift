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
    private var metricsBatch: [AggregationSnapshot] = []
    private var pendingDrops: UInt64 = 0
    private let maxRetries: Int
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
        maxRetries: Int = 2,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.profileName = profileName
        self.resource = resource
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.maxRetries = maxRetries
        // Allow injecting a custom session for testing; default is
        // an ephemeral session (no disk cache, no cookies).
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    /// Record DTrace drops so the next OTLP batch includes a
    /// `dtlm.drops` attribute. Thread-safe — called from the
    /// drop handler on the poll thread.
    func reportDrops(_ count: UInt64) {
        lock.lock()
        pendingDrops += count
        lock.unlock()
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
        let drops: UInt64
        if shouldFlush {
            pending = batch
            drops = pendingDrops
            batch = []
            pendingDrops = 0
        } else {
            pending = nil
            drops = 0
        }
        lock.unlock()

        if let pending {
            asyncPost(pending, drops: drops)
        }
    }

    func emit(snapshot: AggregationSnapshot) throws {
        guard !snapshot.dataPoints.isEmpty else { return }
        lock.lock()
        metricsBatch.append(snapshot)
        lock.unlock()
    }

    func flush() throws {
        lock.lock()
        let pendingLogs = batch
        let pendingMetrics = metricsBatch
        let drops = pendingDrops
        batch = []
        metricsBatch = []
        pendingDrops = 0
        lock.unlock()

        // Synchronous flush — used by shutdown() to drain before exit.
        if !pendingLogs.isEmpty {
            postBatch(pendingLogs, drops: drops)
        }
        if !pendingMetrics.isEmpty {
            postMetrics(pendingMetrics)
        }
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
    /// When `drops` > 0, a `dtlm.drops` attribute is added to the
    /// first log record so the collector/dashboard can detect data loss.
    func buildEnvelope(_ records: [LogRecord], drops: UInt64 = 0) -> String {
        var json = "{\"resourceLogs\":[{\"resource\":{\"attributes\":["
        json += resourceAttributesJSON()
        json += "]},\"scopeLogs\":[{\"scope\":{\"name\":\"dtlm\",\"version\":\"\(escapeJSON(resource.dtlmVersion))\"},"
        json += "\"logRecords\":["
        for (i, record) in records.enumerated() {
            if i > 0 { json += "," }
            // Attach drop count to the first record in the batch.
            let recordDrops = (i == 0 && drops > 0) ? drops : UInt64(0)
            json += buildRecordJSON(record, drops: recordDrops)
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

    private func buildRecordJSON(_ record: LogRecord, drops: UInt64 = 0) -> String {
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
        if drops > 0 {
            if !record.attributes.isEmpty { json += "," }
            json += "{\"key\":\"dtlm.drops\",\"value\":{\"intValue\":\"\(drops)\"}}"
        }
        json += "]}"
        return json
    }

    /// Dispatch a batch to the sender queue for async POST.
    /// Called from `emit()` on the reader thread — returns immediately.
    private func asyncPost(_ records: [LogRecord], drops: UInt64) {
        senderQueue.async { [self] in
            postBatch(records, drops: drops)
        }
    }

    /// Timer callback: drain current batches if non-empty. Runs on
    /// the sender queue so it serializes naturally with async POSTs.
    private func timerFlush() {
        lock.lock()
        let pendingLogs = batch
        let pendingMetrics = metricsBatch
        let drops = pendingDrops
        batch = []
        metricsBatch = []
        pendingDrops = 0
        lock.unlock()

        if !pendingLogs.isEmpty {
            postBatch(pendingLogs, drops: drops)
        }
        if !pendingMetrics.isEmpty {
            postMetrics(pendingMetrics)
        }
    }

    /// POST a batch of log records to /v1/logs with retry and gzip.
    private func postBatch(_ records: [LogRecord], drops: UInt64 = 0) {
        let body = buildEnvelope(records, drops: drops)
        guard let bodyData = body.data(using: .utf8) else { return }
        post(data: bodyData, path: "v1/logs")
    }

    /// POST metrics to /v1/metrics with retry and gzip.
    private func postMetrics(_ snapshots: [AggregationSnapshot]) {
        let body = buildMetricsEnvelope(snapshots)
        guard let bodyData = body.data(using: .utf8) else { return }
        post(data: bodyData, path: "v1/metrics")
    }

    /// Shared HTTP POST with gzip compression and retry/backoff.
    /// Synchronous — called on the sender queue or shutdown path.
    private func post(data: Data, path: String) {
        let url = endpoint.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // gzip compress the body if possible.
        if let compressed = gzip(data) {
            request.httpBody = compressed
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Retry loop with exponential backoff (100ms, 400ms).
        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delayMs = 100 * (1 << (attempt - 1))  // 100, 200, 400...
                Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
            }

            let sem = DispatchSemaphore(value: 0)
            let errorBox = ErrorBox()

            let task = session.dataTask(with: request) { _, response, error in
                if let error {
                    errorBox.value = "otlp: POST /\(path) failed: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    errorBox.value = "otlp: POST /\(path) returned \(http.statusCode)"
                }
                sem.signal()
            }
            task.resume()
            sem.wait()

            if errorBox.value == nil {
                return  // success
            }
            if attempt == maxRetries {
                // Final attempt failed — log and discard.
                if let msg = errorBox.value {
                    FileHandle.standardError.write(Data(
                        ("\(msg) (after \(maxRetries + 1) attempts)\n").utf8
                    ))
                }
            }
        }
    }

    /// Compress data with gzip using the shell `gzip` command.
    /// Returns nil if compression fails (falls back to uncompressed).
    private func gzip(_ data: Data) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        proc.arguments = ["-c"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try proc.run()
        } catch {
            return nil
        }

        stdinPipe.fileHandleForWriting.write(data)
        try? stdinPipe.fileHandleForWriting.close()

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let compressed = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return compressed.isEmpty ? nil : compressed
    }

    /// Build the OTLP metrics JSON envelope.
    ///
    /// Maps DTrace aggregation kinds to OTLP metric types:
    ///   count, sum → Sum (monotonic)
    ///   min, max, avg, stddev → Gauge
    ///   quantize, lquantize, llquantize → Histogram
    func buildMetricsEnvelope(_ snapshots: [AggregationSnapshot]) -> String {
        let timeNano = dateToUnixNano(Date())

        var json = "{\"resourceMetrics\":[{\"resource\":{\"attributes\":["
        json += resourceAttributesJSON()
        json += "]},\"scopeMetrics\":[{\"scope\":{\"name\":\"dtlm\",\"version\":\"\(escapeJSON(resource.dtlmVersion))\"},"
        json += "\"metrics\":["

        for (si, snapshot) in snapshots.enumerated() {
            if si > 0 { json += "," }

            let metricName = snapshot.aggregationName.isEmpty
                ? "dtlm.\(escapeJSON(snapshot.profileName)).\(snapshot.kind.rawValue)"
                : "dtlm.\(escapeJSON(snapshot.profileName)).\(escapeJSON(snapshot.aggregationName))"

            json += "{\"name\":\"\(metricName)\","

            switch snapshot.kind {
            case .count, .sum:
                json += "\"sum\":{\"dataPoints\":["
                json += buildSumDataPoints(snapshot, timeNano: timeNano)
                json += "],\"aggregationTemporality\":2,\"isMonotonic\":true}}"

            case .min, .max, .avg, .stddev:
                json += "\"gauge\":{\"dataPoints\":["
                json += buildGaugeDataPoints(snapshot, timeNano: timeNano)
                json += "]}}"

            case .quantize, .lquantize, .llquantize:
                json += "\"histogram\":{\"dataPoints\":["
                json += buildHistogramDataPoints(snapshot, timeNano: timeNano)
                json += "],\"aggregationTemporality\":2}}"
            }
        }

        json += "]}]}]}"
        return json
    }

    private func buildSumDataPoints(_ snapshot: AggregationSnapshot, timeNano: UInt64) -> String {
        var parts: [String] = []
        for dp in snapshot.dataPoints {
            var json = "{\"timeUnixNano\":\"\(timeNano)\""
            if case .scalar(let v) = dp.value {
                json += ",\"asInt\":\"\(v)\""
            }
            json += ",\"attributes\":["
            json += dp.keys.enumerated().map { i, k in
                "{\"key\":\"key.\(i)\",\"value\":{\"stringValue\":\"\(escapeJSON(k))\"}}"
            }.joined(separator: ",")
            json += "]}"
            parts.append(json)
        }
        return parts.joined(separator: ",")
    }

    private func buildGaugeDataPoints(_ snapshot: AggregationSnapshot, timeNano: UInt64) -> String {
        var parts: [String] = []
        for dp in snapshot.dataPoints {
            var json = "{\"timeUnixNano\":\"\(timeNano)\""
            if case .scalar(let v) = dp.value {
                json += ",\"asInt\":\"\(v)\""
            }
            json += ",\"attributes\":["
            json += dp.keys.enumerated().map { i, k in
                "{\"key\":\"key.\(i)\",\"value\":{\"stringValue\":\"\(escapeJSON(k))\"}}"
            }.joined(separator: ",")
            json += "]}"
            parts.append(json)
        }
        return parts.joined(separator: ",")
    }

    private func buildHistogramDataPoints(_ snapshot: AggregationSnapshot, timeNano: UInt64) -> String {
        var parts: [String] = []
        for dp in snapshot.dataPoints {
            guard case .histogram(let buckets) = dp.value else { continue }

            var json = "{\"timeUnixNano\":\"\(timeNano)\""

            // OTLP histogram: explicitBounds + bucketCounts arrays.
            // explicitBounds has N-1 entries, bucketCounts has N entries.
            let sortedBuckets = buckets.sorted { $0.upperBound < $1.upperBound }
            let totalCount = sortedBuckets.reduce(Int64(0)) { $0 + $1.count }
            let totalSum = sortedBuckets.reduce(Int64(0)) { $0 + $1.upperBound * $1.count }

            json += ",\"count\":\"\(totalCount)\""
            json += ",\"sum\":\(totalSum)"

            json += ",\"explicitBounds\":["
            json += sortedBuckets.dropLast().map { "\($0.upperBound)" }.joined(separator: ",")
            json += "]"

            json += ",\"bucketCounts\":["
            json += sortedBuckets.map { "\"\($0.count)\"" }.joined(separator: ",")
            json += "]"

            json += ",\"attributes\":["
            json += dp.keys.enumerated().map { i, k in
                "{\"key\":\"key.\(i)\",\"value\":{\"stringValue\":\"\(escapeJSON(k))\"}}"
            }.joined(separator: ",")
            json += "]}"
            parts.append(json)
        }
        return parts.joined(separator: ",")
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
