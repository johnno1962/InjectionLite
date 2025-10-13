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

public func autoBitCast<IN,OUT>(_ x: IN) -> OUT {
    return unsafeBitCast(x, to: OUT.self)
}
@discardableResult /// Can be used in if statements
public func detail(_ str: @autoclosure () -> String) -> Bool {
    if getenv("INJECTION_DETAIL") != nil {
        log(str())
    }
    return true
}

extension Reloader {
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
    
    // Defaults for Xcode location and platform for linking
    public static var xcodeDev = "/Applications/Xcode.app/Contents/Developer"
    public static var platform = "iPhoneSimulator"
    public static var sysroot =
        "\(xcodeDev)/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk"
    public static var linkCommand = ""

    public static var optionsToRemove = #"(-(pch-output-dir|supplementary-output-file-map|emit-((reference-)?dependencies|const-values)|serialize-diagnostics|index-(store|unit-output))(-path)?|(-validate-clang-modules-once )?-clang-build-session-file|-Xcc -ivfsstatcache -Xcc)"#,
        typeCheckLimit = "-warn-long-expression-type-checking=150",
        typeCheckRegex = #"(?<=/)\w+\.swift:\d+:\d+: warning: expression took \d+ms to type-check.*"#

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
