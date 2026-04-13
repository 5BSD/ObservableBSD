/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import XCTest
import Foundation
@testable import dtlm
@testable import OTelExport

/// Unit tests for `JSONLExporter` — JSON encoding correctness, body
/// escaping, stack array shape, and round-tripping the produced
/// output through `JSONSerialization` to verify it's valid JSON.
final class JSONLExporterTests: XCTestCase {

    private func makeResource() -> ResourceAttributes {
        ResourceAttributes(
            serviceName: "dtlm",
            serviceInstanceId: nil,
            hostName: "test-host",
            osName: "freebsd",
            osVersion: "15.0",
            serviceVersion: "0.1.0",
            custom: [:]
        )
    }

    /// Drive the exporter against an in-memory pipe so we can read
    /// what it wrote and assert on the bytes.
    private func runExporter(
        profileName: String = "kill",
        _ block: (JSONLExporter) throws -> Void
    ) rethrows -> String {
        let pipe = Pipe()
        let exporter = JSONLExporter(
            profileName: profileName,
            output: pipe.fileHandleForWriting,
            resource: makeResource()
        )
        try block(exporter)
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - escapeJSON helper

    func testEscapeJSONHandlesQuotesAndBackslashes() {
        XCTAssertEqual(escapeJSON("plain"), "plain")
        XCTAssertEqual(escapeJSON(#"with "quote""#), #"with \"quote\""#)
        XCTAssertEqual(escapeJSON(#"back\slash"#), #"back\\slash"#)
        XCTAssertEqual(escapeJSON("line\nfeed"), #"line\nfeed"#)
        XCTAssertEqual(escapeJSON("tab\there"), #"tab\there"#)
        XCTAssertEqual(escapeJSON("carriage\rreturn"), #"carriage\rreturn"#)
    }

    func testEscapeJSONHandlesControlCharacters() {
        // 0x01 is below 0x20 and not in the named-escape set, so it
        // should become \u0001.
        XCTAssertEqual(escapeJSON("\u{01}"), "\\u0001")
        // 0x7f is above 0x20 and should pass through unchanged.
        XCTAssertEqual(escapeJSON("\u{7f}"), "\u{7f}")
    }

    // MARK: - emit(event:) basic shape

    func testEmitProducesValidJSON() throws {
        let output = try runExporter { exporter in
            try exporter.start()
            try exporter.emit(event: ProbeEvent(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                profileName: "kill",
                probeName: "",
                pid: 0,
                execname: "",
                printfBody: "nginx[4123]: signal 15 to pid 4567",
                stack: nil,
                ustack: nil
            ))
            try exporter.flush()
            try exporter.shutdown()
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "one event = one line")

        // Each line must round-trip through JSONSerialization.
        guard let data = String(lines[0]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("emitted line is not valid JSON: \(lines[0])")
            return
        }
        XCTAssertEqual(obj["profile"] as? String, "kill")
        XCTAssertEqual(obj["body"] as? String, "nginx[4123]: signal 15 to pid 4567")
        XCTAssertNotNil(obj["time"] as? String)
    }

    func testEmitSkipsEventsWithEmptyBody() throws {
        let output = try runExporter { exporter in
            try exporter.start()
            try exporter.emit(event: ProbeEvent(
                timestamp: Date(),
                profileName: "kill",
                probeName: "",
                pid: 0,
                execname: "",
                printfBody: "",
                stack: nil,
                ustack: nil
            ))
            try exporter.emit(event: ProbeEvent(
                timestamp: Date(),
                profileName: "kill",
                probeName: "",
                pid: 0,
                execname: "",
                printfBody: nil,
                stack: nil,
                ustack: nil
            ))
        }
        XCTAssertTrue(output.isEmpty,
                      "events with empty/nil printfBody should be dropped, got: '\(output)'")
    }

    func testEmitMultipleEventsProducesOneLineEach() throws {
        let output = try runExporter { exporter in
            try exporter.start()
            for i in 0..<5 {
                try exporter.emit(event: ProbeEvent(
                    timestamp: Date(),
                    profileName: "kill",
                    probeName: "",
                    pid: 0,
                    execname: "",
                    printfBody: "event \(i)",
                    stack: nil,
                    ustack: nil
                ))
            }
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 5)
        for (i, line) in lines.enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                XCTFail("line \(i) is not valid JSON: \(line)")
                continue
            }
            XCTAssertEqual(obj["body"] as? String, "event \(i)")
        }
    }

    // MARK: - body escaping

    func testEmitEscapesEmbeddedQuotesInBody() throws {
        let output = try runExporter { exporter in
            try exporter.start()
            try exporter.emit(event: ProbeEvent(
                timestamp: Date(),
                profileName: "open",
                probeName: "",
                pid: 0,
                execname: "",
                printfBody: #"nginx[1]: open("/etc/nginx.conf")"#,
                stack: nil,
                ustack: nil
            ))
        }
        let line = output.trimmingCharacters(in: .newlines)
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("escaped line is not valid JSON: \(line)")
            return
        }
        XCTAssertEqual(obj["body"] as? String, #"nginx[1]: open("/etc/nginx.conf")"#)
    }

    func testEmitEscapesBackslashesAndNewlinesInBody() throws {
        let body = #"path\with\backslashes and\nembedded newlines"#
        let output = try runExporter { exporter in
            try exporter.start()
            try exporter.emit(event: ProbeEvent(
                timestamp: Date(),
                profileName: "x",
                probeName: "",
                pid: 0,
                execname: "",
                printfBody: body,
                stack: nil,
                ustack: nil
            ))
        }
        let line = output.trimmingCharacters(in: .newlines)
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("escaped line is not valid JSON: \(line)")
            return
        }
        XCTAssertEqual(obj["body"] as? String, body)
    }

    // MARK: - stack arrays

    func testEmitIncludesStackArrayWhenProvided() throws {
        let stack = [
            StackFrame(address: 0xffff_0000_dead_beef, module: "kernel", symbol: "vm_fault", offset: 0x42),
            StackFrame(address: 0xffff_0000_cafe_babe, module: "kernel", symbol: "trap", offset: 0x10),
        ]
        let output = try runExporter { exporter in
            try exporter.start()
            try exporter.emit(event: ProbeEvent(
                timestamp: Date(),
                profileName: "kill",
                probeName: "",
                pid: 0,
                execname: "",
                printfBody: "fault",
                stack: stack,
                ustack: nil
            ))
        }
        let line = output.trimmingCharacters(in: .newlines)
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("line with stack is not valid JSON: \(line)")
            return
        }
        guard let stackArr = obj["stack"] as? [String] else {
            XCTFail("stack array missing or wrong type")
            return
        }
        XCTAssertEqual(stackArr.count, 2)
        XCTAssertEqual(stackArr[0], "kernel`vm_fault+0x42")
        XCTAssertEqual(stackArr[1], "kernel`trap+0x10")
    }

    func testEmitIncludesUstackArrayWhenProvided() throws {
        let ustack = [
            StackFrame(address: 0x1000, module: "libc.so.7", symbol: "malloc", offset: nil),
        ]
        let output = try runExporter { exporter in
            try exporter.start()
            try exporter.emit(event: ProbeEvent(
                timestamp: Date(),
                profileName: "alloc",
                probeName: "",
                pid: 0,
                execname: "",
                printfBody: "malloc",
                stack: nil,
                ustack: ustack
            ))
        }
        let line = output.trimmingCharacters(in: .newlines)
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("line with ustack is not valid JSON: \(line)")
            return
        }
        guard let ustackArr = obj["ustack"] as? [String] else {
            XCTFail("ustack array missing or wrong type")
            return
        }
        XCTAssertEqual(ustackArr.count, 1)
        XCTAssertEqual(ustackArr[0], "libc.so.7`malloc")
    }

    func testEmitOmitsStackFieldsWhenAbsent() throws {
        let output = try runExporter { exporter in
            try exporter.start()
            try exporter.emit(event: ProbeEvent(
                timestamp: Date(),
                profileName: "kill",
                probeName: "",
                pid: 0,
                execname: "",
                printfBody: "no-stacks",
                stack: nil,
                ustack: nil
            ))
        }
        let line = output.trimmingCharacters(in: .newlines)
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("not valid JSON")
            return
        }
        XCTAssertNil(obj["stack"], "stack field should be absent when no stack captured")
        XCTAssertNil(obj["ustack"], "ustack field should be absent when no ustack captured")
    }

    // MARK: - Static metadata

    func testFormatNameIsJson() {
        XCTAssertEqual(JSONLExporter.formatName, "json")
    }
}
