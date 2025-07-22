//
//  InjectionBase.swift
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  Start a FileWatcher in the user's home directory
//  and dispatch modified Swift files off to the
//  injection processing to recompile, link, load
//  and rebind into the app.
//
//  Created by John Holdsworth on 09/11/2024.
//

#if DEBUG || !SWIFT_PACKAGE
#if canImport(InjectionImplC)
import InjectionImplC
import InjectionImpl
#endif
import Foundation

open class InjectionBase: NSObject {

    public var watcher: FileWatcher?
    private var gitIgnoreParsers: [GitIgnoreParser] = []
    private let ignoreCache = NSCache<NSString, NSNumber>()

    /// Called from InjectionBoot.m, setup filewatch and wait...
    public override init() {
        super.init()
        Reloader.injectionQueue.async {
            self.performInjection()
        }
    }

    func performInjection() {
        #if !targetEnvironment(simulator) && !os(macOS)
        log(APP_NAME+": can only be used in the simulator or unsandboxed macOS")
        #endif
        let home = NSHomeDirectory()
            .replacingOccurrences(of: #"(/Users/[^/]+).*"#,
                                  with: "$1", options: .regularExpression)
        var dirs = [home]
        let library = home+"/Library"
        if let extra = getenv(INJECTION_DIRECTORIES) {
            dirs = String(cString: extra).components(separatedBy: ",")
                .map { $0.replacingOccurrences(of: #"^~"#,
                   with: home, options: .regularExpression) } // expand ~ in paths
            if FileWatcher.derivedLog == nil && dirs.allSatisfy({
                $0 != home && !$0.hasPrefix(library) }) {
                log("⚠️ INJECTION_DIRECTORIES should contain ~/Library")
                dirs.append(library)
            }
        }

        fileWatch(dirs: dirs)
    }

    func fileWatch(dirs: [String]) {
        // Load gitignore files for watched directories
        for dir in dirs {
            let parsers = GitIgnoreParser.findGitIgnoreFiles(startingFrom: dir)
            gitIgnoreParsers.append(contentsOf: parsers)
        }
        
        let isVapor = Reloader.injectionQueue != .main
        watcher = FileWatcher(roots: dirs, callback: { filesChanged in
            for file in filesChanged {
                if self.shouldProcessFile(file) {
                    self.inject(source: file)
                }
            }
        }, runLoop: isVapor ? CFRunLoopGetCurrent() : nil)
        log(APP_NAME+": Watching for source changes under \(dirs)/...")
        if isVapor {
            CFRunLoopRun()
        }
    }

    func inject(source: String) {
        fatalError("Subclass responsibilty: "+#function)
    }
    
    private func shouldProcessFile(_ filePath: String) -> Bool {
        // Early exit: Only process relevant source files
        guard isValidSourceFile(filePath) else {
            return false
        }
        
        // Use cached result if available
        if let cachedResult = ignoreCache.object(forKey: filePath as NSString) {
            return !cachedResult.boolValue
        }
        
        // Check if file should be ignored according to gitignore rules
        let isDirectory = FileManager.default.fileExists(atPath: filePath, isDirectory: nil)
        var shouldIgnore = false
        
        for parser in gitIgnoreParsers {
            if parser.shouldIgnore(path: filePath, isDirectory: isDirectory) {
                shouldIgnore = true
                break
            }
        }
        
        // Cache the result - NSCache handles memory management automatically
        ignoreCache.setObject(NSNumber(value: shouldIgnore), forKey: filePath as NSString)
        
        return !shouldIgnore
    }
    
    private func isValidSourceFile(_ filePath: String) -> Bool {
        let validExtensions = Set([".swift", ".m", ".mm", ".h", ".c", ".cpp", ".cc"])
        let fileExtension = "." + (filePath as NSString).pathExtension.lowercased()
        return validExtensions.contains(fileExtension)
    }
    
}
#endif
