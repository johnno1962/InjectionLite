// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "InjectionLite",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "InjectionLite",
            targets: ["InjectionLite", "InjectionLiteC"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/johnno1962/DLKit",
                 .upToNextMinor(from: "3.0.2")),
        .package(url: "https://github.com/johnno1962/Popen",
                 .upToNextMinor(from: "1.1.0"))
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "InjectionLite",
            dependencies: ["DLKit", "Popen", "InjectionLiteC"]),
        .target(
            name: "InjectionLiteC",
            dependencies: []),
        .testTarget(
            name: "InjectionLiteTests",
            dependencies: ["InjectionLite"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-interposable"])])]
)
