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
#if canImport(InjectionImpl)
@_exported import InjectionBazel
@_exported import InjectionImplC
@_exported import InjectionImpl
#endif
import Foundation

public struct Recompiler {

    /// A cache is kept of compiltaion commands in /tmp as Xcode housekeeps logs.
    lazy var longTermCache = NSMutableDictionary(contentsOfFile:
                    Reloader.cacheFile) ?? NSMutableDictionary()
    public var cacheKey: String?

    let tmpdir = NSTemporaryDirectory()
    var tmpbase: String {
        return tmpdir+"eval\(Reloader.injectionNumber)"
    }
    
    static var workspaceCache = [String: String]()
  
    func findParser(forProjectContaining source: String) -> LiteParser {
        #if os(macOS)
        let notBazel = "_NOTBAZEL_"
        // Check if this is a Bazel workspace
        if let workspaceRoot = Self.workspaceCache[source] ??
            BazelInterface.findWorkspaceRoot(containing: source),
            workspaceRoot != notBazel {
            Self.workspaceCache[source] = workspaceRoot
            do {
                return try BazelAQueryParser(workspaceRoot: workspaceRoot)
            } catch {
                log("⚠️ Failed to create BazelAQueryParser: \(error), falling back to LogParser")
            }
        }
        Self.workspaceCache[source] = notBazel
        #endif

        // Fallback to traditional Xcode log parsing
        return LogParser()
    }

