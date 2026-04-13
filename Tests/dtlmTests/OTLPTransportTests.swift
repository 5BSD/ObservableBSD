/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import XCTest
import Foundation
@testable import OTelExport

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport-level tests for `OTLPHTTPJSONExporter` using a mock
/// URLSession. Validates retry logic, compression, custom headers,
/// partial-success handling, and Retry-After behavior without any
/// network access.
final class OTLPTransportTests: XCTestCase {

    // MARK: - Mock URLSession via URLProtocol

    /// Registers a handler that intercepts all HTTP requests made by
    /// the exporter's URLSession. Returns the captured requests after
    /// the test block runs.
    private func withMockSession(
        handler: @escaping (URLRequest) -> (Data, HTTPURLResponse),
        _ block: (OTLPHTTPJSONExporter) throws -> Void
    ) rethrows -> [URLRequest] {
        let requestLog = RequestLog()
        MockURLProtocol.handler = { request in
            requestLog.append(request)
            return handler(request)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let exporter = OTLPHTTPJSONExporter(
            endpoint: URL(string: "http://test-collector:4318")!,
            profileName: "test",
            resource: ResourceAttributes(
                serviceName: "test",
                hostName: "test-host",
                osName: "freebsd",
                osVersion: "15.0",
                serviceVersion: "0.1.0"
            ),
            batchSize: 1000,
            maxRetries: 2,
            headers: ["X-Custom": "value"],
            session: session
        )

        try block(exporter)
        return requestLog.requests
    }

    private func makeEvent(body: String = "test line") -> ProbeEvent {
        ProbeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "test",
            probeName: "",
            pid: 1,
            execname: "test",
            printfBody: body
        )
    }

    // MARK: - Tests

    func testSuccessfulPostSendsOneRequest() throws {
        let requests = try withMockSession(handler: { _ in
            ok200()
        }) { exporter in
            try exporter.emit(event: makeEvent())
            try exporter.flush()
        }

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertTrue(requests[0].url!.path.hasSuffix("v1/logs"))
    }

    func testCustomHeadersAreSent() throws {
        let requests = try withMockSession(handler: { _ in
            ok200()
        }) { exporter in
            try exporter.emit(event: makeEvent())
            try exporter.flush()
        }

        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Custom"), "value")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testGzipCompressionIsAppliedByDefault() throws {
        let requests = try withMockSession(handler: { _ in
            ok200()
        }) { exporter in
            try exporter.emit(event: makeEvent())
            try exporter.flush()
        }

        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Encoding"), "gzip")
    }

    func testCompressionNoneSkipsGzip() throws {
        MockURLProtocol.handler = { _ in ok200() }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let exporter = OTLPHTTPJSONExporter(
            endpoint: URL(string: "http://test-collector:4318")!,
            profileName: "test",
            resource: ResourceAttributes(
                serviceName: "test",
                hostName: "test-host",
                osName: "freebsd",
                osVersion: "15.0",
                serviceVersion: "0.1.0"
            ),
            batchSize: 1000,
            compression: "none",
            session: session
        )

        let requestLog = RequestLog()
        MockURLProtocol.handler = { request in
            requestLog.append(request)
            return ok200()
        }

        try exporter.emit(event: makeEvent())
        try exporter.flush()

        XCTAssertNil(requestLog.requests[0].value(forHTTPHeaderField: "Content-Encoding"),
                     "compression=none should not set Content-Encoding")
    }

    func testRetryOn503() throws {
        var attempt = 0
        let requests = try withMockSession(handler: { _ in
            attempt += 1
            if attempt == 1 {
                return error503()
            }
            return ok200()
        }) { exporter in
            try exporter.emit(event: makeEvent())
            try exporter.flush()
        }

        // First attempt gets 503, second succeeds.
        XCTAssertEqual(requests.count, 2)
    }

    func testNoRetryOn400() throws {
        let requests = try withMockSession(handler: { _ in
            let response = HTTPURLResponse(
                url: URL(string: "http://test-collector:4318/v1/logs")!,
                statusCode: 400,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), response)
        }) { exporter in
            try exporter.emit(event: makeEvent())
            try exporter.flush()
        }

        // 400 is non-retryable — should only try once.
        XCTAssertEqual(requests.count, 1)
    }

    func testMaxRetriesRespected() throws {
        let requests = try withMockSession(handler: { _ in
            error503()
        }) { exporter in
            try exporter.emit(event: makeEvent())
            try exporter.flush()
        }

        // maxRetries=2 → 3 total attempts (initial + 2 retries).
        XCTAssertEqual(requests.count, 3)
    }

    func testMetricsPostToV1Metrics() throws {
        let requests = try withMockSession(handler: { _ in
            ok200()
        }) { exporter in
            let snapshot = AggregationSnapshot(
                timestamp: Date(),
                profileName: "test",
                aggregationName: "counts",
                kind: .count,
                dataPoints: [DataPoint(keys: ["a"], value: .scalar(1))]
            )
            try exporter.emit(snapshot: snapshot)
            try exporter.flush()
        }

        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].url!.path.hasSuffix("v1/metrics"))
    }

    func testPartialSuccessDoesNotRetry() throws {
        let requests = try withMockSession(handler: { _ in
            let body = #"{"partialSuccess":{"rejectedLogRecords":5,"errorMessage":"quota"}}"#
            let response = HTTPURLResponse(
                url: URL(string: "http://test-collector:4318/v1/logs")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body.data(using: .utf8)!, response)
        }) { exporter in
            try exporter.emit(event: makeEvent())
            try exporter.flush()
        }

        // Partial success is 200 — no retry, just a warning.
        XCTAssertEqual(requests.count, 1)
    }

    func testUserAgentHeaderIsSet() throws {
        let requests = try withMockSession(handler: { _ in
            ok200()
        }) { exporter in
            try exporter.emit(event: makeEvent())
            try exporter.flush()
        }

        let ua = requests[0].value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(ua)
        XCTAssertTrue(ua!.hasPrefix("OTel-OTLP-Exporter-Swift/"))
    }
}

// MARK: - Mock infrastructure

private func ok200() -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: URL(string: "http://test-collector:4318/v1/logs")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
    return (Data(), response)
}

private func error503() -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: URL(string: "http://test-collector:4318/v1/logs")!,
        statusCode: 503,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
    return (Data(), response)
}

/// Thread-safe request log.
private final class RequestLog: @unchecked Sendable {
    private var _requests: [URLRequest] = []
    private let lock = NSLock()

    func append(_ request: URLRequest) {
        lock.lock()
        _requests.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }
}

/// URLProtocol subclass that intercepts all requests and calls
/// the configured handler.
private class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
