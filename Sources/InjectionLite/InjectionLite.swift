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

#if DEBUG
import InjectionLiteC
import Foundation
import DLKit

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
open class InjectionLite: NSObject {

    var watcher: FileWatcher?
    var recompiler = Recompiler()
    var reloader = Reloader()
    let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
    public let injectionQueue = dlsym(RTLD_DEFAULT, VAPOR_SYMBOL) != nil ?
        DispatchQueue(label: "InjectionQueue") : .main

    open class func detail(_ msg: @autoclosure () -> String) {
        if getenv("INJECTION_DETAIL") != nil {
            log(msg())
        }
    }
    open class func log(_ what: Any...) {
        let msg = what.map {"\($0)"}.joined(separator: " ")
        print(APP_PREFIX+msg)
        if msg.contains("symbol not found") {
            print("""
            ℹ️ Symbol not found during load. Unfortunately it is not possible \
            to inject code that uses a default argument when calling a function. \
            Make the value explicit and this should work.
            """)
        }
    }

    public init(passive: Bool) {
        DLKit.logger = { Self.log($0) }
        super.init()
    }

    /// Called from InjectionBoot.m, setup filewatch and wait...
    public convenience override init() {
        self.init(passive: false)
        injectionQueue.async {
            self.performInjection()
        }
    }

    func performInjection() {
        #if !targetEnvironment(simulator) && !os(macOS)
        Self.log(APP_NAME+": can only be used in the simulator or unsandboxed macOS")
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
                Self.log("⚠️ INJECTION_DIRECTORIES should contain ~/Library")
                dirs.append(library)
            }
        }

        let isVapor = injectionQueue != .main
        watcher = FileWatcher(roots: dirs, callback: { filesChanged in
            for file in filesChanged {
                self.inject(source: file)
            }
        }, runLoop: isVapor ? CFRunLoopGetCurrent() : nil)
        Self.log(APP_NAME+": Watching for source changes under \(home)/...")
        if isVapor {
            CFRunLoopRun()
        }
    }

    func inject(source: String) {
        let usingCached = recompiler.longTermCache[source] != nil
        if let dylib = recompiler.recompile(source: source),
           loadAndPatchIn(dylib: dylib) {
        } else if usingCached {
            recompiler.longTermCache.removeObject(forKey: source)
            recompiler.writeToCache()
            inject(source: source)
        }
    }
    
    open func loadAndPatchIn(dylib: String) -> Bool {
        guard notXCTest(in: dylib) || loadXCTest,
              let image = DLKit.load(dylib: dylib) else { return false }
        
        let (classes, generics) = reloader.patchClasses(in: image)
        if classes.count != 0 {
            Self.log("Ignore messages about duplicate classes ⬆️")
        }
        
        let rebound = reloader.interposeSymbols(in: image)
        if classes.count == 0 && rebound.count == 0 &&
            image.entries(withPrefix: "_OBJC_$_CATEGORY_").count == 0 {
            Self.log("ℹ️ No symbols replaced, have you added -Xlinker -interposable to your project's \"Other Linker Flags\"?")
        }
        
        DispatchQueue.main.async {
            self.reloader.performSweep(oldClasses: classes, generics, image: image)
            NotificationCenter.default.post(name: self.notification, object: classes)
            let symbols = Set(rebound.map { String(cString: $0) })
            Self.log("Loaded and rebound \(symbols.count) symbols \(classes)")
            
            if let XCTestCase = objc_getClass("XCTestCase") as? AnyClass {
                for test in classes where self.isSubclass(test, of: XCTestCase) {
                    print("\n\(APP_PREFIX)Running test \(test)")
                    NSObject.runXCTestCase(test)
                }
            }
        }
        
        return true
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

    func notXCTest(in dylib:String) -> Bool {
        if let object = NSData(contentsOfFile: dylib),
           memmem(object.bytes, object.count, "XCTest", 6) != nil,
           object.count != 0 { return false }
        return true
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
#endif
