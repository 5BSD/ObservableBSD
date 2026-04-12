/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import XCTest
@testable import dtlm

final class ProfileLoaderTests: XCTestCase {

    func testLoaderFindsBundledProfiles() {
        let loader = ProfileLoader()
        XCTAssertGreaterThan(loader.count, 0,
                             "loader should find at least the bundled set")
    }

    func testKillProfileIsBundled() {
        let loader = ProfileLoader()
        let kill = loader.lookup("kill")
        XCTAssertNotNil(kill, "the bundled `kill` profile should be loaded")
        XCTAssertEqual(kill?.origin, .bundled)
    }

    func testKillDescriptionIsParsedFromBlockComment() {
        let loader = ProfileLoader()
        guard let kill = loader.lookup("kill") else {
            XCTFail("kill profile missing")
            return
        }
        XCTAssertTrue(kill.description.contains("kill"),
                      "description should mention kill")
    }

    func testAllReturnsSortedByName() {
        let loader = ProfileLoader()
        let names = loader.all().map { $0.name }
        XCTAssertEqual(names, names.sorted(),
                       "all() must return profiles in stable name order for display")
    }

    func testLookupReturnsNilForUnknownProfile() {
        let loader = ProfileLoader()
        XCTAssertNil(loader.lookup("definitely-not-a-real-profile"))
    }

    // MARK: - Profile.render

    func testRenderWithoutFilterPredicateLeavesMarkerEmpty() throws {
        let loader = ProfileLoader()
        guard let kill = loader.lookup("kill") else {
            XCTFail("kill profile missing")
            return
        }
        let rendered = try kill.render()
        XCTAssertFalse(rendered.contains("@dtlm-predicate"),
                       "the marker should be replaced even when the predicate is empty")
        XCTAssertTrue(rendered.contains("syscall::kill:entry"),
                      "rendered source should keep the original probe")
    }

    func testRenderInjectsFilterPredicate() throws {
        let loader = ProfileLoader()
        guard let kill = loader.lookup("kill") else {
            XCTFail("kill profile missing")
            return
        }
        let rendered = try kill.render(predicate: "/execname == \"nginx\"/")
        XCTAssertTrue(rendered.contains("execname == \"nginx\""),
                      "filter predicate should appear in the rendered source")
    }

    func testRenderInjectsDurationTickClause() throws {
        let loader = ProfileLoader()
        guard let kill = loader.lookup("kill") else {
            XCTFail("kill profile missing")
            return
        }
        let rendered = try kill.render(durationSeconds: 1.0)
        XCTAssertTrue(rendered.contains("tick-1000000000ns"),
                      "rendered source should contain a tick-Ns clause")
        XCTAssertTrue(rendered.contains("exit(0)"),
                      "rendered source should call exit(0) on tick")
    }

    // MARK: - Stack capture markers

    func testRenderInjectsStackActionWhenWithStack() throws {
        let loader = ProfileLoader()
        guard let kill = loader.lookup("kill") else {
            XCTFail("kill profile missing")
            return
        }
        let rendered = try kill.render(withStack: true)
        XCTAssertTrue(rendered.contains("stack();"),
                      "with-stack should inject stack(); at the marker")
        XCTAssertFalse(rendered.contains("@dtlm-stack"),
                       "the @dtlm-stack marker should be consumed")
    }

    func testRenderInjectsUstackActionWhenWithUstack() throws {
        let loader = ProfileLoader()
        guard let kill = loader.lookup("kill") else {
            XCTFail("kill profile missing")
            return
        }
        let rendered = try kill.render(withUstack: true)
        XCTAssertTrue(rendered.contains("ustack();"),
                      "with-ustack should inject ustack(); at the marker")
        XCTAssertFalse(rendered.contains("@dtlm-ustack"),
                       "the @dtlm-ustack marker should be consumed")
    }

    func testRenderLeavesStackMarkersEmptyByDefault() throws {
        let loader = ProfileLoader()
        guard let kill = loader.lookup("kill") else {
            XCTFail("kill profile missing")
            return
        }
        let rendered = try kill.render()
        XCTAssertFalse(rendered.contains("stack();"),
                       "no stack action without --with-stack")
        XCTAssertFalse(rendered.contains("ustack();"),
                       "no ustack action without --with-ustack")
        XCTAssertFalse(rendered.contains("@dtlm-stack"),
                       "the @dtlm-stack marker should still be consumed")
        XCTAssertFalse(rendered.contains("@dtlm-ustack"),
                       "the @dtlm-ustack marker should still be consumed")
    }

    // MARK: - The two predicate marker flavors

