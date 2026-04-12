/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import XCTest
@testable import dtlm

/// Sweeps every bundled `.d` profile and verifies structural properties
/// that don't require libdtrace to be running. The point of this suite
/// is to catch authoring mistakes at unit-test time — leftover marker
/// strings, unsubstituted `${param}` placeholders, unbalanced braces,
/// filename/name mismatches — without needing root.
///
/// Anything that requires actually compiling D source via libdtrace
/// lives in `IntegrationTests` (root-gated).
final class BundledProfilesTests: XCTestCase {

    /// Sentinel parameters used for profiles that declare `${param}`
    /// placeholders. Specific profiles add their own keys here so the
    /// sweep can render them without throwing `missingParameter`.
    private let sentinelParameters: [String: String] = [
        "func": "vm_fault",
        "offset": "4",
    ]

    private func loader() -> ProfileLoader {
        ProfileLoader()
    }

    // MARK: - Catalog size

    func testBundledCatalogShipsAtLeast85Profiles() {
        // dwatch ships 85; dtlm should hit at least parity.
        XCTAssertGreaterThanOrEqual(loader().count, 85,
            "bundled catalog should match dwatch parity (≥ 85), got \(loader().count)")
    }

    // MARK: - Per-profile structural sweeps

    /// Render every bundled profile with sentinel params + no filters
    /// + no stack capture + no duration. Asserts that rendering doesn't
    /// throw and that no `@dtlm-*` marker token survives.
    func testEveryBundledProfileRendersAndConsumesAllMarkers() throws {
        for profile in loader().all() {
            do {
                let rendered = try profile.render(parameters: sentinelParameters)
                XCTAssertFalse(
                    rendered.contains("@dtlm-"),
                    "profile '\(profile.name)' has a leftover @dtlm-* marker after rendering — token wasn't consumed"
                )
                XCTAssertFalse(
                    rendered.isEmpty,
                    "profile '\(profile.name)' rendered to empty string"
                )
            } catch {
                XCTFail("profile '\(profile.name)' failed to render with sentinel params: \(error)")
            }
        }
    }

    /// Render every bundled profile and assert no `${name}` placeholder
    /// survives. Catches profiles whose `${param}` placeholders aren't
    /// in the sentinel set above.
    func testEveryBundledProfileConsumesAllParameterPlaceholders() throws {
        for profile in loader().all() {
            let rendered = try profile.render(parameters: sentinelParameters)
            XCTAssertFalse(
                rendered.contains("${"),
                "profile '\(profile.name)' has an unsubstituted ${name} placeholder — add the param to sentinelParameters or fix the profile"
            )
        }
    }

    /// Brace count must match. Cheap structural sanity check that
    /// catches profiles where I dropped a `}` or added an unmatched
    /// `{` in the printf body. Doesn't catch every D syntax error but
    /// catches the obvious ones.
    func testEveryBundledProfileHasBalancedBraces() throws {
        for profile in loader().all() {
            let rendered = try profile.render(parameters: sentinelParameters)
            // Strip string literals so braces inside printf format
            // strings don't get counted. Cheap heuristic — find every
            // "..." span and replace with empty.
            let stripped = stripStringLiterals(rendered)
            let opens = stripped.filter { $0 == "{" }.count
            let closes = stripped.filter { $0 == "}" }.count
            XCTAssertEqual(opens, closes,
                "profile '\(profile.name)' has unbalanced braces: \(opens) '{' vs \(closes) '}'")
        }
    }

    /// Render every bundled profile **with** filter flags + stack
    /// capture flags set, to verify the marker substitution works in
    /// the "everything turned on" case.
    func testEveryBundledProfileRendersWithAllOptionsOn() throws {
        for profile in loader().all() {
            do {
                let rendered = try profile.render(
                    parameters: sentinelParameters,
                    predicate: "/execname == \"sentinel-exec\"/",
                    predicateAnd: " && execname == \"sentinel-exec\"",
                    withStack: true,
                    withUstack: true,
                    durationSeconds: 1.0
                )
                XCTAssertFalse(rendered.isEmpty,
                    "profile '\(profile.name)' rendered to empty string with all options on")
                // No marker should survive.
                XCTAssertFalse(rendered.contains("@dtlm-"),
                    "profile '\(profile.name)' leaked an @dtlm-* marker with all options on")
                // The duration tick should be appended.
                XCTAssertTrue(rendered.contains("tick-1000000000ns"),
                    "profile '\(profile.name)' didn't get the --duration tick clause")
                XCTAssertTrue(rendered.contains("exit(0)"),
                    "profile '\(profile.name)' didn't get the exit(0) action")
            } catch {
                XCTFail("profile '\(profile.name)' failed to render with all options on: \(error)")
            }
        }
    }

