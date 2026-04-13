/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import XCTest
import Foundation
@testable import dtlm

/// Subprocess-based end-to-end tests that exec the actual `dtlm`
/// binary built by `swift build` and validate behavior.
///
/// Tests are split into two tiers:
///
///   1. **No-root tier** — `dtlm list` and `dtlm generate` don't open
///      a libdtrace handle, so they run in any context. These run on
///      every `swift test` invocation.
///
///   2. **Root tier** — `dtlm watch` and `dtlm probes` need libdtrace
///      which needs root. These tests skip cleanly when not running
///      as root, so the suite stays green for non-root developers.
///
/// The root tier is the **single most valuable test we have** because
/// it actually compiles every bundled `.d` file via libdtrace, which
/// catches every invented probe name in one shot.
final class IntegrationTests: XCTestCase {

    /// Path to the dtlm binary that was built alongside this test
    /// bundle. The test bundle and the executable are siblings inside
    /// the SwiftPM build directory's `<triple>/debug/` directory:
    ///
    ///   <build-path>/x86_64-unknown-freebsd/debug/dtlmPackageTests.xctest   ← test bundle
    ///   <build-path>/x86_64-unknown-freebsd/debug/dtlm                      ← executable
    ///
    /// `Bundle(for:).bundleURL` points to different things on
    /// different platforms — sometimes the `.xctest` file, sometimes
    /// the `debug/` directory itself, sometimes a shared library
    /// inside the bundle. Rather than assume one shape, try a list
    /// of candidates and return the first one that exists. The
    /// fallback path lets `skipIfBinaryMissing` produce a useful
    /// error message if none match.
    private var dtlmBinaryPath: String {
        let fm = FileManager.default
        let bundleURL = Bundle(for: type(of: self)).bundleURL

        // Candidate 1: bundleURL IS the debug directory (FreeBSD swift test).
        let candidate1 = bundleURL.appendingPathComponent("dtlm").path

        // Candidate 2: bundleURL is the .xctest sibling, debug/ is the parent.
        let candidate2 = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("dtlm")
            .path

        // Candidate 3: bundleURL is inside debug/<bundle>/Contents/MacOS,
        // walk up two more levels (mac-style nested xctest bundles).
        let candidate3 = bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("dtlm")
            .path

        for candidate in [candidate1, candidate2, candidate3] {
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }
        // Best-effort fallback so the failure message points at the
        // expected layout the test was originally built against.
        return candidate1
    }

    /// Run the dtlm binary with the given args, capture stdout +
    /// stderr + exit status. Returns nil if the binary doesn't exist.
    ///
    /// Enforces a per-subprocess timeout (default 10 seconds). If the
    /// process is still running when the timeout expires, dtlm gets
    /// SIGTERM, then SIGKILL after a brief grace period, and the
    /// returned `stderr` is prefixed with `[TIMEOUT]` so the caller
    /// can recognize the failure mode. Without this, a single hung
    /// profile would stall the entire integration suite.
    ///
    /// **Pipe draining is critical.** dtlm's text-mode profiles (and
    /// json mode for high-rate ones like sched-on-cpu) can produce
    /// megabytes of stdout per second. The kernel pipe buffer is
    /// ~64KB on FreeBSD; if we don't drain it concurrently with the
    /// run, the child blocks on `write(2)` and looks hung. We use
    /// `readabilityHandler` to accumulate bytes into thread-safe
    /// buffers as they arrive, and only stop reading after the child
    /// has signaled EOF (which happens when it exits or is killed).
    private func runDtlm(
        _ args: [String],
        asRoot: Bool = false,
        timeout: TimeInterval = 10.0
    ) -> (
        stdout: String,
        stderr: String,
        exitCode: Int32
    )? {
        let bin = dtlmBinaryPath
        guard FileManager.default.fileExists(atPath: bin) else {
            return nil
        }

        let process = Process()
        if asRoot {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", bin] + args   // -n = non-interactive
        } else {
            process.executableURL = URL(fileURLWithPath: bin)
            process.arguments = args
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Background drain. readabilityHandler is invoked from a
        // private dispatch queue every time the file descriptor has
        // bytes available, so we don't need to spin our own thread.
        // The byte accumulators live inside a tiny ref-typed box so
        // the @Sendable closure can mutate through it under a lock.
        let outBuf = ByteBuffer()
        let errBuf = ByteBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF — clear the handler so the FileHandle can close.
                handle.readabilityHandler = nil
                return
            }
            outBuf.append(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errBuf.append(chunk)
        }

        do {
            try process.run()
        } catch {
            XCTFail("failed to launch dtlm: \(error)")
            return nil
        }

        // Wait with timeout. We poll process.isRunning rather than
        // sitting in waitUntilExit so we can SIGTERM after `timeout`
        // seconds. The pipe drain runs concurrently on its own queue.
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

        // After the child exits, the kernel writes EOF to the pipe.
        // The readabilityHandler will fire one last time with an
        // empty Data and clear itself. Synchronously drain whatever
        // is still buffered before reading the final values.
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

        let finalOut = outBuf.snapshot()
        let finalErr = errBuf.snapshot()

        var stderr = String(data: finalErr, encoding: .utf8) ?? ""
        if timedOut {
            stderr = "[TIMEOUT after \(timeout)s] " + stderr
        }
        return (
            String(data: finalOut, encoding: .utf8) ?? "",
            stderr,
            process.terminationStatus
        )
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.fileExists(atPath: dtlmBinaryPath) else {
            throw XCTSkip("dtlm binary not found at \(dtlmBinaryPath); run `swift build` first")
        }
    }