    func testRenderPredicateAndMarkerWithoutFilters() throws {
        // The errno-tracer profile uses /errno != 0 @dtlm-predicate-and/
        // — without filters the marker should disappear and leave
        // the inherent predicate intact.
        let loader = ProfileLoader()
        guard let errno = loader.lookup("errno-tracer") else {
            XCTFail("errno-tracer profile missing")
            return
        }
        let rendered = try errno.render(predicate: "", predicateAnd: "")
        XCTAssertTrue(rendered.contains("/errno != 0"),
                      "the inherent predicate should remain")
        XCTAssertFalse(rendered.contains("@dtlm-predicate-and"),
                       "the @dtlm-predicate-and marker should be consumed")
    }

    func testRenderPredicateAndMarkerWithFilters() throws {
        let loader = ProfileLoader()
        guard let errno = loader.lookup("errno-tracer") else {
            XCTFail("errno-tracer profile missing")
            return
        }
        let rendered = try errno.render(
            predicate: "",
            predicateAnd: " && execname == \"nginx\""
        )
        XCTAssertTrue(rendered.contains("execname == \"nginx\""),
                      "the AND-clause should appear inside the inherent predicate")
        XCTAssertTrue(rendered.contains("/errno != 0"),
                      "the inherent predicate should remain")
        // Make sure we didn't double-inject (no orphan slash).
        XCTAssertFalse(rendered.contains("//"),
                       "no double slashes in rendered output")
    }

    // MARK: - The 23-profile catalog

    func testCatalogShipsAtLeast21Profiles() {
        let loader = ProfileLoader()
        XCTAssertGreaterThanOrEqual(loader.count, 21,
                                    "the v1 bundled catalog should have ≥ 21 profiles, got \(loader.count)")
    }

    func testInstrumentsUmbrellaProfilesArePresent() {
        let loader = ProfileLoader()
        let umbrellas = [
            "time-profiler",
            "system-trace",
            "file-activity",
            "network-activity",
            "process-activity",
            "lock-contention",
            "thread-states",
        ]
        for name in umbrellas {
            XCTAssertNotNil(loader.lookup(name),
                            "Instruments-equivalent umbrella profile '\(name)' should ship in the bundled catalog")
        }
    }

    func testRenderRequiresParamForPlaceholder() {
        let loader = ProfileLoader()
        guard let kinst = loader.lookup("kinst") else {
            XCTFail("kinst profile missing — bundled profile is required for this test")
            return
        }
        XCTAssertThrowsError(try kinst.render(parameters: [:])) { error in
            guard let pe = error as? ProfileError else {
                XCTFail("expected ProfileError, got \(error)")
                return
            }
            switch pe {
            case .missingParameter:
                break
            default:
                XCTFail("expected missingParameter, got \(pe)")
            }
        }
    }

    func testRenderSubstitutesPlaceholders() throws {
        let loader = ProfileLoader()
        guard let kinst = loader.lookup("kinst") else {
            XCTFail("kinst profile missing")
            return
        }
        let rendered = try kinst.render(parameters: [
            "func": "vm_fault",
            "offset": "4",
        ])
        XCTAssertTrue(rendered.contains("kinst::vm_fault:4"),
                      "placeholders should be substituted into the probe spec")
        XCTAssertFalse(rendered.contains("${func}"),
                       "no placeholder should remain after rendering")
        XCTAssertFalse(rendered.contains("${offset}"),
                       "no placeholder should remain after rendering")
    }

    // MARK: - FilterOptions.renderPredicate

    func testFilterRendersEmptyWithoutFlags() throws {
        // ArgumentParser's @Option properties throw at access time
        // unless they were populated via `.parse(...)`. Construct
        // through the parser with no flags to get the empty case.
        let filter = try FilterOptions.parse([])
        XCTAssertEqual(filter.renderPredicate(), "")
    }

    func testFilterRendersAndedClauses() throws {
        let filter = try FilterOptions.parse([
            "--execname", "nginx",
            "--pid", "1234",
        ])
        let pred = filter.renderPredicate()
        XCTAssertTrue(pred.contains("execname == \"nginx\""),
                      "predicate should contain execname clause; got '\(pred)'")
        XCTAssertTrue(pred.contains("pid == 1234"),
                      "predicate should contain pid clause; got '\(pred)'")
        XCTAssertTrue(pred.contains("&&"),
                      "predicate should AND clauses together; got '\(pred)'")
        XCTAssertTrue(pred.hasPrefix("/"),
                      "predicate should be wrapped in /.../; got '\(pred)'")
        XCTAssertTrue(pred.hasSuffix("/"),
                      "predicate should be wrapped in /.../; got '\(pred)'")
    }
}
