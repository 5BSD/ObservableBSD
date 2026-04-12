/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import Foundation

// MARK: - Profile

/// One loaded `.d` profile, ready to render and run.
///
/// A profile is a `.d` file with a name (the filename minus `.d`),
/// a one-line description (parsed from the first `/* … */` comment),
/// and the raw D source. The source contains the optional
/// `/* @dtlm-predicate */` marker where dtlm injects CLI filter
/// predicates, and may contain `${param}` placeholders that
/// `--param key=value` flags substitute.
///
/// Profiles do **not** carry metadata blocks. There is no JSON
/// wrapper, no Codable schema, no typed DSL payload. The .d file
/// IS the profile.
struct Profile: Sendable {

    /// Profile name (filename without `.d`).
    let name: String

    /// One-line description from the first `/* … */` comment in the
    /// source. Empty if the file has no leading block comment.
    let description: String

    /// Raw D source as loaded from disk (or extracted from a SwiftPM
    /// resource bundle).
    let source: String

    /// Where this profile came from. Used for `dtlm list` display
    /// and for shadowing rules when the same name appears in
    /// multiple sources.
    let origin: ProfileOrigin

    /// Render the profile to a final D source string ready for
    /// libdtrace, with parameter substitution, filter injection,
    /// stack capture, and duration injection applied.
    ///
    /// - Parameters:
    ///   - parameters: `${name}` → value substitutions to apply.
    ///   - predicate: D predicate string (already wrapped in
    ///     `/.../`) to substitute at the `@dtlm-predicate` marker.
    ///     Pass `""` for no filter. Used by profiles **without**
    ///     their own predicate.
    ///   - predicateAnd: `&&`-prefixed clause list to substitute at
    ///     the `@dtlm-predicate-and` marker. Used by profiles **with**
    ///     their own predicate that want to AND in CLI filters. Pass
    ///     `""` for no filter.
    ///   - withStack: if `true`, replace `/* @dtlm-stack */` markers
    ///     with `stack();`. Otherwise the marker becomes empty.
    ///   - withUstack: if `true`, replace `/* @dtlm-ustack */`
    ///     markers with `ustack();`. Otherwise empty.
    ///   - durationSeconds: optional CLI-supplied duration. If
    ///     non-nil, dtlm appends a `tick-Ns { exit(0); }` clause to
    ///     the rendered source.
    /// - Throws: `ProfileError.missingParameter` if the source
    ///   contains a `${name}` placeholder for which no value was
    ///   supplied.
    func render(
        parameters: [String: String] = [:],
        predicate: String = "",
        predicateAnd: String = "",
        withStack: Bool = false,
        withUstack: Bool = false,
        durationSeconds: Double? = nil
    ) throws -> String {
        var rendered = source

        // 1. Parameter substitution.
        //    Find every ${name} and replace with the supplied value.
        //    Refuse to render if any placeholder is unsatisfied.
        let placeholderPattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#
        let regex = try NSRegularExpression(pattern: placeholderPattern)
        let nsRange = NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
        let matches = regex.matches(in: rendered, range: nsRange)

        // Walk matches in reverse so range offsets stay valid as we
        // splice replacements in.
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: rendered),
                  let fullRange = Range(match.range, in: rendered)
            else { continue }
            let name = String(rendered[nameRange])
            guard let value = parameters[name] else {
                throw ProfileError.missingParameter(name: name, profile: self.name)
            }
            rendered.replaceSubrange(fullRange, with: value)
        }

        // 2. Filter-predicate injection (two flavors).
        //    Profiles without their own predicate use
        //    `/* @dtlm-predicate */` and dtlm replaces it with the
        //    full `/clause/` block. Profiles WITH their own
        //    predicate use `/* @dtlm-predicate-and */` inside the
        //    existing predicate block, and dtlm replaces it with
        //    `&& clause` (or empty if no filter is set). If the
        //    marker is absent, dtlm does nothing — profiles without
        //    either marker silently ignore filter flags.
        rendered = rendered.replacingOccurrences(
            of: "/* @dtlm-predicate-and */",
            with: predicateAnd
        )
        rendered = rendered.replacingOccurrences(
            of: "/* @dtlm-predicate */",
            with: predicate
        )

        // 3. Stack capture injection.
        //    Replace `/* @dtlm-stack */` markers with `stack();` if
        //    --with-stack was passed, otherwise empty. Same for
        //    `/* @dtlm-ustack */` and --with-ustack. Profiles
        //    without the markers silently don't get stacks even if
        //    the flag is set — they simply don't opt in.
        rendered = rendered.replacingOccurrences(
            of: "/* @dtlm-stack */",
            with: withStack ? "stack();" : ""
        )
        rendered = rendered.replacingOccurrences(
            of: "/* @dtlm-ustack */",
            with: withUstack ? "ustack();" : ""
        )

        // 4. CLI-supplied duration injection.
        //    Append a tick clause that calls exit(0) after N seconds.
        //    Profiles that already declare their own tick-Ns clause
        //    will fire whichever timer comes first.
        if let durationSeconds, durationSeconds > 0 {
            let nanos = Int(durationSeconds * 1_000_000_000)
            // Use a tick-Ns probe that maps to nanoseconds. dtrace
            // accepts tick-Ns suffix natively (ns/us/ms/s/h/m/d).
            rendered += "\n\ntick-\(nanos)ns { exit(0); }\n"
        }

        return rendered
    }
}

// MARK: - ProfileOrigin

/// Where a loaded profile came from. Higher numbered cases shadow
/// lower numbered ones — `userDir` overrides `systemDir` overrides
/// `bundled`.
enum ProfileOrigin: Int, Sendable, Comparable {
    case bundled = 0       // SwiftPM resource inside the binary
    case systemDir = 1     // /usr/local/share/dtlm/profiles/
    case userDir = 2       // ~/.dtlm/profiles/
    case explicit = 3      // -f /path/to/script.d (highest priority)

    var displayName: String {
        switch self {
        case .bundled:   return "bundled"
        case .systemDir: return "system"
        case .userDir:   return "user"
        case .explicit:  return "explicit"
        }
    }

    static func < (lhs: ProfileOrigin, rhs: ProfileOrigin) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - ProfileError

enum ProfileError: Error, CustomStringConvertible {
    /// The profile's source contains `${name}` but no value was supplied.
    case missingParameter(name: String, profile: String)
    /// The filename (without `.d`) doesn't match the profile name field.
    case nameMismatch(filename: String, declared: String)
    /// The file couldn't be read.
    case readFailed(path: String, underlying: Error)
    /// The user asked for a profile name dtlm doesn't have.
    case unknownProfile(String)

    var description: String {
        switch self {
        case .missingParameter(let name, let profile):
            return "profile '\(profile)' requires --param \(name)=<value>"
        case .nameMismatch(let filename, let declared):
            return "profile filename '\(filename)' doesn't match declared name '\(declared)'"
        case .readFailed(let path, let underlying):
            return "failed to read profile at \(path): \(underlying)"
        case .unknownProfile(let name):
            return "unknown profile '\(name)'. Try `dtlm list`."
        }
    }
}