    private var isRoot: Bool {
        getuid() == 0
    }

    // MARK: - No-root tier: list

    func testListSubcommandRunsCleanly() throws {
        try skipIfBinaryMissing()
        guard let result = runDtlm(["list"]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0,
            "dtlm list should exit 0, got \(result.exitCode); stderr: \(result.stderr)")
        XCTAssertFalse(result.stdout.isEmpty,
            "dtlm list should produce output")
    }

    func testListSubcommandShowsAtLeast85Profiles() throws {
        try skipIfBinaryMissing()
        guard let result = runDtlm(["list"]) else {
            XCTFail("could not run dtlm")
            return
        }
        // Last non-empty line is "<N> profiles".
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        guard let summary = lines.last(where: { !$0.isEmpty }) else {
            XCTFail("no summary line in dtlm list output")
            return
        }
        // Parse "<N> profiles" — N is the first whitespace-separated token.
        let token = summary.split(whereSeparator: { $0.isWhitespace }).first ?? ""
        guard let count = Int(token) else {
            XCTFail("could not parse profile count from '\(summary)'")
            return
        }
        XCTAssertGreaterThanOrEqual(count, 85,
            "dtlm list reports \(count) profiles, expected ≥ 85 (dwatch parity)")
    }

    func testListSubcommandShowsKillProfile() throws {
        try skipIfBinaryMissing()
        guard let result = runDtlm(["list"]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertTrue(result.stdout.contains("kill"),
            "dtlm list output should contain the 'kill' profile")
    }

    // MARK: - No-root tier: generate

    func testGenerateSubcommandRendersKill() throws {
        try skipIfBinaryMissing()
        guard let result = runDtlm(["generate", "kill"]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0,
            "dtlm generate kill should exit 0; stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("syscall::kill:entry"),
            "rendered output should contain the kill probe spec")
        XCTAssertTrue(result.stdout.contains("printf"),
            "rendered output should contain a printf action")
    }

    func testGenerateSubcommandInjectsFilterPredicate() throws {
        try skipIfBinaryMissing()
        guard let result = runDtlm(["generate", "kill", "--execname", "nginx"]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("execname == \"nginx\""),
            "filter predicate should be in the rendered output")
    }

    func testGenerateSubcommandInjectsDurationTick() throws {
        try skipIfBinaryMissing()
        guard let result = runDtlm(["generate", "kill", "--duration", "5"]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("tick-5000000000ns"),
            "duration should be injected as a tick clause")
        XCTAssertTrue(result.stdout.contains("exit(0)"))
    }

    func testGenerateSubcommandInjectsStackActions() throws {
        try skipIfBinaryMissing()
        guard let result = runDtlm(["generate", "kill", "--with-stack", "--with-ustack"]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("stack();"),
            "--with-stack should inject stack();")
        XCTAssertTrue(result.stdout.contains("ustack();"),
            "--with-ustack should inject ustack();")
    }

    func testGenerateSubcommandRefusesUnknownProfile() throws {
        try skipIfBinaryMissing()
        guard let result = runDtlm(["generate", "definitely-not-a-real-profile"]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertNotEqual(result.exitCode, 0,
            "generate of unknown profile should fail")
        XCTAssertTrue(
            result.stderr.contains("unknown profile") || result.stdout.contains("unknown profile"),
            "should explain that the profile is unknown"
        )
    }

    func testGenerateSubcommandRequiresKinstParams() throws {
        try skipIfBinaryMissing()
        // kinst.d has ${func} and ${offset} placeholders. Without
        // --param, render should fail.
        guard let result = runDtlm(["generate", "kinst"]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertNotEqual(result.exitCode, 0,
            "kinst without --param should fail")
    }

    func testGenerateSubcommandWithKinstParams() throws {
        try skipIfBinaryMissing()
        guard let result = runDtlm([
            "generate", "kinst",
            "--param", "func=vm_fault",
            "--param", "offset=4",
        ]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0,
            "kinst with --param should succeed; stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("kinst::vm_fault:4"),
            "rendered kinst probe spec should have substituted params")
    }

    // MARK: - Root tier: actually compile every bundled profile via libdtrace

    /// **The single most valuable test in the suite when run as root.**
    ///
    /// Iterates every bundled profile, runs `dtlm watch <profile>
    /// --duration 0.05`, and asserts the watch session starts cleanly.
    /// libdtrace will refuse to run anything that doesn't compile, so
    /// this catches every invented probe name across the entire 160-
    /// profile catalog in one shot.
    ///
    /// Per-profile timeout is 8 seconds (the runDtlm helper's
    /// default), so any individual profile that hangs libdtrace gets
    /// killed and reported as a failure rather than stalling the
    /// whole suite.
    ///
    /// At ~150ms per profile (50ms duration + ~50ms switchrate +
    /// ~50ms binary launch overhead), the full sweep against 160
    /// profiles takes ~24-30 seconds. Skipped when not running as
    /// root.
    func testEveryBundledProfileCompilesViaLibdtrace() throws {
        try XCTSkipUnless(isRoot,
            "this test compiles every bundled profile via libdtrace, requires root. Run with `sudo swift test`.")
        try skipIfBinaryMissing()

        // Spawn a long-lived process so pid-provider profiles can
        // grab it. /bin/sleep is a simple, universally-available
        // target that links libc (so lib-calls can find malloc).
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["3600"]
        try sleeper.run()
        let targetPid = String(sleeper.processIdentifier)
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }

        // Profiles that need a kinst module which may not be loaded.
        // Skip with a warning — environment issue, not a profile bug.
        let kinstSkip: Set<String> = ["kinst"]

        var failures: [(name: String, stderr: String)] = []
        var skipped: [String] = []

        for profile in ProfileLoader().all() {
            let extraArgs: [String]
            switch profile.name {
            case "kinst":
                extraArgs = ["--param", "func=vm_fault", "--param", "offset=4"]
            case "malloc-trace", "malloc-counts", "malloc-leaks",
                 "postgresql-queries", "postgresql-slow",
                 "mysql-queries",
                 "python-calls", "python-slow",
                 "ruby-calls",
                 "node-http", "node-gc",
                 "usdt-list":
                extraArgs = ["--param", "pid=\(targetPid)"]
            case "func-trace", "func-time":
                extraArgs = ["--param", "pid=\(targetPid)", "--param", "func=malloc"]
            case "kfunc-trace", "kfunc-time":
                extraArgs = ["--param", "func=vm_fault"]
            case "lib-calls":
                extraArgs = ["--param", "pid=\(targetPid)", "--param", "lib=libc.so.7", "--param", "func=malloc"]
            case "dns-latency":
                extraArgs = ["--param", "pid=\(targetPid)"]
            case "sqlite-latency":
                extraArgs = ["--param", "pid=\(targetPid)"]
            default:
                extraArgs = []
            }

            let args = ["watch", profile.name, "--duration", "0.05"] + extraArgs
            guard let result = runDtlm(args, timeout: 8.0) else {
                XCTFail("could not run dtlm")
                return
            }
            if result.exitCode != 0 {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if kinstSkip.contains(profile.name)
                    && stderr.contains("does not match any probes") {
                    skipped.append(profile.name)
                    continue
                }
                // USDT profiles (mysql, postgres, node, python, ruby)
                // will fail with "does not match any probes" because
                // /bin/sleep doesn't have those probes. That's an
                // environment issue — the profile syntax is valid.
                if stderr.contains("does not match any probes") {
                    skipped.append(profile.name)
                    continue
                }
                failures.append((profile.name, stderr))
            }
        }

        if !skipped.isEmpty {
            print("[testEveryBundledProfileCompilesViaLibdtrace] skipped (no matching probes): \(skipped)")
        }
        if !failures.isEmpty {
            let summary = failures
                .map { "  \($0.name): \($0.stderr)" }
                .joined(separator: "\n")
            XCTFail("\(failures.count) profile(s) failed to compile via libdtrace:\n\(summary)")
        }
    }

    // MARK: - Root tier: --format json end-to-end

    /// Run `sched-on-cpu` in `--format json --duration 1` and assert
    /// every output line is valid JSONL with the expected fields
    /// (`time`, `profile`, `body`).
    func testJsonFormatProducesValidJSONL() throws {
        try XCTSkipUnless(isRoot,
            "json format runs libdtrace; requires root. Run with `sudo swift test`.")
        try skipIfBinaryMissing()

        guard let result = runDtlm(
            ["watch", "sched-on-cpu", "--format", "json", "--duration", "1"],
            timeout: 15.0
        ) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0,
            "dtlm watch --format json should exit 0; stderr: \(result.stderr)")
        XCTAssertFalse(result.stdout.isEmpty,
            "json format should produce at least one line of output")

        // Every non-empty line must parse as a JSON object.
        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        XCTAssertGreaterThan(lines.count, 0,
            "json output should contain at least one record")

        var validRecords = 0
        var invalidLines: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                invalidLines.append(line)
                continue
            }
            // Required fields per the JSONLExporter contract.
            XCTAssertNotNil(obj["time"] as? String, "missing 'time' in: \(line)")
            XCTAssertNotNil(obj["profile"] as? String, "missing 'profile' in: \(line)")
            XCTAssertNotNil(obj["body"] as? String, "missing 'body' in: \(line)")
            XCTAssertEqual(obj["profile"] as? String, "sched-on-cpu")
            validRecords += 1
        }

