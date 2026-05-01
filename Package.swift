// swift-tools-version: 6.3
//
// ObservableBSD — convert FreeBSD's instrumentation surface to
// OpenTelemetry telemetry.
//
// Executable targets:
//   - bsdinstruments — DTrace-based instruments and profiling
//   - hwtlm   — Hardware telemetry (power, temperature, frequency)
//   - bsdtrace — Process tracing via HWT (Intel PT / ARM CoreSight)
//
// Test helper executables (built by SPM, used by test-bsdtrace.sh):
//   - bsdtrace-testprog  — deterministic trace target
//   - bsdtrace-attachprog — long-running attach target
//   - bsdtrace-floodprog  — PT buffer wrap stress target
//
// Shared library:
//   - OTelExport — Exporter protocol, data types, and three
//     exporter implementations (text, JSONL, OTLP/HTTP) shared
//     across all ObservableBSD tools.

import PackageDescription

let package = Package(
    name: "ObservableBSD",
    products: [
        .executable(name: "bsdinstruments", targets: ["bsdinstruments"]),
        .executable(name: "hwtlm", targets: ["hwtlm"]),
        .executable(name: "bsdtrace", targets: ["bsdtrace"]),
        .library(name: "OTelExport", targets: ["OTelExport"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SwiftBSD/FreeBSDKit",
            from: "0.2.6"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.2.0"
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            pkgConfig: nil,
            providers: []
        ),
        .systemLibrary(
            name: "CCpuctl",
            pkgConfig: nil,
            providers: []
        ),
        .target(
            name: "OTelExport",
            dependencies: [
                "CZlib",
            ]
        ),
        .executableTarget(
            name: "bsdinstruments",
            dependencies: [
                .product(name: "DTraceCore", package: "FreeBSDKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "OTelExport",
            ],
            resources: [
                .process("Profiles"),
            ]
        ),
        .executableTarget(
            name: "hwtlm",
            dependencies: [
                .product(name: "FreeBSDKit", package: "FreeBSDKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "OTelExport",
                "CCpuctl",
            ],
            exclude: ["ARM.md"]
        ),
        .executableTarget(
            name: "bsdtrace",
            dependencies: [],
            cSettings: [
                .unsafeFlags(["-I/usr/local/include/libipt"]),
            ],
            linkerSettings: [
                .linkedLibrary("ipt"),
                .linkedLibrary("elf"),
                .linkedLibrary("dwarf"),
            ]
        ),
        .executableTarget(
            name: "bsdtrace-testprog",
            dependencies: [],
            path: "Tests/bsdtrace/testprog",
            cSettings: [
                .unsafeFlags(["-O0"]),
            ]
        ),
        .executableTarget(
            name: "bsdtrace-attachprog",
            dependencies: [],
            path: "Tests/bsdtrace/attachprog",
            cSettings: [
                .unsafeFlags(["-O0"]),
            ]
        ),
        .executableTarget(
            name: "bsdtrace-floodprog",
            dependencies: [],
            path: "Tests/bsdtrace/floodprog",
            cSettings: [
                .unsafeFlags(["-O0"]),
            ]
        ),
        .testTarget(
            name: "bsdinstrumentsTests",
            dependencies: ["bsdinstruments", "OTelExport"]
        ),
        .testTarget(
            name: "hwtlmTests",
            dependencies: ["hwtlm", "OTelExport"]
        ),
    ]
)
