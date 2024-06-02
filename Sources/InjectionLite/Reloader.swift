//
//  Reloader.swift
//
//  Perform all the magic of patching, swizzling
//  and interposing to bind new implementations
//  of function bodies into the running app.
//  Interposing requires the "Other Linker Flags"
//  -Xlinker -interposable for all binaries.
//
//  Created by John Holdsworth on 25/02/2023.
//
#if DEBUG
import Foundation
import DLKitD

public func autoBitCast<IN,OUT>(_ x: IN) -> OUT {
    return unsafeBitCast(x, to: OUT.self)
}

struct Reloader {

    /// The vtable of classes needs to be patched for overridable methods
    func patchClasses(in image: ImageSymbols)
        -> (classes: [AnyClass], generics: Set<String>) {
        var injectedGenerics = Set<String>()
        var oldClasses = [AnyClass]()

        for entry in image.swiftSymbols(withSuffixes: ["CMa"]) {
            if let genericClassName = entry.name.demangled?
                    .components(separatedBy: " ").last,
               !genericClassName.hasPrefix("__C.") {
                injectedGenerics.insert(genericClassName)
            }
        }

        for aClass in Set((image.swiftSymbols(withSuffixes: ["CN"]) +
                           image.entries(withPrefix: "OBJC_CLASS_$_"))
                    .compactMap { $0.value }) {
            let newClass: AnyClass = autoBitCast(aClass)
            injectedGenerics.remove(_typeName(newClass))
            for oldClass in versions(of: newClass) {
                patchSwift(oldClass: oldClass, from: newClass, in: image)
                if inheritedGeneric(anyType: oldClass) {
                    swizzleBasics(oldClass: oldClass, in: image)
                } else {
                    swizzle(oldClass: object_getClass(oldClass),
                            from: object_getClass(newClass))
                    swizzle(oldClass: oldClass, from: newClass)
                }
                oldClasses.append(oldClass)
            }
        }
        return (oldClasses, injectedGenerics)
    }

    /// Does the type derive from a generic (crashes some Objective-C apis)
    func inheritedGeneric(anyType: Any.Type) -> Bool {
        var inheritedGeneric: AnyClass? = anyType as? AnyClass
        if class_getSuperclass(inheritedGeneric) == nil {
            return true
        }
        while let parent = inheritedGeneric {
            if _typeName(parent).hasSuffix(">") {
                return true
            }
            inheritedGeneric = class_getSuperclass(parent)
        }
        return false
    }

    /// Scan class list for previous versions of a class
    func versions(of aClass: AnyClass) -> [AnyClass] {
        var out = [AnyClass](), nc: UInt32 = 0
        if let classes = UnsafePointer(objc_copyClassList(&nc)) {
            let named = _typeName(aClass)
            for i in 0 ..< Int(nc) {
                if class_getSuperclass(classes[i]) != nil && classes[i] != aClass,
                   _typeName(classes[i]) == named {
                    out.append(classes[i])
                }
            }
            free(UnsafeMutableRawPointer(mutating: classes))
        }
        return out
    }

    /// Extract pointers to class vtables in class meta-data
    func iterate(oldClass: AnyClass, newClass: AnyClass,
                 patcher: (_ slots: Int,
                           _ oldSlots: UnsafeMutablePointer<SIMP?>,
                           _ newSlots: UnsafeMutablePointer<SIMP?>) -> Void) {
        let existingClass = unsafeBitCast(oldClass, to:
            UnsafeMutablePointer<TargetClassMetadata>.self)
        let classMetadata = unsafeBitCast(newClass, to:
            UnsafeMutablePointer<TargetClassMetadata>.self)

        // Is this a Swift class?
        // Reference: https://github.com/apple/swift/blob/master/include/swift/ABI/Metadata.h#L1195
        let oldSwiftCondition = classMetadata.pointee.Data & 0x1 == 1
        let newSwiftCondition = classMetadata.pointee.Data & 0x3 != 0

        guard newSwiftCondition || oldSwiftCondition else { return }

        if classMetadata.pointee.ClassAddressPoint !=
            existingClass.pointee.ClassAddressPoint {
            log("""
                ⚠️ Mixing Xcode versions across injection. This may work \
                but "Clean Build Folder" when switching Xcode versions. \
                To clear the cache: rm \(Recompiler.cacheFile)
                """)
        } else if classMetadata.pointee.ClassSize !=
                    existingClass.pointee.ClassSize {
            log("""
                ⚠️ Adding or [re]moving methods of non-final classes is not supported. \
                Your application will likely crash. Paradoxically, you can avoid this by \
                making the class you are trying to inject (and add methods to) "final". ⚠️
                """)
        }

        let slots = (Int(existingClass.pointee.ClassSize -
                existingClass.pointee.ClassAddressPoint) -
            MemoryLayout<TargetClassMetadata>.size) /
            MemoryLayout<SIMP>.size

        patcher(slots, &existingClass.pointee.IVarDestroyer,
                       &classMetadata.pointee.IVarDestroyer)
    }

