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

import Foundation
import DLKit

class Reloader {

    func rebind(image: ImageSymbols) -> [AnyClass] {
        let oldClasses = patchClasses(in: image)
        interposeSymbols(in: image)
        return oldClasses
    }

    func patchClasses(in image: ImageSymbols) -> [AnyClass] {
        var oldClasses = [AnyClass]()
        for info in image.swiftSymbols(withSuffixes: ["CN"]) {
            let newClass: AnyClass =
                unsafeBitCast(info.value, to: AnyClass.self)
            if let oldClass = objc_getClass(
                class_getName(newClass)) as? AnyClass {
                patch(oldClass: oldClass, from: newClass, in: image)
                if !inheritedGeneric(anyType: oldClass) {
                    swizzle(oldClass: object_getClass(oldClass),
                            from: object_getClass(newClass))
                    swizzle(oldClass: oldClass, from: newClass)
                }
                oldClasses.append(oldClass)
            }
        }
        if oldClasses.count != 0 {
            log("Ignore messages about duplicate classes ⬆️")
        }
        return oldClasses
    }

    func inheritedGeneric(anyType: Any.Type) -> Bool {
        var inheritedGeneric: Any.Type? = anyType
        while let parent = inheritedGeneric {
            if _typeName(parent).hasSuffix(">") {
                return true
            }
            inheritedGeneric = (parent as? AnyClass)?.superclass()
        }
        return false
    }

    /** pointer to a function implementing a Swift method */
    public typealias SIMP = @convention(c) () -> Void

    /**
     Layout of a class instance. Needs to be kept in sync with ~swift/include/swift/Runtime/Metadata.h
     */
    public struct TargetClassMetadata {

        let MetaClass: uintptr_t = 0, SuperClass: uintptr_t = 0
        let CacheData1: uintptr_t = 0, CacheData2: uintptr_t = 0

        public let Data: uintptr_t = 0

        /// Swift-specific class flags.
        public let Flags: UInt32 = 0

        /// The address point of instances of this type.
        public let InstanceAddressPoint: UInt32 = 0

        /// The required size of instances of this type.
        /// 'InstanceAddressPoint' bytes go before the address point;
        /// 'InstanceSize - InstanceAddressPoint' bytes go after it.
        public let InstanceSize: UInt32 = 0

        /// The alignment mask of the address point of instances of this type.
        public let InstanceAlignMask: UInt16 = 0

        /// Reserved for runtime use.
        public let Reserved: UInt16 = 0

        /// The total size of the class object, including prefix and suffix
        /// extents.
        public let ClassSize: UInt32 = 0

        /// The offset of the address point within the class object.
        public let ClassAddressPoint: UInt32 = 0

        /// An out-of-line Swift-specific description of the type, or null
        /// if this is an artificial subclass.  We currently provide no
        /// supported mechanism for making a non-artificial subclass
        /// dynamically.
        public let Description: uintptr_t = 0

        /// A function for destroying instance variables, used to clean up
        /// after an early return from a constructor.
        public var IVarDestroyer: SIMP? = nil

        // After this come the class members, laid out as follows:
        //   - class members for the superclass (recursively)
        //   - metadata reference for the parent, if applicable
        //   - generic parameters for this class
        //   - class variables (if we choose to support these)
        //   - "tabulated" virtual methods

    }

