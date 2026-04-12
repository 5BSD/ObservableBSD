/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser

// MARK: - FilterOptions

/// CLI filter flags shared by every subcommand that runs a profile.
///
/// Every flag is optional; the unfiltered case produces an empty
/// predicate and dtlm leaves the loaded `.d` file's clauses
/// untouched. When at least one flag is set, dtlm composes a
/// D predicate string and substitutes it at the
/// `/* @dtlm-predicate */` marker in the loaded script.
///
/// Filters AND together: passing `--execname nginx --uid 80` matches
/// probe firings where both predicates hold.
///
/// `--where` is the escape hatch for predicates the typed flags
/// don't cover — e.g. `--where 'arg0 > 0 && curlwp->l_class == LSRUN'`.
struct FilterOptions: ParsableArguments {

    @Option(
        name: .long,
        help: "Match only probes fired by this PID."
    )
    var pid: Int32?

    @Option(
        name: .long,
        help: "Match only probes fired by processes with this execname."
    )
    var execname: String?

    @Option(
        name: .long,
        help: "Match only probes fired by processes owned by this UID."
    )
    var uid: UInt32?

    @Option(
        name: .long,
        help: "Match only probes fired by processes in this group (GID)."
    )
    var gid: UInt32?

    @Option(
        name: .long,
        help: "Match only probes fired by processes in this jail (JID)."
    )
    var jail: Int32?

    @Option(
        name: .customLong("where"),
        help: ArgumentHelp(
            "Custom DTrace predicate AND'd into every probe clause.",
            discussion: "Use this for predicates the typed flags don't cover."
        )
    )
    var wherePredicate: String?

    /// Build the list of D-source predicate clauses (without slashes
    /// or any joining `&&`). Returns an empty array if no filters
    /// were set.
    private func clauseList() -> [String] {
        var clauses: [String] = []
        if let pid {
            clauses.append("pid == \(pid)")
        }
        if let execname {
            // Escape any embedded double quotes in the execname so
            // we don't break the D string literal.
            let escaped = execname.replacingOccurrences(of: "\"", with: "\\\"")
            clauses.append("execname == \"\(escaped)\"")
        }
        if let uid {
            clauses.append("uid == \(uid)")
        }
        if let gid {
            clauses.append("gid == \(gid)")
        }
        if let jail {
            clauses.append("curproc->p_ucred->cr_prison->pr_id == \(jail)")
        }
        if let wherePredicate {
            // Wrap user-supplied expressions in parens to keep the
            // surrounding && composition unambiguous.
            clauses.append("(\(wherePredicate))")
        }
        return clauses
    }

    /// Render the filter flags into a D predicate string suitable
    /// for substitution at the **`@dtlm-predicate`** marker.
    ///
    /// Returns the empty string if no filter flags were given. The
    /// returned string includes the leading slash and trailing slash
    /// (e.g. `/execname == "nginx" && pid == 1234/`) so it slots
    /// directly into a clause between the probe spec and the action
    /// block.
    ///
    /// Use this in profiles that **don't** already have their own
    /// `/.../` predicate. For profiles that do (like `errno-tracer`),
    /// use `renderPredicateAnd()` instead.
    func renderPredicate() -> String {
        let clauses = clauseList()
        guard !clauses.isEmpty else {
            return ""
        }
        return "/" + clauses.joined(separator: " && ") + "/"
    }

    /// Render the filter flags as an `&&`-prefixed clause list
    /// suitable for substitution at the **`@dtlm-predicate-and`**
    /// marker, which lives **inside** an existing `/.../` predicate
    /// block.
    ///
    /// Returns the empty string if no filter flags were given. When
    /// non-empty, the returned string starts with ` && ` so it can
    /// be appended after the profile's own predicate clause without
    /// further punctuation.
    ///
    /// Example: a profile with
    /// ```d
    /// /errno != 0 /* @dtlm-predicate-and */ /
    /// ```
    /// becomes, when `--execname nginx --pid 1234` is supplied:
    /// ```d
    /// /errno != 0  && execname == "nginx" && pid == 1234 /
    /// ```
    /// and, when no filters are supplied, simply:
    /// ```d
    /// /errno != 0  /
    /// ```
    func renderPredicateAnd() -> String {
        let clauses = clauseList()
        guard !clauses.isEmpty else {
            return ""
        }
        return " && " + clauses.joined(separator: " && ")
    }
}

// MARK: - DurationOption

/// CLI flag for the run-length bound, separated from FilterOptions
/// because not every subcommand needs it (e.g. `generate` and
/// `list` don't run anything).
struct DurationOption: ParsableArguments {

    @Option(
        name: .customLong("duration"),
        help: ArgumentHelp(
            "Run the script for at most this many seconds, then stop.",
            discussion: """
                If the profile already ships an in-script \
                `tick-Ns { exit(0); }` clause, the kernel-side timer \
                wins; this flag is the user-side convenience for \
                open-ended profiles. dtlm injects an equivalent \
                `tick-Ns { exit(0); }` clause into the loaded script \
                before handing it to libdtrace.
                """
        )
    )
    var durationSeconds: Double?
}

// MARK: - StackOptions

/// CLI flags for stack capture. Both flags can be combined.
///
/// dtlm injects `stack();` / `ustack();` actions at the
/// `/* @dtlm-stack */` / `/* @dtlm-ustack */` markers in the loaded
/// `.d` source. Profiles that don't include those markers silently
/// ignore the flags. The bundled profiles all include the markers
/// after their printf actions, so `--with-stack` and `--with-ustack`
/// work uniformly across the catalog.
struct StackOptions: ParsableArguments {

    @Flag(
        name: .customLong("with-stack"),
        help: "Capture and print the kernel stack at every probe firing."
    )
    var withStack: Bool = false

    @Flag(
        name: .customLong("with-ustack"),
        help: "Capture and print the user-space stack at every probe firing."
    )
    var withUstack: Bool = false
}
