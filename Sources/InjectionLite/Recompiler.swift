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

#if DEBUG || !SWIFT_PACKAGE
#if canImport(InjectionImplC)
import InjectionImplC
import InjectionImpl
#endif
import Foundation
#if canImport(PopenD)
import PopenD
#else
import Popen
#endif

extension String {
    var unescape: String {
        return self[#"\\(.)"#, "$1"]
    }
}

public struct Recompiler {

    /// A cache is kept of compiltaion commands in /tmp as Xcode housekeeps logs.
    lazy var longTermCache = NSMutableDictionary(contentsOfFile:
                    Reloader.cacheFile) ?? NSMutableDictionary()

    let parser = LogParser()
    let tmpdir = NSTemporaryDirectory()
    var tmpbase: String {
        return tmpdir+"eval\(Reloader.injectionNumber)"
    }

    /// Recompile a source to produce a dynamic library that can be loaded
    mutating func recompile(source: String, dylink: Bool) -> String? {
        var scanned: (logDir: String, scanner: Popen?)?
        guard var command = longTermCache[source] as? String ??
                parser.command(for: source, found: &scanned) else {
            log("""
                ⚠️ Could not locate command for \(source). \
                Try editing a file and rebuilding your project. \
                \(APP_NAME) is not compatible with \"Whole Module\" \
                Compilation Mode.
                """)
            return nil
        }

        let filelistRegex = #" -filelist (\#(Recompiler.argumentRegex))"#
        if let filelistPath = (command[filelistRegex] as String?)?.unescape,
           !FileManager.default.fileExists(atPath: filelistPath) {
            if scanned == nil,
               let rescanned = parser.command(for: source, found: &scanned) {
                command = rescanned
            }

            var buildLog = "NOLOG"
            while let log = scanned?.scanner?.readLine() {
                buildLog = log
            }

            if let logDir = scanned?.logDir {
                do {
                    try recoverFileList(for: source, from: logDir+"/"+buildLog,
                                        command: &command, regex: filelistRegex)
                } catch {
                    log("recoverFileList: \(error)")
                }
            }
        }

        log("LiteRecompiling \(source)")

        Reloader.injectionNumber += 1
        let objectFile = tmpbase + ".o"
        unlink(objectFile)
        let benchmark = source.hasSuffix(".swift") ? Reloader.typeCheckLimit : ""
        while let errors = Popen.system(command+" -o \(objectFile) " +
                                        benchmark, errors: nil) {
            for slow: String in errors[Reloader.typeCheckRegex] {
                log(slow)
            }

            if let (path, before, after): (String, String, String) = errors[
                #"PCH file '(([^']+?-Bridging-Header-swift_)\w+(-clang_\w+.pch))' not found:"#],
               let mostRecent = Popen(
                cmd: "/bin/ls -rt \(before)*\(after)")?.readLine() {
                log("ℹ️ Linking \(path) to \(mostRecent)")
                if symlink(mostRecent, path) == EXIT_SUCCESS {
                    continue
                }
                log("⚠️ Linking PCH failed " +
                    String(cString: strerror(errno)))
            }

            if !errors.contains(" error: ") { break }
            let wasCached = longTermCache[source] != nil
            longTermCache[source] = nil
            writeToCache()
            if wasCached {
                return recompile(source: source, dylink: dylink)
            }
            log("Processing command: "+command+" -o \(objectFile)\n")
            log("Current log: \(FileWatcher.derivedLog ?? "no log")")
            log("⚠️ Compiler output:\n"+errors)
            log("⚠️ Recompilation failed")
            return nil
        }

        if longTermCache[source] as? String != command {
            longTermCache[source] = command
            writeToCache()
        }
        if !dylink {
            return objectFile
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
        if let errors = Popen.system(codesign, errors: true) {
            log(errors, prefix: "")
            log("⚠️ Codesign failed \(codesign)")
        }
        #endif
        return dylib
    }

    public mutating func writeToCache() {
        longTermCache.write(toFile: Reloader.cacheFile,
                            atomically: true)
    }

    func recoverFileList(for source: String, from logFile: String,
                         command: inout String, regex: String) throws {
        let scanner = Popen(cmd: "/usr/bin/gunzip <'\(logFile)' | /usr/bin/tr '\\r' '\\n'")
        let sourceName = URL(fileURLWithPath: source).lastPathComponent
        while let line = scanner?.readLine() {
            if let mapFile = (line[
                #" -output-file-map (\#(Self.argumentRegex))"#] as String?)?.unescape {
               let data = try Data(contentsOf: URL(fileURLWithPath: mapFile))
                guard let map = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { continue }
                if map[source] == nil &&
                    map.keys.filter({ $0.hasSuffix(sourceName) }).isEmpty {
                    continue
                }
                let flielists = "/tmp/InjectionLite_filelists/"
                try? FileManager.default.createDirectory(atPath: flielists,
                                         withIntermediateDirectories: true)
                let tmpFilelist = flielists+sourceName
                try (map.keys.joined(separator: "\n")+"\n")
                    .write(toFile: tmpFilelist, atomically: false, encoding: .utf8)
                command[regex] = tmpFilelist[#"([\s\$])"#, #"\\\\$1"#]
                log("ℹ️ Recovered \(tmpFilelist) from \(mapFile)[\(map.keys.count)]")
                break
            }
        }
    }

    /// Regex for path argument, perhaps containg escaped spaces
    static let argumentRegex = #"[^\s\\]*(?:\\.[^\s\\]*)*"#
    /// Regex to extract filename base, perhaps containg escaped spaces
    static let fileNameRegex = #"/(\#(argumentRegex))\.\w+"#
    static let parsePlatform = try! NSRegularExpression(pattern:
        #"-(?:isysroot|sdk)(?: |"\n")((\#(fileNameRegex)/Contents/Developer)/Platforms/(\w+)\.platform\#(fileNameRegex)\#\.sdk)"#)

    #if arch(arm64)
    public var arch = "arm64"
    #elseif arch(arm)
    public var arch = "armv7"
    #elseif arch(x86_64)
    public var arch = "x86_64"
    #endif

    /// Create a dyanmic library from an object file
    mutating func link(objectFile: String, _ compileCommand: String) -> String? {
        // Default for Objective-C with Xcode 15.3+
        var sdk = "\(Reloader.xcodeDev)/Platforms/\(Reloader.platform).platform/Developer/SDKs/\(Reloader.platform).sdk"
        // Extract sdk, Xcode path and platform from compilation command
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
            log("⚠️ Unable to parse SDK from: \(compileCommand)")
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
            log("⚠️ Invalid platform \(Reloader.platform)")
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
            log(errors, prefix: "")
            log("⚠️ Linking failed")
            return nil
        }

        return dylib
    }
}
#endif