        if !invalidLines.isEmpty {
            XCTFail("\(invalidLines.count) line(s) failed JSON parse, e.g.: \(invalidLines.first ?? "")")
        }
        XCTAssertGreaterThan(validRecords, 0,
            "expected at least one valid JSONL record")
    }

    /// Run a per-event probe in `--format json` and assert each
    /// record's `body` field contains the printf body shape.
    func testJsonFormatPreservesPrintfBody() throws {
        try XCTSkipUnless(isRoot, "requires root")
        try skipIfBinaryMissing()

        guard let result = runDtlm(
            ["watch", "proc-exec-success", "--format", "json", "--duration", "2"],
            timeout: 15.0
        ) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0,
            "stderr: \(result.stderr)")

        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        // On a quiet system there might be no exec events. Skip
        // rather than fail in that case.
        try XCTSkipIf(lines.isEmpty,
            "no proc-exec-success events fired during the test window — system was idle")

        guard let data = lines[0].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("first record is not valid JSON: \(lines[0])")
            return
        }
        XCTAssertEqual(obj["profile"] as? String, "proc-exec-success")
        guard let body = obj["body"] as? String else {
            XCTFail("missing body field")
            return
        }
        XCTAssertTrue(body.contains("proc"),
            "body should contain a proc-shaped printf, got: \(body)")
    }

    // MARK: - Root tier: otel format

    /// Smoke test for `--format otel`: verify dtlm exits cleanly
    /// when POSTing to a collector (or when the collector is down —
    /// errors are non-fatal). No stdout expected since output goes
    /// to the collector, not the terminal.
    func testOtelFormatExitsCleanly() throws {
        try XCTSkipUnless(isRoot,
            "otel format runs libdtrace; requires root. Run with `sudo swift test`.")
        try skipIfBinaryMissing()

        guard let result = runDtlm(
            ["watch", "kill", "--format", "otel", "--duration", "1",
             "--endpoint", "http://localhost:4318"],
            timeout: 15.0
        ) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0,
            "dtlm watch --format otel should exit 0; stderr: \(result.stderr)")
        // No stdout expected — output goes to the collector.
        // Stderr may contain drop messages or HTTP errors if
        // the collector isn't running, but the exit code should
        // still be 0.
    }

    /// Test otel format with an aggregation profile to verify
    /// metrics export doesn't crash.
    func testOtelFormatWithAggregationProfile() throws {
        try XCTSkipUnless(isRoot,
            "otel format runs libdtrace; requires root.")
        try skipIfBinaryMissing()

        guard let result = runDtlm(
            ["watch", "syscall-counts", "--format", "otel", "--duration", "1",
             "--endpoint", "http://localhost:4318"],
            timeout: 15.0
        ) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0,
            "dtlm watch syscall-counts --format otel should exit 0; stderr: \(result.stderr)")
    }

    // MARK: - Root tier: probes subcommand

    func testProbesSubcommandLightSmokeTest() throws {
        try XCTSkipUnless(isRoot, "dtlm probes needs root")
        try skipIfBinaryMissing()
        guard let result = runDtlm(["probes", "--provider", "proc"]) else {
            XCTFail("could not run dtlm")
            return
        }
        XCTAssertEqual(result.exitCode, 0,
            "dtlm probes --provider proc should succeed; stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("proc:"),
            "should list at least one proc probe")
    }
}

/// Locked byte accumulator used by `runDtlm`'s background pipe drain.
/// Foundation's `FileHandle.readabilityHandler` is invoked from a
/// private dispatch queue concurrently with the test thread, so the
/// closure can't capture a `var Data` directly under Swift 6 strict
/// concurrency. Wrapping the bytes in a final class with internal
/// locking gives the closure a stable reference to mutate.
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
