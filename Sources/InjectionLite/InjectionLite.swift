//
//  InjectionLite.swift
//
//  Start a FileWatcher in the user's home directory
//  and dispatch modified Swift files off to the
//  injection processing to recompile, link, load
//  and rebind into the app.
//
//  Created by John Holdsworth on 25/02/2023.
//

import Foundation
import DLKit

#if !targetEnvironment(simulator) && !os(macOS)
#error("InjectionLite can only be used in the simulator or unsandboxed macOS")
#endif

let APP_PREFIX = "🔥 ", APP_NAME = "InjectionLite"
func log(_ what: Any...) {
    print(APP_PREFIX+what.map {"\($0)"}.joined(separator: " "))
}
let showDetail = getenv("INJECTION_DETAIL") != nil
func detail(_ str: @autoclosure () -> String) {
    if showDetail {
        log(str())
    }
}

@objc(InjectionLite)
public class InjectionLite: NSObject {

    var watcher: FileWatcher?
    let recompiler = Recompiler()
    let reloader = Reloader()
    let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")

    /// Called from InjectionBoot.m, setup filewatch and wait...
    public override init() {
        super.init()
        DLKit.logger = { log($0) }
        let home = NSHomeDirectory()
            .replacingOccurrences(of: #"(/Users/[^/]+).*"#, with: "$1",
            options: .regularExpression)
        watcher = FileWatcher(roots: [home], callback: { filesChanged in
            for file in filesChanged {
                self.inject(source: file)
            }
        })
        log(APP_NAME+": Watching for source changes under \(home)/...")
    }

    func inject(source: String) {
        if let dylib = recompiler.recompile(source: source),
           let image = DLKit.load(dylib: dylib) {
            let (classes, generics) = reloader.patchClasses(in: image)
            if classes.count != 0 {
                log("Ignore messages about duplicate classes ⬆️")
            }
            let rebound = reloader.interposeSymbols(in: image)
            if classes.count == 0 && rebound.count == 0 {
                log("ℹ️ No symbols replaced, have you added -Xlinker -interposable to your project's \"Other Linker Flags\"?")
            }
            reloader.performSweep(oldClasses: classes, generics, image: image)
            NotificationCenter.default.post(name: notification, object: classes)
            log("Loaded and rebound \(classes)")
        }
    }
}
