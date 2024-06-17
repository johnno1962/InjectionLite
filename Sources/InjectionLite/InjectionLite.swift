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

#if DEBUG
import InjectionImplC
import InjectionImpl
import Foundation
import DLKitD

@objc(InjectionLite)
open class InjectionLite: NSObject {

    var watcher: FileWatcher?
    var recompiler = Recompiler()
    var reloader = Reloader()
    
    /// Called from InjectionBoot.m, setup filewatch and wait...
    public override init() {
        super.init()
        Reloader.injectionQueue.async {
            self.performInjection()
        }
    }

    func performInjection() {
        #if !targetEnvironment(simulator) && !os(macOS)
        log(APP_NAME+": can only be used in the simulator or unsandboxed macOS")
        #endif
        let home = NSHomeDirectory()
            .replacingOccurrences(of: #"(/Users/[^/]+).*"#,
                                  with: "$1", options: .regularExpression)
        var dirs = [home]
        let library = home+"/Library"
        if let extra = getenv("INJECTION_DIRECTORIES") {
            dirs = String(cString: extra).components(separatedBy: ",")
                .map { $0.replacingOccurrences(of: #"^~"#,
                   with: home, options: .regularExpression) } // expand ~ in paths
            if FileWatcher.derivedLog == nil && dirs.allSatisfy({
                $0 != home && !$0.hasPrefix(library) }) {
                log("⚠️ INJECTION_DIRECTORIES should contain ~/Library")
                dirs.append(library)
            }
        }

        let isVapor = Reloader.injectionQueue != .main
        watcher = FileWatcher(roots: dirs, callback: { filesChanged in
            for file in filesChanged {
                self.inject(source: file)
            }
        }, runLoop: isVapor ? CFRunLoopGetCurrent() : nil)
        log(APP_NAME+": Watching for source changes under \(home)/...")
        if isVapor {
            CFRunLoopRun()
        }
    }

    func inject(source: String) {
        let usingCached = recompiler.longTermCache[source] != nil
        if let dylib = recompiler.recompile(source: source),
           let (image, classes) = reloader.loadAndPatch(in: dylib) {
            reloader.sweeper.sweepAndRunTests(image: image, classes: classes)
        } else if usingCached {
            recompiler.longTermCache.removeObject(forKey: source)
            recompiler.writeToCache()
            inject(source: source)
        }
    }
}
#endif
