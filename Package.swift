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
// Depends on FreeBSDKit for the DTraceCore module (libdtrace
// bindings). dtlm does NOT depend on DBlocks — profiles are .d
// files loaded as text and handed to libdtrace via DTraceCore's
// compile/exec/go/poll/consume APIs.

import PackageDescription

let package = Package(
    name: "ObservableBSD",
    products: [
        .executable(name: "dtlm", targets: ["dtlm"]),
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
        .executableTarget(
            name: "dtlm",
            dependencies: [
                .product(name: "DTraceCore", package: "FreeBSDKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "CZlib",
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
