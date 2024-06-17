//
//  Recompiler.swift
//  Copyright © 2023 John Holdsworth. All rights reserved.
//
//  Run compilation command returned by the log parser
//  to recompile a Swift source into a new object file
//  which is then linked into a dynamic library that
//  can be loaded. As Xcode is more agressive in
//  cleaning up build logs of late a long term
//  cache of build commands is kept in /tmp.
//
//  Created by John Holdsworth on 25/02/2023.
//

#if DEBUG
import InjectionImplC
import InjectionImpl
import Foundation
import PopenD

public struct Recompiler {

    /// A cache is kept of compiltaion commands in /tmp as Xcode housekeeps logs.
    lazy var longTermCache = NSMutableDictionary(contentsOfFile: Reloader.cacheFile) ??
        NSMutableDictionary()

    let parser = LogParser()
    let tmpdir = NSTemporaryDirectory()
    var tmpbase: String {
        return tmpdir+"eval\(Reloader.injectionNumber)"
    }

    /// Recompile a source to produce a dynamic library that can be loaded
    mutating func recompile(source: String) -> String? {
        guard let command = longTermCache[source] as? String ??
                parser.command(for: source) else {
            log("""
                ⚠️ Could not locate command for \(source). \
                Try editing a file and rebuilding your project. \
                \(APP_NAME) is not compatible with \"Whole Module\" \
                Compilation Mode.
                """)
            return nil
        }

        log("Recompiling \(source)")

        Reloader.injectionNumber += 1
        let objectFile = tmpbase+".o"
        try? FileManager.default.removeItem(atPath: objectFile)
        if let errors = Popen.system(command+" -o \(objectFile)", errors: true) {
            detail("Processed: "+command+" -o \(objectFile)")
            print(errors)
            log("⚠️ Recompilation failed")
            return nil
        }

        if longTermCache[source] as? String != command {
            longTermCache[source] = command
            writeToCache()
        }
        guard let dylib = link(objectFile: objectFile, command) else {
            return nil
        }
        #if os(tvOS)
        let codesign = """
            (export CODESIGN_ALLOCATE=\"\(Reloader.xcodeDev
             )/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate\"; \
            if /usr/bin/file \"\(dylib)\" | /usr/bin/grep ' shared library ' >/dev/null; \
            then /usr/bin/codesign --force -s - \"\(dylib)\";\
            else exit 1; fi)
            """
        if let error = Popen.system(codesign, errors: true) {
            print(error)
            log("⚠️ Codesign failed \(codesign)")
        }
        #endif
        return dylib
    }

    public mutating func writeToCache() {
        longTermCache.write(toFile: Reloader.cacheFile,
                            atomically: true)
    }

    /// Regex for path argument, perhaps containg escaped spaces
    static let argumentRegex = #"[^\s\\]*(?:\\.[^\s\\]*)*"#
    /// Regex to extract filename base, perhaps containg escaped spaces
    static let fileNameRegex = #"/(\#(argumentRegex))\.\w+"#
    static let parsePlatform = try! NSRegularExpression(pattern:
        #"-(?:isysroot|sdk)(?: |"\n")((\#(fileNameRegex)/Contents/Developer)/Platforms/(\w+)\.platform\#(fileNameRegex)\#\.sdk)"#)


    func evalError(_ str: String) -> Int {
        log("⚠️ "+str)
        return 0
    }

    #if arch(arm64)
    public var arch = "arm64"
    #elseif arch(arm)
    public var arch = "armv7"
    #elseif arch(x86_64)
    public var arch = "x86_64"
    #endif

    /// Create a dyanmic library from an object file
    mutating func link(objectFile: String, _ compileCommand: String) -> String? {
        var sdk = "\(Reloader.xcodeDev)/Platforms/\(Reloader.platform).platform/Developer/SDKs/\(Reloader.platform).sdk"
        if let match = Self.parsePlatform.firstMatch(in: compileCommand,
            options: [], range: NSMakeRange(0, compileCommand.utf16.count)) {
            func extract(group: Int, into: inout String) {
                if let range = Range(match.range(at: group), in: compileCommand) {
                    into = compileCommand[range]
                        .replacingOccurrences(of: #"\\(.)"#, with: "$1",
                                              options: .regularExpression)
                }
            }
            extract(group: 1, into: &sdk)
            extract(group: 2, into: &Reloader.xcodeDev)
            extract(group: 4, into: &Reloader.platform)
        } else if compileCommand.contains(" -o ") {
            _ = evalError("Unable to parse SDK from: \(compileCommand)")
        }

        var osSpecific = ""
        switch Reloader.platform {
        case "iPhoneSimulator":
            osSpecific = "-mios-simulator-version-min=9.0"
        case "iPhoneOS":
            osSpecific = "-miphoneos-version-min=9.0"
        case "AppleTVSimulator":
            osSpecific = "-mtvos-simulator-version-min=9.0"
        case "AppleTVOS":
            osSpecific = "-mtvos-version-min=9.0"
        case "MacOSX":
            let target = compileCommand
                .replacingOccurrences(of: #"^.*( -target \S+).*$"#,
                                      with: "$1", options: .regularExpression)
            osSpecific = "-mmacosx-version-min=10.11"+target
        case "XRSimulator": fallthrough case "XROS":
            osSpecific = ""
        default:
            _ = evalError("Invalid platform \(Reloader.platform)")
            // -Xlinker -bundle_loader -Xlinker \"\(Bundle.main.executablePath!)\""
        }

        let dylib = tmpbase+".dylib"
        let toolchain = Reloader.xcodeDev+"/Toolchains/XcodeDefault.xctoolchain"
        let frameworks = Bundle.main.privateFrameworksPath ?? "/tmp"
        let linkCommand = """
            "\(toolchain)/usr/bin/clang" -arch "\(arch)" \
                -Xlinker -dylib -isysroot "__PLATFORM__" \
                -L"\(toolchain)/usr/lib/swift/\(Reloader.platform.lowercased())" \(osSpecific) \
                -undefined dynamic_lookup -dead_strip -Xlinker -objc_abi_version \
                -Xlinker 2 -Xlinker -interposable -fobjc-arc \
                -fprofile-instr-generate \(objectFile) -L "\(frameworks)" -F "\(frameworks)" \
                -rpath "\(frameworks)" -o \"\(dylib)\"
            """.replacingOccurrences(of: "__PLATFORM__", with: sdk)

        if let errors = Popen.system(linkCommand, errors: true) {
            print(errors)
            log("⚠️ Linking failed")
            return nil
        }

        return dylib
    }
}
#endif
