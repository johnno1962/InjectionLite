//
//  Common.swift
//
//  Created by John Holdsworth on 17/06/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  A collection of code and state shared by InjectionImpl.
//
#if DEBUG || !SWIFT_PACKAGE
import Foundation
#if canImport(InjectionImplC)
import InjectionImplC
#endif

/// Inhibit loading of injection bundle.
@objc(InjectionClient)
public class InjectionClient: NSObject {
    @objc class func connectTo(_ host: String) -> NSObject? {
        log("⚠️ App loading iOSInjection.bundle but also " +
            "using InjectionLite/InjectionNext Swift Package.")
        /// iOSInjection.bundle allowed to run standalone.
        return nil //InjectionBoth()
    }

    public class InjectionBoth: NSObject {
        @objc func run() {}
    }
}

#if !canImport(Nimble) && !canImport(InjectionNextC)
public func autoBitCast<IN,OUT>(_ x: IN) -> OUT {
    return unsafeBitCast(x, to: OUT.self)
}
#endif
@discardableResult /// Can be used in if statements
public func detail(_ str: @autoclosure () -> String) -> Bool {
    if getenv("INJECTION_DETAIL") != nil {
        log(str())
    }
    return true
}

extension Reloader {
    public static var traceHook = { (injected: UnsafeMutableRawPointer,
                                     symname: UnsafePointer<CChar>) in
                                    return injected }
    static func traceSIMP<T>(_ simp: T, _ name: UnsafePointer<CChar>) -> T {
        return unsafeBitCast(traceHook(unsafeBitCast(simp,
                 to: UnsafeMutableRawPointer.self), name), to: T.self)
    }
    public static var injectionNumber = 0
    // Injection is relatively thread safe as interposes etc. are atomic but..
    #if os(macOS)
    public static var injectionQueue = DispatchQueue(label: "InjectionQueue")
    #else
    public static let injectionQueue = DispatchQueue.main
    #endif
    // Determines name of cache .plist file in /tmp
    #if os(macOS) || targetEnvironment(macCatalyst)
    static let sdk = "macOS"
    #elseif os(tvOS)
    static let sdk = "tvOS"
    #elseif os(visionOS)
    static let sdk = "xrOS"
    #elseif targetEnvironment(simulator)
    static let sdk = "iOS_Simulator"
    #else
    static let sdk = "iOS"
    #endif
    #if arch(arm64)
    public static var arch = "arm64"
    #elseif arch(arm)
    public static var arch = "armv7"
    #elseif arch(x86_64)
    public static var arch = "x86_64"
    #endif
    public static let appName = Bundle.main.executableURL?.lastPathComponent ?? "Unknown"
    public static var cacheFile = "/tmp/\(appName)_\(sdk)_builds.plist"
    public static var unhider: (() -> Void)?

    public static var optionsToRemove = #"(-(pch-output-dir|supplementary-output-file-map|emit-((reference-)?dependencies|const-values)|serialize-diagnostics|index-(store|unit-output))(-path)?|(-validate-clang-modules-once )?-clang-build-session-file|-Xcc -ivfsstatcache -Xcc)"#,
        typeCheckLimit = "-warn-long-expression-type-checking=150",
        typeCheckRegex = #"(?<=/)\w+\.swift:\d+:\d+: warning: expression took \d+ms to type-check.*"#

