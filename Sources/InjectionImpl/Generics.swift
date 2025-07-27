//
//  Generics.swift
//  InjectionLite
//
//  Created by John Holdsworth on 16/07/2025.
//  Copyright © 2025 John Holdsworth. All rights reserved.
//
//  New implementation of injecting methods in generic classes.
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation
import os.lock
#if canImport(DLKitD)
import fishhookD
import DLKitD
#endif

private struct TrackingGenerics {
    typealias GenericAllocFunc = @convention(c) (UnsafeMutableRawPointer,
                        UnsafeRawPointer, UnsafeRawPointer) -> AnyClass

    static let allocFuncName = "swift_allocateGenericClassMetadata"
    static var save_allocateGeneric: GenericAllocFunc!

    private static var registryLock = os_unfair_lock()
    private static var _registry = [String: [AnyClass]]()
    
    static func addToRegistry(baseName: String, newClass: AnyClass) {
        os_unfair_lock_lock(&registryLock)
        defer { os_unfair_lock_unlock(&registryLock) }
        _registry[baseName, default: []].append(newClass)
    }
    
    static func getClasses(for baseName: String) -> [AnyClass] {
        os_unfair_lock_lock(&registryLock)
        defer { os_unfair_lock_unlock(&registryLock) }
        return _registry[baseName] ?? []
    }
}

@_cdecl("injection_hookGenerics")
public func hookGenerics(original: UnsafeMutableRawPointer,
                         replacer: UnsafeMutableRawPointer) {
    TrackingGenerics.save_allocateGeneric = autoBitCast(original)
    var genericAllocRebinding = [rebinding(name: strdup(TrackingGenerics.allocFuncName),
                                           replacement: replacer, replaced: nil)]
    #if canImport(Nimble) || SWIFT_PACKAGE
    Reloader.interposed[TrackingGenerics.allocFuncName] = replacer
    _ = DLKit.appImages.rebind(rebindings: &genericAllocRebinding)
    #else
    SwiftTrace.initialRebindings += genericAllocRebinding
    _ = SwiftTrace.apply(rebindings: &genericAllocRebinding)
    #endif
}

@_cdecl("injection_allocateGenericClassMetadata")
public func injection_allocateGeneric(description: UnsafeMutableRawPointer,
    arguments: UnsafeRawPointer, pattern: UnsafeMutableRawPointer) -> AnyClass {
    let newClass: AnyClass = TrackingGenerics.save_allocateGeneric(description, arguments, pattern)
    let fullName = _typeName(newClass)
    if let params = fullName.firstIndex(of: "<") {
        let baseName = String(fullName.prefix(upTo: params))
        TrackingGenerics.addToRegistry(baseName: baseName, newClass: newClass)
    }
    return newClass
}

#if canImport(Nimble) || SWIFT_PACKAGE // InjectionNext
extension Sweeper {
    func hookedPatch(of generics: Set<String>, in image: ImageSymbols) -> [AnyClass] {
        var patched = Set<UnsafeRawPointer>()
        for baseName in generics {
            for special in TrackingGenerics.getClasses(for: baseName) {
                _ = patchGenerics(oldClass: special, image: image,
                                  injectedGenerics: generics, patched: &patched)
            }
        }
        let patchedClasses = patched.map { unsafeBitCast($0, to: AnyClass.self) }
        if !patched.isEmpty {
            detail("Patched generics \(patchedClasses)")
        }
        return patchedClasses
    }
}
#else // backport for InjectionIII
extension SwiftInjection {
    static func hookedPatch(of generics: Set<String>, tmpfile: String) -> [AnyClass] {
        var patched = Set<UnsafeRawPointer>()
        for baseName in generics {
            for special in TrackingGenerics.getClasses(for: baseName) {
                _ = patchGenerics(oldClass: special, tmpfile: tmpfile,
                                  injectedGenerics: generics, patched: &patched)
            }
        }
        let patchedClasses = patched.map { unsafeBitCast($0, to: AnyClass.self) }
        if !patched.isEmpty {
            detail("Patched generics \(patchedClasses)")
        }
        return patchedClasses
    }
}
#endif
#endif
