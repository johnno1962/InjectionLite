//
//  Common.swift
//
//  Created by John Holdsworth on 17/06/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  A collection of code and state shared by InjectionImpl.
//
#if DEBUG
import Foundation
import InjectionImplC

// Inhibit loading of injection bundle.
@objc(InjectionClient)
public class InjectionClient: NSObject {
}

public func autoBitCast<IN,OUT>(_ x: IN) -> OUT {
    return unsafeBitCast(x, to: OUT.self)
}
/// Message Xcode console
public func log(_ what: Any..., separator: String = " ") {
    print(APP_PREFIX+what.map {"\($0)"}.joined(separator: separator))
}
@discardableResult /// Can be used in if statements
public func detail(_ str: @autoclosure () -> String) -> Bool {
    if getenv("INJECTION_DETAIL") != nil {
        log(str())
    }
    return true
}

extension Reloader {
    // Injection is relatively thread safe as interposes etc. are atomic but..
    #if os(macOS)
    public static let injectionQueue = DispatchQueue(label: "InjectionQueue")
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
    static let sdk = "iOS"
    #else
    static let sdk = "maciOS"
    #endif
    public static let appName = Bundle.main.executableURL?.lastPathComponent ?? "Unknown"
    public static var cacheFile = "/tmp/\(appName)_\(sdk)_builds.plist"
    // Defaults for Xcode location and platform
    public static var xcodeDev = "/Applications/Xcode.app/Contents/Developer"
    public static var platform = "iPhoneSimulator"
}
#endif
