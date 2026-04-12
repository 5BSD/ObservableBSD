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

    /// Path to the dtlm binary built by `swift build` in `.build/debug/`.
    /// Computed relative to the test bundle's location, since
    /// `swift test` cwd isn't always the project root.
    private var dtlmBinaryPath: String {
        // Find the .build/debug directory by walking up from the test
        // bundle's URL until we find Package.swift.
        var dir = Bundle(for: type(of: self)).bundleURL
            .deletingLastPathComponent()  // strip the .xctest dir
        while dir.path != "/" {
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                return dir
                    .appendingPathComponent(".build")
                    .appendingPathComponent("debug")
                    .appendingPathComponent("dtlm")
                    .path
            }
            dir = dir.deletingLastPathComponent()
        }
        // Fallback: assume cwd is project root
        return ".build/debug/dtlm"
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

        do {
            try process.run()
        } catch {
            XCTFail("failed to launch dtlm: \(error)")
            return nil
        }

        // Wait with timeout. We poll process.isRunning rather than
        // sitting in waitUntilExit so we can SIGTERM after `timeout`
        // seconds.
        let deadline = Date(timeIntervalSinceNow: timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                // Give it a grace period to clean up via SIGTERM.
                let graceDeadline = Date(timeIntervalSinceNow: 1.0)
                while process.isRunning && Date() < graceDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                // If it's still alive, forcibly kill it.
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        var stderr = String(data: errData, encoding: .utf8) ?? ""
        if timedOut {
            stderr = "[TIMEOUT after \(timeout)s] " + stderr
        }
        return (
            String(data: outData, encoding: .utf8) ?? "",
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
    /// this catches every invented probe name across the entire 99-
    /// profile catalog in one shot.
    ///
    /// Per-profile timeout is 8 seconds (the runDtlm helper's
    /// default), so any individual profile that hangs libdtrace gets
    /// killed and reported as a failure rather than stalling the
    /// whole suite.
    ///
    /// At ~150ms per profile (50ms duration + ~50ms switchrate +
    /// ~50ms binary launch overhead), the full sweep against 99
    /// profiles takes ~15-20 seconds. Skipped when not running as
    /// root.
    func testEveryBundledProfileCompilesViaLibdtrace() throws {
        try XCTSkipUnless(isRoot,
            "this test compiles every bundled profile via libdtrace, requires root. Run with `sudo swift test`.")
        try skipIfBinaryMissing()

        // Profiles that need a kinst module which may not be loaded
        // by default. We skip them with a warning rather than
        // failing the whole sweep — kinst availability is a
        // kernel-config decision, not a profile bug.
        let kinstSkipNames: Set<String> = ["kinst"]

        var failures: [(name: String, stderr: String)] = []
        var skipped: [String] = []

        for profile in ProfileLoader().all() {
            // Skip profiles with required params unless we have
            // sentinel values for them.
            let extraArgs: [String]
            switch profile.name {
            case "kinst":
                extraArgs = ["--param", "func=vm_fault", "--param", "offset=4"]
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
                // kinst profile failures when the kinst.ko module
                // isn't loaded show up as "does not match any
                // probes" — those are environment issues, not
                // profile bugs.
                if kinstSkipNames.contains(profile.name)
                    && stderr.contains("does not match any probes") {
                    skipped.append(profile.name)
                    continue
                }
                failures.append((profile.name, stderr))
            }
        }

        if !skipped.isEmpty {
            print("[testEveryBundledProfileCompilesViaLibdtrace] skipped (kernel module not loaded): \(skipped)")
        }
        if !failures.isEmpty {
            let summary = failures
                .map { "  \($0.name): \($0.stderr)" }
                .joined(separator: "\n")
            XCTFail("\(failures.count) profile(s) failed to compile via libdtrace:\n\(summary)")
        }
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
