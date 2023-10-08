//
//  Recompiler.swift
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
import Foundation
import Popen

struct Recompiler {

    /// A cache is kept of compiltaion commands in /tmp as Xcode housekeeps logs.
    static let appName = Bundle.main.executableURL?.lastPathComponent ?? "unknown"
    #if os(macOS) || targetEnvironment(macCatalyst)
    static let sdk = "macOS"
    #elseif os(tvOS)
    static let sdk = "tvOS"
    #elseif targetEnvironment(simulator)
    static let sdk = "iOS"
    #else
    static let sdk = "maciOS"
    #endif
    static var cacheFile = "/tmp/\(appName)_\(sdk)_builds.plist"
    lazy var longTermCache = NSMutableDictionary(contentsOfFile: Self.cacheFile) ??
        NSMutableDictionary()

    let parser = LogParser()
    let tmpdir = NSTemporaryDirectory()
    var injectionNumber = 0
    var tmpbase: String {
        return tmpdir+"eval\(injectionNumber)"
    }

    /// Recompile a source to produce a dynamic library that can be loaded
    mutating func recompile(source: String) -> String? {
        guard let command = longTermCache[source] as? String ??
                parser.command(for: source) else {
            log("⚠️ Could not locate command for " + source +
                ". Injection is not compatible with \"Whole Module\" Compilation Mode. Edit a file and rebuild your project.")
            return nil
        }

        log("Recompiling \(source)")

        injectionNumber += 1
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
            (export CODESIGN_ALLOCATE=\"\(xcodeDev
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

    mutating func writeToCache() {
        longTermCache.write(toFile: Self.cacheFile,
                            atomically: true)
    }

    /// Regex for path argument, perhaps containg escaped spaces
    static let argumentRegex = #"[^\s\\]*(?:\\.[^\s\\]*)*"#
    /// Regex to extract filename base, perhaps containg escaped spaces
    static let fileNameRegex = #"/(\#(argumentRegex))\.\w+"#
    static let parsePlatform = try! NSRegularExpression(pattern:
        #"-(?:isysroot|sdk)(?: |"\n")((\#(fileNameRegex)/Contents/Developer)/Platforms/(\w+)\.platform\#(fileNameRegex)\#\.sdk)"#)

    var xcodeDev = "/Applications/Xcode.app/Contents/Developer"
    var platform = "iPhoneSimulator"

    func evalError(_ str: String) -> Int {
        log("⚠️ "+str)
        return 0
    }

    #if arch(arm64)
    public var arch = "arm64"
    #elseif arch(x86_64)
    public var arch = "x86_64"
    #endif

    /// Create a dyanmic library from an object file
    mutating func link(objectFile: String, _ compileCommand: String) -> String? {
        var sdk = "\(xcodeDev)/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk"
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
            extract(group: 2, into: &xcodeDev)
            extract(group: 4, into: &platform)
        } else if compileCommand.contains(" -o ") {
            _ = evalError("Unable to parse SDK from: \(compileCommand)")
        }

        var osSpecific = ""
        switch platform {
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
            _ = evalError("Invalid platform \(platform)")
            // -Xlinker -bundle_loader -Xlinker \"\(Bundle.main.executablePath!)\""
        }

        let dylib = tmpbase+".dylib"
        let toolchain = xcodeDev+"/Toolchains/XcodeDefault.xctoolchain"
        let frameworks = Bundle.main.privateFrameworksPath ?? "/tmp"
        let linkCommand = """
            "\(toolchain)/usr/bin/clang" -arch "\(arch)" \
                -Xlinker -dylib -isysroot "__PLATFORM__" \
                -L"\(toolchain)/usr/lib/swift/\(platform.lowercased())" \(osSpecific) \
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
