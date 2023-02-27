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

    var watcher: FileWatcher!
    let recompiler: Recompiler
    let reloader: Reloader
    let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")

    public override init() {
        let home = NSHomeDirectory()
            .replacingOccurrences(of: #"(/Users/[^/]+).*"#, with: "$1",
            options: .regularExpression)
        recompiler = Recompiler()
        reloader = Reloader()
        super.init()
        DLKit.logger = { log($0) }
        watcher = FileWatcher(roots: [home], callback: { filesChanged in
            for file in filesChanged {
                self.inject(source: file)
            }
        })
        log(APP_NAME+": Watching for source changes under \(home)/...")
    }

    func inject(source: String) {
        log("Recompiling \(source)")
        if let dylib = recompiler
            .recompile(source: source),
        let image = DLKit.load(dylib: dylib) {
            let classes = reloader.rebind(image: image)
            SwiftSweeper.performSweep(oldClasses: classes)
            NotificationCenter.default.post(name: notification, object: classes)
            log("Loaded and rebound \(classes)")
        }
    }
}
