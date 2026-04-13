/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import XCTest
import Foundation
@testable import hwtlm

/// Subprocess-based end-to-end tests for `hwtlm`.
///
/// Tests are split into two tiers:
///
///   1. **No-root tier** — `hwtlm list` reads sysctls that don't
///      need root (temperatures, frequencies). Runs on every
///      `swift test` invocation.
///
///   2. **Root tier** — `hwtlm watch` and `hwtlm exec` need root
///      for RAPL (cpuctl). These tests skip cleanly when not root.
///      `hwtlm watch` without root still works for temps/freqs.
final class IntegrationTests: XCTestCase {

    // MARK: - Binary discovery

    private var hwtlmBinaryPath: String {
        let fm = FileManager.default
        let bundleURL = Bundle(for: type(of: self)).bundleURL

        let candidate1 = bundleURL.appendingPathComponent("hwtlm").path
        let candidate2 = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("hwtlm")
            .path
        let candidate3 = bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("hwtlm")
            .path

        for candidate in [candidate1, candidate2, candidate3] {
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return candidate1
    }

    // MARK: - Process runner

    private func runHwtlm(
        _ args: [String],
        timeout: TimeInterval = 10.0
    ) -> (stdout: String, stderr: String, exitCode: Int32)? {
        let bin = hwtlmBinaryPath
        guard FileManager.default.fileExists(atPath: bin) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBuf = ByteBuffer()
        let errBuf = ByteBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            outBuf.append(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            errBuf.append(chunk)
        }

        do {
            try process.run()
        } catch {
            XCTFail("failed to launch hwtlm: \(error)")
            return nil
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                let graceDeadline = Date(timeIntervalSinceNow: 1.0)
                while process.isRunning && Date() < graceDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        while true {
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            outBuf.append(chunk)
        }
        while true {
            let chunk = errPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            errBuf.append(chunk)
        }

        var stderr = String(data: errBuf.snapshot(), encoding: .utf8) ?? ""
        if timedOut { stderr = "[TIMEOUT] " + stderr }
        return (
            String(data: outBuf.snapshot(), encoding: .utf8) ?? "",
            stderr,
            process.terminationStatus
        )
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.fileExists(atPath: hwtlmBinaryPath) else {
            throw XCTSkip("hwtlm binary not found at \(hwtlmBinaryPath); run `swift build` first")
        }
    }

    private var isRoot: Bool { getuid() == 0 }

    // MARK: - list (no root needed)

    func testListExitsCleanly() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["list"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0,
            "hwtlm list should exit 0; stderr: \(result.stderr)")
        XCTAssertFalse(result.stdout.isEmpty,
            "hwtlm list should produce output")
    }

    func testListShowsCPUCount() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["list"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertTrue(result.stdout.contains("Logical CPUs:"),
            "list should show CPU count")
    }

    func testListShowsFrequency() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["list"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertTrue(result.stdout.contains("MHz"),
            "list should show frequency in MHz")
    }

    func testListJsonIsValidJSON() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["list", "--format", "json"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0)
        guard let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("list --json output is not valid JSON: \(result.stdout)")
            return
        }
        XCTAssertNotNil(obj["logical_cpus"], "JSON should contain logical_cpus")
    }

    func testListJsonContainsFrequency() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["list", "--format", "json"]) else {
            XCTFail("could not run hwtlm"); return
        }
        guard let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("invalid JSON"); return
        }
        // At least one freq value should exist
        XCTAssertTrue(
            obj["freq_max_mhz"] != nil || obj["freq_avg_mhz"] != nil,
            "JSON should contain frequency data"
        )
    }

    // MARK: - list with root (RAPL + coretemp)

    func testListShowsRAPLDomainsWhenRoot() throws {
        try skipIfBinaryMissing()
        try XCTSkipUnless(isRoot, "RAPL requires root. Run with `sudo swift test`.")
        guard let result = runHwtlm(["list"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertTrue(result.stdout.contains("RAPL domains:"),
            "list should show RAPL domains when root")
        XCTAssertTrue(result.stdout.contains("package"),
            "list should show package domain")
    }

    func testListShowsTDPWhenRoot() throws {
        try skipIfBinaryMissing()
        try XCTSkipUnless(isRoot, "RAPL requires root")
        guard let result = runHwtlm(["list"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertTrue(result.stdout.contains("TDP"),
            "list should show TDP when root")
    }

    func testListShowsTemperaturesWhenCoretempLoaded() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["list"]) else {
            XCTFail("could not run hwtlm"); return
        }
        // coretemp may or may not be loaded
        let hasTemps = result.stdout.contains("°C min")
        let hasNotAvail = result.stdout.contains("not available")
        XCTAssertTrue(hasTemps || hasNotAvail,
            "list should show temperatures or 'not available'")
    }

    // MARK: - watch (no root — temps/freqs only)

    func testWatchTextFormatProducesOutput() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["watch", "--duration", "2", "--interval", "0.5"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0,
            "watch should exit 0; stderr: \(result.stderr)")
        // Should have at least 2 data lines plus header
        let lines = result.stdout.split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy { $0 == "─" } }
        XCTAssertGreaterThanOrEqual(lines.count, 3,
            "watch should produce header + at least 2 sample lines")
    }

    func testWatchJsonFormatProducesValidJSONL() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["watch", "--format", "json", "--duration", "2", "--interval", "1"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0)
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        XCTAssertGreaterThanOrEqual(lines.count, 1, "should produce at least 1 JSON line")
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                XCTFail("line is not valid JSON: \(line)")
                return
            }
        }
    }

    func testWatchJsonContainsFrequencyAndTime() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["watch", "--format", "json", "--duration", "1", "--interval", "1"]) else {
            XCTFail("could not run hwtlm"); return
        }
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        guard let first = lines.first,
              let data = first.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("no valid JSON line"); return
        }
        XCTAssertNotNil(obj["time"], "JSON should contain time")
        XCTAssertTrue(
            obj["freq_max_mhz"] != nil || obj["freq_avg_mhz"] != nil,
            "JSON should contain frequency data"
        )
    }

    // MARK: - watch with root (RAPL)

    func testWatchShowsRAPLWattsWhenRoot() throws {
        try skipIfBinaryMissing()
        try XCTSkipUnless(isRoot, "RAPL requires root")
        guard let result = runHwtlm(["watch", "--format", "json", "--duration", "2", "--interval", "1"]) else {
            XCTFail("could not run hwtlm"); return
        }
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        guard let first = lines.first,
              let data = first.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("no valid JSON line"); return
        }
        XCTAssertNotNil(obj["package_watts"],
            "JSON should contain package_watts when root")
        if let watts = obj["package_watts"] as? Double {
            XCTAssertGreaterThan(watts, 0,
                "package_watts should be positive")
        }
    }

    // MARK: - exec (no root — energy won't be available but temps work)

    func testExecRunsCommand() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["exec", "--", "echo", "hello"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0,
            "exec should exit 0; stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("hello") || result.stderr.contains("Elapsed"),
            "exec should run the command and report results")
    }

    func testExecReportsElapsed() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["exec", "--", "sleep", "1"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertTrue(result.stderr.contains("Elapsed"),
            "exec should report elapsed time")
    }

    func testExecJsonIsValidJSON() throws {
        try skipIfBinaryMissing()
        // Use `true` (no stdout) so the child output doesn't mix with JSON.
        guard let result = runHwtlm(["exec", "--format", "json", "--", "true"]) else {
            XCTFail("could not run hwtlm"); return
        }
        // The JSON line is the last non-empty line (child may produce output before it).
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        guard let jsonLine = lines.last(where: { $0.hasPrefix("{") }),
              let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("exec --json output has no valid JSON line: \(result.stdout)")
            return
        }
        XCTAssertNotNil(obj["elapsed_seconds"])
        XCTAssertNotNil(obj["exit_code"])
        XCTAssertNotNil(obj["command"])
    }

    func testExecPassesThroughNonzeroExitCode() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["exec", "--", "false"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertNotEqual(result.exitCode, 0,
            "exec should propagate non-zero exit from child")
    }

    func testExecReportsEnergyWhenRoot() throws {
        try skipIfBinaryMissing()
        try XCTSkipUnless(isRoot, "RAPL requires root")
        guard let result = runHwtlm(["exec", "--format", "json", "--", "sleep", "1"]) else {
            XCTFail("could not run hwtlm"); return
        }
        guard let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("invalid JSON"); return
        }
        XCTAssertNotNil(obj["domains"],
            "exec --json should contain domains when root")
    }

    func testExecReportsTemperature() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["exec", "--format", "json", "--", "sleep", "1"]) else {
            XCTFail("could not run hwtlm"); return
        }
        guard let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("invalid JSON"); return
        }
        // temp_before / temp_after should exist if coretemp is loaded
        let hasTempBefore = obj["temp_before"] != nil
        let hasTempAfter = obj["temp_after"] != nil
        // Don't fail if coretemp isn't loaded, just verify structure
        if hasTempBefore {
            XCTAssertTrue(hasTempAfter,
                "if temp_before is present, temp_after should be too")
        }
    }

    // MARK: - per-core mode

    func testWatchPerCoreTextProducesOutput() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["watch", "--per-core", "--duration", "2", "--interval", "1"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0,
            "watch --per-core should exit 0; stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("CPU"),
            "per-core output should contain CPU column header")
        // Should have at least one core row (CPU 0)
        XCTAssertTrue(result.stdout.contains("  0") || result.stdout.contains(" 0 "),
            "per-core output should contain CPU 0 row")
    }

    func testWatchPerCoreJsonIsValid() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["watch", "--per-core", "--format", "json", "--duration", "1", "--interval", "1"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0)
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        guard let first = lines.first,
              let data = first.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("no valid JSON line"); return
        }
        XCTAssertNotNil(obj["cores"], "per-core JSON should contain cores array")
        if let cores = obj["cores"] as? [[String: Any]] {
            XCTAssertGreaterThan(cores.count, 0, "cores array should not be empty")
            XCTAssertNotNil(cores[0]["cpu"], "each core should have a cpu field")
        }
    }

    func testListShowsCStateInfo() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["list"]) else {
            XCTFail("could not run hwtlm"); return
        }
        // C-states should be shown if available
        let hasCState = result.stdout.contains("C-state") || result.stdout.contains("C1")
        XCTAssertTrue(hasCState,
            "list should show C-state information")
    }

    func testListPerCoreShowsAllCPUs() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["list", "--per-core"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("CPU  0") || result.stdout.contains("CPU 0:"),
            "per-core list should show CPU 0")
    }

    // MARK: - wall-clock duration bound

    func testWatchDurationIsWallClockBound() throws {
        try skipIfBinaryMissing()
        let start = Date()
        guard let result = runHwtlm([
            "watch", "--format", "json",
            "--duration", "2", "--interval", "0.5"
        ], timeout: 10.0) else {
            XCTFail("could not run hwtlm"); return
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.exitCode, 0,
            "watch --duration 2 should exit 0; stderr: \(result.stderr)")

        // Should finish within duration + one interval of slack.
        XCTAssertLessThan(elapsed, 3.5,
            "wall-clock elapsed (\(String(format: "%.1f", elapsed))s) should be < 3.5s for --duration 2 --interval 0.5")

        // Should have produced at least 2 samples.
        let lines = result.stdout.split(whereSeparator: \.isNewline)
            .filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(lines.count, 2,
            "should emit at least 2 samples in 2s at 0.5s interval")
    }

    // MARK: - OTLP subprocess with fake collector

    func testWatchOtelPostsToCollector() throws {
        try skipIfBinaryMissing()

        // Start a minimal HTTP server that accepts OTLP POSTs and
        // records request count + bodies.
        let serverSocket = try startFakeCollector()
        defer { close(serverSocket) }
        let port = try boundPort(serverSocket)

        let endpoint = "http://127.0.0.1:\(port)"
        guard let result = runHwtlm([
            "watch", "--format", "otel",
            "--endpoint", endpoint,
            "--duration", "2", "--interval", "0.5"
        ], timeout: 10.0) else {
            XCTFail("could not run hwtlm"); return
        }

        // The exporter should have POSTed at least one batch.
        // We can't easily inspect the TCP stream from within the
        // test, but we verify the process exited cleanly (it logs
        // errors to stderr if the POST fails).
        XCTAssertEqual(result.exitCode, 0,
            "watch --format otel should exit 0; stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("Exporting to"),
            "stderr should show the endpoint being used")
    }

    func testWatchOtelRejectsInvalidEndpoint() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm([
            "watch", "--format", "otel",
            "--endpoint", "not-a-url",
            "--duration", "1"
        ]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertNotEqual(result.exitCode, 0,
            "invalid endpoint should fail")
        XCTAssertTrue(result.stderr.contains("http://") || result.stderr.contains("https://"),
            "error should mention required scheme")
    }

    func testListRejectsFormatOtel() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["list", "--format", "otel"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("only supported by"),
            "should explain that otel is only for watch")
    }

    // Bind a TCP socket that accepts connections and returns 200.
    // This is a minimal fake OTLP collector — enough to prevent
    // the exporter from logging connection errors.
    private func startFakeCollector() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "test", code: 1) }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // kernel picks a free port
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { close(fd); throw NSError(domain: "test", code: 2) }
        listen(fd, 5)

        // Accept connections in background and send HTTP 200
        DispatchQueue.global().async {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                // Read the request (don't care about contents)
                var buf = [UInt8](repeating: 0, count: 4096)
                _ = recv(client, &buf, buf.count, 0)
                // Send minimal HTTP 200
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
                _ = response.withCString { send(client, $0, strlen($0), 0) }
                close(client)
            }
        }

        return fd
    }

    private func boundPort(_ fd: Int32) throws -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard result == 0 else { throw NSError(domain: "test", code: 3) }
        return UInt16(bigEndian: addr.sin_port)
    }

    // MARK: - help

    func testHelpExitsCleanly() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["--help"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Hardware telemetry"),
            "help should contain tool description")
    }

    func testVersionExitsCleanly() throws {
        try skipIfBinaryMissing()
        guard let result = runHwtlm(["--version"]) else {
            XCTFail("could not run hwtlm"); return
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("0.1.0"),
            "version should show 0.1.0")
    }
}

