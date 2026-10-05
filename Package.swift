// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ducko",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DuckoApp", targets: ["DuckoApp"]),
        .executable(name: "DuckoCLI", targets: ["DuckoCLI"]),
        .library(name: "DuckoCore", targets: ["DuckoCore"]),
        .library(name: "DuckoData", targets: ["DuckoData"]),
        .library(name: "DuckoXMPP", targets: ["DuckoXMPP"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.37.5")
    ],
    targets: [
        .systemLibrary(name: "CLibxml2", path: "Sources/CLibxml2", pkgConfig: "libxml-2.0"),
        .systemLibrary(name: "CDnssd", path: "Sources/CDnssd"),

        .target(name: "DuckoXMPP", dependencies: [
            "CLibxml2",
            "CDnssd",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Logging", package: "swift-log")
        ]),
        .testTarget(name: "DuckoXMPPTests", dependencies: ["DuckoXMPP", "DuckoTestSupport"], resources: [.copy("Fixtures")]),

        .target(name: "DuckoCore", dependencies: [
            "DuckoXMPP",
            .product(name: "Logging", package: "swift-log")
        ]),
        .target(name: "DuckoTestSupport", dependencies: ["DuckoCore", "DuckoXMPP"], path: "Sources/DuckoTestSupport"),
        .testTarget(name: "DuckoCoreTests", dependencies: ["DuckoCore", "DuckoTestSupport"]),

        .target(name: "DuckoData", dependencies: ["DuckoCore"]),
        .testTarget(name: "DuckoDataTests", dependencies: ["DuckoData", "DuckoTestSupport"]),

        .target(name: "DuckoUI", dependencies: [
            "DuckoCore",
            .product(name: "Logging", package: "swift-log")
        ]),
        .testTarget(name: "DuckoUITests", dependencies: ["DuckoUI", "DuckoTestSupport"]),

        .executableTarget(
            name: "DuckoApp",
            dependencies: [
                "DuckoCore",
                "DuckoData",
                "DuckoUI",
                "DuckoXMPP",
                "Sparkle",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(name: "DuckoAppTests", dependencies: ["DuckoApp"]),

        .executableTarget(
            name: "DuckoCLI",
            dependencies: [
                "DuckoCore",
                "DuckoData",
                "DuckoXMPP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(name: "DuckoCLITests", dependencies: ["DuckoCLI"]),

        .testTarget(name: "DuckoScriptTests")
    ]
)