    public func patch(oldClass: AnyClass, from newClass: AnyClass,
                      in lastImage: ImageSymbols) {
        let existingClass = unsafeBitCast(oldClass, to:
            UnsafeMutablePointer<TargetClassMetadata>.self)
        let classMetadata = unsafeBitCast(newClass, to:
            UnsafeMutablePointer<TargetClassMetadata>.self)

        // Is this a Swift class?
        // Reference: https://github.com/apple/swift/blob/master/include/swift/ABI/Metadata.h#L1195
        let oldSwiftCondition = classMetadata.pointee.Data & 0x1 == 1
        let newSwiftCondition = classMetadata.pointee.Data & 0x3 != 0

        guard newSwiftCondition || oldSwiftCondition else { return }

        let slots = (Int(existingClass.pointee.ClassSize -
                existingClass.pointee.ClassAddressPoint) -
            MemoryLayout<TargetClassMetadata>.size) /
            MemoryLayout<SIMP>.size
        withUnsafeMutablePointer(
            to: &existingClass.pointee.IVarDestroyer) { to in
                withUnsafeMutablePointer(
                to: &classMetadata.pointee.IVarDestroyer) { from in
                for slot in 1...slots {
                    let impl = unsafeBitCast(from[slot],
                        to: UnsafeMutableRawPointer.self)
                    let lastInfo = lastImage[impl]
                    if let info = lastInfo ?? DLKit.allImages[impl],
                       Self.injectableSymbol(info.name) {
                        if lastInfo == nil, let injectedSuper =
                            interposed[String(cString: info.name)] ?? nil {
                            from[slot] = unsafeBitCast(injectedSuper,
                                                       to: SIMP.self)
                        }
                        to[slot] = from[slot]
                        let symbol = info.name.demangled ??
                            String(cString: info.name)
                        detail("Patched \(impl) \(symbol)")
                    }
                }
            }
        }
    }

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

    var interposed = [String: UnsafeMutableRawPointer?]()

    func interposeSymbols(in image: ImageSymbols) {
        var names = [DLKit.SymbolName]()
        var impls = [UnsafeMutableRawPointer]()
        for entry in image.definitions {
            guard let value = entry.value,
                  Self.injectableSymbol(entry.name) else { continue }
            let symbol = String(cString: entry.name)
            detail("Interposing \(value) "+(entry.name.demangled ?? symbol))
            names.append(entry.name)
            impls.append(value)
            interposed[symbol] = value
        }

        // apply interposes using "fishhook"
        DLKit.appImages[names] = impls

        // Apply previous interposes
        // to the newly loaded image
        let save = DLKit.logger
        DLKit.logger = { _ in }
        image[Array(interposed.keys)] = Array(interposed.values)
        DLKit.logger = save
    }

    public static var preserveStatics = false

    /// Determine if symbol name is injectable
    /// - Parameter symname: Pointer to symbol name
    /// - Returns: Whether symbol should be patched
    public static var injectableSymbol: // STSymbolFilter
        (UnsafePointer<CChar>) -> Bool = { symname in
//        print("Injectable?", String(cString: symname))
        let symstart = symname +
            (symname.pointee == UInt8(ascii: "_") ? 1 : 0)
        let isCPlusPlus = strncmp(symstart, "_ZN", 3) == 0
        if isCPlusPlus { return true }
        let isSwift = strncmp(symstart, "$s", 2) == 0
        if !isSwift { return false }
        var symlast = symname+strlen(symname)-1
        return
            symlast.match(ascii: "C") ||
            symlast.match(ascii: "D") && symlast.match(ascii: "f") ||
            // static/class methods, getters, setters
            (symlast.match(ascii: "Z") || true) &&
                (symlast.match(ascii: "F") ||
                 symlast.match(ascii: "g") ||
                 symlast.match(ascii: "s")) ||
            // async [class] functions
            symlast.match(ascii: "u") && (
                symlast.match(ascii: "T") &&
                (symlast.match(ascii: "Z") || true) &&
                symlast.match(ascii: "F") ||
                // "Mutable Addressors"
                !preserveStatics &&
                symlast.match(ascii: "a") &&
                symlast.match(ascii: "v")) ||
            symlast.match(ascii: "M") &&
            symlast.match(ascii: "v")
    }
}

extension UnsafePointer where Pointee == Int8 {
    @inline(__always)
    mutating func match(ascii: UnicodeScalar, inc: Int = -1) -> Bool {
        if pointee == UInt8(ascii: ascii) {
            self = self.advanced(by: inc)
            return true
        }
        return false
    }
}
