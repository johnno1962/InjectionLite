//
//  LogParser.swift
//
//  Parse the most recently built project's build
//  logs to find the command to recompile a Swift
//  file. The command needs to be processed a little
//  to only compile the injected Swift source to
//  produce a single object file.
//
//  Created by John Holdsworth on 25/02/2023.
//
#if DEBUG
import Foundation
import Popen

struct LogParser {

    /// "grep" the most recent build log for the command to recompile a file
    func command(for source: String) -> String? {
        guard let logsDir = FileWatcher.derivedLog.flatMap({
            URL(fileURLWithPath: $0)
                .deletingLastPathComponent().path
                .replacingOccurrences(of: "$", with: "\\$")
        }) else {
            log("⚠️ Logs dir not initialised. Edit a file and build your project.")
            return nil
        }
        let triplesc = #"\\\\\\$1"#, escaped = source
            .replacingOccurrences(of: #"([ '(){}])"#, with: triplesc,
                                  options: .regularExpression)
            .replacingOccurrences(of: #"([$*&])"#, with: #"\\\\"#+triplesc,
                                  options: .regularExpression)
        let option = source.hasSuffix(".swift") ? "-primary-file" : "-c"
        let scanner = """
            cd "\(logsDir)" && for log in `/bin/ls -t *.xcactivitylog`; do \
                if /usr/bin/gunzip <$log | /usr/bin/tr '\\r' '\\n' | \
                    /usr/bin/grep " \(option) \(escaped) "; \
                then echo $log && exit; fi; done
            """

        let scanning = popen(scanner, "r")
        defer { _ = pclose(scanning) }
        guard let command = scanning?.readLine() else {
            log("Scanner: "+scanner)
            return nil
        }

        return makeSinglePrimary(source: source, command)
    }

    /// re-process command to only compile a single file at a time.
    func makeSinglePrimary(source: String, _ command: String) -> String {
        func escape(path: String) -> String {
            return path.replacingOccurrences(of: #"([ '(){}$&*])"#,
                        with: #"\\$1"#, options: .regularExpression)
        }

        var command = command as NSString
        #if targetEnvironment(simulator) // case sensitive file system
        if let argument = try? NSRegularExpression(
            pattern: Recompiler.fileNameRegex) {
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
            // Strip out all per-primary file options.
            .replacingOccurrences(of: " -o "+Recompiler.fileNameRegex,
                                  with: " ", options: .regularExpression,
                                  range: NSMakeRange(0, command.length))
            .replacingOccurrences(of:
                #" -(pch-output-dir|supplementary-output-file-map|emit-(reference-)?dependencies|serialize-diagnostics|index-(store|unit-output))-path \#(Recompiler.argumentRegex)"#,
                                  with: "", options: .regularExpression)
            // save primary source file we are injecting
            .replacingOccurrences(of: " -primary-file "+escaped,
                                  with: " -primary-save "+escaped)
            // strip other -primary-file or all files when -filelist
            .replacingOccurrences(of: " -primary-file " +
                                  (command.contains(" -filelist") ?
                                   Recompiler.argumentRegex : ""),
                with: " ", options: .regularExpression)
            // restore the -primary-file
            .replacingOccurrences(of: "-primary-save", with: "-primary-file")
            .replacingOccurrences(of:
                "-frontend-parseable-output ", with: "")
    }

    /// determine the real casing of a path on the file system
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
}
#endif