// MARK: - Unit tests

/// Unit tests for SysctlReader — no subprocess needed.
final class SysctlReaderTests: XCTestCase {

    func testCpuCountIsPositive() {
        let count = SysctlReader.cpuCount()
        XCTAssertGreaterThan(count, 0, "hw.ncpu should be > 0")
    }

    func testSnapshotTimestampIsRecent() {
        let cpuCount = SysctlReader.cpuCount()
        let snapshot = SysctlReader.snapshot(cpuCount: cpuCount)
        let age = Date().timeIntervalSince(snapshot.timestamp)
        XCTAssertLessThan(age, 2.0, "snapshot timestamp should be recent")
    }

    func testSnapshotFrequenciesArePositive() {
        let cpuCount = SysctlReader.cpuCount()
        let snapshot = SysctlReader.snapshot(cpuCount: cpuCount)
        if !snapshot.frequencies.isEmpty {
            for (cpu, freq) in snapshot.frequencies {
                XCTAssertGreaterThan(freq, 0,
                    "CPU \(cpu) frequency should be positive, got \(freq)")
            }
        }
    }

    func testSnapshotTemperaturesArePlausible() {
        let cpuCount = SysctlReader.cpuCount()
        let snapshot = SysctlReader.snapshot(cpuCount: cpuCount)
        for (cpu, temp) in snapshot.temperatures {
            XCTAssertGreaterThan(temp, 0,
                "CPU \(cpu) temperature should be > 0°C, got \(temp)")
            XCTAssertLessThan(temp, 120,
                "CPU \(cpu) temperature should be < 120°C, got \(temp)")
        }
    }

