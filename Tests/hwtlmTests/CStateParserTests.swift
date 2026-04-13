/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import XCTest
@testable import hwtlm

/// Unit tests for CStateParser — pure string parsing, no root needed.
final class CStateParserTests: XCTestCase {

    // MARK: - parseSupported

    func testParseSupportedThreeStates() {
        let result = CStateParser.parseSupported("C1/1/1 C2/2/127 C3/3/1048")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], CStateLevel(name: "C1", type: 1, latencyUs: 1))
        XCTAssertEqual(result[1], CStateLevel(name: "C2", type: 2, latencyUs: 127))
        XCTAssertEqual(result[2], CStateLevel(name: "C3", type: 3, latencyUs: 1048))
    }

    func testParseSupportedSingleState() {
        let result = CStateParser.parseSupported("C1/1/1")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "C1")
    }

    func testParseSupportedEmpty() {
        XCTAssertTrue(CStateParser.parseSupported("").isEmpty)
        XCTAssertTrue(CStateParser.parseSupported("  ").isEmpty)
    }

    func testParseSupportedSkipsMalformed() {
        let result = CStateParser.parseSupported("C1/1/1 garbage C3/3/1048")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "C1")
        XCTAssertEqual(result[1].name, "C3")
    }

    // MARK: - parseUsage

    func testParseUsageWithLast() {
        let result = CStateParser.parseUsage("100.00% 0.00% 0.00% last 775us")
        XCTAssertEqual(result.percentages.count, 3)
        XCTAssertEqual(result.percentages[0], 100.0, accuracy: 0.01)
        XCTAssertEqual(result.percentages[1], 0.0, accuracy: 0.01)
        XCTAssertEqual(result.percentages[2], 0.0, accuracy: 0.01)
        XCTAssertEqual(result.lastDuration, "775us")
    }

    func testParseUsageWithoutLast() {
        let result = CStateParser.parseUsage("50.00% 30.00% 20.00%")
        XCTAssertEqual(result.percentages.count, 3)
        XCTAssertEqual(result.percentages[0], 50.0, accuracy: 0.01)
        XCTAssertNil(result.lastDuration)
    }

    func testParseUsageEmpty() {
        let result = CStateParser.parseUsage("")
        XCTAssertTrue(result.percentages.isEmpty)
        XCTAssertNil(result.lastDuration)
    }

    func testParseUsageMixedResidency() {
        let result = CStateParser.parseUsage("12.34% 56.78% 30.88% last 2ms")
        XCTAssertEqual(result.percentages.count, 3)
        XCTAssertEqual(result.percentages[0], 12.34, accuracy: 0.001)
        XCTAssertEqual(result.percentages[1], 56.78, accuracy: 0.001)
        XCTAssertEqual(result.percentages[2], 30.88, accuracy: 0.001)
        XCTAssertEqual(result.lastDuration, "2ms")
    }

    // MARK: - parseUsageCounters

    func testParseUsageCounters() {
        let result = CStateParser.parseUsageCounters("26644580 0 0")
        XCTAssertEqual(result, [26644580, 0, 0])
    }

    func testParseUsageCountersSingle() {
        XCTAssertEqual(CStateParser.parseUsageCounters("42"), [42])
    }

    func testParseUsageCountersEmpty() {
        XCTAssertTrue(CStateParser.parseUsageCounters("").isEmpty)
    }

    func testParseUsageCountersLargeValues() {
        let result = CStateParser.parseUsageCounters("18446744073709551615 0")
        XCTAssertEqual(result[0], UInt64.max)
    }
}
