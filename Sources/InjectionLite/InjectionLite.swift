//
//  InjectionLite.swift
//  Copyright © 2023 John Holdsworth. All rights reserved.
//
//  Start a FileWatcher in the user's home directory
//  and dispatch modified Swift files off to the
//  injection processing to recompile, link, load
//  and rebind into the app.
//
//  Created by John Holdsworth on 25/02/2023.
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation
#if canImport(InjectionImplC)
import InjectionImplC
import InjectionImpl
import DLKitD
#endif

@objc(InjectionLite)
open class InjectionLite: InjectionBase {
    var recompiler = Recompiler()
    var reloader = Reloader()

    override func inject(source: String) {
        let usingCached = recompiler.longTermCache[source] != nil
        if let dylib = recompiler.recompile(source: source, dylink: true),
           let (image, classes) = reloader.loadAndPatch(in: dylib) {
            reloader.sweeper.sweepAndRunTests(image: image, classes: classes)
        } else if usingCached { // Try again once, after reparsing logs.
            recompiler.longTermCache.removeObject(forKey: source)
            recompiler.writeToCache()
            inject(source: source)
        }
    }
}
#endif
