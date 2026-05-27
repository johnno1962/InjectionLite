// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "InjectionLite",
    platforms: [.iOS(.v12), .macOS("10.12")],
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
        // Expose InjectionBazel so embedders can flip `BazelInterface.isDisabled`
        // at startup to skip the Bazel workspace probe when they're not
        // using Bazel — avoids the spurious "Failed to create BazelAQueryParser"
        // log line on every save.
        .library(
            name: "InjectionBazel",
            targets: ["InjectionBazel"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // Abstraction for performing shell command to grep logs and recompile.
        .package(url: "https://github.com/johnno1962/Popen",
                 .upToNextMajor(from: "2.2.1")),
        // An interface to in-memory symbol table of loaded images.
        .package(url: "https://github.com/johnno1962/DLKit",
                 .upToNextMajor(from: "3.5.7")),
        // No-fuss regular expressions for conditioning Strings.
        .package(url: "https://github.com/johnno1962/SwiftRegex5",
                 .upToNextMajor(from: "6.3.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        // The stand-alone implementation, delegating actual "swizzing" to InjectionImpl
        .target(
            name: "InjectionLite",
            dependencies: ["InjectionImpl", "InjectionBazel",
                // DEBUG_ONLY version of abstraction for popen().
                .product(name: "PopenD", package: "Popen")]),
        // Implementation of "Swizzling for Swift" using interposing et all.
        .target(
            name: "InjectionImpl",
            dependencies: ["InjectionImplC",
                .product(name: "PopenD", package: "Popen"),
                // Also declare the non-debug Popen — Xcode 26's dep
                // scanner reads ALL #if branches in source files; some
                // branches `import Popen` (without D), and without this
                // dep declared the scanner emits a (mislabeled?) warning
                // about a missing PopenD dependency.
                .product(name: "Popen", package: "Popen"),
                .product(name: "DLKitD", package: "DLKit"), // DEBUG_ONLY versions
                .product(name: "SwiftRegexD", package: "SwiftRegex")]),
        // Boots up standalone injection on load for InjectionLite product
        .target(
            name: "InjectionBazel", dependencies: ["InjectionImpl",
                .product(name: "DLKitD", package: "DLKit"),
                .product(name: "PopenD", package: "Popen")]),
        .target(
            name: "InjectionImplC"),
        // Yes, there are tests.
        .testTarget(
            name: "InjectionLiteTests",
            dependencies: ["InjectionLite"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-interposable"])])
    ],
    swiftLanguageVersions: [.v5]
)
