//
//  Sweeper.swift
//
//  This is how the instance level @objc func injected()
//  method is called. Performs a "sweep" of all live
//  objects in the app to find instances of classes
//  that have been injected to message.
//
//  Created by John Holdsworth on 25/02/2023.
//

import Foundation
import DLKit

#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

@objc public protocol SwiftInjected {
    @objc optional func injected()
}

extension Reloader {
    static let injectedSEL = #selector(SwiftInjected.injected)
    static var sweepWarned = false

    func performSweep(oldClasses: [AnyClass],
                      _ injectedGenerics: Set<String>, image: ImageSymbols) {
        typealias ClassIMP = @convention(c) (AnyClass, Selector) -> ()
        for cls in oldClasses {
            if let classMethod = class_getClassMethod(cls, Self.injectedSEL) {
                let classIMP = method_getImplementation(classMethod)
                unsafeBitCast(classIMP, to: ClassIMP.self)(cls, Self.injectedSEL)
            }
        }
        var injectedClasses = [AnyClass]()
        for cls in oldClasses {
            if class_getInstanceMethod(cls, Self.injectedSEL) != nil {
                injectedClasses.append(cls)
                if !Self.sweepWarned {
                    log("""
                        As class \(cls) has an @objc injected() \
                        method, \(APP_NAME) will perform a "sweep" of live \
                        instances to determine which objects to message. \
                        If this fails, subscribe to the notification \
                        "INJECTION_BUNDLE_NOTIFICATION" instead.
                        \(APP_PREFIX)(note: notification may not arrive on the main thread)
                        """)
                    Self.sweepWarned = true
                }
                let kvoName = "NSKVONotifying_" + NSStringFromClass(cls)
                if let kvoCls = NSClassFromString(kvoName) {
                    injectedClasses.append(kvoCls)
                }
            }
        }

        // implement -injected() method using sweep of objects in application
        if !injectedClasses.isEmpty || !injectedGenerics.isEmpty {
            log("Starting sweep \(injectedClasses), \(injectedGenerics)...")
            var patched = Set<UnsafeRawPointer>()
            SwiftSweeper(instanceTask: {
                (instance: AnyObject) in
                if let instanceClass = object_getClass(instance),
                   injectedClasses.contains(where: { $0 === instanceClass }) ||
                    !injectedGenerics.isEmpty &&
                    self.patchGenerics(oldClass: instanceClass, image: image,
                        injectedGenerics: injectedGenerics, patched: &patched) {
                    let proto = unsafeBitCast(instance, to: SwiftInjected.self)
//                    if SwiftEval.sharedInstance().vaccineEnabled {
//                        performVaccineInjection(instance)
//                        proto.injected?()
//                        return
//                    }

                    proto.injected?()

//                    #if os(iOS) || os(tvOS)
//                    if let vc = instance as? UIViewController {
//                        flash(vc: vc)
//                    }
//                    #endif
                }
            }).sweepValue(SwiftSweeper.seeds)
        }
    }

    func patchGenerics(oldClass: AnyClass, image: ImageSymbols,
                       injectedGenerics: Set<String>,
                       patched: inout Set<UnsafeRawPointer>) -> Bool {
        let typeName = _typeName(oldClass)
        if let genericClassName = typeName.components(separatedBy: "<").first,
           genericClassName != typeName,
           injectedGenerics.contains(genericClassName) {
            if patched.insert(autoBitCast(oldClass)).inserted {
                let patched = newPatchSwift(oldClass: oldClass, in: image)
                let swizzled = swizzleBasics(oldClass: oldClass, in: image)
                log("Injected generic '\(oldClass)' (\(patched),\(swizzled))")
            }
            return oldClass.instancesRespond(to: Self.injectedSEL)
        }
        return false
    }

    func newPatchSwift(oldClass: AnyClass, in lastLoaded: ImageSymbols) -> Int {
        var patched = 0

        iterate(oldClass: oldClass, newClass: oldClass) {
            (slots, oldSlots, _) in
            for slotIndex in 1...slots {
                guard let existing = oldSlots[slotIndex],
                      let symname = lastLoaded[existing]?.name ??
                        DLKit.allImages[existing]?.name,
                      Self.injectableSymbol(symname) else { continue }
                let symbol = String(cString: symname)
                let demangled = symname.demangled ?? symbol

                guard let replacement = lastLoaded[symname] ??
                        interposed[symbol] ?? DLKit.allImages[symname] else {
                    log("⚠️ Class patching failed to lookup \(demangled)")
                    continue
                }
                if replacement != existing {
                    oldSlots[slotIndex] = replacement
                    detail("Patched \(replacement) \(demangled)")
                    patched += 1
                }
            }
        }

        return patched
    }

    @discardableResult
    func swizzleBasics(oldClass: AnyClass, in image: ImageSymbols) -> Int {
        var swizzled = swizzle(oldClass: oldClass,
                               selector: Self.injectedSEL, in: image)
        #if os(iOS) || os(tvOS)
        swizzled += swizzle(oldClass: oldClass, selector:
            #selector(UIViewController.viewDidLoad), in: image)
        #endif
        return swizzled
    }
}

class SwiftSweeper {