    // MARK: - Naming + metadata sanity

    func testEveryBundledProfileHasNonEmptyDescription() {
        for profile in loader().all() {
            XCTAssertFalse(profile.description.isEmpty,
                "profile '\(profile.name)' has empty description (no /* … */ block comment at top of .d file)")
        }
    }

    func testEveryBundledProfileNameIsKebabCaseOrUnderscored() {
        // Names are filenames without .d. Allow lowercase letters,
        // digits, hyphens, and underscores. Reject anything else.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        for profile in loader().all() {
            let nameSet = CharacterSet(charactersIn: profile.name)
            XCTAssertTrue(allowed.isSuperset(of: nameSet),
                "profile name '\(profile.name)' contains characters outside [a-z0-9_-]")
        }
    }

    // MARK: - dwatch parity

    /// Every dwatch profile name from `/usr/libexec/dwatch/` (the
    /// canonical 85-profile baseline) must exist in the dtlm bundled
    /// catalog. Hardcoded list because we can't read the system
    /// directory at unit-test time on every CI machine.
    func testEveryDwatchProfileNameIsCovered() {
        let dwatchProfiles: Set<String> = [
            "chmod", "errno", "fchmodat", "io", "io-done", "io-start",
            "ip", "ip-receive", "ip-send", "kill", "lchmod", "nanosleep",
            "open", "openat", "proc", "proc-create", "proc-exec",
            "proc-exec-failure", "proc-exec-success", "proc-exit",
            "proc-signal", "proc-signal-clear", "proc-signal-discard",
            "proc-signal-send", "proc-status", "read", "recv", "recvfrom",
            "recvmsg", "rw", "sched", "sched-change-pri", "sched-cpu",
            "sched-dequeue", "sched-enqueue", "sched-exec", "sched-lend-pri",
            "sched-load-change", "sched-off-cpu", "sched-on-cpu",
            "sched-preempt", "sched-pri", "sched-queue", "sched-remain-cpu",
            "sched-sleep", "sched-surrender", "sched-tick", "sched-wakeup",
            "send", "sendmsg", "sendrecv", "sendto", "systop", "tcp",
            "tcp-accept", "tcp-accept-established", "tcp-accept-refused",
            "tcp-connect", "tcp-connect-established", "tcp-connect-refused",
            "tcp-connect-request", "tcp-established", "tcp-init", "tcp-io",
            "tcp-receive", "tcp-refused", "tcp-send", "tcp-state-change",
            "tcp-status", "udp", "udp-receive", "udp-send", "udplite",
            "udplite-receive", "udplite-send", "vop_create", "vop_lookup",
            "vop_mkdir", "vop_mknod", "vop_readdir", "vop_remove",
            "vop_rename", "vop_rmdir", "vop_symlink", "write",
        ]
        let loader = self.loader()
        let dtlmNames = Set(loader.all().map { $0.name })
        let missing = dwatchProfiles.subtracting(dtlmNames).sorted()
        XCTAssertTrue(missing.isEmpty,
            "dtlm is missing \(missing.count) dwatch parity profile(s): \(missing)")
    }

    // MARK: - Helpers

    /// Walk a string and replace every "..." span with empty so brace
    /// counts ignore characters inside string literals. Doesn't handle
    /// escaped quotes inside strings, but that's good enough for the
    /// hand-authored .d files we ship.
    private func stripStringLiterals(_ s: String) -> String {
        var out = ""
        var inString = false
        var escape = false
        for ch in s {
            if escape {
                escape = false
                if !inString { out.append(ch) }
                continue
            }
            if ch == "\\" {
                escape = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                continue
            }
            if !inString {
                out.append(ch)
            }
        }
        return out
    }
}