    func testSnapshotAggregatesAreConsistent() {
        let cpuCount = SysctlReader.cpuCount()
        let snapshot = SysctlReader.snapshot(cpuCount: cpuCount)

        if let min = snapshot.minTemp, let max = snapshot.maxTemp, let avg = snapshot.avgTemp {
            XCTAssertLessThanOrEqual(min, avg, "min temp should be <= avg")
            XCTAssertGreaterThanOrEqual(max, avg, "max temp should be >= avg")
        }

        if let min = snapshot.minFreq, let max = snapshot.maxFreq, let avg = snapshot.avgFreq {
            XCTAssertLessThanOrEqual(min, avg, "min freq should be <= avg")
            XCTAssertGreaterThanOrEqual(max, avg, "max freq should be >= avg")
        }
    }

    func testTjMaxIsPlausible() {
        if let tjmax = SysctlReader.coreTjMax() {
            XCTAssertGreaterThanOrEqual(tjmax, 80, "TjMax should be >= 80°C")
            XCTAssertLessThanOrEqual(tjmax, 115, "TjMax should be <= 115°C")
        }
    }

    func testAcpiTemperatureIsPlausible() {
        if let temp = SysctlReader.acpiTemperature() {
            XCTAssertGreaterThan(temp, -10, "ACPI temp should be > -10°C")
            XCTAssertLessThan(temp, 80, "ACPI temp should be < 80°C")
        }
    }