    /// Recompile a source to produce a dynamic library that can be loaded
    mutating func recompile(source: String, platformFilter: String = "",
                            dylink: Bool) -> String? {
        let parser = findParser(forProjectContaining: source)
        var scanned: (logDir: String, scanner: Popen?)?
        let cacheKey = source+platformFilter
        self.cacheKey = cacheKey
        var cachedCommand = getenv("NO_CACHING") == nil ?
            longTermCache[cacheKey] as? String : nil
        if cachedCommand?.contains("llvmcas://") == true {
            log("⚠️ Injection is not compatable with build" +
                " setting COMPILATION_CACHE_ENABLE_CACHING")
            writeToCache(removing: cacheKey)
            cachedCommand = nil
        }
        guard var command = cachedCommand ??
                parser.command(for: source, platformFilter:
                                platformFilter, found: &scanned) else {
            log("""
                ⚠️ Could not locate command for \(source). \
                Try editing a file and rebuilding/reopening your project. \
                \(APP_NAME) is not compatible with \"Whole Module\" \
                Compilation Mode.
                """)
            return nil
        }

        let filelistRegex = #" -filelist (\#(Reloader.argumentRegex))"#
        if let filelistPath = (command[filelistRegex] as String?)?.unescape,
           !FileManager.default.fileExists(atPath: filelistPath) {
            if scanned == nil,
               let rescanned = parser.command(for: source, platformFilter:
                                              platformFilter, found: &scanned) {
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

        let fileName = URL(fileURLWithPath: source).lastPathComponent
        log("🔄 [\(fileName)] Recompiling\(platformFilter.isEmpty ? "" : " (\(platformFilter))")")

        Reloader.injectionNumber += 1
        var objectFile = tmpbase + ".o"
        unlink(objectFile)
        let benchmark = source.hasSuffix(".swift") ? Reloader.typeCheckLimit : ""
        var builtinSwitftCompile = 0
        withUnsafeMutablePointer(to: &builtinSwitftCompile) {
            command[LogParser.builtinSwiftCompile, count: $0] = ""
        }
        let finalCommand = builtinSwitftCompile != 0 ?
            command[#"-use-frontend-parseable-output "#, ""]+" -Xfrontend \(benchmark)" :
            parser.prepareFinalCommand(
            command: command,
            source: source,
            objectFile: objectFile,
            tmpdir: tmpdir,
            injectionNumber: Reloader.injectionNumber
        ) + " \(benchmark)"

        // Time the compilation step
        let compilationStartTime = Date.timeIntervalSinceReferenceDate
        while let errors = Popen.system(finalCommand, errors: nil) {
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

//            if !errors.contains(" error: ") { break }
            if !errors.contains("error: ") { break }
            writeToCache(removing: cacheKey)
            if cachedCommand != nil { // retry once
                return recompile(source: source, platformFilter:
                                    platformFilter, dylink: dylink)
            }
            log("Processing command: "+finalCommand+"\n")
            log("Current log: \(FileWatcher.derivedLog ?? "no log")")
            log("❌ Compilation failed:\n"+errors)
            return nil
        }

        // Log successful compilation with timing
        let compilationDuration = Date.timeIntervalSinceReferenceDate - compilationStartTime
        log(String(format: "⚡ Compiled in %.0fms", compilationDuration * 1000))

        if let frameworksArg: String = command[
            " -F (\(Reloader.argumentRegex)/PackageFrameworks) "] {
            Unhider.packageFrameworks = frameworksArg[#"\\(.)"#, "$1"]
            Reloader.unhider = Unhider.startUnhide
        }
        if longTermCache[cacheKey] as? String != command {
            longTermCache[cacheKey] = command
            if builtinSwitftCompile == 0 {
                writeToCache()
            }
        }

        if builtinSwitftCompile != 0 {
            log("""
                ℹ️ Falling back to "builtin" compilation of files. \
                This only works injecting files in the main package. \
                Injection is faster if you add a build setting to \
                your project: \(EMIT_FRONTEND_COMMAND_LINES)=YES \
                then restart the \(APP_NAME) app.
                """)
            var located = false, filename = URL(fileURLWithPath: source)
                .deletingPathExtension().lastPathComponent+".o"
            for base in FileWatcher.objectBases {
                let candidate = URL(fileURLWithPath: base)
                    .appendingPathComponent(filename).path
                if FileManager.default.fileExists(atPath: candidate) {
                    print(APP_PREFIX+"Located object file "+candidate)
                    objectFile = candidate[#"([ $()])"#, "\\\\$1"]
                    located = true
                    break
                }
            }
            if !located {
                log("⚠️ Valid object path not found. Modify a file and build." +
                    " Add a build setting \(EMIT_FRONTEND_COMMAND_LINES)=YES.")
                writeToCache(removing: source)
                return nil
            }
        }

        Reloader.extractLinkCommand(from: finalCommand)
        if !dylink {
            return objectFile
        }

        guard let dylib = link(objectFile: objectFile) else {
            log("❌ Linking failed")
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

    public mutating func writeToCache(removing: String? = nil) {
        if let removing = removing {
            longTermCache.removeObject(forKey: removing)
        }
        longTermCache.write(toFile: Reloader.cacheFile,
                            atomically: true)
    }

    func recoverFileList(for source: String, from logFile: String,
                         command: inout String, regex: String) throws {
        let scanner = Popen(cmd: "/usr/bin/gunzip <'\(logFile)' | /usr/bin/tr '\\r' '\\n'")
        let sourceName = URL(fileURLWithPath: source).lastPathComponent
        while let line = scanner?.readLine() {
            if let mapFile = (line[
                #" -output-file-map (\#(Reloader.argumentRegex))"#] as String?)?.unescape {
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

    /// Create a dyanmic library from an object file
    mutating func link(objectFile: String) -> String? {
        let dylib = tmpbase+".dylib"
        let linkCommand = Reloader.linkCommand + " \(objectFile) -o \"\(dylib)\""
        if let errors = Popen.system(linkCommand, errors: true) {
            log("⚠️ Linking failed:\n\(linkCommand)\nerrors:\n"+errors)
            return linkingFailed()
        }

        return dylib
    }
    
    mutating func linkingFailed<R>() -> R? {
        writeToCache(removing: cacheKey)
        return nil
    }
}
#endif
