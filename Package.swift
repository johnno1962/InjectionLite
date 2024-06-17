// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "InjectionLite",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "InjectionLite",
            targets: ["InjectionLite"]),
        .library(
            name: "InjectionImpl",
            targets: ["InjectionImpl"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/johnno1962/DLKit",
                 .upToNextMajor(from: "3.4.1")),
        .package(url: "https://github.com/johnno1962/Popen",
                 .upToNextMajor(from: "2.1.6")),
        .package(url: "https://github.com/johnno1962/SwiftRegex5",
                 .upToNextMajor(from: "6.1.2")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "InjectionLite",
            dependencies: ["InjectionImpl",
                .product(name: "PopenD", package: "Popen")]),
        .target(
            name: "InjectionImpl",
            dependencies: ["InjectionImplC",
                .product(name: "DLKitD", package: "DLKit"),
                .product(name: "SwiftRegexD", package: "SwiftRegex")]),
        .target(
            name: "InjectionImplC"),
        .testTarget(
            name: "InjectionLiteTests",
            dependencies: ["InjectionLite"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-interposable"])])]
)
