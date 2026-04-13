/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation
import CZlib

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OTLPHTTPJSONExporter

/// OTLP/HTTP+JSON exporter. Batches events as OpenTelemetry
/// LogRecords and POSTs them to `/v1/logs`. Aggregation snapshots
/// are mapped to OTLP metrics and POSTed to `/v1/metrics`.
///
/// **Batching**: count-based (default 200) plus a time-based flush
/// timer (default 500 ms).
///
/// **Async sender**: `emit()` hands off batches to a dedicated
/// serial `DispatchQueue` so HTTP latency never blocks the reader.
public final class OTLPHTTPJSONExporter: Exporter, @unchecked Sendable {

    public static let formatName = "otel"

    private let endpoint: URL
    private let resource: ResourceAttributes
    private let scopeName: String
    private let profileName: String
    private let batchSize: Int
    private let flushInterval: Double
    private let lock = NSLock()
    private var batch: [LogRecord] = []
    private var metricsBatch: [AggregationSnapshot] = []
    private var pendingDrops: UInt64 = 0
    private let maxRetries: Int
    private let session: URLSession

    private let senderQueue = DispatchQueue(
        label: "otelexport.otlp.sender",
        qos: .utility
    )

    private var flushTimer: DispatchSourceTimer?

    public init(
        endpoint: URL,
        scopeName: String? = nil,
        profileName: String,
        resource: ResourceAttributes,
        batchSize: Int = 200,
        flushInterval: Double = 0.5,
        maxRetries: Int = 2,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.scopeName = scopeName ?? resource.serviceName
        self.profileName = profileName
        self.resource = resource
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.maxRetries = maxRetries
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    /// Record drops so the next OTLP batch includes a drop attribute.
    public func reportDrops(_ count: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        pendingDrops += count
    }

    public func start() throws {
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

    public func emit(event: ProbeEvent) throws {
        let body = event.printfBody ?? ""
        guard !body.isEmpty else { return }

        let record = LogRecord(
            timeUnixNano: dateToUnixNano(event.timestamp),
            severityNumber: 9,
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

    public func emit(snapshot: AggregationSnapshot) throws {
        guard !snapshot.dataPoints.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        metricsBatch.append(snapshot)
    }

    public func flush() throws {
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

    public func shutdown() throws {
        flushTimer?.cancel()
        flushTimer = nil
        senderQueue.sync { }
        try flush()
        session.invalidateAndCancel()
    }

    // MARK: - Internal types

    struct LogRecord: Sendable {
        let timeUnixNano: UInt64
        let severityNumber: Int
        let body: String
        let attributes: [(key: String, value: AttributeValue)]
    }

    public enum AttributeValue: Sendable {
        case string(String)
        case int(Int64)
        case double(Double)
    }

    // MARK: - Private

    private func buildAttributes(event: ProbeEvent) -> [(key: String, value: AttributeValue)] {
        var attrs: [(key: String, value: AttributeValue)] = []
        attrs.append((key: "\(scopeName).profile", value: .string(event.profileName)))
        attrs.append((key: "\(scopeName).probe", value: .string(event.probeName)))
        attrs.append((key: "process.pid", value: .int(Int64(event.pid))))
        attrs.append((key: "process.executable.name", value: .string(event.execname)))
        return attrs
    }

    private func dateToUnixNano(_ date: Date) -> UInt64 {
        let seconds = date.timeIntervalSince1970
        return UInt64(seconds * 1_000_000_000)
    }

    func buildEnvelope(_ records: [LogRecord], drops: UInt64 = 0) -> String {
        var json = "{\"resourceLogs\":[{\"resource\":{\"attributes\":["
        json += resourceAttributesJSON()
        json += "]},\"scopeLogs\":[{\"scope\":{\"name\":\"\(escapeJSON(scopeName))\",\"version\":\"\(escapeJSON(resource.serviceVersion))\"},"
        json += "\"logRecords\":["
        for (i, record) in records.enumerated() {
            if i > 0 { json += "," }
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
            ("service.version", resource.serviceVersion),
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
                json += "\"intValue\":\"\(n)\""
            case .double(let d):
                json += "\"doubleValue\":\(d)"
            }
            json += "}}"
        }
        if drops > 0 {
            if !record.attributes.isEmpty { json += "," }
            json += "{\"key\":\"\(escapeJSON(scopeName)).drops\",\"value\":{\"intValue\":\"\(drops)\"}}"
        }
        json += "]}"
        return json
    }

    private func asyncPost(_ records: [LogRecord], drops: UInt64) {
        senderQueue.async { [self] in
            postBatch(records, drops: drops)
        }
    }

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

    private func postBatch(_ records: [LogRecord], drops: UInt64 = 0) {
        let body = buildEnvelope(records, drops: drops)
        guard let bodyData = body.data(using: .utf8) else { return }
        post(data: bodyData, path: "v1/logs")
    }

    private func postMetrics(_ snapshots: [AggregationSnapshot]) {
        let body = buildMetricsEnvelope(snapshots)
        guard let bodyData = body.data(using: .utf8) else { return }
        post(data: bodyData, path: "v1/metrics")
    }

    private func post(data: Data, path: String) {
        let url = endpoint.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        if let compressed = gzip(data) {
            request.httpBody = compressed
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delayMs = 100 * (1 << (attempt - 1))
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
                return
            }
            if attempt == maxRetries {
                if let msg = errorBox.value {
                    FileHandle.standardError.write(Data(
                        ("\(msg) (after \(maxRetries + 1) attempts)\n").utf8
                    ))
                }
            }
        }
    }

    private func gzip(_ data: Data) -> Data? {
        let srcLen = data.count
        guard srcLen > 0 else { return nil }

        let bound = Int(CZlib.compressBound(UInt(srcLen)))
        var dest = [UInt8](repeating: 0, count: bound)

        let result: Data? = data.withUnsafeBytes { srcBuf in
            dest.withUnsafeMutableBufferPointer { destBuf in
                guard let srcBase = srcBuf.baseAddress,
                      let destBase = destBuf.baseAddress else { return nil }

                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer(
                    mutating: srcBase.assumingMemoryBound(to: UInt8.self)
                )
                stream.avail_in = UInt32(srcLen)
                stream.next_out = destBase
                stream.avail_out = UInt32(bound)

                let initResult = deflateInit2_(
                    &stream,
                    Z_DEFAULT_COMPRESSION,
                    Z_DEFLATED,
                    15 + 16,
                    8,
                    Z_DEFAULT_STRATEGY,
                    ZLIB_VERSION,
                    Int32(MemoryLayout<z_stream>.size)
                )
                guard initResult == Z_OK else { return nil }

                let deflateResult = CZlib.deflate(&stream, Z_FINISH)
                CZlib.deflateEnd(&stream)

                guard deflateResult == Z_STREAM_END else { return nil }
                return Data(destBuf.prefix(Int(stream.total_out)))
            }
        }
        return result
    }

    // MARK: - Metrics envelope

    func buildMetricsEnvelope(_ snapshots: [AggregationSnapshot]) -> String {
        let timeNano = dateToUnixNano(Date())

        var json = "{\"resourceMetrics\":[{\"resource\":{\"attributes\":["
        json += resourceAttributesJSON()
        json += "]},\"scopeMetrics\":[{\"scope\":{\"name\":\"\(escapeJSON(scopeName))\",\"version\":\"\(escapeJSON(resource.serviceVersion))\"},"
        json += "\"metrics\":["

        for (si, snapshot) in snapshots.enumerated() {
            if si > 0 { json += "," }

            let metricName = snapshot.aggregationName.isEmpty
                ? "\(escapeJSON(scopeName)).\(escapeJSON(snapshot.profileName)).\(snapshot.kind.rawValue)"
                : "\(escapeJSON(scopeName)).\(escapeJSON(snapshot.profileName)).\(escapeJSON(snapshot.aggregationName))"

            json += "{\"name\":\"\(metricName)\","

            switch snapshot.kind {
            case .count, .sum:
                json += "\"sum\":{\"dataPoints\":["
                json += buildScalarDataPoints(snapshot, timeNano: timeNano)
                json += "],\"aggregationTemporality\":2,\"isMonotonic\":true}}"

            case .min, .max, .avg, .stddev:
                json += "\"gauge\":{\"dataPoints\":["
                json += buildScalarDataPoints(snapshot, timeNano: timeNano)
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

    private func buildScalarDataPoints(_ snapshot: AggregationSnapshot, timeNano: UInt64) -> String {
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

            let sortedBuckets = buckets.sorted { $0.upperBound < $1.upperBound }
            let totalCount = sortedBuckets.reduce(Int64(0)) { $0 + $1.count }
            let totalSum = sortedBuckets.reduce(Int64(0)) { $0 + $1.upperBound * $1.count }

            json += ",\"count\":\"\(totalCount)\""
            json += ",\"sum\":\"\(totalSum)\""

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

    private final class ErrorBox: @unchecked Sendable {
        var value: String?
    }
}
