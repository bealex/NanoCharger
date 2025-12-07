// swift-tools-version:6.2

// Copyright (c) 2025 Alex Babaev. All rights reserved.

import PackageDescription

let package = Package(
    name: "NanoCharger",
    platforms: [ .macOS(.v14) ],
    products: [
        .executable(name: "nanocharger", targets: [ "NanoCharger" ]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(name: "NanoCharger", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Subprocess", package: "swift-subprocess"),
        ], path: "Sources"),
    ],
   swiftLanguageModes: [ .v6 ]
)