    /// Regex for path argument, perhaps containg escaped spaces
    public static let argumentRegex = #"[^\s\\]*(?:\\.[^\s\\]*)*"#
    /// Regex to extract filename base, perhaps containg escaped spaces
    public static let fileNameRegex = #"/(\#(argumentRegex))\.\w+"#
    /// Parse -sdk argument to extract sdk, Xcode path, platform
    static let parsePlatform = try! NSRegularExpression(pattern:
        #"-(?:isysroot|sdk)(?: |"\n")((\#(fileNameRegex)/Contents/Developer)/Platforms/(\w+)\.platform\#(fileNameRegex)\#\.sdk)"#)

    // Defaults for Xcode location and platform for linking
    public static var xcodeDev = "/Applications/Xcode.app/Contents/Developer"
    public static var platform = "iPhoneSimulator"
    public static var sysroot =
        "\(xcodeDev)/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk"
    public static var linkCommand = ""

    public static func extractLinkCommand(from compileCommand: String) {
        // Default for Objective-C with Xcode 15.3+
        sysroot = "\(xcodeDev)/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk"
        // Extract sdk, Xcode path and platform from compilation command
        if let match = parsePlatform.firstMatch(in: compileCommand,
            options: [], range: NSMakeRange(0, compileCommand.utf16.count)) {
            func extract(group: Int, into: inout String) {
                if let range = Range(match.range(at: group), in: compileCommand) {
                    into = compileCommand[range]
                        .replacingOccurrences(of: #"\\(.)"#, with: "$1",
                                              options: .regularExpression)
                }
            }
            extract(group: 1, into: &sysroot)
            extract(group: 2, into: &xcodeDev)
            extract(group: 4, into: &platform)
        } else if compileCommand.contains(" -o ") {
            log("⚠️ Unable to parse SDK from: \(compileCommand)")
            #if canImport(InjectionBazel) && os(macOS)
            // Only resolve when we can't extract from compile command
            // This avoids unnecessary processing for the common case
            let resolvedXcodeDev = BinaryResolver.shared.resolveXcodeDeveloperDir()
            if xcodeDev == "/Applications/Xcode.app/Contents/Developer" {
                xcodeDev = resolvedXcodeDev
            }
            #endif
            // Use resolved path for SDK construction
            sysroot = "\(xcodeDev)/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk"
        }

        let osSpecific: String
        switch platform {
        case "iPhoneSimulator":
            osSpecific = "-mios-simulator-version-min=9.0"
        case "iPhoneOS":
            osSpecific = "-miphoneos-version-min=9.0"
        case "AppleTVSimulator":
            osSpecific = "-mtvos-simulator-version-min=9.0"
        case "AppleTVOS":
            osSpecific = "-mtvos-version-min=9.0"
        case "MacOSX":
            let target = compileCommand
                .replacingOccurrences(of: #"^.*( -target \S+).*$"#,
                                      with: "$1", options: .regularExpression)
            osSpecific = "-mmacosx-version-min=10.11"+target
        case "XRSimulator": fallthrough case "XROS": fallthrough
        default:
            osSpecific = ""
            log("⚠️ Invalid platform \(platform)")
            // -Xlinker -bundle_loader -Xlinker \"\(Bundle.main.executablePath!)\""
        }

        let toolchain = xcodeDev+"/Toolchains/XcodeDefault.xctoolchain"
        let frameworks = Bundle.main.privateFrameworksPath ?? "/tmp"
        Self.linkCommand = """
            "\(toolchain)/usr/bin/clang" -arch "\(arch)" \
                -Xlinker -dylib -isysroot "\(sysroot)" \(osSpecific) \
                -L"\(toolchain)/usr/lib/swift/\(platform.lowercased())" \
                -undefined dynamic_lookup -dead_strip -Xlinker -objc_abi_version \
                -Xlinker 2 -Xlinker -interposable -fobjc-arc \
                -fprofile-instr-generate -L "\(frameworks)" -F "\(frameworks)" \
                -rpath "\(frameworks)" -rpath /usr/lib/swift \
                -rpath "\(toolchain)/usr/lib/swift-5.5/\(platform.lowercased())"
            """
    }

    /// A way to determine if a file being injected is an XCTest
    public static func injectingXCTest(in dylib: String) -> Bool {
        if let object = NSData(contentsOfFile: dylib),
           memmem(object.bytes, object.count, "XCTest", 6) != nil ||
            memmem(object.bytes, object.count, "Quick", 5) != nil,
           object.count != 0 { return true }
        return false
    }
}
#endif
