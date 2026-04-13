/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser
import Foundation

// MARK: - dtlm generate

/// `dtlm generate` — print a profile's rendered D source without
/// running it.
///
/// This is the "show me what dtlm would actually hand to libdtrace"
/// command. It needs no privileges (no DTrace handle is opened) and
/// is the right way to inspect a profile, debug a filter / parameter,
/// or feed the rendered D source to `dtrace -s -` directly.
struct GenerateCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Render a profile to D source without running it.",
        discussion: """
            No privileges required — this never opens a DTrace handle. \
            Useful for inspecting what dtlm would actually run, piping \
            the rendered D into `dtrace -s -` directly, or verifying \
            that a filter flag or --param landed where you expected.
            """
    )

    @Argument(
        help: "Name of the profile to render. Use `-f` for an explicit .d file."
    )
    var profile: String?

    @Option(
        name: .customShort("f"),
        help: "Path to an explicit .d file to render instead of a named profile."
    )
    var file: String?

    @Option(
        name: .customLong("param"),
        parsing: .upToNextOption,
        help: "Substitute ${name} placeholders in the .d source. Repeatable."
    )
    var paramArgs: [String] = []

    @OptionGroup
    var filter: FilterOptions

    @OptionGroup
    var duration: DurationOption

    @OptionGroup
    var stack: StackOptions

    func validate() throws {
        if profile == nil && file == nil {
            throw ValidationError("provide a profile name or `-f /path/to/script.d`.")
        }
        if profile != nil && file != nil {
            throw ValidationError("pass either a profile name or `-f`, not both.")
        }
        for raw in paramArgs where !raw.contains("=") {
            throw ValidationError("--param expects key=value, got '\(raw)'")
        }
    }

    func run() throws {
        let profileToRender: Profile
        do {
            profileToRender = try ProfileLoader.resolve(name: profile, file: file)
        } catch {
            FileHandle.standardError.write(Data(
                "dtlm generate: \(error)\n".utf8
            ))
            throw ExitCode.failure
        }

        let params = ProfileLoader.parseParams(paramArgs)

        let rendered = try profileToRender.render(
            parameters: params,
            predicate: filter.renderPredicate(),
            predicateAnd: filter.renderPredicateAnd(),
            withStack: stack.withStack,
            withUstack: stack.withUstack,
            durationSeconds: duration.durationSeconds
        )
        print(rendered)
    }
}
