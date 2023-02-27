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

import Foundation
import Popen

class LogParser {

    func command(for source: String) -> String? {
        guard let logsDir = FileWatcher.derivedLog.flatMap({
            URL(fileURLWithPath: $0)
                .deletingLastPathComponent().path
                .replacingOccurrences(of: "$", with: "\\$")
        }) else {
            log("⚠️ Logs dir not initialised")
            return nil
        }
        let triplesc = #"\\\\\\$1"#, escaped = source
            .replacingOccurrences(of: #"([ '(){}])"#, with: triplesc,
                                  options: .regularExpression)
            .replacingOccurrences(of: #"([$*&])"#, with: #"\\\\"#+triplesc,
                                  options: .regularExpression)
        let scanner = """
            cd "\(logsDir)" && for log in `/bin/ls -t *.xcactivitylog`; do \
                if /usr/bin/gunzip <$log | /usr/bin/tr '\\r' '\\n' | \
                    /usr/bin/grep " -primary-file \(escaped) "; \
                then echo $log && exit; fi; done
            """

        let scanning = popen(scanner, "r")
        defer { _ = pclose(scanning) }
        guard var command = scanning?.readLine() else {
            log("Scanner: "+scanner)
            return nil
        }

        command = makeSinglePrimary(source: source, command)
        return command
    }

    func makeSinglePrimary(source: String, _ command: String) -> String {
        let escape2 = source
            .replacingOccurrences(of: #"([ '(){}$&*])"#, with: #"\\$1"#,
                                  options: .regularExpression)
        return command
            // Strip out all per-primary file options.
            .replacingOccurrences(of: " -o "+Recompiler.fileNameRegex,
                with: " ", options: .regularExpression)
            .replacingOccurrences(of:
                #" -(pch-output-dir|supplementary-output-file-map|emit-(reference-)?dependencies|serialize-diagnostics|index-(store|unit-output))-path \#(Recompiler.argumentRegex)"#,
                                  with: "", options: .regularExpression)
            // save primary source file we are injecting
            .replacingOccurrences(of: " -primary-file "+escape2,
                                  with: " -primary-save "+escape2)
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
}