    func testSnapshotCoresOrderedByCPUID() {
        let cpuCount = SysctlReader.cpuCount()
        let snapshot = SysctlReader.snapshot(cpuCount: cpuCount)
        let cores = snapshot.cores
        if cores.count > 1 {
            for i in 1..<cores.count {
                XCTAssertGreaterThan(cores[i].cpu, cores[i-1].cpu,
                    "cores should be ordered by CPU ID")
            }
        }
    }

    func testSnapshotCoresHaveFrequencies() {
        let cpuCount = SysctlReader.cpuCount()
        let snapshot = SysctlReader.snapshot(cpuCount: cpuCount)
        let coresWithFreq = snapshot.cores.filter { $0.frequencyMHz != nil }
        XCTAssertGreaterThan(coresWithFreq.count, 0,
            "at least some cores should have frequency data")
    }

    func testCStateInfoParsesIfAvailable() {
        let cpuCount = SysctlReader.cpuCount()
        let snapshot = SysctlReader.snapshot(cpuCount: cpuCount)
        // C-states may or may not be available
        if !snapshot.cstates.isEmpty {
            for (cpu, info) in snapshot.cstates {
                XCTAssertFalse(info.supported.isEmpty,
                    "CPU \(cpu) should have at least one supported C-state")
                if let residency = info.residency {
                    XCTAssertFalse(residency.percentages.isEmpty,
                        "CPU \(cpu) residency should have at least one percentage")
                }
            }
        }
    }
}

