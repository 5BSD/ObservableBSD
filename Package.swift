// swift-tools-version: 6.3
//
// ObservableBSD — convert FreeBSD's instrumentation surface to
// OpenTelemetry telemetry.
//
// Executable targets:
//   - dtlm    — DTrace-based instruments and profiling
//   - hwtlm   — Hardware telemetry (power, temperature, frequency)
//   - bptrace — Process tracing via HWT (Intel PT / ARM CoreSight)
//
// Shared library:
//   - OTelExport — Exporter protocol, data types, and three
//     exporter implementations (text, JSONL, OTLP/HTTP) shared
//     across all ObservableBSD tools.

import PackageDescription

let package = Package(
    name: "ObservableBSD",
    products: [
        .executable(name: "dtlm", targets: ["dtlm"]),
        .executable(name: "hwtlm", targets: ["hwtlm"]),
        .executable(name: "bptrace", targets: ["bptrace"]),
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
        .systemLibrary(
            name: "CHwt",
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
            name: "dtlm",
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
            name: "bptrace",
            dependencies: [],
            cSettings: [
                .unsafeFlags(["-I/usr/local/include/libipt"]),
            ],
            linkerSettings: [
                .linkedLibrary("ipt"),
                .linkedLibrary("elf"),
            ]
        ),
        .testTarget(
            name: "dtlmTests",
            dependencies: ["dtlm", "OTelExport"]
        ),
        .testTarget(
            name: "hwtlmTests",
            dependencies: ["hwtlm", "OTelExport"]
        ),
    ]
)
