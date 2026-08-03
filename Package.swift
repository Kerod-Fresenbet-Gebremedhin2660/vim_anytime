// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VimAny",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "VimAnyCore", targets: ["VimAnyCore"]),
        .executable(name: "VimAny", targets: ["VimAnyApp"]),
    ],
    targets: [
        .target(
            name: "VimAnyCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "VimAnyApp",
            dependencies: ["VimAnyCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "VimAnyCoreTests",
            dependencies: ["VimAnyCore"]
        ),
        .testTarget(
            name: "VimAnyIntegrationTests",
            dependencies: ["VimAnyCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
