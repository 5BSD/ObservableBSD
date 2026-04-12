/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

import ArgumentParser
import Foundation

// MARK: - dtlm list

/// `dtlm list` — print every profile the loader found, across all
/// three sources (bundled, system, user).
struct ListCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every profile dtlm knows about.",
        discussion: """
            Profiles are loaded from three sources at startup: \
            bundled SwiftPM resources inside the dtlm binary, \
            /usr/local/share/dtlm/profiles/ (where the FreeBSD port \
            drops the catalog), and ~/.dtlm/profiles/ (per-user). \
            User profiles override system, system overrides bundled, \
            with a stderr warning when shadowing happens.
            """
    )

    @Flag(
        name: .long,
        help: "Emit one JSONL record per profile instead of a text table."
    )
    var json: Bool = false

    func run() throws {
        let loader = ProfileLoader()

        // Surface any shadowing warnings to stderr first so the
        // user sees them above the table.
        for warning in loader.shadowingWarnings {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }

        let profiles = loader.all()
        if json {
            try emitJSONL(profiles)
        } else {
            emitTable(profiles)
        }
    }

    private func emitTable(_ profiles: [Profile]) {
        guard !profiles.isEmpty else {
            print("(no profiles found — bundled set is empty and the system / user dirs are empty too)")
            return
        }

        let nameWidth = max(4, profiles.map { $0.name.count }.max() ?? 4)
        let originWidth = 8

        let header = "\(pad("NAME", nameWidth))  \(pad("ORIGIN", originWidth))  DESCRIPTION"
        print(header)
        print(String(repeating: "─", count: header.count))
        for p in profiles {
            print("\(pad(p.name, nameWidth))  \(pad(p.origin.displayName, originWidth))  \(p.description)")
        }
        print()
        print("\(profiles.count) profile\(profiles.count == 1 ? "" : "s")")
    }

    private func emitJSONL(_ profiles: [Profile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for p in profiles {
            let row = ProfileRow(
                name: p.name,
                origin: p.origin.displayName,
                description: p.description
            )
            let data = try encoder.encode(row)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    private struct ProfileRow: Encodable {
        let name: String
        let origin: String
        let description: String
    }
}
