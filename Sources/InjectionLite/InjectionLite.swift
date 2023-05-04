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

import InjectionLiteC
import Foundation
import DLKit

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

// for compatability
@objc(InjectionClient)
public class InjectionClient: NSObject {
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
        #if !targetEnvironment(simulator) && !os(macOS)
        #warning("InjectionLite can only be used in the simulator or unsandboxed macOS")
        log(APP_NAME+": can only be used in the simulator or unsandboxed macOS")
        #endif
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
        let isTest = source.replacingOccurrences(of: #"Tests?\."#,
            with: "-", options: .regularExpression) != source
        if let dylib = recompiler.recompile(source: source),
           isTest ? loadXCTest : true,
           let image = DLKit.load(dylib: dylib) {
            let (classes, generics) = reloader.patchClasses(in: image)
            if classes.count != 0 {
                log("Ignore messages about duplicate classes ⬆️")
            }

            let rebound = reloader.interposeSymbols(in: image)
            if classes.count == 0 && rebound.count == 0 &&
                image.entries(withPrefix: "_OBJC_$_CATEGORY_").count == 0 {
                log("ℹ️ No symbols replaced, have you added -Xlinker -interposable to your project's \"Other Linker Flags\"?")
            }

            reloader.performSweep(oldClasses: classes, generics, image: image)
            NotificationCenter.default.post(name: notification, object: classes)
            log("Loaded and rebound \(classes)")

            if let XCTestCase = objc_getClass("XCTestCase") as? AnyClass {
                for test in classes where isSubclass(test, of: XCTestCase) {
                    print("\n\(APP_PREFIX)Running test \(test)")
                    NSObject.runXCTestCase(test)
                }
            }
        } else {
            recompiler.longTermCache.removeObject(forKey: source)
            recompiler.writeToCache()
        }
    }

    open func isSubclass(_ subClass: AnyClass, of aClass: AnyClass) -> Bool {
        var subClass: AnyClass? = subClass
        repeat {
            if subClass == aClass {
                return true
            }
            subClass = class_getSuperclass(subClass)
        } while subClass != nil
        return false
    }

    lazy var loadXCTest: Bool = {
        let platformDev = recompiler.xcodeDev +
            "/Platforms/\(recompiler.platform).platform/Developer/"

        _ = DLKit.load(dylib: platformDev +
                       "Library/Frameworks/XCTest.framework/XCTest")
        _ = DLKit.load(dylib: platformDev +
                       "usr/lib/libXCTestSwiftSupport.dylib")

        if let plugins = Bundle.main.path(forResource: "PlugIns", ofType: nil),
           let contents = try? FileManager.default
            .contentsOfDirectory(atPath: plugins) {
            for xctest in contents {
                let name = xctest
                    .replacingOccurrences(of: ".xctest", with: "")
                if name != xctest {
                    _ = DLKit.load(dylib: plugins+"/"+xctest+"/"+name)
                }
            }
        }
        return true
    }()
}
