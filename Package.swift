// swift-tools-version: 6.3
//
// ObservableBSD — convert FreeBSD's instrumentation surface to
// OpenTelemetry telemetry. The first (and currently only)
// executable target is `dtlm`, which bridges DTrace probe data
// (and, post-v1, the hwt(4) Hardware Trace Framework — see
// DESIGN-HWT.md) into structured OTel signals.
//
// As ObservableBSD grows, additional executable targets and
// shared library targets will be added to this same package
// using the FreeBSDKit-style multi-target layout.
//
// Pinned against FreeBSDKit 0.2.3 for the DTraceCore module (the
// libdtrace bindings). The dtlm executable intentionally does NOT
// depend on DBlocks — profiles are .d files loaded as text and
// handed to libdtrace via DTraceCore's compile/exec/go/work/consume
// APIs.

import PackageDescription

let package = Package(
    name: "ObservableBSD",
    products: [
        .executable(name: "dtlm", targets: ["dtlm"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SwiftBSD/FreeBSDKit",
            branch: "main"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.2.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "dtlm",
            dependencies: [
                .product(name: "DTraceCore", package: "FreeBSDKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [
                // Bundle the hand-authored .d profiles as SwiftPM
                // resources. Loaded at runtime via Bundle.module.url.
                .process("Profiles"),
            ]
        ),
        .testTarget(
            name: "dtlmTests",
            dependencies: ["dtlm"]
        ),
    ]
)