    /// Patch "injectable" members in class vtable
    public func patchSwift(oldClass: AnyClass, from newClass: AnyClass,
                           in lastLoaded: ImageSymbols) {
        iterate(oldClass: oldClass, newClass: newClass) {
                (slots, oldSlots, newSlots) in
                for slot in 1..<1+slots {
                    guard let impl = newSlots[slot] else { continue }
                    let lastInfo = lastLoaded[impl]
                    if let info = lastInfo ?? DLKit.allImages[impl],
                       let name = info.name,
                       Self.injectableSymbol(name) {
                        if lastInfo == nil, let injectedSuper =
                            Self.interposed[String(cString: name)] {
                            newSlots[slot] = injectedSuper
                        }
                        let symbol = name.demangled ??
                                 String(cString: name)
                        if symbol.contains(".getter : ") &&
                            symbol.hasSuffix(">") &&
                            !symbol.contains(".Optional<__C.") { continue }
                        if oldSlots[slot] != newSlots[slot] {
                            oldSlots[slot] = newSlots[slot]
                            detail("Patched \(impl) \(symbol)")
                        }
                    }
                }
        }
    }

    /// Old-school swizzling for Objective-C methods
    func swizzle(oldClass: AnyClass?,
                 from newClass: AnyClass?) {
        var methodCount: UInt32 = 0, swizzled = 0
        if let methods = class_copyMethodList(newClass, &methodCount) {
            for i in 0 ..< Int(methodCount) {
                let selector = method_getName(methods[i])
                let replacement = method_getImplementation(methods[i])
                guard let method = class_getInstanceMethod(oldClass, selector) ??
                                    class_getInstanceMethod(newClass, selector),
                      let _ = i < 0 ? nil : method_getImplementation(method) else {
                    continue
                }

                if class_replaceMethod(oldClass, selector, replacement,
                    method_getTypeEncoding(methods[i])) != replacement {
                    swizzled += 1
                }
            }
            free(methods)
        }
    }

    /// Swizzle an individual method (for types inheriting from generics)
    func swizzle(oldClass: AnyClass, selector: Selector,
                 in image: ImageSymbols) -> Int {
        if let method = class_getInstanceMethod(oldClass, selector) {
           let existing = method_getImplementation(method)
           if let symname = DLKit.appImages[unsafeBitCast(existing,
                           to: UnsafeMutableRawPointer.self)]?.name,
              let replacement = unsafeBitCast(image[symname] ?? [
                image, DLKit.mainImage, DLKit.appImages].compactMap({
                    $0.entry(named: symname)?.value }).first, to: IMP?.self),
              replacement != class_replaceMethod(oldClass, selector,
                     replacement, method_getTypeEncoding(method)) {
               detail("Swizzled "+(symname.demangled ??
                                   String(cString: symname)))
               return 1
           } else {
               detail("⚠️ Swizzle failed -[\(oldClass) \(selector)]")
           }
        }
        return 0
    }

    static var interposed = [String: UnsafeMutableRawPointer]()

    /// Rebind "injectable" symbols in the app to the new implementations just loaded
    mutating func interposeSymbols(in image: ImageSymbols) -> [DLKit.SymbolName] {
        var names = [DLKit.SymbolName]()
        var impls = [UnsafeMutableRawPointer]()
        for entry in image {
            guard let value = entry.value,
                  Self.injectableSymbol(entry.name) else { continue }
            let symbol = String(cString: entry.name)
            detail("Interposing \(value) "+(entry.name.demangled ?? symbol))
            names.append(entry.name)
            impls.append(value)
            Self.interposed[symbol] = value
        }

        // apply interposes using "fishhook"
        let rebound = DLKit.appImages.rebind(names: names, values: impls)

        // Apply previous interposes
        // to the newly loaded image
        _ = image.rebind(symbols: Array(Self.interposed.keys),
                         values: Array(Self.interposed.values))
        return rebound
    }

    public static var preserveStatics = false

    /// Determine if symbol name is injectable
    /// - Parameter symname: Pointer to symbol name
    /// - Returns: Whether symbol should be patched/interposed
    public static var injectableSymbol: // STSymbolFilter
        (UnsafePointer<CChar>) -> Bool = { symname in
//        print("Injectable?", String(cString: symname))
        let symstart = symname +
            (symname.pointee == UInt8(ascii: "_") ? 1 : 0)
        let isCPlusPlus = strncmp(symstart, "_ZN", 3) == 0
        if isCPlusPlus { return true }
        let isSwift = strncmp(symstart, "$s", 2) == 0 &&
                     symstart[2] != UInt8(ascii: "S") &&
                     symstart[2] != UInt8(ascii: "s")
        if !isSwift { return false }
        var symlast = symname+strlen(symname)-1

        func match(ascii: UnicodeScalar, inc: Int = -1) -> Bool {
            if symlast.pointee == UInt8(ascii: ascii) {
                symlast = symlast.advanced(by: inc)
                return true
            }
            return false
        }

        return
            match(ascii: "C") ||
            match(ascii: "D") && match(ascii: "f") ||
            // static/class methods, getters, setters
            (match(ascii: "Z") || true) &&
                (match(ascii: "F") && !match(ascii: "M") ||
                 match(ascii: "g") || match(ascii: "s")) ||
            // async [class] functions
            match(ascii: "u") && ( match(ascii: "T") &&
                (match(ascii: "Z") || true) && match(ascii: "F") ||
                // "Mutable Addressors"
                !preserveStatics &&
                match(ascii: "a") && match(ascii: "v")) ||
            match(ascii: "M") && match(ascii: "v")
    }
}
#endif
