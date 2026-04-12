/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import XCTest
@testable import dtlm

/// Edge-case coverage for `FilterOptions.renderPredicate()` and
/// `renderPredicateAnd()`. The simple happy paths are in
/// `ProfileLoaderTests`; this file covers the cases that bit me
/// once or could bite me in the future.
final class FilterOptionsTests: XCTestCase {

    // MARK: - renderPredicate (the @dtlm-predicate marker)

    func testRenderPredicateEmptyWithNoFlags() throws {
        let f = try FilterOptions.parse([])
        XCTAssertEqual(f.renderPredicate(), "")
    }

    func testRenderPredicateSinglePid() throws {
        let f = try FilterOptions.parse(["--pid", "1234"])
        XCTAssertEqual(f.renderPredicate(), "/pid == 1234/")
    }

    func testRenderPredicateSingleExecname() throws {
        let f = try FilterOptions.parse(["--execname", "nginx"])
        XCTAssertEqual(f.renderPredicate(), "/execname == \"nginx\"/")
    }

    func testRenderPredicateExecnameWithEmbeddedQuoteIsEscaped() throws {
        // Embedded double quotes in the execname must be backslash-escaped
        // so the resulting D string literal stays valid.
        let f = try FilterOptions.parse(["--execname", "weird\"name"])
        let pred = f.renderPredicate()
        XCTAssertTrue(pred.contains("execname == \"weird\\\"name\""),
            "embedded quote should be backslash-escaped, got '\(pred)'")
    }

    func testRenderPredicateAllSimpleFiltersAndedTogether() throws {
        let f = try FilterOptions.parse([
            "--pid", "1234",
            "--execname", "nginx",
            "--uid", "80",
            "--gid", "80",
            "--jail", "1",
        ])
        let pred = f.renderPredicate()
        XCTAssertTrue(pred.hasPrefix("/"), "predicate should start with /")
        XCTAssertTrue(pred.hasSuffix("/"), "predicate should end with /")
        XCTAssertTrue(pred.contains("pid == 1234"))
        XCTAssertTrue(pred.contains("execname == \"nginx\""))
        XCTAssertTrue(pred.contains("uid == 80"))
        XCTAssertTrue(pred.contains("gid == 80"))
        XCTAssertTrue(pred.contains("curproc->p_ucred->cr_prison->pr_id == 1"))
        // 5 clauses → 4 ANDs
        XCTAssertEqual(pred.components(separatedBy: " && ").count, 5)
    }

    func testRenderPredicateWhereClauseIsParenthesized() throws {
        // The user-supplied --where expression must be wrapped in
        // parentheses so the surrounding && composition stays
        // unambiguous when there are other filters set.
        let f = try FilterOptions.parse([
            "--execname", "nginx",
            "--where", "arg0 > 0 || curlwp->l_class == LSRUN",
        ])
        let pred = f.renderPredicate()
        XCTAssertTrue(pred.contains("(arg0 > 0 || curlwp->l_class == LSRUN)"),
            "user --where expression should be parenthesized: '\(pred)'")
    }

    // MARK: - renderPredicateAnd (the @dtlm-predicate-and marker)

    func testRenderPredicateAndEmptyWithNoFlags() throws {
        let f = try FilterOptions.parse([])
        XCTAssertEqual(f.renderPredicateAnd(), "")
    }

    func testRenderPredicateAndPrefixedWithAnd() throws {
        let f = try FilterOptions.parse(["--execname", "nginx"])
        let pa = f.renderPredicateAnd()
        XCTAssertTrue(pa.hasPrefix(" && "),
            "predicate-and should start with ' && ', got '\(pa)'")
        XCTAssertTrue(pa.contains("execname == \"nginx\""))
    }

    func testRenderPredicateAndComposesWithProfilePredicate() throws {
        // Simulate the errno-tracer case: a profile with /errno != 0/
        // and we add --execname to it.
        let f = try FilterOptions.parse(["--execname", "nginx"])
        let profilePredicate = "/errno != 0\(f.renderPredicateAnd()) /"
        XCTAssertEqual(profilePredicate, "/errno != 0 && execname == \"nginx\" /",
            "compound predicate should be syntactically valid D")
    }

    func testRenderPredicateAndPlusWhereClause() throws {
        let f = try FilterOptions.parse([
            "--pid", "1234",
            "--where", "arg0 > 0",
        ])
        let pa = f.renderPredicateAnd()
        XCTAssertTrue(pa.contains("pid == 1234"))
        XCTAssertTrue(pa.contains("(arg0 > 0)"))
        XCTAssertTrue(pa.hasPrefix(" && "))
    }

    // MARK: - DurationOption

    func testDurationOptionParsesSeconds() throws {
        let d = try DurationOption.parse(["--duration", "30"])
        XCTAssertEqual(d.durationSeconds, 30.0)
    }

    func testDurationOptionDefaultsToNil() throws {
        let d = try DurationOption.parse([])
        XCTAssertNil(d.durationSeconds)
    }

    func testDurationOptionParsesFractionalSeconds() throws {
        let d = try DurationOption.parse(["--duration", "0.5"])
        XCTAssertEqual(d.durationSeconds, 0.5)
    }

    // MARK: - StackOptions

    func testStackOptionsBothDefaultFalse() throws {
        let s = try StackOptions.parse([])
        XCTAssertFalse(s.withStack)
        XCTAssertFalse(s.withUstack)
    }

    func testStackOptionsBothCanBeSet() throws {
        let s = try StackOptions.parse(["--with-stack", "--with-ustack"])
        XCTAssertTrue(s.withStack)
        XCTAssertTrue(s.withUstack)
    }
}
