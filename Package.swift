// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "InjectionLite",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        // A self-contained of injection including log parsing and recompiling
        .library(
            name: "InjectionLite",
            targets: ["InjectionLite"]),
        // This is the in-memory substrate of injection loading a dynamic
        // libraray, interposing function pointers, updating class vtables
        // and performing old-school "Swizzling" of Objective-c methods.
        .library(
            name: "InjectionImpl",
            targets: ["InjectionImpl"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // Abstraction for performing shell command to grep logs and recompile.
        .package(url: "https://github.com/johnno1962/Popen",
                 .upToNextMajor(from: "2.1.8")),
        // An interface to in-memory symbol table of loaded images.
        .package(url: "https://github.com/johnno1962/DLKit",
                 .upToNextMajor(from: "3.4.11")),
        // No-fuss regular expressions for conditioning Strings.
        .package(url: "https://github.com/johnno1962/SwiftRegex5",
                 .upToNextMajor(from: "6.1.3")),
        // Swift filename matcher for gitignore pattern matching.
        .package(url: "https://github.com/ileitch/swift-filename-matcher.git", from: "2.0.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        // The stand-alone implementation, delegating actual "swizzing" to InjectionImpl
        .target(
            name: "InjectionLite",
            dependencies: ["InjectionImpl",
                // DEBUG_ONLY version of abstraction for popen().
                .product(name: "PopenD", package: "Popen"),
                // Swift filename matcher for gitignore pattern matching.
                .product(name: "FilenameMatcher", package: "swift-filename-matcher")]),
        // Implementation of "Swizzling for Swift" using interposing et all.
        .target(
            name: "InjectionImpl",
            dependencies: ["InjectionImplC",
                .product(name: "DLKitD", package: "DLKit"), // DEBUG_ONLY versions
                .product(name: "SwiftRegexD", package: "SwiftRegex")]),
        // Boots up standalone injection on load for InjectionLite product
        .target(
            name: "InjectionImplC"),
        // Yes, there are tests.
        .testTarget(
            name: "InjectionLiteTests",
            dependencies: ["InjectionLite",
                .product(name: "FilenameMatcher", package: "swift-filename-matcher")],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-interposable"])])]
)
