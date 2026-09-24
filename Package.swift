// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

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
                // Command Line Tools ships swift-testing's macro plugin in plugins/testing/, which the
                // compiler driver does not search by default (Xcode installs it in plugins/).
                // Harmless extra search path on machines where it does not exist.
                .unsafeFlags([
                    "-plugin-path",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
                ])
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
