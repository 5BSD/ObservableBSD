/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import XCTest
import Foundation
@testable import hwtlm
@testable import OTelExport

/// Tests that hwtlm's OTLP metric emission produces valid
/// OpenTelemetry JSON envelopes. No network, no root needed.
final class OTLPTests: XCTestCase {

    private func makeExporter() -> OTLPHTTPJSONExporter {
        let resource = ResourceAttributes(
            serviceName: "hwtlm",
            serviceInstanceId: nil,
            hostName: "test-host",
            osName: "freebsd",
            osVersion: "15.0",
            serviceVersion: "0.1.0",
            custom: [:]
        )
        return OTLPHTTPJSONExporter(
            endpoint: URL(string: "http://localhost:4318")!,
            profileName: "hardware",
            resource: resource,
            batchSize: 1000
        )
    }

    // MARK: - Power metric envelope

    func testPowerMetricIsValidJSON() throws {
        let exporter = makeExporter()
        let snapshot = AggregationSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "power",
            aggregationName: "package_watts",
            kind: .avg,
            dataPoints: [DataPoint(keys: ["package"], value: .scalar(6200))]
        )
        let json = exporter.buildMetricsEnvelope([snapshot])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("power metric envelope is not valid JSON: \(json)")
            return
        }
        XCTAssertNotNil(obj["resourceMetrics"])
    }

    func testPowerMetricHasCorrectStructure() throws {
        let exporter = makeExporter()
        let snapshot = AggregationSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "power",
            aggregationName: "package_watts",
            kind: .avg,
            dataPoints: [DataPoint(keys: ["package"], value: .scalar(6200))]
        )
        let json = exporter.buildMetricsEnvelope([snapshot])
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let resourceMetrics = obj["resourceMetrics"] as! [[String: Any]]
        let rm = resourceMetrics[0]
        let scopeMetrics = rm["scopeMetrics"] as! [[String: Any]]
        let sm = scopeMetrics[0]

        // Scope name should be the service name
        let scope = sm["scope"] as! [String: Any]
        XCTAssertEqual(scope["name"] as? String, "hwtlm")

        // Should have one metric
        let metrics = sm["metrics"] as! [[String: Any]]
        XCTAssertEqual(metrics.count, 1)

        let metric = metrics[0]
        XCTAssertEqual(metric["name"] as? String, "hwtlm.power.package_watts")

        // avg kind maps to gauge
        XCTAssertNotNil(metric["gauge"], "avg aggregation should produce a gauge metric")
    }

    // MARK: - Temperature metric

    func testTemperatureMetricIsValidJSON() throws {
        let exporter = makeExporter()
        let snapshot = AggregationSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "system",
            aggregationName: "cpu_temp_max",
            kind: .max,
            dataPoints: [DataPoint(keys: ["cpu"], value: .scalar(55))]
        )
        let json = exporter.buildMetricsEnvelope([snapshot])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("temp metric is not valid JSON"); return
        }

        let resourceMetrics = obj["resourceMetrics"] as! [[String: Any]]
        let metrics = (resourceMetrics[0]["scopeMetrics"] as! [[String: Any]])[0]["metrics"] as! [[String: Any]]
        let metric = metrics[0]
        XCTAssertEqual(metric["name"] as? String, "hwtlm.system.cpu_temp_max")
        XCTAssertNotNil(metric["gauge"], "max kind should produce a gauge")
    }

    // MARK: - Per-core metrics

    func testPerCoreMetricsProduceMultipleSnapshots() throws {
        let exporter = makeExporter()

        // Simulate per-core temp for 3 CPUs
        for cpu in 0..<3 {
            try exporter.emit(snapshot: AggregationSnapshot(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                profileName: "cpu",
                aggregationName: "temp",
                kind: .avg,
                dataPoints: [DataPoint(keys: [String(cpu)], value: .scalar(Int64(50 + cpu)))]
            ))
        }

        // Flush and check the batch was accepted without error
        try exporter.flush()
        try exporter.shutdown()
    }

    // MARK: - Multiple metric types in one batch

    func testMixedMetricBatchIsValidJSON() throws {
        let exporter = makeExporter()

        let power = AggregationSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "power",
            aggregationName: "package_watts",
            kind: .avg,
            dataPoints: [DataPoint(keys: ["package"], value: .scalar(6200))]
        )
        let temp = AggregationSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "system",
            aggregationName: "cpu_temp_max",
            kind: .max,
            dataPoints: [DataPoint(keys: ["cpu"], value: .scalar(55))]
        )
        let freq = AggregationSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "system",
            aggregationName: "cpu_freq_max_mhz",
            kind: .max,
            dataPoints: [DataPoint(keys: ["cpu"], value: .scalar(2685))]
        )

        let json = exporter.buildMetricsEnvelope([power, temp, freq])
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let resourceMetrics = obj["resourceMetrics"] as! [[String: Any]]
        let metrics = (resourceMetrics[0]["scopeMetrics"] as! [[String: Any]])[0]["metrics"] as! [[String: Any]]
        XCTAssertEqual(metrics.count, 3, "should have 3 metrics in batch")

        let names = metrics.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("hwtlm.power.package_watts"))
        XCTAssertTrue(names.contains("hwtlm.system.cpu_temp_max"))
        XCTAssertTrue(names.contains("hwtlm.system.cpu_freq_max_mhz"))
    }

    // MARK: - Resource attributes

    func testResourceAttributesContainServiceName() throws {
        let exporter = makeExporter()
        let snapshot = AggregationSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "power",
            aggregationName: "package_watts",
            kind: .avg,
            dataPoints: [DataPoint(keys: ["package"], value: .scalar(6200))]
        )
        let json = exporter.buildMetricsEnvelope([snapshot])
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let resourceMetrics = obj["resourceMetrics"] as! [[String: Any]]
        let resource = resourceMetrics[0]["resource"] as! [String: Any]
        let attrs = resource["attributes"] as! [[String: Any]]

        let serviceAttr = attrs.first { ($0["key"] as? String) == "service.name" }
        XCTAssertNotNil(serviceAttr, "resource should have service.name attribute")
        let value = serviceAttr?["value"] as? [String: Any]
        XCTAssertEqual(value?["stringValue"] as? String, "hwtlm")
    }

    // MARK: - C-state metric

    func testCStateMetricNameIsCorrect() throws {
        let exporter = makeExporter()
        let snapshot = AggregationSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "cpu",
            aggregationName: "cstate_c1_pct",
            kind: .avg,
            dataPoints: [DataPoint(keys: ["0"], value: .scalar(9500))]
        )
        let json = exporter.buildMetricsEnvelope([snapshot])
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let resourceMetrics = obj["resourceMetrics"] as! [[String: Any]]
        let metrics = (resourceMetrics[0]["scopeMetrics"] as! [[String: Any]])[0]["metrics"] as! [[String: Any]]
        XCTAssertEqual(metrics[0]["name"] as? String, "hwtlm.cpu.cstate_c1_pct")
    }
}
