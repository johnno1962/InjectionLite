//
//  LogParser.swift
//  Copyright © 2023 John Holdsworth. All rights reserved.
//
//  Parse the most recently built project's build
//  logs to find the command to recompile a Swift
//  file. The command needs to be processed a little
//  to only compile the injected Swift source (a.k.a
//  "-primary-file") to produce a single object file.
//
//  Created by John Holdsworth on 25/02/2023.
//
#if DEBUG || !SWIFT_PACKAGE
import Foundation

struct LogParser: LiteParser {

    /// "grep" the most recent build log for the command to recompile a file
    func command(for source: String, platformFilter: String = "",
                 found: inout (logDir: String, scanner: Popen?)?) -> String? {
        guard let logsDir = FileWatcher.derivedLog.flatMap({
            URL(fileURLWithPath: $0)
                .deletingLastPathComponent().path
                .replacingOccurrences(of: "$", with: "\\$")
        }) else {
            log("⚠️ Logs dir not initialised. Edit a file and build your project.")
            return nil
        }
        // Escape "difficult" characters for shell.
        let isSwift = source.hasSuffix(".swift")
        let triplesc = #"\\\\\\$1"#, escaped = source
            .replacingOccurrences(of: #"([ '(){}])"#, with: triplesc,
                                  options: .regularExpression)
            .replacingOccurrences(of: #"([$*&])"#, with: #"\\\\"#+triplesc,
                                  options: .regularExpression)
        let option = isSwift ? "-primary-file" : "-c"
        let platformRestrict = isSwift && platformFilter != "" ?
            "| /usr/bin/grep \(platformFilter)" : "",
            scanner = """
            cd "\(logsDir)" && for log in `/bin/ls -t *.xcactivitylog`; do \
                if /usr/bin/gunzip <$log | /usr/bin/tr '\\r' '\\n' | \
                    /usr/bin/grep -v builtin-ScanDependencies | /usr/bin/grep -v llvmcas:// | \
                    /usr/bin/grep " \(option) \(escaped) " \(platformRestrict); \
                then echo $log && exit; fi; done
            """,
            builtinSwiftc = #"builtin-Swift-Compilation"#, xCode26_3 = """
            cd "\(logsDir)" && for log in `/bin/ls -t *.xcactivitylog`; do \
                if /usr/bin/gunzip <$log | /usr/bin/tr '\\r' '\\n' | \
                    /usr/bin/grep \(builtinSwiftc) | \
                    /usr/bin/grep " -module-name \(Reloader.appName) " \(platformRestrict); \
                then exit; fi; exit; done
            """

        let scanning = Popen(cmd: scanner)
        guard let command = scanning?.readLine() ?? (true || getenv("XCODE_263") != nil ?
               Popen(cmd: xCode26_3)?.readLine() : nil) else {
            log("Log scanning failed: "+scanner)
            if !logsDir.contains(Reloader.appName) {
                log("⚠️ logsDir seems to be incorrect. Modify a file and rebuild.")
            }
            log("ℹ️ With Xcode 16.3+, have you tried adding build setting \(EMIT_FRONTEND_COMMAND_LINES)?")
            return nil
        }

        found = (logsDir, scanning)
        if command[builtinSwiftc] {
            return command
        }

        return makeSinglePrimary(source: source, command) +
            (isSwift ? "" : " -Xclang -fno-validate-pch")
    }

    /// re-process command to only compile a single file at a time.
    func makeSinglePrimary(source: String, _ command: String) -> String {
        func escape(path: String) -> String {
            return path.replacingOccurrences(of: #"([ '(){}$&*])"#,
                        with: #"\\$1"#, options: .regularExpression)
        }

        var command = command as NSString
        #if targetEnvironment(simulator) // has a case sensitive file system
        if let argument = try? NSRegularExpression(
            pattern: Reloader.fileNameRegex) {
            for match in argument.matches(in: command as String,
                          range: NSMakeRange(0, command.length)).reversed() {
                let range = match.range, path = command.substring(with: range)
                    .replacingOccurrences(of: #"\\(.)"#, with: "$1",
                                          options: .regularExpression)
                if let cased = actualCase(path: path), cased != path {
                    command = command.replacingCharacters(in: range,
                              with: escape(path: cased)) as NSString
                    detail("Cased \(path) -> \(cased)")
                }
            }
        }
        #endif

        let escaped = escape(path: source)
        return command
            // Remove all output object files
            .replacingOccurrences(of: " -o "+Reloader.fileNameRegex,
                                  with: " ", options: .regularExpression,
                                  range: NSMakeRange(0, command.length))
            // Strip out all per-primary-file options.
            .replacingOccurrences(of: " "+Reloader.optionsToRemove +
                                  " "+Reloader.argumentRegex,
                                  with: "", options: .regularExpression)
            // save to one side primary source file we are injecting
            .replacingOccurrences(of: " -primary-file "+escaped,
                                  with: " -primary-save "+escaped)
            // strip other -primary-file's or all files when -filelist
            .replacingOccurrences(of: " -primary-file " +
                                  (command.contains(" -filelist") ?
                                   Reloader.argumentRegex : ""),
                with: " ", options: .regularExpression)
            // restore the -primary-file saved above
            .replacingOccurrences(of: "-primary-save", with: "-primary-file")
            // Not required
            .replacingOccurrences(of:
                "-frontend-parseable-output ", with: "")
            // Strip junk with Xcode 16.3 and EMIT_FRONTEND_COMMAND_LINES
            .replacingOccurrences(of: #"^.*\d"/"#,
                                  with: "/", options: .regularExpression)
    }

    /// determine the real letter casing of a path on the file system
    public func actualCase(path: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            return path
        }
        var out = ""
        for component in path.split(separator: "/") {
            var real: String?
            if fm.fileExists(atPath: out+"/"+component) {
                real = String(component)
            } else {
                guard let contents = try? fm.contentsOfDirectory(atPath: "/"+out) else {
                    return nil
                }
                real = contents.first { $0.lowercased() == component.lowercased() }
            }

            guard let found = real else {
                return nil
            }
            out += "/" + found
        }
        return out
    }

    func prepareFinalCommand(command: String, source: String, objectFile: String, tmpdir: String, injectionNumber: Int) -> String {
        command + " -o \(objectFile)"
    }
}
#endif
