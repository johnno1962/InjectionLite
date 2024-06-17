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
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation
import SwiftRegexD
import fishhookD
import DLKitD

private struct ViewBodyKeyPaths {
    typealias KeyPathFunc = @convention(c) (UnsafeMutableRawPointer,
                                            UnsafeRawPointer) -> UnsafeRawPointer

    static let keyPathFuncName = "swift_getKeyPath"
    static var save_getKeyPath: KeyPathFunc!

    static var cache = [String: ViewBodyKeyPaths]()
    static var lastInjectionNumber = Reloader.injectionNumber
    static var hasInjected = false

    var lastOffset = 0
    var keyPathNumber = 0
    var recycled = false
    var keyPaths = [UnsafeRawPointer]()
}

@_cdecl("hookKeyPaths")
public func hookKeyPaths() {
    let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
    guard let original = dlsym(RTLD_DEFAULT, ViewBodyKeyPaths.keyPathFuncName) else {
        print("⚠️ Could not find original symbol: \(ViewBodyKeyPaths.keyPathFuncName)")
        return
    }
    guard let replacer = dlsym(RTLD_DEFAULT, "injection_getKeyPath") else {
        print("⚠️ Could not find replacement symbol: injection_getKeyPath")
        return
    }
    ViewBodyKeyPaths.save_getKeyPath = autoBitCast(original)
    var keyPathRebinding = [rebinding(name: strdup(ViewBodyKeyPaths.keyPathFuncName),
                                      replacement: replacer, replaced: nil)]
    Reloader.interposed[ViewBodyKeyPaths.keyPathFuncName] = replacer
    _ = DLKit.appImages.rebind(rebindings: &keyPathRebinding)
}

@_cdecl("injection_getKeyPath")
public func injection_getKeyPath(pattern: UnsafeMutableRawPointer,
                                 arguments: UnsafeRawPointer) -> UnsafeRawPointer {
    if ViewBodyKeyPaths.lastInjectionNumber != Reloader.injectionNumber {
        ViewBodyKeyPaths.lastInjectionNumber = Reloader.injectionNumber
        for key in ViewBodyKeyPaths.cache.keys {
            ViewBodyKeyPaths.cache[key]?.keyPathNumber = 0
            ViewBodyKeyPaths.cache[key]?.recycled = false
        }
        ViewBodyKeyPaths.hasInjected = true
    }
    var info = Dl_info()
    for caller in Thread.callStackReturnAddresses.dropFirst() {
        guard let caller = caller.pointerValue,
              dladdr(caller, &info) != 0, let symbol = info.dli_sname,
              let callerDecl = symbol.demangled else {
            continue
        }
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
            detail("Recycling \(callerKey)\(body.keyPathNumber)")
            keyPath = body.keyPaths[body.keyPathNumber]
            body.recycled = true
        } else {
            keyPath = ViewBodyKeyPaths.save_getKeyPath(pattern, arguments)
            if body.keyPaths.count == body.keyPathNumber {
                body.keyPaths.append(keyPath)
            }
            if body.recycled {
                log("""
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
