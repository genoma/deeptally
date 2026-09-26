// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

// Command Line Tools ships swift-testing's macro plugin in plugins/testing/, which the compiler
// driver does not search by default (Xcode installs it in plugins/). Harmless extra search path on
// machines where it does not exist. Spelled out per test target and not shared through one variable:
// a shared `SwiftSetting` list made SwiftPM drop the flag from one of the two targets.
let package = Package(
    name: "DeepTally",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "DeepTallyApp", targets: ["DeepTallyApp"]),
        .executable(name: "deeptally", targets: ["deeptally"]),
        .library(name: "DeepTallyCore", targets: ["DeepTallyCore"]),
    ],
    targets: [
        .target(
            name: "DeepTallyCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "DeepTallyApp",
            dependencies: ["DeepTallyCore"]
        ),
        .executableTarget(
            name: "deeptally",
            dependencies: ["DeepTallyCore"],
            path: "Sources/DeepTallyCLI"
        ),
        .testTarget(
            name: "DeepTallyCoreTests",
            dependencies: ["DeepTallyCore"],
            swiftSettings: [
                .unsafeFlags([
                    "-plugin-path",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
                ])
            ]
        ),
        // The app target is an executable, and SwiftPM links it into the test bundle anyway, so the app
        // layer is tested in place: no library extraction, no duplicated seam types. Verified on this
        // machine's CLT-only toolchain — `swift test` builds and runs this target.
        .testTarget(
            name: "DeepTallyAppTests",
            dependencies: ["DeepTallyApp", "DeepTallyCore"],
            swiftSettings: [
                .unsafeFlags([
                    "-plugin-path",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
                ])
            ]
        ),
        // Same reason as the app target, which this mirrors: `deeptally` is an executable, and SwiftPM
        // links it into the test bundle in place, so the command surface and the reports it prints are
        // tested without extracting a library or duplicating a seam.
        .testTarget(
            name: "DeepTallyCLITests",
            dependencies: ["deeptally", "DeepTallyCore"],
            swiftSettings: [
                .unsafeFlags([
                    "-plugin-path",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
                ])
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
