//
//  SwiftKeyPath.swift
//
//  Created by John Holdsworth on 20/03/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftKeyPath.swift#28 $
//
//  Key paths weren't made to be injected as their underlying types can change.
//  This is particularly evident in code that uses "The Composable Architecture".
//  This code maintains a cache of previously allocated key paths using a unique
//  identifier of the calling site so they remain invariant over an injection.
//  This isn't an easy peice of code to understand but you shouldn't need to.
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation
#if canImport(SwiftRegexD)
import InjectionImplC
import SwiftRegexD
import fishhookD
import DLKitD
#endif

private struct ViewBodyKeyPaths {
    typealias KeyPathFunc = @convention(c) (UnsafeMutableRawPointer,
                                            UnsafeRawPointer) -> UnsafeRawPointer

    static let keyPathFuncName = "swift_getKeyPath"
    static var save_getKeyPath: KeyPathFunc!

    static var cache = [String: ViewBodyKeyPaths]()
    #if canImport(Nimble) || SWIFT_PACKAGE // InjectionNext
    static var injectionNumber: Int { Reloader.injectionNumber }
    static var lastInjectionNumber = injectionNumber
    #if canImport(DLKitD)
    static func log(_ what: Any...) { InjectionImpl.log(what) }
    static var detail = InjectionImpl.detail
    #else
    static func log(_ what: Any...) { InjectionBundle.log(what) }
    static var detail = InjectionBundle.detail
    #endif
    #else
    static var injectionNumber: Int { SwiftEval.instance.injectionNumber }
    static var lastInjectionNumber = SwiftEval().injectionNumber
    #endif
    static var hasInjected = false

    var lastOffset = 0
    var keyPathNumber = 0
    var recycled = false
    var keyPaths = [UnsafeRawPointer]()
}

#if canImport(Nimble) || SWIFT_PACKAGE // InjectionNext
private typealias SwiftInjection = ViewBodyKeyPaths
#endif

@_cdecl("hookKeyPaths")
public func hookKeyPaths(original: UnsafeMutableRawPointer,
                         replacer: UnsafeMutableRawPointer) {
// Use of dlsym() here causes Xcode 16's previews to deadlock and time out.
//    let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
//    guard let original = dlsym(RTLD_DEFAULT, ViewBodyKeyPaths.keyPathFuncName) else {
//        print("⚠️ Could not find original symbol: \(ViewBodyKeyPaths.keyPathFuncName)")
//        return
//    }
//    guard let replacer = dlsym(RTLD_DEFAULT, "injection_getKeyPath") else {
//        print("⚠️ Could not find replacement symbol: injection_getKeyPath")
//        return
//    }
    SwiftInjection.log(
        "ℹ️ Intercepting keypaths for when their types are injected. Add an " +
        "env. var \(INJECTION_NOKEYPATHS) to your scheme to opt-out of this.")
    ViewBodyKeyPaths.save_getKeyPath = autoBitCast(original)
    var keyPathRebinding = [rebinding(name: strdup(ViewBodyKeyPaths.keyPathFuncName),
                                      replacement: replacer, replaced: nil)]
    #if canImport(Nimble) || SWIFT_PACKAGE // InjectionNext
    Reloader.interposed[ViewBodyKeyPaths.keyPathFuncName] = replacer
    _ = DLKit.appImages.rebind(rebindings: &keyPathRebinding)
    #else
    SwiftTrace.initialRebindings += keyPathRebinding
    _ = SwiftTrace.apply(rebindings: &keyPathRebinding)
    #endif
}

@_cdecl("injection_getKeyPath")
public func injection_getKeyPath(pattern: UnsafeMutableRawPointer,
                                 arguments: UnsafeRawPointer) -> UnsafeRawPointer {
    if ViewBodyKeyPaths.lastInjectionNumber != ViewBodyKeyPaths.injectionNumber {
        ViewBodyKeyPaths.lastInjectionNumber = ViewBodyKeyPaths.injectionNumber
        for key in ViewBodyKeyPaths.cache.keys { // Reset counters
            ViewBodyKeyPaths.cache[key]?.keyPathNumber = 0
            ViewBodyKeyPaths.cache[key]?.recycled = false
        }
        ViewBodyKeyPaths.hasInjected = true
    }
    for caller in Thread.callStackReturnAddresses.dropFirst() {
        #if canImport(Nimble) || SWIFT_PACKAGE // InjectionNext
        guard let caller = caller.pointerValue, let dlinfo =
                Reloader.cachedGetInfo(image: DLKit.allImages, impl: caller),
              let callerDecl = dlinfo.name.demangled else {
            continue
        }
        let info = dlinfo.info
        #else
        var info = Dl_info()
        guard let caller = caller.pointerValue,
              dladdr(caller, &info) != 0, let symbol = info.dli_sname,
              let callerDecl = SwiftMeta.demangle(symbol: symbol) else {
                continue
        }
        #endif
        if !callerDecl.hasSuffix(".body.getter : some") {
            break
        }
        // identify caller site
        var relevant: [String] = callerDecl[#"(closure #\d+ |in \S+ : some)"#]
        if relevant.isEmpty {
            relevant = [callerDecl]
        }
        let callerKey = relevant.joined() + ".keyPath#"
//        print(callerSym, ins)
        var body = ViewBodyKeyPaths.cache[callerKey] ?? ViewBodyKeyPaths()
        // reset keyPath counter ?
        let offset = caller-info.dli_saddr
        if offset <= body.lastOffset {
            body.keyPathNumber = 0
            body.recycled = false
        }
        body.lastOffset = offset
//        print(">>", offset, body.keyPathNumber)
        // extract cached keyPath or create
        let keyPath: UnsafeRawPointer
        if body.keyPathNumber < body.keyPaths.count && ViewBodyKeyPaths.hasInjected {
            _ = SwiftInjection.detail("Recycling \(callerKey)\(body.keyPathNumber)")
            keyPath = body.keyPaths[body.keyPathNumber]
            body.recycled = true
        } else {
            keyPath = ViewBodyKeyPaths.save_getKeyPath(pattern, arguments)
            if body.keyPaths.count == body.keyPathNumber {
                body.keyPaths.append(keyPath)
            }
            if body.recycled {
                SwiftInjection.log("""
                    ⚠️ New key path expression introduced over injection. \
                    This will likely fail and you'll have to restart your \
                    application.
                    """)
            }
        }
        body.keyPathNumber += 1
        ViewBodyKeyPaths.cache[callerKey] = body
        _ = Unmanaged<AnyKeyPath>.fromOpaque(keyPath).retain()
        return keyPath
    }
    return ViewBodyKeyPaths.save_getKeyPath(pattern, arguments)
}
#endif