    #if os(iOS) || os(tvOS)
    static let app = UIApplication.shared
    #else
    static let app = NSApplication.shared
    #endif
    static var seeds: [Any] = [app.delegate as Any] + app.windows
    static var current: SwiftSweeper?

    let instanceTask: (AnyObject) -> Void
    var seen = [UnsafeRawPointer: Bool]()
    let debugSweep = getenv("INJECTION_SWEEP_DETAIL") != nil
    let sweepExclusions = { () -> NSRegularExpression? in
        if let exclusions = getenv("INJECTION_SWEEP_EXCLUDE") {
            let pattern = String(cString: exclusions)
            do {
                let filter = try NSRegularExpression(pattern: pattern, options: [])
                log("⚠️ Excluding types matching '\(pattern)' from sweep")
                return filter
            } catch {
                log("⚠️ Invalid sweep filter pattern \(error): \(pattern)")
            }
        }
        return nil
    }()

    init(instanceTask: @escaping (AnyObject) -> Void) {
        self.instanceTask = instanceTask
        SwiftSweeper.current = self
    }

    func sweepValue(_ value: Any, _ containsType: Bool = false) {
        /// Skip values that cannot be cast into `AnyObject` because they end up being `nil`
        /// Fixes a potential crash that the value is not accessible during injection.
//        print(value)
        guard !containsType && value as? AnyObject != nil else { return }

        let mirror = Mirror(reflecting: value)
        if var style = mirror.displayStyle {
            if _typeName(mirror.subjectType).hasPrefix("Swift.ImplicitlyUnwrappedOptional<") {
                style = .optional
            }
            switch style {
            case .set, .collection:
                let containsType = _typeName(type(of: value)).contains(".Type")
                if debugSweep {
                    print("Sweeping collection:", _typeName(type(of: value)))
                }
                for (_, child) in mirror.children {
                    sweepValue(child, containsType)
                }
                return
            case .dictionary:
                for (_, child) in mirror.children {
                    for (_, element) in Mirror(reflecting: child).children {
                        sweepValue(element)
                    }
                }
                return
            case .class:
                sweepInstance(value as AnyObject)
                return
            case .optional, .enum:
                if let evals = mirror.children.first?.value {
                    sweepValue(evals)
                }
            case .tuple, .struct:
                sweepMembers(value)
            @unknown default:
                break
            }
        }
    }

    func sweepInstance(_ instance: AnyObject) {
        let reference = unsafeBitCast(instance, to: UnsafeRawPointer.self)
        if seen[reference] == nil {
            seen[reference] = true
            if let filter = sweepExclusions {
                let typeName = _typeName(type(of: instance))
                if filter.firstMatch(in: typeName,
                    range: NSMakeRange(0, typeName.utf16.count)) != nil {
                    return
                }
            }

            if debugSweep {
                print("Sweeping instance \(reference) of class \(type(of: instance))")
            }

            sweepMembers(instance)
            instance.legacySwiftSweep?()

            instanceTask(instance)
        }
    }

    func sweepMembers(_ instance: Any) {
        var mirror: Mirror? = Mirror(reflecting: instance)
        while mirror != nil {
            for (name, value) in mirror!.children
                where name?.hasSuffix("Type") != true {
                sweepValue(value)
            }
            mirror = mirror!.superclassMirror
        }
    }
}

extension NSObject {
    @objc func legacySwiftSweep() {
        var icnt: UInt32 = 0, cls: AnyClass? = object_getClass(self)
        while cls != nil && cls != NSObject.self && cls != NSURL.self {
            let className = NSStringFromClass(cls!)
            if className.hasPrefix("_") || className.hasPrefix("WK") ||
                className.hasPrefix("NS") && className != "NSWindow" {
                return
            }
            if let ivars = class_copyIvarList(cls, &icnt) {
                let object = UInt8(ascii: "@")
                for i in 0 ..< Int(icnt) {
                    if /*let name = ivar_getName(ivars[i])
                        .flatMap({ String(cString: $0)}),
                       sweepExclusions?.firstMatch(in: name,
                           range: NSMakeRange(0, name.utf16.count)) == nil,*/
                       let type = ivar_getTypeEncoding(ivars[i]), type[0] == object {
                        (unsafeBitCast(self, to: UnsafePointer<Int8>.self) + ivar_getOffset(ivars[i]))
                            .withMemoryRebound(to: AnyObject?.self, capacity: 1) {
//                                print("\($0.pointee) \(self) \(name):  \(String(cString: type))")
                                if let obj = $0.pointee {
                                    SwiftSweeper.current?.sweepInstance(obj)
                                }
                        }
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(cls)
        }
    }
}

extension NSSet {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSArray {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSDictionary {
    @objc override func legacySwiftSweep() {
        self.allValues.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}