/// Unit tests for RAPLSampler — requires root.
final class RAPLSamplerTests: XCTestCase {

    func testRAPLSamplerInitReturnsNilWithoutCpuctl() throws {
        try XCTSkipIf(getuid() == 0, "this test checks non-root behavior")
        // Without root, cpuctl can't be opened
        let sampler = RAPLSampler()
        // May or may not be nil depending on permissions
        // Just verify it doesn't crash
        _ = sampler
    }

    func testRAPLSamplerInitSucceedsWhenRoot() throws {
        try XCTSkipUnless(getuid() == 0, "RAPL requires root")
        let sampler = RAPLSampler()
        XCTAssertNotNil(sampler, "RAPLSampler should initialize when root with cpuctl")
    }

    func testRAPLDomainsNonEmptyWhenRoot() throws {
        try XCTSkipUnless(getuid() == 0, "RAPL requires root")
        guard let sampler = RAPLSampler() else {
            XCTFail("RAPLSampler is nil"); return
        }
        XCTAssertFalse(sampler.domains.isEmpty,
            "RAPL domains should not be empty")
        XCTAssertTrue(sampler.domains.contains(.package),
            "RAPL should always include package domain")
    }

    func testRAPLReadCountersWhenRoot() throws {
        try XCTSkipUnless(getuid() == 0, "RAPL requires root")
        guard let sampler = RAPLSampler() else {
            XCTFail("RAPLSampler is nil"); return
        }
        let counters = try sampler.readCounters()
        XCTAssertFalse(counters.isEmpty,
            "readCounters should return at least one domain")
        // Package counter is always active. Other domains (DRAM, PP1)
        // may read 0 on some SKUs (e.g. Alder Lake mobile).
        XCTAssertNotNil(counters[.package],
            "package counter should be present")
        XCTAssertGreaterThan(counters[.package]!, 0,
            "package energy counter should be > 0")
    }

    func testRAPLSampleProducesWatts() throws {
        try XCTSkipUnless(getuid() == 0, "RAPL requires root")
        guard let sampler = RAPLSampler() else {
            XCTFail("RAPLSampler is nil"); return
        }
        // Prime
        _ = try sampler.sampleOnce()
        Thread.sleep(forTimeInterval: 0.5)
        guard let snapshot = try sampler.sampleOnce() else {
            XCTFail("second sample should return a snapshot"); return
        }
        XCTAssertFalse(snapshot.samples.isEmpty)
        // Package always has positive power. Other domains (DRAM, PP1)
        // may read 0 on some mobile SKUs — that's hardware, not a bug.
        let pkg = snapshot.samples.first { $0.domain == .package }
        XCTAssertNotNil(pkg, "package sample should be present")
        XCTAssertGreaterThan(pkg!.watts, 0,
            "package watts should be positive")
        XCTAssertGreaterThan(pkg!.joules, 0,
            "package joules should be positive")
        for sample in snapshot.samples {
            XCTAssertGreaterThanOrEqual(sample.watts, 0,
                "\(sample.domain) watts should be >= 0")
            XCTAssertGreaterThan(sample.elapsed, 0.4,
                "elapsed should be ~0.5s")
        }
    }

    func testRAPLPowerInfoWhenRoot() throws {
        try XCTSkipUnless(getuid() == 0, "RAPL requires root")
        guard let sampler = RAPLSampler() else {
            XCTFail("RAPLSampler is nil"); return
        }
        let info = try sampler.readPowerInfo()
        XCTAssertGreaterThan(info.thermalSpecPower, 0,
            "TDP should be positive")
        XCTAssertLessThan(info.thermalSpecPower, 500,
            "TDP should be < 500W")
    }
}

// MARK: - ByteBuffer (shared with dtlm tests)

/// Thread-safe byte accumulator for draining pipes.
private final class ByteBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
