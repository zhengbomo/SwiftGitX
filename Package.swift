// swift-tools-version: 6.0
// The minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftGitX",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1),
        .watchOS(.v6)
    ],
    products: [
        .library(
            name: "SwiftGitX",
            targets: ["SwiftGitX"]
        )
    ],
    dependencies: [
        // static-libgit2 提供预编译的 Clibgit2，包含 libgit2 + libssh2 + OpenSSL
        .package(url: "https://github.com/flaboy/static-libgit2", from: "1.8.4")
    ],
    targets: [
        .target(
            name: "SwiftGitX",
            dependencies: [
                .product(name: "static-libgit2", package: "static-libgit2")
            ]
        ),
        .testTarget(
            name: "SwiftGitXTests",
            dependencies: ["SwiftGitX"]
        )
    ]
)
